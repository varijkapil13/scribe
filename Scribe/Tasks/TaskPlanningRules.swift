import Foundation

/// Pure, in-memory mirror of the planning-aware list membership rules
/// (Today / Upcoming / Inbox / Someday). `TaskStore.fetchTasks` implements
/// the same rules in SQL; this copy backs client-side counts (sidebar
/// badges) and keeps the semantics unit-testable in one place.
///
/// Day granularity throughout: a start date ("defer until") of any time
/// today makes the task available today.
enum TaskPlanningRules {

    /// Active = neither completed nor cancelled.
    static func isActive(_ task: TodoTask) -> Bool {
        task.completedAt == nil && task.cancelledAt == nil
    }

    /// True while the task's start date is after today — it's hidden from
    /// Today until that day arrives.
    static func isDeferred(_ task: TodoTask, now: Date, calendar: Calendar) -> Bool {
        guard let start = task.startAt else { return false }
        return start >= startOfTomorrow(now: now, calendar: calendar)
    }

    /// Today = active, not deferred, and either due by the end of today
    /// (overdue included), explicitly planned for Today, or an undated
    /// This-Evening task. A dated evening task joins Today on its due day.
    static func isInToday(_ task: TodoTask, now: Date, calendar: Calendar) -> Bool {
        guard isActive(task), !isDeferred(task, now: now, calendar: calendar) else { return false }
        let tomorrow = startOfTomorrow(now: now, calendar: calendar)
        if let due = task.dueAt, due < tomorrow { return true }
        switch task.scheduleBucket {
        case .today:   return true
        case .evening: return task.dueAt == nil
        case .anytime, .someday: return false
        }
    }

    /// The This-Evening section of Today: Today tasks planned for the evening
    /// that aren't overdue (overdue work always leads).
    static func isInEvening(_ task: TodoTask, now: Date, calendar: Calendar) -> Bool {
        guard task.scheduleBucket == .evening, isInToday(task, now: now, calendar: calendar) else { return false }
        if let due = task.dueAt, due < calendar.startOfDay(for: now) { return false }
        return true
    }

    /// Upcoming = active and either due before the end of the 7-day window
    /// (overdue included) or starting within the window (tomorrow onward).
    static func isInUpcoming(_ task: TodoTask, now: Date, calendar: Calendar) -> Bool {
        guard task.completedAt == nil, task.cancelledAt == nil else { return false }
        let tomorrow = startOfTomorrow(now: now, calendar: calendar)
        guard let endOfWindow = calendar.date(byAdding: .day, value: 7, to: tomorrow) else { return false }
        if let due = task.dueAt, due < endOfWindow { return true }
        if let start = task.startAt, start >= tomorrow, start < endOfWindow { return true }
        return false
    }

    /// Inbox = active, no project, not parked in Someday.
    static func isInInbox(_ task: TodoTask) -> Bool {
        isActive(task) && task.projectId == nil && task.scheduleBucket != .someday
    }

    static func isInSomeday(_ task: TodoTask) -> Bool {
        isActive(task) && task.scheduleBucket == .someday
    }

    private static func startOfTomorrow(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
    }
}
