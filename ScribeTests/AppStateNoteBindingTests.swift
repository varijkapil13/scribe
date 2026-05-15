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

        // startSession boots audio capture, which fails in a test bundle. We
        // tolerate that and assert only on the persisted session row's noteId.
        // The bind must happen BEFORE the audio bootstrap so the assertion is
        // meaningful even on failure.
        do {
            try await appState.startSession(title: "Test", noteId: note.id)
        } catch {
            // expected when audio path fails under XCTest
        }

        let bound = try transcripts.fetchSessions(forNoteId: note.id)
        XCTAssertEqual(bound.count, 1, "Session should be persisted and bound to note before audio bootstrap")
        XCTAssertEqual(bound.first?.title, "Test")

        // Best-effort teardown
        await appState.stopSession()
    }

    func testStartSessionWithoutNoteIdLeavesSessionUnbound() async throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let transcripts = TranscriptStore(databaseManager: dbm)
        let appState = AppState(transcriptStore: transcripts)

        do {
            try await appState.startSession(title: "Untracked")
        } catch {
            // ignored
        }

        let all = try transcripts.fetchAllSessions()
        XCTAssertEqual(all.count, 1)
        XCTAssertNil(all.first?.noteId)
        await appState.stopSession()
    }
}
