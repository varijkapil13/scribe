// ScribeTests/NoteImportWriterTests.swift
import XCTest
@testable import Scribe

/// The import writer against an in-memory database and a temp vault: never
/// overwrites, dedupes titles, saves attachments, creates notebooks.
final class NoteImportWriterTests: XCTestCase {
    private var dbm: DatabaseManager!
    private var notes: NoteStore!
    private var fileStore: NoteFileStore!
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dbm = try DatabaseManager(path: ":memory:")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportWriter-\(UUID().uuidString)", isDirectory: true)
        fileStore = NoteFileStore(directory: NotesDirectory(root: root))
        notes = NoteStore(databaseManager: dbm, fileStore: fileStore)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        notes = nil
        fileStore = nil
        dbm = nil
        root = nil
        try super.tearDownWithError()
    }

    private func makeWriter() -> NoteImportWriter {
        NoteImportWriter(noteStore: notes, fileStore: fileStore, dbManager: dbm, attachmentsRoot: root)
    }

    private func importedIds(_ summary: NoteImportSummary) -> [String] {
        summary.items.compactMap { item in
            if case .imported(let noteId, _, _) = item.outcome { return noteId }
            return nil
        }
    }

    func testExistingTitlesAreNeverOverwrittenAndGetSuffixes() throws {
        let existing = try notes.createNote(title: "Ideas", body: "original body")

        var summary = NoteImportSummary(sourceLabel: "Test")
        makeWriter().write([
            ImportedNoteDraft(title: "Ideas", body: "imported one"),
            ImportedNoteDraft(title: "ideas", body: "imported two"),
            ImportedNoteDraft(title: "Fresh", body: "new"),
        ], into: &summary)

        XCTAssertEqual(summary.importedCount, 3)
        XCTAssertEqual(summary.renamedCount, 2)
        XCTAssertEqual(summary.failedCount, 0)

        let original = try XCTUnwrap(try notes.fetchNote(id: existing.id))
        XCTAssertEqual(original.title, "Ideas")
        XCTAssertEqual(original.body, "original body")

        let titles = try notes.fetchAllNotes().map(\.title).sorted()
        XCTAssertEqual(titles, ["Fresh", "Ideas", "Ideas 2", "ideas 3"])
        XCTAssertEqual(summary.headline, "Imported 3 notes (2 renamed to keep titles unique).")
    }

    func testAttachmentsTagsDatesAndNotebooks() throws {
        var collector = ImportAttachmentCollector()
        let placeholder = collector.register(ImportedAttachmentSource(
            content: .data(Data([1, 2, 3])), filename: "Beach Photo.png", mimeType: "image/png"
        ))
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let updated = Date(timeIntervalSince1970: 1_700_086_400)
        let draft = ImportedNoteDraft(
            title: "Trip",
            body: "Look: ![beach](\(placeholder))",
            tags: ["#Summer Fun", "travel"],
            createdAt: created,
            updatedAt: updated,
            notebookPath: ["Imports", "Travel"],
            attachments: collector.attachments,
            sourceName: "trip.md"
        )
        var summary = NoteImportSummary(sourceLabel: "Test")
        makeWriter().write([draft], into: &summary)

        XCTAssertEqual(summary.attachmentsSaved, 1)
        XCTAssertEqual(summary.notebooksCreated, 2)
        let noteId = try XCTUnwrap(importedIds(summary).first)
        let note = try XCTUnwrap(try notes.fetchNote(id: noteId))
        XCTAssertEqual(note.body, "Look: ![beach](attachments/\(noteId)/Beach-Photo.png)")
        XCTAssertEqual(note.createdAt, created)
        XCTAssertEqual(note.updatedAt, updated)
        XCTAssertEqual(Set(try notes.tags(for: noteId)), ["summer-fun", "travel"])
        let saved = root.appendingPathComponent("attachments/\(noteId)/Beach-Photo.png")
        XCTAssertEqual(try Data(contentsOf: saved), Data([1, 2, 3]))

        let notebooks = try notes.fetchAllNotebooks()
        let travel = try XCTUnwrap(notebooks.first { $0.name == "Travel" })
        let imports = try XCTUnwrap(notebooks.first { $0.name == "Imports" })
        XCTAssertEqual(travel.parentId, imports.id)
        XCTAssertEqual(note.notebookId, travel.id)

        // A second import reuses the notebooks instead of duplicating them.
        var second = NoteImportSummary(sourceLabel: "Test")
        makeWriter().write([ImportedNoteDraft(title: "Trip", body: "again", notebookPath: ["imports", "travel"])], into: &second)
        XCTAssertEqual(second.notebooksCreated, 0)
        XCTAssertEqual(try notes.fetchAllNotebooks().count, 2)
    }

    func testFailedAttachmentFallsBackToItsFileName() throws {
        var collector = ImportAttachmentCollector()
        let missing = root.appendingPathComponent("does-not-exist.png")
        let placeholder = collector.register(ImportedAttachmentSource(content: .file(missing), filename: "my pic.png", mimeType: nil))
        var summary = NoteImportSummary(sourceLabel: "Test")
        makeWriter().write([
            ImportedNoteDraft(title: "Broken", body: "![x](\(placeholder))", attachments: collector.attachments),
        ], into: &summary)
        XCTAssertEqual(summary.attachmentsFailed, 1)
        let noteId = try XCTUnwrap(importedIds(summary).first)
        XCTAssertEqual(try notes.fetchNote(id: noteId)?.body, "![x](my%20pic.png)")
    }

    func testCancellationStopsBeforeTheNextNote() {
        var summary = NoteImportSummary(sourceLabel: "Test")
        makeWriter().write(
            [ImportedNoteDraft(title: "A", body: "a"), ImportedNoteDraft(title: "B", body: "b")],
            into: &summary,
            isCancelled: { true }
        )
        XCTAssertEqual(summary.importedCount, 0)
        XCTAssertEqual(summary.warnings.count, 1)
    }

    func testCleanTag() {
        XCTAssertEqual(NoteImportWriter.cleanTag("##Deep Work "), "Deep-Work")
        XCTAssertEqual(NoteImportWriter.cleanTag("plain"), "plain")
    }

    func testSummaryHeadline() {
        var summary = NoteImportSummary(sourceLabel: "X")
        summary.items = [
            NoteImportItemResult(sourceName: "a", outcome: .imported(noteId: "1", title: "A", renamed: false)),
            NoteImportItemResult(sourceName: "b", outcome: .failed(reason: "bad")),
        ]
        summary.attachmentsFailed = 2
        XCTAssertEqual(summary.headline, "Imported 1 note, 1 failed, 2 attachments couldn't be saved.")
        XCTAssertEqual(summary.firstImportedNoteId, "1")
    }
}
