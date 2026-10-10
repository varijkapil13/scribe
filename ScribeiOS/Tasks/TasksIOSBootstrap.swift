import Combine
import Foundation
import GRDB
import SwiftUI
import UIKit
import UserNotifications

/// Launch wiring for tasks on iPhone / iPad: the reminder notification
/// category + delegate (Mark Done / Snooze actions, tap opens the task), the
/// automatic reminder scheduler, the app icon badge, and the Apple Reminders
/// sync scheduler. Idempotent; called from `ScribeiOSApp.init` and, as a
/// fallback, when a task screen appears.
@MainActor
enum TasksIOSBootstrap {
    private static var started = false
    private static var observers: [any NSObjectProtocol] = []

    static func start() {
        guard !started else { return }
        started = true

        let scheduler = TaskReminderScheduler.shared
        scheduler.registerCategory()
        scheduler.installDelegate()
        scheduler.openTaskHandler = { taskId in
            TasksOpenRequest.shared.open(taskId)
        }

        let database = DatabaseManager.shared.database
        TasksReminderAutoScheduler.shared.start(database: database)
        TasksBadgeController.shared.start()
        // Self-gated on the Reminders toggle + full access: nothing runs (and
        // no prompt appears) until the user turns it on in Settings → Tasks.
        RemindersSyncScheduler.shared.start(database: database)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { appDidBecomeActive() }
        })
        observers.append(center.addObserver(forName: UIApplication.significantTimeChangeNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TasksBadgeController.shared.refresh() }
        })
    }

    private static func appDidBecomeActive() {
        RemindersSyncScheduler.shared.appDidBecomeActive()
        TasksBadgeController.shared.refresh()
        TasksReminderAutoScheduler.shared.changed()
        TasksCalendarEventsModel.shared.refreshAccess()
        TasksCloudSyncStatus.shared.refresh()
    }
}

// MARK: - Reminders

/// Keeps pending task reminder notifications in step with the tasks table,
/// whoever changed it (this device, iCloud sync, Apple Reminders sync).
/// Debounced; only touches reminders whose task changed.
@MainActor
final class TasksReminderAutoScheduler {
    static let shared = TasksReminderAutoScheduler()

    private var scheduled: [String: TaskReminderPlanning.Entry] = [:]
    private var observation: AnyDatabaseCancellable?
    private var debounceTask: Task<Void, Never>?
    private var isRefreshing = false
    private var needsRefresh = false
    private var reconciledPending = false

    func start(database: DatabaseQueue) {
        guard observation == nil else { return }
        observation = Self.observeTasks(in: database) {
            Task { @MainActor in TasksReminderAutoScheduler.shared.changed() }
        }
        changed()
    }

    func changed() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func refresh() async {
        guard !isRefreshing else {
            needsRefresh = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            needsRefresh = false
            await refreshOnce()
        } while needsRefresh
    }

    private func refreshOnce() async {
        let tasks = (try? TaskStore.shared.fetchTasks(filter: .all)) ?? []
        let desired = TaskReminderPlanning.desired(tasks, now: Date())
        var pending: Set<String> = []
        if !reconciledPending {
            reconciledPending = true
            pending = Set(await TasksNotificationBridge.pendingTaskReminderIds())
        }
        let changes = TaskReminderPlanning.changes(desired: desired, scheduled: scheduled, pendingTaskIds: pending)
        guard !changes.schedule.isEmpty || !changes.cancel.isEmpty else { return }

        let scheduler = TaskReminderScheduler.shared
        for id in changes.cancel {
            await scheduler.cancel(taskId: id)
            scheduled[id] = nil
        }
        let tasksById = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let entriesById = Dictionary(desired.map { ($0.taskId, $0) }, uniquingKeysWith: { first, _ in first })
        for id in changes.schedule {
            guard let task = tasksById[id], let entry = entriesById[id] else { continue }
            await scheduler.schedule(task)
            scheduled[id] = entry
        }
    }

