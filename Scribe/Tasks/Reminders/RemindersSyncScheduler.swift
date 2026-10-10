#if canImport(EventKit)
import EventKit
import Foundation
import GRDB

/// Kicks automatic Apple Reminders sync rounds (Mac and iPhone / iPad; the
/// iOS app starts it from `TasksIOSBootstrap`). Triggers: launch,
/// the sync being enabled (or its settings changing), the app becoming active
/// (throttled), Reminders changing (`EKEventStoreChanged`, debounced) and local
/// task edits (GRDB observation, debounced). Every trigger self-gates on the
/// toggle AND full Reminders access, so nothing runs — and no prompt
/// appears — until the user opts in under Settings → Reminders.
///
/// Reuses `TaskSyncTriggerPolicy` for the timing rules (activation throttle,
/// post-round quiet period); store changes count as `.localChange` once
/// debounced.
@MainActor
final class RemindersSyncScheduler {

    static let shared: RemindersSyncScheduler = makeShared()

    /// Closures built in a main-actor function, not in the `static let`
    /// initializer (where they'd be inferred `@concurrent`).
    private static func makeShared() -> RemindersSyncScheduler {
        RemindersSyncScheduler(
            policy: TaskSyncTriggerPolicy(activationInterval: 2 * 60, postSyncQuietPeriod: 3),
            debounce: .seconds(4),
            isSyncAllowed: { @MainActor in RemindersSyncService.shared.isActive },
            settingsSignature: { @MainActor in RemindersSyncSettings.signature },
            runSync: { @MainActor in try await RemindersSyncService.shared.sync() }
        )
    }

    private var policy: TaskSyncTriggerPolicy
    private let debounce: Duration
    private let isSyncAllowed: @MainActor () -> Bool
    private let settingsSignature: @MainActor () -> String
    private let runSync: @MainActor () async throws -> Void

    private var started = false
    private var lastSignature = ""
    private var defaultsObserver: (any NSObjectProtocol)?
    private var storeObserver: (any NSObjectProtocol)?
    private var taskObservation: AnyDatabaseCancellable?
    private var debounceTask: Task<Void, Never>?
    /// A change arrived mid-round; run one debounced follow-up afterwards.
    private var pendingChange = false

    /// The running round, if any (exposed for tests to await).
    private(set) var inFlight: Task<Void, Never>?

    var isSyncing: Bool { policy.isSyncing }

    init(
        policy: TaskSyncTriggerPolicy,
        debounce: Duration,
        isSyncAllowed: @escaping @MainActor () -> Bool,
        settingsSignature: @escaping @MainActor () -> String,
        runSync: @escaping @MainActor () async throws -> Void
    ) {
        self.policy = policy
        self.debounce = debounce
        self.isSyncAllowed = isSyncAllowed
        self.settingsSignature = settingsSignature
        self.runSync = runSync
    }

    // MARK: - Lifecycle

    /// Starts observing settings, Reminders and local tasks, and runs the
    /// launch round. Idempotent.
    func start(database: DatabaseQueue) {
        guard !started else { return }
        started = true
        lastSignature = settingsSignature()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsDidChange() }
        }

        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.externalOrLocalChange() }
        }

        taskObservation = Self.observeLocalTaskChanges(in: database) { [weak self] in
            // Re-capture weakly by value: a nested Sendable closure may not
            // capture the outer closure's `weak var self` by reference.
            Task { @MainActor [weak self] in self?.externalOrLocalChange() }
        }

        request(.launch)
    }

    /// Call when the app becomes active; throttled by the policy.
    func appDidBecomeActive() {
        request(.activation)
    }

    /// Runs a round now (Settings → Sync Now), unless one is running.
    func syncNow() {
        request(.enabled)
    }

    // MARK: - Triggers

    /// Any Reminders setting changed (toggle on, list, mapping, direction):
    /// sync right away so the user sees the effect.
    func settingsDidChange() {
        let signature = settingsSignature()
        guard signature != lastSignature else { return }
        lastSignature = signature
        guard !policy.isSyncing else {
            // The running round read the old settings; the policy would drop
            // a request now, so follow up once it finishes instead.
            if isSyncAllowed() { pendingChange = true }
            return
        }
        request(.enabled)
    }

    /// Reminders or local tasks changed: (re)arm the debounce.
    func externalOrLocalChange() {
        guard isSyncAllowed() else { return }
        guard !policy.isSyncing else {
            // Possibly our own writes echoing back; a follow-up round is a
            // cheap no-op if so, and catches real edits if not.
            pendingChange = true
            return
        }
        armDebounce()
    }

    private func armDebounce() {
        debounceTask?.cancel()
        let delay = max(debounce, .seconds(policy.postSyncQuietPeriod))
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            if self.policy.isSyncing {
                self.pendingChange = true
            } else {
                self.request(.localChange)
            }
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
                Log.app.error("Reminders sync failed: \(error.localizedDescription, privacy: .private)")
            }
            self.policy.didFinish(at: Date())
            self.inFlight = nil
            if self.pendingChange {
                self.pendingChange = false
                if self.isSyncAllowed() { self.armDebounce() }
            }
        }
    }

    // MARK: - Database observation

    /// Observes the `tasks` table. `nonisolated` so GRDB's change callback
    /// (invoked on the database queue) is not a main-actor closure.
    nonisolated private static func observeLocalTaskChanges(
        in database: DatabaseQueue,
        onChange: @escaping @Sendable () -> Void
    ) -> AnyDatabaseCancellable {
        let observation = DatabaseRegionObservation(tracking: TodoTask.all())
        return observation.start(
            in: database,
            onError: { error in
                Log.storage.error("Reminders-sync change observation failed: \(error.localizedDescription, privacy: .private)")
            },
            onChange: { _ in onChange() }
        )
    }
}
#endif
