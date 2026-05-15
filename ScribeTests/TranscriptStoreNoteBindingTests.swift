// ScribeTests/TranscriptStoreNoteBindingTests.swift
import XCTest
import Combine
@testable import Scribe

final class TranscriptStoreNoteBindingTests: XCTestCase {
    private var dbm: DatabaseManager!
    private var transcripts: TranscriptStore!
    private var notes: NoteStore!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        dbm = try! DatabaseManager(path: ":memory:")
        transcripts = TranscriptStore(databaseManager: dbm)
        notes = NoteStore(databaseManager: dbm)
    }

    override func tearDown() {
        cancellables.removeAll()
        transcripts = nil
        notes = nil
        dbm = nil
        super.tearDown()
    }

    func testBindSessionAttachesNoteId() throws {
        let note = try notes.createNote(title: "N", body: "")
        let session = try transcripts.createSession(title: "S")
        try transcripts.bindSession(session.id, toNote: note.id)
        let fetched = try transcripts.fetchSession(id: session.id)
        XCTAssertEqual(fetched?.noteId, note.id)
    }

    func testBindSessionToNilDetaches() throws {
        let note = try notes.createNote(title: "N", body: "")
        let session = try transcripts.createSession(title: "S")
        try transcripts.bindSession(session.id, toNote: note.id)
        try transcripts.bindSession(session.id, toNote: nil)
        let fetched = try transcripts.fetchSession(id: session.id)
        XCTAssertNil(fetched?.noteId)
    }

    func testFetchSessionsForNoteIdOrdersByCreatedAtDesc() throws {
        let note = try notes.createNote(title: "N", body: "")
        let s1 = try transcripts.createSession(title: "First")
        // Sleep 10 ms so s2 gets a strictly later createdAt timestamp.
        Thread.sleep(forTimeInterval: 0.01)
        let s2 = try transcripts.createSession(title: "Second")
        try transcripts.bindSession(s1.id, toNote: note.id)
        try transcripts.bindSession(s2.id, toNote: note.id)
        let list = try transcripts.fetchSessions(forNoteId: note.id)
        XCTAssertEqual(list.map(\.id), [s2.id, s1.id])
    }

    func testFetchSessionsForNoteIdExcludesUnbound() throws {
        let note = try notes.createNote(title: "N", body: "")
        let bound = try transcripts.createSession(title: "Bound")
        _ = try transcripts.createSession(title: "Unbound")
        try transcripts.bindSession(bound.id, toNote: note.id)
        let list = try transcripts.fetchSessions(forNoteId: note.id)
        XCTAssertEqual(list.map(\.id), [bound.id])
    }

    func testObserveSessionsForNoteIdEmitsOnBind() throws {
        let note = try notes.createNote(title: "N", body: "")
        let session = try transcripts.createSession(title: "S")
        let expectation = self.expectation(description: "observation emits after bind")
        expectation.expectedFulfillmentCount = 2  // initial empty + post-bind

        var emissions: [[Session]] = []
        transcripts.observeSessions(forNoteId: note.id)
            .sink(receiveCompletion: { _ in },
                  receiveValue: { value in
                emissions.append(value)
                expectation.fulfill()
            })
            .store(in: &cancellables)

        let sessionId = session.id
        let noteId = note.id
        let store = transcripts!
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            try? store.bindSession(sessionId, toNote: noteId)
        }

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(emissions.first?.count, 0)
        XCTAssertEqual(emissions.last?.count, 1)
        XCTAssertEqual(emissions.last?.first?.id, session.id)
    }
}
