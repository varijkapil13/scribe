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
        isPinned: Bool = false
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
    }

    var isCompleted: Bool { completedAt != nil }
    var isCancelled: Bool { cancelledAt != nil }
}

extension TodoTask: FetchableRecord, PersistableRecord {
    static let databaseTableName = "tasks"
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
