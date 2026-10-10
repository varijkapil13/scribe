import AppIntents
import Foundation

// Note intents. Each `perform()` hops to `ScribeIntentsBridge` (main actor)
// for anything that touches app state; read-only lookups go straight to
// `ScribeIntentsData`. Only Sendable values cross between them.

/// Creates a note.
struct CreateNoteIntent: AppIntent {

    static var title: LocalizedStringResource { "Create Note" }

    @Parameter(title: "Title")
    var noteTitle: String

    @Parameter(title: "Body")
    var noteBody: String?

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> & ProvidesDialog {
        let title = noteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = noteBody ?? ""
        let entity = try await ScribeIntentsBridge.createNote(title: title, body: body)
        return .result(value: entity, dialog: "Created \(entity.title).")
    }
}

/// Appends text to the end of a note.
struct AppendToNoteIntent: AppIntent {

    static var title: LocalizedStringResource { "Append to Note" }

    @Parameter(title: "Note")
    var note: NoteEntity

    @Parameter(title: "Text")
    var text: String

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> & ProvidesDialog {
        let noteId = note.id
        let addition = text
        let entity = try await ScribeIntentsBridge.append(addition, toNoteId: noteId)
        return .result(value: entity, dialog: "Added to \(entity.title).")
    }
}

/// Opens a note in Scribe's main window.
struct OpenNoteIntent: AppIntent {

    static var title: LocalizedStringResource { "Open Note" }

    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Note")
    var note: NoteEntity

    init() {}

    func perform() async throws -> some IntentResult {
        let noteId = note.id
        try await ScribeIntentsBridge.openNote(id: noteId)
        return .result()
    }
}

/// Full-text search over notes.
struct SearchNotesIntent: AppIntent {

    static var title: LocalizedStringResource { "Search Notes" }

    @Parameter(title: "Search Text")
    var query: String

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<[NoteEntity]> {
        let notes = try ScribeIntentsData.live.searchNotes(query).map(NoteEntity.init(note:))
        return .result(value: notes)
    }
}
