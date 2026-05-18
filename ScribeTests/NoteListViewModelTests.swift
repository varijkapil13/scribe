// ScribeTests/NoteListViewModelTests.swift
import XCTest
import Combine
@testable import Scribe

/// Covers the new staged-deletion flow on `NoteListViewModel`:
///   requestDelete → pendingDelete published → View shows confirm dialog
///   → confirmDelete → store.deleteNote called and pendingDelete cleared.
///
/// The point of staging the delete is to give the View enough info — note
/// title + bound-session count — to warn the user about the cascade before
/// it's irreversible. Tests assert the staging carries that info.
@MainActor
final class NoteListViewModelTests: XCTestCase {
    private var dbm: DatabaseManager!
    private var notes: NoteStore!
    private var transcripts: TranscriptStore!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        try await super.setUp()
        dbm = try DatabaseManager(path: ":memory:")
        notes = NoteStore(databaseManager: dbm)
        transcripts = TranscriptStore(databaseManager: dbm)
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        notes = nil
        transcripts = nil
        dbm = nil
        try await super.tearDown()
    }

    func testRequestDeleteSurfacesNoteTitleAndZeroSessionCount() throws {
        let note = try notes.createNote(title: "Solo note", body: "")
        let vm = NoteListViewModel(store: notes, scope: .all)

        vm.requestDelete(id: note.id)
        let staged = try XCTUnwrap(vm.pendingDelete)
        XCTAssertEqual(staged.noteId, note.id)
        XCTAssertEqual(staged.noteTitle, "Solo note")
        XCTAssertEqual(staged.sessionCount, 0,
                       "No recordings → count is 0; dialog should skip the cascade warning.")
    }

    func testRequestDeleteCountsBoundSessions() throws {
        let note = try notes.createNote(title: "Has recordings", body: "")
        _ = try transcripts.createSession(title: "First", noteId: note.id)
        _ = try transcripts.createSession(title: "Second", noteId: note.id)
        _ = try transcripts.createSession(title: "Third", noteId: note.id)

        let vm = NoteListViewModel(store: notes, scope: .all)
        vm.requestDelete(id: note.id)

        let staged = try XCTUnwrap(vm.pendingDelete)
        XCTAssertEqual(staged.sessionCount, 3)
    }

    func testRequestDeleteSuppressedForMissingNote() {
        let vm = NoteListViewModel(store: notes, scope: .all)
        vm.requestDelete(id: "does-not-exist")
        XCTAssertNil(vm.pendingDelete,
                     "If the note row is already gone the View shouldn't show a dialog.")
    }

    func testConfirmDeleteRemovesNoteAndClearsPendingState() throws {
        let note = try notes.createNote(title: "Bye", body: "")
        let vm = NoteListViewModel(store: notes, scope: .all)
        vm.requestDelete(id: note.id)
        let staged = try XCTUnwrap(vm.pendingDelete)

        let deletedId = vm.confirmDelete(staged)

        XCTAssertEqual(deletedId, note.id)
        XCTAssertNil(vm.pendingDelete, "Pending request is consumed on confirm.")
        XCTAssertNil(try notes.fetchNote(id: note.id))
    }

    func testConfirmDeleteCascadesToBoundSessions() throws {
        let note = try notes.createNote(title: "Has recordings", body: "")
        let session = try transcripts.createSession(title: "Recording", noteId: note.id)

        let vm = NoteListViewModel(store: notes, scope: .all)
        vm.requestDelete(id: note.id)
        let staged = try XCTUnwrap(vm.pendingDelete)
        _ = vm.confirmDelete(staged)

        XCTAssertNil(try transcripts.fetchSession(id: session.id),
                     "Confirm-delete must remove sessions bound to the note.")
    }
}
