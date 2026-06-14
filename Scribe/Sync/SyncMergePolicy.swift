import Foundation

/// Pure last-writer-wins conflict resolution for task sync. Kept free of
/// CloudKit so the policy — the part that actually decides what happens to a
/// user's data — is fully unit-testable. `CloudKitSyncService` applies the
/// outcomes; `TaskCloudRecord` handles the CKRecord wire format.
///
/// Tombstones: a deleted task is represented by a `deletedAt` timestamp rather
/// than an absent record, so a delete on one device wins over a stale edit on
/// another (and isn't resurrected by it).
enum SyncMergePolicy {

    /// What to do for a single task id, given the local and remote sides.
    enum Resolution: Equatable {
        case noChange
        case applyRemoteUpsert      // remote is newer → write remote into local
        case applyRemoteDelete      // remote tombstone is newer → delete local
        case pushLocalUpsert        // local is newer → push local to remote
        case pushLocalDelete        // local tombstone is newer → push delete
    }

    /// A minimal view of a record for merge purposes: when it last changed and
    /// whether that change was a deletion. Both stores and CloudKit can supply
    /// these two facts cheaply.
    struct Side: Equatable {
        var updatedAt: Date
        var isDeleted: Bool
    }

    /// Resolve one id. `local`/`remote` are nil when that side has never seen
    /// the record.
    static func resolve(local: Side?, remote: Side?) -> Resolution {
        switch (local, remote) {
        case (nil, nil):
            return .noChange
        case (nil, .some(let r)):
            // New on remote only.
            return r.isDeleted ? .noChange : .applyRemoteUpsert
        case (.some(let l), nil):
            // New on local only.
            return l.isDeleted ? .noChange : .pushLocalUpsert
        case (.some(let l), .some(let r)):
            // Both sides know it — newest write wins. Ties favour local so a
            // device doesn't ping-pong a record it just wrote.
            if r.updatedAt > l.updatedAt {
                return r.isDeleted ? .applyRemoteDelete : .applyRemoteUpsert
            } else if l.updatedAt > r.updatedAt {
                return l.isDeleted ? .pushLocalDelete : .pushLocalUpsert
            } else {
                return .noChange
            }
        }
    }
}
