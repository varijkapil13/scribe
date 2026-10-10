import Foundation
import GRDB

/// A user-actionable task in Scribe's task layer.
///
/// Named `TodoTask` instead of `Task` to avoid colliding with
/// `_Concurrency.Task` (which is used pervasively across the UI for `Task { }`
/// blocks). The underlying database table is `tasks`.
struct TodoTask: Codable, Identifiable, Equatable, Hashable {

    enum Priority: String, Codable, CaseIterable, Hashable {
        case high   = "High"
        case medium = "Medium"
        case low    = "Low"
    }

    var id: String
    var title: String
    var notes: String
    var projectId: String?
    var priority: Priority?
    var dueAt: Date?
    var remindAt: Date?
    /// RRULE-flavoured recurrence rule (e.g. "FREQ=WEEKLY;BYDAY=MO,WE,FR").
    /// Parsed by `RecurrenceEngine` (added in slice 7).
    var recurrenceRule: String?
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var sortOrder: Int
    /// Optional link back to the meeting session this task came from.
    var sourceSessionId: String?
    /// Optional link back to the summary action item that produced this task.
    var sourceActionItemId: String?
    /// Non-nil when the task is cancelled ("Won't do"): excluded from active
    /// lists, shown struck + muted under Completed. Mutually exclusive with
    /// completion (setting one clears the other).
    var cancelledAt: Date?
    /// Floats the task to the top of its bucket.
    var isPinned: Bool
    /// Defer / start date (v20): the task stays out of Today until this day
    /// arrives. Nil = available now.
    var startAt: Date?
    /// Things-style "when" bucket (v20): explicitly Today, This Evening, or
    /// Someday. `.anytime` leaves the task purely date-driven.
    var scheduleBucket: TaskScheduleBucket
    /// Estimated duration in minutes (v20). Nil = no estimate.
    var estimatedMinutes: Int?
    /// Area the task belongs to directly when it has no project (v20). Tasks
    /// inside a project inherit the project's area instead.
    var areaId: String?
    /// Heading inside the task's project the task is filed under (v20).
    var headingId: String?

    init(
        id: String = UUID().uuidString,
        title: String,
        notes: String = "",
        projectId: String? = nil,
        priority: Priority? = nil,
        dueAt: Date? = nil,
        remindAt: Date? = nil,
        recurrenceRule: String? = nil,
        completedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sortOrder: Int = 0,
        sourceSessionId: String? = nil,
        sourceActionItemId: String? = nil,
        cancelledAt: Date? = nil,
        isPinned: Bool = false,
        startAt: Date? = nil,
        scheduleBucket: TaskScheduleBucket = .anytime,
        estimatedMinutes: Int? = nil,
        areaId: String? = nil,
        headingId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.projectId = projectId
        self.priority = priority
        self.dueAt = dueAt
        self.remindAt = remindAt
        self.recurrenceRule = recurrenceRule
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
        self.sourceSessionId = sourceSessionId
        self.sourceActionItemId = sourceActionItemId
        self.cancelledAt = cancelledAt
        self.isPinned = isPinned
        self.startAt = startAt
        self.scheduleBucket = scheduleBucket
        self.estimatedMinutes = estimatedMinutes
        self.areaId = areaId
        self.headingId = headingId
    }

    var isCompleted: Bool { completedAt != nil }
    var isCancelled: Bool { cancelledAt != nil }
}

extension TodoTask: FetchableRecord, PersistableRecord {
    static let databaseTableName = "tasks"
}

// MARK: - Planning (v20)

/// Things-style "when" bucket for a task. Stored as its raw string in
/// `tasks.scheduleBucket` (NOT NULL, default `none`).
enum TaskScheduleBucket: String, Codable, CaseIterable, Hashable, Sendable {
    /// Date-driven only (the default). Stored as "none"; the case is named
    /// `anytime` so it never collides with `Optional.none`.
    case anytime = "none"
    /// Explicitly planned for today, whatever its due date.
    case today
    /// Planned for this evening: shown in Today's "This Evening" section.
    case evening
    /// Parked for later: out of Inbox / Today / Upcoming, listed under Someday.
    case someday

    var title: String {
        switch self {
        case .anytime: return "Anytime"
        case .today:   return "Today"
        case .evening: return "This Evening"
        case .someday: return "Someday"
        }
    }

    var systemImage: String {
        switch self {
        case .anytime: return "circle.dashed"
        case .today:   return "star"
        case .evening: return "moon"
        case .someday: return "archivebox"
        }
    }
}

/// An Area groups projects (and loose tasks), like Things' areas of
/// responsibility. Persisted in the `areas` table (v20).
struct TaskArea: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var sortOrder: Int
    /// SF Symbol name; nil falls back to a generic area glyph.
    var symbol: String?

    init(id: String = UUID().uuidString, name: String, sortOrder: Int = 0, symbol: String? = nil) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.symbol = symbol
    }
}

extension TaskArea: FetchableRecord, PersistableRecord {
    static let databaseTableName = "areas"
}

/// A heading inside a project's task list (Things-style). Persisted in the
/// `project_headings` table (v20) with an `ON DELETE CASCADE` FK to its
/// project; tasks reference it via `tasks.headingId` (`ON DELETE SET NULL`).
struct ProjectHeading: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var projectId: String
    var title: String
    var sortOrder: Int

    init(id: String = UUID().uuidString, projectId: String, title: String, sortOrder: Int = 0) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.sortOrder = sortOrder
    }
}

extension ProjectHeading: FetchableRecord, PersistableRecord {
    static let databaseTableName = "project_headings"
}

// MARK: - Junction / history rows

/// Junction row for the many-to-many `task_tags` table.
struct TaskTagRow: Codable, Equatable, Hashable {
    var taskId: String
    var tag: String
}

extension TaskTagRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "task_tags"
}

/// History row for completion events on recurring tasks.
struct TaskCompletion: Codable, Identifiable, Equatable, Hashable {
    var id: Int64?
    var taskId: String
    var completedAt: Date

    init(id: Int64? = nil, taskId: String, completedAt: Date = Date()) {
        self.id = id
        self.taskId = taskId
        self.completedAt = completedAt
    }
}

extension TaskCompletion: FetchableRecord, PersistableRecord {
    static let databaseTableName = "task_completions"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Subtasks / checklist (TickTick parity)

/// A single checklist item belonging to a `TodoTask`. Persisted in the
/// `task_subtasks` table (v14 migration) with an `ON DELETE CASCADE` FK so a
/// task's subtasks vanish when the parent is deleted.
struct TaskSubtask: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var taskId: String
    var title: String
    var isCompleted: Bool
    var sortOrder: Int
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        taskId: String,
        title: String,
        isCompleted: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskId = taskId
        self.title = title
        self.isCompleted = isCompleted
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

extension TaskSubtask: FetchableRecord, PersistableRecord {
    static let databaseTableName = "task_subtasks"
}

/// Lightweight progress snapshot for a task's checklist — used by the list-row
/// "n/m" chip without fetching the full subtask list.
struct SubtaskProgress: Equatable, Hashable {
    var completed: Int
    var total: Int

    var isComplete: Bool { total > 0 && completed == total }
    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}
