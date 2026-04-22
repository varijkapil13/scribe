import SwiftUI
import KeyboardShortcuts
import AppKit

/// App-wide settings view presented as a tabbed window.
///
/// Styled to match macOS System Settings: each toggle is followed by a
/// short caption describing what it does, and sections are clearly grouped.
struct SettingsView: View {

    @ObservedObject var audioManager: AudioSessionManager

    @AppStorage("selectedMicrophoneID") var selectedMicID: String = ""
    @AppStorage("captureSystemAudio") var captureSystemAudio: Bool = true
    @AppStorage("selectedLanguage") var selectedLanguage: String = "auto"
    @AppStorage("showOverlayOnRecord") var showOverlay: Bool = true
    @AppStorage("alwaysOnTop") var alwaysOnTop: Bool = true
    @AppStorage("retainAudio") var retainAudio: Bool = false
    @AppStorage("storageLocation") var storageLocation: String = ""
    @AppStorage("autoSummarize") var autoSummarize: Bool = false
    @AppStorage("autoExtractActions") var autoExtractActions: Bool = false
    @AppStorage("autoAnalyze") var autoAnalyze: Bool = true
    @AppStorage("extractEntities") var extractEntities: Bool = true
    @AppStorage("detectLanguage") var detectLanguage: Bool = true
    @AppStorage("analyzeSentiment") var analyzeSentiment: Bool = true

    @State private var showDeleteConfirmation: Bool = false

    private let supportedLanguages: [String: String] = [
        "auto": "Auto-detect",
        "en": "English",
        "de": "German",
        "fr": "French",
        "es": "Spanish",
        "it": "Italian",
        "pt": "Portuguese",
        "nl": "Dutch",
        "ja": "Japanese",
        "zh": "Chinese",
        "ko": "Korean"
    ]

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            intelligenceTab
                .tabItem { Label("Intelligence", systemImage: "sparkles") }
            storageTab
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 540, height: 460)
    }

    // MARK: - General Tab

    private var generalTab: some View {
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
                    ForEach(sortedLanguageKeys, id: \.self) { key in
                        Text(supportedLanguages[key] ?? key).tag(key)
                    }
                }
                Text("Powered by Apple Speech — on-device recognition with no model downloads required.")
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

    // MARK: - Intelligence Tab

    private var intelligenceTab: some View {
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

            Section {
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
            } header: {
                Text("Transcript Analysis")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Storage Tab

    private var storageTab: some View {
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
                        Button("Change…") {
                            chooseStorageLocation()
                        }
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
                    Button("Delete All Data", role: .destructive) {
                        deleteAllData()
                    }
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

    // MARK: - Shortcuts Tab

    private var shortcutsTab: some View {
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

    // MARK: - Components

    /// A toggle styled like System Settings: leading title, trailing switch,
    /// and a muted caption below explaining what the setting does.
    @ViewBuilder
    private func toggleWithCaption(_ title: String, isOn: Binding<Bool>, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Private Helpers

    private var sortedLanguageKeys: [String] {
        var keys = Array(supportedLanguages.keys)
        keys.sort { lhs, rhs in
            if lhs == "auto" { return true }
            if rhs == "auto" { return false }
            return (supportedLanguages[lhs] ?? lhs) < (supportedLanguages[rhs] ?? rhs)
        }
        return keys
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
        let store = TranscriptStore()
        try? store.deleteAllData()
    }
}
