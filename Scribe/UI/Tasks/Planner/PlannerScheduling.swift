import Foundation

/// A task scheduled at a time of day, as drawn on the planner's grid.
struct PlannerTaskBlock: Equatable, Identifiable {
    let task: TodoTask
    let start: Date
    let end: Date
    let durationMinutes: Int

    var id: String { task.id }
}

/// The planner's side list for a day: open tasks without a time.
struct PlannerSideList: Equatable {
    /// Due that day (or, viewing today, overdue — including blocks left over
    /// from earlier days — or planned for Today or This Evening) but not yet
    /// given a time on it.
    var forDay: [TodoTask]
    /// Undated, available tasks (not parked in Someday).
    var undated: [TodoTask]
}

/// Pure planning rules for the time grid: which tasks are blocks, how long a
/// block is, and what scheduling / moving / resizing writes to the task.
///
/// A task is "scheduled" when its `dueAt` carries a time of day (Scribe stores
/// a date-only due as local midnight). Its block lasts `estimatedMinutes`, or
/// `defaultDurationMinutes` without an estimate.
enum PlannerScheduling {

    nonisolated static let defaultDurationMinutes = 30

    nonisolated static func hasTime(_ date: Date, calendar: Calendar) -> Bool {
        calendar.startOfDay(for: date) != date
    }

    nonisolated static func isScheduled(_ task: TodoTask, calendar: Calendar) -> Bool {
        guard let due = task.dueAt else { return false }
        return hasTime(due, calendar: calendar)
    }

    nonisolated static func durationMinutes(of task: TodoTask) -> Int {
        if let minutes = task.estimatedMinutes, minutes > 0 { return minutes }
        return defaultDurationMinutes
    }

    nonisolated static func isOpen(_ task: TodoTask) -> Bool {
        !task.isCompleted && !task.isCancelled
    }

    /// Time blocks for open tasks scheduled on `day`, by start time.
    nonisolated static func taskBlocks(
        _ tasks: [TodoTask],
        on day: Date,
        calendar: Calendar
    ) -> [PlannerTaskBlock] {
        tasks.compactMap { task -> PlannerTaskBlock? in
            guard isOpen(task), let due = task.dueAt, hasTime(due, calendar: calendar),
                  calendar.isDate(due, inSameDayAs: day) else { return nil }
            let minutes = durationMinutes(of: task)
            return PlannerTaskBlock(task: task, start: due,
                                    end: due.addingTimeInterval(TimeInterval(minutes * 60)),
                                    durationMinutes: minutes)
        }
        .sorted { a, b in a.start != b.start ? a.start < b.start : a.task.id < b.task.id }
    }

    /// Open tasks without a time that are worth scheduling on `day`.
    nonisolated static func sideList(
        _ tasks: [TodoTask],
        for day: Date,
        calendar: Calendar,
        now: Date
    ) -> PlannerSideList {
        let dayStart = calendar.startOfDay(for: day)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let isToday = calendar.isDate(day, inSameDayAs: now)
        var forDay: [TodoTask] = []
        var undated: [TodoTask] = []
        for task in tasks where isOpen(task) {
            // Deferred past this day: not available yet.
            if let start = task.startAt, start >= nextDay { continue }
            if isScheduled(task, calendar: calendar) {
                // A block from an earlier day that was never done: viewing
                // today, offer it again so it can be given a new time.
                if isToday, let due = task.dueAt, due < dayStart { forDay.append(task) }
                continue
            }
            if let due = task.dueAt {
                if calendar.isDate(due, inSameDayAs: day) || (isToday && due < dayStart) {
                    forDay.append(task)
                }
                continue
            }
            if isToday && (task.scheduleBucket == .today || task.scheduleBucket == .evening) {
                forDay.append(task)
            } else if task.scheduleBucket != .someday {
                undated.append(task)
            }
        }
        return PlannerSideList(forDay: forDay, undated: undated)
    }

    /// A grid start minute a task can actually hold: 00:00 reads as "date
    /// only" in Scribe's model, so a block can't start before the first step.
    nonisolated static func representableStartMinute(_ minute: Int, snapMinutes: Int) -> Int {
        max(minute, max(1, snapMinutes))
    }

    // MARK: Writes

    /// `task` scheduled to start at `start`: the due time is set, a missing
    /// estimate becomes the default block length, a Someday plan becomes
    /// Anytime, and a defer date after the block is dropped.
    nonisolated static func scheduling(_ task: TodoTask, at start: Date, calendar: Calendar) -> TodoTask {
        var updated = task
        updated.dueAt = start
        if (task.estimatedMinutes ?? 0) <= 0 { updated.estimatedMinutes = defaultDurationMinutes }
        if updated.scheduleBucket == .someday { updated.scheduleBucket = .anytime }
        if let deferred = task.startAt, deferred > start { updated.startAt = nil }
        return updated
    }

