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
    /// Temp vault root for the disk-backed file store used by the property
    /// round-trip tests. `nil` for the logic-only tests above (no disk mirror).
    private var tempRoot: URL?
    private var fileStore: NoteFileStore?

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
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil
        fileStore = nil
        try await super.tearDown()
    }

    /// Swaps `notes` for a disk-backed store (temp dir + in-memory DB) so the
    /// property load/save path — which reads/writes frontmatter `extra` on the
    /// `.md` file — has somewhere to persist. Used only by the property tests.
    private func useDiskBackedStore() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = NoteFileStore(directory: NotesDirectory(root: root))
        tempRoot = root
        fileStore = store
        notes = NoteStore(databaseManager: dbm, fileStore: store)
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
        expectation.assertForOverFulfill = false  // publisher may deliver more than once
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
        // (and stayed empty). `$sessions` emits the initial value AND the GRDB
        // observation's delivery, so the sink can fulfill more than once —
        // tolerate it (otherwise XCTest raises an NSException that crashes the
        // whole test process, which made this flaky in CI).
        let expectation = self.expectation(description: "initial empty observation")
        expectation.assertForOverFulfill = false
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
        expectation.assertForOverFulfill = false  // publisher may deliver more than once
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

    // MARK: - Properties (frontmatter round-trip)

    /// Writes the `.md` frontmatter for a freshly created note's id, injecting
    /// the given `extra` lines, then returns the (now disk-backed) note.
    /// Mirrors how an external editor / earlier save would have left the file.
    private func seedNoteWithExtra(_ extra: [FrontmatterEntry], body: String = "Body") throws -> Note {
        let note = try notes.createNote(title: "Props", body: body)
        let url = try XCTUnwrap(try fileStore?.findURL(for: note.id))
        var file = try XCTUnwrap(fileStore?.read(at: url))
        file.frontmatter.extra = extra
        _ = try fileStore?.write(file)
        return note
    }

    func testLoadPropertiesFromFrontmatter() throws {
        useDiskBackedStore()
        let note = try seedNoteWithExtra([
            FrontmatterEntry(key: "status", value: "doing"),
            FrontmatterEntry(key: "priority", value: "2"),
            FrontmatterEntry(key: "starred", value: "true"),
        ])

        let vm = makeVM(note)

        XCTAssertEqual(vm.properties.map(\.key), ["status", "priority", "starred"])
        XCTAssertEqual(vm.properties.first { $0.key == "priority" }?.value, .number(2))
        XCTAssertEqual(vm.properties.first { $0.key == "starred" }?.value, .checkbox(true))
    }

    func testLoadPropertiesEmptyWhenNoExtra() throws {
        useDiskBackedStore()
        let note = try notes.createNote(title: "Bare", body: "")
        let vm = makeVM(note)
        XCTAssertTrue(vm.properties.isEmpty)
    }

    func testUpdatePropertiesPersistsToFrontmatterAndRoundTrips() throws {
        useDiskBackedStore()
        let note = try notes.createNote(title: "Edit me", body: "The body stays.")
        let vm = makeVM(note)

        vm.updateProperties([
            NoteProperty(key: "status", value: .select("done")),
            NoteProperty(key: "count", value: .number(3)),
            NoteProperty(key: "topics", value: .list(["swift", "macos"])),
        ])

        // Persisted to disk: re-read the file's frontmatter directly.
        let url = try XCTUnwrap(try fileStore?.findURL(for: note.id))
        let file = try XCTUnwrap(fileStore?.read(at: url))
        XCTAssertEqual(file.frontmatter.extraValue(forKey: "status"), "done")
        XCTAssertEqual(file.frontmatter.extraValue(forKey: "count"), "3")
        XCTAssertEqual(file.frontmatter.extraValue(forKey: "topics"), "[swift, macos]")
        // Body preserved.
        XCTAssertEqual(file.body, "The body stays.")

        // Round-trips back through a fresh VM load.
        let reloaded = makeVM(try XCTUnwrap(notes.fetchNote(id: note.id)))
        XCTAssertEqual(reloaded.properties.first { $0.key == "status" }?.value, .select("done"))
        XCTAssertEqual(reloaded.properties.first { $0.key == "count" }?.value, .number(3))
        XCTAssertEqual(reloaded.properties.first { $0.key == "topics" }?.value, .list(["swift", "macos"]))
    }

    func testUpdatePropertiesDropsEmptyValues() throws {
        useDiskBackedStore()
        let note = try seedNoteWithExtra([FrontmatterEntry(key: "status", value: "doing")])
        let vm = makeVM(note)

        // Clearing status to empty + adding a non-empty key.
        vm.updateProperties([
            NoteProperty(key: "status", value: .select("")),
            NoteProperty(key: "owner", value: .text("varij")),
        ])

        // Empty `status` dropped; `owner` kept — both on disk and in the bound list.
        let url = try XCTUnwrap(try fileStore?.findURL(for: note.id))
        let file = try XCTUnwrap(fileStore?.read(at: url))
        XCTAssertNil(file.frontmatter.extraValue(forKey: "status"))
        XCTAssertEqual(file.frontmatter.extraValue(forKey: "owner"), "varij")
        XCTAssertEqual(vm.properties.map(\.key), ["owner"])
    }

    func testUpdatePropertiesPreservesReservedExtras() throws {
        useDiskBackedStore()
        // `font` is a reserved extra (per-note typeface) the property pane
        // must not surface or clobber.
        let note = try seedNoteWithExtra([
            FrontmatterEntry(key: "font", value: "serif"),
            FrontmatterEntry(key: "status", value: "doing"),
        ])
        let vm = makeVM(note)
        XCTAssertEqual(vm.properties.map(\.key), ["status"], "reserved `font` must not surface as a property")

        vm.updateProperties([NoteProperty(key: "status", value: .select("done"))])

        let url = try XCTUnwrap(try fileStore?.findURL(for: note.id))
        let file = try XCTUnwrap(fileStore?.read(at: url))
        XCTAssertEqual(file.frontmatter.extraValue(forKey: "font"), "serif", "reserved extra preserved")
        XCTAssertEqual(file.frontmatter.extraValue(forKey: "status"), "done")
    }

    func testPropertyOptionSuggestionsAggregatesSelectAndList() throws {
        useDiskBackedStore()
        let note = try seedNoteWithExtra([
            FrontmatterEntry(key: "status", value: "doing"),
            FrontmatterEntry(key: "topics", value: "[swift, macos]"),
        ])
        let vm = makeVM(note)
        XCTAssertEqual(vm.propertyOptionSuggestions["status"], ["doing"])
        XCTAssertEqual(vm.propertyOptionSuggestions["topics"], ["macos", "swift"])
    }
}
