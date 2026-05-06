import Foundation
import GRDB
import Combine

enum TaskStoreError: LocalizedError {
    case recurringTaskRequiresDueDate

    var errorDescription: String? {
        switch self {
        case .recurringTaskRequiresDueDate:
            return "A recurring task must have a due date."
        }
    }
}

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
        try db.write { database in
            let nextOrder = try Int.fetchOne(database,
                sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM projects") ?? 0
            let project = Project(name: name, color: color, icon: icon, sortOrder: nextOrder)
            try project.insert(database)
            return project
        }
    }

    func updateProject(_ project: Project) throws {
        try db.write { try project.update($0) }
    }

    func deleteProject(id: String) throws {
        try db.write { _ = try Project.deleteOne($0, key: id) }
    }

    func fetchProjects() throws -> [Project] {
        try db.read { try Self.fetchProjects($0) }
    }

    fileprivate static func fetchProjects(_ database: Database) throws -> [Project] {
        try Project
            .order(Column("sortOrder").asc, Column("createdAt").asc)
            .fetchAll(database)
    }

    /// Persists a new manual ordering for the sidebar's project list. Ids
    /// not present in the projects table are silently skipped.
    func reorderProjects(_ orderedIds: [String]) throws {
        try db.write { database in
            for (index, id) in orderedIds.enumerated() {
                try database.execute(
                    sql: "UPDATE projects SET sortOrder = ? WHERE id = ?",
                    arguments: [index, id]
                )
            }
        }
    }

    /// Combine publisher emitting the project list whenever the projects
    /// table changes. Used by the sidebar so create/edit/delete reflect
    /// without manual refresh.
    func observeProjects() -> DatabasePublishers.Value<[Project]> {
        let observation = ValueObservation.tracking { database -> [Project] in
            try Self.fetchProjects(database)
        }
        return observation.publisher(in: db, scheduling: .async(onQueue: .main))
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
        try validateRecurrence(rule: recurrenceRule, dueAt: dueAt)
        return try db.write { database in
            let nextOrder = try Int.fetchOne(database,
                sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM tasks WHERE projectId IS ?",
                arguments: [projectId]) ?? 0

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

            try task.insert(database)
            for tag in normalisedTags(tags) {
                try TaskTagRow(taskId: task.id, tag: tag).insert(database)
            }
            return task
        }
    }

    /// Persists changes to an existing task. `updatedAt` is always stamped
    /// to the current time so callers don't have to remember to bump it.
    func updateTask(_ task: TodoTask) throws {
        var copy = task
        copy.updatedAt = Date()
        try validateRecurrence(rule: copy.recurrenceRule, dueAt: copy.dueAt)
        try db.write { try copy.update($0) }
    }

    func deleteTask(id: String) throws {
        try db.write { _ = try TodoTask.deleteOne($0, key: id) }
    }

    /// Moves a task to a different project (or out to Inbox when `projectId`
    /// is nil) and assigns it the next sortOrder within the destination
    /// scope so it lands at the bottom of the list.
    func moveTask(id: String, toProject projectId: String?) throws {
        try db.write { database in
            guard var task = try TodoTask.fetchOne(database, key: id) else { return }
            let nextOrder = try Int.fetchOne(database,
                sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM tasks WHERE projectId IS ?",
                arguments: [projectId]) ?? 0
            task.projectId = projectId
            task.sortOrder = nextOrder
            task.updatedAt = Date()
            try task.update(database)
        }
    }

    /// Marks a task complete. For recurring tasks, advances `dueAt` to the
    /// next occurrence and clears `completedAt`; for one-off tasks, sets
    /// `completedAt`. Either way a `task_completions` history row is written.
    func completeTask(id: String, at date: Date = Date()) throws {
        try db.write { database in
            guard var task = try TodoTask.fetchOne(database, key: id) else { return }
            try TaskCompletion(taskId: id, completedAt: date).insert(database)

            if let ruleStr = task.recurrenceRule,
               let due = task.dueAt {
                let rule = try RecurrenceRule.parse(ruleStr)
                task.dueAt = RecurrenceEngine.nextDate(after: due, rule: rule)
                task.completedAt = nil
            } else {
                task.completedAt = date
            }

            task.updatedAt = date
            try task.update(database)
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

    /// Returns the task created from the given action item, if any. Used by
    /// the convert-to-task button in `TranscriptDetailView` to switch the row
    /// from "Convert" to "Open task" once a link exists.
    func fetchTaskForActionItem(_ actionItemId: String) throws -> TodoTask? {
        try db.read { database in
            try TodoTask
                .filter(Column("sourceActionItemId") == actionItemId)
                .fetchOne(database)
        }
    }

    /// Bulk variant — returns the set of action-item ids that already have a
    /// linked task, so a transcript view can mark every "converted" row in
    /// one query rather than N.
    func actionItemIdsWithLinkedTasks(in actionItemIds: [String]) throws -> Set<String> {
        guard !actionItemIds.isEmpty else { return [] }
        return try db.read { database in
            let tasks = try TodoTask
                .filter(actionItemIds.contains(Column("sourceActionItemId")))
                .fetchAll(database)
            return Set(tasks.compactMap(\.sourceActionItemId))
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

    /// Fetches tasks for a sidebar filter. Sort: incomplete first (by dueAt
    /// then sortOrder), completed at the bottom (most recently completed
    /// first).
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
            // Half-open window `dueAt < startOfTomorrow` includes overdue and
            // every dueAt today regardless of sub-second precision.
            let startOfTomorrow = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!)
            request = request
                .filter(Column("completedAt") == nil)
                .filter(Column("dueAt") != nil && Column("dueAt") < startOfTomorrow)
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
            // Avoid emitting `id IN ()` (rejected by some SQLite versions).
            guard !ids.isEmpty else { return [] }
            request = request
                .filter(ids.contains(Column("id")))
                .filter(Column("completedAt") == nil)
        }

        // Incomplete tasks first (NULL `completedAt` ranked highest via the
        // explicit `IS NULL DESC`), tie-broken by dueAt then sortOrder.
        // Completed tasks fall to the bottom and are sorted newest-first.
        return try request
            .order(sql: """
                completedAt IS NULL DESC,
                completedAt DESC,
                dueAt ASC,
                sortOrder ASC,
                createdAt ASC
                """)
            .fetchAll(database)
    }

    // MARK: - Reordering

    /// Persists a new manual ordering for the given task ids within a single
    /// project scope (`projectId == nil` = Inbox). `sortOrder` is per-project,
    /// so callers must reorder one scope at a time; ids in `orderedIds` that
    /// don't live in `projectId` are skipped to keep scopes independent.
    func reorderTasks(_ orderedIds: [String], in projectId: String? = nil) throws {
        try db.write { database in
            let now = Date()
            for (index, id) in orderedIds.enumerated() {
                try database.execute(
                    sql: """
                        UPDATE tasks
                        SET sortOrder = ?, updatedAt = ?
                        WHERE id = ? AND projectId IS ?
                        """,
                    arguments: [index, now, id, projectId]
                )
            }
        }
    }

    // MARK: - Search

    /// Full-text search over `title` + `notes` via the `tasks_fts` FTS5
    /// virtual table. Returns matching tasks ordered by FTS5's bm25 ranking
    /// (best match first). Empty queries return an empty array.
    ///
    /// Free-text input is sanitised: each token is wrapped in double quotes
    /// and a `*` prefix is appended so partial words match. This avoids
    /// the user having to type FTS5's syntax themselves and prevents the
    /// query from blowing up on punctuation.
    func searchTasks(query: String, includeCompleted: Bool = true, limit: Int = 100) throws -> [TodoTask] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let sanitized = Self.ftsQuery(from: trimmed)
        guard !sanitized.isEmpty else { return [] }

        return try db.read { database in
            var sql = """
                SELECT tasks.* FROM tasks
                JOIN tasks_fts ON tasks_fts.rowid = tasks.rowid
                WHERE tasks_fts MATCH ?
                """
            if !includeCompleted {
                sql += " AND tasks.completedAt IS NULL"
            }
            sql += " ORDER BY bm25(tasks_fts) ASC LIMIT ?"
            return try TodoTask.fetchAll(database, sql: sql,
                                         arguments: [sanitized, limit])
        }
    }

    /// Builds a safe FTS5 MATCH expression from raw user input. Splits on
    /// whitespace, drops anything that isn't alphanumeric, wraps each
    /// surviving token in double quotes (so single quotes / hyphens don't
    /// break the parser), and appends `*` for prefix matching.
    static func ftsQuery(from raw: String) -> String {
        let tokens = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .map { token in
                token.unicodeScalars
                    .filter { CharacterSet.alphanumerics.contains($0) }
                    .reduce(into: "") { $0.append(Character($1)) }
            }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // MARK: - Observation

    /// Combine publisher emitting tasks for the given filter whenever the
    /// underlying tables change.
    func observeTasks(filter: Filter) -> DatabasePublishers.Value<[TodoTask]> {
        let observation = ValueObservation.tracking { database -> [TodoTask] in
            try Self.fetchTasks(database, filter: filter)
        }
        return observation.publisher(in: db, scheduling: .async(onQueue: .main))
    }

    /// Batch-fetches tags for a set of task ids. Returns a dictionary keyed by
    /// task id so callers can do O(1) lookups per row. Tasks with no tags are
    /// absent from the result (treat a missing key as an empty array).
    func fetchTagsForTasks(_ ids: [String]) throws -> [String: [String]] {
        guard !ids.isEmpty else { return [:] }
        return try db.read { database in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(database,
                sql: "SELECT taskId, tag FROM task_tags WHERE taskId IN (\(placeholders)) ORDER BY tag ASC",
                arguments: StatementArguments(ids))
            var out: [String: [String]] = [:]
            for row in rows {
                out[row["taskId"], default: []].append(row["tag"])
            }
            return out
        }
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

    private func validateRecurrence(rule: String?, dueAt: Date?) throws {
        guard let ruleStr = rule else { return }
        if dueAt == nil { throw TaskStoreError.recurringTaskRequiresDueDate }
        _ = try RecurrenceRule.parse(ruleStr)
    }
}

