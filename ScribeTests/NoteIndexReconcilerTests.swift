// ScribeTests/NoteIndexReconcilerTests.swift
import XCTest
import GRDB
@testable import Scribe

/// Slice 4 contract: the reconciler treats disk as the source of truth.
/// Files present → DB rows present with matching body/tags. Files absent →
/// DB rows removed. Re-running with no changes is a no-op.
final class NoteIndexReconcilerTests: XCTestCase {

    private var tempRoot: URL!
    private var dbManager: DatabaseManager!
    private var fileStore: NoteFileStore!
    private var reconciler: NoteIndexReconciler!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = NotesDirectory(root: tempRoot)
        fileStore = NoteFileStore(directory: directory)
        dbManager = try! DatabaseManager(path: ":memory:")
        reconciler = NoteIndexReconciler(fileStore: fileStore, dbManager: dbManager)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testEmptyVaultNoOp() throws {
        let result = try reconciler.reconcile()
        XCTAssertEqual(result.upserted, 0)
        XCTAssertEqual(result.removed, 0)
    }

    func testUpsertsFilesIntoDb() throws {
        try fileStore.write(NoteFile(
            id: "id-1",
            frontmatter: NoteFrontmatter(title: "A", createdAt: Date(), updatedAt: Date()),
            body: "first"
        ))
        try fileStore.write(NoteFile(
            id: "id-2",
            frontmatter: NoteFrontmatter(title: "B", createdAt: Date(), updatedAt: Date()),
            body: "second"
        ))
        let result = try reconciler.reconcile()
        XCTAssertEqual(result.upserted, 2)
        XCTAssertEqual(result.removed, 0)

        let stored = try dbManager.database.read { db in
            try Note.order(Column("title")).fetchAll(db)
        }
        XCTAssertEqual(stored.map(\.title), ["A", "B"])
        // After Slice 5 the body isn't in SQLite — bodyExcerpt is the
        // surfaceable preview. The actual body still lives on disk.
        XCTAssertEqual(stored.map(\.bodyExcerpt), ["first", "second"])
    }

    func testRebuildsTagsFromFrontmatter() throws {
        try fileStore.write(NoteFile(
            id: "id-tags",
            frontmatter: NoteFrontmatter(
                title: "Tagged",
                createdAt: Date(),
                updatedAt: Date(),
                tags: ["foo", "Bar"]
            ),
            body: ""
        ))
        _ = try reconciler.reconcile()
        let tags = try dbManager.database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT tag FROM note_tags WHERE noteId = ? ORDER BY tag",
                arguments: ["id-tags"]
            )
        }
        XCTAssertEqual(tags, ["bar", "foo"])
    }

    func testRebuildsWikiLinksFromBody() throws {
        try fileStore.write(NoteFile(
            id: "source",
            frontmatter: NoteFrontmatter(title: "Source", createdAt: Date(), updatedAt: Date()),
            body: "See [[Target]] for details."
        ))
        try fileStore.write(NoteFile(
            id: "target",
            frontmatter: NoteFrontmatter(title: "Target", createdAt: Date(), updatedAt: Date()),
            body: ""
        ))
        _ = try reconciler.reconcile()
        let links = try dbManager.database.read { db in
            try NoteLinkRow.fetchAll(db)
        }
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.sourceNoteId, "source")
        XCTAssertEqual(links.first?.targetNoteId, "target")
    }

    func testRemovesOrphanDbRows() throws {
        // Seed the DB with a row, no matching file.
        try dbManager.database.write { db in
            let orphan = Note(id: "orphan", title: "ghost", body: "")
            try orphan.insert(db)
        }
        let result = try reconciler.reconcile()
        XCTAssertEqual(result.removed, 1)
        let remaining = try dbManager.database.read { db in
            try Note.fetchAll(db)
        }
        XCTAssertTrue(remaining.isEmpty)
    }

    func testIdempotentSecondPass() throws {
        try fileStore.write(NoteFile(
            id: "x",
            frontmatter: NoteFrontmatter(title: "X", createdAt: Date(), updatedAt: Date()),
            body: "body"
        ))
        _ = try reconciler.reconcile()
        let pass2 = try reconciler.reconcile()
        XCTAssertEqual(pass2.upserted, 1) // upserts every pass, but content unchanged
        XCTAssertEqual(pass2.removed, 0)
        // Confirm nothing duplicated.
        let count = try dbManager.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? -1
        }
        XCTAssertEqual(count, 1)
    }

    func testExternalEditWinsAfterReconcile() throws {
        // Initial state: row in DB with stale excerpt.
        try dbManager.database.write { db in
            let note = Note(id: "edited", title: "Edited", body: "", bodyExcerpt: "stale excerpt")
            try note.insert(db)
        }
        // Disk has fresher body — reconcile should rewrite the excerpt
        // and the FTS row from the disk content.
        try fileStore.write(NoteFile(
            id: "edited",
            frontmatter: NoteFrontmatter(title: "Edited", createdAt: Date(), updatedAt: Date()),
            body: "fresh disk body"
        ))
        _ = try reconciler.reconcile()
        let note = try dbManager.database.read { db in
            try Note.fetchOne(db, key: "edited")
        }
        XCTAssertEqual(note?.bodyExcerpt, "fresh disk body")
    }
}
