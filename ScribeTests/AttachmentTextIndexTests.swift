// ScribeTests/AttachmentTextIndexTests.swift
import CryptoKit
import GRDB
import XCTest
@testable import Scribe

final class AttachmentTextStoreTests: XCTestCase {
    private var dbm: DatabaseManager!
    private var store: AttachmentTextStore!
    private var notes: NoteStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dbm = try DatabaseManager(path: ":memory:")
        store = AttachmentTextStore(dbManager: dbm)
        notes = NoteStore(databaseManager: dbm)
    }

    override func tearDown() {
        store = nil
        notes = nil
        dbm = nil
        super.tearDown()
    }

    private func record(_ path: String, noteId: String?, text: String, hash: String = "h1") -> AttachmentTextRecord {
        AttachmentTextRecord(
            path: path,
            noteId: noteId,
            contentHash: hash,
            fileSize: 10,
            modifiedAt: 100,
            kind: "image",
            text: text,
            recognizedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testMigrationCreatesTables() throws {
        let tables = try dbm.database.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table') ORDER BY name")
        }
        XCTAssertTrue(tables.contains("attachment_text"))
        XCTAssertTrue(tables.contains("attachment_text_fts"))
        let applied = try dbm.database.read { db in
            try DatabaseManager.makeMigrator().appliedMigrations(db)
        }
        XCTAssertTrue(applied.contains("v25_attachment_text"))
    }

    func testUpsertReadBackAndRemove() throws {
        try store.upsert(record("attachments/n1/a.png", noteId: "n1", text: "Invoice 2026"))
        let stored = try XCTUnwrap(try store.record(forPath: "attachments/n1/a.png"))
        XCTAssertEqual(stored.text, "Invoice 2026")
        XCTAssertEqual(stored.noteId, "n1")

        // Re-upserting replaces the FTS row rather than duplicating it.
        try store.upsert(record("attachments/n1/a.png", noteId: "n1", text: "Receipt", hash: "h2"))
        let ids = try dbm.database.read { db in
            try AttachmentTextStore.matchingNoteIds(db, ftsQuery: FTSQuery.escape("invoice"), limit: 10)
        }
        XCTAssertTrue(ids.isEmpty)
        XCTAssertEqual(try store.record(forPath: "attachments/n1/a.png")?.contentHash, "h2")

        try store.touch(path: "attachments/n1/a.png", fileSize: 99, modifiedAt: 555)
        XCTAssertEqual(try store.record(forPath: "attachments/n1/a.png")?.modifiedAt, 555)
        XCTAssertEqual(try store.records(forNoteId: "n1").count, 1)

        try store.remove(paths: ["attachments/n1/a.png"])
        XCTAssertNil(try store.record(forPath: "attachments/n1/a.png"))
        let afterRemove = try dbm.database.read { db in
            try AttachmentTextStore.matchingNoteIds(db, ftsQuery: FTSQuery.escape("receipt"), limit: 10)
        }
        XCTAssertTrue(afterRemove.isEmpty)
    }

    func testNoteSearchFindsTextInsideAttachments() throws {
        let withScan = try notes.createNote(title: "Trip", body: "Photos from the weekend")
        let other = try notes.createNote(title: "Groceries", body: "milk, eggs")
        try store.upsert(record("attachments/\(withScan.id)/ticket.jpg", noteId: withScan.id, text: "BOARDING PASS Gate 42"))

        XCTAssertEqual(try notes.searchNotes(query: "boarding").map(\.id), [withScan.id])
        // Body matches come first, then attachment-only matches, no duplicates.
        try store.upsert(record("attachments/\(other.id)/receipt.png", noteId: other.id, text: "weekend sale milk"))
        let results = try notes.searchNotes(query: "milk").map(\.id)
        XCTAssertEqual(results, [other.id])
        let weekend = try notes.searchNotes(query: "weekend").map(\.id)
        XCTAssertEqual(weekend, [withScan.id, other.id])
    }

    func testLockedNotesAreExcludedFromAttachmentMatches() throws {
        let sealed = try LockedNoteEnvelope.seal("secret", key: SymmetricKey(size: .bits256))
        let locked = try notes.createNote(title: "Locked", body: sealed)
        try store.upsert(record("attachments/\(locked.id)/id-card.png", noteId: locked.id, text: "PASSPORT NUMBER"))
        XCTAssertTrue(try notes.searchNotes(query: "passport").isEmpty)
    }

    func testEmptyTextIsStoredButNotIndexed() throws {
        try store.upsert(record("attachments/n2/blank.png", noteId: "n2", text: "   "))
        XCTAssertNotNil(try store.record(forPath: "attachments/n2/blank.png"))
        let ftsRows = try dbm.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attachment_text_fts") ?? -1
        }
        XCTAssertEqual(ftsRows, 0)
    }

    func testNoteIdFromRelativePath() {
        XCTAssertEqual(AttachmentTextStore.noteId(forRelativePath: "attachments/abc/x.png"), "abc")
        XCTAssertEqual(AttachmentTextStore.noteId(forRelativePath: "attachments/abc/sub/x.png"), "abc")
        XCTAssertNil(AttachmentTextStore.noteId(forRelativePath: "attachments/unfiled/x.png"))
        XCTAssertNil(AttachmentTextStore.noteId(forRelativePath: "attachments/x.png"))
        XCTAssertNil(AttachmentTextStore.noteId(forRelativePath: "Notes/x.png"))
    }
}

