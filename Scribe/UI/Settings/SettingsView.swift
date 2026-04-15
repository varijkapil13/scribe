import SwiftUI
import KeyboardShortcuts
#if canImport(AppKit)
import AppKit
#endif
import CoreAudio

/// App-wide settings view presented as a tabbed window.
struct SettingsView: View {

    @ObservedObject var audioManager: AudioSessionManager
    @ObservedObject var modelManager: ModelManager

    @AppStorage("selectedMicrophoneID") var selectedMicID: String = ""
    @AppStorage("captureSystemAudio") var captureSystemAudio: Bool = true
    @AppStorage("selectedLanguage") var selectedLanguage: String = "auto"
    @AppStorage("showOverlayOnRecord") var showOverlay: Bool = true
    @AppStorage("alwaysOnTop") var alwaysOnTop: Bool = true
    @AppStorage("retainAudio") var retainAudio: Bool = false
    @AppStorage("storageLocation") var storageLocation: String = ""
    @AppStorage("transcriptionEngine") var transcriptionEngine: String = "whisper"
    @AppStorage("autoSummarize") var autoSummarize: Bool = false
    @AppStorage("autoExtractActions") var autoExtractActions: Bool = false
    @AppStorage("autoAnalyze") var autoAnalyze: Bool = true
    @AppStorage("extractEntities") var extractEntities: Bool = true
    @AppStorage("detectLanguage") var detectLanguage: Bool = true
    @AppStorage("analyzeSentiment") var analyzeSentiment: Bool = true

    @State private var showDeleteConfirmation: Bool = false

    let supportedLanguages: [String: String] = [
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
            modelsTab
                .tabItem { Label("Models", systemImage: "cpu") }
            storageTab
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            intelligenceTab
                .tabItem { Label("Intelligence", systemImage: "sparkles") }
        }
        .frame(width: 500, height: 450)
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

                Toggle("Capture system audio", isOn: $captureSystemAudio)
            }

            Section("Transcription") {
                Picker("Language", selection: $selectedLanguage) {
                    ForEach(sortedLanguageKeys, id: \.self) { key in
                        Text(supportedLanguages[key] ?? key).tag(key)
                    }
                }

                Picker("Transcription Engine", selection: $transcriptionEngine) {
                    Text("Whisper (whisper.cpp)").tag("whisper")
                    Text("Apple Speech (on-device)").tag("apple")
                }
                if transcriptionEngine == "apple" {
                    Text("Uses Apple's built-in speech recognition. No model download needed.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text("Uses whisper.cpp with downloadable models. Better accuracy for multilingual audio.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            Section("Interface") {
                Toggle("Show overlay when recording starts", isOn: $showOverlay)
                Toggle("Overlay always on top", isOn: $alwaysOnTop)
            }
        }
    }

    // MARK: - Models Tab

    private var modelsTab: some View {
        Form {
            Section("Whisper Models") {
                ForEach(modelManager.availableModels) { model in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.displayName)
                                .font(.headline)
                            Text(model.estimatedSize)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if modelManager.isModelDownloaded(model) {
                            if modelManager.selectedModel == model {
                                Text("Active")
                                    .foregroundColor(.green)
                            } else {
                                Button("Select") {
                                    modelManager.selectedModel = model
                                }
                            }
                            Button("Delete") {
                                try? modelManager.deleteModel(model)
                            }
                            .foregroundColor(.red)
                        } else if modelManager.isDownloading {
                            ProgressView(value: modelManager.downloadProgress)
                                .frame(width: 100)
                        } else {
                            Button("Download") {
                                Task {
                                    try? await modelManager.downloadModel(model)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Storage Tab

    private var storageTab: some View {
        Form {
            Section("Storage") {
                Toggle("Retain raw audio recordings", isOn: $retainAudio)

                LabeledContent("Location") {
                    HStack {
                        Text(storageLocation.isEmpty ? "Default" : storageLocation)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change...") {
                            chooseStorageLocation()
                        }
                    }
                }
            }

            Section("Data") {
                Button("Delete All Data...", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .confirmationDialog(
                    "Are you sure you want to delete all transcription data? This action cannot be undone.",
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete All Data", role: .destructive) {
                        deleteAllData()
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
    }

    // MARK: - Shortcuts Tab

    private var shortcutsTab: some View {
        Form {
            Section("Keyboard Shortcuts") {
                Text("Configure global keyboard shortcut for Start/Stop Recording")
                    .foregroundColor(.secondary)
                // KeyboardShortcuts.Recorder("Toggle Recording:", name: .toggleRecording)
            }
        }
    }

    // MARK: - Intelligence Tab

    private var intelligenceTab: some View {
        Form {
            Section("Apple Intelligence") {
                // Show availability status
                HStack {
                    Image(systemName: MeetingSummarizer.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(MeetingSummarizer.isAvailable ? .green : .red)
                    Text(MeetingSummarizer.isAvailable ? "Available on this Mac" : "Requires macOS 26+ with Apple Silicon")
                }

                if MeetingSummarizer.isAvailable {
                    Toggle("Auto-summarize after recording", isOn: $autoSummarize)
                    Toggle("Auto-extract action items", isOn: $autoExtractActions)
                }
            }

            Section("Transcript Analysis") {
                Text("NaturalLanguage framework features work on macOS 13+")
                    .font(.caption).foregroundColor(.secondary)
                Toggle("Auto-analyze transcripts", isOn: $autoAnalyze)
                Toggle("Extract entities (people, places, orgs)", isOn: $extractEntities)
                Toggle("Detect language", isOn: $detectLanguage)
                Toggle("Analyze sentiment", isOn: $analyzeSentiment)
            }

            Section("Apple Speech Recognition") {
                // Show SFSpeechRecognizer availability
                HStack {
                    Text("On-device speech recognition")
                    Spacer()
                    Text("Available").foregroundColor(.green).font(.caption)
                }
                Text("Select 'Apple Speech' as the transcription engine in the General tab to use this feature.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Private Helpers

    /// Returns language keys sorted so "auto" comes first, then alphabetical
    /// by display name.
    private var sortedLanguageKeys: [String] {
        var keys = Array(supportedLanguages.keys)
        keys.sort { lhs, rhs in
            if lhs == "auto" { return true }
            if rhs == "auto" { return false }
            return (supportedLanguages[lhs] ?? lhs) < (supportedLanguages[rhs] ?? rhs)
        }
        return keys
    }

    /// Presents an NSOpenPanel for the user to choose a storage directory.
    private func chooseStorageLocation() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        storageLocation = url.path
        #endif
    }

    /// Deletes all transcription data from the store.
    private func deleteAllData() {
        let store = TranscriptStore()
        try? store.deleteAllData()
    }
}
