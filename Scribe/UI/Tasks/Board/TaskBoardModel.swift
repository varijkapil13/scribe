import Foundation

// MARK: - Layout mode + grouping

/// How a task list is presented: the classic bucketed list, or a Kanban board.
/// Persisted per filter by `TaskListView`.
enum TaskListLayoutMode: String, CaseIterable, Identifiable, Sendable {
    case list
    case board

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list:  return "List"
        case .board: return "Board"
        }
    }

    var systemImage: String {
        switch self {
        case .list:  return "list.bullet"
        case .board: return "rectangle.split.3x1"
        }
    }
}

/// What the Kanban board's columns are.
enum TaskBoardGrouping: String, CaseIterable, Identifiable, Sendable {
    /// To Do / Today / This Evening / Someday / Done (the task's when-bucket
    /// plus completion).
    case status
    /// Inbox + one column per project.
    case project
    /// High / Medium / Low / None.
    case priority

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status:   return "Status"
        case .project:  return "Project"
        case .priority: return "Priority"
        }
    }

    var systemImage: String {
        switch self {
        case .status:   return "circle.lefthalf.filled"
        case .project:  return "folder"
        case .priority: return "flag"
        }
    }

    /// Edit › Undo title for a card dragged between columns.
    var undoActionName: String {
        switch self {
        case .status:   return "Change Status"
        case .project:  return "Move to Project"
        case .priority: return "Change Priority"
        }
    }
}

/// A status column of the board.
enum TaskBoardStatus: String, CaseIterable, Hashable, Sendable {
    case toDo
    case today
    case evening
    case someday
    case done

    var title: String {
        switch self {
        case .toDo:    return "To Do"
        case .today:   return "Today"
        case .evening: return "This Evening"
        case .someday: return "Someday"
        case .done:    return "Done"
        }
    }

    var systemImage: String {
        switch self {
        case .toDo:    return "circle"
        case .today:   return "star"
        case .evening: return "moon"
        case .someday: return "archivebox"
        case .done:    return "checkmark.circle"
        }
    }
}

/// Identity of one board column. `project(nil)` is the Inbox column and
/// `priority(nil)` the "None" column.
enum TaskBoardColumnKey: Hashable {
    case status(TaskBoardStatus)
    case project(String?)
    case priority(TodoTask.Priority?)

    /// Stable string form (SwiftUI ids, accessibility identifiers, drop
    /// highlight bookkeeping).
    var stableId: String {
        switch self {
        case .status(let status):     return "status.\(status.rawValue)"
        case .project(let id):        return "project.\(id ?? "inbox")"
        case .priority(let priority): return "priority.\(priority?.rawValue ?? "none")"
        }
    }
}

/// One column of the board, ready to render.
struct TaskBoardColumn: Identifiable, Equatable {
    let key: TaskBoardColumnKey
    let title: String
    let systemImage: String
    /// Project colour (hex) for project columns, nil otherwise.
    let colorHex: String?
    var tasks: [TodoTask]

    var id: String { key.stableId }
}

// MARK: - Column building (pure)

enum TaskBoardLayout {

    /// The status column a task belongs in.
    nonisolated static func status(of task: TodoTask) -> TaskBoardStatus {
        if task.isCompleted || task.isCancelled { return .done }
        switch task.scheduleBucket {
        case .anytime: return .toDo
        case .today:   return .today
        case .evening: return .evening
        case .someday: return .someday
        }
    }

    /// Builds every column for `grouping`, empty ones included (so they accept
    /// drops). `active` is the list's current task set, in display order;
    /// `done` is the scoped recently-finished set (status grouping only — the
    /// other groupings show open tasks only). A task present in both is taken
    /// from `active` (it may be a pre-completion settle snapshot).
    nonisolated static func columns(
        active: [TodoTask],
        done: [TodoTask],
        grouping: TaskBoardGrouping,
        projects: [Project]
    ) -> [TaskBoardColumn] {
        switch grouping {
        case .status:
            var byStatus: [TaskBoardStatus: [TodoTask]] = [:]
            var seen = Set<String>()
            for task in active where seen.insert(task.id).inserted {
                byStatus[status(of: task), default: []].append(task)
            }
            for task in done where seen.insert(task.id).inserted {
                byStatus[.done, default: []].append(task)
            }
            return TaskBoardStatus.allCases.map { status in
                TaskBoardColumn(key: .status(status), title: status.title,
                                systemImage: status.systemImage, colorHex: nil,
                                tasks: byStatus[status] ?? [])
            }

        case .project:
            let open = openTasks(active)
            let known = Set(projects.map(\.id))
            var byProject: [String: [TodoTask]] = [:]
            var inbox: [TodoTask] = []
            for task in open {
                if let projectId = task.projectId, known.contains(projectId) {
                    byProject[projectId, default: []].append(task)
                } else {
                    inbox.append(task)
                }
            }
            var out = [TaskBoardColumn(key: .project(nil), title: "Inbox",
                                       systemImage: "tray", colorHex: nil, tasks: inbox)]
            for project in projects {
                out.append(TaskBoardColumn(key: .project(project.id), title: project.name,
                                           systemImage: project.icon ?? "folder",
                                           colorHex: project.color,
                                           tasks: byProject[project.id] ?? []))
            }
            return out

        case .priority:
            let open = openTasks(active)
            let order: [TodoTask.Priority?] = [.high, .medium, .low, nil]
            return order.map { priority in
                TaskBoardColumn(key: .priority(priority),
                                title: priority?.rawValue ?? "None",
                                systemImage: priority == nil ? "flag.slash" : "flag.fill",
                                colorHex: nil,
                                tasks: open.filter { $0.priority == priority })
            }
        }
    }

