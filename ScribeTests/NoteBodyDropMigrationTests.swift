// ScribeTests/NoteBodyDropMigrationTests.swift
import XCTest
import GRDB
@testable import Scribe

/// Slice 5 contract: `v13_drop_notes_body` drops the `notes.body` column,
/// adds `bodyExcerpt`, and rebuilds `notes_fts` as contentless. Bodies
/// from the legacy schema must be flushed to disk during the migration
/// so the disk-side store doesn't lose anything that was only ever
/// written through pre-Slice-2 code paths.
final class NoteBodyDropMigrationTests: XCTestCase {

    func testNotesTableHasNoBodyColumnAfterV13() throws {
        let db = try DatabaseManager(path: ":memory:")
        let columns: [String] = try db.database.read { database in
            try Row.fetchAll(database, sql: "PRAGMA table_info(notes)")
                .compactMap { $0["name"] as String? }
        }
        XCTAssertFalse(columns.contains("body"),
                       "notes.body must be dropped after v13")
        XCTAssertTrue(columns.contains("bodyExcerpt"),
                      "notes.bodyExcerpt must exist after v13")
    }

    func testNotesFtsIsContentlessAfterV13() throws {
        let db = try DatabaseManager(path: ":memory:")
        // The trigger-driven FTS table referenced `notes.body`; if v13
        // didn't drop those triggers we'd see them in sqlite_master.
        let triggers: [String] = try db.database.read { database in
            try String.fetchAll(database, sql: """
                SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'notes_fts_%'
                """)
        }
        XCTAssertTrue(triggers.isEmpty, "notes_fts triggers must be removed by v13")

        // Confirm we can insert into notes_fts manually via the new
        // (noteId, title, body) schema — proves the contentless table
        // exists and has the right columns.
        try db.database.write { database in
            try database.execute(sql: """
                INSERT INTO notes_fts(noteId, title, body) VALUES (?, ?, ?)
                """, arguments: ["x", "title", "body content"])
        }
    }

    func testV13FlushesLegacyBodiesToDisk() throws {
        // Drive the migrator up to v12 only and seed a row with a body in
        // the old column. v13 should write that body to disk before
        // dropping the column.
        let tmpDb = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmpDb) }
        let queue = try DatabaseQueue(path: tmpDb.path)
        var migrator = DatabaseManager.makeMigrator()
        // Run everything up to and including v12 (the slice-5 migration
        // is v13, so this stops just before it).
        try migrator.migrate(queue, upTo: "v12_notebook_parentId")

        // Seed a note in the legacy schema. Note.insert() can't be used
        // here because our Codable conformance has already moved past v12 —
        // the in-memory struct no longer carries `body`. Insert raw SQL
        // against the legacy shape instead.
        let noteId = "legacy-1"
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO notes
                    (id, title, body, createdAt, updatedAt, isDailyNote, dailyDate, notebookId)
                VALUES (?, ?, ?, ?, ?, 0, NULL, NULL)
                """, arguments: [noteId, "Legacy", "captured body", Date(), Date()])
        }

        // Verify file doesn't exist before migration.
        let vault = try NotesDirectory.defaultLocation()
        let store = NoteFileStore(directory: vault)
        // Tidy any leftover from prior runs that happened to choose the
        // same filename.
        try? store.delete(id: noteId)

        // Run the slice-5 migration.
        migrator = DatabaseManager.makeMigrator()
        try migrator.migrate(queue)

        // The legacy body should now be on disk.
        let url = try store.findURL(for: noteId)
        XCTAssertNotNil(url, "v13 should have flushed legacy body to disk")
        if let url {
            let parsed = try store.read(at: url)
            XCTAssertEqual(parsed.body, "captured body")
        }

        // Also confirm bodyExcerpt was populated from the legacy column.
        let excerpt: String? = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT bodyExcerpt FROM notes WHERE id = ?", arguments: [noteId])
        }
        XCTAssertEqual(excerpt, "captured body")

        // Clean up the file we created.
        try? store.delete(id: noteId)
    }
}
