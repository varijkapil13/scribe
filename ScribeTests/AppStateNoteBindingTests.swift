// ScribeTests/AppStateNoteBindingTests.swift
import XCTest
@testable import Scribe

@MainActor
final class AppStateNoteBindingTests: XCTestCase {

    func testStartSessionBindsSessionToProvidedNoteId() async throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let transcripts = TranscriptStore(databaseManager: dbm)
        let notes = NoteStore(databaseManager: dbm)
        let appState = AppState(transcriptStore: transcripts)

        let note = try notes.createNote(title: "My note", body: "")

        // startSession boots speech + audio capture, which usually fails in a
        // test bundle. A failed start rolls back completely (no phantom
        // session row); a successful one leaves the row bound to the note.
        var started = true
        do {
            try await appState.startSession(title: "Test", noteId: note.id)
        } catch {
            // expected when the speech/audio path fails under XCTest
            started = false
        }

        let bound = try transcripts.fetchSessions(forNoteId: note.id)
        if started {
            XCTAssertEqual(bound.count, 1, "Session should be persisted and bound to the note")
            XCTAssertEqual(bound.first?.title, "Test")
        } else {
            XCTAssertEqual(bound.count, 0, "A failed start must delete the session row it created")
            XCTAssertNil(appState.currentSessionId, "A failed start must clear currentSessionId")
            XCTAssertFalse(appState.isTranscribing)
            XCTAssertFalse(appState.isStartingSession)
        }

        // Best-effort teardown
        await appState.stopSession()
    }

    func testStartSessionWithoutNoteIdThrows() async throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let transcripts = TranscriptStore(databaseManager: dbm)
        let appState = AppState(transcriptStore: transcripts)

        do {
            try await appState.startSession(title: "No note")
            XCTFail("Expected startSession to throw AppStateError.sessionRequiresNoteId")
        } catch AppStateError.sessionRequiresNoteId {
            // expected
        } catch {
            XCTFail("Expected AppStateError.sessionRequiresNoteId, got \(error)")
        }

        // No session row should have been persisted.
        let all = try transcripts.fetchAllSessions()
        XCTAssertEqual(all.count, 0)
    }

    func testResolveNoteContextUsesOpenNoteWhenSelected() throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let notes = NoteStore(databaseManager: dbm)
        let note = try notes.createNote(title: "Existing", body: "")

        let resolved = try AppDelegate.resolveNoteContext(
            selection: .note(note.id),
            noteStore: notes,
            now: Date()
        )

        XCTAssertEqual(resolved.noteId, note.id)
        XCTAssertEqual(resolved.didCreateNote, false)
    }

    func testResolveNoteContextAutoCreatesNoteWhenNothingSelected() throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let notes = NoteStore(databaseManager: dbm)

        let fixedDate = Date(timeIntervalSince1970: 1_715_000_000)
        let resolved = try AppDelegate.resolveNoteContext(
            selection: nil,
            noteStore: notes,
            now: fixedDate
        )

        XCTAssertTrue(resolved.didCreateNote)
        let created = try notes.fetchNote(id: resolved.noteId)
        XCTAssertNotNil(created)
        XCTAssertTrue(created!.title.hasPrefix("Meeting on"),
                      "Got: \(created!.title)")
    }

    func testResolveNoteContextAutoCreatesNoteWhenNonNoteSelectionActive() throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let notes = NoteStore(databaseManager: dbm)

        let resolved = try AppDelegate.resolveNoteContext(
            selection: .tasks(.inbox),
            noteStore: notes,
            now: Date()
        )

        XCTAssertFalse(resolved.noteId.isEmpty)
        XCTAssertTrue(resolved.didCreateNote)
    }

    // MARK: - NoteContextError surfacing (review item #12)

    func testNoteContextErrorIncludesUnderlyingMessage() {
        // resolveNoteContext wraps any createNote failure in
        // NoteContextError.autoCreateFailed so the user sees a meaningful
        // message ("disk full…") instead of the downstream generic
        // AppStateError.sessionRequiresNoteId.
        struct DiskFullStub: LocalizedError {
            var errorDescription: String? { "disk is full" }
        }
        let wrapped = NoteContextError.autoCreateFailed(underlying: DiskFullStub())
        let message = wrapped.errorDescription ?? ""
        XCTAssertTrue(message.contains("disk is full"),
                      "Underlying error message must be preserved. Got: \(message)")
        XCTAssertTrue(message.lowercased().contains("meeting note"),
                      "Wrapped error should explain it's about the auto-created meeting note. Got: \(message)")
    }
}
