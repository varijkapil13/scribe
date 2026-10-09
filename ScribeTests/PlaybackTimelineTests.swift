// ScribeTests/PlaybackTimelineTests.swift
import XCTest
@testable import Scribe

final class PlaybackTimelineTests: XCTestCase {

    private func seg(_ id: Int64, _ start: Int, _ end: Int, _ speaker: String = "you") -> Segment {
        Segment(id: id, sessionId: "s", startMs: start, endMs: end, speaker: speaker, text: "t\(id)")
    }

    // MARK: Segment lookup

    func testNoSegmentBeforeFirstStart() {
        let segments = [seg(1, 1_000, 2_000)]
        XCTAssertNil(PlaybackTimeline.currentSegmentIndex(at: 500, in: segments))
        XCTAssertNil(PlaybackTimeline.currentSegmentIndex(at: 0, in: []))
    }

    func testFindsContainingSegment() {
        let segments = [seg(1, 0, 4_000), seg(2, 5_000, 9_000), seg(3, 10_000, 12_000)]
        XCTAssertEqual(PlaybackTimeline.currentSegmentIndex(at: 0, in: segments), 0)
        XCTAssertEqual(PlaybackTimeline.currentSegmentIndex(at: 6_500, in: segments), 1)
        XCTAssertEqual(PlaybackTimeline.currentSegmentId(at: 11_000, in: segments), 3)
    }

    func testGapKeepsLastStartedSegment() {
        let segments = [seg(1, 0, 4_000), seg(2, 5_000, 9_000)]
        XCTAssertEqual(PlaybackTimeline.currentSegmentIndex(at: 4_500, in: segments), 0)
        XCTAssertEqual(PlaybackTimeline.currentSegmentIndex(at: 60_000, in: segments), 1)
    }

    func testOverlapPrefersLatestContainingSegment() {
        // A long mic segment overlapped by a remote one that starts later.
        let segments = [seg(1, 0, 20_000, "you"), seg(2, 5_000, 8_000, "remote")]
        XCTAssertEqual(PlaybackTimeline.currentSegmentIndex(at: 6_000, in: segments), 1)
        // After the remote segment ends, the still-running mic one is current.
        XCTAssertEqual(PlaybackTimeline.currentSegmentIndex(at: 10_000, in: segments), 0)
    }

    // MARK: Formatting

    func testFormat() {
        XCTAssertEqual(PlaybackTimeline.format(0), "0:00")
        XCTAssertEqual(PlaybackTimeline.format(5.9), "0:05")
        XCTAssertEqual(PlaybackTimeline.format(65), "1:05")
        XCTAssertEqual(PlaybackTimeline.format(3_600), "1:00:00")
        XCTAssertEqual(PlaybackTimeline.format(3_725), "1:02:05")
        XCTAssertEqual(PlaybackTimeline.format(-3), "0:00")
        XCTAssertEqual(PlaybackTimeline.format(.nan), "0:00")
        XCTAssertEqual(PlaybackTimeline.format(.infinity), "0:00")
    }

    // MARK: Seeking

    func testClampedSeek() {
        XCTAssertEqual(PlaybackTimeline.clampedSeek(-1, duration: 10), 0)
        XCTAssertEqual(PlaybackTimeline.clampedSeek(4, duration: 10), 4)
        XCTAssertEqual(PlaybackTimeline.clampedSeek(12, duration: 10), 10)
        XCTAssertEqual(PlaybackTimeline.clampedSeek(.nan, duration: 10), 0)
        XCTAssertEqual(PlaybackTimeline.clampedSeek(3, duration: 0), 0)
    }

    func testSecondsFromMs() {
        XCTAssertEqual(PlaybackTimeline.seconds(fromMs: 1_500), 1.5)
        XCTAssertEqual(PlaybackTimeline.seconds(fromMs: -10), 0)
    }

    // MARK: Speed

    func testRateCycle() {
        XCTAssertEqual(PlaybackTimeline.nextRate(after: 1.0), 1.5)
        XCTAssertEqual(PlaybackTimeline.nextRate(after: 1.5), 2.0)
        XCTAssertEqual(PlaybackTimeline.nextRate(after: 2.0), 1.0)
        XCTAssertEqual(PlaybackTimeline.nextRate(after: 0.75), 1.0)
    }

    func testRateLabel() {
        XCTAssertEqual(PlaybackTimeline.rateLabel(1.0), "1×")
        XCTAssertEqual(PlaybackTimeline.rateLabel(1.5), "1.5×")
        XCTAssertEqual(PlaybackTimeline.rateLabel(2.0), "2×")
    }

    // MARK: Echo cancellation gating

    func testVoiceProcessingOnlyWithSystemAudio() {
        XCTAssertTrue(AudioSessionManager.shouldUseVoiceProcessing(setting: true, captureSystemAudio: true))
        XCTAssertFalse(AudioSessionManager.shouldUseVoiceProcessing(setting: true, captureSystemAudio: false))
        XCTAssertFalse(AudioSessionManager.shouldUseVoiceProcessing(setting: false, captureSystemAudio: true))
    }
}