    /// `task` with its block resized to `minutes`.
    nonisolated static func resizing(_ task: TodoTask, toMinutes minutes: Int) -> TodoTask {
        var updated = task
        updated.estimatedMinutes = max(1, minutes)
        return updated
    }

    /// `task` taken off the grid: keeps its date, drops the time of day.
    nonisolated static func unscheduling(_ task: TodoTask, calendar: Calendar) -> TodoTask {
        var updated = task
        if let due = task.dueAt { updated.dueAt = calendar.startOfDay(for: due) }
        return updated
    }

    /// `current` with the fields planner edits touch copied from `snapshot`
    /// (what undo / redo write).
    nonisolated static func restoring(from snapshot: TodoTask, to current: TodoTask) -> TodoTask {
        var result = current
        result.dueAt = snapshot.dueAt
        result.estimatedMinutes = snapshot.estimatedMinutes
        result.scheduleBucket = snapshot.scheduleBucket
        result.startAt = snapshot.startAt
        return result
    }
}

// MARK: - Grid items

/// One block on the planner's day grid, in minutes of the day, with its
/// overlap placement.
struct PlannerGridItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case event(CalendarEventInfo)
        case task(TodoTask)
    }

    let id: String
    let kind: Kind
    /// Start / end minute of the day, clipped to 0...1440 (end > start).
    let startMinute: Int
    let endMinute: Int
    let placement: TimeGridPlacement

    var durationMinutes: Int { endMinute - startMinute }
}

/// Builds the planner's day grid: timed calendar events (minus the ones
/// Scribe itself wrote as time blocks) and scheduled tasks, laid out together
/// so a task beside a meeting gets its own column. Pure.
enum PlannerGrid {

    nonisolated static func eventItemId(_ event: CalendarEventInfo) -> String {
        "event:\(event.id)@\(Int(event.start.timeIntervalSince1970))"
    }

    nonisolated static func taskItemId(_ taskId: String) -> String {
        "task:\(taskId)"
    }

    nonisolated static func items(
        events: [CalendarEventInfo],
        hiddenEventIds: Set<String>,
        tasks: [TodoTask],
        day: Date,
        calendar: Calendar
    ) -> [PlannerGridItem] {
        let dayStart = calendar.startOfDay(for: day)
        let dayLength = TimeGridGeometry.minutesPerDay

        struct Raw {
            let id: String
            let kind: PlannerGridItem.Kind
            let start: Int
            let end: Int
        }
        var raw: [Raw] = []
        var seen = Set<String>()
        for event in events where !event.isAllDay && !hiddenEventIds.contains(event.id) {
            let start = max(0, TimeGridGeometry.minuteOfDay(for: event.start, on: dayStart, calendar: calendar))
            let end = min(dayLength, TimeGridGeometry.minuteOfDay(for: event.end, on: dayStart, calendar: calendar))
            // Ends at or before this day's midnight, or starts after it.
            guard event.end > dayStart, start < dayLength else { continue }
            let id = eventItemId(event)
            guard seen.insert(id).inserted else { continue }
            raw.append(Raw(id: id, kind: PlannerGridItem.Kind.event(event), start: start, end: max(end, start + 1)))
        }
        for block in PlannerScheduling.taskBlocks(tasks, on: dayStart, calendar: calendar) {
            let start = max(0, TimeGridGeometry.minuteOfDay(for: block.start, on: dayStart, calendar: calendar))
            let end = min(dayLength, start + block.durationMinutes)
            let id = taskItemId(block.task.id)
            guard seen.insert(id).inserted else { continue }
            raw.append(Raw(id: id, kind: PlannerGridItem.Kind.task(block.task), start: start, end: max(end, start + 1)))
        }

        let intervals = raw.map { item in
            TimeGridInterval(id: item.id,
                             start: dayStart.addingTimeInterval(TimeInterval(item.start * 60)),
                             end: dayStart.addingTimeInterval(TimeInterval(item.end * 60)))
        }
        let placements = TimeGridLayout.layout(intervals, minimumDuration: TimeGridLayout.defaultMinimumDuration)
        return raw.map { item in
            PlannerGridItem(id: item.id, kind: item.kind, startMinute: item.start, endMinute: item.end,
                            placement: placements[item.id] ?? TimeGridPlacement(column: 0, columnCount: 1, span: 1))
        }
        .sorted { a, b in
            a.startMinute != b.startMinute ? a.startMinute < b.startMinute : a.id < b.id
        }
    }

    /// All-day events touching `day` (shown in a strip above the grid).
    nonisolated static func allDayEvents(_ events: [CalendarEventInfo], day: Date, calendar: Calendar) -> [CalendarEventInfo] {
        let dayStart = calendar.startOfDay(for: day)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        return events.filter { $0.isAllDay && $0.start < nextDay && $0.end > dayStart }
    }
}
