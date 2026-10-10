import Foundation
import Combine

extension Notification.Name {
    /// Posted (object: note id) after a Scribe-generated edit was written to a
    /// note's file. userInfo: `NoteAIEdit.userInfoKey` → `NoteAIEdit`. An open
    /// `NoteDetailView` replays the same pure edit on its in-memory body so
    /// unsaved typing isn't lost and the next autosave doesn't revert it.
    static let scribeNoteAIEditApplied = Notification.Name("scribe.noteAIEditApplied")
}

/// A pure, replayable edit to a note body.
enum NoteAIEdit: Sendable, Equatable {
    /// Insert/replace the template-summary block for a session.
    case upsertSummary(sessionId: String, markdown: String)
    /// Append a `## heading` section at the end of the note.
    case appendSection(heading: String, markdown: String)
    /// Append plain text at the end of the note (Shortcuts "Append to Note").
    case appendText(String)

    static let userInfoKey = "edit"

    func apply(to body: String) -> String {
        switch self {
        case .upsertSummary(let sessionId, let markdown):
            return NoteScribeBlocks.upsertSummary(body: body, sessionId: sessionId, content: markdown)
        case .appendSection(let heading, let markdown):
            return NoteScribeBlocks.appendSection(body: body, heading: heading, content: markdown)
        case .appendText(let text):
            return ScribeIntentsText.append(text, to: body)
        }
    }
}

/// Writes Scribe-generated content into a note on disk (via `NoteStore`, so
/// the index + FTS stay current) and notifies any open editor.
@MainActor
enum NoteAIEditWriter {
    static func apply(_ edit: NoteAIEdit, toNoteId noteId: String, noteStore: NoteStore = .shared) throws {
        guard var note = try noteStore.fetchNote(id: noteId) else { return }
        // Never write into a locked note's ciphertext.
        guard !LockedNoteEnvelope.isLocked(note.body) else { return }
        let updated = edit.apply(to: note.body)
        if updated != note.body {
            note.body = updated
            let tags = try noteStore.tags(for: noteId)
            try noteStore.updateNote(note, tags: tags)
        }
        NotificationCenter.default.post(
            name: .scribeNoteAIEditApplied,
            object: noteId,
            userInfo: [NoteAIEdit.userInfoKey: edit]
        )
    }
}

/// Typed segment tuples the summarizer APIs take.
enum NoteAISegments {
    static func tuples(_ segments: [Segment]) -> [(speaker: String, text: String, timestamp: String)] {
        segments.map { (speaker: $0.speaker, text: $0.text, timestamp: $0.formattedTimestamp) }
    }

    /// Segments of several sessions in recording order, each session
    /// introduced by a header line so the model knows they're separate.
    static func combined(
        sessions: [Session],
        transcriptStore: TranscriptStore
    ) -> [(speaker: String, text: String, timestamp: String)] {
        let ordered = sessions.sorted { $0.createdAt < $1.createdAt }
        var out: [(speaker: String, text: String, timestamp: String)] = []
        for session in ordered {
            let segments = (try? transcriptStore.fetchSegments(sessionId: session.id)) ?? []
            guard !segments.isEmpty else { continue }
            if ordered.count > 1 {
                out.append((speaker: "", text: "— Recording: \(session.title) —", timestamp: ""))
            }
            out.append(contentsOf: tuples(segments))
        }
        return out
    }
}

/// Automatic template summary after a recording stops (gated by
/// `TemplateSettings.useForAutoSummary`). Called from `AppState.stopSession`.
@MainActor
enum TemplateAutoSummary {
    static func runIfEnabled(
        sessionId: String,
        title: String,
        segments: [(speaker: String, text: String, timestamp: String)],
        transcriptStore: TranscriptStore,
        noteStore: NoteStore = .shared
    ) async {
        guard TemplateSettings.useForAutoSummary, !segments.isEmpty else { return }
        guard let session = try? transcriptStore.fetchSession(id: sessionId),
              let noteId = session.noteId,
              let store = SummaryTemplateStore.current() else { return }
        let noteTitle = (try? noteStore.fetchNote(id: noteId))?.title ?? ""
        guard let template = TemplateSelector.select(
            from: store.listTemplates(),
            titles: [title, noteTitle],
            defaultId: TemplateSettings.defaultTemplateId,
            autoPick: TemplateSettings.autoPick
        ) else { return }
        do {
            let markdown = try await MeetingSummarizer.renderSummary(
                template: template,
                title: title,
                segments: segments
            )
            try NoteAIEditWriter.apply(.upsertSummary(sessionId: sessionId, markdown: markdown), toNoteId: noteId)
            Log.intelligence.info("Template auto-summary written (template \(template.id, privacy: .public))")
        } catch {
            Log.intelligence.error("Template auto-summary failed: \(error.localizedDescription)")
        }
    }
}

/// Drives the template / enhance / recipe actions for one view. Owns the
/// busy + error state and the latest result for preview sheets.
@MainActor
final class NoteAIController: ObservableObject {

    struct RecipeResult: Identifiable, Equatable {
        let id = UUID()
        let recipe: NoteRecipe
        let markdown: String
        /// Note the result can be inserted into, if any.
        let noteId: String?
    }

    struct EnhanceResult: Identifiable, Equatable {
        let id = UUID()
        /// The user's notes the enhancement was generated from (to detect edits
        /// made while generating).
        let originalUserNotes: String
        let enhanced: String
    }

