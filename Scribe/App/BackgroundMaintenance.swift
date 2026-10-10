import Foundation

/// A periodic maintenance job run through `NSBackgroundActivityScheduler`.
///
/// Where Scribe's periodic work lives:
///
/// | Job                     | Launch                          | Periodic (this file)                 |
/// |-------------------------|---------------------------------|--------------------------------------|
/// | Audio retention cleanup | `AppState.runAudioHousekeeping` | `.audioRetention`, every 12 h        |
/// | Vault reconcile         | `VaultCoordinator.start()`      | `.vaultReconcile`, every 6 h         |
/// | Spotlight reindex       | `SpotlightIndexer.start()`      | `.spotlightReindex`, every 12 h      |
/// | Automatic backups       | —                               | `ScribeAutoBackupScheduler` (hourly) |
///
/// The launch passes stay where they are (they must run promptly at launch);
/// these activities only repeat them for a Mac that keeps Scribe open for
/// days, letting the system pick idle, power-friendly moments. Backups already
/// had their own activity, so they're listed for completeness only. There is
/// no embeddings index to maintain.
enum ScribeMaintenanceJob: String, CaseIterable, Sendable {
    /// Expired retained audio + orphaned audio folders.
    case audioRetention
    /// Safety-net vault ⇄ index reconcile behind the FSEvents watcher.
    case vaultReconcile
    /// Spotlight pass; a full reindex once a day.
    case spotlightReindex

    nonisolated var identifier: String {
        "com.varij.scribe.maintenance.\(rawValue)"
    }

    /// Seconds between runs.
    nonisolated var interval: TimeInterval {
        switch self {
        case .audioRetention:   return 12 * 60 * 60
        case .vaultReconcile:   return 6 * 60 * 60
        case .spotlightReindex: return 12 * 60 * 60
        }
    }

    /// How far the system may move a run to batch it with other work.
    nonisolated var tolerance: TimeInterval {
        interval / 4
    }

    nonisolated var qualityOfService: QualityOfService {
        switch self {
        case .audioRetention, .spotlightReindex: return .background
        case .vaultReconcile:                    return .utility
        }
    }
}

/// Schedules every `ScribeMaintenanceJob`. Started once at launch (not under
/// UI tests / screenshot fixtures, which must not touch the user's data).
@MainActor
final class ScribeBackgroundMaintenance {

    static let shared = ScribeBackgroundMaintenance()

    private var activities: [NSBackgroundActivityScheduler] = []

    private init() {}

    func start(transcriptStore: TranscriptStore) {
        guard activities.isEmpty else { return }
        guard !AppLaunchEnvironment.isUITesting, !AppLaunchEnvironment.usesUITestFixtures else { return }
        for job in ScribeMaintenanceJob.allCases {
            let scheduler = NSBackgroundActivityScheduler(identifier: job.identifier)
            scheduler.repeats = true
            scheduler.interval = job.interval
            scheduler.tolerance = job.tolerance
            scheduler.qualityOfService = job.qualityOfService
            Self.schedule(scheduler, job: job, store: transcriptStore)
            activities.append(scheduler)
        }
    }

    func stop() {
        for activity in activities { activity.invalidate() }
        activities.removeAll()
    }

    /// Nonisolated with an explicitly `@Sendable` block (same pattern as
    /// `ScribeAutoBackupScheduler`): the scheduler runs the block on a
    /// background queue, so it must not inherit main-actor isolation.
    private nonisolated static func schedule(
        _ scheduler: NSBackgroundActivityScheduler,
        job: ScribeMaintenanceJob,
        store: TranscriptStore
    ) {
        scheduler.schedule { @Sendable completion in
            run(job, store: store)
            completion(.finished)
        }
    }

    private nonisolated static func run(_ job: ScribeMaintenanceJob, store: TranscriptStore) {
        switch job {
        case .audioRetention:
            do {
                let result = try store.runAudioHousekeeping(
                    policy: AudioRetentionPolicy.current(),
                    root: SessionAudioStorage.defaultRoot()
                )
                if result.expired > 0 || result.orphans > 0 {
                    Log.app.info("Scheduled audio housekeeping removed \(result.expired) expired and \(result.orphans) orphaned recording(s).")
                }
            } catch {
                Log.app.error("Scheduled audio housekeeping failed: \(error.localizedDescription, privacy: .private)")
            }
        case .vaultReconcile:
            // The reconcile itself runs on the scheduler's own serial queue.
            Task { @MainActor in VaultCoordinator.shared.requestMaintenanceReconcile() }
        case .spotlightReindex:
            // Passes read the DB off the main actor; this only kicks one off.
            Task { @MainActor in SpotlightIndexer.shared.runMaintenancePass() }
        }
    }
}
