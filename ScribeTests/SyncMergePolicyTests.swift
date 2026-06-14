import XCTest
@testable import Scribe

final class SyncMergePolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let t1 = Date(timeIntervalSince1970: 2_000_000)

    private func side(_ updatedAt: Date, deleted: Bool = false) -> SyncMergePolicy.Side {
        SyncMergePolicy.Side(updatedAt: updatedAt, isDeleted: deleted)
    }

    func testBothAbsent() {
        XCTAssertEqual(SyncMergePolicy.resolve(local: nil, remote: nil), .noChange)
    }

    func testRemoteOnlyUpsert() {
        XCTAssertEqual(SyncMergePolicy.resolve(local: nil, remote: side(t0)), .applyRemoteUpsert)
    }

    func testRemoteOnlyDeletedIsNoOp() {
        // A remote tombstone for a record we never had — nothing to delete.
        XCTAssertEqual(SyncMergePolicy.resolve(local: nil, remote: side(t0, deleted: true)), .noChange)
    }

    func testLocalOnlyUpsert() {
        XCTAssertEqual(SyncMergePolicy.resolve(local: side(t0), remote: nil), .pushLocalUpsert)
    }

    func testLocalOnlyDeletedIsNoOp() {
        XCTAssertEqual(SyncMergePolicy.resolve(local: side(t0, deleted: true), remote: nil), .noChange)
    }

    func testRemoteNewerWins() {
        XCTAssertEqual(SyncMergePolicy.resolve(local: side(t0), remote: side(t1)), .applyRemoteUpsert)
    }

    func testRemoteNewerDeleteWins() {
        XCTAssertEqual(SyncMergePolicy.resolve(local: side(t0), remote: side(t1, deleted: true)), .applyRemoteDelete)
    }

    func testLocalNewerWins() {
        XCTAssertEqual(SyncMergePolicy.resolve(local: side(t1), remote: side(t0)), .pushLocalUpsert)
    }

    func testLocalNewerDeleteWins() {
        XCTAssertEqual(SyncMergePolicy.resolve(local: side(t1, deleted: true), remote: side(t0)), .pushLocalDelete)
    }

    func testTieIsNoChange() {
        XCTAssertEqual(SyncMergePolicy.resolve(local: side(t0), remote: side(t0)), .noChange)
    }
}
