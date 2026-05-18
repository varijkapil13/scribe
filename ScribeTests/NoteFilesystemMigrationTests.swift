// ScribeTests/NoteFilesystemMigrationTests.swift
import XCTest
@testable import Scribe

/// Slice 3 contract: `migrateNotesToDisk()` is idempotent and writes one
/// `.md` file per DB note that isn't already on disk. Preserves UUIDs,
/// daily-note semantics, and notebook hierarchy across the round-trip.
final class NoteFilesystemMigrationTests: XCTestCase {

    private var tempRoot: URL!
    private var dbManager: DatabaseManager!
    private var fileStore: NoteFileStore!
    private var hybrid: NoteStore!
    private var dbOnly: NoteStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = NotesDirectory(root: tempRoot)
        fileStore = NoteFileStore(directory: directory)
        dbManager = try! DatabaseManager(path: ":memory:")
        hybrid = NoteStore(databaseManager: dbManager, fileStore: fileStore)
        // A second NoteStore against the same DB but with no file store —
        // simulates the legacy app, used to seed DB rows that don't yet
        // exist on disk before the migration runs.
        dbOnly = NoteStore(databaseManager: dbManager, fileStore: nil)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testMigratesAllPreExistingNotes() throws {
        _ = try dbOnly.createNote(title: "A", body: "first")
        _ = try dbOnly.createNote(title: "B", body: "second")
        _ = try dbOnly.createNote(title: "C", body: "third", tags: ["foo"])
        XCTAssertTrue(try fileStore.listAll().isEmpty)

        let written = try hybrid.migrateNotesToDisk()
        XCTAssertEqual(written, 3)
        XCTAssertEqual(try fileStore.listAll().count, 3)
    }

    func testIdempotentOnSecondRun() throws {
        _ = try dbOnly.createNote(title: "A", body: "x")
        XCTAssertEqual(try hybrid.migrateNotesToDisk(), 1)
        // Second run sees the file already present and skips.
        XCTAssertEqual(try hybrid.migrateNotesToDisk(), 0)
    }

    func testPartiallyMigratedStateResumes() throws {
        // Seed three DB-only notes, run migration, then *manually* remove
        // one disk file to simulate a crash mid-flight. The next migration
        // run must pick up exactly the missing one.
        let a = try dbOnly.createNote(title: "A", body: "1")
        _ = try dbOnly.createNote(title: "B", body: "2")
        _ = try dbOnly.createNote(title: "C", body: "3")
        XCTAssertEqual(try hybrid.migrateNotesToDisk(), 3)
        try fileStore.delete(id: a.id)
        XCTAssertEqual(try hybrid.migrateNotesToDisk(), 1)
    }

    func testPreservesIdAndTitle() throws {
        let note = try dbOnly.createNote(title: "Preserved", body: "body")
        _ = try hybrid.migrateNotesToDisk()
        let url = try fileStore.findURL(for: note.id)
        let parsed = try fileStore.read(at: url!)
        XCTAssertEqual(parsed.id, note.id)
        XCTAssertEqual(parsed.frontmatter.title, "Preserved")
    }

    func testPreservesTags() throws {
        let note = try dbOnly.createNote(title: "Tagged", tags: ["alpha", "beta"])
        _ = try hybrid.migrateNotesToDisk()
        let url = try fileStore.findURL(for: note.id)
        let parsed = try fileStore.read(at: url!)
        XCTAssertEqual(parsed.frontmatter.tags.sorted(), ["alpha", "beta"])
    }

    func testPreservesNotebookId() throws {
        let nb = try dbOnly.createNotebook(name: "Inbox")
        let note = try dbOnly.createNote(title: "Filed", notebookId: nb.id)
        _ = try hybrid.migrateNotesToDisk()
        let url = try fileStore.findURL(for: note.id)
        let parsed = try fileStore.read(at: url!)
        XCTAssertEqual(parsed.frontmatter.notebookId, nb.id)
    }

    func testPreservesDailyNoteSemantics() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 18
        let date = Calendar(identifier: .gregorian).date(from: components)!
        _ = try dbOnly.dailyNote(for: date)
        _ = try hybrid.migrateNotesToDisk()
        // Daily-note files live under Daily/ — confirm the layout survives.
        let files = try fileStore.listAll()
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].frontmatter.isDailyNote)
    }

    func testNilFileStoreReturnsZero() throws {
        _ = try dbOnly.createNote(title: "Nothing to migrate", body: "")
        let written = try dbOnly.migrateNotesToDisk()
        XCTAssertEqual(written, 0)
    }
}
