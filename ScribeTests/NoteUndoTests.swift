import XCTest
@testable import Scribe

/// Edit › Undo Delete Note: `NoteStore.restoreDeletedNote` and the `NoteUndo`
/// safety policy (never offer undo when recordings/attachments were destroyed).
final class NoteUndoTests: XCTestCase {

    private var tempRoot: URL!
    private var dbManager: DatabaseManager!
    private var store: NoteStore!
    private var transcripts: TranscriptStore!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        dbManager = try DatabaseManager(path: ":memory:")
        store = NoteStore(databaseManager: dbManager,
                          fileStore: NoteFileStore(directory: NotesDirectory(root: tempRoot)))
        transcripts = TranscriptStore(databaseManager: dbManager)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        store = nil
        transcripts = nil
        dbManager = nil
    }

    func testPolicy() {
        XCTAssertTrue(NoteUndo.canUndoDelete(sessionCount: 0, hasAttachments: false))
        XCTAssertFalse(NoteUndo.canUndoDelete(sessionCount: 1, hasAttachments: false))
        XCTAssertFalse(NoteUndo.canUndoDelete(sessionCount: 0, hasAttachments: true))
    }

    func testHasAttachments() throws {
        let noteId = "note-with-files"
        XCTAssertFalse(NoteUndo.hasAttachments(noteId: noteId, root: tempRoot))
        let dir = tempRoot.appendingPathComponent("attachments/\(noteId)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertFalse(NoteUndo.hasAttachments(noteId: noteId, root: tempRoot), "Empty folder holds nothing")
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.png"))
        XCTAssertTrue(NoteUndo.hasAttachments(noteId: noteId, root: tempRoot))
    }

    func testNoSnapshotForNoteWithRecordings() throws {
        let note = try store.createNote(title: "Standup", body: "notes")
        _ = try transcripts.createSession(title: "Recording", noteId: note.id)
        XCTAssertNil(NoteUndo.restorableSnapshot(noteId: note.id, store: store, attachmentsRoot: tempRoot))
    }

    func testDeleteAndRestoreKeepsIdBodyTagsAndNotebook() throws {
        let notebook = try store.createNotebook(name: "Work")
        let created = try store.createNote(title: "Plan", body: "Ship **it**", tags: ["q3"],
                                           notebookId: notebook.id)
        let snapshot = try XCTUnwrap(NoteUndo.restorableSnapshot(noteId: created.id, store: store,
                                                                 attachmentsRoot: tempRoot))
        try store.deleteNote(id: created.id)
        XCTAssertNil(try store.fetchNote(id: created.id))

        try store.restoreDeletedNote(snapshot.note, tags: snapshot.tags)

        let restored = try XCTUnwrap(store.fetchNote(id: created.id))
        XCTAssertEqual(restored.title, "Plan")
        XCTAssertEqual(restored.body, "Ship **it**")
        XCTAssertEqual(restored.notebookId, notebook.id)
        XCTAssertEqual(try store.tags(for: created.id), ["q3"])
        XCTAssertEqual(try store.searchNotes(query: "Ship").map(\.id), [created.id],
                       "Full-text index is rebuilt")
    }

    func testRestoreRebuildsOutgoingLinks() throws {
        let target = try store.createNote(title: "Target", body: "")
        let source = try store.createNote(title: "Source", body: "")
        var withLink = try XCTUnwrap(store.fetchNote(id: source.id))
        withLink.body = "See [[Target]]"
        try store.updateNote(withLink, tags: [])
        let snapshot = try XCTUnwrap(NoteUndo.restorableSnapshot(noteId: source.id, store: store,
                                                                 attachmentsRoot: tempRoot))

        try store.deleteNote(id: source.id)
        XCTAssertTrue(try store.backlinks(for: target.id).isEmpty)

        try store.restoreDeletedNote(snapshot.note, tags: snapshot.tags)
        XCTAssertEqual(try store.backlinks(for: target.id).map(\.id), [source.id])
    }

    @MainActor
    func testDeleteRegistersUndoAndRedo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(databaseManager: try DatabaseManager(path: ":memory:"),
                              fileStore: NoteFileStore(directory: NotesDirectory(root: root)))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let note = try store.createNote(title: "Scratch", body: "temp")

        undoManager.beginUndoGrouping()
        try NoteUndo.deleteNote(id: note.id, store: store, undoManager: undoManager)
        undoManager.endUndoGrouping()
        XCTAssertNil(try store.fetchNote(id: note.id))
        XCTAssertEqual(undoManager.undoActionName, "Delete Note")

        undoManager.undo()
        XCTAssertEqual(try store.fetchNote(id: note.id)?.title, "Scratch")
        undoManager.redo()
        XCTAssertNil(try store.fetchNote(id: note.id))
    }
}
