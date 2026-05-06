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
        sourceActionItemId: String? = nil
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
    }

    var isCompleted: Bool { completedAt != nil }
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