final class AttachmentOCRPlannerTests: XCTestCase {

    private func fileStat(_ path: String, size: Int64 = 10, modified: Double = 100) -> AttachmentFileStat {
        AttachmentFileStat(relativePath: path, size: size, modifiedAt: modified)
    }

    private func record(_ path: String, size: Int64 = 10, modified: Double = 100) -> AttachmentTextRecord {
        AttachmentTextRecord(path: path, noteId: nil, contentHash: "h", fileSize: size, modifiedAt: modified,
                             kind: "image", text: "", recognizedAt: Date())
    }

    func testPlanSkipsUnchangedAndQueuesNewOrChangedNewestFirst() {
        let files = [
            fileStat("attachments/a/same.png"),
            fileStat("attachments/a/new.png", modified: 300),
            fileStat("attachments/a/resized.png", size: 20, modified: 100),
            fileStat("attachments/a/touched.png", modified: 200),
        ]
        let records = [
            "attachments/a/same.png": record("attachments/a/same.png"),
            "attachments/a/resized.png": record("attachments/a/resized.png"),
            "attachments/a/touched.png": record("attachments/a/touched.png", modified: 150),
            "attachments/a/deleted.png": record("attachments/a/deleted.png"),
        ]
        let plan = AttachmentOCRPlanner.plan(files: files, records: records, limit: 10)
        XCTAssertEqual(plan.toCheck.map(\.relativePath), [
            "attachments/a/new.png", "attachments/a/touched.png", "attachments/a/resized.png",
        ])
        XCTAssertEqual(plan.removals, ["attachments/a/deleted.png"])
        XCTAssertEqual(plan.remaining, 0)
    }

    func testPlanHonoursTheLimit() {
        let files = (0..<5).map { fileStat("attachments/a/\($0).png", modified: Double($0)) }
        let plan = AttachmentOCRPlanner.plan(files: files, records: [:], limit: 2)
        XCTAssertEqual(plan.toCheck.map(\.relativePath), ["attachments/a/4.png", "attachments/a/3.png"])
        XCTAssertEqual(plan.remaining, 3)
    }

    func testUnchangedHashSkipsRecognition() {
        let existing = record("p")
        XCTAssertTrue(AttachmentOCRPlanner.isUnchanged(record: existing, contentHash: "h"))
        XCTAssertFalse(AttachmentOCRPlanner.isUnchanged(record: existing, contentHash: "other"))
        XCTAssertFalse(AttachmentOCRPlanner.isUnchanged(record: nil, contentHash: "h"))
    }

    func testSHA256Hex() {
        XCTAssertEqual(
            AttachmentOCRPlanner.sha256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testKindForPath() {
        XCTAssertEqual(AttachmentTextRecognizer.kind(forPath: "a/b.PNG"), .image)
        XCTAssertEqual(AttachmentTextRecognizer.kind(forPath: "a/scan.pdf"), .pdf)
        XCTAssertNil(AttachmentTextRecognizer.kind(forPath: "a/notes.md"))
        XCTAssertNil(AttachmentTextRecognizer.kind(forPath: "a/vector.svg"))
    }

    func testAttachmentFilesListsSupportedFilesUnderAttachments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("attachments/note-1", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("photo.png"))
        try Data([1]).write(to: folder.appendingPathComponent("readme.txt"))
        try Data([1]).write(to: folder.appendingPathComponent(".hidden.png"))
        try Data([1]).write(to: root.appendingPathComponent("outside.png"))

        let files = AttachmentOCRIndexer.attachmentFiles(under: root)
        XCTAssertEqual(files.map(\.relativePath), ["attachments/note-1/photo.png"])
        XCTAssertEqual(files.first?.size, 3)
    }
}
