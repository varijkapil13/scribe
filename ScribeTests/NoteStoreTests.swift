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
        // Body is no longer a SQLite column after Phase 5 / Slice 5 —
        // disk is the source. Confirm the rest of the metadata round-
        // trips and that body comes back empty when fetched directly
        // through GRDB (without going through NoteStore's disk read).
        let note = Note(title: "Test", body: "Hello world", bodyExcerpt: "Hello world")
        try db.database.write { try note.insert($0) }
        let fetched = try db.database.read { try Note.fetchOne($0, key: note.id) }
        XCTAssertEqual(fetched?.title, "Test")
        XCTAssertEqual(fetched?.body, "")
        XCTAssertEqual(fetched?.bodyExcerpt, "Hello world")
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

    // MARK: - Task 2 tests (require NoteStore)

    func testCreateAndFetchNote() throws {
        // After Slice 5, bodies live on disk — exercise the file-backed
        // path so the round-trip preserves body content.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = NoteStore(
            databaseManager: db,
            fileStore: NoteFileStore(directory: NotesDirectory(root: tmp))
        )
        let note = try store.createNote(title: "Hello", body: "World", tags: [])
        let fetched = try store.fetchNote(id: note.id)
        XCTAssertEqual(fetched?.title, "Hello")
        XCTAssertEqual(fetched?.body, "World")
        XCTAssertEqual(fetched?.bodyExcerpt, "World")
        XCTAssertFalse(fetched!.isDailyNote)
    }

    func testUpdateNote() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = NoteStore(
            databaseManager: db,
            fileStore: NoteFileStore(directory: NotesDirectory(root: tmp))
        )
        var note = try store.createNote(title: "Old", body: "", tags: [])
        note.title = "New"
        note.body = "Updated body"
        try store.updateNote(note, tags: [])
        let fetched = try store.fetchNote(id: note.id)
        XCTAssertEqual(fetched?.title, "New")
        XCTAssertEqual(fetched?.body, "Updated body")
    }

    func testDeleteNote() throws {
        let store = NoteStore(databaseManager: db)
        let note = try store.createNote(title: "Delete me", body: "", tags: [])
        try store.deleteNote(id: note.id)
        XCTAssertNil(try store.fetchNote(id: note.id))
    }

    func testTagsNormalized() throws {
        let store = NoteStore(databaseManager: db)
        let note = try store.createNote(title: "Tagged", body: "", tags: ["Swift", " iOS "])
        let tags = try store.tags(for: note.id)
        XCTAssertEqual(Set(tags), Set(["swift", "ios"]))
    }

    func testDailyNoteIdempotent() throws {
        let store = NoteStore(databaseManager: db)
        let today = Date()
        let first = try store.dailyNote(for: today)
        let second = try store.dailyNote(for: today)
        XCTAssertEqual(first.id, second.id)
        XCTAssertTrue(first.isDailyNote)
        XCTAssertTrue(first.title.hasPrefix("Daily Note \u{2013}"))
    }

    func testDailyNoteDifferentDates() throws {
        let store = NoteStore(databaseManager: db)
        let today = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let a = try store.dailyNote(for: today)
        let b = try store.dailyNote(for: tomorrow)
        XCTAssertNotEqual(a.id, b.id)
    }

    func testFTSSearch() throws {
        let store = NoteStore(databaseManager: db)
        _ = try store.createNote(title: "Swift concurrency", body: "actors and tasks", tags: [])
        _ = try store.createNote(title: "Python guide", body: "no concurrency here", tags: [])
        let results = try store.searchNotes(query: "concurr")
        XCTAssertEqual(results.count, 2)
    }

    func testFTSSearchEmptyQueryReturnsAll() throws {
        let store = NoteStore(databaseManager: db)
        _ = try store.createNote(title: "A", body: "", tags: [])
        _ = try store.createNote(title: "B", body: "", tags: [])
        let results = try store.searchNotes(query: "")
        XCTAssertEqual(results.count, 2)
    }

    func testBacklinks() throws {
        let store = NoteStore(databaseManager: db)
        let target = try store.createNote(title: "Target", body: "", tags: [])
        let source = try store.createNote(title: "Source", body: "See [[Target]] for details", tags: [])
        try store.updateNote(source, tags: [])
        let links = try store.backlinks(for: target.id)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].id, source.id)
    }

    func testAllNoteTags() throws {
        let store = NoteStore(databaseManager: db)
        _ = try store.createNote(title: "A", body: "", tags: ["swift", "ios"])
        _ = try store.createNote(title: "B", body: "", tags: ["swift", "macos"])
        let tags = try store.allNoteTags()
        XCTAssertEqual(Set(tags), Set(["swift", "ios", "macos"]))
    }

    func testDeleteCascadesCleansTagsAndLinks() throws {
        let store = NoteStore(databaseManager: db)
        let b = try store.createNote(title: "B", body: "", tags: [])
        let a = try store.createNote(title: "A", body: "[[B]]", tags: ["x"])
        try store.updateNote(a, tags: ["x"])
        try store.deleteNote(id: a.id)
        let linksAfter = try store.backlinks(for: b.id)
        XCTAssertTrue(linksAfter.isEmpty)
    }

    func testNormalizeTagsDeduplicates() throws {
        let store = NoteStore(databaseManager: db)
        // "swift" and "Swift" normalise to the same tag — must not insert twice
        // (would have hit a primary-key violation before the dedup fix).
        XCTAssertNoThrow(try store.createNote(title: "X", body: "", tags: ["swift", "Swift", "SWIFT"]))
        let tags = try store.allNoteTags()
        XCTAssertEqual(tags.filter { $0 == "swift" }.count, 1)
    }

    func testSearchNotesFTSSpecialCharacters() throws {
        let store = NoteStore(databaseManager: db)
        _ = try store.createNote(title: "Hello World", body: "", tags: [])
        // FTS5 operators in raw input must not crash; sanitiser strips them.
        XCTAssertNoThrow(try store.searchNotes(query: "hello OR world"))
        XCTAssertNoThrow(try store.searchNotes(query: "\"hello\""))
        XCTAssertNoThrow(try store.searchNotes(query: "hello-world"))
        XCTAssertNoThrow(try store.searchNotes(query: "--"))
    }

    func testDailyNoteAtomicIdempotency() throws {
        let store = NoteStore(databaseManager: db)
        let today = Date()
        // Simulate rapid double-call (TOCTOU scenario).
        let first = try store.dailyNote(for: today)
        let second = try store.dailyNote(for: today)
        XCTAssertEqual(first.id, second.id, "Concurrent dailyNote calls must return same note")
        let all = try store.fetchAllNotes()
        XCTAssertEqual(all.filter { $0.isDailyNote }.count, 1, "Must not create duplicate daily notes")
    }

    func testFetchNotesByTag() throws {
        let store = NoteStore(databaseManager: db)
        _ = try store.createNote(title: "Swift Note", body: "", tags: ["swift"])
        _ = try store.createNote(title: "Python Note", body: "", tags: ["python"])
        let swiftNotes = try store.fetchNotes(withTag: "swift")
        XCTAssertEqual(swiftNotes.count, 1)
        XCTAssertEqual(swiftNotes[0].title, "Swift Note")
    }

    func testFetchAllLinksReturnsSingleQueryResult() throws {
        let store = NoteStore(databaseManager: db)
        let a = try store.createNote(title: "A", body: "[[B]]", tags: [])
        let b = try store.createNote(title: "B", body: "", tags: [])
        try store.updateNote(a, tags: [])
        let links = try store.fetchAllLinks()
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].sourceNoteId, a.id)
        XCTAssertEqual(links[0].targetNoteId, b.id)
    }

    func testDeleteNoteRemovesAttachmentsFolder() throws {
        let store = NoteStore(databaseManager: db)
        let note = try store.createNote(title: "Has images", body: "")

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dir = try AttachmentsDirectory.directory(forNoteId: note.id, root: tempRoot)
        try Data().write(to: dir.appendingPathComponent("image.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))

        AttachmentsDirectory.rootOverrideForTesting = tempRoot
        defer { AttachmentsDirectory.rootOverrideForTesting = nil }

        try store.deleteNote(id: note.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path),
                       "deleteNote should remove the attachments folder")
    }

    // MARK: - sessionCount(forNoteId:)

    func testSessionCountIsZeroForUnboundNote() throws {
        let store = NoteStore(databaseManager: db)
        let note = try store.createNote(title: "Solo", body: "")
        XCTAssertEqual(try store.sessionCount(forNoteId: note.id), 0)
    }

    func testSessionCountReflectsBoundSessions() throws {
        let store = NoteStore(databaseManager: db)
        let transcripts = TranscriptStore(databaseManager: db)
        let note = try store.createNote(title: "Sync", body: "")
        _ = try transcripts.createSession(title: "R1", noteId: note.id)
        _ = try transcripts.createSession(title: "R2", noteId: note.id)
        XCTAssertEqual(try store.sessionCount(forNoteId: note.id), 2)
    }

    func testSessionCountIgnoresSessionsBoundToOtherNotes() throws {
        let store = NoteStore(databaseManager: db)
        let transcripts = TranscriptStore(databaseManager: db)
        let a = try store.createNote(title: "A", body: "")
        let b = try store.createNote(title: "B", body: "")
        _ = try transcripts.createSession(title: "for-a", noteId: a.id)
        _ = try transcripts.createSession(title: "for-b1", noteId: b.id)
        _ = try transcripts.createSession(title: "for-b2", noteId: b.id)
        XCTAssertEqual(try store.sessionCount(forNoteId: a.id), 1)
        XCTAssertEqual(try store.sessionCount(forNoteId: b.id), 2)
    }

    func testSessionCountZeroForUnknownNoteId() throws {
        let store = NoteStore(databaseManager: db)
        XCTAssertEqual(try store.sessionCount(forNoteId: "does-not-exist"), 0)
    }
}
