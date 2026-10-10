import Foundation

/// What a scheduled task's mirrored calendar event should look like.
struct TaskCalendarBlockDraft: Equatable, Hashable, Sendable {
    let taskId: String
    let title: String
    let start: Date
    let end: Date
}

/// One step of a time-blocking pass. Every step that touches an existing event
/// carries the link row it came from: the mirror only ever edits or deletes an
/// event whose identifier Scribe recorded when it created it.
enum TaskCalendarMirrorAction: Equatable, Sendable {
    /// Write a new event for the task (and record its link, replacing any
    /// stale link for the same task).
    case create(TaskCalendarBlockDraft)
    /// Move / retitle Scribe's existing event.
    case update(TaskCalendarBlockLink, TaskCalendarBlockDraft)
    /// Remove Scribe's event and its link (task completed, deleted,
    /// unscheduled, mirroring turned off, or the target calendar changed).
    case delete(TaskCalendarBlockLink)
    /// The event is already gone from the calendar: drop the link only.
    case forget(TaskCalendarBlockLink)
}

/// Settings + clock the planner decides against.
struct TaskCalendarMirrorConfiguration: Equatable, Sendable {
    /// "Write scheduled tasks to calendar".
    var isEnabled: Bool
    /// `EKCalendar.calendarIdentifier` new blocks go to. Nil = none chosen
    /// (treated like off).
    var calendarId: String?
    /// Only blocks overlapping `[windowStart, windowEnd)` are newly created,
    /// so enabling the feature doesn't flood the calendar with old history.
    /// Blocks Scribe already mirrors keep being updated outside the window.
    var windowStart: Date
    var windowEnd: Date

    /// The default window around `now`: yesterday through 60 days ahead.
    nonisolated static func window(around now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
        let end = calendar.date(byAdding: .day, value: 60, to: today) ?? today.addingTimeInterval(60 * 86_400)
        return (start, end)
    }
}

/// Pure create / update / delete decisions for mirroring scheduled task
/// blocks into a calendar. The EventKit side (`TaskCalendarMirrorService`)
/// executes the actions; it never decides anything itself.
enum TaskCalendarMirrorPlanner {

    nonisolated static let untitledTitle = "Untitled task"

    /// The block a task should have on the calendar, or nil when it shouldn't
    /// be mirrored (finished, or no time of day).
    nonisolated static func draft(for task: TodoTask, calendar: Calendar) -> TaskCalendarBlockDraft? {
        guard PlannerScheduling.isOpen(task),
              let due = task.dueAt,
              PlannerScheduling.hasTime(due, calendar: calendar) else { return nil }
        let minutes = PlannerScheduling.durationMinutes(of: task)
        let trimmed = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return TaskCalendarBlockDraft(
            taskId: task.id,
            title: trimmed.isEmpty ? untitledTitle : trimmed,
            start: due,
            end: due.addingTimeInterval(TimeInterval(minutes * 60))
        )
    }

    /// Whether the event Scribe last wrote for `link` differs from `draft`.
    nonisolated static func needsUpdate(_ link: TaskCalendarBlockLink, for draft: TaskCalendarBlockDraft) -> Bool {
        link.lastStart != draft.start || link.lastEnd != draft.end || link.lastTitle != draft.title
    }

    /// Plans one pass.
    ///
    /// - Parameters:
    ///   - tasks: every task row (finished ones included; a task missing from
    ///     this list is treated as deleted).
    ///   - links: every `task_calendar_blocks` row.
    ///   - existingEventIds: identifiers (from `links`) whose event still
    ///     exists in the calendar store.
    /// - Returns: deletes / forgets first, then updates, then creates; each
    ///   group ordered by task id.
    nonisolated static func plan(
        tasks: [TodoTask],
        links: [TaskCalendarBlockLink],
        existingEventIds: Set<String>,
        configuration: TaskCalendarMirrorConfiguration,
        calendar: Calendar
    ) -> [TaskCalendarMirrorAction] {
        var removals: [TaskCalendarMirrorAction] = []
        var updates: [TaskCalendarMirrorAction] = []
        var creates: [TaskCalendarMirrorAction] = []

        let sortedLinks = links.sorted { $0.taskId < $1.taskId }

        func removal(_ link: TaskCalendarBlockLink) -> TaskCalendarMirrorAction {
            existingEventIds.contains(link.eventIdentifier) ? .delete(link) : .forget(link)
        }

        guard configuration.isEnabled, let targetCalendarId = configuration.calendarId,
              !targetCalendarId.isEmpty else {
            return sortedLinks.map(removal)
        }

        var linkByTask: [String: TaskCalendarBlockLink] = [:]
        for link in sortedLinks where linkByTask[link.taskId] == nil {
            linkByTask[link.taskId] = link
        }

        var drafts: [String: TaskCalendarBlockDraft] = [:]
        for task in tasks where drafts[task.id] == nil {
            guard let draft = Self.draft(for: task, calendar: calendar) else { continue }
            let inWindow = draft.end > configuration.windowStart && draft.start < configuration.windowEnd
            if inWindow || linkByTask[task.id] != nil {
                drafts[task.id] = draft
            }
        }

        for link in sortedLinks {
            // A duplicate row for a task (shouldn't happen: taskId is the
            // primary key) is simply dropped.
            guard linkByTask[link.taskId] == link else {
                removals.append(removal(link))
                continue
            }
            guard let draft = drafts[link.taskId] else {
                removals.append(removal(link))
                continue
            }
            let exists = existingEventIds.contains(link.eventIdentifier)
            if link.calendarId != targetCalendarId {
                // Calendar changed in Settings: move the block over.
                removals.append(removal(link))
                creates.append(.create(draft))
            } else if !exists {
                // Removed in Calendar while the task is still scheduled: the
                // task is the source of truth, so the block comes back.
                removals.append(.forget(link))
                creates.append(.create(draft))
            } else if needsUpdate(link, for: draft) {
                updates.append(.update(link, draft))
            }
        }

        for taskId in drafts.keys.sorted() where linkByTask[taskId] == nil {
            if let draft = drafts[taskId] { creates.append(.create(draft)) }
        }

        creates.sort { lhs, rhs in
            guard case .create(let a) = lhs, case .create(let b) = rhs else { return false }
            return a.taskId < b.taskId
        }
        return removals + updates + creates
    }
}
