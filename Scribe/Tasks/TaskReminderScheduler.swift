import Foundation
import UserNotifications

/// Subset of the scheduler API the rest of the app talks to. Lets test view
/// models pass a no-op stand-in instead of touching the real
/// `UNUserNotificationCenter`, which crashes outside a real app bundle.
@MainActor
protocol TaskReminderScheduling: AnyObject, Sendable {
    func schedule(_ task: TodoTask) async
    func cancel(taskId: String) async
}

/// No-op scheduler used in unit tests that don't care about reminders.
@MainActor
final class NoOpTaskReminderScheduler: TaskReminderScheduling, Sendable {
    func schedule(_ task: TodoTask) async {}
    func cancel(taskId: String) async {}
}

/// Wraps `UNUserNotificationCenter` for the task reminder flow. Owns:
///
/// - Authorization (lazy: requested the first time a reminder is scheduled).
/// - Scheduling / re-scheduling / cancelling per-task notifications.
/// - The category + actions ("Mark Done", "Snooze 15 min") and the delegate
///   that handles the user's response when the notification fires.
///
/// One instance per process — `AppDelegate` constructs the singleton at
/// launch, registers categories, and wires the delegate; the rest of the app
/// reaches it via `TaskReminderScheduler.shared`.
@MainActor
final class TaskReminderScheduler: NSObject, TaskReminderScheduling {

    // MARK: - Singletons / identifiers

    static let shared = TaskReminderScheduler()

    nonisolated static let categoryId = "scribe.task-reminder"
    nonisolated static let actionMarkDone = "scribe.task.mark-done"
    nonisolated static let actionSnooze   = "scribe.task.snooze"
    nonisolated static let userInfoTaskId = "taskId"

    /// 15 minutes — slice 6 ships a fixed snooze interval. Slice 8 can grow
    /// this into a picker if anyone asks.
    nonisolated static let snoozeInterval: TimeInterval = 15 * 60

    // MARK: - Dependencies

    private var center: UNUserNotificationCenterAdapter
    /// Used by the action handler (Mark Done / Snooze) to mutate the task.
    /// Defaults to a fresh `TaskStore` over the shared database; tests can
    /// override.
    var taskStore: TaskStore = TaskStore()

    /// Cached authorization decision. `nil` means "not yet checked".
    private var authorizationGranted: Bool?

    // MARK: - Init

    init(center: UNUserNotificationCenterAdapter = SystemNotificationCenter()) {
        self.center = center
        super.init()
    }

    // MARK: - Setup

    /// Registers the reminder category + actions with the system. Safe to call
    /// multiple times — the system replaces the registration in place.
    func registerCategory() {
        let markDone = UNNotificationAction(
            identifier: Self.actionMarkDone,
            title: "Mark Done",
            options: [.authenticationRequired]
        )
        let snooze = UNNotificationAction(
            identifier: Self.actionSnooze,
            title: "Snooze 15 min",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryId,
            actions: [markDone, snooze],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([category])
    }

    /// Installs `self` as the system notification center's delegate so action
    /// taps route through `userNotificationCenter(_:didReceive:withCompletionHandler:)`.
    func installDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Authorization

    /// Requests notification authorization if it hasn't been resolved yet.
    /// Returns true on grant. Cached for the process lifetime to keep
    /// repeated `schedule` calls cheap.
    @discardableResult
    func ensureAuthorized() async -> Bool {
        if let cached = authorizationGranted { return cached }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            authorizationGranted = granted
            return granted
        } catch {
            Log.app.error("Reminder authorization failed: \(error.localizedDescription, privacy: .public)")
            authorizationGranted = false
            return false
        }
    }

    // MARK: - Scheduling

