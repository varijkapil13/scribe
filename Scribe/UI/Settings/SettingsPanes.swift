import SwiftUI
import KeyboardShortcuts
import AppKit

/// One of the four settings screens shown in the combined main window. Each
/// pane is a standalone `View`, chosen from the sidebar.
enum SettingsPane: String, CaseIterable, Hashable, Identifiable {
    case general
    case intelligence
    case storage
    case shortcuts
    case mcp
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:      return "General"
        case .intelligence: return "Intelligence"
        case .storage:      return "Storage"
        case .shortcuts:    return "Shortcuts"
        case .mcp:          return "MCP Server"
        case .about:        return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general:      return "gear"
        case .intelligence: return "sparkles"
        case .storage:      return "internaldrive"
        case .shortcuts:    return "keyboard"
        case .mcp:          return "server.rack"
        case .about:        return "info.circle"
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
        case .shortcuts:    ShortcutsSettingsPane()
        case .mcp:          MCPSettingsPane()
        case .about:        AboutSettingsPane()
        }
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @ObservedObject var audioManager: AudioSessionManager

    @AppStorage("selectedMicrophoneID") var selectedMicID: String = ""
    @AppStorage("captureSystemAudio") var captureSystemAudio: Bool = true
    @AppStorage("selectedLanguage") var selectedLanguage: String = "auto"

    var body: some View {
        Form {
            Section("Audio") {
                Picker("Microphone", selection: $selectedMicID) {
                    Text("System Default").tag("")
                    ForEach(audioManager.availableMicrophones(), id: \.id) { mic in
                        Text(mic.name).tag(String(mic.id))
                    }
                }
                toggleWithCaption(
                    "Capture system audio",
                    isOn: $captureSystemAudio,
                    caption: "Record remote participants via ScreenCaptureKit. Requires Screen Recording permission."
                )
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
    }
}

// MARK: - Intelligence

private struct IntelligenceSettingsPane: View {
    @AppStorage("autoSummarize") var autoSummarize: Bool = false
    @AppStorage("autoExtractActions") var autoExtractActions: Bool = false
    @AppStorage("autoAnalyze") var autoAnalyze: Bool = true
    @AppStorage("extractEntities") var extractEntities: Bool = true
    @AppStorage("detectLanguage") var detectLanguage: Bool = true
    @AppStorage("analyzeSentiment") var analyzeSentiment: Bool = true

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Apple Intelligence is available on this Mac")
                        .font(.callout)
                }
            } header: {
                Text("Apple Intelligence")
            } footer: {
                Text("Summaries, action items, and smart search run entirely on-device. No audio or text ever leaves your Mac.")
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
    @AppStorage("retainAudio") var retainAudio: Bool = false
    @AppStorage("storageLocation") var storageLocation: String = ""
    @State private var showDeleteConfirmation: Bool = false

    var body: some View {
        Form {
            Section("Storage") {
                toggleWithCaption(
                    "Retain raw audio recordings",
                    isOn: $retainAudio,
                    caption: "Keep the original audio file alongside the transcript. Disabled by default to save disk space."
                )

                LabeledContent("Location") {
                    HStack {
                        Text(storageLocation.isEmpty ? "Default" : storageLocation)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Change…", action: chooseStorageLocation)
                    }
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
                    Text("This permanently removes every session, segment, summary, and action item. This action cannot be undone.")
                }

                Text("Scribe stores data at ~/Library/Application Support/Scribe/.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
        try? TranscriptStore().deleteAllData()
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettingsPane: View {
    var body: some View {
        Form {
            Section("Global Shortcuts") {
                KeyboardShortcuts.Recorder("Toggle Recording:", name: .toggleRecording)
                Text("Press this shortcut from any app to start or stop recording without opening Scribe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            }

            Section("Acknowledgements") {
                Text("Built with GRDB, KeyboardShortcuts, Apple SpeechAnalyzer, and FoundationModels.")
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

// MARK: - MCP Server

private struct MCPSettingsPane: View {

    @AppStorage("mcpEnabled") var mcpEnabled: Bool = false
    @AppStorage("mcpPort")    var mcpPort: Int = 3333
    @ObservedObject private var server = MCPServer.shared

    var body: some View {
        Form {
            Section {
                toggleWithCaption(
                    "Enable MCP Server",
                    isOn: Binding(
                        get: { mcpEnabled },
                        set: { enabled in
                            mcpEnabled = enabled
                            if enabled { server.start(port: UInt16(mcpPort)) }
                            else       { server.stop() }
                        }
                    ),
                    caption: "Exposes tasks and transcripts to LLM agents via the Model Context Protocol (HTTP+SSE on localhost)."
                )

                if mcpEnabled {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(server.isRunning ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(server.isRunning ? "Running on port \(mcpPort)" : "Starting…")
                                .foregroundStyle(.secondary)
                        }
                    }

                    LabeledContent("Port") {
                        HStack {
                            TextField("", value: $mcpPort, format: .number)
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: mcpPort) { _, newPort in
                                    guard mcpEnabled else { return }
                                    server.stop()
                                    server.start(port: UInt16(newPort))
                                }
                            Text("(1024–65535)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    if let error = server.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }
            } header: {
                Text("MCP Server")
            } footer: {
                Text("Only accessible from localhost. No authentication is required — keep this disabled when not actively using an agent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if mcpEnabled && server.isRunning {
                Section("Connect an Agent") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add this to your MCP client config (e.g. Claude Desktop's `claude_desktop_config.json`):")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(claudeDesktopConfig)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                Section("Available Tools") {
                    ForEach(toolList, id: \.0) { name, desc in
                        LabeledContent(name) {
                            Text(desc)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if mcpEnabled && !server.isRunning {
                server.start(port: UInt16(mcpPort))
            }
        }
    }

    private var claudeDesktopConfig: String {
        """
        {
          "mcpServers": {
            "scribe": {
              "url": "http://127.0.0.1:\(mcpPort)/sse"
            }
          }
        }
        """
    }

    private var toolList: [(String, String)] {
        [
            ("create_task",       "Create a task with title, notes, due date, priority"),
            ("list_tasks",        "List tasks by filter (today, inbox, all, …)"),
            ("search_tasks",      "Full-text search across tasks"),
            ("update_task",       "Update title, notes, due date, priority, or completion"),
            ("delete_task",       "Delete a task by ID"),
            ("list_transcripts",  "List recent recording sessions"),
            ("get_transcript",    "Get full transcript text and action items"),
        ]
    }
}

// MARK: - Shared helpers

/// System-Settings-style toggle with a caption describing what it does.
@ViewBuilder
fileprivate func toggleWithCaption(_ title: String, isOn: Binding<Bool>, caption: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Toggle(title, isOn: isOn)
        Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
