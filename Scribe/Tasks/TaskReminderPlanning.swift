import Foundation

/// Which task reminders should be pending with the system, and what to change
/// to get there. Used on iPhone / iPad to keep local notifications in step
/// with tasks edited anywhere (this device, iCloud sync, Apple Reminders
/// sync). Pure; the UNUserNotificationCenter side lives in the app.
enum TaskReminderPlanning {

    /// iOS keeps at most 64 pending local notifications per app; leave room
    /// for other features (calendar / meeting notifications).
    static let pendingLimit = 50

    /// One reminder as scheduled: what was asked for, so an unchanged task
    /// isn't re-added on every database change.
    struct Entry: Equatable, Hashable, Sendable {
        let taskId: String
        let fireAt: Date
        let title: String
        let body: String
    }

    struct Changes: Equatable {
        /// Task ids to (re)schedule, soonest first.
        var schedule: [String]
        /// Task ids whose pending reminder must go.
        var cancel: [String]
    }

    /// Open tasks with a reminder still in the future, soonest first, capped
    /// at `limit`.
    static func desired(_ tasks: [TodoTask], now: Date, limit: Int = pendingLimit) -> [Entry] {
        let entries = tasks.compactMap { task -> Entry? in
            guard TaskPlanningRules.isActive(task), let remind = task.remindAt, remind > now else { return nil }
            return Entry(taskId: task.id, fireAt: remind, title: task.title, body: task.notes)
        }
        .sorted { a, b in a.fireAt != b.fireAt ? a.fireAt < b.fireAt : a.taskId < b.taskId }
        return Array(entries.prefix(max(0, limit)))
    }

    /// What to change to go from `scheduled` (what this process last asked
    /// for) to `desired`. `pendingTaskIds` are reminders the system still
    /// holds from earlier launches; any not desired are cancelled too.
    static func changes(
        desired: [Entry],
        scheduled: [String: Entry],
        pendingTaskIds: Set<String> = []
    ) -> Changes {
        let desiredIds = Set(desired.map(\.taskId))
        let schedule = desired.filter { scheduled[$0.taskId] != $0 }.map(\.taskId)
        let stale = Set(scheduled.keys).union(pendingTaskIds).subtracting(desiredIds)
        return Changes(schedule: schedule, cancel: stale.sorted())
    }

    /// The task id inside a reminder notification identifier
    /// (`TaskReminderScheduler.identifier(for:)`), or nil for other ones.
    static func taskId(fromNotificationIdentifier identifier: String) -> String? {
        let prefix = TaskReminderScheduler.identifier(for: "")
        guard identifier.hasPrefix(prefix) else { return nil }
        let id = String(identifier.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }
}
