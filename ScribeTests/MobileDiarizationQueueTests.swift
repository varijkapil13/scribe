import XCTest
@testable import Scribe

/// The iPhone / iPad diarization job queue, the session-clock shift, and the
/// store queries speaker separation runs on.
@MainActor
final class MobileDiarizationQueueTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileDiarizationQueueTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    private func job(_ sessionId: String, createdAt: TimeInterval, file: String = "mic.m4a") -> MobileDiarizationJob {
        MobileDiarizationJob(
            sessionId: sessionId,
            audioDirectoryPath: "/audio/\(sessionId)",
            audioFileName: file,
            isScratch: true,
            speakerKeys: ["In person"],
            pieces: [.init(startMs: 0, endMs: 1_500, text: "hello"), .init(startMs: 1_600, endMs: 3_000, text: "there")],
            createdAt: Date(timeIntervalSince1970: createdAt),
            failureCount: 0
        )
    }

    // MARK: - Queue

    func testSaveReadAndRemoveJobs() throws {
        let queue = MobileDiarizationQueue(directory: tempRoot)
        XCTAssertEqual(queue.pending(), [], "a missing folder is an empty queue")

        let later = job("B", createdAt: 200)
        let earlier = job("A", createdAt: 100)
        try queue.save(later)
        try queue.save(earlier)
        XCTAssertEqual(queue.pending(), [earlier, later], "oldest first, round-tripped exactly")

        var retried = later
        retried.failureCount = 2
        try queue.save(retried)
        XCTAssertEqual(queue.pending().count, 2, "saving again replaces")
        XCTAssertEqual(queue.job(for: "B")?.failureCount, 2)

        queue.remove(sessionId: "A")
        XCTAssertEqual(queue.pending().map(\.sessionId), ["B"])
        queue.remove(sessionId: "missing")
        XCTAssertEqual(queue.pending().count, 1)
    }

    func testUnreadableJobFilesAreDropped() throws {
        let queue = MobileDiarizationQueue(directory: tempRoot)
        try queue.save(job("A", createdAt: 1))
        let garbage = tempRoot.appendingPathComponent("broken.json")
        try Data("not json".utf8).write(to: garbage)
        XCTAssertEqual(queue.pending().map(\.sessionId), ["A"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: garbage.path))
    }

    func testFileNamesAndLocations() {
        XCTAssertEqual(MobileDiarizationQueue.safeFileName("6F9A-11"), "6F9A-11")
        XCTAssertEqual(MobileDiarizationQueue.safeFileName("../x/y"), "___x_y")
        XCTAssertEqual(MobileDiarizationQueue.safeFileName(""), "_")

        let support = URL(fileURLWithPath: "/S", isDirectory: true)
        XCTAssertEqual(MobileDiarizationQueue.defaultDirectory(applicationSupport: support).path, "/S/Scribe/DiarizationQueue")
        XCTAssertEqual(MobileDiarizationQueue.scratchAudioDirectory(applicationSupport: support, sessionId: "abc").path,
                       "/S/Scribe/DiarizationAudio/abc")

        let micJob = job("A", createdAt: 0)
        XCTAssertEqual(micJob.audioFileURL.path, "/audio/A/mic.m4a")
        XCTAssertEqual(micJob.rebuilderPieces, [
            DiarizedSegmentRebuilder.Piece(startMs: 0, endMs: 1_500, text: "hello"),
            DiarizedSegmentRebuilder.Piece(startMs: 1_600, endMs: 3_000, text: "there"),
        ])
    }

    // MARK: - Session clock

    func testTurnsShiftByTheDiarizedTracksOffset() {
        let turns = [DiarizedSegmentRebuilder.Turn(speakerId: "S1", start: 1, end: 2)]
        let timing = SessionAudioTiming(micStartOffsetMs: 500, systemStartOffsetMs: 2_000)

        XCTAssertEqual(job("A", createdAt: 0).turnsOnSessionClock(turns, timing: nil), turns)
        XCTAssertEqual(job("A", createdAt: 0).turnsOnSessionClock(turns, timing: timing),
                       [DiarizedSegmentRebuilder.Turn(speakerId: "S1", start: 1.5, end: 2.5)])
        XCTAssertEqual(job("A", createdAt: 0, file: "system.m4a").turnsOnSessionClock(turns, timing: timing),
                       [DiarizedSegmentRebuilder.Turn(speakerId: "S1", start: 3, end: 4)])
    }

    // MARK: - Store

    func testInPersonSegmentsAreDiarizableAndSplit() throws {
        let dbm = try DatabaseManager(path: ":memory:")
        let notes = NoteStore(databaseManager: dbm)
        let store = TranscriptStore(databaseManager: dbm)
        let note = try notes.createNote(title: "N", body: "")
        let session = try store.createSession(title: "S", noteId: note.id)

        try store.addSegment(sessionId: session.id, startMs: 0, endMs: 3_000, speaker: "In person", text: "hello there")
        try store.addSegment(sessionId: session.id, startMs: 4_000, endMs: 5_000, speaker: "In person", text: "ok")
        try store.addSegment(sessionId: session.id, startMs: 6_000, endMs: 7_000, speaker: "remote", text: "other source")
        try store.addSegment(sessionId: session.id, startMs: 8_000, endMs: 9_000, speaker: "In person", text: "mine")
        let ids = try store.fetchSegments(sessionId: session.id).compactMap(\.id)
        XCTAssertEqual(ids.count, 4)
        try store.setSpeakerOverride("Priya", forSegmentIds: [ids[3]])

        let stored = try store.fetchDiarizableSegments(sessionId: session.id, speakerKeys: ["In person"])
        XCTAssertEqual(stored.map(\.id), [ids[0], ids[1]], "other sources and manual reassignments are skipped")
        XCTAssertEqual(try store.fetchDiarizableSegments(sessionId: session.id).map(\.id), [ids[2]],
                       "the Mac's remote-only query is unchanged")

        let pieces = job("A", createdAt: 0).rebuilderPieces
        let turns = [
            DiarizedSegmentRebuilder.Turn(speakerId: "a", start: 0, end: 1.55),
            DiarizedSegmentRebuilder.Turn(speakerId: "b", start: 1.55, end: 5),
        ]
        let changes = DiarizedSegmentRebuilder.changes(stored: stored, pieces: pieces, turns: turns)
        XCTAssertFalse(changes.isEmpty)
        try store.applyDiarization(changes, sessionId: session.id)

        let after = try store.fetchSegments(sessionId: session.id)
        XCTAssertEqual(after.map(\.text), ["hello", "there", "ok", "other source", "mine"])
        XCTAssertEqual(after.map(\.speakerOverride), ["Speaker 1", "Speaker 2", "Speaker 2", nil, "Priya"])
        XCTAssertEqual(try store.speakerKeysInOrder(sessionId: session.id), ["Speaker 1", "Speaker 2", "remote", "Priya"])
    }
}
