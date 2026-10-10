import XCTest
@testable import Scribe

final class DictationPastePolicyTests: XCTestCase {

    func testTemporaryItemIsMarkedTransientAndConcealed() {
        let markers = DictationPastePolicy.temporaryItemMarkerTypes
        XCTAssertTrue(markers.contains("org.nspasteboard.TransientType"))
        XCTAssertTrue(markers.contains("org.nspasteboard.ConcealedType"))
    }

    func testRestoreDelayIsLongerThanLegacyFixedDelay() {
        // The old fixed 400 ms restored too early for busy apps.
        XCTAssertGreaterThan(DictationPastePolicy.restoreDelayMilliseconds(forTextLength: 0), 400)
        XCTAssertGreaterThan(DictationPastePolicy.restoreDelayMilliseconds(forTextLength: 20), 400)
    }

    func testRestoreDelayGrowsWithLengthAndIsCapped() {
        let short = DictationPastePolicy.restoreDelayMilliseconds(forTextLength: 50)
        let long = DictationPastePolicy.restoreDelayMilliseconds(forTextLength: 5_000)
        let huge = DictationPastePolicy.restoreDelayMilliseconds(forTextLength: 10_000_000)
        XCTAssertGreaterThan(long, short)
        XCTAssertEqual(huge, DictationPastePolicy.maxRestoreDelayMilliseconds)
        XCTAssertLessThanOrEqual(long, DictationPastePolicy.maxRestoreDelayMilliseconds)
    }

    func testNegativeLengthIsTreatedAsEmpty() {
        XCTAssertEqual(
            DictationPastePolicy.restoreDelayMilliseconds(forTextLength: -10),
            DictationPastePolicy.restoreDelayMilliseconds(forTextLength: 0)
        )
    }

    func testRestoreSkippedWhenPasteboardChangedAfterWrite() {
        XCTAssertTrue(DictationPastePolicy.shouldRestore(currentChangeCount: 7, changeCountAfterWrite: 7))
        XCTAssertFalse(DictationPastePolicy.shouldRestore(currentChangeCount: 8, changeCountAfterWrite: 7))
    }
}
