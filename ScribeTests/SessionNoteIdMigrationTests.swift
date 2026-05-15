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

    func testSessionRoundTripsNoteId() throws {
        let session = Session(title: "T", noteId: "note-42")
        try db.database.write { try session.insert($0) }
        let fetched = try db.database.read { try Session.fetchOne($0, key: session.id) }
        XCTAssertEqual(fetched?.noteId, "note-42")
    }

    func testSessionDefaultsToNilNoteId() throws {
        let session = Session(title: "T")
        try db.database.write { try session.insert($0) }
        let fetched = try db.database.read { try Session.fetchOne($0, key: session.id) }
        XCTAssertNil(fetched?.noteId)
    }
}
