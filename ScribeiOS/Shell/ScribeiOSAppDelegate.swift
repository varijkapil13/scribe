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

/// Launch-time setup for the whole iOS app — the ONE place each launch-time
/// service is started (areas don't start these themselves): database
/// migrations, the notification delegate + task reminders, the notes vault
/// (iCloud / local) + index reconcile, CloudKit task sync, the recorder's
/// system hooks, and widgets / Spotlight / Share import. Idempotent.
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
        //    UNUserNotificationCenter delegate (Mark Done / Snooze actions,
        //    tap opens the task); NotificationRouter lets other iOS areas add
        //    categories. Areas must call NotificationRouter.shared.register(...)
        //    BEFORE this runs (i.e. from their own static setup) or re-run
        //    `installNotifications()` after registering. Set up here, in
        //    didFinishLaunching, so actions work on a background launch too.
        installNotifications()

        // 3. Tasks: reminder auto-scheduling, the app badge and the Apple
        //    Reminders sync scheduler (ios-tasks). Its notification wiring is
        //    the delegate installed above.
        TasksIOSBootstrap.start()

        // 4. Notes vault: picks the iCloud Drive or local vault, observes it,
        //    migrates DB-only notes to disk and reconciles the vault into
        //    SQLite (notes that arrived via iCloud Drive / Files while the app
        //    wasn't running). IOSVaultSyncController (ios-notes) owns the
        //    single NoteReconcileScheduler.
        IOSVaultSyncController.shared.start()

        // 5. CloudKit task sync: launch round + toggle / local-change
        //    observation. A no-op until the user enables iCloud sync, and
        //    safe when the build has no iCloud entitlement.
        TaskSyncScheduler.shared.start()

        // 6. Recording: create the recorder now so it registers with
        //    ScribeRecordingControlRegistry (Siri / Shortcuts / Control
        //    Center / widgets) and installs the Live Activity Stop / Pause
        //    handler before any intent runs — not only once the Record tab
        //    is first shown. Creating it doesn't touch the microphone.
        _ = MobileRecordingController.shared

        // 7. Widgets snapshot, widget task toggles, Spotlight indexing and
        //    Share-extension import (ios-system). Also started by each
        //    scene's `.scribeSystemIntegration()`; idempotent.
        IOSSystemIntegration.shared.start()
    }

    static func installNotifications() {
        let scheduler = TaskReminderScheduler.shared
        NotificationRouter.shared.install(on: scheduler)
        // Tapping a task reminder: the key scene's RootTabView picks this up
        // and routes it through its navigator (Tasks tab → the task).
        scheduler.openTaskHandler = { taskId in
            TasksOpenRequest.shared.open(taskId)
        }
        scheduler.registerCategory()
        scheduler.installDelegate()
    }

    /// Scene became active: opportunistic, throttled sync + re-index.
    static func sceneDidBecomeActive() {
        TaskSyncScheduler.shared.appDidBecomeActive()
        IOSVaultSyncController.shared.refresh()
    }
}
