import Combine
import Foundation
import GRDB

/// Pure timing rules for automatic meeting-sync rounds (no clocks / I/O, so
/// it's unit-tested).
struct MeetingSyncTriggerPolicy {

    enum Trigger: Equatable, Sendable {
        /// App launch.
        case launch
        /// "Sync meetings" (or "Sync recording audio") was just turned on.
        case enabled
        /// The app became active — throttled.
        case activation
        /// A finished meeting changed locally (a recording finished, a
        /// speaker was renamed, a meeting was deleted) — already debounced.
        case localChange
        /// The periodic background round — throttled like activation.
        case periodic
        /// "Sync Now".
        case manual
    }

    /// Minimum time between throttled (activation / periodic) rounds.
    var throttleInterval: TimeInterval

    private(set) var isSyncing = false
    private(set) var lastStart: Date?
    private(set) var lastFinish: Date?

    init(throttleInterval: TimeInterval) {
        self.throttleInterval = throttleInterval
    }

    func shouldStart(_ trigger: Trigger, now: Date) -> Bool {
        guard !isSyncing else { return false }
        switch trigger {
        case .launch, .enabled, .localChange, .manual:
            return true
        case .activation, .periodic:
            guard let lastStart else { return true }
            return now.timeIntervalSince(lastStart) >= throttleInterval
        }
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

/// Kicks meeting-sync rounds on the Mac and on iPhone / iPad: at launch, when
/// "Sync meetings" is turned on, when the app becomes active (throttled), on
/// a periodic round while the app runs, and shortly after a finished meeting
/// changes locally (a recording finishing ends its session, which the v28
/// triggers record). A recording in progress never starts a round — its
/// session isn't pushable until it ends.
///
/// Every trigger self-gates on `MeetingSyncSettings.canSync` (the iCloud
/// opt-in, the "Sync meetings" sub-toggle and a CloudKit-entitled build), so
/// this is a no-op until the user opts in. Foundation + GRDB + Combine only.
@MainActor
final class MeetingSyncScheduler: ObservableObject {

    static let shared: MeetingSyncScheduler = makeShared()

    /// Builds the closures in a main-actor function rather than in the
    /// `static let` initializer (see `TaskSyncScheduler.makeShared`).
    private static func makeShared() -> MeetingSyncScheduler {
        MeetingSyncScheduler(
            policy: MeetingSyncTriggerPolicy(throttleInterval: 5 * 60),
            changeDebounce: .seconds(15),
            periodicInterval: .seconds(15 * 60),
            localStore: MeetingSyncLocalStore.shared,
            isSyncAllowed: { @MainActor in MeetingSyncSettings.canSync() },
            makeEngine: { @MainActor in
                MeetingSyncEngine(
                    local: MeetingSyncLocalStore.shared,
                    cloud: MeetingCloudKitService(containerIdentifier: "iCloud.com.varij.scribe")
                )
            }
        )
    }

    // MARK: - Observable status (Settings rows)

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var lastReport: MeetingSyncRoundReport?

    /// Platform hook run after a round created, changed or removed local
    /// sessions (the Mac refreshes its lists and the semantic index). The
    /// `scribeMeetingSyncDidChangeSessions` notification is posted as well.
    var onSessionsChanged: (@MainActor ([String]) -> Void)?

    // MARK: - Dependencies

    private var policy: MeetingSyncTriggerPolicy
    private let changeDebounce: Duration
    private let periodicInterval: Duration
    private let localStore: MeetingSyncLocalStore
    private let isSyncAllowed: @MainActor () -> Bool
    private let makeEngine: @MainActor () -> MeetingSyncEngine
    private var engine: MeetingSyncEngine?

    private var started = false
    private var lastKnownAllowed = false
    private var lastKnownAudio = false
    private var defaultsObserver: (any NSObjectProtocol)?
    private var observation: AnyDatabaseCancellable?
    private var debounceTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    /// A change arrived while a round ran: follow up once it finishes.
    private var pendingFollowUp = false

    /// The running round (exposed for tests to await).
    private(set) var inFlight: Task<Void, Never>?

    init(
        policy: MeetingSyncTriggerPolicy,
        changeDebounce: Duration,
        periodicInterval: Duration,
        localStore: MeetingSyncLocalStore,
        isSyncAllowed: @escaping @MainActor () -> Bool,
        makeEngine: @escaping @MainActor () -> MeetingSyncEngine
    ) {
        self.policy = policy
        self.changeDebounce = changeDebounce
        self.periodicInterval = periodicInterval
        self.localStore = localStore
        self.isSyncAllowed = isSyncAllowed
        self.makeEngine = makeEngine
    }

    // MARK: - Lifecycle

    /// Observes the toggles and local meeting changes, starts the periodic
    /// round and runs the launch round. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        lastKnownAllowed = isSyncAllowed()
        lastKnownAudio = MeetingSyncSettings.isAudioSyncOn()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsDidChange() }
        }

        observation = Self.observeLocalMeetingChanges(in: localStore.dbManager.database) { [weak self] in
            Task { @MainActor [weak self] in self?.localMeetingsDidChange() }
        }

