import Foundation

/// Pure decisions for meeting sync: last-writer-wins on the session record's
/// `updatedAt`, tombstones, the in-progress rule and when a transcript has to
/// be (re)transferred. Free of CloudKit and the database so it's unit-tested.
enum MeetingSyncMergePolicy {

    /// One side's view of a session for merge purposes.
    struct Side: Equatable, Sendable {
        var updatedAt: Date
        var isDeleted: Bool
        /// A local recording still running (never synced, never overwritten).
        var isInProgress: Bool

        init(updatedAt: Date, isDeleted: Bool, isInProgress: Bool = false) {
            self.updatedAt = updatedAt
            self.isDeleted = isDeleted
            self.isInProgress = isInProgress
        }
    }

    enum Resolution: Equatable, Sendable {
        /// Local is as new or newer (or still recording): keep it; a dirty
        /// local copy goes up on the push half of the round.
        case keepLocal
        /// Remote is newer: import it (creating the session if needed).
        case applyRemote
        /// Remote tombstone is newer: delete the local session.
        case applyRemoteDelete
        /// Remote tombstone for a session this device never had: remember it
        /// so a stale copy arriving later can't resurrect it.
        case rememberTombstone
    }

    /// Clock differences below this are treated as equal: SQLite keeps
    /// milliseconds, so a value that went through the database and back
    /// mustn't look "newer" than itself.
    nonisolated static let clockTolerance: TimeInterval = 0.002

    nonisolated static func resolve(local: Side?, remote: Side) -> Resolution {
        guard let local else {
            return remote.isDeleted ? .rememberTombstone : .applyRemote
        }
        if local.isInProgress { return .keepLocal }
        guard remote.updatedAt.timeIntervalSince(local.updatedAt) > clockTolerance else {
            // Ties favour local so a device doesn't re-import what it pushed.
            return .keepLocal
        }
        if remote.isDeleted {
            // Remote delete is newer. A local tombstone already agrees.
            return local.isDeleted ? .keepLocal : .applyRemoteDelete
        }
        return .applyRemote
    }

    /// A session may be pushed only once its recording has finished.
    nonisolated static func isPushable(endedAt: Date?) -> Bool {
        endedAt != nil
    }

    /// Whether an import has to fetch / apply the transcript: the remote
    /// version names a transcript and it differs from the one we hold.
    nonisolated static func needsTranscript(remoteHash: String?, localHash: String?) -> Bool {
        guard let remoteHash else { return false }
        return remoteHash != localHash
    }
}
