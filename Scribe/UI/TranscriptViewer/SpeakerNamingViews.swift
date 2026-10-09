import SwiftUI

// MARK: - Speakers button + rename sheet

/// "Speakers" action-bar button: opens a sheet to rename this session's
/// speakers (e.g. "Remote" → "Priya").
struct SpeakersButton: View {
    @ObservedObject var viewModel: TranscriptDetailViewModel
    @State private var showSheet = false

    var body: some View {
        Button { showSheet = true } label: {
            Label("Speakers", systemImage: "person.2")
        }
        .help("Name the speakers in this transcript")
        .sheet(isPresented: $showSheet) {
            SpeakerNamesSheet(viewModel: viewModel) { showSheet = false }
        }
    }
}

/// Edits per-session speaker names. Empty fields fall back to the default
/// ("You" uses the name from Settings → Vocabulary).
struct SpeakerNamesSheet: View {
    @ObservedObject var viewModel: TranscriptDetailViewModel
    let onDismiss: () -> Void

    @State private var drafts: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Speakers")
                    .font(.system(.title3, weight: .semibold))
                Text("Names apply to this transcript, its exports and post-meeting hooks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                ForEach(viewModel.speakerKeys, id: \.self) { key in
                    LabeledContent {
                        TextField(
                            "Name",
                            text: binding(for: key),
                            prompt: Text(defaultName(for: key))
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    } label: {
                        Label(sourceLabel(for: key), systemImage: SpeakerGlyph.symbol(for: key))
                    }
                }
            }
            .formStyle(.grouped)

            Text("Scribe can't yet tell several remote people apart automatically. To split them, select segments and use Assign Speaker.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Save") {
                    save()
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 480)
        .frame(minHeight: 320)
        .onAppear { drafts = viewModel.speakerResolver.sessionNames }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { drafts[key] ?? "" },
            set: { drafts[key] = $0 }
        )
    }

    private func defaultName(for key: String) -> String {
        var resolver = viewModel.speakerResolver
        resolver.sessionNames = [:]
        return resolver.displayName(forKey: key)
    }

    private func sourceLabel(for key: String) -> String {
        switch key {
        case SpeakerNameResolver.youKey:    return "Microphone"
        case SpeakerNameResolver.remoteKey: return "System audio"
        default:                            return "Added speaker"
        }
    }

    private func save() {
        let original = viewModel.speakerResolver.sessionNames
        for key in viewModel.speakerKeys {
            let new = (drafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let old = (original[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard new != old else { continue }
            // Clearing an added speaker's name would orphan it; keep its key
            // as the name instead.
            if new.isEmpty, key != SpeakerNameResolver.youKey, key != SpeakerNameResolver.remoteKey {
                viewModel.renameSpeaker(key: key, to: key)
            } else {
                viewModel.renameSpeaker(key: key, to: new)
            }
        }
    }
}

// MARK: - Assign speaker menu (selection mode)

/// Selection-mode menu that reassigns the selected segments to a speaker.
struct AssignSpeakerMenu: View {
    @ObservedObject var viewModel: TranscriptDetailViewModel
    @State private var showNewSpeaker = false
    @State private var newSpeakerName = ""

    var body: some View {
        Menu {
            ForEach(viewModel.speakerKeys, id: \.self) { key in
                Button(viewModel.speakerResolver.displayName(forKey: key)) {
                    viewModel.assignSelectedSegments(toSpeakerKey: key)
                }
            }
            Divider()
            Button("New Speaker…") {
                newSpeakerName = ""
                showNewSpeaker = true
            }
            Button("Restore Original Speaker") {
                viewModel.assignSelectedSegments(toSpeakerKey: nil)
            }
        } label: {
            Label("Assign Speaker", systemImage: "person.crop.circle.badge.checkmark")
        }
        .fixedSize()
        .disabled(viewModel.selectedSegmentIds.isEmpty)
        .help("Attribute the selected segments to a speaker")
        .alert("New Speaker", isPresented: $showNewSpeaker) {
            TextField("Name", text: $newSpeakerName)
            Button("Assign") {
                viewModel.assignSelectedSegments(toNewSpeakerNamed: newSpeakerName)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected segments will be attributed to this person.")
        }
    }
}

// MARK: - Add to vocabulary

/// Adds a term (optionally with a "heard as" correction) to the custom
/// vocabulary, starting from a transcript segment's words.
struct AddToVocabularySheet: View {
    let segmentText: String

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var vocabulary: VocabularyStore = .shared

    @State private var term = ""
    @State private var heardAs = ""
    @State private var fillTarget: FillTarget = .heardAs

    enum FillTarget: String, CaseIterable, Identifiable {
        case heardAs = "Heard as"
        case term = "Correct spelling"
        var id: String { rawValue }
    }

    private var words: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for token in segmentText.split(whereSeparator: { $0.isWhitespace }) {
            let word = token.trimmingCharacters(in: .punctuationCharacters)
            guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { continue }
            out.append(word)
            if out.count >= 80 { break }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            Text("Add to Vocabulary")
                .font(.system(.title3, weight: .semibold))

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Picker("Tapping a word fills", selection: $fillTarget) {
                    ForEach(FillTarget.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                ScrollView {
                    FlowLayoutView(items: words) { word in
                        Button(word) { append(word) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }

            Form {
                TextField("Correct spelling", text: $term, prompt: Text("e.g. kubectl"))
                TextField("Heard as (optional)", text: $heardAs, prompt: Text("e.g. cube control"))
            }
            .formStyle(.grouped)

            Text("The spelling is suggested to the transcriber. If you also fill \"Heard as\", that phrase is replaced in future transcripts and dictation.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Add") {
                    vocabulary.add(term: term, heardAs: heardAs)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 520)
    }

    private func append(_ word: String) {
        switch fillTarget {
        case .heardAs: heardAs = heardAs.isEmpty ? word : heardAs + " " + word
        case .term:    term = term.isEmpty ? word : term + " " + word
        }
    }
}
