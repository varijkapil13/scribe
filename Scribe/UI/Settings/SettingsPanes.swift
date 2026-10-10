import SwiftUI
import KeyboardShortcuts
import AppKit
import ServiceManagement

/// One settings screen in the Settings window. Each pane is a standalone
/// `View`, chosen from the window's sidebar (see `SettingsRootView`), where
/// panes are listed under their `SettingsPaneGroup`.
enum SettingsPane: String, CaseIterable, Hashable, Identifiable {
    case general
    case intelligence
    case storage
    case dictation
    case calendar
    case reminders
    case vocabulary
    case hooks
    case shortcuts
    case links
    case templates
    case mcp
    case about
    case privacy
    case backup
    case documents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:      return "General"
        case .intelligence: return "Intelligence"
        case .storage:      return "Storage & Sync"
        case .dictation:    return "Dictation"
        case .calendar:     return "Calendar"
        case .reminders:    return "Reminders"
        case .vocabulary:   return "Vocabulary"
        case .hooks:        return "Hooks"
        case .shortcuts:    return "Shortcuts"
        case .links:        return "Links & Handoff"
        case .templates:    return "Templates"
        case .mcp:          return "MCP Server"
        case .about:        return "About"
        case .privacy:      return "Privacy"
        case .backup:       return "Backup"
        case .documents:    return "Documents"
        }
    }

    var systemImage: String {
        switch self {
        case .general:      return "gear"
        case .intelligence: return "sparkles"
        case .storage:      return "internaldrive"
        case .dictation:    return "mic.badge.plus"
        case .calendar:     return "calendar"
        case .reminders:    return "checklist"
        case .vocabulary:   return "character.book.closed"
        case .hooks:        return "terminal"
        case .shortcuts:    return "keyboard"
        case .links:        return "link"
        case .templates:    return "doc.text.magnifyingglass"
        case .mcp:          return "server.rack"
        case .about:        return "info.circle"
        case .privacy:      return "hand.raised"
        case .backup:       return "externaldrive.badge.timemachine"
        case .documents:    return "doc.on.doc"
        }
    }
}

/// Dispatches to the correct pane view based on the selected section.
struct SettingsPaneView: View {
    let pane: SettingsPane
    @ObservedObject var audioManager: AudioSessionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: pane.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("SETTINGS")
                    .eyebrowStyle()
            }
            Text(pane.title)
                .font(DesignTokens.Typography.title2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.top, DesignTokens.Spacing.xl)
        .padding(.bottom, DesignTokens.Spacing.lg)
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .general:      GeneralSettingsPane(audioManager: audioManager)
        case .intelligence: IntelligenceSettingsPane()
        case .storage:      StorageSettingsPane()
        case .dictation:    DictationSettingsPane()
        case .calendar:     CalendarSettingsPane()
        case .reminders:    RemindersSettingsPane()
        case .vocabulary:   VocabularySettingsPane()
        case .hooks:        HooksSettingsPane()
        case .shortcuts:    ShortcutsSettingsPane()
        case .links:        LinksSettingsPane()
        case .templates:    TemplatesSettingsPane()
        case .mcp:          MCPSettingsPane()
        case .about:        AboutSettingsPane()
        case .privacy:      PrivacySettingsPane()
        case .backup:       BackupSettingsPane()
        case .documents:    DocumentsSettingsPane()
        }
    }
}

