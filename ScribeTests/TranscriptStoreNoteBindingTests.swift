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
        let session = try TestHelpers.makeBoundSession(title: "S", notes: notes, transcripts: transcripts)
        try transcripts.bindSession(session.id, toNote: note.id)
        let fetched = try transcripts.fetchSession(id: session.id)
        XCTAssertEqual(fetched?.noteId, note.id)
    }

    func testUnbindSessionForTestingDetaches() throws {
        // unbindSessionForTesting is the only API that can produce a NULL
        // noteId — it lives behind `#if DEBUG` precisely to keep production
        // code from violating the post-v11 invariant.
        let note = try notes.createNote(title: "N", body: "")
        let session = try TestHelpers.makeBoundSession(title: "S", notes: notes, transcripts: transcripts)
        try transcripts.bindSession(session.id, toNote: note.id)
        try transcripts.unbindSessionForTesting(session.id)
        let fetched = try transcripts.fetchSession(id: session.id)
        XCTAssertNil(fetched?.noteId)
    }

    func testFetchSessionsForNoteIdOrdersByCreatedAtDesc() throws {
        let note = try notes.createNote(title: "N", body: "")
        let earlier = Session(title: "First", createdAt: Date(timeIntervalSinceNow: -10))
        let later = Session(title: "Second", createdAt: Date())
        try dbm.database.write {
            try earlier.insert($0)
            try later.insert($0)
        }
        try transcripts.bindSession(earlier.id, toNote: note.id)
        try transcripts.bindSession(later.id, toNote: note.id)
        let list = try transcripts.fetchSessions(forNoteId: note.id)
        XCTAssertEqual(list.map(\.id), [later.id, earlier.id])
    }

    func testFetchSessionsForNoteIdExcludesUnbound() throws {
        let note = try notes.createNote(title: "N", body: "")
        let bound = try TestHelpers.makeBoundSession(title: "Bound", notes: notes, transcripts: transcripts)
        _ = try TestHelpers.makeBoundSession(title: "Unbound", notes: notes, transcripts: transcripts)
        try transcripts.bindSession(bound.id, toNote: note.id)
        let list = try transcripts.fetchSessions(forNoteId: note.id)
        XCTAssertEqual(list.map(\.id), [bound.id])
    }

    func testObserveSessionsForNoteIdEmitsOnBind() throws {
        let note = try notes.createNote(title: "N", body: "")
        let session = try TestHelpers.makeBoundSession(title: "S", notes: notes, transcripts: transcripts)
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

    func testDeleteNoteAlsoDeletesItsSessions() throws {
        let note = try notes.createNote(title: "N", body: "")
        let session = try transcripts.createSession(title: "S", noteId: note.id)

        try notes.deleteNote(id: note.id)

        // Note is gone.
        XCTAssertNil(try notes.fetchNote(id: note.id))
        // Session is gone — transcripts are part of the note.
        XCTAssertNil(try transcripts.fetchSession(id: session.id))
    }

    func testDeleteNoteCascadesThroughSessionToSegments() throws {
        let note = try notes.createNote(title: "N", body: "")
        let session = try transcripts.createSession(title: "S", noteId: note.id)
        // Insert a segment via raw SQL since addSegment may have a different
        // signature. The session FK has ON DELETE CASCADE from migration v1.
        try dbm.database.write {
            try $0.execute(sql: """
                INSERT INTO segments (sessionId, startMs, endMs, speaker, text)
                VALUES (?, 0, 1000, 'you', 'hello')
                """, arguments: [session.id])
        }

        try notes.deleteNote(id: note.id)

        let segCount = try dbm.database.read {
            try Int.fetchOne($0,
                sql: "SELECT COUNT(*) FROM segments WHERE sessionId = ?",
                arguments: [session.id]) ?? -1
        }
        XCTAssertEqual(segCount, 0)
    }
}
