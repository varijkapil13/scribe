import XCTest
import Combine
@testable import Scribe

/// Pins the pure parts of the recording session lifecycle: the start gate
/// (double-start / stop-while-starting), the speech engine's generation token
/// and audio ledger (timestamps across a language switch), preference change
/// filtering, heavy-work deferral and diarization scratch cleanup.
@MainActor
final class SessionLifecycleTests: XCTestCase {

    // MARK: - SessionStartGate

    func testGateRejectsSecondStartWhileStarting() {
        var gate = SessionStartGate()
        XCTAssertTrue(gate.begin(isRunning: false))
        XCTAssertTrue(gate.isStarting)
        XCTAssertFalse(gate.begin(isRunning: false), "a second start must be refused while one is in flight")
        gate.end()
        XCTAssertFalse(gate.isStarting)
        XCTAssertTrue(gate.begin(isRunning: false), "the gate is reusable after the start ends")
    }

    func testGateRejectsStartWhileRunning() {
        var gate = SessionStartGate()
        XCTAssertFalse(gate.begin(isRunning: true))
        XCTAssertFalse(gate.isStarting)
    }

    func testStopWhileStartingIsAbsorbedAsCancellation() {
        var gate = SessionStartGate()
        XCTAssertFalse(gate.requestStop(), "nothing starting: the caller stops normally")
        XCTAssertTrue(gate.begin(isRunning: false))
        XCTAssertTrue(gate.requestStop())
        XCTAssertTrue(gate.stopRequested)
        gate.end()
        XCTAssertFalse(gate.stopRequested, "ending the start clears the request")
        XCTAssertTrue(gate.begin(isRunning: false))
        XCTAssertFalse(gate.stopRequested, "a new start begins uncancelled")
    }

    // MARK: - AppState start gate

    func testAppStateRefusesSecondConcurrentStart() throws {
        let manager = try DatabaseManager(path: ":memory:")
        let state = AppState(transcriptStore: TranscriptStore(databaseManager: manager))

        XCTAssertTrue(state.beginStartingSession())
        XCTAssertTrue(state.isStartingSession)
        XCTAssertFalse(state.beginStartingSession())
        state.endStartingSession()
        XCTAssertFalse(state.isStartingSession)
    }

