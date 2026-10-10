import XCTest
@testable import Scribe

/// Pins the bookkeeping around meeting detection: which recordings
/// "stop when the meeting ends" may stop, when the event-driven detector has
/// to sample again on its own, and how slow the safety-net poll is.
@MainActor
final class MeetingDetectionSchedulingTests: XCTestCase {

    private let zoom = MeetingApp(bundleID: "us.zoom.xos", name: "Zoom", kind: .conferencing)
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - Ownership

    func testAutoStopOnlyStopsDetectorStartedRecording() {
        var ownership = MeetingRecordingOwnership()
        ownership.detectorStarted(sessionId: "auto-1")
        XCTAssertEqual(
            ownership.endResponse(endAction: .stop, isRecording: true, currentSessionId: "auto-1"),
            .stop
        )
    }

    func testAutoStopAsksForManualRecording() {
        let ownership = MeetingRecordingOwnership()
        XCTAssertEqual(
            ownership.endResponse(endAction: .stop, isRecording: true, currentSessionId: "manual-1"),
            .ask,
            "a recording the user started by hand must never be stopped automatically"
        )
    }

    func testReplacedRecordingIsNotOwned() {
        var ownership = MeetingRecordingOwnership()
        ownership.detectorStarted(sessionId: "auto-1")
        // User stopped the auto recording and started their own mid-call.
        XCTAssertFalse(ownership.ownsRecording(currentSessionId: "manual-2"))
        XCTAssertEqual(
            ownership.endResponse(endAction: .stop, isRecording: true, currentSessionId: "manual-2"),
            .ask
        )
    }

    func testUnknownSessionIdIsNeverOwned() {
        var ownership = MeetingRecordingOwnership()
        ownership.detectorStarted(sessionId: nil)
        XCTAssertFalse(ownership.ownsRecording(currentSessionId: nil))
        XCTAssertEqual(ownership.endResponse(endAction: .stop, isRecording: true, currentSessionId: nil), .ask)
    }

    func testEndResponseRespectsEndActionAndRecordingState() {
        var ownership = MeetingRecordingOwnership()
        ownership.detectorStarted(sessionId: "auto-1")
        XCTAssertEqual(ownership.endResponse(endAction: .nothing, isRecording: true, currentSessionId: "auto-1"), .ignore)
        XCTAssertEqual(ownership.endResponse(endAction: .notify, isRecording: true, currentSessionId: "auto-1"), .ask)
        XCTAssertEqual(ownership.endResponse(endAction: .stop, isRecording: false, currentSessionId: nil), .ignore)
    }

    func testClearForgetsOwnership() {
        var ownership = MeetingRecordingOwnership()
        ownership.detectorStarted(sessionId: "auto-1")
        ownership.clear()
        XCTAssertNil(ownership.detectorSessionId)
        XCTAssertEqual(ownership.endResponse(endAction: .stop, isRecording: true, currentSessionId: "auto-1"), .ask)
    }

    // MARK: - Policy deadlines

    func testNoDeadlineWhenIdle() {
        var policy = MeetingDetectionPolicy(startDelay: 3, endGrace: 15)
        XCTAssertNil(policy.nextEvaluation())
        XCTAssertNil(policy.update(active: [], now: at(0)))
        XCTAssertNil(policy.nextEvaluation())
    }

    func testDeadlineAtStartDelayForCandidate() {
        var policy = MeetingDetectionPolicy(startDelay: 3, endGrace: 15)
        XCTAssertNil(policy.update(active: [zoom], now: at(0)))
        XCTAssertEqual(policy.nextEvaluation(), at(3))
        // Sampling at the deadline starts the meeting.
        XCTAssertEqual(policy.update(active: [zoom], now: at(3)), .started(zoom))
        XCTAssertNil(policy.nextEvaluation(), "while the meeting holds the mic only a change matters")
    }

    func testCameraShortensDeadline() {
        var policy = MeetingDetectionPolicy(startDelay: 3, endGrace: 15, cameraStartDelay: 1)
        XCTAssertNil(policy.update(active: [zoom], now: at(0), cameraInUse: true))
        XCTAssertEqual(policy.nextEvaluation(), at(1))
    }

    func testDeadlineAtEndGraceOnceMicReleased() {
        var policy = MeetingDetectionPolicy(startDelay: 3, endGrace: 15)
        _ = policy.update(active: [zoom], now: at(0))
        XCTAssertEqual(policy.update(active: [zoom], now: at(3)), .started(zoom))
        XCTAssertNil(policy.update(active: [], now: at(10)))
        // Last seen at 3 s → ends at 18 s.
        XCTAssertEqual(policy.nextEvaluation(), at(18))
        XCTAssertEqual(policy.update(active: [], now: at(18)), .ended(zoom))
        XCTAssertNil(policy.nextEvaluation())
    }

    func testResetClearsDeadline() {
        var policy = MeetingDetectionPolicy(startDelay: 3, endGrace: 15)
        _ = policy.update(active: [zoom], now: at(0))
        policy.reset()
        XCTAssertNil(policy.nextEvaluation())
    }

    // MARK: - Fallback poll

    func testFallbackPollIsSlowWithListenersAndSlowerInLowPower() {
        let normal = MeetingDetectionSchedule.fallbackInterval(lowPowerMode: false, listenersActive: true)
        let lowPower = MeetingDetectionSchedule.fallbackInterval(lowPowerMode: true, listenersActive: true)
        XCTAssertGreaterThanOrEqual(normal, 15)
        XCTAssertGreaterThan(lowPower, normal)
    }

    func testFallbackPollIsFasterWithoutListeners() {
        let withListeners = MeetingDetectionSchedule.fallbackInterval(lowPowerMode: false, listenersActive: true)
        let without = MeetingDetectionSchedule.fallbackInterval(lowPowerMode: false, listenersActive: false)
        let withoutLowPower = MeetingDetectionSchedule.fallbackInterval(lowPowerMode: true, listenersActive: false)
        XCTAssertLessThan(without, withListeners)
        XCTAssertGreaterThan(withoutLowPower, without)
    }

    func testToleranceIsAFractionOfTheInterval() {
        XCTAssertEqual(MeetingDetectionSchedule.tolerance(for: 60), 15)
        XCTAssertEqual(MeetingDetectionSchedule.tolerance(for: 1), 0.5)
    }
}
