import Foundation
import os

/// Backup preferences (UserDefaults keys). All under the `backup.` prefix,
/// which ScribeBackupSettings never exports.
enum ScribeBackupPreferences {
    static let autoEnabledKey = "backup.autoEnabled"
    static let autoFolderKey = "backup.autoFolderPath"
    static let autoKeepCountKey = "backup.autoKeepCount"
    /// Double — `timeIntervalSince1970` of the last successful automatic backup.
    static let lastAutoBackupKey = "backup.lastAutoBackupAt"
    /// String — the last automatic backup failure, cleared on success.
    static let lastAutoBackupErrorKey = "backup.lastAutoBackupError"
    static let defaultKeepCount = 7
}

/// Resolves the live app's backup inputs and restore targets. Nonisolated so
/// the background scheduler can use it.
enum ScribeBackupEnvironment {

    /// `~/Library/Application Support/Scribe`.
    nonisolated static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Scribe", isDirectory: true)
    }

    /// Where "Before Restore …" safety copies go.
    nonisolated static func safetyCopiesDirectory() -> URL {
        supportDirectory().appendingPathComponent("Restore Safety Copies", isDirectory: true)
    }

    /// The vault root currently in use.
    nonisolated static func currentVaultRoot() -> URL? {
        if let root = NoteStore.shared.fileStore?.directory.root { return root }
        return (try? NotesDirectory.defaultLocation())?.root
    }

    nonisolated static func appVersion() -> (version: String, build: String) {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return (version, build)
    }

    nonisolated static func makeSources() -> ScribeBackupSources {
        let settings = ScribeBackupSettings.currentSettingsPlist()
        let version = appVersion()
        return ScribeBackupSources(
            database: DatabaseManager.shared,
            vaultRoot: currentVaultRoot(),
            supportFiles: [VocabularyStore.defaultFileURL()],
            settingsPlist: settings?.data,
            settingsCount: settings?.count ?? 0,
            appVersion: version.version,
            appBuild: version.build
        )
    }

    nonisolated static func makeRestoreTargets(vaultRoot: URL) -> ScribeRestoreTargets {
        ScribeRestoreTargets(
            database: DatabaseManager.shared,
            vaultRoot: vaultRoot,
            supportDirectory: supportDirectory(),
            safetyCopiesDirectory: safetyCopiesDirectory()
        )
    }
}

/// Runs automatic backups. Nonisolated and synchronous: called from the
/// background-activity scheduler's queue and from detached tasks.
enum ScribeAutoBackupRunner {

    private static let running = OSAllocatedUnfairLock(initialState: false)

    /// Whether automatic backups are on and have a folder.
    nonisolated static func isConfigured() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: ScribeBackupPreferences.autoEnabledKey) else { return false }
        let folder = defaults.string(forKey: ScribeBackupPreferences.autoFolderKey) ?? ""
        return !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func lastBackupDate() -> Date? {
        let stamp = UserDefaults.standard.double(forKey: ScribeBackupPreferences.lastAutoBackupKey)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    nonisolated static func keepCount() -> Int {
        let stored = UserDefaults.standard.integer(forKey: ScribeBackupPreferences.autoKeepCountKey)
        return ScribeBackupRetention.clampedKeepCount(stored == 0 ? ScribeBackupPreferences.defaultKeepCount : stored)
    }

    /// Makes a backup when one is due (or always, with `force`), then prunes
    /// old automatic backups. Returns the archive written, or nil when nothing
    /// ran. Concurrent calls are collapsed: a second caller returns nil.
    @discardableResult
    nonisolated static func runIfDue(now: Date = Date(), force: Bool = false) throws -> URL? {
        guard isConfigured() else { return nil }
        guard force || ScribeBackupRetention.isBackupDue(lastBackupAt: lastBackupDate(), now: now) else { return nil }
        let acquired = running.withLock { (busy: inout Bool) -> Bool in
            if busy { return false }
            busy = true
            return true
        }
        guard acquired else { return nil }
        defer { running.withLock { (busy: inout Bool) in busy = false } }

        let defaults = UserDefaults.standard
        let folderPath = defaults.string(forKey: ScribeBackupPreferences.autoFolderKey) ?? ""
        let folder = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(
                ScribeBackupRetention.fileName(for: now, automatic: true),
                isDirectory: false
            )
            try ScribeBackupArchiver.createArchive(
                sources: ScribeBackupEnvironment.makeSources(),
                destination: destination,
                now: now,
                automatic: true
            )
            defaults.set(now.timeIntervalSince1970, forKey: ScribeBackupPreferences.lastAutoBackupKey)
            defaults.removeObject(forKey: ScribeBackupPreferences.lastAutoBackupErrorKey)
            prune(folder: folder)
            Log.storage.info("Automatic backup written to \(destination.lastPathComponent, privacy: .public).")
            return destination
        } catch {
            defaults.set(error.localizedDescription, forKey: ScribeBackupPreferences.lastAutoBackupErrorKey)
            Log.storage.error("Automatic backup failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Deletes automatic backups beyond the keep count. Manual backups and
    /// unrelated files are never touched.
    nonisolated static func prune(folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let candidates = ScribeBackupRetention.automaticBackups(in: folder, fileNames: names)
        for backup in ScribeBackupRetention.backupsToDelete(candidates, keeping: keepCount()) {
            do {
                try FileManager.default.removeItem(at: backup.url)
            } catch {
                Log.storage.error("Couldn't prune old backup \(backup.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)")
            }
        }
    }
}
