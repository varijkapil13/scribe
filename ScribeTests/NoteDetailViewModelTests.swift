// ScribeTests/NoteDetailViewModelTests.swift
import XCTest
import Combine
@testable import Scribe

@MainActor
final class NoteDetailViewModelTests: XCTestCase {
    private var dbm: DatabaseManager!
    private var notes: NoteStore!
    private var transcripts: TranscriptStore!

    override func setUp() async throws {
        try await super.setUp()
        dbm = try DatabaseManager(path: ":memory:")
        notes = NoteStore(databaseManager: dbm)
        transcripts = TranscriptStore(databaseManager: dbm)
    }

    override func tearDown() async throws {
        notes = nil
        transcripts = nil
        dbm = nil
        try await super.tearDown()
    }

    func testSessionsExposesBoundSessions() async throws {
        let note = try notes.createNote(title: "N", body: "")
        let session = try transcripts.createSession(title: "S")
        try transcripts.bindSession(session.id, toNote: note.id)

        let vm = NoteDetailViewModel(
            note: note,
            store: notes,
            transcriptStore: transcripts,
            onNavigate: { _ in }
        )

        // Wait for the async observation to deliver.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(vm.sessions.map(\.id), [session.id])
    }

    func testSessionsEmptyWhenNoneBound() async throws {
        let note = try notes.createNote(title: "N", body: "")
        let vm = NoteDetailViewModel(
            note: note,
            store: notes,
            transcriptStore: transcripts,
            onNavigate: { _ in }
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(vm.sessions.count, 0)
    }
}
