// ScribeTests/NoteDetailViewModelTests.swift
import XCTest
import Combine
@testable import Scribe

@MainActor
final class NoteDetailViewModelTests: XCTestCase {
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

    func testSessionsExposesBoundSessions() async throws {
        let note = try notes.createNote(title: "N", body: "")
        let session = try transcripts.createSession(title: "S", noteId: note.id)

        let vm = NoteDetailViewModel(
            note: note,
            store: notes,
            transcriptStore: transcripts,
            onNavigate: { _ in }
        )

        let expectation = self.expectation(description: "sessions delivered")
        vm.$sessions
            .dropFirst()  // skip the initial empty value the @Published property emits
            .sink { sessions in
                if sessions.contains(where: { $0.id == session.id }) {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        await fulfillment(of: [expectation], timeout: 2.0)
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

        // Allow at least one observation emission so we know the publisher fired
        // (and stayed empty).
        let expectation = self.expectation(description: "initial empty observation")
        vm.$sessions
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)
        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(vm.sessions.count, 0)
    }

    func testCachedInnerVMSeesSummaryFromInjectedStore() async throws {
        let note = try notes.createNote(title: "Project kickoff", body: "")
        let session = try transcripts.createSession(title: "Kickoff", noteId: note.id)

        let summary = MeetingSummary(
            id: UUID(),
            sessionId: session.id,
            summary: "Discussed scope and risks.",
            keyDecisions: ["Use Swift 6"],
            actionItems: [],
            keyTopics: [],
            followUpQuestions: [],
            createdAt: Date()
        )
        try transcripts.saveSummary(summary)

        // Build the VM with injected stores.
        let vm = NoteDetailViewModel(
            note: note,
            store: notes,
            transcriptStore: transcripts,
            onNavigate: { _ in }
        )

        // Wait for the observation to deliver the bound session.
        let expectation = self.expectation(description: "sessions delivered")
        vm.$sessions
            .dropFirst()
            .sink { sessions in
                if sessions.contains(where: { $0.id == session.id }) {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)
        await fulfillment(of: [expectation], timeout: 2.0)

        // Resolve the cached inner VM and ask it to load summary state.
        let inner = vm.transcriptDetailViewModel(for: session)
        inner.loadSummary()

        // The summary must be visible — proving the inner VM reads from the
        // same injected `transcripts` store, not the on-disk `.shared` default.
        XCTAssertNotNil(inner.meetingSummary, "Inner VM should see the summary persisted to the injected store")
        XCTAssertEqual(inner.meetingSummary?.summary, "Discussed scope and risks.")
        XCTAssertEqual(inner.meetingSummary?.keyDecisions, ["Use Swift 6"])
    }
}
