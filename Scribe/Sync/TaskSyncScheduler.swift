import Foundation
import GRDB

/// Pure timing rules for when an automatic task-sync round may start.
/// Kept free of clocks, tasks and I/O so it's unit-testable.
struct TaskSyncTriggerPolicy {

    /// Why a sync round is being requested.
    enum Trigger: Equatable {
        /// App launch.
        case launch
        /// The user just turned the iCloud task-sync toggle on.
        case enabled
        /// The app became active (throttled by `activationInterval`).
        case activation
        /// Local tasks changed (already debounced by the caller).
        case localChange
    }

    /// Minimum time between activation-triggered rounds, so flipping between
    /// apps doesn't hammer CloudKit.
    var activationInterval: TimeInterval = 5 * 60

    /// Local-change notifications arriving this soon after a round finished
    /// are treated as the echo of that round's own writes (pulled remote
    /// changes land in the local tables too) and ignored.
    var postSyncQuietPeriod: TimeInterval = 3

    private(set) var isSyncing = false
    private(set) var lastStart: Date?
    private(set) var lastFinish: Date?

    init(activationInterval: TimeInterval = 5 * 60, postSyncQuietPeriod: TimeInterval = 3) {
        self.activationInterval = activationInterval
        self.postSyncQuietPeriod = postSyncQuietPeriod
    }

    /// Whether a round for `trigger` may start at `now`.
    func shouldStart(_ trigger: Trigger, now: Date) -> Bool {
        guard !isSyncing else { return false }
        switch trigger {
        case .launch, .enabled:
            return true
        case .activation:
            guard let lastStart else { return true }
            return now.timeIntervalSince(lastStart) >= activationInterval
        case .localChange:
            guard let lastFinish else { return true }
            return now.timeIntervalSince(lastFinish) >= postSyncQuietPeriod
        }
    }

    /// Whether a local-change notification at `now` should (re)arm the
    /// debounce. Changes during a round or in its quiet period are echoes.
    func acceptsLocalChange(now: Date) -> Bool {
        guard !isSyncing else { return false }
        guard let lastFinish else { return true }
        return now.timeIntervalSince(lastFinish) >= postSyncQuietPeriod
    }

    mutating func didStart(at date: Date) {
        isSyncing = true
        lastStart = date
    }

    mutating func didFinish(at date: Date) {
        isSyncing = false
        lastFinish = date
    }
}

/// Kicks automatic CloudKit task-sync rounds on the Mac (the iOS app syncs from
/// `RootTabView` on foreground). Triggers: launch, the iCloud toggle being
/// turned on, the app becoming active (throttled), and local task edits
/// (debounced). Every trigger self-gates on `CloudKitAvailability.canSyncTasks`
/// — the opt-in toggle AND a CloudKit-entitled binary — so it's a no-op until
/// the user opts in and the container is provisioned.
///
/// Uses only Foundation + GRDB (no AppKit); the app delegate feeds it the
/// lifecycle events.
@MainActor
final class TaskSyncScheduler {

    static let shared = TaskSyncScheduler(
        isSyncAllowed: { CloudKitAvailability.canSyncTasks },
        isToggleOn: { CloudKitSyncService.isEnabled },
        runSync: { try await TaskSyncCoordinator.live.sync() }
    )

    private var policy: TaskSyncTriggerPolicy
    private let isSyncAllowed: @MainActor () -> Bool
    private let isToggleOn: @MainActor () -> Bool
    private let runSync: @MainActor () async throws -> Void
    private let localChangeDebounce: Duration

    private var lastKnownToggle = false
    private var started = false
    private var defaultsObserver: (any NSObjectProtocol)?
    private var taskObservation: AnyDatabaseCancellable?
    private var debounceTask: Task<Void, Never>?

    /// The running round, if any (exposed for tests to await).
    private(set) var inFlight: Task<Void, Never>?

    /// Whether a round is currently running.
    var isSyncing: Bool { policy.isSyncing }

    init(
        policy: TaskSyncTriggerPolicy = TaskSyncTriggerPolicy(),
        localChangeDebounce: Duration = .seconds(5),
        isSyncAllowed: @escaping @MainActor () -> Bool,
        isToggleOn: @escaping @MainActor () -> Bool,
        runSync: @escaping @MainActor () async throws -> Void
    ) {
        self.policy = policy
        self.localChangeDebounce = localChangeDebounce
        self.isSyncAllowed = isSyncAllowed
        self.isToggleOn = isToggleOn
        self.runSync = runSync
    }

    // MARK: - Lifecycle

    /// Starts observing the toggle and local task changes, and runs the launch
    /// round. Idempotent.
    func start(database: DatabaseQueue = DatabaseManager.shared.database) {
        guard !started else { return }
        started = true
        lastKnownToggle = isToggleOn()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsDidChange() }
        }

        taskObservation = Self.observeLocalTaskChanges(in: database) { [weak self] in
            Task { @MainActor in self?.localTasksDidChange() }
        }

        request(.launch)
    }

    /// Call when the app becomes active; throttled by the policy.
    func appDidBecomeActive() {
        request(.activation)
    }

    // MARK: - Triggers

    /// Re-reads the toggle; an off→on flip syncs immediately.
    func defaultsDidChange() {
        let now = isToggleOn()
        defer { lastKnownToggle = now }
        if now && !lastKnownToggle {
            request(.enabled)
        }
    }

    /// A local task (or tombstone) row changed: (re)arm the debounce.
    func localTasksDidChange() {
        guard isSyncAllowed(), policy.acceptsLocalChange(now: Date()) else { return }
        debounceTask?.cancel()
        let delay = localChangeDebounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.request(.localChange)
        }
    }

    /// Starts a round for `trigger` if sync is allowed and the policy agrees.
    func request(_ trigger: TaskSyncTriggerPolicy.Trigger) {
        guard isSyncAllowed() else { return }
        let now = Date()
        guard policy.shouldStart(trigger, now: now) else { return }
        policy.didStart(at: now)
        inFlight = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runSync()
            } catch {
                Log.storage.error("Task sync failed: \(error.localizedDescription, privacy: .private)")
            }
            self.policy.didFinish(at: Date())
            self.inFlight = nil
        }
    }

    // MARK: - Database observation

    /// Observes the tables task sync reads (`tasks` + `task_tombstones`).
    /// `nonisolated` so GRDB's change callback (invoked on the database
    /// queue) is not a main-actor closure; it only forwards a Sendable ping.
    nonisolated private static func observeLocalTaskChanges(
        in database: DatabaseQueue,
        onChange: @escaping @Sendable () -> Void
    ) -> AnyDatabaseCancellable {
        let observation = DatabaseRegionObservation(
            tracking: TodoTask.all(),
            SQLRequest<Row>(sql: "SELECT * FROM task_tombstones")
        )
        return observation.start(
            in: database,
            onError: { error in
                Log.storage.error("Task-sync change observation failed: \(error.localizedDescription, privacy: .private)")
            },
            onChange: { _ in onChange() }
        )
    }
}
