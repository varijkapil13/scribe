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
    /// Pushes a taxonomy-aware round (tasks with tags, areas, projects,
    /// headings, deletions). See the default below for older fakes.
    func push(batch: TaskSyncPushBatch) async throws -> Int
}

extension RemoteTaskSyncing {
    /// Default for conformers that predate taxonomy sync (test fakes): only
    /// the task half of the batch. `CloudKitSyncService` implements it fully.
    func push(batch: TaskSyncPushBatch) async throws -> Int {
        try await push(upserts: batch.tasks, deletions: batch.taskDeletions)
    }
}

extension TaskStore: LocalTaskSyncing {}
extension CloudKitSyncService: RemoteTaskSyncing {}

/// Persists the incremental-sync cursors between runs: CloudKit's zone change
/// token (for pulls) and the high-water mark for local pushes.
protocol SyncCursorStoring: AnyObject {
    var changeToken: CKServerChangeToken? { get set }
    var lastPushDate: Date? { get set }
}

/// High-water mark for taxonomy pushes. Nil on a device that hasn't pushed
/// taxonomy yet (fresh install, or just upgraded): that round uploads every
/// area / project / heading and re-sends every task so its tags travel too.
protocol TaxonomySyncCursorStoring: AnyObject {
    var taxonomyLastPushDate: Date? { get set }
}

/// `UserDefaults`-backed cursor store. The change token is a `NSSecureCoding`
/// object archived to `Data`.
final class UserDefaultsSyncCursorStore: SyncCursorStoring, TaxonomySyncCursorStoring {
    private let defaults: UserDefaults
    private let tokenKey = "taskSync.changeToken"
    private let pushKey = "taskSync.lastPushDate"
    private let taxonomyPushKey = "taskSync.taxonomyLastPushDate"

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

    var taxonomyLastPushDate: Date? {
        get { defaults.object(forKey: taxonomyPushKey) as? Date }
        set { defaults.set(newValue, forKey: taxonomyPushKey) }
    }
}

/// The taxonomy half of a round: where areas / projects / headings / tags
/// live locally, and its push cursor.
struct TaxonomySyncSetup {
    var store: LocalTaxonomySyncing
    var cursor: TaxonomySyncCursorStoring
}

/// Drives one round of task sync: pull remote changes (applying last-writer-wins
/// per record), then push everything changed locally since the last push.
///
/// With a `TaxonomySyncSetup` (the live configuration) the round also syncs
/// areas, projects, project headings and task tags, all in the 'Tasks' zone:
/// pulled rows apply areas → projects → headings → tasks so references
/// resolve; a reference whose target hasn't arrived falls back (task →
/// Inbox) and is resolved on a later pull (`resolvePendingTaxonomyReferences`).
///
/// ⚠️ DEVICE-VALIDATION REQUIRED for the live path (needs the provisioned
/// iCloud container). The decision logic — `SyncMergePolicy`/`SyncReconciler`
/// and this coordinator over fakes — is unit-tested.
final class TaskSyncCoordinator {
    private let local: LocalTaskSyncing
    private let remote: RemoteTaskSyncing
    private let cursor: SyncCursorStoring
    private let taxonomy: TaxonomySyncSetup?

    /// Remote tasks shown in Inbox because their project hasn't reached this
    /// device yet (taxonomy rounds; resolved automatically when it arrives).
    /// Surfaced by the iOS sync status.
    private(set) var skippedForMissingProject = 0

    /// Rows the last pull wrote from the server ("kind:id" → the remote
    /// `updatedAt`), so the push in the same round doesn't echo them back.
    private var appliedFromRemote: [String: Date] = [:]

    /// Upper bound on zone-change pages fetched in one round.
    static let maxPullPagesPerRound = 50

    /// Timestamps round-trip through SQLite at millisecond precision; two
    /// stamps closer than this are the same write.
    static let timestampTolerance: TimeInterval = 0.002

    /// Pushes look this far behind the cursor, so an edit stamped in the same
    /// millisecond as the previous push (stored truncated) isn't missed. A
    /// re-sent unchanged row is a no-op for last-writer-wins.
    static let pushCursorMargin: TimeInterval = 0.002

    init(local: LocalTaskSyncing,
         remote: RemoteTaskSyncing,
         cursor: SyncCursorStoring = UserDefaultsSyncCursorStore(),
         taxonomy: TaxonomySyncSetup? = nil) {
        self.local = local
        self.remote = remote
        self.cursor = cursor
        self.taxonomy = taxonomy
    }

