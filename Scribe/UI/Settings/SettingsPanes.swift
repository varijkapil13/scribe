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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:      return "General"
        case .intelligence: return "Intelligence"
        case .storage:      return "Storage"
        case .shortcuts:    return "Shortcuts"
        }
    }

    var systemImage: String {
        switch self {
        case .general:      return "gear"
        case .intelligence: return "sparkles"
        case .storage:      return "internaldrive"
        case .shortcuts:    return "keyboard"
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
        HStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: pane.systemImage)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            Text(pane.title)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
            Spacer()
        }
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
        }
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @ObservedObject var audioManager: AudioSessionManager

    @AppStorage("selectedMicrophoneID") var selectedMicID: String = ""
    @AppStorage("captureSystemAudio") var captureSystemAudio: Bool = true
    @AppStorage("selectedLanguage") var selectedLanguage: String = "auto"
    @AppStorage("showOverlayOnRecord") var showOverlay: Bool = true
    @AppStorage("alwaysOnTop") var alwaysOnTop: Bool = true

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

            Section("Overlay") {
                toggleWithCaption(
                    "Show overlay when recording starts",
                    isOn: $showOverlay,
                    caption: "Display a floating window with the live transcript during recording."
                )
                toggleWithCaption(
                    "Keep overlay on top",
                    isOn: $alwaysOnTop,
                    caption: "Overlay stays above all other windows so you can see it during video calls."
                )
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