    func testStopDuringStartCancelsStartWithoutCreatingSession() async throws {
        let manager = try DatabaseManager(path: ":memory:")
        let transcripts = TranscriptStore(databaseManager: manager)
        let notes = NoteStore(databaseManager: manager)
        let state = AppState(transcriptStore: transcripts)
        let note = try notes.createNote(title: "Meeting", body: "")

        // AppDelegate claims the gate before its permission checks; a stop
        // arriving then must cancel the start rather than run a full stop.
        XCTAssertTrue(state.beginStartingSession())
        await state.stopSession()

        do {
            try await state.startSession(title: "Cancelled", noteId: note.id)
            XCTFail("Expected the start to be cancelled")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        state.endStartingSession()

        XCTAssertEqual(try transcripts.fetchSessions(forNoteId: note.id).count, 0)
        XCTAssertNil(state.currentSessionId)
        XCTAssertFalse(state.isTranscribing)
        XCTAssertFalse(state.isStartingSession)
    }

    // MARK: - SessionGeneration

    func testGenerationTokenGoesStaleAfterAdvance() {
        var generation = SessionGeneration()
        let start = generation.advance()
        XCTAssertTrue(generation.isCurrent(start))
        // stopSession while the start awaits the model install:
        generation.advance()
        XCTAssertFalse(generation.isCurrent(start), "a superseded start must not install its pipelines")
    }

    func testOnlyLatestOfOverlappingStartsIsCurrent() {
        var generation = SessionGeneration()
        let first = generation.advance()
        let second = generation.advance()
        XCTAssertFalse(generation.isCurrent(first))
        XCTAssertTrue(generation.isCurrent(second))
    }

    // MARK: - AudioSwapLedger

    func testFreshSessionStartsAtZero() {
        var ledger = AudioSwapLedger<Int>()
        ledger.beginHolding()
        let release = ledger.endHolding()
        XCTAssertEqual(release.baseOffsetMs, 0)
        XCTAssertEqual(release.buffers, [])
    }

    func testOffsetCarriesOverAcrossSwap() {
        var ledger = AudioSwapLedger<Int>()
        // 10 s fed to the first pipeline.
        for i in 0..<10 {
            let fedNow = ledger.receive(i, seconds: 1)
            XCTAssertTrue(fedNow)
        }
        // Language switch: audio arriving during the swap is held.
        ledger.beginHolding()
        let fedFirst = ledger.receive(100, seconds: 0.5)
        let fedSecond = ledger.receive(101, seconds: 0.5)
        XCTAssertFalse(fedFirst)
        XCTAssertFalse(fedSecond)
        let release = ledger.endHolding()
        // The new pipeline's first buffer (100) sits at 10 s of session audio.
        XCTAssertEqual(release.baseOffsetMs, 10_000)
        XCTAssertEqual(release.buffers, [100, 101])
        XCTAssertFalse(ledger.isHolding)
        let fedAfter = ledger.receive(102, seconds: 1)
        XCTAssertTrue(fedAfter, "after the swap buffers go straight to the pipeline")
    }

    func testHeldAudioIsBoundedButOffsetStaysCorrect() {
        var ledger = AudioSwapLedger<Int>(maxHeldSeconds: 5)
        for i in 0..<10 { _ = ledger.receive(i, seconds: 1) }     // 0…10 s
        ledger.beginHolding()
        _ = ledger.receive(20, seconds: 3)                           // 10…13 s
        _ = ledger.receive(21, seconds: 3)                           // 13…16 s → drops 20
        _ = ledger.receive(22, seconds: 3)                           // 16…19 s → drops 21
        XCTAssertEqual(ledger.heldCount, 1)
        let release = ledger.endHolding()
        XCTAssertEqual(release.buffers, [22])
        XCTAssertEqual(release.baseOffsetMs, 16_000, "base must point at the oldest buffer still held")
    }

    func testBeginHoldingIsIdempotentDuringOverlappingSwaps() {
        var ledger = AudioSwapLedger<Int>()
        _ = ledger.receive(0, seconds: 2)
        ledger.beginHolding()
        _ = ledger.receive(1, seconds: 1)
        ledger.beginHolding() // a second language switch before the first finished
        _ = ledger.receive(2, seconds: 1)
        let release = ledger.endHolding()
        XCTAssertEqual(release.buffers, [1, 2])
        XCTAssertEqual(release.baseOffsetMs, 2_000)
    }

    func testResetStartsANewTimeline() {
        var ledger = AudioSwapLedger<Int>()
        _ = ledger.receive(0, seconds: 30)
        ledger.reset()
        XCTAssertEqual(ledger.receivedSeconds, 0)
        ledger.beginHolding()
        XCTAssertEqual(ledger.endHolding().baseOffsetMs, 0)
    }

    func testSessionOffsetsAddBase() {
        let offsets = PipelineTimestamps.sessionOffsets(rangeStartSeconds: 1.5, rangeEndSeconds: 2.25, baseOffsetMs: 60_000)
        XCTAssertEqual(offsets.startMs, 61_500)
        XCTAssertEqual(offsets.endMs, 62_250)
    }

    func testSessionOffsetsClampInvalidRanges() {
        let offsets = PipelineTimestamps.sessionOffsets(rangeStartSeconds: -1, rangeEndSeconds: .nan, baseOffsetMs: 1_000)
        XCTAssertEqual(offsets.startMs, 1_000)
        XCTAssertEqual(offsets.endMs, 1_000)
    }

    // MARK: - Preference change filtering

    func testChangesDropsUnchangedFirstEmission() {
        let subject = PassthroughSubject<String, Never>()
        var received: [String] = []
        let cancellable = subject.changes(from: "42").sink { received.append($0) }

        subject.send("42")   // unrelated defaults write: same value
        subject.send("42")
        subject.send("7")    // real change
        subject.send("7")
        subject.send("")     // back to system default
        XCTAssertEqual(received, ["7", ""])
        cancellable.cancel()
    }

    // MARK: - Heavy work deferral

    func testHeavyWorkDefersWhenHotOrLowPower() {
        XCTAssertFalse(HeavyWorkConditions.shouldDefer(thermalState: .nominal, isLowPowerMode: false))
        XCTAssertFalse(HeavyWorkConditions.shouldDefer(thermalState: .fair, isLowPowerMode: false))
        XCTAssertTrue(HeavyWorkConditions.shouldDefer(thermalState: .serious, isLowPowerMode: false))
        XCTAssertTrue(HeavyWorkConditions.shouldDefer(thermalState: .critical, isLowPowerMode: false))
        XCTAssertTrue(HeavyWorkConditions.shouldDefer(thermalState: .nominal, isLowPowerMode: true))
    }

    // MARK: - Keep-awake assertion

    func testActivityAssertionEndIsIdempotent() {
        let activity = SystemActivityAssertion(reason: "test")
        XCTAssertTrue(activity.isActive)
        activity.end()
        XCTAssertFalse(activity.isActive)
        activity.end()
        XCTAssertFalse(activity.isActive)
    }

    // MARK: - Diarization scratch cleanup

    func testRemoveLeftoverScratchDeletesEverySessionFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScribeDiarizationTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("system.caf"))
        }

        XCTAssertEqual(SpeakerDiarizationCapture.removeLeftoverScratch(in: root), 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testRemoveLeftoverScratchKeepsFoldersCreatedAfterLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScribeDiarizationTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("recording-now", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)

        // A recording that started after launch (auto-record racing the
        // cleanup) must keep its scratch audio.
        let launchedAt = Date().addingTimeInterval(-3600)
        XCTAssertEqual(SpeakerDiarizationCapture.removeLeftoverScratch(in: root, createdBefore: launchedAt), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
    }

    func testRemoveLeftoverScratchToleratesMissingRoot() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScribeDiarizationMissing-\(UUID().uuidString)", isDirectory: true)
        XCTAssertEqual(SpeakerDiarizationCapture.removeLeftoverScratch(in: missing), 0)
    }

    func testScratchDirectoryLivesUnderScratchRoot() {
        let dir = SpeakerDiarizationCapture.scratchDirectory(for: "abc")
        XCTAssertEqual(dir.deletingLastPathComponent().standardizedFileURL, SpeakerDiarizationCapture.scratchRoot.standardizedFileURL)
    }
}
