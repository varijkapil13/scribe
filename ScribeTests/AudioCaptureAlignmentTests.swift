// ScribeTests/AudioCaptureAlignmentTests.swift
import AVFoundation
import XCTest
@testable import Scribe

// MARK: - Session clock

final class SessionClockTests: XCTestCase {

    func testRunsOnlyWhileStarted() {
        var clock = SessionClock()
        XCTAssertFalse(clock.isRunning)
        XCTAssertEqual(clock.sessionSeconds(atHostSeconds: 50), 0)

        clock.beginRun(atHostSeconds: 100)
        XCTAssertTrue(clock.isRunning)
        XCTAssertEqual(clock.sessionSeconds(atHostSeconds: 100.5), 0.5, accuracy: 1e-9)
        // An instant before the run began reads as its start.
        XCTAssertEqual(clock.sessionSeconds(atHostSeconds: 99), 0, accuracy: 1e-9)
    }

    func testPausedTimeIsExcluded() {
        var clock = SessionClock()
        clock.beginRun(atHostSeconds: 100)
        clock.endRun(atHostSeconds: 110)
        XCTAssertEqual(clock.accumulatedSeconds, 10, accuracy: 1e-9)
        // While paused the clock stands still.
        XCTAssertEqual(clock.sessionSeconds(atHostSeconds: 500), 10, accuracy: 1e-9)

        clock.beginRun(atHostSeconds: 600)
        XCTAssertEqual(clock.sessionSeconds(atHostSeconds: 602.5), 12.5, accuracy: 1e-9)
    }

    func testBeginAndEndAreIdempotent() {
        var clock = SessionClock()
        clock.beginRun(atHostSeconds: 100)
        clock.beginRun(atHostSeconds: 105) // already running: ignored
        XCTAssertEqual(clock.sessionSeconds(atHostSeconds: 106), 6, accuracy: 1e-9)
        clock.endRun(atHostSeconds: 110)
        clock.endRun(atHostSeconds: 120) // already paused: ignored
        XCTAssertEqual(clock.accumulatedSeconds, 10, accuracy: 1e-9)
    }
}

// MARK: - Track timeline

final class AudioTrackTimelineTests: XCTestCase {

    func testFirstBufferFixesStartOffsetWithoutPadding() {
        var timeline = AudioTrackTimeline()
        XCTAssertNil(timeline.startOffsetFrames)
        let pad = timeline.place(frameCount: 1_600, expectedSessionFrame: 8_000, tolerance: 320, maxGap: 1_000_000)
        XCTAssertEqual(pad, 0, "the leading offset is persisted, not written as silence")
        XCTAssertEqual(timeline.startOffsetFrames, 8_000)
        XCTAssertEqual(timeline.fedFrames, 1_600)
        XCTAssertEqual(timeline.nextSessionFrame, 9_600)
    }

    func testOnTimeAndSlightlyLateBuffersAreNotPadded() {
        var timeline = AudioTrackTimeline()
        _ = timeline.place(frameCount: 1_600, expectedSessionFrame: 0, tolerance: 320, maxGap: 1_000_000)
        XCTAssertEqual(timeline.place(frameCount: 1_600, expectedSessionFrame: 1_600, tolerance: 320, maxGap: 1_000_000), 0)
        // Jitter within tolerance.
        XCTAssertEqual(timeline.place(frameCount: 1_600, expectedSessionFrame: 3_400, tolerance: 320, maxGap: 1_000_000), 0)
        XCTAssertEqual(timeline.paddedFrames, 0)
        XCTAssertEqual(timeline.anchors.count, 1)
    }

    func testLateBufferIsPaddedAndMapped() {
        var timeline = AudioTrackTimeline()
        _ = timeline.place(frameCount: 1_600, expectedSessionFrame: 1_000, tolerance: 320, maxGap: 1_000_000)
        // Next frame would land on 2 600; the buffer really starts at 10 600.
        let pad = timeline.place(frameCount: 1_600, expectedSessionFrame: 10_600, tolerance: 320, maxGap: 1_000_000)
        XCTAssertEqual(pad, 8_000)
        XCTAssertEqual(timeline.paddedFrames, 8_000)
        XCTAssertEqual(timeline.nextSessionFrame, 12_200)

        // Track positions before the gap keep the start offset…
        XCTAssertEqual(timeline.sessionFrame(forTrackFrame: 0), 1_000)
        XCTAssertEqual(timeline.sessionFrame(forTrackFrame: 1_599), 2_599)
        // …and after it, also the gap.
        XCTAssertEqual(timeline.sessionFrame(forTrackFrame: 1_600), 10_600)
        XCTAssertEqual(timeline.sessionFrame(forTrackFrame: 3_000), 12_000)
    }

