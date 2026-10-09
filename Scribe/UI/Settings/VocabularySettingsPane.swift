import SwiftUI
import AppKit

/// Settings → Vocabulary: the custom vocabulary / personal dictionary and the
/// default speaker name for "you".
struct VocabularySettingsPane: View {
    @ObservedObject private var vocabulary: VocabularyStore = .shared
    @AppStorage(SpeakerNamePreferences.defaultYouNameKey) private var youName: String = ""

    @State private var newTerm = ""
    @State private var newHeardAs = ""

    private var canAdd: Bool {
        !newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section("Add a word") {
                TextField("Correct spelling", text: $newTerm, prompt: Text("e.g. Kubernetes, Priya, kubectl"))
                    .onSubmit(add)
                TextField("Heard as (optional)", text: $newHeardAs, prompt: Text("e.g. cube control"))
                    .onSubmit(add)
                HStack {
                    Text("Words help the transcriber spell names and jargon. With \"Heard as\", that phrase is also replaced in new transcripts and dictation (whole words, any case).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Add", action: add)
                        .disabled(!canAdd)
                }
            }

            Section("Vocabulary (\(vocabulary.entries.count))") {
                if vocabulary.entries.isEmpty {
                    Text("No words yet. Add some above, or right-click a transcript segment and choose Add to Vocabulary.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vocabulary.entries) { entry in
                        HStack {
                            if let heard = entry.heardAs {
                                Text(heard).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .accessibilityLabel("becomes")
                            }
                            Text(entry.term).fontWeight(.medium)
                            Spacer()
                            Button {
                                vocabulary.remove(entry)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                            .accessibilityLabel("Remove \(entry.term)")
                        }
                    }
                }
                if let error = vocabulary.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                HStack {
                    Button("Open File") {
                        ensureFileExists()
                        NSWorkspace.shared.open(vocabulary.fileURL)
                    }
                    Button("Reveal in Finder") {
                        ensureFileExists()
                        NSWorkspace.shared.activateFileViewerSelecting([vocabulary.fileURL])
                    }
                    Button("Reload") { vocabulary.reload() }
                    Spacer()
                }
                Text("Stored as Markdown at \(vocabulary.fileURL.path). Changes apply to the next recording or dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Speakers") {
                TextField("Your name", text: $youName,
                          prompt: Text(SpeakerNamePreferences.systemFullName() ?? "You"))
                Text("Used for your microphone in transcripts, exports and hooks. Rename the remote side per transcript with the Speakers button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { vocabulary.reload() }
    }

    private func add() {
        guard canAdd else { return }
        if vocabulary.add(term: newTerm, heardAs: newHeardAs) {
            newTerm = ""
            newHeardAs = ""
        }
    }

    /// Writes an empty vocabulary file so Open / Reveal have something to show.
    private func ensureFileExists() {
        guard !FileManager.default.fileExists(atPath: vocabulary.fileURL.path) else { return }
        try? FileManager.default.createDirectory(
            at: vocabulary.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? VocabularyFile.serialize([]).write(to: vocabulary.fileURL, atomically: true, encoding: .utf8)
    }
}