    /// Open (not completed, not cancelled) tasks, first occurrence of each id.
    nonisolated private static func openTasks(_ tasks: [TodoTask]) -> [TodoTask] {
        var seen = Set<String>()
        return tasks.filter { !$0.isCompleted && !$0.isCancelled && seen.insert($0.id).inserted }
    }

    /// How many days back the Done column reaches for a filter. Nil = no limit
    /// (the Completed list itself).
    nonisolated static func doneWindowDays(for filter: TaskStore.Filter) -> Int? {
        switch filter {
        case .completed: return nil
        case .today:     return 1
        default:         return 7
        }
    }

    /// Recently finished tasks (completed or cancelled) that belong to
    /// `filter`'s scope, newest first — the board's Done column. Active lists
    /// never include finished tasks, so the board reads them separately.
    nonisolated static func doneTasks(
        _ finished: [TodoTask],
        filter: TaskStore.Filter,
        tagsByTask: [String: [String]],
        projectAreaIds: [String: String],
        calendar: Calendar,
        now: Date
    ) -> [TodoTask] {
        var cutoff: Date?
        if let days = doneWindowDays(for: filter) {
            let today = calendar.startOfDay(for: now)
            cutoff = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today
        }
        let scoped = finished.filter { task in
            guard let finishedAt = task.completedAt ?? task.cancelledAt else { return false }
            if let cutoff, finishedAt < cutoff { return false }
            switch filter {
            case .inbox:
                return task.projectId == nil
            case .project(let id):
                return task.projectId == id
            case .area(let id):
                if task.areaId == id { return true }
                if let projectId = task.projectId { return projectAreaIds[projectId] == id }
                return false
            case .tag(let tag):
                return (tagsByTask[task.id] ?? []).contains(tag)
            case .someday:
                return task.scheduleBucket == .someday
            case .today, .dueOn, .upcoming, .all, .completed:
                return true
            }
        }
        return scoped.sorted { a, b in
            let fa = a.completedAt ?? a.cancelledAt ?? .distantPast
            let fb = b.completedAt ?? b.cancelledAt ?? .distantPast
            return fa != fb ? fa > fb : a.id < b.id
        }
    }
}

// MARK: - Dropping a card on a column (pure)

/// What dropping a card on a column does to the task.
enum TaskBoardDropOutcome: Equatable {
    /// The task is already in that column.
    case unchanged
    /// Store this row (`TaskStore.updateTask`).
    case update(TodoTask)
    /// Complete it through `TaskStore.completeTask` (recurrence-aware: a
    /// recurring task advances instead of finishing).
    case complete
    /// Re-file it through `TaskStore.moveTask` (keeps heading / area links
    /// consistent and appends it to the destination).
    case moveToProject(String?)
}

enum TaskBoardMove {

    nonisolated static func outcome(
        dropping task: TodoTask,
        into key: TaskBoardColumnKey,
        calendar: Calendar,
        now: Date
    ) -> TaskBoardDropOutcome {
        switch key {
        case .status(let target):
            let current = TaskBoardLayout.status(of: task)
            guard current != target else { return .unchanged }
            if target == .done { return .complete }
            return .update(reopened(task, into: target, calendar: calendar, now: now))

        case .project(let projectId):
            return task.projectId == projectId ? .unchanged : .moveToProject(projectId)

        case .priority(let priority):
            guard task.priority != priority else { return .unchanged }
            var updated = task
            updated.priority = priority
            return .update(updated)
        }
    }

    /// `task` moved to an open status column: completion / cancellation are
    /// cleared and the when-bucket set. Planning into Today / This Evening /
    /// Someday drops any defer date (so the task shows up there now); This
    /// Evening also moves a task dated on another day to today, keeping its
    /// time of day (same rule as the list's "This Evening" action).
    nonisolated static func reopened(
        _ task: TodoTask,
        into status: TaskBoardStatus,
        calendar: Calendar,
        now: Date
    ) -> TodoTask {
        var updated = task
        updated.completedAt = nil
        updated.cancelledAt = nil
        switch status {
        case .toDo:
            updated.scheduleBucket = .anytime
        case .today:
            updated.scheduleBucket = .today
            updated.startAt = nil
        case .evening:
            updated.scheduleBucket = .evening
            updated.startAt = nil
            if let due = task.dueAt, !calendar.isDate(due, inSameDayAs: now) {
                let time = calendar.dateComponents([.hour, .minute], from: due)
                updated.dueAt = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0,
                                              second: 0, of: now) ?? calendar.startOfDay(for: now)
            }
        case .someday:
            updated.scheduleBucket = .someday
            updated.startAt = nil
        case .done:
            break
        }
        return updated
    }

    /// `current` with the fields a `grouping` drop can change copied back from
    /// `snapshot` — what undo / redo write. Unrelated edits made in between
    /// (title, notes, tags…) are kept.
    nonisolated static func restoring(
        _ grouping: TaskBoardGrouping,
        from snapshot: TodoTask,
        to current: TodoTask
    ) -> TodoTask {
        var result = current
        switch grouping {
        case .status:
            result.completedAt = snapshot.completedAt
            result.cancelledAt = snapshot.cancelledAt
            result.scheduleBucket = snapshot.scheduleBucket
            result.startAt = snapshot.startAt
            // A recurring completion advances the due date (and may rewrite
            // COUNT); an evening plan may move it to today.
            result.dueAt = snapshot.dueAt
            result.recurrenceRule = snapshot.recurrenceRule
        case .project:
            result.projectId = snapshot.projectId
            result.headingId = snapshot.headingId
            result.areaId = snapshot.areaId
            result.sortOrder = snapshot.sortOrder
        case .priority:
            result.priority = snapshot.priority
        }
        return result
    }
}
