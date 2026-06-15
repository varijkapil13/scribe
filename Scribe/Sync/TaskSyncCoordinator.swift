import CloudKit
import Foundation

/// Local side of task sync, abstracted so the coordinator can be unit-tested
/// against a fake. `TaskStore` conforms (its methods match 1:1).
protocol LocalTaskSyncing {
    func localTaskSides() throws -> [String: SyncMergePolicy.Side]
    func tasks(forIDs ids: [String]) throws -> [TodoTask]
    func upsertFromSync(_ task: TodoTask) throws
    func applyRemoteDelete(id: String) throws
}

/// Remote (CloudKit) side, abstracted likewise. `CloudKitSyncService` conforms.
protocol RemoteTaskSyncing {
    func ensureZone() async throws
    func pullChanges(since token: CKServerChangeToken?) async throws -> CloudKitSyncService.PullResult
    func push(upserts: [TodoTask], deletions: [String]) async throws -> Int
}

extension TaskStore: LocalTaskSyncing {}
extension CloudKitSyncService: RemoteTaskSyncing {}

/// Persists the incremental-sync cursors between runs: CloudKit's zone change
/// token (for pulls) and the high-water mark for local pushes.
protocol SyncCursorStoring: AnyObject {
    var changeToken: CKServerChangeToken? { get set }
    var lastPushDate: Date? { get set }
}

/// `UserDefaults`-backed cursor store. The change token is a `NSSecureCoding`
/// object archived to `Data`.
final class UserDefaultsSyncCursorStore: SyncCursorStoring {
    private let defaults: UserDefaults
    private let tokenKey = "taskSync.changeToken"
    private let pushKey = "taskSync.lastPushDate"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var changeToken: CKServerChangeToken? {
        get {
            guard let data = defaults.data(forKey: tokenKey) else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }
        set {
            if let token = newValue,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
                defaults.set(data, forKey: tokenKey)
            } else {
                defaults.removeObject(forKey: tokenKey)
            }
        }
    }

    var lastPushDate: Date? {
        get { defaults.object(forKey: pushKey) as? Date }
        set { defaults.set(newValue, forKey: pushKey) }
    }
}

/// Drives one round of task sync: pull remote changes (applying last-writer-wins
/// per record), then push everything changed locally since the last push.
///
/// ⚠️ DEVICE-VALIDATION REQUIRED for the live path (needs the provisioned
/// iCloud container). The decision logic — `SyncMergePolicy`/`SyncReconciler`
/// and this coordinator over fakes — is unit-tested.
final class TaskSyncCoordinator {
    private let local: LocalTaskSyncing
    private let remote: RemoteTaskSyncing
    private let cursor: SyncCursorStoring

    init(local: LocalTaskSyncing,
         remote: RemoteTaskSyncing,
         cursor: SyncCursorStoring = UserDefaultsSyncCursorStore()) {
        self.local = local
        self.remote = remote
        self.cursor = cursor
    }

    /// The production coordinator wired to the shared task store + CloudKit.
    /// Computed (not a stored singleton) so it carries no cross-actor state;
    /// the cursor it uses persists in `UserDefaults`.
    static var live: TaskSyncCoordinator {
        TaskSyncCoordinator(
            local: TaskStore.shared,
            remote: CloudKitSyncService(),
            cursor: UserDefaultsSyncCursorStore()
        )
    }

    /// Full round-trip. No-op unless the user opted into iCLoud sync.
    func sync() async throws {
        guard CloudKitSyncService.isEnabled else { return }
        try await remote.ensureZone()
        try await pullRemoteChanges()
        try await pushLocalChanges()
    }

    /// Applies remote changes with per-record last-writer-wins, then advances
    /// the change token. Internal (not private) so it's unit-testable directly.
    func pullRemoteChanges() async throws {
        let result = try await remote.pullChanges(since: cursor.changeToken)
        let localSides = try local.localTaskSides()

        for task in result.changed {
            let remoteSide = SyncMergePolicy.Side(updatedAt: task.updatedAt, isDeleted: false)
            if SyncMergePolicy.resolve(local: localSides[task.id], remote: remoteSide) == .applyRemoteUpsert {
                try local.upsertFromSync(task)
            }
        }
        // CloudKit deletions carry no timestamp, so they're treated as
        // authoritative for the zone; a locally-newer edit re-uploads on the
        // next push (benign resurrection window, refined in the device phase).
        for id in result.deletedIDs {
            try local.applyRemoteDelete(id: id)
        }
        cursor.changeToken = result.token
    }

    /// Pushes everything changed locally since the last push (live upserts +
    /// tombstoned deletes). On first run `lastPushDate` is nil → full upload.
    func pushLocalChanges() async throws {
        let since = cursor.lastPushDate ?? .distantPast
        let pushedAt = Date()
        let sides = try local.localTaskSides()

        var upsertIDs: [String] = []
        var deletionIDs: [String] = []
        for (id, side) in sides where side.updatedAt > since {
            if side.isDeleted { deletionIDs.append(id) } else { upsertIDs.append(id) }
        }

        let tasks = try local.tasks(forIDs: upsertIDs)
        _ = try await remote.push(upserts: tasks, deletions: deletionIDs)
        cursor.lastPushDate = pushedAt
    }
}