    func testEarlyBufferIsPlacedAsIs() {
        var timeline = AudioTrackTimeline()
        _ = timeline.place(frameCount: 1_600, expectedSessionFrame: 0, tolerance: 320, maxGap: 1_000_000)
        XCTAssertEqual(timeline.place(frameCount: 1_600, expectedSessionFrame: 0, tolerance: 320, maxGap: 1_000_000), 0)
        XCTAssertEqual(timeline.nextSessionFrame, 3_200)
    }

    func testGapIsCapped() {
        var timeline = AudioTrackTimeline()
        _ = timeline.place(frameCount: 100, expectedSessionFrame: 0, tolerance: 0, maxGap: 500)
        XCTAssertEqual(timeline.place(frameCount: 100, expectedSessionFrame: 10_000, tolerance: 0, maxGap: 500), 500)
        XCTAssertEqual(timeline.sessionFrame(forTrackFrame: 100), 600)
    }

    func testEmptyBuffersAndEmptyTimelineAreNeutral() {
        var timeline = AudioTrackTimeline()
        XCTAssertEqual(timeline.sessionFrame(forTrackFrame: 1_234), 1_234)
        XCTAssertEqual(timeline.place(frameCount: 0, expectedSessionFrame: 99, tolerance: 0, maxGap: 100), 0)
        XCTAssertNil(timeline.startOffsetFrames)
    }
}

// MARK: - Both tracks on one clock

final class AudioSessionAlignmentTests: XCTestCase {

    /// 100 ms at 16 kHz.
    private let tenth: Int64 = 1_600

    func testSystemStartingLateIsMeasuredAndMapped() {
        var alignment = AudioSessionAlignment(sampleRate: 16_000)
        alignment.beginRun(atHostSeconds: 1_000)
        alignment.trackWillStart(.system)

        XCTAssertEqual(alignment.place(.mic, frameCount: tenth, startHostSeconds: 1_000.1), 0)
        XCTAssertEqual(alignment.place(.system, frameCount: tenth, startHostSeconds: 1_000.5), 0)

        XCTAssertEqual(alignment.startOffsetMs(.mic), 100)
        XCTAssertEqual(alignment.startOffsetMs(.system), 500)
        // A remote segment 1 s into the system audio happened 1.5 s into the session.
        XCTAssertEqual(alignment.sessionMs(forTrackMs: 1_000, track: .system), 1_500)
        XCTAssertEqual(alignment.sessionMs(forTrackMs: 0, track: .mic), 100)
        XCTAssertEqual(alignment.timing, SessionAudioTiming(micStartOffsetMs: 100, systemStartOffsetMs: 500))
    }

    func testPauseAndLateResumeArePaddedOnBothTracks() {
        var alignment = AudioSessionAlignment(sampleRate: 16_000)
        alignment.beginRun(atHostSeconds: 1_000)
        alignment.trackWillStart(.system)

        // Mic: 100 buffers from 1000.1 → 10 s of audio, ends at session 10.1 s.
        for i in 0..<100 {
            XCTAssertEqual(alignment.place(.mic, frameCount: tenth, startHostSeconds: 1_000.1 + Double(i) * 0.1), 0)
        }
        // System: 96 buffers from 1000.5 → 9.6 s, also ends at session 10.1 s.
        for i in 0..<96 {
            XCTAssertEqual(alignment.place(.system, frameCount: tenth, startHostSeconds: 1_000.5 + Double(i) * 0.1), 0)
        }

        alignment.endRun(atHostSeconds: 1_010.1)
        // Long pause; paused time is not on the session clock.
        alignment.beginRun(atHostSeconds: 1_100)

        // Mic comes back 50 ms after the resume, system 400 ms after it.
        XCTAssertEqual(alignment.place(.mic, frameCount: tenth, startHostSeconds: 1_100.05), 800)
        alignment.trackWillStart(.system)
        XCTAssertEqual(alignment.place(.system, frameCount: tenth, startHostSeconds: 1_100.4), 6_400)

        // Remote audio just before the pause, and the first after it.
        XCTAssertEqual(alignment.sessionMs(forTrackMs: 9_500, track: .system), 10_000)
        XCTAssertEqual(alignment.sessionMs(forTrackMs: 9_600, track: .system), 10_500)
        XCTAssertEqual(alignment.sessionMs(forTrackMs: 10_000, track: .mic), 10_150)
        // Start offsets are unchanged by later gaps.
        XCTAssertEqual(alignment.startOffsetMs(.system), 500)
    }

