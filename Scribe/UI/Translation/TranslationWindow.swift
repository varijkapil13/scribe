// Scribe/UI/Translation/TranslationWindow.swift
import SwiftUI
import Translation

/// What the Translate window was opened for.
struct ScribeTranslationRequest: Codable, Hashable, Identifiable {
    enum Source: String, Codable, Hashable {
        case note
        case transcript
    }

    var noteId: String
    var source: Source

    var id: String { "\(source.rawValue):\(noteId)" }

    static let windowID = "translate"
}

/// File › Translate Note… / Translate Transcript…: translates a note's text
/// or one of its transcripts on-device and saves the result as a NEW note
/// ("Title (German)") linking back to the original. The original note and
/// transcript are never modified.
@MainActor
struct TranslationWindowView: View {
    let request: ScribeTranslationRequest

    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var model: TranslationWindowModel

    init(request: ScribeTranslationRequest) {
        self.request = request
        _model = StateObject(wrappedValue: TranslationWindowModel(request: request))
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Note", value: model.noteTitle)
                Picker("Translate", selection: $model.source) {
                    Text("Note text").tag(ScribeTranslationRequest.Source.note)
                    Text("Transcript").tag(ScribeTranslationRequest.Source.transcript)
                }
                .pickerStyle(.segmented)
                if model.source == .transcript {
                    if model.sessions.isEmpty {
                        Text("This note has no recordings.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Recording", selection: $model.selectedSessionId) {
                            ForEach(model.sessions) { session in
                                Text(TranslationWindowModel.label(for: session)).tag(Optional(session.id))
                            }
                        }
                    }
                }
                Picker("Into", selection: $model.targetIdentifier) {
                    if model.languages.isEmpty {
                        Text("Loading languages…").tag(model.targetIdentifier)
                    }
                    ForEach(model.languages, id: \.minimalIdentifier) { language in
                        Text(ScribeTranslationRunner.displayName(for: language)).tag(language.minimalIdentifier)
                    }
                }
            } footer: {
                Text("Translation runs on your Mac with Apple’s Translation framework (macOS may ask to download the language first). The result is saved as a new note; the original stays unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let progress = model.progress {
                ProgressView(value: progress) {
                    Text("Translating…")
                }
            }
            if let message = model.errorMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 300)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismissWindow() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Translate") { model.start() }
                    .disabled(!model.canStart)
            }
        }
        .navigationTitle("Translate")
        .task(id: request) { await model.load() }
        .modifier(ScribeTranslationHost(
            configuration: model.configuration,
            texts: model.pendingTexts,
            onProgress: { [model = self.model] fraction in model.progress = fraction },
            onFinish: { [model = self.model] outcome in model.finish(outcome) }
        ))
        .onChange(of: model.savedNoteId) { _, saved in
            if saved != nil { dismissWindow() }
        }
    }
}

/// State and actions of the Translate window.
@MainActor
final class TranslationWindowModel: ObservableObject {
    let request: ScribeTranslationRequest

    @Published var source: ScribeTranslationRequest.Source
    @Published private(set) var note: Note?
    @Published private(set) var sessions: [Session] = []
    @Published var selectedSessionId: String?
    @Published private(set) var languages: [Locale.Language] = []
    @Published var targetIdentifier: String {
        didSet { UserDefaults.standard.set(targetIdentifier, forKey: Self.targetDefaultsKey) }
    }

    @Published private(set) var configuration: TranslationSession.Configuration?
    @Published private(set) var pendingTexts: [String] = []
    @Published var progress: Double?
    @Published private(set) var errorMessage: String?
    /// Set once the translation was saved; the window closes.
    @Published private(set) var savedNoteId: String?

    private var pendingJob: PendingJob?

    /// What the running translation will turn into once it finishes.
    private enum PendingJob {
        case note(plan: MarkdownTranslationPlan, languageName: String)
        case transcript(lines: [TranscriptTranslationLine], sessionTitle: String, languageName: String)
    }

    nonisolated static let targetDefaultsKey = "translationTargetLanguage"

    init(request: ScribeTranslationRequest) {
        self.request = request
        self.source = request.source
        self.targetIdentifier = UserDefaults.standard.string(forKey: Self.targetDefaultsKey) ?? ""
    }

