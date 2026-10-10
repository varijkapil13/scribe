import AppKit
import SwiftUI

/// Settings → Backup: manual backup / restore and automatic daily backups.
struct BackupSettingsPane: View {
    @ObservedObject private var controller: ScribeBackupController = .shared

    @AppStorage(ScribeBackupPreferences.autoEnabledKey) private var autoEnabled: Bool = false
    @AppStorage(ScribeBackupPreferences.autoFolderKey) private var autoFolderPath: String = ""
    @AppStorage(ScribeBackupPreferences.autoKeepCountKey) private var keepCount: Int = ScribeBackupPreferences.defaultKeepCount
    @AppStorage(ScribeBackupPreferences.lastAutoBackupKey) private var lastBackupStamp: Double = 0
    @AppStorage(ScribeBackupPreferences.lastAutoBackupErrorKey) private var lastBackupError: String = ""

    var body: some View {
        Form {
            Section("Back up and restore") {
                HStack {
                    Button("Back Up Scribe…") { controller.backUpInteractively() }
                    Button("Restore from Backup…") { controller.restoreInteractively() }
                    Spacer()
                    if controller.isWorking {
                        ProgressView().controlSize(.small)
                        if let message = controller.progressMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(controller.isWorking)
                Text("A backup is one .\(ScribeBackupManifest.fileExtension) file with your notes vault (including attachments and templates), transcripts, tasks, vocabulary and settings. Recorded audio isn't included. Restoring moves your current data to a safety folder first — nothing is deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Automatic backups") {
                Toggle("Back up automatically every day", isOn: $autoEnabled)
                    .onChange(of: autoEnabled) { _, enabled in
                        if enabled && autoFolderPath.isEmpty {
                            chooseFolder()
                        }
                        ScribeAutoBackupScheduler.shared.refresh()
                    }

                LabeledContent("Folder") {
                    HStack {
                        Text(autoFolderPath.isEmpty ? "Not chosen" : autoFolderPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(autoFolderPath)
                        Button("Choose…", action: chooseFolder)
                        if !autoFolderPath.isEmpty {
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: autoFolderPath)])
                            }
                        }
                    }
                }

                Stepper(value: keepCountBinding, in: ScribeBackupRetention.keepCountRange) {
                    Text("Keep the last \(keepCountBinding.wrappedValue) automatic backup\(keepCountBinding.wrappedValue == 1 ? "" : "s")")
                }

                LabeledContent("Last automatic backup") {
                    Text(lastBackupText)
                        .foregroundStyle(.secondary)
                }
                if !lastBackupError.isEmpty {
                    Label(lastBackupError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Button("Back Up Now") { controller.backUpToAutomaticFolderNow() }
                    .disabled(!autoEnabled || autoFolderPath.isEmpty || controller.isWorking)

                Text("Scribe checks about once an hour while it's open and makes a backup when a day has passed. Older automatic backups beyond the number kept are deleted; backups you make yourself are never deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var keepCountBinding: Binding<Int> {
        Binding(
            get: { ScribeBackupRetention.clampedKeepCount(keepCount == 0 ? ScribeBackupPreferences.defaultKeepCount : keepCount) },
            set: { keepCount = ScribeBackupRetention.clampedKeepCount($0) }
        )
    }

    private var lastBackupText: String {
        guard lastBackupStamp > 0 else { return "Never" }
        return Date(timeIntervalSince1970: lastBackupStamp).formatted(date: .abbreviated, time: .shortened)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Automatic Backup Folder"
        panel.message = "Choose where Scribe saves its daily backups — ideally another disk or a synced folder."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            autoFolderPath = url.path
        } else if autoFolderPath.isEmpty {
            autoEnabled = false
        }
        ScribeAutoBackupScheduler.shared.refresh()
    }
}