    /// The production coordinator wired to the shared task store + CloudKit.
    /// Computed (not a stored singleton) so it carries no cross-actor state;
    /// the cursor it uses persists in `UserDefaults`.
    static var live: TaskSyncCoordinator {
        let cursor = UserDefaultsSyncCursorStore()
        return TaskSyncCoordinator(
            local: TaskStore.shared,
            remote: CloudKitSyncService(),
            cursor: cursor,
            taxonomy: TaxonomySyncSetup(store: TaskStore.shared, cursor: cursor)
        )
    }

    /// Full round-trip. No-op unless the user opted into iCLoud sync.
    func sync() async throws {
        _ = try await syncReportingSkipped()
    }

    /// `sync()`, returning how many remote tasks wait in Inbox for their
    /// project (a Sendable result, so callers needn't touch the coordinator
    /// again after the round).
    @discardableResult
    func syncReportingSkipped() async throws -> Int {
        guard CloudKitSyncService.isEnabled else { return 0 }
        try await remote.ensureZone()
        try await pullRemoteChanges()
        try await pushLocalChanges()
        return skippedForMissingProject
    }

    // MARK: - Pull

    /// Applies remote changes with per-record last-writer-wins, then advances
    /// the change token (page by page while the server has more). Internal
    /// (not private) so it's unit-testable directly.
    func pullRemoteChanges() async throws {
        appliedFromRemote = [:]
        skippedForMissingProject = 0
        var token = cursor.changeToken
        if let taxonomy, taxonomy.cursor.taxonomyLastPushDate == nil {
            // First taxonomy-aware round on this device: re-read the whole
            // zone. Records an older version skipped (tasks in projects it
            // didn't have) or couldn't read (areas, projects, headings, tags)
            // sit before the stored token. Last-writer-wins makes re-applying
            // the rest a no-op.
            token = nil
        }
        var pages = 0
        while true {
            let result = try await remote.pullChanges(since: token)
            if let taxonomy {
                try applyTaxonomyAware(result, store: taxonomy.store)
            } else {
                try applyTasksOnly(result)
            }
            token = result.token
            cursor.changeToken = token
            pages += 1
            if !result.moreComing || pages >= Self.maxPullPagesPerRound { break }
        }
        if let taxonomy {
            skippedForMissingProject = try taxonomy.store.taxonomySyncCounts().tasksAwaitingProject
            if skippedForMissingProject > 0 {
                Log.storage.info("Task sync: \(self.skippedForMissingProject, privacy: .public) task(s) wait in Inbox for their project.")
            }
        }
    }

    /// Tasks only (no taxonomy configured).
    private func applyTasksOnly(_ result: CloudKitSyncService.PullResult) throws {
        let localSides = try local.localTaskSides()
        for task in result.changed {
            let remoteSide = SyncMergePolicy.Side(updatedAt: task.updatedAt, isDeleted: false)
            if SyncMergePolicy.resolve(local: localSides[task.id], remote: remoteSide) == .applyRemoteUpsert {
                try local.upsertFromSync(task)
                appliedFromRemote[Self.key("task", task.id)] = task.updatedAt
            }
        }
        // CloudKit deletions carry no timestamp, so they're treated as
        // authoritative for the zone; a locally-newer edit re-uploads on the
        // next push (benign resurrection window, refined in the device phase).
        for id in result.deletedIDs {
            try local.applyRemoteDelete(id: id)
        }
    }

    /// One page with taxonomy: areas → projects → headings → tasks (+ tags),
    /// then deletions, then any waiting references that can now resolve.
    private func applyTaxonomyAware(_ result: CloudKitSyncService.PullResult,
                                    store: LocalTaxonomySyncing) throws {
        let sides = try store.localTaxonomySides()
        for entry in result.areas where Self.remoteWins(sides.areas[entry.item.id], entry.updatedAt) {
            try store.applyRemoteArea(entry)
            appliedFromRemote[Self.key(.area, entry.item.id)] = entry.updatedAt
        }
        for entry in result.projects where Self.remoteWins(sides.projects[entry.item.id], entry.updatedAt) {
            try store.applyRemoteProject(entry)
            appliedFromRemote[Self.key(.project, entry.item.id)] = entry.updatedAt
        }
        for entry in result.headings where Self.remoteWins(sides.headings[entry.item.id], entry.updatedAt) {
            try store.applyRemoteHeading(entry)
            appliedFromRemote[Self.key(.heading, entry.item.id)] = entry.updatedAt
        }

        let taskSides = try local.localTaskSides()
        for task in result.changed {
            let tags = result.taskTags[task.id]
            let localSide = taskSides[task.id]
            if Self.remoteWins(localSide, task.updatedAt) {
                try store.applyRemoteTask(task, tags: tags,
                                          linksAuthoritative: result.taskLinksAuthoritative.contains(task.id))
                appliedFromRemote[Self.key("task", task.id)] = task.updatedAt
            } else if let tags, let localSide, !localSide.isDeleted,
                      Self.sameStamp(localSide.updatedAt, task.updatedAt) {
                // Same version on both sides, but tags may never have been
                // exchanged (e.g. the first round after upgrading): union.
                try store.mergeRemoteTagsOnTie(taskID: task.id, tags: tags)
            }
        }

        // Deletions carry no timestamp: authoritative, like task deletions.
        for id in result.deletedHeadingIDs { try store.applyRemoteTaxonomyDelete(.heading, id: id) }
        for id in result.deletedProjectIDs { try store.applyRemoteTaxonomyDelete(.project, id: id) }
        for id in result.deletedAreaIDs { try store.applyRemoteTaxonomyDelete(.area, id: id) }
        for id in result.deletedIDs { try local.applyRemoteDelete(id: id) }

        try store.resolvePendingTaxonomyReferences()
    }

