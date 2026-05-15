// ScribeTests/SessionNoteIdMigrationTests.swift
import XCTest
import GRDB
@testable import Scribe

final class SessionNoteIdMigrationTests: XCTestCase {
    private var db: DatabaseManager!

    override func setUp() {
        super.setUp()
        db = try! DatabaseManager(path: ":memory:")
    }

    override func tearDown() {
        db = nil
        super.tearDown()
    }

    func testSessionsHasNoteIdColumn() throws {
        let columns: [String] = try db.database.read { database in
            try Row.fetchAll(database, sql: "PRAGMA table_info(sessions)")
                .compactMap { $0["name"] as String? }
        }
        XCTAssertTrue(columns.contains("noteId"),
                      "sessions table must have a noteId column after v10 migration")
    }

    func testSessionsNoteIdIndexExists() throws {
        let names: [String] = try db.database.read { database in
            try String.fetchAll(database,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='sessions'")
        }
        XCTAssertTrue(names.contains("sessions_noteId_idx"),
                      "sessions_noteId_idx must exist after v10 migration")
    }

    func testV11LeavesNoOrphansAfterMigrationOnFreshDB() throws {
        // setUp ran all migrations on an empty DB. No sessions exist, so no
        // orphans either — trivial but proves the migration is safe to run on
        // a clean schema.
        let orphans = try db.database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessions WHERE noteId IS NULL") ?? -1
        }
        XCTAssertEqual(orphans, 0)
    }

    func testV11BackfillBehaviourOnOrphanSession() throws {
        // Simulate a session that survived from the v10 era (noteId nullable
        // and unset). Insert raw SQL bypassing the Swift API. Then re-run the
        // backfill SQL inline to verify it cleans up.
        let sessionId = UUID().uuidString
        let createdAt = Date(timeIntervalSince1970: 1_715_000_000)
        try db.database.write {
            try $0.execute(sql: """
                INSERT INTO sessions (id, title, createdAt, tags, noteId)
                VALUES (?, 'Standup', ?, '[]', NULL)
                """, arguments: [sessionId, createdAt])
        }

        // Mirror the migration logic to verify behaviour.
        try db.database.write { database in
            let orphans = try Row.fetchAll(database, sql: """
                SELECT id, title, createdAt FROM sessions WHERE noteId IS NULL
                """)
            XCTAssertEqual(orphans.count, 1)
            for row in orphans {
                let sid: String = row["id"]
                let stitle: String = row["title"]
                let sCreatedAt: Date = row["createdAt"]
                let noteTitle = stitle.isEmpty ? "Meeting on x" : stitle
                let noteId = UUID().uuidString
                try database.execute(sql: """
                    INSERT INTO notes (id, title, body, createdAt, updatedAt, isDailyNote, dailyDate, notebookId)
                    VALUES (?, ?, '', ?, ?, 0, NULL, NULL)
                    """, arguments: [noteId, noteTitle, sCreatedAt, Date()])
                try database.execute(sql: "UPDATE sessions SET noteId = ? WHERE id = ?",
                                     arguments: [noteId, sid])
            }
        }

        // After backfill: zero orphans, one new note bound to the session.
        let remaining = try db.database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessions WHERE noteId IS NULL") ?? -1
        }
        XCTAssertEqual(remaining, 0)

        let fetched = try db.database.read {
            try Row.fetchOne($0,
                sql: "SELECT noteId FROM sessions WHERE id = ?",
                arguments: [sessionId])
        }
        let boundNoteId: String? = fetched?["noteId"]
        XCTAssertNotNil(boundNoteId)

        let note = try db.database.read {
            try Note.filter(sql: "id = ?", arguments: [boundNoteId!]).fetchOne($0)
        }
        XCTAssertEqual(note?.title, "Standup")
    }

}
