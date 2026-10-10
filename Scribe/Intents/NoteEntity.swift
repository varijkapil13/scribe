import AppIntents
import Foundation

/// A Scribe note as Shortcuts / Siri see it.
struct NoteEntity: AppEntity, Sendable {

    let id: String
    let title: String
    let excerpt: String?
    let updatedAt: Date

    init(id: String, title: String, excerpt: String?, updatedAt: Date) {
        self.id = id
        self.title = title
        self.excerpt = excerpt
        self.updatedAt = updatedAt
    }

    init(note: Note) {
        self.init(
            id: note.id,
            title: ScribeIntentsText.displayTitle(note.title, fallback: "Untitled"),
            excerpt: note.bodyExcerpt,
            updatedAt: note.updatedAt
        )
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Note")
    }

    static var defaultQuery: NoteEntityQuery { NoteEntityQuery() }

    var displayRepresentation: DisplayRepresentation {
        let subtitle: LocalizedStringResource? = excerpt.map { "\($0)" }
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle,
            image: DisplayRepresentation.Image(systemName: "doc.text")
        )
    }
}

/// Resolves notes by id, by text (full-text search) and suggests the most
/// recently edited ones.
struct NoteEntityQuery: EntityStringQuery {

    init() {}

    func entities(for identifiers: [NoteEntity.ID]) async throws -> [NoteEntity] {
        try ScribeIntentsData.live.notes(ids: identifiers).map(NoteEntity.init(note:))
    }

    func entities(matching string: String) async throws -> [NoteEntity] {
        try ScribeIntentsData.live.searchNotes(string).map(NoteEntity.init(note:))
    }

    func suggestedEntities() async throws -> [NoteEntity] {
        try ScribeIntentsData.live.recentNotes().map(NoteEntity.init(note:))
    }
}