/// Sidebar grouping for the Settings window. Groups with a `header` render as
/// a titled sidebar section; the rest render their panes as top-level rows.
/// Every `SettingsPane` belongs to exactly one group (pinned by tests).
enum SettingsPaneGroup: String, CaseIterable, Identifiable {
    case general
    case recording
    case intelligence
    case dictation
    case storageSync
    case shortcuts
    case mcp
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:      return "General"
        case .recording:    return "Recording"
        case .intelligence: return "Intelligence"
        case .dictation:    return "Dictation"
        case .storageSync:  return "Storage & Sync"
        case .shortcuts:    return "Shortcuts"
        case .mcp:          return "MCP"
        case .about:        return "About"
        }
    }

    /// Panes listed under this group, in sidebar order. Audio and meeting
    /// detection live inside the General pane; speaker naming inside
    /// Vocabulary.
    var panes: [SettingsPane] {
        switch self {
        case .general:      return [.general, .privacy]
        case .recording:    return [.calendar]
        case .intelligence: return [.intelligence, .templates, .vocabulary, .hooks]
        case .dictation:    return [.dictation]
        case .storageSync:  return [.storage, .reminders, .backup, .documents]
        case .shortcuts:    return [.shortcuts, .links]
        case .mcp:          return [.mcp]
        case .about:        return [.about]
        }
    }

    /// Section header shown in the sidebar, or nil for single-pane groups
    /// whose one row already carries the name.
    var header: String? {
        switch self {
        case .recording, .intelligence: return title
        default:                        return nil
        }
    }
}

extension SettingsPane {
    /// The sidebar group this pane is listed under.
    var group: SettingsPaneGroup {
        SettingsPaneGroup.allCases.first { $0.panes.contains(self) } ?? .general
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @ObservedObject var audioManager: AudioSessionManager
    @ObservedObject private var vault: VaultCoordinator = .shared

    @AppStorage("selectedMicrophoneID") var selectedMicID: String = ""
    @AppStorage("captureSystemAudio") var captureSystemAudio: Bool = true
    @AppStorage(AudioSessionManager.echoCancellationKey) var echoCancellation: Bool = true
    @AppStorage("selectedLanguage") var selectedLanguage: String = "auto"
    @AppStorage(NotesDirectory.userPreferenceKey) var notesVaultPath: String = ""
    @AppStorage(MeetingDetectionMode.defaultsKey) var meetingDetectionMode: MeetingDetectionMode = MeetingDetectionMode.defaultValue
    @AppStorage(MeetingEndAction.defaultsKey) var meetingEndAction: MeetingEndAction = MeetingEndAction.defaultValue
    @AppStorage(MeetingDetector.includeBrowsersKey) var detectBrowserMeetings: Bool = true
    @AppStorage(MeetingDetector.includeOtherAppsKey) var detectOtherApps: Bool = false
    @AppStorage(MenuBarPreferences.showIconKey) var showMenuBarIcon: Bool = true
    @AppStorage(PlantUMLRenderingPreference.remoteEnabledKey)
    var plantUMLRemoteEnabled: Bool = PlantUMLRenderingPreference.defaultValue

    @State private var openAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var openConfirm: OpenConfirm?
    @State private var moveConfirm: MoveConfirm?

    private var resolvedVaultPath: String {
        vault.currentRoot?.path
            ?? (notesVaultPath.isEmpty ? NotesDirectory.builtInDefault().path : notesVaultPath)
    }

    var body: some View {
        Form {
            Section("Notes vault") {
                HStack(alignment: .firstTextBaseline) {
                    Text("Location")
                    Spacer()
                    Text(resolvedVaultPath)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(resolvedVaultPath)
                }
                HStack {
                    Button("Move vault…") { startMove() }
                        .disabled(vault.isBusy)
                    Button("Open vault…") { startOpen() }
                        .disabled(vault.isBusy)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: resolvedVaultPath)]
                        )
                    }
                    .disabled(!FileManager.default.fileExists(atPath: resolvedVaultPath))
                    Spacer()
                    if vault.isBusy {
                        ProgressView().controlSize(.small)
                    }
                }
                // Vault move/open outcomes are recoverable/background events, so
                // they speak the one feedback language: failures route to the
                // unified banner, successes to the success toast (see
                // FeedbackPolicy) — no bespoke inline red/green status here.
                Text("Move copies your current notes into a new folder. Open switches Scribe to use an existing folder as the vault — your current files stay where they are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagrams") {
                toggleWithCaption(
                    "Render PlantUML diagrams with plantuml.com",
                    isOn: $plantUMLRemoteEnabled,
                    caption: "Sends diagram source to the internet (plantuml.com) to draw ```plantuml``` blocks. Off by default; when off, PlantUML blocks show their source. Mermaid diagrams always render on your Mac."
                )
            }

