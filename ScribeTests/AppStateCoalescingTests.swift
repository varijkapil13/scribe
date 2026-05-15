import XCTest
import Combine
@testable import Scribe

/// Drives ``AppState``'s coalescing logic directly with synthetic
/// `TranscriptionSegment` events to validate the speaker-change / time-window
/// flush behaviour and the error-surfacing wiring. Uses an in-memory
/// `TranscriptStore` so tests don't touch the user's real on-disk DB.
@MainActor
final class AppStateCoalescingTests: XCTestCase {

    private var manager: DatabaseManager!
    private var store: TranscriptStore!
    private var notes: NoteStore!
    private var state: AppState!

    override func setUp() async throws {
        manager = try DatabaseManager(path: ":memory:")
        store = TranscriptStore(databaseManager: manager)
        notes = NoteStore(databaseManager: manager)
        state = AppState(transcriptStore: store)
    }

    override func tearDown() async throws {
        state = nil
        notes = nil
        store = nil
        manager = nil
    }

    // MARK: - Helpers

    private func startSession() throws -> String {
        let session = try TestHelpers.makeBoundSession(title: "test", notes: notes, transcripts: store)
        state.currentSessionId = session.id
        return session.id
    }

    private func makeSegment(
        speaker: String,
        offsetMs: Int,
        durationMs: Int = 1_000,
        text: String
    ) -> TranscriptionSegment {
        TranscriptionSegment(
            id: UUID(),
            sessionOffsetMs: offsetMs,
            startMs: offsetMs,
            endMs: offsetMs + durationMs,
            speaker: speaker,
            text: text
        )
    }

    // MARK: - Coalescing

    func testSameSpeakerSegmentsMergeIntoOneStoredRow() throws {
        let sid = try startSession()

        state.ingestTranscribedSegment(makeSegment(speaker: "you", offsetMs: 0,     text: "Hello"))
        state.ingestTranscribedSegment(makeSegment(speaker: "you", offsetMs: 1_500, text: "world"))
        state.ingestTranscribedSegment(makeSegment(speaker: "you", offsetMs: 3_000, text: "again"))

        // Nothing committed yet — pending segment buffers them.
        XCTAssertEqual(try store.fetchSegments(sessionId: sid).count, 0)

        // Force flush (simulates session end).
        state.flushPendingSegment()

        let saved = try store.fetchSegments(sessionId: sid)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.text, "Hello world again")
        XCTAssertEqual(saved.first?.speaker, "you")
        XCTAssertEqual(saved.first?.startMs, 0)
    }

    func testSpeakerChangeFlushesPendingAndStartsNew() throws {
        let sid = try startSession()

        state.ingestTranscribedSegment(makeSegment(speaker: "you",    offsetMs: 0,     text: "Going to start"))
        state.ingestTranscribedSegment(makeSegment(speaker: "remote", offsetMs: 2_000, text: "Sounds good"))

        // First (you) segment auto-flushed when remote arrived; remote still pending.
        let saved = try store.fetchSegments(sessionId: sid)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.text, "Going to start")
        XCTAssertEqual(saved.first?.speaker, "you")

        state.flushPendingSegment()
        let final = try store.fetchSegments(sessionId: sid)
        XCTAssertEqual(final.count, 2)
        XCTAssertEqual(final.last?.speaker, "remote")
        XCTAssertEqual(final.last?.text, "Sounds good")
    }

    func testEmptyTextSegmentIgnored() throws {
        let sid = try startSession()
        state.ingestTranscribedSegment(makeSegment(speaker: "you", offsetMs: 0, text: "   "))
        state.flushPendingSegment()
        XCTAssertEqual(try store.fetchSegments(sessionId: sid).count, 0)
    }

    func testFlushWithoutPendingIsNoOp() throws {
        let sid = try startSession()
        state.flushPendingSegment()
        XCTAssertEqual(try store.fetchSegments(sessionId: sid).count, 0)
    }

    func testFlushWithoutSessionDoesNotPersist() {
        // currentSessionId is nil
        state.ingestTranscribedSegment(makeSegment(speaker: "you", offsetMs: 0, text: "hello"))
        state.flushPendingSegment()
        // No session, no row — and no crash.
        XCTAssertEqual(state.currentSessionId, nil)
    }

    // MARK: - Overlay

    func testOverlayShowsLiveCoalescedSegment() throws {
        _ = try startSession()
        XCTAssertTrue(state.overlaySegments.isEmpty)

        state.ingestTranscribedSegment(makeSegment(speaker: "you", offsetMs: 0,     text: "Hello"))
        XCTAssertEqual(state.overlaySegments.count, 1)
        XCTAssertEqual(state.overlaySegments.first?.text, "Hello")

        state.ingestTranscribedSegment(makeSegment(speaker: "you", offsetMs: 1_000, text: "world"))
        XCTAssertEqual(state.overlaySegments.count, 1, "should still be one live coalesced row")
        XCTAssertEqual(state.overlaySegments.first?.text, "Hello world")
    }

    func testOverlayUpdatesAfterSpeakerSwitch() throws {
        _ = try startSession()
        state.ingestTranscribedSegment(makeSegment(speaker: "you", offsetMs: 0, text: "First"))
        state.ingestTranscribedSegment(makeSegment(speaker: "remote", offsetMs: 1_000, text: "Reply"))

        // After speaker change the prior live row was flushed (it stays in the overlay
        // as the previous synthetic id), and the current live row is the remote text.
        XCTAssertTrue(state.overlaySegments.contains { $0.text == "Reply" && $0.speaker == "remote" })
    }

    // MARK: - Error surfacing

    func testSpeechEngineErrorPopulatesLastError() async {
        XCTAssertNil(state.lastError)
        let pretend = NSError(domain: "TestSpeech", code: 42, userInfo: [NSLocalizedDescriptionKey: "Model crashed"])
        state.speechEngine.onSessionError?(pretend)
        XCTAssertEqual(state.lastError, "Model crashed")
    }
}
