// ScribeTests/NoteStoreHybridTests.swift
import XCTest
@testable import Scribe

/// Slice 2 contract: when a `NoteFileStore` is injected, every successful
/// DB write mirrors to a `.md` file, every delete removes the file, and
/// `fetchNote(id:)` prefers the disk body over the DB column.
///
/// These tests intentionally use a temp directory for the file store and
/// an in-memory DB, so they leave no production-state behind.
final class NoteStoreHybridTests: XCTestCase {

    private var tempRoot: URL!
    private var dbManager: DatabaseManager!
    private var fileStore: NoteFileStore!
    private var store: NoteStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = NotesDirectory(root: tempRoot)
        fileStore = NoteFileStore(directory: directory)
        dbManager = try! DatabaseManager(path: ":memory:")
        store = NoteStore(databaseManager: dbManager, fileStore: fileStore)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Create

    func testCreateMirrorsBodyToDisk() throws {
        let note = try store.createNote(title: "Hello", body: "Some body")
        let url = try fileStore.findURL(for: note.id)
        XCTAssertNotNil(url)
        let parsed = try fileStore.read(at: url!)
        XCTAssertEqual(parsed.body, "Some body")
        XCTAssertEqual(parsed.frontmatter.title, "Hello")
    }

    func testCreateMirrorsTags() throws {
        let note = try store.createNote(title: "Tagged", tags: ["foo", "BAR"])
        let url = try fileStore.findURL(for: note.id)
        let parsed = try fileStore.read(at: url!)
        // Tags are normalized to lowercase in the DB; mirror should match.
        XCTAssertEqual(parsed.frontmatter.tags, ["foo", "bar"])
    }

    // MARK: - Update

    func testUpdateMirrorsBodyChange() throws {
        let note = try store.createNote(title: "Initial", body: "v1")
        var updated = note
        updated.body = "v2"
        try store.updateNote(updated, tags: [])
        let url = try fileStore.findURL(for: note.id)
        XCTAssertEqual(try fileStore.read(at: url!).body, "v2")
    }

    func testUpdateMirrorsTitleRename() throws {
        let note = try store.createNote(title: "Old name", body: "")
        var renamed = note
        renamed.title = "New name"
        try store.updateNote(renamed, tags: [])
        let url = try fileStore.findURL(for: note.id)
        XCTAssertEqual(url?.lastPathComponent, "New name.md")
    }

    // MARK: - Fetch

    func testFetchReadsBodyFromDisk() throws {
        let note = try store.createNote(title: "Source of truth", body: "disk wins")
        // Manually edit the disk file to a different body — simulates an
        // external editor changing the file while the DB column is stale.
        let url = try fileStore.findURL(for: note.id)!
        var onDisk = try fileStore.read(at: url)
        onDisk.body = "edited externally"
        try fileStore.write(onDisk)
        let fetched = try store.fetchNote(id: note.id)
        XCTAssertEqual(fetched?.body, "edited externally")
    }

    func testFetchReturnsEmptyBodyWhenFileMissing() throws {
        // Slice 5: body is not persisted in SQLite. Removing the disk file
        // is therefore an unrecoverable body loss — fetchNote returns the
        // metadata row but body comes back empty. The bodyExcerpt remains
        // (written at create-time from the now-lost body), giving the UI
        // something to show until the user re-edits the note.
        let note = try store.createNote(title: "Has file", body: "from-disk")
        try fileStore.delete(id: note.id)
        let fetched = try store.fetchNote(id: note.id)
        XCTAssertEqual(fetched?.title, "Has file")
        XCTAssertEqual(fetched?.body, "")
        XCTAssertEqual(fetched?.bodyExcerpt, "from-disk")
    }

    // MARK: - Delete

    func testDeleteRemovesFile() throws {
        let note = try store.createNote(title: "Doomed", body: "")
        XCTAssertNotNil(try fileStore.findURL(for: note.id))
        try store.deleteNote(id: note.id)
        XCTAssertNil(try fileStore.findURL(for: note.id))
    }

    // MARK: - Daily note

    func testDailyNoteMirrorsToDailyFolder() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 18
        let date = Calendar(identifier: .gregorian).date(from: components)!
        let note = try store.dailyNote(for: date)
        let url = try fileStore.findURL(for: note.id)
        XCTAssertEqual(url?.lastPathComponent, "2026-05-18.md")
        XCTAssertEqual(url?.deletingLastPathComponent().lastPathComponent, "Daily")
    }

    // MARK: - Opt-out

    func testNilFileStoreSkipsMirroring() throws {
        let plain = NoteStore(databaseManager: dbManager, fileStore: nil)
        _ = try plain.createNote(title: "DB only", body: "x")
        // fileStore still wired to the suite's temp directory but the
        // store under test didn't get to know about it — nothing should
        // appear on disk.
        let listed = try fileStore.listAll()
        XCTAssertTrue(listed.isEmpty)
    }

    // MARK: - Per-note typeface in frontmatter

    func testNoteFontRoundTripsThroughFrontmatter() throws {
        let note = try store.createNote(title: "Styled", body: "Hello")
        XCTAssertNil(store.noteFont(id: note.id))

        store.setNoteFont(id: note.id, "serif")
        XCTAssertEqual(store.noteFont(id: note.id), "serif")

        // Persisted to the actual file's frontmatter (Obsidian-compatible).
        let url = try XCTUnwrap(fileStore.findURL(for: note.id))
        XCTAssertEqual(try fileStore.read(at: url).frontmatter.extraValue(forKey: "font"), "serif")

        store.setNoteFont(id: note.id, nil)
        XCTAssertNil(store.noteFont(id: note.id))
    }

    func testFontSurvivesDBDrivenWrite() throws {
        var note = try store.createNote(title: "Styled", body: "Body")
        store.setNoteFont(id: note.id, "mono")

        // A normal DB-driven save rebuilds frontmatter from the DB — the font
        // extra must NOT be clobbered (mirrorToDisk merges existing extras).
        note.body = "Edited body"
        try store.updateNote(note, tags: [])

        XCTAssertEqual(store.noteFont(id: note.id), "mono",
                       "per-note font in frontmatter must survive a DB-driven write")
        XCTAssertEqual(try store.fetchNote(id: note.id)?.body, "Edited body")
    }
}
