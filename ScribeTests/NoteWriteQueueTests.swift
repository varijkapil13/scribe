import XCTest
@testable import Scribe

final class NoteWriteQueueTests: XCTestCase {

    func testNestedRunExecutesInlineWithoutDeadlock() {
        let value = NoteWriteQueue.run {
            XCTAssertTrue(NoteWriteQueue.isCurrent)
            return NoteWriteQueue.run { NoteWriteQueue.run { 42 } }
        }
        XCTAssertEqual(value, 42)
        XCTAssertFalse(NoteWriteQueue.isCurrent)
    }

    func testRunAndDrainFromQueuedWorkDoNotDeadlock() {
        let done = expectation(description: "queued work finished")
        NoteWriteQueue.async {
            NoteWriteQueue.run {}
            NoteWriteQueue.drain()
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testRunWaitsForEarlierQueuedWork() {
        nonisolated(unsafe) var order: [Int] = []
        NoteWriteQueue.async {
            Thread.sleep(forTimeInterval: 0.05)
            order.append(1)
        }
        NoteWriteQueue.run { order.append(2) }
        XCTAssertEqual(order, [1, 2])
    }
}
