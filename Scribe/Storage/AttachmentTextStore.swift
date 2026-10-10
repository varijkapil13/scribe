// Scribe/Storage/AttachmentTextStore.swift
import Foundation
import GRDB

/// Text recognized inside one vault attachment (an image via OCR, or a PDF
/// via its text layer plus OCR of image-only pages). Keyed by the
/// attachment's vault-relative path; `contentHash` / `fileSize` /
/// `modifiedAt` let the background indexer skip unchanged files.
struct AttachmentTextRecord: Codable, Equatable, Sendable {
    /// Vault-relative path, e.g. `attachments/<noteId>/scan.pdf`.
    var path: String
    /// The owning note (the `attachments/<noteId>/` folder name), if any.
    var noteId: String?
    /// SHA-256 (hex) of the file's bytes when it was recognized.
    var contentHash: String
    var fileSize: Int64
    /// File modification time (seconds since 1970) when it was recognized.
    var modifiedAt: Double
    /// `image` or `pdf`.
    var kind: String
    /// Recognized text (may be empty: nothing found).
    var text: String
    var recognizedAt: Date

    init(
        path: String,
        noteId: String?,
        contentHash: String,
        fileSize: Int64,
        modifiedAt: Double,
        kind: String,
        text: String,
        recognizedAt: Date
    ) {
        self.path = path
        self.noteId = noteId
        self.contentHash = contentHash
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.kind = kind
        self.text = text
        self.recognizedAt = recognizedAt
    }
}

extension AttachmentTextRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "attachment_text"
}

// MARK: - Migration

extension DatabaseManager {

    /// Registers `v25_attachment_text`: the recognized-text table for vault
    /// attachments plus its FTS5 index. Additive (new tables only). Called
    /// from `makeMigrator()` after every earlier migration.
    static func registerAttachmentTextMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v25_attachment_text") { db in
            try db.create(table: "attachment_text") { t in
                t.column("path", .text).notNull().primaryKey()
                t.column("noteId", .text)
                t.column("contentHash", .text).notNull()
                t.column("fileSize", .integer).notNull().defaults(to: 0)
                t.column("modifiedAt", .double).notNull().defaults(to: 0)
                t.column("kind", .text).notNull().defaults(to: "image")
                t.column("text", .text).notNull().defaults(to: "")
                t.column("recognizedAt", .datetime).notNull()
            }
            try db.create(index: "attachment_text_noteId_idx",
                          on: "attachment_text",
                          columns: ["noteId"])
            // Kept in sync explicitly by `AttachmentTextStore` (no triggers),
            // like `notes_fts`.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE attachment_text_fts USING fts5(
                    path UNINDEXED,
                    noteId UNINDEXED,
                    text
                )
                """)
        }
    }
}

// MARK: - Store

/// Reads/writes recognized attachment text and its full-text index. The
/// macOS OCR indexer is the writer; note search (`NoteStore.searchNotes`)
/// reads `matchingNoteIds` so a query finds notes by text inside their
/// images and scanned PDFs.
final class AttachmentTextStore: Sendable {

    static let shared = AttachmentTextStore(dbManager: .shared)

    private let dbManager: DatabaseManager

    init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    private var db: DatabaseQueue { dbManager.database }

    // MARK: Reads

    func record(forPath path: String) throws -> AttachmentTextRecord? {
        try db.read { try AttachmentTextRecord.fetchOne($0, key: path) }
    }

    func allRecords() throws -> [AttachmentTextRecord] {
        try db.read { try AttachmentTextRecord.fetchAll($0) }
    }

    /// Number of recognized attachments (without loading their text).
    func recordCount() throws -> Int {
        try db.read { try AttachmentTextRecord.fetchCount($0) }
    }

    /// Records for one note's attachments, by path.
    func records(forNoteId noteId: String) throws -> [AttachmentTextRecord] {
        try db.read { database in
            try AttachmentTextRecord
                .filter(Column("noteId") == noteId)
                .order(Column("path"))
                .fetchAll(database)
        }
    }

    // MARK: Writes

    /// Inserts or replaces the record and its FTS row.
    func upsert(_ record: AttachmentTextRecord) throws {
        try db.write { database in
            try Self.upsert(record, in: database)
        }
    }

    /// Updates only the stat facts of an unchanged file (same hash), so the
    /// next pass takes the cheap stat path again.
    func touch(path: String, fileSize: Int64, modifiedAt: Double) throws {
        try db.write { database in
            try database.execute(
                sql: "UPDATE attachment_text SET fileSize = ?, modifiedAt = ? WHERE path = ?",
                arguments: [fileSize, modifiedAt, path]
            )
        }
    }

    /// Removes records (and FTS rows) for vanished files.
    func remove(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try db.write { database in
            for path in paths {
                _ = try AttachmentTextRecord.deleteOne(database, key: path)
                try database.execute(sql: "DELETE FROM attachment_text_fts WHERE path = ?", arguments: [path])
            }
        }
    }

    static func upsert(_ record: AttachmentTextRecord, in database: Database) throws {
        try record.save(database)
        try database.execute(sql: "DELETE FROM attachment_text_fts WHERE path = ?", arguments: [record.path])
        let text = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        try database.execute(
            sql: "INSERT INTO attachment_text_fts(path, noteId, text) VALUES (?, ?, ?)",
            arguments: [record.path, record.noteId, text]
        )
    }

    // MARK: Search

    /// Note ids whose attachments match an already-escaped FTS5 query
    /// (`FTSQuery.escape`), best match first, each id once.
    static func matchingNoteIds(_ database: Database, ftsQuery: String, limit: Int) throws -> [String] {
        guard !ftsQuery.isEmpty else { return [] }
        let rows = try Row.fetchAll(database, sql: """
            SELECT noteId FROM attachment_text_fts
            WHERE attachment_text_fts MATCH ?
            ORDER BY bm25(attachment_text_fts)
            LIMIT ?
            """, arguments: [ftsQuery, limit * 4])
        var seen = Set<String>()
        var out: [String] = []
        for row in rows {
            guard let noteId = row["noteId"] as String?, !noteId.isEmpty else { continue }
            if seen.insert(noteId).inserted {
                out.append(noteId)
                if out.count >= limit { break }
            }
        }
        return out
    }

    /// The note id an attachment belongs to, from its vault-relative path
    /// (`attachments/<noteId>/…`). Nil for anything else.
    nonisolated static func noteId(forRelativePath path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 3, components[0] == "attachments" else { return nil }
        let folder = String(components[1])
        guard folder != "unfiled", folder != ".", folder != ".." else { return nil }
        return folder
    }
}
