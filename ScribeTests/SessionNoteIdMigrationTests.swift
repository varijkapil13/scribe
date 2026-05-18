// ScribeTests/SessionNoteIdMigrationTests.swift
import XCTest
import GRDB
@testable import Scribe

/// Migration tests for `v10_session_noteId` (adds the nullable column +
/// index) and `v11_session_noteId_backfill` (auto-creates a Note for every
/// pre-existing orphan session).
///
/// v11 is the load-bearing migration — it's what makes the post-PR
/// invariant "every session belongs to a note" true on databases that
/// existed before this feature. Verifying it via inline-mirrored SQL is
/// not enough; we drive the real migrator with a database that stops at
/// v10, simulate an orphan, then let v11 run for real.
final class SessionNoteIdMigrationTests: XCTestCase {

    func testSessionsHasNoteIdColumnAfterV10() throws {
        let db = try DatabaseManager(path: ":memory:")
        let columns: [String] = try db.database.read { database in
            try Row.fetchAll(database, sql: "PRAGMA table_info(sessions)")
                .compactMap { $0["name"] as String? }
        }
        XCTAssertTrue(columns.contains("noteId"),
                      "sessions table must have a noteId column after v10 migration")
    }

    func testSessionsNoteIdIndexExistsAfterV10() throws {
        let db = try DatabaseManager(path: ":memory:")
        let names: [String] = try db.database.read { database in
            try String.fetchAll(database,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='sessions'")
        }
        XCTAssertTrue(names.contains("sessions_noteId_idx"),
                      "sessions_noteId_idx must exist after v10 migration")
    }

    func testV11LeavesNoOrphansOnFreshDB() throws {
        // Trivial sanity: a brand-new DB has no sessions, so v11 has
        // nothing to backfill and exits cleanly. Proves the migration is
        // safe to run on a clean schema.
        let db = try DatabaseManager(path: ":memory:")
        let orphans = try db.database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessions WHERE noteId IS NULL") ?? -1
        }
        XCTAssertEqual(orphans, 0)
    }

    func testV11BackfillRunsAgainstSimulatedLegacyDatabase() throws {
        // Drive the real migrator up to v10 only. That mirrors what a user
        // sitting on the v9 schema sees the first time they upgrade to a
        // build that contains v10 + v11.
        let queue = try DatabaseQueue(path: ":memory:")
        let migrator = DatabaseManager.makeMigrator()
        try migrator.migrate(queue, upTo: "v10_session_noteId")

        // Insert a session at the v10 state — column exists, noteId NULL.
        let sessionId = UUID().uuidString
        let createdAt = Date(timeIntervalSince1970: 1_715_000_000)
        try queue.write { database in
            try database.execute(sql: """
                INSERT INTO sessions (id, title, createdAt, tags, noteId)
                VALUES (?, 'Standup', ?, '[]', NULL)
                """, arguments: [sessionId, createdAt])
        }

        // Sanity: orphan is present at the v10 checkpoint.
        let orphanCountBefore = try queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessions WHERE noteId IS NULL") ?? -1
        }
        XCTAssertEqual(orphanCountBefore, 1)

        // Drive the migrator forward — this is the real v11 SQL, not a
        // hand-rolled mirror inside the test.
        try migrator.migrate(queue)

        // After v11: zero orphans, exactly one new note bound to the
        // session, note title carried over from the session title.
        let orphanCountAfter = try queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessions WHERE noteId IS NULL") ?? -1
        }
        XCTAssertEqual(orphanCountAfter, 0,
                       "v11 must leave no orphan sessions behind.")

        let row = try queue.read {
            try Row.fetchOne($0,
                sql: "SELECT noteId FROM sessions WHERE id = ?",
                arguments: [sessionId])
        }
        let boundNoteId: String? = row?["noteId"]
        let unwrappedNoteId = try XCTUnwrap(boundNoteId,
                                            "Session must be bound to a note after v11.")

        let note = try queue.read {
            try Note.filter(sql: "id = ?", arguments: [unwrappedNoteId]).fetchOne($0)
        }
        XCTAssertEqual(note?.title, "Standup",
                       "v11 should copy the session title into the auto-created note.")
    }

    func testV11SynthesisesTitleForEmptySessionTitle() throws {
        // Same scenario but the legacy session had no title — v11 must
        // synthesise a "Meeting on <date>" title from the createdAt.
        let queue = try DatabaseQueue(path: ":memory:")
        let migrator = DatabaseManager.makeMigrator()
        try migrator.migrate(queue, upTo: "v10_session_noteId")

        let sessionId = UUID().uuidString
        let createdAt = Date(timeIntervalSince1970: 1_715_000_000)
        try queue.write { database in
            try database.execute(sql: """
                INSERT INTO sessions (id, title, createdAt, tags, noteId)
                VALUES (?, '', ?, '[]', NULL)
                """, arguments: [sessionId, createdAt])
        }

        try migrator.migrate(queue)

        let row = try queue.read {
            try Row.fetchOne($0,
                sql: "SELECT noteId FROM sessions WHERE id = ?",
                arguments: [sessionId])
        }
        let boundNoteId = try XCTUnwrap(row?["noteId"] as String?)
        let note = try queue.read {
            try Note.filter(sql: "id = ?", arguments: [boundNoteId]).fetchOne($0)
        }
        XCTAssertTrue(note?.title.hasPrefix("Meeting on") ?? false,
                      "Empty session title should backfill to 'Meeting on …'. Got: \(note?.title ?? "nil")")
    }

    func testV11BackfillsMultipleOrphansIndependently() throws {
        // Two legacy sessions → two distinct auto-created notes (one per
        // session). The migrator must not collapse them into a single
        // note or skip any.
        let queue = try DatabaseQueue(path: ":memory:")
        let migrator = DatabaseManager.makeMigrator()
        try migrator.migrate(queue, upTo: "v10_session_noteId")

        let s1 = UUID().uuidString
        let s2 = UUID().uuidString
        try queue.write { database in
            try database.execute(sql: """
                INSERT INTO sessions (id, title, createdAt, tags, noteId) VALUES
                    (?, 'Alpha', ?, '[]', NULL),
                    (?, 'Beta', ?, '[]', NULL)
                """, arguments: [s1, Date(), s2, Date()])
        }

        try migrator.migrate(queue)

        let boundIds: [String?] = try queue.read { database in
            try [s1, s2].map { id in
                try Row.fetchOne(database,
                    sql: "SELECT noteId FROM sessions WHERE id = ?",
                    arguments: [id])?["noteId"] as String?
            }
        }
        XCTAssertNotNil(boundIds[0])
        XCTAssertNotNil(boundIds[1])
        XCTAssertNotEqual(boundIds[0], boundIds[1],
                          "Each orphan session must get its own note.")
    }
}
