// ScribeTests/NoteBodyExcerptTests.swift
import XCTest
@testable import Scribe

/// Slice 5: NoteStore writes populate `notes.bodyExcerpt` and the
/// contentless `notes_fts`. Disk remains the source of truth for full
/// body content; SQLite holds only the snippet + searchable index.
final class NoteBodyExcerptTests: XCTestCase {

    private var tempRoot: URL!
    private var dbManager: DatabaseManager!
    private var fileStore: NoteFileStore!
    private var store: NoteStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        fileStore = NoteFileStore(directory: NotesDirectory(root: tempRoot))
        dbManager = try! DatabaseManager(path: ":memory:")
        store = NoteStore(databaseManager: dbManager, fileStore: fileStore)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testMakeExcerptCollapsesWhitespace() {
        let body = "First line.\n\nSecond line with   extra spaces."
        let excerpt = Note.makeExcerpt(from: body)
        XCTAssertEqual(excerpt, "First line. Second line with   extra spaces.")
    }

    func testMakeExcerptTruncatesAtLimit() {
        let body = String(repeating: "a", count: 500)
        let excerpt = Note.makeExcerpt(from: body, limit: 100)
        XCTAssertEqual(excerpt?.count, 101)  // 100 chars + ellipsis
        XCTAssertTrue(excerpt?.hasSuffix("…") ?? false)
    }

    func testMakeExcerptReturnsNilForEmpty() {
        XCTAssertNil(Note.makeExcerpt(from: ""))
        XCTAssertNil(Note.makeExcerpt(from: "   \n\n  "))
    }

    func testCreatePopulatesExcerpt() throws {
        let note = try store.createNote(title: "Hello", body: "Some body text")
        // Bulk fetch returns body="" but bodyExcerpt populated.
        let bulk = try store.fetchAllNotes()
        let row = bulk.first { $0.id == note.id }
        XCTAssertEqual(row?.bodyExcerpt, "Some body text")
        XCTAssertEqual(row?.body, "")
    }

    func testUpdateRewritesExcerpt() throws {
        var note = try store.createNote(title: "T", body: "v1")
        note.body = "v2 body content"
        try store.updateNote(note, tags: [])
        let bulk = try store.fetchAllNotes()
        let row = bulk.first { $0.id == note.id }
        XCTAssertEqual(row?.bodyExcerpt, "v2 body content")
    }

    func testCreatePopulatesFTSContentless() throws {
        let note = try store.createNote(title: "Searchable", body: "find this unique phrase")
        let results = try store.searchNotes(query: "unique phrase")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, note.id)
    }

    func testDeleteRemovesFTSRow() throws {
        let note = try store.createNote(title: "Ephemeral", body: "vanishing prose")
        XCTAssertEqual(try store.searchNotes(query: "vanishing").count, 1)
        try store.deleteNote(id: note.id)
        XCTAssertEqual(try store.searchNotes(query: "vanishing").count, 0)
    }

    func testSearchByTitleAlsoWorks() throws {
        _ = try store.createNote(title: "Quarkus rollout", body: "no body match here")
        let results = try store.searchNotes(query: "Quarkus")
        XCTAssertEqual(results.count, 1)
    }
}
