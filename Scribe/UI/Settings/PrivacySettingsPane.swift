import AppKit
import SwiftUI

/// Settings → Privacy: what Scribe stores and where, which permissions it
/// holds, and which features can reach beyond this Mac.
struct PrivacySettingsPane: View {
    @StateObject private var model = PrivacyDashboardModel()
    @ObservedObject private var mcpServer: MCPServer = .shared

    @AppStorage(CloudKitSyncService.enabledDefaultsKey) private var iCloudTaskSync: Bool = false
    @AppStorage("iCloudNotesEnabled") private var iCloudNotes: Bool = false
    @AppStorage(MeetingHookSettings.enabledKey) private var hooksEnabled: Bool = false
    @AppStorage(MeetingDetectionMode.defaultsKey) private var meetingDetection: MeetingDetectionMode = MeetingDetectionMode.defaultValue
    @AppStorage(CalendarService.enabledKey) private var calendarEnabled: Bool = false
    @AppStorage(PlantUMLRenderingPreference.remoteEnabledKey) private var plantUMLRemote: Bool = PlantUMLRenderingPreference.defaultValue
    @AppStorage(SpeakerDiarizationSettings.allowModelDownloadKey) private var diarizerDownload: Bool = true
    @AppStorage(SessionAudioStorage.retainAudioKey) private var retainAudio: Bool = false
    @AppStorage(ScribeBackupPreferences.autoEnabledKey) private var autoBackup: Bool = false

    @State private var deleteOlderThan: AudioRetentionPolicy = .days30
    @State private var confirmAudioDelete = false

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        Text("Your data stays on this Mac")
                            .font(.callout.weight(.semibold))
                        Text("Recording, transcription, speaker detection, summaries, Ask and dictation clean-up all run on-device with Apple's speech recognition and Apple Intelligence. Scribe has no account, no servers and no analytics. Nothing leaves your Mac unless you turn on one of the connections below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.green)
                }
            }

            Section("What Scribe stores") {
                storageRow(
                    "Notes vault",
                    detail: "Markdown notes, attachments and templates",
                    path: model.vaultPath,
                    bytes: model.vaultBytes
                )
                storageRow(
                    "Database",
                    detail: "Transcripts, summaries, tasks and the search index",
                    path: model.databasePath,
                    bytes: model.databaseBytes
                )
                storageRow(
                    "Recorded audio",
                    detail: retainAudio ? "Kept for playback (Settings → Storage & Sync)" : "Not kept for new recordings",
                    path: model.audioPath,
                    bytes: model.audioBytes
                )
                HStack {
                    Picker("Delete recorded audio older than", selection: $deleteOlderThan) {
                        ForEach(AudioRetentionPolicy.allCases.filter { $0.retentionDays != nil }) { policy in
                            Text("\(policy.retentionDays ?? 0) days").tag(policy)
                        }
                    }
                    Button("Delete…") { confirmAudioDelete = true }
                        .disabled(model.isDeletingAudio)
                }
                .confirmationDialog(
                    "Delete recorded audio older than \(deleteOlderThan.retentionDays ?? 0) days?",
                    isPresented: $confirmAudioDelete,
                    titleVisibility: .visible
                ) {
                    Button("Delete Audio", role: .destructive) {
                        model.deleteAudio(olderThan: deleteOlderThan)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Transcripts and notes are kept; only the audio files of finished recordings are removed. This can't be undone.")
                }
            }

            Section("Permissions") {
                ForEach(PrivacyPermissionKind.allCases) { kind in
                    permissionRow(kind)
                }
                Text("macOS asks before Scribe can use any of these. Changes made in System Settings show here when you come back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Connections") {
                connectionRow("iCloud task sync", isOn: iCloudTaskSync,
                              detail: "Tasks sync through your private iCloud database.")
                connectionRow("Notes in iCloud Drive", isOn: iCloudNotes,
                              detail: "Your vault lives in iCloud Drive and syncs with Apple's servers.")
                connectionRow("MCP server", isOn: mcpServer.isRunning,
                              detail: "Lets AI tools on this Mac read your meetings over localhost with a token. Never reachable from other computers.")
                connectionRow("Post-meeting hooks", isOn: hooksEnabled,
                              detail: "Runs your own scripts with each meeting's transcript when recording stops.")
                connectionRow("Meeting auto-detection", isOn: meetingDetection != .off,
                              detail: "Watches which apps use the microphone (\(meetingDetection.title)). Nothing is recorded until you start or allow it.")
                connectionRow("Calendar integration", isOn: calendarEnabled,
                              detail: "Reads event titles and attendees on this Mac.")
                connectionRow("PlantUML diagrams via plantuml.com", isOn: plantUMLRemote,
                              detail: "Sends diagram source to plantuml.com to draw it.")
                connectionRow("Speaker model download", isOn: diarizerDownload,
                              detail: "If the speaker model isn't bundled, downloads it once. No audio or text is sent.")
                connectionRow("Automatic backups", isOn: autoBackup,
                              detail: "Copies your data daily to the folder you chose (Settings → Backup).")
            }
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshPermissions() }
        }
    }

    // MARK: - Rows

    private func storageRow(_ title: String, detail: String, path: String?, bytes: Int64?) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Calculating…")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let path, FileManager.default.fileExists(atPath: path) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        Image(systemName: "magnifyingglass.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal \(title) in Finder")
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let path {
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                    .textSelection(.enabled)
            }
        }
    }

    private func permissionRow(_ kind: PrivacyPermissionKind) -> some View {
        let state = model.permissions[kind] ?? .unknown
        return HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: kind.systemImage)
                .frame(width: 18)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(kind.title)
                Text(kind.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Label(state.label, systemImage: state.systemImage)
                .font(.caption)
                .foregroundStyle(color(for: state))
            Button("Open System Settings") {
                PrivacyPermissionProbe.openSettings(for: kind)
            }
            .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
    }

    private func connectionRow(_ title: String, isOn: Bool, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(isOn ? "On" : "Off")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isOn ? Color.orange : Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func color(for state: PrivacyPermissionState) -> Color {
        switch state {
        case .granted:                 return .green
        case .limited:                 return .yellow
        case .denied:                  return .orange
        case .notDetermined, .unknown: return .secondary
        }
    }
}

