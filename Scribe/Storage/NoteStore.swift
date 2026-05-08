// Scribe/Storage/NoteStore.swift
import Foundation
import GRDB
import Combine

enum NoteStoreError: Error, LocalizedError {
    case dailyNoteNotFound(String)
    var errorDescription: String? {
        switch self {
        case .dailyNoteNotFound(let key): return "Daily note for \(key) not found after insert."
        }
    }
}

// @unchecked Sendable is safe: DatabaseQueue is thread-safe and dbManager is
// immutable after init — no mutable state crosses actor boundaries.
final class NoteStore: @unchecked Sendable {

    private let dbManager: DatabaseManager
    private var db: DatabaseQueue { dbManager.database }

    // nonisolated(unsafe) required for Swift 6 strict concurrency on a global
    // stored property accessed from non-isolated contexts.
    nonisolated(unsafe) static let shared = NoteStore(databaseManager: .shared)

    init(databaseManager: DatabaseManager = .shared) {
        self.dbManager = databaseManager
    }

    // MARK: - CRUD

    @discardableResult
    func createNote(title: String, body: String = "", tags: [String] = [],
                    isDailyNote: Bool = false, dailyDate: String? = nil,
                    notebookId: String? = nil) throws -> Note {
        try db.write { database in
            let note = Note(title: title, body: body,
                            isDailyNote: isDailyNote, dailyDate: dailyDate,
                            notebookId: notebookId)
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
            let anchors = Self.parseWikiLinks(from: mutable.body)
            try database.execute(sql: "DELETE FROM note_links WHERE sourceNoteId = ?",
                                 arguments: [note.id])
            for anchor in anchors {
                if let target = try Note
                    .filter(sql: "LOWER(title) = LOWER(?)", arguments: [anchor])
                    .fetchOne(database) {
                    let link = NoteLinkRow(sourceNoteId: note.id,
                                          targetNoteId: target.id,
                                          anchorText: anchor)
                    // insertOrIgnore: duplicate (sourceNoteId, targetNoteId, anchorText)
                    // is expected when a note links to the same target twice with
                    // identical anchor text — silently skip the duplicate.
                    try link.insert(database, onConflict: .ignore)
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

    // Intentionally uses device timezone (no explicit timeZone set) so month/day
    // names appear in the user's locale and current timezone — unlike
    // dailyDateFormatter which uses en_US_POSIX for machine-readable keys.
    private static let dailyTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    /// Returns an existing daily note for `date`, or nil if none exists.
    /// Never creates a note — use `dailyNote(for:)` only when creation is
    /// explicitly intended (e.g. after the user starts typing).
    func fetchExistingDailyNote(for date: Date) throws -> Note? {
        let key = Self.dailyDateFormatter.string(from: date)
        return try db.read { try Note.filter(sql: "dailyDate = ?", arguments: [key]).fetchOne($0) }
    }

    /// Atomically fetches or creates the daily note for `date`. Call only
    /// when creation is intended — for read-only lookup use fetchExistingDailyNote(for:).
    func dailyNote(for date: Date) throws -> Note {
        let key = Self.dailyDateFormatter.string(from: date)
        let title = "Daily Note \u{2013} \(Self.dailyTitleFormatter.string(from: date))"
        // Atomic: INSERT OR IGNORE then SELECT avoids TOCTOU race where two
        // rapid calls (e.g. double .onAppear) would create two notes for the
        // same date. The UNIQUE constraint on dailyDate enforces uniqueness at
        // the DB level; this write block makes the check-then-insert atomic.
        return try db.write { database in
            try database.execute(
                sql: """
                    INSERT OR IGNORE INTO notes
                        (id, title, body, createdAt, updatedAt, isDailyNote, dailyDate)
                    VALUES (?, ?, '', ?, ?, 1, ?)
                    """,
                arguments: [UUID().uuidString, title, Date(), Date(), key]
            )
            guard let note = try Note.filter(sql: "dailyDate = ?", arguments: [key]).fetchOne(database) else {
                throw NoteStoreError.dailyNoteNotFound(key)
            }
            return note
        }
    }

    func fetchNotes(withTag tag: String) throws -> [Note] {
        try db.read { database in
            try Note.fetchAll(database, sql: """
                SELECT notes.* FROM notes
                JOIN note_tags ON notes.id = note_tags.noteId
                WHERE note_tags.tag = ?
                ORDER BY notes.updatedAt DESC
                """, arguments: [tag])
        }
    }

    func fetchDailyDates() throws -> [String] {
        try db.read { database in
            try String.fetchAll(database,
                sql: "SELECT dailyDate FROM notes WHERE isDailyNote = 1 AND dailyDate IS NOT NULL ORDER BY dailyDate")
        }
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

    // MARK: - Links

    func fetchAllLinks() throws -> [NoteLinkRow] {
        try db.read { try NoteLinkRow.fetchAll($0) }
    }

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
        let sanitized = Self.ftsQuery(from: q)
        guard !sanitized.isEmpty else { return [] }
        return try db.read { database in
            try Note.fetchAll(database, sql: """
                SELECT notes.* FROM notes
                JOIN notes_fts ON notes.rowid = notes_fts.rowid
                WHERE notes_fts MATCH ?
                ORDER BY bm25(notes_fts)
                LIMIT 100
                """, arguments: [sanitized])
        }
    }

    /// Builds a safe FTS5 MATCH expression. Matches TaskStore.ftsQuery(from:).
    static func ftsQuery(from raw: String) -> String {
        let tokens = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .map { token in
                token.unicodeScalars
                    .filter { CharacterSet.alphanumerics.contains($0) }
                    .reduce(into: "") { $0.append(Character($1)) }
            }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // MARK: - Observation

    func observeNotes() -> AnyPublisher<[Note], Error> {
        ValueObservation
            .tracking { try Note.order(Column("updatedAt").desc).fetchAll($0) }
            .publisher(in: db, scheduling: .async(onQueue: .main))
            .eraseToAnyPublisher()
    }

    func observeNotebooks() -> AnyPublisher<[Notebook], Error> {
        ValueObservation
            .tracking { try Notebook.order(Column("sortOrder")).fetchAll($0) }
            .publisher(in: db, scheduling: .async(onQueue: .main))
            .eraseToAnyPublisher()
    }

    // MARK: - Notebooks

    @discardableResult
    func createNotebook(name: String) throws -> Notebook {
        try db.write { database in
            let maxSort = try Int.fetchOne(database,
                sql: "SELECT COALESCE(MAX(sortOrder), -1) FROM notebooks") ?? -1
            let nb = Notebook(name: name, sortOrder: maxSort + 1)
            try nb.insert(database)
            return nb
        }
    }

    func updateNotebook(_ notebook: Notebook) throws {
        try db.write { try notebook.update($0) }
    }

    func deleteNotebook(id: String) throws {
        try db.write { database in
            // Set notebookId = NULL on orphaned notes (FK is not enforced via
            // ALTER TABLE, so we do it manually before deleting the notebook).
            try database.execute(
                sql: "UPDATE notes SET notebookId = NULL WHERE notebookId = ?",
                arguments: [id]
            )
            try Notebook.deleteOne(database, key: id)
        }
    }

    func fetchAllNotebooks() throws -> [Notebook] {
        try db.read { try Notebook.order(Column("sortOrder")).fetchAll($0) }
    }

    // Notes filtered by notebook. nil = Inbox (notebookId IS NULL and not a daily note).
    func fetchNotes(inNotebook notebookId: String) throws -> [Note] {
        try db.read { database in
            try Note
                .filter(Column("notebookId") == notebookId)
                .order(Column("updatedAt").desc)
                .fetchAll(database)
        }
    }

    func fetchInboxNotes() throws -> [Note] {
        try db.read { database in
            try Note
                // GRDB maps `== nil` to `IS NULL` — intentional, selects unassigned notes.
                .filter(Column("notebookId") == nil && Column("isDailyNote") == false)
                .order(Column("updatedAt").desc)
                .fetchAll(database)
        }
    }

    func moveNote(id: String, toNotebookId: String?) throws {
        try db.write { database in
            try database.execute(
                sql: "UPDATE notes SET notebookId = ? WHERE id = ?",
                arguments: [toNotebookId, id]
            )
        }
    }

    // MARK: - Private helpers

    static func normalizeTags(_ tags: [String]) -> [String] {
        // Deduplicate after normalising — matches TaskStore.normalisedTags behaviour.
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static let wikiLinkRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\[\[([^\[\]]+)\]\]"#)
    }()

    static func parseWikiLinks(from text: String) -> [String] {
        let regex = Self.wikiLinkRegex
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r]).trimmingCharacters(in: .whitespaces)
        }
    }
}