    /// `nonisolated` so GRDB's change callback (on the database queue) is not
    /// a main-actor closure.
    nonisolated private static func observeTasks(
        in database: DatabaseQueue,
        onChange: @escaping @Sendable () -> Void
    ) -> AnyDatabaseCancellable {
        let observation = DatabaseRegionObservation(tracking: TodoTask.all())
        return observation.start(
            in: database,
            onError: { error in
                Log.storage.error("Reminder auto-scheduler observation failed: \(error.localizedDescription, privacy: .private)")
            },
            onChange: { _ in onChange() }
        )
    }
}

// MARK: - Badge

/// App icon badge = open tasks in Today (overdue included). On by default;
/// Settings → Tasks turns it off. Never asks for notification permission on
/// its own — the badge shows once notifications are allowed.
@MainActor
final class TasksBadgeController {
    static let shared = TasksBadgeController()

    nonisolated static let enabledKey = "iosTaskBadgeEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private var cancellable: AnyCancellable?
    private var lastCount: Int?

    func start() {
        guard cancellable == nil else { return }
        cancellable = TaskStore.shared.observeTasks(filter: .all)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] tasks in
                self?.apply(tasks)
            })
    }

    func refresh() {
        let tasks = (try? TaskStore.shared.fetchTasks(filter: .all)) ?? []
        lastCount = nil
        apply(tasks)
    }

    private func apply(_ tasks: [TodoTask]) {
        let count = Self.isEnabled ? TaskListSectioning.appBadgeCount(tasks, now: Date(), calendar: .current) : 0
        guard count != lastCount else { return }
        lastCount = count
        TasksNotificationBridge.setBadgeCount(count)
    }
}

/// UNUserNotificationCenter calls made outside the main actor (their
/// completion handlers run on background queues).
enum TasksNotificationBridge {

    static func setBadgeCount(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { error in
            if let error {
                Log.app.error("Set badge failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Task ids of the reminder notifications the system still holds.
    static func pendingTaskReminderIds() async -> [String] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                let ids = requests.compactMap { TaskReminderPlanning.taskId(fromNotificationIdentifier: $0.identifier) }
                continuation.resume(returning: ids)
            }
        }
    }

    /// Whether the user allowed notifications (alerts or badges).
    static func authorizationSummary() async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let text: String
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: text = "Allowed"
                case .denied:                               text = "Off in Settings"
                case .notDetermined:                        text = "Not requested yet"
                @unknown default:                           text = "Unknown"
                }
                continuation.resume(returning: text)
            }
        }
    }
}

// MARK: - iCloud task sync status

/// Status of the iCloud (CloudKit) task sync for the sidebar and settings.
/// The last-sync time is the coordinator's push cursor, so rounds started
/// elsewhere (the shell's foreground sync) count too.
@MainActor
final class TasksCloudSyncStatus: ObservableObject {
    static let shared = TasksCloudSyncStatus()

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isEnabled = false
    /// Tasks the last round skipped: their project isn't on this device
    /// (projects don't sync yet).
    @Published private(set) var skippedTasks = 0

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = CloudKitSyncService.isEnabled
        lastSyncAt = UserDefaultsSyncCursorStore().lastPushDate
    }

    func syncNow() async {
        refresh()
        guard CloudKitAvailability.canSyncTasks, !isSyncing else { return }
        isSyncing = true
        do {
            skippedTasks = try await TaskSyncCoordinator.live.syncReportingSkipped()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        isSyncing = false
        refresh()
    }

    var symbol: String {
        if !isEnabled { return "icloud.slash" }
        if lastError != nil { return "exclamationmark.icloud" }
        return "checkmark.icloud"
    }

    var statusText: String {
        guard isEnabled else { return "iCloud sync is off (Settings)" }
        if isSyncing { return "Syncing…" }
        if let lastError { return "Sync failed: \(lastError)" }
        guard let lastSyncAt else { return "Not synced yet — pull to sync" }
        let synced = "Synced \(lastSyncAt.formatted(.relative(presentation: .named)))"
        guard skippedTasks > 0 else { return synced }
        return synced + " · \(skippedTasks) in projects not on this device"
    }
}
