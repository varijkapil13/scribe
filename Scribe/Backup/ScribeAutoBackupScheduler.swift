import Foundation

/// Schedules automatic daily backups with `NSBackgroundActivityScheduler`.
///
/// The activity wakes roughly hourly (letting the system pick an idle,
/// power-friendly moment) and `ScribeAutoBackupRunner.runIfDue` decides
/// whether a day has passed since the last backup — so a Mac that's only
/// awake for a few hours a day still gets its backup, and relaunching the
/// app never resets the clock.
@MainActor
final class ScribeAutoBackupScheduler {

    static let shared = ScribeAutoBackupScheduler()

    static let activityIdentifier = "com.varij.scribe.automatic-backup"

    private var activity: NSBackgroundActivityScheduler?

    private init() {}

    /// Called once at launch: schedules (when enabled) and runs a catch-up
    /// check shortly after launch, once the app has settled.
    func start() {
        refresh()
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(120))
            do {
                try ScribeAutoBackupRunner.runIfDue()
            } catch {
                // Recorded in UserDefaults for Settings → Backup.
            }
        }
    }

    /// Re-reads the preferences and (re)schedules or cancels the activity.
    /// Called when the automatic-backup settings change.
    func refresh() {
        activity?.invalidate()
        activity = nil
        guard ScribeAutoBackupRunner.isConfigured() else { return }

        let scheduler = NSBackgroundActivityScheduler(identifier: Self.activityIdentifier)
        scheduler.repeats = true
        scheduler.interval = 60 * 60
        scheduler.tolerance = 15 * 60
        scheduler.qualityOfService = .utility
        Self.schedule(scheduler)
        activity = scheduler
    }

    /// Kept nonisolated with an explicitly `@Sendable` block: the scheduler
    /// invokes the block on a background queue, so it must not inherit this
    /// class's main-actor isolation (Swift 6 would trap on the executor check).
    private nonisolated static func schedule(_ scheduler: NSBackgroundActivityScheduler) {
        scheduler.schedule { @Sendable completion in
            do {
                try ScribeAutoBackupRunner.runIfDue()
            } catch {
                // Failure is recorded for Settings; try again next wake.
            }
            completion(.finished)
        }
    }
}
