// ScribeTests/NoteStoreTests.swift
import XCTest
import GRDB
@testable import Scribe

final class NoteStoreTests: XCTestCase {
    private var db: DatabaseManager!

    override func setUp() {
        super.setUp()
        db = try! DatabaseManager(path: ":memory:")
    }

    override func tearDown() { db = nil }

    func testMigrationCreatesNotesTable() throws {
        // Verify migration v6 ran — notes table exists
        let tableNames = try db.database.read { database in
            try String.fetchAll(database, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        XCTAssertTrue(tableNames.contains("notes"))
        XCTAssertTrue(tableNames.contains("note_tags"))
        XCTAssertTrue(tableNames.contains("note_links"))
    }

    func testMigrationCreatesFTSTable() throws {
        let tableNames = try db.database.read { database in
            try String.fetchAll(database, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        XCTAssertTrue(tableNames.contains("notes_fts"))
    }

    func testNoteModelRoundTrip() throws {
        let note = Note(title: "Test", body: "Hello world")
        try db.database.write { try note.insert($0) }
        let fetched = try db.database.read { try Note.fetchOne($0, key: note.id) }
        XCTAssertEqual(fetched?.title, "Test")
        XCTAssertEqual(fetched?.body, "Hello world")
        XCTAssertFalse(fetched!.isDailyNote)
    }

    func testNoteLinkRowRoundTrip() throws {
        let a = Note(title: "A", body: "")
        let b = Note(title: "B", body: "")
        try db.database.write { db in
            try a.insert(db)
            try b.insert(db)
            let link = NoteLinkRow(sourceNoteId: a.id, targetNoteId: b.id, anchorText: "B")
            try link.insert(db)
        }
        let links = try db.database.read { try NoteLinkRow.fetchAll($0) }
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].sourceNoteId, a.id)
    }

    func testNoteTagRowRoundTrip() throws {
        let note = Note(title: "Tagged", body: "")
        try db.database.write { db in
            try note.insert(db)
            try NoteTagRow(noteId: note.id, tag: "swift").insert(db)
        }
        let tags = try db.database.read { try NoteTagRow.fetchAll($0) }
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags[0].tag, "swift")
    }

    func testCascadeDeleteCleansNoteLinks() throws {
        let a = Note(title: "A", body: "")
        let b = Note(title: "B", body: "")
        try db.database.write { db in
            try a.insert(db)
            try b.insert(db)
            try NoteLinkRow(sourceNoteId: a.id, targetNoteId: b.id, anchorText: "B").insert(db)
        }
        try db.database.write { _ = try Note.deleteOne($0, key: a.id) }
        let links = try db.database.read { try NoteLinkRow.fetchAll($0) }
        XCTAssertTrue(links.isEmpty)
    }
}
