// ScribeTests/VaultWriteGuardTests.swift
import XCTest
@testable import Scribe

/// Phase 0 safety gate: the watcher must suppress a reconcile while within
/// the self-write window, but resume reconciling once it lapses.
final class VaultWriteGuardTests: XCTestCase {

    func testSuppressesImmediatelyAfterSelfWrite() {
        let guardian = VaultWriteGuard(window: 1.0)
        let t0 = Date(timeIntervalSince1970: 1_000)
        guardian.recordSelfWrite(at: t0)

        // FSEvents typically fires ~0.5s after the write — still inside.
        XCTAssertTrue(guardian.isWithinSelfWriteWindow(now: t0.addingTimeInterval(0.5)))
        XCTAssertTrue(guardian.isWithinSelfWriteWindow(now: t0.addingTimeInterval(0.99)))
    }

    func testStopsSuppressingAfterWindowLapses() {
        let guardian = VaultWriteGuard(window: 1.0)
        let t0 = Date(timeIntervalSince1970: 1_000)
        guardian.recordSelfWrite(at: t0)

        // A genuine external edit a couple seconds later must NOT be suppressed.
        XCTAssertFalse(guardian.isWithinSelfWriteWindow(now: t0.addingTimeInterval(1.01)))
        XCTAssertFalse(guardian.isWithinSelfWriteWindow(now: t0.addingTimeInterval(5.0)))
    }

    func testDoesNotSuppressBeforeAnyWrite() {
        let guardian = VaultWriteGuard(window: 1.0)
        XCTAssertFalse(guardian.isWithinSelfWriteWindow(now: Date()))
    }
}