        let interval = periodicInterval
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.request(.periodic)
            }
        }

        request(.launch)
    }

    /// Call when the app becomes active; throttled.
    func appDidBecomeActive() {
        request(.activation)
    }

    /// "Sync Now".
    func syncNow() {
        request(.manual)
    }

    // MARK: - Triggers

    func defaultsDidChange() {
        let allowed = isSyncAllowed()
        let audio = MeetingSyncSettings.isAudioSyncOn()
        defer {
            lastKnownAllowed = allowed
            lastKnownAudio = audio
        }
        if (allowed && !lastKnownAllowed) || (allowed && audio && !lastKnownAudio) {
            request(.enabled)
        }
    }

    /// The bookkeeping tables changed: (re)arm the debounce. While a
    /// recording runs this fires per segment, so the debounce keeps moving
    /// and no round starts until things settle.
    func localMeetingsDidChange() {
        guard isSyncAllowed() else { return }
        if policy.isSyncing {
            pendingFollowUp = true
            return
        }
        armDebounce()
    }

    private func armDebounce() {
        debounceTask?.cancel()
        let delay = changeDebounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            if self.policy.isSyncing {
                self.pendingFollowUp = true
                return
            }
            // Only when there's something to push: a round's own writes
            // (imports, push bookkeeping) leave nothing pending, so they
            // don't cause an echo round.
            guard (try? self.localStore.hasPendingWork()) == true else { return }
            self.request(.localChange)
        }
    }

    /// Starts a round for `trigger` if allowed and the policy agrees.
    func request(_ trigger: MeetingSyncTriggerPolicy.Trigger) {
        guard isSyncAllowed() else { return }
        let now = Date()
        guard policy.shouldStart(trigger, now: now) else {
            if policy.isSyncing, trigger == .manual || trigger == .localChange {
                pendingFollowUp = true
            }
            return
        }
        policy.didStart(at: now)
        isSyncing = true
        let engine = engineInstance()
        let options = MeetingSyncRoundOptions(
            deviceKind: MeetingDeviceKind.current(),
            syncAudio: MeetingSyncSettings.isAudioSyncOn(),
            maxAudioFileBytes: MeetingAudioSyncPolicy.maxFileBytes,
            maxAudioSessionBytes: MeetingAudioSyncPolicy.maxSessionBytes,
            now: now
        )
        inFlight = Task { [weak self] in
            var report: MeetingSyncRoundReport?
            var failure: String?
            do {
                report = try await engine.runRound(options)
            } catch {
                failure = error.localizedDescription
                Log.storage.error("Meeting sync failed: \(error.localizedDescription, privacy: .public)")
            }
            self?.finishRound(report: report, failure: failure)
        }
    }

    private func finishRound(report: MeetingSyncRoundReport?, failure: String?) {
        policy.didFinish(at: Date())
        isSyncing = false
        inFlight = nil
        if let report {
            lastReport = report
            lastSyncedAt = Date()
            lastError = report.failures > 0 ? "Some meetings couldn't be synced; Scribe will retry." : nil
            let changed = report.changedSessionIds
            if !changed.isEmpty {
                NotificationCenter.default.post(name: .scribeMeetingSyncDidChangeSessions, object: changed)
                onSessionsChanged?(changed)
            }
        } else {
            lastError = failure
        }
        if pendingFollowUp {
            pendingFollowUp = false
            if isSyncAllowed() { armDebounce() }
        }
    }

    private func engineInstance() -> MeetingSyncEngine {
        if let engine { return engine }
        let created = makeEngine()
        engine = created
        return created
    }

    // MARK: - Audio on demand

    /// Whether `sessionId` has audio in iCloud that isn't on this device.
    func canDownloadAudio(sessionId: String) -> Bool {
        guard isSyncAllowed() else { return false }
        guard let files = try? localStore.remoteAudioFiles(sessionId: sessionId), !files.isEmpty else { return false }
        if let path = try? localStore.audioDirectory(sessionId: sessionId) {
            let present = MeetingAudioSyncPolicy.localFiles(in: URL(fileURLWithPath: path, isDirectory: true))
            if !present.isEmpty { return false }
        }
        return true
    }

    /// Downloads the session's audio from iCloud; returns its folder path.
    func downloadAudio(sessionId: String) async throws -> String {
        guard isSyncAllowed() else { throw MeetingSyncEngineError.noRemoteAudio }
        let engine = engineInstance()
        let root = SessionAudioStorage.defaultRoot()
        let path = try await engine.downloadAudio(sessionId: sessionId, audioRoot: root)
        NotificationCenter.default.post(name: .scribeMeetingSyncDidChangeSessions, object: [sessionId])
        onSessionsChanged?([sessionId])
        return path
    }

    // MARK: - Database observation

    /// Observes the sync bookkeeping (bumped by the v28 triggers on every
    /// meeting write). `nonisolated` so GRDB's callback isn't a main-actor
    /// closure; it only forwards a Sendable ping.
    nonisolated private static func observeLocalMeetingChanges(
        in database: DatabaseQueue,
        onChange: @escaping @Sendable () -> Void
    ) -> AnyDatabaseCancellable {
        let observation = DatabaseRegionObservation(
            tracking: SQLRequest<Row>(sql: "SELECT * FROM meeting_sync_state"),
            SQLRequest<Row>(sql: "SELECT * FROM meeting_sync_tombstones")
        )
        return observation.start(
            in: database,
            onError: { error in
                Log.storage.error("Meeting-sync change observation failed: \(error.localizedDescription, privacy: .private)")
            },
            onChange: { _ in onChange() }
        )
    }
}
