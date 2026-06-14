import XCTest
@testable import Scribe

final class SyncReconcilerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)

    private func side(_ at: Date, deleted: Bool = false) -> SyncMergePolicy.Side {
        SyncMergePolicy.Side(updatedAt: at, isDeleted: deleted)
    }

    func testEmptyInputsProduceEmptyPlan() {
        XCTAssertTrue(SyncReconciler.plan(local: [:], remote: [:]).isEmpty)
    }

    func testMixedSidesAreBucketedCorrectly() {
        let local: [String: SyncMergePolicy.Side] = [
            "local-only": side(t0),                 // push upsert
            "local-newer": side(t1),                // push upsert (local wins)
            "local-gone": side(t1, deleted: true),  // push delete (local tombstone wins)
            "agree": side(t0)                        // tie → no change
        ]
        let remote: [String: SyncMergePolicy.Side] = [
            "remote-only": side(t0),                // apply upsert
            "local-newer": side(t0),                // local wins → push upsert
            "remote-gone": side(t1, deleted: true), // apply delete
            "local-gone": side(t0),                 // local tombstone newer → push delete
            "agree": side(t0)                        // tie
        ]

        let plan = SyncReconciler.plan(local: local, remote: remote)

        XCTAssertEqual(plan.applyRemoteUpserts, ["remote-only"])
        XCTAssertEqual(plan.applyRemoteDeletes, ["remote-gone"])
        XCTAssertEqual(plan.pushLocalUpserts.sorted(), ["local-newer", "local-only"])
        XCTAssertEqual(plan.pushLocalDeletes, ["local-gone"])
    }

    func testDeterministicOrdering() {
        // ids are processed sorted, so the plan is stable across runs.
        let local: [String: SyncMergePolicy.Side] = ["b": side(t0), "a": side(t0), "c": side(t0)]
        let plan = SyncReconciler.plan(local: local, remote: [:])
        XCTAssertEqual(plan.pushLocalUpserts, ["a", "b", "c"])
    }
}
