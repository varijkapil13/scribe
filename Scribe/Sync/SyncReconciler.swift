import Foundation

/// Turns a snapshot of local + remote task state into a concrete set of
/// actions, by running `SyncMergePolicy` over the union of ids. Pure and
/// deterministic (ids sorted) so the whole reconcile decision is unit-testable;
/// `TaskSyncCoordinator` executes the plan against `TaskStore` + CloudKit.
enum SyncReconciler {

    struct Plan: Equatable {
        /// Remote is newer → write the remote task into the local store.
        var applyRemoteUpserts: [String] = []
        /// Remote tombstone is newer → delete locally.
        var applyRemoteDeletes: [String] = []
        /// Local is newer → push the local task to CloudKit.
        var pushLocalUpserts: [String] = []
        /// Local tombstone is newer → push a delete to CloudKit.
        var pushLocalDeletes: [String] = []

        var isEmpty: Bool {
            applyRemoteUpserts.isEmpty && applyRemoteDeletes.isEmpty
                && pushLocalUpserts.isEmpty && pushLocalDeletes.isEmpty
        }
    }

    static func plan(
        local: [String: SyncMergePolicy.Side],
        remote: [String: SyncMergePolicy.Side]
    ) -> Plan {
        var plan = Plan()
        let ids = Set(local.keys).union(remote.keys).sorted()
        for id in ids {
            switch SyncMergePolicy.resolve(local: local[id], remote: remote[id]) {
            case .noChange:
                break
            case .applyRemoteUpsert:
                plan.applyRemoteUpserts.append(id)
            case .applyRemoteDelete:
                plan.applyRemoteDeletes.append(id)
            case .pushLocalUpsert:
                plan.pushLocalUpserts.append(id)
            case .pushLocalDelete:
                plan.pushLocalDeletes.append(id)
            }
        }
        return plan
    }
}
