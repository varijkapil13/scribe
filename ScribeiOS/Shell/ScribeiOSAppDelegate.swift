import Foundation
import UIKit
import UserNotifications

/// UIKit lifecycle hooks for the iOS app (wired with
/// `@UIApplicationDelegateAdaptor` in ScribeiOSApp). Runs the portable
/// bootstrap once at launch; per-scene work (deep links, Handoff, scene
/// phase) lives in RootTabView.
@MainActor
final class ScribeiOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        ScribeiOSBootstrap.run()
        return true
    }
}

/// Launch-time setup shared with the Mac's data layer: database migrations,
/// notifications, the note index, and CloudKit task sync. Idempotent.
@MainActor
enum ScribeiOSBootstrap {
    private static var didRun = false

    static func run() {
        guard !didRun else { return }
        didRun = true

        // 1. Database: the shared manager runs every GRDB migration on first
        //    access — do it now rather than on the first screen's query.
        _ = DatabaseManager.shared

        // 2. Notifications: the task-reminder scheduler owns the single
        //    UNUserNotificationCenter delegate (Mark Done / Snooze actions);
        //    NotificationRouter lets other iOS areas add categories.
        //    Areas must call NotificationRouter.shared.register(...) BEFORE
        //    this runs (i.e. from their own static setup) or re-run
        //    `installNotifications()` after registering.
        installNotifications()

        // 3. Notes index: reconcile the markdown vault on disk into SQLite
        //    (picks up notes that arrived via iCloud Drive / Files while the
        //    app wasn't running). Off the main thread.
        reconcileVault()

        // 4. CloudKit task sync: launch round + toggle / local-change
        //    observation. A no-op until the user enables iCloud sync, and
        //    safe when the build has no iCloud entitlement.
        TaskSyncScheduler.shared.start()
    }

    static func installNotifications() {
        NotificationRouter.shared.install(on: TaskReminderScheduler.shared)
        TaskReminderScheduler.shared.registerCategory()
        TaskReminderScheduler.shared.installDelegate()
    }

    /// Scene became active: opportunistic, throttled sync + re-index.
    static func sceneDidBecomeActive() {
        TaskSyncScheduler.shared.appDidBecomeActive()
        reconcileVault()
    }

    /// Coalesces reconciles (launch + every activation) onto one serial
    /// queue; rebuilt when the vault moves (e.g. iCloud Drive toggled).
    private static var reconcileScheduler: NoteReconcileScheduler?

    private static func reconcileVault() {
        guard let fileStore = NoteStore.shared.fileStore else { return }
        if reconcileScheduler?.fileStore.directory.root != fileStore.directory.root {
            reconcileScheduler?.invalidate()
            let reconciler = NoteIndexReconciler(fileStore: fileStore, dbManager: DatabaseManager.shared)
            reconcileScheduler = NoteReconcileScheduler(reconciler: reconciler) { result in
                switch result {
                case .success(let pass):
                    Log.storage.info("iOS vault reconcile: \(pass.upserted) upserted, \(pass.removed) removed")
                case .failure(let error):
                    Log.storage.error("iOS vault reconcile failed: \(error.localizedDescription)")
                }
            }
        }
        reconcileScheduler?.requestReconcile()
    }
}
