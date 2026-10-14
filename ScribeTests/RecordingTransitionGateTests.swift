import XCTest
@testable import Scribe

final class RecordingTransitionGateTests: XCTestCase {

    func testSecondResumeIsRefusedWhileOneIsInFlight() {
        var gate = RecordingTransitionGate()
        XCTAssertTrue(gate.begin(.resuming))
        XCTAssertFalse(gate.begin(.resuming))
        XCTAssertFalse(gate.begin(.starting))
    }

    func testTransitionCanBeginAgainAfterEnd() {
        var gate = RecordingTransitionGate()
        XCTAssertTrue(gate.begin(.resuming))
        XCTAssertFalse(gate.end())
        XCTAssertNil(gate.inFlight)
        XCTAssertTrue(gate.begin(.resuming))
    }

    func testPauseDuringResumeIsDeferredAndReportedAtEnd() {
        var gate = RecordingTransitionGate()
        XCTAssertTrue(gate.begin(.resuming))
        XCTAssertTrue(gate.deferPauseIfResuming())
        XCTAssertTrue(gate.pauseRequested)
        XCTAssertTrue(gate.end())
        XCTAssertFalse(gate.pauseRequested)
    }

    func testPauseWithNothingInFlightIsAppliedImmediately() {
        var gate = RecordingTransitionGate()
        XCTAssertFalse(gate.deferPauseIfResuming())
        XCTAssertFalse(gate.pauseRequested)
    }

    func testPauseDuringStartIsNotDeferred() {
        var gate = RecordingTransitionGate()
        XCTAssertTrue(gate.begin(.starting))
        XCTAssertFalse(gate.deferPauseIfResuming())
        XCTAssertFalse(gate.end())
    }

    func testDeferredPauseDoesNotLeakIntoTheNextResume() {
        var gate = RecordingTransitionGate()
        XCTAssertTrue(gate.begin(.resuming))
        XCTAssertTrue(gate.deferPauseIfResuming())
        gate.end()
        XCTAssertTrue(gate.begin(.resuming))
        XCTAssertFalse(gate.end())
    }
}