    func testSteadyStateJitterIsNotPadded() {
        var alignment = AudioSessionAlignment(sampleRate: 16_000)
        alignment.beginRun(atHostSeconds: 0)
        _ = alignment.place(.system, frameCount: tenth, startHostSeconds: 0.2)
        // 300 ms late in steady state: below the 500 ms tolerance, so the
        // buffer follows straight on (next frame lands at session 0.4 s).
        XCTAssertEqual(alignment.place(.system, frameCount: tenth, startHostSeconds: 0.6), 0)
        XCTAssertEqual(alignment.system.nextSessionFrame, 6_400)
        // A real stall is padded up to where the buffer really starts (2 s).
        XCTAssertEqual(alignment.place(.system, frameCount: tenth, startHostSeconds: 2.0), 32_000 - 6_400)
    }

    func testRestartUsesTightTolerance() {
        var alignment = AudioSessionAlignment(sampleRate: 16_000)
        alignment.beginRun(atHostSeconds: 0)
        _ = alignment.place(.mic, frameCount: tenth, startHostSeconds: 0)
        // Mid-session mic restart: 100 ms hole.
        alignment.trackWillStart(.mic)
        XCTAssertEqual(alignment.place(.mic, frameCount: tenth, startHostSeconds: 0.2), tenth)
        // The flag is consumed by that buffer.
        XCTAssertEqual(alignment.place(.mic, frameCount: tenth, startHostSeconds: 0.4), 0)
    }

    func testTrackThatNeverStartedHasNoOffsetAndIdentityMapping() {
        var alignment = AudioSessionAlignment(sampleRate: 16_000)
        alignment.beginRun(atHostSeconds: 0)
        _ = alignment.place(.mic, frameCount: tenth, startHostSeconds: 0.05)
        XCTAssertNil(alignment.startOffsetMs(.system))
        XCTAssertEqual(alignment.sessionMs(forTrackMs: 4_321, track: .system), 4_321)
        XCTAssertEqual(alignment.timing, SessionAudioTiming(micStartOffsetMs: 50, systemStartOffsetMs: nil))
    }

    func testAlignerWrapperMatchesValueLogicAndResets() {
        let aligner = AudioStreamAligner(sampleRate: 16_000)
        aligner.beginRun(atHostSeconds: 10)
        XCTAssertEqual(aligner.place(.system, frameCount: tenth, startHostSeconds: 10.25), 0)
        XCTAssertEqual(aligner.sessionMs(forTrackMs: 0, track: .system), 250)
        XCTAssertEqual(aligner.timing.systemStartOffsetMs, 250)

        aligner.reset()
        XCTAssertNil(aligner.timing.systemStartOffsetMs)
        XCTAssertEqual(aligner.sessionMs(forTrackMs: 700, track: .system), 700)
    }
}

// MARK: - Persisted timing and playback

final class SessionAudioTimingTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionAudioTimingTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testRoundTrip() throws {
        let timing = SessionAudioTiming(micStartOffsetMs: 80, systemStartOffsetMs: 640)
        try timing.write(to: directory)
        let loaded = try XCTUnwrap(SessionAudioTiming.load(from: directory))
        XCTAssertEqual(loaded, timing)
        XCTAssertEqual(loaded.version, SessionAudioTiming.currentVersion)
        XCTAssertEqual(loaded.systemStartOffsetSeconds, 0.64, accuracy: 1e-9)
        XCTAssertEqual(loaded.micStartOffsetSeconds, 0.08, accuracy: 1e-9)
    }

    func testMissingOrUnreadableTimingIsNil() throws {
        XCTAssertNil(SessionAudioTiming.load(from: directory))
        try Data("not json".utf8).write(to: SessionAudioTiming.fileURL(in: directory))
        XCTAssertNil(SessionAudioTiming.load(from: directory))
    }

    func testUnknownOffsetsReadAsZero() {
        let timing = SessionAudioTiming(micStartOffsetMs: nil, systemStartOffsetMs: nil)
        XCTAssertEqual(timing.micStartOffsetSeconds, 0)
        XCTAssertEqual(timing.systemStartOffsetSeconds, 0)
    }
}

final class TrackPlaybackPlanTests: XCTestCase {