    /// Schedules — or re-schedules — the reminder for a task. A task without
    /// `remindAt`, with `remindAt` in the past, or that's already completed
    /// has any pending reminder removed instead.
    func schedule(_ task: TodoTask) async {
        let id = Self.identifier(for: task.id)
        guard let comps = Self.triggerComponents(for: task) else {
            await center.removePendingNotificationRequests(withIdentifiers: [id])
            return
        }
        guard await ensureAuthorized() else { return }

        // Hand the adapter a Sendable bundle of fields and let it construct
        // the (non-Sendable) UNNotificationRequest on its side. This keeps
        // strict-concurrency happy without weakening the isolation model.
        let payload = ReminderRequestPayload(
            identifier: id,
            title: task.title,
            body: task.notes.isEmpty ? nil : task.notes,
            categoryId: Self.categoryId,
            taskId: task.id,
            dateComponents: comps
        )
        do {
            try await center.add(payload: payload)
        } catch {
            Log.app.error("Schedule reminder failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Cancels any pending reminder for the task. Safe to call when no
    /// reminder exists.
    func cancel(taskId: String) async {
        await center.removePendingNotificationRequests(withIdentifiers: [Self.identifier(for: taskId)])
    }

    // MARK: - Pure helpers (testable)

    nonisolated static func identifier(for taskId: String) -> String { "scribe.task.\(taskId)" }

    nonisolated static func shouldSchedule(_ task: TodoTask, now: Date = Date()) -> Bool {
        guard !task.isCompleted, let remind = task.remindAt else { return false }
        return remind > now
    }

    nonisolated static func snoozeDate(from now: Date = Date(), interval: TimeInterval = snoozeInterval) -> Date {
        now.addingTimeInterval(interval)
    }

    /// Returns the calendar components used to trigger the notification, or
    /// nil when the task isn't a candidate. `schedule` treats nil as "cancel
    /// any pending reminder for this task".
    nonisolated static func triggerComponents(for task: TodoTask, now: Date = Date()) -> DateComponents? {
        guard shouldSchedule(task, now: now), let remind = task.remindAt else { return nil }
        return Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: remind
        )
    }
}

/// Sendable bundle of every field the adapter needs to construct a
/// `UNNotificationRequest`. Keeps the non-Sendable Apple type from crossing
/// actor boundaries.
struct ReminderRequestPayload: Sendable {
    let identifier: String
    let title: String
    let body: String?
    let categoryId: String
    let taskId: String
    let dateComponents: DateComponents
}

// MARK: - UNUserNotificationCenterDelegate

extension TaskReminderScheduler: UNUserNotificationCenterDelegate {

    /// Foreground presentation: show the banner + sound even when the app is
    /// active so the user actually sees the reminder.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    /// Action tap router. Hops to the main actor (the store + scheduler are
    /// `@MainActor`) before reading the user-info dictionary. Extracts the
    /// only fields we care about (action id, task id) here so we don't have
    /// to ferry a non-Sendable `UNNotificationResponse` across the boundary.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let actionId = response.actionIdentifier
        let taskId = response.notification.request.content.userInfo[Self.userInfoTaskId] as? String
        Task { @MainActor in
            if let taskId {
                await TaskReminderScheduler.shared.handle(actionId: actionId, taskId: taskId)
            }
            completionHandler()
        }
    }

    /// Mutates the task to reflect the chosen action. Default tap (= open the
    /// app) is a no-op for now; the routed task id is preserved on the
    /// notification so a future slice can navigate the sidebar to it.
    func handle(actionId: String, taskId: String) async {
        do {
            switch actionId {
            case Self.actionMarkDone:
                try taskStore.completeTask(id: taskId)
                await cancel(taskId: taskId)
            case Self.actionSnooze:
                guard var task = try taskStore.fetchTask(id: taskId) else { return }
                task.remindAt = Self.snoozeDate()
                try taskStore.updateTask(task)
                await schedule(task)
            default:
                break
            }
        } catch {
            Log.app.error("Reminder action handler failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - System adapter

/// Thin protocol over `UNUserNotificationCenter` so unit tests can verify
/// schedule / cancel call patterns without touching the real notification
/// daemon. Marked `Sendable` so the @MainActor scheduler can hand requests
/// to the system center without tripping Swift 6 isolation checks.
protocol UNUserNotificationCenterAdapter: AnyObject, Sendable {
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(payload: ReminderRequestPayload) async throws
    func removePendingNotificationRequests(withIdentifiers ids: [String]) async
}

final class SystemNotificationCenter: UNUserNotificationCenterAdapter, @unchecked Sendable {
    // Lazy so that constructing this adapter (which the scheduler singleton
    // does eagerly) doesn't reach into UN — which crashes from xctest hosts
    // that have no app bundle. The real app touches `center` inside
    // `applicationDidFinishLaunching`, by which point a bundle exists.
    private var _center: UNUserNotificationCenter?
    private var center: UNUserNotificationCenter {
        if let c = _center { return c }
        let c = UNUserNotificationCenter.current()
        _center = c
        return c
    }
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        // Bridge the completion-handler API to async/await ourselves so the
        // request never crosses an actor boundary as a non-Sendable
        // UNNotificationRequest. (UN's own async surface marks the value as
        // sent, which Swift 6 strict concurrency rejects from @MainActor.)
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: options) { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
    }
    func add(payload: ReminderRequestPayload) async throws {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        if let body = payload.body { content.body = body }
        content.categoryIdentifier = payload.categoryId
        content.userInfo = [TaskReminderScheduler.userInfoTaskId: payload.taskId]
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: payload.dateComponents, repeats: false)
        let request = UNNotificationRequest(identifier: payload.identifier, content: content, trigger: trigger)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    func removePendingNotificationRequests(withIdentifiers ids: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
