import XCTest
import GRDB
@testable import Scribe

/// Tests for `TranscriptStore.recoverIncompleteSessions()` — the
/// crash-recovery sweep that runs at app launch.
final class CrashRecoveryTests: XCTestCase {

    private var manager: DatabaseManager!
    private var store: TranscriptStore!
    private var notes: NoteStore!

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: ":memory:")
        store = TranscriptStore(databaseManager: manager)
        notes = NoteStore(databaseManager: manager)
    }

    override func tearDown() {
        notes = nil
        store = nil
        manager = nil
    }

    func testRecoverFinalisesDanglingSessionsWithSegments() throws {
        let session = try TestHelpers.makeBoundSession(title: "Dangling", notes: notes, transcripts: store)
        try store.addSegment(sessionId: session.id, startMs: 0, endMs: 1_000, speaker: "you", text: "first")
        try store.addSegment(sessionId: session.id, startMs: 1_000, endMs: 5_000, speaker: "you", text: "last")

        let count = try store.recoverIncompleteSessions()
        XCTAssertEqual(count, 1)

        let recovered = try XCTUnwrap(store.fetchSession(id: session.id))
        XCTAssertNotNil(recovered.endedAt)
        XCTAssertEqual(recovered.durationSeconds, 5)
    }

    func testRecoverHandlesSessionWithNoSegments() throws {
        let session = try TestHelpers.makeBoundSession(title: "Empty crash", notes: notes, transcripts: store)

        let count = try store.recoverIncompleteSessions()
        XCTAssertEqual(count, 1)

        let recovered = try XCTUnwrap(store.fetchSession(id: session.id))
        XCTAssertNotNil(recovered.endedAt)
        XCTAssertEqual(recovered.durationSeconds, 0)
        XCTAssertEqual(recovered.endedAt, recovered.createdAt)
    }

    func testRecoverIgnoresAlreadyEndedSessions() throws {
        let s1 = try TestHelpers.makeBoundSession(title: "Done", notes: notes, transcripts: store)
        try store.addSegment(sessionId: s1.id, startMs: 0, endMs: 100, speaker: "you", text: "x")
        try store.endSession(id: s1.id)
        let endedAtBefore = try XCTUnwrap(store.fetchSession(id: s1.id)?.endedAt)

        let s2 = try TestHelpers.makeBoundSession(title: "Crashed", notes: notes, transcripts: store)
        try store.addSegment(sessionId: s2.id, startMs: 0, endMs: 2_000, speaker: "you", text: "y")

        let count = try store.recoverIncompleteSessions()
        XCTAssertEqual(count, 1)

        // Already-ended session unchanged.
        let s1Reloaded = try XCTUnwrap(store.fetchSession(id: s1.id))
        XCTAssertEqual(s1Reloaded.endedAt, endedAtBefore)

        // Crashed session now finalized.
        let s2Reloaded = try XCTUnwrap(store.fetchSession(id: s2.id))
        XCTAssertNotNil(s2Reloaded.endedAt)
        XCTAssertEqual(s2Reloaded.durationSeconds, 2)
    }

    func testRecoverIsIdempotent() throws {
        let session = try TestHelpers.makeBoundSession(title: "Once", notes: notes, transcripts: store)
        try store.addSegment(sessionId: session.id, startMs: 0, endMs: 1_000, speaker: "you", text: "hi")

        XCTAssertEqual(try store.recoverIncompleteSessions(), 1)
        // Second call should find nothing left to recover.
        XCTAssertEqual(try store.recoverIncompleteSessions(), 0)
    }

    func testRecoverReturnsZeroOnEmptyDatabase() throws {
        XCTAssertEqual(try store.recoverIncompleteSessions(), 0)
    }
}