    var noteTitle: String {
        guard let note else { return "…" }
        return note.title.isEmpty ? "Untitled" : note.title
    }

    var targetLanguage: Locale.Language? {
        languages.first { $0.minimalIdentifier == targetIdentifier }
    }

    var canStart: Bool {
        guard note != nil, targetLanguage != nil, progress == nil else { return false }
        if source == .transcript { return selectedSessionId != nil && !sessions.isEmpty }
        return true
    }

    static func label(for session: Session) -> String {
        let date = session.createdAt.formatted(date: .abbreviated, time: .shortened)
        return session.title.isEmpty ? date : "\(session.title) — \(date)"
    }

    func load() async {
        note = try? NoteStore.shared.fetchNote(id: request.noteId)
        sessions = (try? TranscriptStore.shared.fetchSessions(forNoteId: request.noteId)) ?? []
        selectedSessionId = sessions.first?.id
        languages = await ScribeTranslationRunner.supportedLanguages()
        if targetLanguage == nil {
            let preferred = Locale.current.language.minimalIdentifier
            targetIdentifier = languages.first { $0.minimalIdentifier == preferred }?.minimalIdentifier
                ?? languages.first?.minimalIdentifier ?? ""
        }
    }

    func start() {
        guard let note, let target = targetLanguage, canStart else { return }
        errorMessage = nil
        let languageName = ScribeTranslationRunner.displayName(for: target)
        switch source {
        case .note:
            let plan = MarkdownTranslationPlan(markdown: note.body)
            guard !plan.texts.isEmpty else {
                errorMessage = "This note has no text to translate."
                return
            }
            pendingJob = .note(plan: plan, languageName: languageName)
            pendingTexts = plan.texts
        case .transcript:
            guard let sessionId = selectedSessionId,
                  let session = sessions.first(where: { $0.id == sessionId }) else { return }
            let segments = (try? TranscriptStore.shared.fetchSegments(sessionId: sessionId)) ?? []
            let resolver = TranscriptStore.shared.speakerResolver(sessionId: sessionId)
            let lines = segments.compactMap { segment -> TranscriptTranslationLine? in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptTranslationLine(speaker: resolver.displayName(for: segment),
                                                 timestamp: segment.formattedTimestamp,
                                                 text: text)
            }
            guard !lines.isEmpty else {
                errorMessage = "This recording has no transcript to translate."
                return
            }
            pendingJob = .transcript(lines: lines, sessionTitle: session.title, languageName: languageName)
            pendingTexts = lines.map(\.text)
        }
        progress = 0
        // A new configuration (or invalidating an equal one) runs the task.
        if configuration?.target == target {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: nil, target: target)
        }
    }

    func finish(_ outcome: ScribeTranslationOutcome) {
        defer {
            progress = nil
            pendingJob = nil
        }
        guard let note, let job = pendingJob else { return }
        switch outcome {
        case .failed(let message):
            errorMessage = "Couldn’t translate: \(message)"
        case .finished(let translations):
            let title: String
            let body: String
            switch job {
            case .note(let plan, let languageName):
                title = ScribeTranslationOutput.noteTitle(original: note.title, languageName: languageName)
                body = ScribeTranslationOutput.noteBody(originalTitle: note.title, languageName: languageName,
                                                  translatedMarkdown: plan.render(translations: translations))
            case .transcript(let lines, let sessionTitle, let languageName):
                title = ScribeTranslationOutput.noteTitle(original: note.title.isEmpty ? sessionTitle : note.title,
                                                    languageName: languageName)
                body = ScribeTranslationOutput.transcriptBody(originalTitle: note.title, sessionTitle: sessionTitle,
                                                        languageName: languageName, lines: lines,
                                                        translations: translations)
            }
            do {
                let created = try NoteStore.shared.createNote(title: title, body: body, notebookId: note.notebookId)
                NotificationCenter.default.post(name: .scribeNavigate, object: MainSelection.note(created.id))
                AppState.shared.notify("Saved translation as “\(title)”")
                savedNoteId = created.id
            } catch {
                errorMessage = "Couldn’t save the translation: \(error.localizedDescription)"
            }
        }
    }
}