    func testBeforeTrackStartsIsDelayed() {
        let plan = TrackPlaybackPlan.make(sessionPosition: 0.2, trackOffset: 0.5, trackDuration: 10)
        XCTAssertEqual(plan?.filePosition, 0)
        XCTAssertEqual(plan?.delay ?? -1, 0.3, accuracy: 1e-9)
    }

    func testInsideTrackStartsAtMatchingFilePosition() {
        let plan = TrackPlaybackPlan.make(sessionPosition: 4.5, trackOffset: 0.5, trackDuration: 10)
        XCTAssertEqual(plan, TrackPlaybackPlan(filePosition: 4, delay: 0))
    }

    func testAfterTrackEndsIsSkipped() {
        XCTAssertNil(TrackPlaybackPlan.make(sessionPosition: 10.5, trackOffset: 0.5, trackDuration: 10))
        XCTAssertNil(TrackPlaybackPlan.make(sessionPosition: 0, trackOffset: 0.5, trackDuration: 0))
    }

    func testZeroOffsetIsThePlainFilePosition() {
        XCTAssertEqual(TrackPlaybackPlan.make(sessionPosition: 3, trackOffset: 0, trackDuration: 10),
                       TrackPlaybackPlan(filePosition: 3, delay: 0))
    }
}

// MARK: - Capture timestamps

final class CaptureTimestampTests: XCTestCase {

    func testPlausiblePresentationTimeIsUsed() {
        XCTAssertEqual(SystemAudioCapture.startHostSeconds(presentationSeconds: 99.9,
                                                           arrivalHostSeconds: 100,
                                                           durationSeconds: 0.02), 99.9)
    }

    func testMissingOrImplausiblePresentationTimeFallsBackToArrival() {
        // No timestamp.
        XCTAssertEqual(SystemAudioCapture.startHostSeconds(presentationSeconds: nil,
                                                           arrivalHostSeconds: 100,
                                                           durationSeconds: 0.25), 99.75, accuracy: 1e-9)
        // Not on the host clock (far from arrival).
        XCTAssertEqual(SystemAudioCapture.startHostSeconds(presentationSeconds: 3,
                                                           arrivalHostSeconds: 100,
                                                           durationSeconds: 0.25), 99.75, accuracy: 1e-9)
        // In the future.
        XCTAssertEqual(SystemAudioCapture.startHostSeconds(presentationSeconds: 100.5,
                                                           arrivalHostSeconds: 100,
                                                           durationSeconds: 0.25), 99.75, accuracy: 1e-9)
    }

    func testBufferStartUsesHostTimeWhenValid() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                 channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        let time = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 12.5))
        XCTAssertEqual(AudioSessionManager.bufferStartHostSeconds(buffer, time: time), 12.5, accuracy: 1e-3)
    }

    func testAlignerFramesScaleToAlignerRate() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                 channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        XCTAssertEqual(AudioSessionManager.alignerFrames(of: buffer, alignerRate: 16_000), 1_600)
    }
}

// MARK: - Recorder gap filling

final class SessionAudioRecorderAlignmentTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionAudioRecorderAlignmentTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testSilenceFillsGapAndTimingIsSaved() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                 channels: 1, interleaved: false))
        func tone() throws -> AVAudioPCMBuffer {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = 16_000
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for i in 0..<16_000 { samples[i] = 0.3 * sinf(Float(i) * 0.1) }
            return buffer
        }

        let recorder = SessionAudioRecorder(directory: directory)
        recorder.appendMic(try tone())
        recorder.appendSilence(frames: 32_000, toMic: true)
        recorder.appendMic(try tone())
        recorder.finish(timing: SessionAudioTiming(micStartOffsetMs: 90, systemStartOffsetMs: nil))

        let file = try AVAudioFile(forReading: SessionAudioStorage.micFileURL(in: directory))
        // 1 s tone + 2 s silence + 1 s tone. AAC frames add a little slack.
        XCTAssertEqual(Double(file.length), 64_000, accuracy: 4_096)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SessionAudioStorage.systemFileURL(in: directory).path))
        XCTAssertEqual(SessionAudioTiming.load(from: directory)?.micStartOffsetMs, 90)
    }

    func testTimingWithoutOffsetsIsNotWritten() {
        let recorder = SessionAudioRecorder(directory: directory)
        recorder.finish(timing: SessionAudioTiming(micStartOffsetMs: nil, systemStartOffsetMs: nil))
        XCTAssertNil(SessionAudioTiming.load(from: directory))
    }
}