// MARK: - Model

/// Live figures for the Privacy pane. Disk sizes are computed off the main
/// actor.
@MainActor
final class PrivacyDashboardModel: ObservableObject {
    @Published private(set) var permissions: [PrivacyPermissionKind: PrivacyPermissionState] = [:]
    @Published private(set) var vaultPath: String?
    @Published private(set) var vaultBytes: Int64?
    @Published private(set) var databasePath: String?
    @Published private(set) var databaseBytes: Int64?
    @Published private(set) var audioPath: String?
    @Published private(set) var audioBytes: Int64?
    @Published private(set) var isDeletingAudio = false

    func refresh() async {
        await refreshPermissions()
        await refreshStorage()
    }

    func refreshPermissions() async {
        permissions = await PrivacyPermissionProbe.states(of: PrivacyPermissionKind.allCases)
    }

    func refreshStorage() async {
        let vaultRoot = VaultCoordinator.shared.currentRoot ?? ScribeBackupEnvironment.currentVaultRoot()
        let databasePath = DatabaseManager.shared.database.path
        let audioRoot = SessionAudioStorage.defaultRoot()
        self.vaultPath = vaultRoot?.path
        self.databasePath = databasePath
        self.audioPath = audioRoot.path

        let store = TranscriptStore.shared
        let sizes = await Task.detached(priority: .utility) { () -> (vault: Int64, database: Int64, audio: Int64) in
            let vault = vaultRoot.map { SessionAudioStorage.diskUsage(of: $0) } ?? 0
            let database = Self.databaseFileSize(atPath: databasePath)
            let directories = (try? store.fetchAllAudioDirectories()) ?? []
            let audio = SessionAudioStorage.totalDiskUsage(root: audioRoot, sessionDirectories: directories)
            return (vault, database, audio)
        }.value
        vaultBytes = sizes.vault
        databaseBytes = sizes.database
        audioBytes = sizes.audio
    }

    /// Deletes the audio of finished recordings older than `policy`'s window
    /// (the same sweep the retention setting runs at launch).
    func deleteAudio(olderThan policy: AudioRetentionPolicy) {
        guard !isDeletingAudio else { return }
        isDeletingAudio = true
        let store = TranscriptStore.shared
        Task {
            let result = await Task.detached(priority: .utility) { () -> Result<Int, any Error> in
                Result { try store.sweepExpiredAudio(policy: policy) }
            }.value
            isDeletingAudio = false
            switch result {
            case .success(let count):
                AppState.shared.notify("Deleted audio from \(count) recording\(count == 1 ? "" : "s").")
            case .failure(let error):
                AppState.shared.report(error)
            }
            await refreshStorage()
        }
    }

    /// The SQLite file plus its journal / WAL side files.
    nonisolated static func databaseFileSize(atPath path: String) -> Int64 {
        let fm = FileManager.default
        return ["", "-wal", "-shm", "-journal"].reduce(Int64(0)) { total, suffix in
            let size = (try? fm.attributesOfItem(atPath: path + suffix))?[.size] as? NSNumber
            return total + (size?.int64Value ?? 0)
        }
    }
}