            Section("Audio") {
                Picker("Microphone", selection: $selectedMicID) {
                    Text("Automatic (mic in use)").tag("auto")
                    Text("System Default").tag("")
                    ForEach(audioManager.availableMicrophones(), id: \.id) { mic in
                        Text(mic.name).tag(String(mic.id))
                    }
                    // If the persisted ID belongs to a device that isn't
                    // currently plugged in, surface a disabled placeholder
                    // so the Picker has a tag matching the binding. Keeps
                    // the user's preference intact for when the device
                    // returns; suppresses the "invalid selection" warning.
                    if !selectedMicID.isEmpty,
                       !audioManager.availableMicrophones().contains(where: { String($0.id) == selectedMicID }) {
                        Text("Saved device (unavailable)").tag(selectedMicID)
                    }
                }
                Text("Automatic follows the mic you're actually speaking into — the one a call app (Teams, Zoom…) is using — even if it differs from your system default, and switches with you mid-session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                toggleWithCaption(
                    "Capture system audio",
                    isOn: $captureSystemAudio,
                    caption: "Record remote participants via ScreenCaptureKit. Requires Screen Recording permission."
                )
                toggleWithCaption(
                    "Echo cancellation (use when not wearing headphones)",
                    isOn: $echoCancellation,
                    caption: "Stops the mic from picking up remote participants playing through your speakers. Applies while system audio is captured; takes effect from the next recording."
                )
                .disabled(!captureSystemAudio)
            }

