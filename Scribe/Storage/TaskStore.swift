import Foundation
import GRDB
import Combine

/// High-level query interface for Scribe's task layer.
///
/// Mirrors the design of `TranscriptStore`: a thin wrapper around a GRDB
/// `DatabaseQueue` providing strongly-typed CRUD and a handful of
/// view-specific queries (Inbox / Today / Upcoming).
final class TaskStore {

    // MARK: - Filters

    /// Filters used by the sidebar to drive the task list.
    enum Filter: Hashable {
        /// Tasks that are not completed and have no project assigned.
        case inbox
        /// Tasks with `dueAt` falling on the current calendar day (or overdue).
        case today
        /// Tasks with `dueAt` within the next 7 days (excluding today).
        case upcoming
        /// Every non-completed task.
        case all
        /// Every completed task.
        case completed
        /// Tasks belonging to a specific project.
        case project(String)
        /// Tasks tagged with a specific tag.
        case tag(String)
    }

    // MARK: - Properties

    private let dbManager: DatabaseManager

    private var db: DatabaseQueue { dbManager.database }

    // MARK: - Initializer

    init(databaseManager: DatabaseManager = .shared) {
        self.dbManager = databaseManager
    }

    // MARK: - Project CRUD

    @discardableResult
    func createProject(name: String, color: String? = nil, icon: String? = nil) throws -> Project {
        let nextOrder = try db.read { try Int.fetchOne($0,
            sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM projects") } ?? 0
        let project = Project(name: name, color: color, icon: icon, sortOrder: nextOrder)
        try db.write { try project.insert($0) }
        return project
    }

    func updateProject(_ project: Project) throws {
        try db.write { try project.update($0) }
    }

    func deleteProject(id: String) throws {
        try db.write { _ = try Project.deleteOne($0, key: id) }
    }

    func fetchProjects() throws -> [Project] {
        try db.read {
            try Project
                .order(Column("sortOrder").asc, Column("createdAt").asc)
                .fetchAll($0)
        }
    }

    // MARK: - Task CRUD

    @discardableResult
    func createTask(
        title: String,
        notes: String = "",
        projectId: String? = nil,
        priority: TodoTask.Priority? = nil,
        dueAt: Date? = nil,
        remindAt: Date? = nil,
        recurrenceRule: String? = nil,
        sourceSessionId: String? = nil,
        sourceActionItemId: String? = nil,
        tags: [String] = []
    ) throws -> TodoTask {
        let nextOrder = try db.read {
            try Int.fetchOne($0,
                sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM tasks WHERE projectId IS ?",
                arguments: [projectId])
        } ?? 0

        let now = Date()
        let task = TodoTask(
            title: title,
            notes: notes,
            projectId: projectId,
            priority: priority,
            dueAt: dueAt,
            remindAt: remindAt,
            recurrenceRule: recurrenceRule,
            createdAt: now,
            updatedAt: now,
            sortOrder: nextOrder,
            sourceSessionId: sourceSessionId,
            sourceActionItemId: sourceActionItemId
        )

        try db.write { database in
            try task.insert(database)
            for tag in normalisedTags(tags) {
                try TaskTagRow(taskId: task.id, tag: tag).insert(database)
            }
        }
        return task
    }

    /// Persists changes to an existing task. The caller is responsible for
    /// stamping `updatedAt`; if it equals the existing value we bump it here.
    func updateTask(_ task: TodoTask) throws {
        var copy = task
        copy.updatedAt = Date()
        try db.write { try copy.update($0) }
    }

    func deleteTask(id: String) throws {
        try db.write { _ = try TodoTask.deleteOne($0, key: id) }
    }

    /// Marks a task complete. For recurring tasks, the next occurrence is
    /// scheduled via `RecurrenceEngine` (added in slice 7); slice 1 simply
    /// records the completion timestamp.
    func completeTask(id: String, at date: Date = Date()) throws {
        try db.write { database in
            guard var task = try TodoTask.fetchOne(database, key: id) else { return }
            task.completedAt = date
            task.updatedAt = date
            try task.update(database)
            try TaskCompletion(taskId: id, completedAt: date).insert(database)
        }
    }

    /// Reverses a completion (undoes `completeTask`).
    func uncompleteTask(id: String) throws {
        try db.write { database in
            guard var task = try TodoTask.fetchOne(database, key: id) else { return }
            task.completedAt = nil
            task.updatedAt = Date()
            try task.update(database)
        }
    }

    func fetchTask(id: String) throws -> TodoTask? {
        try db.read { try TodoTask.fetchOne($0, key: id) }
    }

    // MARK: - Tags

    func setTags(_ tags: [String], for taskId: String) throws {
        let cleaned = normalisedTags(tags)
        try db.write { database in
            try database.execute(sql: "DELETE FROM task_tags WHERE taskId = ?", arguments: [taskId])
            for tag in cleaned {
                try TaskTagRow(taskId: taskId, tag: tag).insert(database)
            }
        }
    }

    func tags(for taskId: String) throws -> [String] {
        try db.read { database in
            try String.fetchAll(database,
                sql: "SELECT tag FROM task_tags WHERE taskId = ? ORDER BY tag ASC",
                arguments: [taskId])
        }
    }

    func allTags() throws -> [String] {
        try db.read { database in
            try String.fetchAll(database,
                sql: "SELECT DISTINCT tag FROM task_tags ORDER BY tag ASC")
        }
    }

    // MARK: - Filtered Queries

    /// Fetches tasks for a sidebar filter. Sort: incomplete first (by dueAt,
    /// then sortOrder), completed at the bottom (by completedAt desc).
    func fetchTasks(filter: Filter, calendar: Calendar = .current, now: Date = Date()) throws -> [TodoTask] {
        try db.read { database in
            try Self.fetchTasks(database, filter: filter, calendar: calendar, now: now)
        }
    }

    /// Inner query usable from any GRDB block (read, write, or observation).
    fileprivate static func fetchTasks(
        _ database: Database,
        filter: Filter,
        calendar: Calendar = .current,
        now: Date = Date()
    ) throws -> [TodoTask] {
        var request = TodoTask.all()

        switch filter {
        case .inbox:
            request = request
                .filter(Column("projectId") == nil)
                .filter(Column("completedAt") == nil)
        case .today:
            let endOfToday = calendar.endOfDay(for: now)
            request = request
                .filter(Column("completedAt") == nil)
                .filter(Column("dueAt") != nil && Column("dueAt") <= endOfToday)
        case .upcoming:
            let startOfTomorrow = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!)
            let endOfWindow = calendar.date(byAdding: .day, value: 7, to: startOfTomorrow)!
            request = request
                .filter(Column("completedAt") == nil)
                .filter(Column("dueAt") >= startOfTomorrow && Column("dueAt") < endOfWindow)
        case .all:
            request = request.filter(Column("completedAt") == nil)
        case .completed:
            request = request.filter(Column("completedAt") != nil)
        case .project(let id):
            request = request
                .filter(Column("projectId") == id)
                .filter(Column("completedAt") == nil)
        case .tag(let tag):
            let ids = try String.fetchAll(database,
                sql: "SELECT taskId FROM task_tags WHERE tag = ?",
                arguments: [tag])
            request = request
                .filter(ids.contains(Column("id")))
                .filter(Column("completedAt") == nil)
        }

        return try request
            .order(
                Column("completedAt").asc,
                Column("dueAt").asc,
                Column("sortOrder").asc,
                Column("createdAt").asc
            )
            .fetchAll(database)
    }

    // MARK: - Reordering

    /// Persists a new manual ordering for the given task ids.
    func reorderTasks(_ orderedIds: [String]) throws {
        try db.write { database in
            for (index, id) in orderedIds.enumerated() {
                try database.execute(
                    sql: "UPDATE tasks SET sortOrder = ?, updatedAt = ? WHERE id = ?",
                    arguments: [index, Date(), id]
                )
            }
        }
    }

    // MARK: - Observation

    /// Combine publisher emitting tasks for the given filter whenever the
    /// underlying tables change.
    func observeTasks(filter: Filter) -> DatabasePublishers.Value<[TodoTask]> {
        let observation = ValueObservation.tracking { database -> [TodoTask] in
            try Self.fetchTasks(database, filter: filter)
        }
        return observation.publisher(in: db, scheduling: .immediate)
    }

    // MARK: - Helpers

    private func normalisedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in tags {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }
}

// MARK: - Calendar convenience

private extension Calendar {
    func endOfDay(for date: Date) -> Date {
        let start = startOfDay(for: date)
        return self.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }
}
