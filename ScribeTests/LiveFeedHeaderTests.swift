// ScribeTests/LiveFeedHeaderTests.swift
import XCTest
@testable import Scribe

/// Covers the pure pieces of the shared live-feed header: the elapsed-time
/// formatter (the one string the three live views all render) and the
/// state-resolution mapping. These were previously duplicated four times with
/// subtle drift; the tests pin the canonical behaviour.
final class LiveFeedHeaderTests: XCTestCase {

    // MARK: - formattedElapsed

    func testSubMinuteIsPaddedMinutesAndSeconds() {
        XCTAssertEqual(LiveFeedStatus.formattedElapsed(0), "00:00")
        XCTAssertEqual(LiveFeedStatus.formattedElapsed(5), "00:05")
        XCTAssertEqual(LiveFeedStatus.formattedElapsed(59), "00:59")
    }

    func testMinutesAndSecondsUnderAnHour() {
        XCTAssertEqual(LiveFeedStatus.formattedElapsed(60), "01:00")
        XCTAssertEqual(LiveFeedStatus.formattedElapsed(252), "04:12") // the plan's "Recording · 04:12"
        XCTAssertEqual(LiveFeedStatus.formattedElapsed(3599), "59:59")
    }

    func testHoursUseNonPaddedHourComponent() {
        // The live form intentionally does NOT zero-pad the hour, unlike the
        // older `TimeInterval.formattedDuration`.
        XCTAssertEqual(LiveFeedStatus.formattedElapsed(3600), "1:00:00")
        XCTAssertEqual(LiveFeedStatus.formattedElapsed(3661), "1:01:01")
        XCTAssertEqual(LiveFeedStatus.formattedElapsed(36000), "10:00:00")
    }

    func testFractionalSecondsTruncateAndNegativesClampToZero() {
        XCTAssertEqual(LiveFeedStatus.formattedElapsed(12.9), "00:12")
        XCTAssertEqual(LiveFeedStatus.formattedElapsed(-5), "00:00")
    }

    // MARK: - resolve

    func testResolveClassifiesState() {
        XCTAssertEqual(LiveFeedStatus.resolve(isTranscribing: false, isPaused: false), .ready)
        XCTAssertEqual(LiveFeedStatus.resolve(isTranscribing: true, isPaused: false), .recording)
        XCTAssertEqual(LiveFeedStatus.resolve(isTranscribing: true, isPaused: true), .paused)
        // Paused takes precedence even if the transcribing flag lags behind.
        XCTAssertEqual(LiveFeedStatus.resolve(isTranscribing: false, isPaused: true), .paused)
    }

    func testLabelsMatchAcrossSurfaces() {
        XCTAssertEqual(LiveFeedStatus.recording.label, "Recording")
        XCTAssertEqual(LiveFeedStatus.recording.eyebrow, "RECORDING")
        XCTAssertEqual(LiveFeedStatus.paused.label, "Paused")
        XCTAssertEqual(LiveFeedStatus.ready.eyebrow, "READY")
    }
}