    // MARK: - Push

    /// Pushes everything changed locally since the last push (live upserts +
    /// tombstoned deletes). On first run `lastPushDate` is nil → full upload.
    func pushLocalChanges() async throws {
        guard let taxonomy else {
            try await pushTasksOnly()
            return
        }
        let pushedAt = Date()
        let store = taxonomy.store
        let taxonomyCursor = taxonomy.cursor.taxonomyLastPushDate
        let taxonomySince = taxonomyCursor.map { $0.addingTimeInterval(-Self.pushCursorMargin) } ?? .distantPast
        // The first taxonomy push re-sends every task, so tags written before
        // tag sync existed reach the other devices.
        let taskSince: Date
        if taxonomyCursor == nil {
            taskSince = .distantPast
        } else {
            taskSince = (cursor.lastPushDate ?? .distantPast).addingTimeInterval(-Self.pushCursorMargin)
        }

        var batch = TaskSyncPushBatch()
        let taskSides = try local.localTaskSides()
        let tasks = changedIDs(taskSides, since: taskSince, kind: "task")
        batch.tasks = try store.tasksForSyncPush(ids: tasks.upserts)
        batch.taskTags = try store.tagsForSyncPush(taskIDs: batch.tasks.map(\.id))
        batch.taskDeletions = tasks.deletions

        let sides = try store.localTaxonomySides()
        let areas = changedIDs(sides.areas, since: taxonomySince, kind: TaxonomySyncKind.area.rawValue)
        let projects = changedIDs(sides.projects, since: taxonomySince, kind: TaxonomySyncKind.project.rawValue)
        let headings = changedIDs(sides.headings, since: taxonomySince, kind: TaxonomySyncKind.heading.rawValue)
        batch.areas = try store.areasForSyncPush(ids: areas.upserts)
        batch.projects = try store.projectsForSyncPush(ids: projects.upserts)
        batch.headings = try store.headingsForSyncPush(ids: headings.upserts)
        batch.deletedAreaIDs = areas.deletions
        batch.deletedProjectIDs = projects.deletions
        batch.deletedHeadingIDs = headings.deletions

        if !batch.isEmpty {
            _ = try await remote.push(batch: batch)
        }
        cursor.lastPushDate = pushedAt
        taxonomy.cursor.taxonomyLastPushDate = pushedAt
    }

    /// The original task-only push (no taxonomy configured).
    private func pushTasksOnly() async throws {
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

    /// Ids changed after `since`, split into upserts and deletions (sorted,
    /// for deterministic batches), minus rows this round just pulled and
    /// hasn't changed since.
    private func changedIDs(_ sides: [String: SyncMergePolicy.Side], since: Date,
                            kind: String) -> (upserts: [String], deletions: [String]) {
        var upserts: [String] = []
        var deletions: [String] = []
        for (id, side) in sides where side.updatedAt > since {
            if side.isDeleted {
                deletions.append(id)
            } else if let pulled = appliedFromRemote[Self.key(kind, id)], Self.sameStamp(pulled, side.updatedAt) {
                continue   // the server already has exactly this version
            } else {
                upserts.append(id)
            }
        }
        return (upserts.sorted(), deletions.sorted())
    }

    // MARK: - Helpers

    /// Last-writer-wins: does the remote version replace the local one?
    static func remoteWins(_ local: SyncMergePolicy.Side?, _ remoteUpdatedAt: Date) -> Bool {
        let remoteSide = SyncMergePolicy.Side(updatedAt: remoteUpdatedAt, isDeleted: false)
        if let local, sameStamp(local.updatedAt, remoteUpdatedAt) { return false }
        return SyncMergePolicy.resolve(local: local, remote: remoteSide) == .applyRemoteUpsert
    }

    static func sameStamp(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < timestampTolerance
    }

    private static func key(_ kind: String, _ id: String) -> String { "\(kind):\(id)" }
    private static func key(_ kind: TaxonomySyncKind, _ id: String) -> String { key(kind.rawValue, id) }
}
