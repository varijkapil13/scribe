import AppKit
import Foundation
import UniformTypeIdentifiers

/// Drives the interactive "Back Up Scribe…" and "Restore from Backup…"
/// flows (File menu and Settings → Backup): panels, confirmation, progress
/// and the relaunch prompt. The file work itself runs off the main actor in
/// `ScribeBackupArchiver`.
@MainActor
final class ScribeBackupController: ObservableObject {

    static let shared = ScribeBackupController()

    /// True while a backup or restore is running (disables the buttons).
    @Published private(set) var isWorking = false
    /// What's happening right now, for Settings → Backup.
    @Published private(set) var progressMessage: String?

    private init() {}

    /// The archive type for save/open panels. A dynamic type derived from the
    /// extension (the type isn't declared in Info.plist), falling back to zip.
    static var archiveContentType: UTType {
        UTType(filenameExtension: ScribeBackupManifest.fileExtension, conformingTo: .zip) ?? .zip
    }

    // MARK: - Back up

    func backUpInteractively() {
        guard !isWorking else { return }
        let panel = NSSavePanel()
        panel.title = "Back Up Scribe"
        panel.message = "Saves your notes, attachments, transcripts, tasks and settings into one file."
        panel.prompt = "Back Up"
        panel.nameFieldStringValue = ScribeBackupRetention.fileName(for: Date(), automatic: false)
        panel.allowedContentTypes = [Self.archiveContentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        begin("Backing up…")
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ScribeBackupManifest, any Error> in
                Result {
                    try ScribeBackupArchiver.createArchive(
                        sources: ScribeBackupEnvironment.makeSources(),
                        destination: destination,
                        now: Date(),
                        automatic: false
                    )
                }
            }.value
            end()
            switch result {
            case .success(let manifest):
                showBackupFinished(manifest, at: destination)
            case .failure(let error):
                showError(title: "Backup Failed", error: error)
            }
        }
    }

    /// "Back Up Now" for the automatic-backup folder (Settings → Backup).
    func backUpToAutomaticFolderNow() {
        guard !isWorking else { return }
        begin("Backing up…")
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL?, any Error> in
                Result { try ScribeAutoBackupRunner.runIfDue(force: true) }
            }.value
            end()
            switch result {
            case .success(let url):
                if let url {
                    AppState.shared.notify("Backed up to \(url.lastPathComponent).")
                }
            case .failure(let error):
                showError(title: "Backup Failed", error: error)
            }
        }
    }

    // MARK: - Restore

    func restoreInteractively() {
        guard !isWorking else { return }
        if AppState.shared.isTranscribing {
            let alert = NSAlert()
            alert.messageText = "Stop Recording First"
            alert.informativeText = "Scribe can't restore a backup while a recording is in progress."
            alert.runModal()
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Restore from Backup"
        panel.message = "Choose a Scribe backup (.\(ScribeBackupManifest.fileExtension))."
        panel.prompt = "Open"
        panel.allowedContentTypes = [Self.archiveContentType, .zip]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let archive = panel.url else { return }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScribeRestore-\(UUID().uuidString)", isDirectory: true)
        begin("Checking backup…")
        Task {
            let opened = await Task.detached(priority: .userInitiated) { () -> Result<ScribeBackupInspection, any Error> in
                Result { () throws -> ScribeBackupInspection in
                    let root = try ScribeBackupArchiver.extractArchive(archive, into: scratch)
                    let known = try ScribeBackupArchiver.knownMigrationIdentifiers()
                    return try ScribeBackupArchiver.inspect(extractedRoot: root, knownMigrations: known)
                }
            }.value

            let inspection: ScribeBackupInspection
            switch opened {
            case .success(let value):
                inspection = value
            case .failure(let error):
                end()
                Self.removeScratch(scratch)
                showError(title: "Can't Open Backup", error: error)
                return
            }

            guard inspection.canRestore else {
                end()
                Self.removeScratch(scratch)
                showError(title: "Can't Restore This Backup", error: ScribeBackupError.cannotRestore(inspection.issues))
                return
            }

            progressMessage = nil
            guard confirmRestore(inspection) else {
                end()
                Self.removeScratch(scratch)
                return
            }
            await performRestore(inspection, scratch: scratch)
        }
    }

    private func confirmRestore(_ inspection: ScribeBackupInspection) -> Bool {
        let date = inspection.manifest.createdAt.formatted(date: .long, time: .shortened)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restore This Backup?"
        alert.informativeText = inspection.manifest.summaryText(formattedDate: date)
            + "\n\nYour current notes, transcripts, tasks and settings are moved to a safety folder first "
            + "(Application Support › Scribe › Restore Safety Copies) — nothing is deleted. "
            + "Scribe relaunches afterwards."
        let restore = alert.addButton(withTitle: "Restore")
        restore.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func performRestore(_ inspection: ScribeBackupInspection, scratch: URL) async {
        guard let vaultRoot = VaultCoordinator.shared.currentRoot ?? ScribeBackupEnvironment.currentVaultRoot() else {
            end()
            Self.removeScratch(scratch)
            showError(title: "Restore Failed", message: "Scribe couldn't find the current notes vault.")
            return
        }
        progressMessage = "Restoring…"

        // Stop watching the vault while it's swapped so the reconciler never
        // sees the half-moved folder.
        VaultCoordinator.shared.stop()
        let currentSettings = ScribeBackupSettings.currentSettingsPlist()?.data
        let targets = ScribeBackupEnvironment.makeRestoreTargets(vaultRoot: vaultRoot)

        let result = await Task.detached(priority: .userInitiated) { () -> Result<ScribeRestoreOutcome, any Error> in
            Result {
                try ScribeBackupArchiver.restore(
                    inspection,
                    into: targets,
                    currentSettingsPlist: currentSettings,
                    now: Date()
                )
            }
        }.value

        Self.removeScratch(scratch)
        // Resume watching whichever vault is now in place.
        VaultCoordinator.shared.start()
        end()

        switch result {
        case .success(let outcome):
            if let settings = outcome.settingsPlist {
                do {
                    try ScribeBackupSettings.apply(settings)
                } catch {
                    Log.storage.error("Restoring settings failed: \(error.localizedDescription, privacy: .private)")
                }
            }
            askToRelaunch(safetyFolder: outcome.safetyCopyFolder)
        case .failure(let error):
            showError(
                title: "Restore Failed",
                message: "\(error.localizedDescription)\n\nYour data was left as it was."
            )
        }
    }

    private func askToRelaunch(safetyFolder: URL) {
        let alert = NSAlert()
        alert.messageText = "Backup Restored"
        alert.informativeText = "Relaunch Scribe to finish loading the restored data. "
            + "Your previous data is in “\(safetyFolder.lastPathComponent)”."
        alert.addButton(withTitle: "Relaunch Now")
        alert.addButton(withTitle: "Show Previous Data")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Self.relaunch()
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([safetyFolder])
        default:
            break
        }
    }

    /// Starts a fresh copy of the app once this process has exited, then quits.
    static func relaunch() {
        let bundlePath = Bundle.main.bundleURL.path
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // $0 = bundle path, $1 = our pid: wait for us to exit, then reopen.
        process.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
            bundlePath,
            pid,
        ]
        do {
            try process.run()
        } catch {
            Log.app.error("Couldn't schedule relaunch: \(error.localizedDescription, privacy: .private)")
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func begin(_ message: String) {
        isWorking = true
        progressMessage = message
    }

    private func end() {
        isWorking = false
        progressMessage = nil
    }

    private nonisolated static func removeScratch(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func showBackupFinished(_ manifest: ScribeBackupManifest, at url: URL) {
        let alert = NSAlert()
        alert.messageText = "Backup Complete"
        alert.informativeText = "Saved \(manifest.counts.notes) notes, \(manifest.counts.sessions) transcripts "
            + "and \(manifest.counts.tasks) tasks to “\(url.lastPathComponent)”."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func showError(title: String, error: any Error) {
        showError(title: title, message: error.localizedDescription)
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
