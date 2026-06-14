// ScribeTests/NoteDetailViewModelTests.swift
import XCTest
import Combine
@testable import Scribe

@MainActor
final class NoteDetailViewModelTests: XCTestCase {
    private var dbm: DatabaseManager!
    private var notes: NoteStore!
    private var transcripts: TranscriptStore!
    private var tasks: TaskStore!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        try await super.setUp()
        dbm = try DatabaseManager(path: ":memory:")
        notes = NoteStore(databaseManager: dbm)
        transcripts = TranscriptStore(databaseManager: dbm)
        tasks = TaskStore(databaseManager: dbm)
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        notes = nil
        transcripts = nil
        tasks = nil
        dbm = nil
        try await super.tearDown()
    }

    /// Builds a fully-injected VM. Crucially passes `taskStore: tasks` so the
    /// VM never instantiates `TaskStore.shared` (which opens the on-disk
    /// `DatabaseManager.shared`) — keeping the test hermetic.
    private func makeVM(_ note: Note) -> NoteDetailViewModel {
        NoteDetailViewModel(
            note: note,
            store: notes,
            transcriptStore: transcripts,
            taskStore: tasks,
            onNavigate: { _ in }
        )
    }

    func testSessionsExposesBoundSessions() async throws {
        let note = try notes.createNote(title: "N", body: "")
        let session = try transcripts.createSession(title: "S", noteId: note.id)

        let vm = makeVM(note)

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
        let vm = makeVM(note)

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
        let vm = makeVM(note)

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

    // MARK: - Tags (Slice C1)

    func testAddTagNormalisesAndDedupes() async throws {
        let note = try notes.createNote(title: "N", body: "")
        let vm = makeVM(note)
        vm.addTag("  #Work ")   // trims, strips '#', lowercases → "work"
        vm.addTag("work")       // duplicate after normalisation → ignored
        vm.addTag("   ")        // blank → ignored
        XCTAssertEqual(vm.tags, ["work"])
        XCTAssertTrue(vm.isDirty)
    }

    func testRemoveTag() async throws {
        let note = try notes.createNote(title: "N", body: "")
        let vm = makeVM(note)
        vm.addTag("alpha")
        vm.addTag("beta")
        vm.removeTag("alpha")
        XCTAssertEqual(vm.tags, ["beta"])
    }

    func testSavePersistsTags() async throws {
        let note = try notes.createNote(title: "N", body: "")
        let vm = makeVM(note)
        vm.addTag("project")
        vm.save()
        XCTAssertFalse(vm.isDirty, "save() should clear the dirty flag on success")
        XCTAssertEqual(try notes.tags(for: note.id), ["project"])
    }

    func testTagSuggestionsExcludeAppliedAndRankPrefix() async throws {
        // Seed the store's tag vocabulary.
        _ = try notes.createNote(title: "A", body: "", tags: ["work", "workout", "personal"])
        let note = try notes.createNote(title: "N", body: "")
        let vm = makeVM(note)
        vm.addTag("work")   // applied → must be excluded from suggestions

        let suggestions = vm.tagSuggestions("wor")
        XCTAssertFalse(suggestions.contains("work"), "applied tag must be excluded")
        XCTAssertTrue(suggestions.contains("workout"), "prefix match must be suggested")
        XCTAssertFalse(suggestions.contains("personal"), "non-matching tag must be excluded")
    }
}