    @Published private(set) var templates: [SummaryTemplate] = []
    @Published private(set) var recipes: [NoteRecipe] = []
    @Published private(set) var busyLabel: String?
    @Published var errorMessage: String?
    @Published var lastSuccess: String?
    @Published var recipeResult: RecipeResult?
    @Published var enhanceResult: EnhanceResult?
    /// Template summary shown in a sheet when the session has no note.
    @Published var standaloneSummary: RecipeResult?

    private let transcriptStore: TranscriptStore
    private let noteStore: NoteStore

    init(transcriptStore: TranscriptStore = .shared, noteStore: NoteStore = .shared) {
        self.transcriptStore = transcriptStore
        self.noteStore = noteStore
    }

    var isBusy: Bool { busyLabel != nil }

    func reloadLists() {
        guard let store = SummaryTemplateStore.current() else {
            templates = SummaryTemplateStore.sorted(BuiltInTemplates.summaries)
            recipes = BuiltInTemplates.recipes
            return
        }
        templates = store.listTemplates()
        recipes = store.listRecipes()
    }

    /// The template auto-selection would pick for `session`.
    func suggestedTemplate(for session: Session) -> SummaryTemplate? {
        let noteTitle = session.noteId.flatMap { try? noteStore.fetchNote(id: $0) }?.title ?? ""
        return TemplateSelector.select(
            from: templates,
            titles: [session.title, noteTitle],
            defaultId: TemplateSettings.defaultTemplateId,
            autoPick: TemplateSettings.autoPick
        )
    }

    // MARK: - Re-summarize

    /// Renders `template` for `session` and stores it as the session's summary
    /// block in its note (or shows it in a sheet when unbound).
    func resummarize(session: Session, template: SummaryTemplate) async {
        guard !isBusy else { return }
        let segments = (try? transcriptStore.fetchSegments(sessionId: session.id)) ?? []
        guard !segments.isEmpty else {
            errorMessage = "This recording has no transcript yet."
            return
        }
        busyLabel = "Summarizing with \(template.name)…"
        errorMessage = nil
        lastSuccess = nil
        defer { busyLabel = nil }
        do {
            let markdown = try await MeetingSummarizer.renderSummary(
                template: template,
                title: session.title,
                segments: NoteAISegments.tuples(segments)
            )
            if let noteId = session.noteId {
                try NoteAIEditWriter.apply(.upsertSummary(sessionId: session.id, markdown: markdown),
                                           toNoteId: noteId, noteStore: noteStore)
                lastSuccess = "\(template.name) summary added to the note."
            } else {
                standaloneSummary = RecipeResult(
                    recipe: NoteRecipe(id: template.id, name: template.name, description: "", prompt: ""),
                    markdown: markdown,
                    noteId: nil
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            Log.intelligence.error("Re-summarize failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Recipes

    /// Runs `recipe` against the given sessions' transcripts + `noteBody`.
    func run(recipe: NoteRecipe, title: String, sessions: [Session], noteBody: String, noteId: String?) async {
        guard !isBusy else { return }
        let segments = NoteAISegments.combined(sessions: sessions, transcriptStore: transcriptStore)
        let userNotes = NoteScribeBlocks.userContent(body: noteBody)
        guard !segments.isEmpty || !userNotes.isEmpty else {
            errorMessage = "Nothing to run the recipe on yet."
            return
        }
        busyLabel = "Running \(recipe.name)…"
        errorMessage = nil
        lastSuccess = nil
        defer { busyLabel = nil }
        do {
            let markdown = try await MeetingSummarizer.runRecipe(
                recipe,
                title: title,
                noteBody: userNotes,
                segments: segments
            )
            recipeResult = RecipeResult(recipe: recipe, markdown: markdown, noteId: noteId)
        } catch {
            errorMessage = error.localizedDescription
            Log.intelligence.error("Recipe failed: \(error.localizedDescription)")
        }
    }

    /// Note body for a recipe run from a session view (the bound note's body).
    func noteBody(for session: Session) -> String {
        guard let noteId = session.noteId,
              let note = try? noteStore.fetchNote(id: noteId) else { return "" }
        return note.body
    }

    /// Appends a recipe result to its note on disk (used outside the note
    /// editor; the editor appends to its in-memory body instead).
    func insertIntoNote(_ result: RecipeResult) {
        guard let noteId = result.noteId else { return }
        do {
            try NoteAIEditWriter.apply(.appendSection(heading: result.recipe.name, markdown: result.markdown),
                                       toNoteId: noteId, noteStore: noteStore)
            lastSuccess = "Inserted into the note."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Enhance notes

    func enhance(noteBody: String, title: String, sessions: [Session]) async {
        guard !isBusy else { return }
        let userNotes = NoteScribeBlocks.userContent(body: noteBody)
        guard !userNotes.isEmpty else {
            errorMessage = "Type a few notes first — Enhance expands your own notes with details from the recording."
            return
        }
        let segments = NoteAISegments.combined(sessions: sessions, transcriptStore: transcriptStore)
        guard !segments.isEmpty else {
            errorMessage = "This note's recordings have no transcript yet."
            return
        }
        busyLabel = "Enhancing notes…"
        errorMessage = nil
        lastSuccess = nil
        defer { busyLabel = nil }
        do {
            let enhanced = try await MeetingSummarizer.enhanceNotes(
                userNotes: userNotes,
                title: title,
                segments: segments
            )
            guard !enhanced.isEmpty else {
                errorMessage = "Apple Intelligence returned an empty result."
                return
            }
            enhanceResult = EnhanceResult(originalUserNotes: userNotes, enhanced: enhanced)
        } catch {
            errorMessage = error.localizedDescription
            Log.intelligence.error("Enhance notes failed: \(error.localizedDescription)")
        }
    }
}
