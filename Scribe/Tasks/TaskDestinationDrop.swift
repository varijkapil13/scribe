import Foundation

/// What dropping (or "Move to…") a task onto a list or a section does.
enum TaskDestinationDropOutcome: Equatable {
    /// Already there; nothing to write.
    case unchanged
    /// Store this row (`TaskStore.updateTask`).
    case update(TodoTask)
    /// Re-file through `TaskStore.moveTask` (appends to the project and keeps
    /// heading / area links consistent).
    case moveToProject(String?)
    /// File under a heading through `TaskStore.setHeading` (nil = none).
    case setHeading(String?)
    /// Complete through `TaskStore.completeTask` (recurrence-aware).
    case complete
}

/// Pure drop rules for the iOS lists, sidebar rows and section headers. The
/// planning edits match the Mac list's row actions (When ▸ Today / This
/// Evening / Someday, drag onto a date section, Move to Project).
enum TaskDestinationDrop {

    /// Dropping `task` on a sidebar list.
    static func outcome(
        dropping task: TodoTask,
        onto destination: TaskListDestination,
        calendar: Calendar,
        now: Date
    ) -> TaskDestinationDropOutcome {
        switch destination {
        case .inbox:
            guard task.projectId != nil || task.areaId != nil || task.scheduleBucket == .someday || task.isCompleted || task.isCancelled
            else { return .unchanged }
            var updated = reopened(task)
            updated.projectId = nil
            updated.headingId = nil
            updated.areaId = nil
            if updated.scheduleBucket == .someday { updated.scheduleBucket = .anytime }
            return .update(updated)

        case .today:
            let updated = planned(reopened(task), bucket: .today, calendar: calendar, now: now)
            return updated == task ? .unchanged : .update(updated)

        case .anytime:
            var updated = reopened(task)
            if updated.scheduleBucket == .someday { updated.scheduleBucket = .anytime }
            if let start = updated.startAt, start >= TaskListSectioning.startOfTomorrow(now: now, calendar: calendar) {
                updated.startAt = nil
            }
            return updated == task ? .unchanged : .update(updated)

        case .someday:
            let updated = planned(reopened(task), bucket: .someday, calendar: calendar, now: now)
            return updated == task ? .unchanged : .update(updated)

        case .logbook:
            return task.isCompleted ? .unchanged : .complete

        case .project(let projectId):
            return task.projectId == projectId ? .unchanged : .moveToProject(projectId)

        case .area(let areaId):
            guard task.areaId != areaId || task.projectId != nil else { return .unchanged }
            var updated = task
            updated.projectId = nil
            updated.headingId = nil
            updated.areaId = areaId
            return .update(updated)

        case .upcoming, .tag, .planner:
            return .unchanged
        }
    }

    /// Dropping `task` on a section of the list it's shown in.
    static func outcome(
        dropping task: TodoTask,
        ontoSection section: TaskListSection.Kind,
        calendar: Calendar,
        now: Date
    ) -> TaskDestinationDropOutcome {
        switch section {
        case .today:
            let updated = planned(task, bucket: .today, calendar: calendar, now: now)
            return updated == task ? .unchanged : .update(updated)
        case .evening:
            let updated = planned(task, bucket: .evening, calendar: calendar, now: now)
            return updated == task ? .unchanged : .update(updated)
        case .day(let day):
            let updated = rescheduled(task, to: day, calendar: calendar)
            return updated == task ? .unchanged : .update(updated)
        case .project(let projectId):
            return task.projectId == projectId ? .unchanged : .moveToProject(projectId)
        case .areaTasks(let areaId):
            return outcome(dropping: task, onto: .area(areaId), calendar: calendar, now: now)
        case .noHeading:
            return task.headingId == nil ? .unchanged : .setHeading(nil)
        case .heading(let heading):
            return task.headingId == heading.id ? .unchanged : .setHeading(heading.id)
        case .overdue, .month, .finishedDay, .plain:
            return .unchanged
        }
    }

    // MARK: - Planning edits

    /// `task` with its when-bucket set. Today / Evening / Someday drop a defer
    /// date (so it shows up there now); This Evening also moves a task dated
    /// on another day to today, keeping its time of day; Someday keeps the
    /// date untouched (like the Mac's When ▸ Someday).
    static func planned(_ task: TodoTask, bucket: TaskScheduleBucket, calendar: Calendar, now: Date) -> TodoTask {
        var updated = task
        updated.scheduleBucket = bucket
        switch bucket {
        case .anytime:
            break
        case .today, .someday:
            updated.startAt = nil
        case .evening:
            updated.startAt = nil
            if let due = task.dueAt, !calendar.isDate(due, inSameDayAs: now) {
                let time = calendar.dateComponents([.hour, .minute], from: due)
                updated.dueAt = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0,
                                              second: 0, of: now) ?? calendar.startOfDay(for: now)
            }
        }
        return updated
    }

    /// `task` due on `day`, keeping its time of day. Leaves an Evening /
    /// Someday / Today plan for date-driven Anytime, and drops a defer date
    /// that would now hide it past its due day.
    static func rescheduled(_ task: TodoTask, to day: Date, calendar: Calendar) -> TodoTask {
        var updated = task
        let dayStart = calendar.startOfDay(for: day)
        if let due = task.dueAt, PlannerTimeOfDay.hasTime(due, calendar: calendar) {
            let time = calendar.dateComponents([.hour, .minute], from: due)
            updated.dueAt = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0,
                                          second: 0, of: dayStart) ?? dayStart
        } else {
            updated.dueAt = dayStart
        }
        updated.scheduleBucket = .anytime
        if let start = task.startAt, start > (updated.dueAt ?? dayStart) { updated.startAt = nil }
        return updated
    }

    /// Clears completion / cancellation (dropping a finished task on an open
    /// list reopens it).
    static func reopened(_ task: TodoTask) -> TodoTask {
        var updated = task
        updated.completedAt = nil
        updated.cancelledAt = nil
        return updated
    }
}

/// Date-only vs timed helper. Scribe stores a date-only due as local midnight.
enum PlannerTimeOfDay {
    static func hasTime(_ date: Date, calendar: Calendar) -> Bool {
        calendar.startOfDay(for: date) != date
    }
}
