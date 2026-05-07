// Scribe/Storage/NoteStore.swift
import Foundation
import GRDB
import Combine

final class NoteStore: @unchecked Sendable {

    private let dbManager: DatabaseManager
    private var db: DatabaseQueue { dbManager.database }

    static let shared = NoteStore(databaseManager: .shared)

    init(databaseManager: DatabaseManager = .shared) {
        self.dbManager = databaseManager
    }

    // MARK: - CRUD

    @discardableResult
    func createNote(title: String, body: String = "", tags: [String] = [],
                    isDailyNote: Bool = false, dailyDate: String? = nil) throws -> Note {
        try db.write { database in
            let note = Note(title: title, body: body,
                            isDailyNote: isDailyNote, dailyDate: dailyDate)
            try note.insert(database)
            for tag in Self.normalizeTags(tags) {
                try NoteTagRow(noteId: note.id, tag: tag).insert(database)
            }
            return note
        }
    }

    func updateNote(_ note: Note, tags: [String]) throws {
        try db.write { database in
            var mutable = note
            mutable.updatedAt = Date()
            try mutable.update(database)

            // rewrite tags
            try database.execute(sql: "DELETE FROM note_tags WHERE noteId = ?",
                                 arguments: [note.id])
            for tag in Self.normalizeTags(tags) {
                try NoteTagRow(noteId: note.id, tag: tag).insert(database)
            }

            // rewrite wiki-links
            let anchors = Self.parseWikiLinks(from: note.body)
            try database.execute(sql: "DELETE FROM note_links WHERE sourceNoteId = ?",
                                 arguments: [note.id])
            for anchor in anchors {
                if let target = try Note
                    .filter(sql: "LOWER(title) = LOWER(?)", arguments: [anchor])
                    .fetchOne(database) {
                    let link = NoteLinkRow(sourceNoteId: note.id,
                                          targetNoteId: target.id,
                                          anchorText: anchor)
                    try? link.insert(database)
                }
            }
        }
    }

    func deleteNote(id: String) throws {
        try db.write { _ = try Note.deleteOne($0, key: id) }
    }

    func fetchNote(id: String) throws -> Note? {
        try db.read { try Note.fetchOne($0, key: id) }
    }

    func fetchAllNotes() throws -> [Note] {
        try db.read { try Note.order(Column("updatedAt").desc).fetchAll($0) }
    }

    // MARK: - Daily notes

    private static let dailyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dailyTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func dailyNote(for date: Date) throws -> Note {
        let key = Self.dailyDateFormatter.string(from: date)
        if let existing = try db.read({ try Note
            .filter(sql: "dailyDate = ?", arguments: [key])
            .fetchOne($0) }) {
            return existing
        }
        let title = "Daily Note \u{2013} \(Self.dailyTitleFormatter.string(from: date))"
        return try createNote(title: title, isDailyNote: true, dailyDate: key)
    }

    // MARK: - Tags

    func tags(for noteId: String) throws -> [String] {
        try db.read { database in
            try NoteTagRow
                .filter(Column("noteId") == noteId)
                .fetchAll(database)
                .map(\.tag)
        }
    }

    func allNoteTags() throws -> [String] {
        try db.read { database in
            try String.fetchAll(database, sql: "SELECT DISTINCT tag FROM note_tags ORDER BY tag")
        }
    }

    // MARK: - Backlinks

    func backlinks(for noteId: String) throws -> [Note] {
        try db.read { database in
            try Note.fetchAll(database, sql: """
                SELECT notes.* FROM notes
                JOIN note_links ON notes.id = note_links.sourceNoteId
                WHERE note_links.targetNoteId = ?
                ORDER BY notes.updatedAt DESC
                """, arguments: [noteId])
        }
    }

    // MARK: - Resolution

    func resolveTitle(_ title: String) throws -> Note? {
        try db.read { database in
            try Note.filter(sql: "LOWER(title) = LOWER(?)", arguments: [title]).fetchOne(database)
        }
    }

    // MARK: - Search

    func searchNotes(query: String) throws -> [Note] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return try fetchAllNotes() }
        return try db.read { database in
            try Note.fetchAll(database, sql: """
                SELECT notes.* FROM notes
                JOIN notes_fts ON notes.rowid = notes_fts.rowid
                WHERE notes_fts MATCH ?
                ORDER BY bm25(notes_fts)
                LIMIT 100
                """, arguments: [q + "*"])
        }
    }

    // MARK: - Observation

    func observeNotes() -> AnyPublisher<[Note], Error> {
        ValueObservation
            .tracking { try Note.order(Column("updatedAt").desc).fetchAll($0) }
            .publisher(in: db, scheduling: .immediate)
            .eraseToAnyPublisher()
    }

    // MARK: - Private helpers

    static func normalizeTags(_ tags: [String]) -> [String] {
        tags.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    static func parseWikiLinks(from text: String) -> [String] {
        let pattern = #"\[\[([^\[\]]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r]).trimmingCharacters(in: .whitespaces)
        }
    }
}
