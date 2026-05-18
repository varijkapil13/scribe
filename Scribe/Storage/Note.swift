// Scribe/Storage/Note.swift
import Foundation
import GRDB

struct Notebook: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var sortOrder: Int
    var parentId: String?

    init(id: String = UUID().uuidString, name: String, sortOrder: Int = 0, parentId: String? = nil) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.parentId = parentId
    }
}

extension Notebook: FetchableRecord, PersistableRecord {
    static let databaseTableName = "notebooks"
}

struct Note: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var title: String
    /// Full markdown body. **Not persisted in SQLite as of Phase 5
    /// Slice 5** — the source of truth is the `.md` file on disk.
    /// `NoteStore.fetchNote(id:)` populates this field from disk;
    /// bulk fetches (`fetchAllNotes`, `fetchInboxNotes`, etc.) return
    /// it empty — use `bodyExcerpt` for list-view snippets instead.
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var isDailyNote: Bool
    var dailyDate: String?    // "YYYY-MM-DD", only set when isDailyNote == true
    var notebookId: String?   // nil = Inbox (uncategorized)
    /// Short preview (first ~200 chars of body, plain text). Maintained
    /// by `NoteStore` and `NoteIndexReconciler` so list views can show a
    /// snippet without a per-row disk read.
    var bodyExcerpt: String?

    init(
        id: String = UUID().uuidString,
        title: String = "",
        body: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isDailyNote: Bool = false,
        dailyDate: String? = nil,
        notebookId: String? = nil,
        bodyExcerpt: String? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDailyNote = isDailyNote
        self.dailyDate = dailyDate
        self.notebookId = notebookId
        self.bodyExcerpt = bodyExcerpt
    }

    /// Codable keys that match SQLite columns. `body` is deliberately
    /// excluded — bodies live on disk after Phase 5 / Slice 5; GRDB
    /// encodes/decodes only what's actually in the `notes` table.
    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, isDailyNote, dailyDate, notebookId, bodyExcerpt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.body = ""
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.isDailyNote = try c.decode(Bool.self, forKey: .isDailyNote)
        self.dailyDate = try c.decodeIfPresent(String.self, forKey: .dailyDate)
        self.notebookId = try c.decodeIfPresent(String.self, forKey: .notebookId)
        self.bodyExcerpt = try c.decodeIfPresent(String.self, forKey: .bodyExcerpt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(isDailyNote, forKey: .isDailyNote)
        try c.encodeIfPresent(dailyDate, forKey: .dailyDate)
        try c.encodeIfPresent(notebookId, forKey: .notebookId)
        try c.encodeIfPresent(bodyExcerpt, forKey: .bodyExcerpt)
    }

    /// Plain-text snippet for list previews. Strips markdown noise lightly —
    /// no full AST parse, just collapse whitespace and remove the most
    /// glaring decoration characters so the preview is readable.
    static func makeExcerpt(from body: String, limit: Int = 200) -> String? {
        let cleaned = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count <= limit { return cleaned }
        let idx = cleaned.index(cleaned.startIndex, offsetBy: limit)
        return String(cleaned[..<idx]) + "…"
    }
}

extension Note: FetchableRecord, PersistableRecord {
    static let databaseTableName = "notes"
}

struct NoteLinkRow: Codable, Equatable, Hashable {
    var sourceNoteId: String
    var targetNoteId: String
    var anchorText: String
}

extension NoteLinkRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "note_links"
}

struct NoteTagRow: Codable, Equatable, Hashable {
    var noteId: String
    var tag: String
}

extension NoteTagRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "note_tags"
}