            Section("Meeting detection") {
                Picker("When a meeting starts", selection: $meetingDetectionMode) {
                    ForEach(MeetingDetectionMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("When it ends", selection: $meetingEndAction) {
                    ForEach(MeetingEndAction.allCases) { Text($0.title).tag($0) }
                }
                .disabled(meetingDetectionMode == .off)
                Toggle("Include calls in web browsers (Google Meet…)", isOn: $detectBrowserMeetings)
                    .disabled(meetingDetectionMode == .off)
                Toggle("Include any other app using the microphone", isOn: $detectOtherApps)
                    .disabled(meetingDetectionMode == .off)
                MeetingDetectionExtraSettings(detectionEnabled: meetingDetectionMode != .off)
                Text("Scribe notices when Zoom, Teams, Slack, FaceTime, Webex and other call apps start using your microphone. It only checks which app holds the mic and never listens until you record. Detection runs only while Scribe is open, so keep it in the menu bar and open at login to catch every call.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ConsentDisclosureSettingsSection()

            Section("Menu bar & login") {
                toggleWithCaption(
                    "Show Scribe in the menu bar",
                    isOn: $showMenuBarIcon,
                    caption: "Recording, dictation and meeting controls from the menu bar. While shown, closing the main window keeps Scribe running in the background."
                )
                Toggle("Open Scribe at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, enabled in setOpenAtLogin(enabled) }
            }

            Section("Transcription") {
                Picker("Language", selection: $selectedLanguage) {
                    ForEach(LanguageOptions.supported, id: \.code) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                Text("Powered by Apple Speech — on-device recognition with no model downloads required. Change applies live without a restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // VaultCoordinator also sets `lastError` from its background reconcile
        // (a recoverable failure). Forward any such failure to the unified
        // banner so vault problems speak the same language wherever they arise
        // (see FeedbackPolicy).
        .onChange(of: vault.lastError) { _, newValue in
            if let message = newValue {
                AppState.shared.report(message)
            }
        }
        .confirmationDialog(
            "Move vault?",
            isPresented: Binding(get: { moveConfirm != nil },
                                  set: { if !$0 { moveConfirm = nil } }),
            presenting: moveConfirm
        ) { confirm in
            Button("Move") {
                performMove(to: confirm.destination)
                moveConfirm = nil
            }
            Button("Cancel", role: .cancel) { moveConfirm = nil }
        } message: { confirm in
            Text("Scribe will copy your notes from \"\(resolvedVaultPath)\" to \"\(confirm.destination.path)\" and switch to the new location. The original folder is removed after the copy succeeds.")
        }
        .confirmationDialog(
            "Open vault?",
            isPresented: Binding(get: { openConfirm != nil },
                                  set: { if !$0 { openConfirm = nil } }),
            presenting: openConfirm
        ) { confirm in
            Button("Open") {
                performOpen(to: confirm.destination)
                openConfirm = nil
            }
            Button("Cancel", role: .cancel) { openConfirm = nil }
        } message: { confirm in
            let parts: [String] = [
                "Scribe will switch to \"\(confirm.destination.path)\". Files in your current vault are not deleted, but they won't appear in Scribe until you Open them back here.",
                confirm.toImport > 0 ? "\(confirm.toImport) note\(confirm.toImport == 1 ? "" : "s") will be imported." : nil,
                confirm.toRemove > 0 ? "\(confirm.toRemove) note\(confirm.toRemove == 1 ? "" : "s") in the current index will be removed (the source files are not touched)." : nil
            ].compactMap { $0 }
            Text(parts.joined(separator: "\n\n"))
        }
    }

    // MARK: - Open at login

    private func setOpenAtLogin(_ enabled: Bool) {
        // Also absorbs the onChange echo from the write-back below.
        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AppState.shared.report("Couldn't change Open at login: \(error.localizedDescription)")
        }
        // Reflect what actually happened (registration can need approval in
        // System Settings → General → Login Items).
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Notes vault — Move / Open

    private struct MoveConfirm: Identifiable {
        let id = UUID()
        let destination: URL
    }
    private struct OpenConfirm: Identifiable {
        let id = UUID()
        let destination: URL
        let toImport: Int
        let toRemove: Int
    }

    private func startMove() {
        let panel = NSOpenPanel()
        panel.title = "Move Notes Vault"
        panel.message = "Pick an empty folder. Scribe will copy your notes there and switch to it."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: resolvedVaultPath).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        moveConfirm = MoveConfirm(destination: url)
    }

    private func startOpen() {
        let panel = NSOpenPanel()
        panel.title = "Open Notes Vault"
        panel.message = "Pick an existing folder to use as the vault."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: resolvedVaultPath).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let preview = try vault.previewOpen(at: url)
            openConfirm = OpenConfirm(
                destination: url,
                toImport: preview.toImport,
                toRemove: preview.toRemove
            )
        } catch {
            AppState.shared.report(error)
        }
    }

    private func performMove(to destination: URL) {
        Task {
            do {
                let copied = try await vault.moveVault(to: destination)
                AppState.shared.notify("Moved \(copied) file\(copied == 1 ? "" : "s") to \(destination.lastPathComponent).")
            } catch {
                AppState.shared.report(error)
            }
        }
    }

    private func performOpen(to destination: URL) {
        Task {
            do {
                try await vault.openVault(at: destination)
                AppState.shared.notify("Opened \(destination.lastPathComponent).")
            } catch {
                AppState.shared.report(error)
            }
        }
    }
}

private extension GeneralSettingsPane {
    /// Confirm sheets — wired via View modifiers on the Form.
    @ViewBuilder
    func vaultConfirmSheets() -> some View {
        EmptyView()
    }
}

// MARK: - Intelligence

private struct IntelligenceSettingsPane: View {
    @AppStorage("autoSummarize") var autoSummarize: Bool = true
    @AppStorage("autoExtractActions") var autoExtractActions: Bool = true
    @AppStorage("autoAnalyze") var autoAnalyze: Bool = true
    @AppStorage("extractEntities") var extractEntities: Bool = true
    @AppStorage("detectLanguage") var detectLanguage: Bool = true
    @AppStorage("analyzeSentiment") var analyzeSentiment: Bool = true

    var body: some View {
        Form {
            Section {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Apple Intelligence is available on this Mac")
                        .font(.callout)
                }
            } header: {
                Text("Apple Intelligence")
            } footer: {
                Text("Summaries, action items, and smart search run entirely on-device. Analysis never sends audio or text off your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Automation") {
                toggleWithCaption(
                    "Auto-summarize after recording",
                    isOn: $autoSummarize,
                    caption: "Generate a meeting summary automatically when you stop recording."
                )
                toggleWithCaption(
                    "Auto-extract action items",
                    isOn: $autoExtractActions,
                    caption: "Pull out commitments and follow-ups as part of the summary."
                )
            }

            Section("Transcript Analysis") {
                toggleWithCaption(
                    "Auto-analyze transcripts",
                    isOn: $autoAnalyze,
                    caption: "Run on-device analysis when a recording ends. Fast and free — uses the NaturalLanguage framework."
                )
                toggleWithCaption(
                    "Extract entities",
                    isOn: $extractEntities,
                    caption: "Identify people, organisations, and places mentioned in the meeting."
                )
                toggleWithCaption(
                    "Detect language",
                    isOn: $detectLanguage,
                    caption: "Determine the primary and secondary languages spoken."
                )
                toggleWithCaption(
                    "Analyze sentiment",
                    isOn: $analyzeSentiment,
                    caption: "Score overall and per-speaker sentiment from -1.0 to +1.0."
                )
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Storage

private struct StorageSettingsPane: View {
    @AppStorage(SessionAudioStorage.retainAudioKey) var retainAudio: Bool = false
    @AppStorage(SessionAudioStorage.storageLocationKey) var storageLocation: String = ""
    @AppStorage(AudioRetentionPolicy.defaultsKey) var audioRetention: AudioRetentionPolicy = AudioRetentionPolicy.defaultValue
    @State private var audioUsageBytes: Int64?
    @AppStorage(CloudKitSyncService.enabledDefaultsKey) var iCloudSyncEnabled: Bool = false
    @AppStorage("iCloudNotesEnabled") var iCloudNotesEnabled: Bool = false
    @State private var notesState: NotesVaultState = .idle
    @State private var showDeleteConfirmation: Bool = false
    @State private var deleteError: String?
    @State private var didDelete: Bool = false

    enum NotesVaultState: Equatable {
        case idle, migrating, done
        case failed(String)
    }

    var body: some View {
        Form {
            Section("Storage") {
                toggleWithCaption(
                    "Retain raw audio recordings",
                    isOn: $retainAudio,
                    caption: "Keep each recording's audio (your mic and system audio, AAC) so you can play it back from the transcript. Off by default to save disk space. Applies from the next recording."
                )

                Picker("Keep audio", selection: $audioRetention) {
                    ForEach(AudioRetentionPolicy.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: audioRetention) { _, newPolicy in applyRetention(newPolicy) }

                LabeledContent("Audio on disk") {
                    Text(audioUsageBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Calculating…")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Location") {
                    HStack {
                        Text(storageLocation.isEmpty ? "Default" : storageLocation)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Change…", action: chooseStorageLocation)
                    }
                }
                Text("Audio recordings are saved in \(audioRootPath). Expired audio is deleted when Scribe opens; transcripts are kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("iCloud") {
                toggleWithCaption(
                    "Sync tasks with iCloud",
                    isOn: $iCloudSyncEnabled,
                    caption: "Keep tasks in sync across your devices. Requires iCloud."
                )
                if iCloudSyncEnabled && !CloudKitAvailability.isCloudKitEntitled {
                    Label("This build of Scribe isn't set up for iCloud, so tasks stay on this Mac for now.", systemImage: "icloud.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                toggleWithCaption(
                    "Store notes in iCloud Drive",
                    isOn: Binding(
                        get: { iCloudNotesEnabled },
                        set: { setNotesEnabled($0) }
                    ),
                    caption: "Copy your notes vault into iCloud Drive so it stays available on every device. Requires iCloud."
                )
                switch notesState {
                case .idle:
                    EmptyView()
                case .migrating:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Moving notes to iCloud Drive…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .done:
                    Label("Notes are stored in iCloud Drive.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            Section("Data") {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Delete All Transcripts…")
                    }
                }
                .confirmationDialog(
                    "Delete all transcripts?",
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete All Data", role: .destructive, action: deleteAllData)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This permanently removes every session, segment, summary, action item, and retained audio recording. Your notes are kept. This action cannot be undone.")
                }

                Text("Scribe stores data at ~/Library/Application Support/Scribe/.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refreshAudioUsage() }
        .alert("Couldn’t Delete Data", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
        .alert("Transcripts Deleted", isPresented: $didDelete) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("All sessions, segments, summaries, and action items were removed.")
        }
    }

    /// Enables/disables the iCloud Drive notes vault via `ICloudVaultMigrator`.
    /// ⚠️ DEVICE-VALIDATION-REQUIRED: the live migrate/copy paths need a
    /// signed-in iCloud account and a provisioned container, so they can only
    /// be exercised on a real device, not in CI.
    private func setNotesEnabled(_ enabled: Bool) {
        if enabled {
            notesState = .migrating
            Task {
                do {
                    try await ICloudVaultMigrator.enableICloudVault()
                    iCloudNotesEnabled = true
                    notesState = .done
                } catch {
                    iCloudNotesEnabled = false
                    notesState = .failed(error.localizedDescription)
                }
            }
        } else {
            ICloudVaultMigrator.disableICloudVault()
            iCloudNotesEnabled = false
            notesState = .idle
        }
    }

    /// Where new recordings' audio goes (re-read on each render, so it
    /// follows the Location picker).
    private var audioRootPath: String {
        _ = storageLocation
        return SessionAudioStorage.defaultRoot().path
    }

    private func chooseStorageLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        storageLocation = url.path
    }

    private func deleteAllData() {
        do {
            try TranscriptStore().deleteAllData()
            // Also sweep session folders no row referenced any more (only
            // UUID-named folders — the root may be inside a user folder).
            // Skipped mid-recording so the live session's files survive.
            if !AppState.shared.isTranscribing {
                SessionAudioStorage.removeOrphanFolders(
                    root: SessionAudioStorage.defaultRoot(),
                    knownSessionIds: []
                )
            }
            didDelete = true
        } catch {
            deleteError = error.localizedDescription
        }
        Task { await refreshAudioUsage() }
    }

    /// Applies a newly picked retention policy right away (rather than only
    /// on next launch), then refreshes the usage figure.
    private func applyRetention(_ policy: AudioRetentionPolicy) {
        let store = TranscriptStore.shared
        Task {
            await Task.detached(priority: .utility) {
                do {
                    try store.sweepExpiredAudio(policy: policy)
                } catch {
                    Log.storage.error("Retention sweep failed: \(error.localizedDescription, privacy: .private)")
                }
            }.value
            await refreshAudioUsage()
        }
    }

    /// Recomputes retained-audio disk usage off the main thread.
    private func refreshAudioUsage() async {
        let store = TranscriptStore.shared
        let root = SessionAudioStorage.defaultRoot()
        let bytes = await Task.detached(priority: .utility) { () -> Int64 in
            let directories = (try? store.fetchAllAudioDirectories()) ?? []
            return SessionAudioStorage.totalDiskUsage(root: root, sessionDirectories: directories)
        }.value
        audioUsageBytes = bytes
    }
}

// MARK: - Dictation

private struct DictationSettingsPane: View {
    @AppStorage(DictationController.Mode.defaultsKey) var mode: DictationController.Mode = .toggle
    @AppStorage(DictationController.removeFillersKey) var removeFillers: Bool = true
    @AppStorage(DictationController.smartCleanupKey) var smartCleanup: Bool = true
    @State private var hasAccessibility = TextInserter.hasAccessibilityPermission

    var body: some View {
        Form {
            Section("Shortcut") {
                KeyboardShortcuts.Recorder("Dictate:", name: .dictation)
                Picker("Mode", selection: $mode) {
                    ForEach(DictationController.Mode.allCases) { Text($0.title).tag($0) }
                }
                Text("Dictate into any app: press the shortcut, speak, and Scribe types the text where your cursor is. Uses on-device speech recognition in your transcription language, separately from meeting recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cleanup") {
                Toggle("Remove filler words (um, uh…)", isOn: $removeFillers)
                Toggle("Polish with Apple Intelligence", isOn: $smartCleanup)
                Text("Fixes punctuation, capitalization and false starts on-device before inserting. Falls back to the plain transcript if Apple Intelligence is unavailable or slow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Typing into other apps") {
                HStack {
                    Label(
                        hasAccessibility ? "Accessibility access granted" : "Accessibility access needed",
                        systemImage: hasAccessibility ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(hasAccessibility ? .green : .orange)
                    Spacer()
                    if !hasAccessibility {
                        Button("Grant Access…") {
                            hasAccessibility = TextInserter.requestAccessibilityPermission()
                            if !hasAccessibility { TextInserter.openAccessibilitySettings() }
                        }
                    }
                }
                Text("Scribe pastes dictated text with ⌘V, which needs Accessibility access. Without it, the text is copied to the clipboard for you to paste.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Pick up a grant made in System Settings while this pane is open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasAccessibility = TextInserter.hasAccessibilityPermission
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettingsPane: View {
    var body: some View {
        Form {
            Section("Global Shortcuts") {
                KeyboardShortcuts.Recorder("Toggle Recording:", name: .toggleRecording)
                KeyboardShortcuts.Recorder("Dictate:", name: .dictation)
                KeyboardShortcuts.Recorder("Quick Capture:", name: .quickCapture)
                Text("Press these shortcuts from any app to start or stop recording, dictate into the focused app, or jot down a note or task, without opening Scribe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SiriSpotlightSettingsSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutSettingsPane: View {

    private var appVersion: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "© Varij. All rights reserved."
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "—")
                LabeledContent("Minimum macOS", value: "26.0")
                LabeledContent("Architecture", value: "Apple Silicon")
            } header: {
                Text("Scribe")
            } footer: {
                Text("On-device meeting transcription for macOS. Built on Apple Speech, Apple Intelligence, and SwiftUI. No telemetry, no analytics, no audio uploads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Label("All audio is processed on-device.", systemImage: "lock.shield")
                Label("No network calls during recording or analysis.", systemImage: "network.slash")
                Label("Recordings live at ~/Library/Application Support/Scribe.", systemImage: "folder")
                Label("iCloud sync for tasks and notes is off unless you turn it on in Storage & Sync.", systemImage: "icloud")
                Label("PlantUML diagrams are sent to plantuml.com only if you enable it in General.", systemImage: "point.3.connected.trianglepath.dotted")
            }

            Section("Acknowledgements") {
                Text("Built with GRDB, KeyboardShortcuts, Apple SpeechAnalyzer, FoundationModels, and FluidAudio. Speaker separation uses the pyannote community-1 models (CC BY 4.0) converted to Core ML by FluidInference.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(copyright)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shared helpers

/// System-Settings-style toggle with a caption describing what it does.
@ViewBuilder
fileprivate func toggleWithCaption(_ title: String, isOn: Binding<Bool>, caption: String) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        Toggle(title, isOn: isOn)
        Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
