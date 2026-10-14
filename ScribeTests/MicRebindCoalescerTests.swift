import CoreAudio
import XCTest
@testable import Scribe

final class MicRebindCoalescerTests: XCTestCase {

    func testFirstRequestSchedulesADrainAndBurstsCoalesce() {
        var coalescer = MicRebindCoalescer()
        XCTAssertTrue(coalescer.request(.defaultInputChanged))
        XCTAssertFalse(coalescer.request(.defaultInputChanged))
        XCTAssertFalse(coalescer.request(.defaultInputChanged))
        XCTAssertEqual(coalescer.take(), .defaultInputChanged)
        XCTAssertNil(coalescer.take())
    }

    func testLastReasonWins() {
        var coalescer = MicRebindCoalescer()
        XCTAssertTrue(coalescer.request(.defaultInputChanged))
        XCTAssertFalse(coalescer.request(.activeInputChanged))
        XCTAssertEqual(coalescer.take(), .activeInputChanged)
    }

    func testRequestAfterDrainSchedulesAgain() {
        var coalescer = MicRebindCoalescer()
        XCTAssertTrue(coalescer.request(.activeInputChanged))
        _ = coalescer.take()
        XCTAssertTrue(coalescer.request(.activeInputChanged))
    }

    func testCancelDropsPendingSoTheScheduledDrainDoesNothing() {
        var coalescer = MicRebindCoalescer()
        XCTAssertTrue(coalescer.request(.defaultInputChanged))
        coalescer.cancel()
        XCTAssertNil(coalescer.take())
    }

    func testCancelThenNewRequestYieldsExactlyOneDrainWithWork() {
        var coalescer = MicRebindCoalescer()
        XCTAssertTrue(coalescer.request(.defaultInputChanged))
        coalescer.cancel()
        XCTAssertTrue(coalescer.request(.activeInputChanged))
        XCTAssertEqual(coalescer.take(), .activeInputChanged)
        XCTAssertNil(coalescer.take())
    }

    func testSystemDefaultModeFollowsDefaultChangesOnly() {
        XCTAssertTrue(MicRebindCoalescer.shouldRebind(
            reason: .defaultInputChanged, selection: .systemDefault, activeTarget: nil, currentDevice: 7))
        XCTAssertFalse(MicRebindCoalescer.shouldRebind(
            reason: .activeInputChanged, selection: .systemDefault, activeTarget: 9, currentDevice: 7))
    }

    func testAutomaticModeSwitchesOnlyToADifferentInUseMic() {
        XCTAssertTrue(MicRebindCoalescer.shouldRebind(
            reason: .activeInputChanged, selection: .automatic, activeTarget: 9, currentDevice: 7))
        XCTAssertFalse(MicRebindCoalescer.shouldRebind(
            reason: .activeInputChanged, selection: .automatic, activeTarget: 7, currentDevice: 7))
        XCTAssertFalse(MicRebindCoalescer.shouldRebind(
            reason: .activeInputChanged, selection: .automatic, activeTarget: nil, currentDevice: 7))
        XCTAssertFalse(MicRebindCoalescer.shouldRebind(
            reason: .defaultInputChanged, selection: .automatic, activeTarget: 9, currentDevice: 7))
    }

    func testPinnedDeviceIgnoresDeviceChanges() {
        for reason in [MicRebindCoalescer.Reason.activeInputChanged, .defaultInputChanged] {
            XCTAssertFalse(MicRebindCoalescer.shouldRebind(
                reason: reason, selection: .device(3), activeTarget: 9, currentDevice: 3))
        }
    }
}
