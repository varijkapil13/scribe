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
        /// Tasks with `dueAt` falling on the given calendar day only. Used by
        /// the Today destination when the user navigates to a non-today date
        /// via the date strip — strict day window, no overdue inclusion.
        case dueOn(Date)
        /// Dated, incomplete tasks the user should act on soon: everything
        /// overdue, due today, and due within the next 7 days. The view groups
        /// these into Overdue / Today / Next-7-days sections so overdue work
        /// leads rather than vanishing (a task-app should never silently hide
        /// past-due items).
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

    nonisolated(unsafe) static let shared = TaskStore(databaseManager: .shared)

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
        try db.write { database in
            _ = try TodoTask.deleteOne(database, key: id)
            try Self.recordTombstone(database, id: id)
        }
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
                // Advance in the user's local calendar: dueAt carries local
                // wall-clock semantics, so weekday/month extraction and DST
                // handling must use Calendar.current, not UTC.
                task.dueAt = RecurrenceEngine.nextDate(after: due, rule: rule, calendar: .current)
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
        case .dueOn(let date):
            let startOfDay = calendar.startOfDay(for: date)
            let startOfNext = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: startOfDay)!)
            request = request
                .filter(Column("completedAt") == nil)
                .filter(Column("dueAt") != nil
                        && Column("dueAt") >= startOfDay
                        && Column("dueAt") < startOfNext)
        case .upcoming:
            // Lead with overdue: include everything dated up to the end of the
            // next-7-days window (overdue + today + the coming week). The view
            // buckets these into Overdue / Today / Next 7 days. Undated tasks
            // are excluded — this is a date-driven view.
            let startOfTomorrow = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!)
            let endOfWindow = calendar.date(byAdding: .day, value: 7, to: startOfTomorrow)!
            request = request
                .filter(Column("completedAt") == nil)
                .filter(Column("dueAt") != nil && Column("dueAt") < endOfWindow)
        case .all:
            request = request.filter(Column("completedAt") == nil)
        case .completed:
            // Completed includes cancelled ("Won't do") tasks, shown muted.
            request = request.filter(Column("completedAt") != nil || Column("cancelledAt") != nil)
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

        // Cancelled ("Won't do") tasks are hidden from every active list and
        // surface only under .completed.
        if case .completed = filter {} else {
            request = request.filter(Column("cancelledAt") == nil)
        }

        // Incomplete first (NULL `completedAt` ranked highest), pinned floated
        // to the top within that, then dueAt / sortOrder. Done/cancelled fall
        // to the bottom, newest-first.
        return try request
            .order(sql: """
                completedAt IS NULL DESC,
                isPinned DESC,
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
            // bm25 returns negative values; more-negative = better match, so ASC = best first.
            sql += " ORDER BY bm25(tasks_fts) ASC LIMIT ?"
            return try TodoTask.fetchAll(database, sql: sql,
                                         arguments: [sanitized, limit])
        }
    }

    /// Thin wrapper kept for source-compatibility. Real logic lives in
    /// `FTSQuery.escape` so notes, tasks, and the universal transcripts
    /// search share the same escaper.
    static func ftsQuery(from raw: String) -> String { FTSQuery.escape(raw) }

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

    // MARK: - Cancel ("Won't do") + pin (TickTick parity)

    /// Marks a task cancelled ("Won't do"). Non-destructive; clears any pending
    /// completion so a task is never both at once.
    func cancelTask(id: String, at date: Date = Date()) throws {
        try db.write { database in
            guard var task = try TodoTask.fetchOne(database, key: id) else { return }
            task.cancelledAt = date
            task.completedAt = nil
            task.updatedAt = date
            try task.update(database)
        }
    }

    /// Reverses a cancellation, returning the task to its active list.
    func uncancelTask(id: String) throws {
        try db.write { database in
            guard var task = try TodoTask.fetchOne(database, key: id) else { return }
            task.cancelledAt = nil
            task.updatedAt = Date()
            try task.update(database)
        }
    }

    /// Sets the pin flag that floats a task to the top of its bucket.
    func setPinned(_ pinned: Bool, for id: String) throws {
        try db.write { database in
            guard var task = try TodoTask.fetchOne(database, key: id) else { return }
            task.isPinned = pinned
            task.updatedAt = Date()
            try task.update(database)
        }
    }

    // MARK: - Batch operations (multi-select)

    /// Completes a set of tasks in one transaction (recurring tasks advance).
    /// Returns the number transitioned.
    @discardableResult
    func completeTasks(ids: [String], at date: Date = Date()) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try db.write { database in
            var changed = 0
            for id in ids {
                guard var task = try TodoTask.fetchOne(database, key: id) else { continue }
                try TaskCompletion(taskId: id, completedAt: date).insert(database)
                if let ruleStr = task.recurrenceRule, let due = task.dueAt {
                    let rule = try RecurrenceRule.parse(ruleStr)
                    task.dueAt = RecurrenceEngine.nextDate(after: due, rule: rule, calendar: .current)
                    task.completedAt = nil
                } else {
                    task.completedAt = date
                    task.cancelledAt = nil
                }
                task.updatedAt = date
                try task.update(database)
                changed += 1
            }
            return changed
        }
    }

    /// Deletes a set of tasks in one transaction. Returns the number deleted.
    @discardableResult
    func deleteTasks(ids: [String]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try db.write { database in
            let count = try TodoTask.deleteAll(database, keys: ids)
            for id in ids { try Self.recordTombstone(database, id: id) }
            return count
        }
    }

    // MARK: - CloudKit sync support
    //
    // Backs `TaskSyncCoordinator`. Tombstones (the `task_tombstones` table)
    // let deletes propagate: a deleted row is otherwise indistinguishable from
    // one that never existed. See SyncMergePolicy / SyncReconciler.

    private static func recordTombstone(_ db: Database, id: String, at date: Date = Date()) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO task_tombstones (id, deletedAt) VALUES (?, ?)",
            arguments: [id, date]
        )
    }

    /// Local sync state for every id the engine should consider: live tasks
    /// (not deleted) plus tombstones (deleted). A tombstone overrides a live
    /// row for the same id (shouldn't co-occur, but tombstone wins if so).
    func localTaskSides() throws -> [String: SyncMergePolicy.Side] {
        try db.read { database in
            var sides: [String: SyncMergePolicy.Side] = [:]
            for task in try TodoTask.fetchAll(database) {
                sides[task.id] = SyncMergePolicy.Side(updatedAt: task.updatedAt, isDeleted: false)
            }
            let rows = try Row.fetchAll(database, sql: "SELECT id, deletedAt FROM task_tombstones")
            for row in rows {
                let id: String = row["id"]
                let deletedAt: Date = row["deletedAt"]
                sides[id] = SyncMergePolicy.Side(updatedAt: deletedAt, isDeleted: true)
            }
            return sides
        }
    }

    /// Fetches the live tasks for the given ids (for pushing upserts).
    func tasks(forIDs ids: [String]) throws -> [TodoTask] {
        guard !ids.isEmpty else { return [] }
        return try db.read { try TodoTask.fetchAll($0, keys: ids) }
    }

    /// Applies a remote upsert: writes the task verbatim — preserving its
    /// remote `updatedAt` (does NOT bump it, unlike `updateTask`) — and clears
    /// any local tombstone for the id.
    func upsertFromSync(_ task: TodoTask) throws {
        try db.write { database in
            try task.save(database)
            try database.execute(sql: "DELETE FROM task_tombstones WHERE id = ?", arguments: [task.id])
        }
    }

    /// Applies a remote delete: removes the local row. No tombstone is written
    /// — the deletion originated remotely, so there's nothing to re-push.
    func applyRemoteDelete(id: String) throws {
        try db.write { database in
            _ = try TodoTask.deleteOne(database, key: id)
            try database.execute(sql: "DELETE FROM task_tombstones WHERE id = ?", arguments: [id])
        }
    }

    /// Moves a set of tasks to a project (or Inbox), each appended at the
    /// bottom of the destination in input order.
    func moveTasks(ids: [String], toProject projectId: String?) throws {
        guard !ids.isEmpty else { return }
        try db.write { database in
            var nextOrder = (try Int.fetchOne(database,
                sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM tasks WHERE projectId IS ?",
                arguments: [projectId])) ?? 0
            for id in ids {
                guard var task = try TodoTask.fetchOne(database, key: id) else { continue }
                task.projectId = projectId
                task.sortOrder = nextOrder
                task.updatedAt = Date()
                try task.update(database)
                nextOrder += 1
            }
        }
    }

    /// Reschedules a set of tasks to `date` (or clears the due date when nil).
    func rescheduleTasks(ids: [String], to date: Date?) throws {
        guard !ids.isEmpty else { return }
        try db.write { database in
            for id in ids {
                guard var task = try TodoTask.fetchOne(database, key: id) else { continue }
                task.dueAt = date
                task.updatedAt = Date()
                try task.update(database)
            }
        }
    }

    /// Sets the priority on a set of tasks.
    func setPriority(_ priority: TodoTask.Priority?, forTasks ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.write { database in
            for id in ids {
                guard var task = try TodoTask.fetchOne(database, key: id) else { continue }
                task.priority = priority
                task.updatedAt = Date()
                try task.update(database)
            }
        }
    }

    // MARK: - Subtasks / checklist (TickTick parity)

    /// Fetches a task's checklist ordered by `sortOrder` then `createdAt`.
    func subtasks(for taskId: String) throws -> [TaskSubtask] {
        try db.read { try Self.subtasks($0, for: taskId) }
    }

    fileprivate static func subtasks(_ database: Database, for taskId: String) throws -> [TaskSubtask] {
        try TaskSubtask
            .filter(Column("taskId") == taskId)
            .order(Column("sortOrder").asc, Column("createdAt").asc)
            .fetchAll(database)
    }

    /// Appends a checklist item to a task. The new item lands at the bottom.
    @discardableResult
    func addSubtask(to taskId: String, title: String) throws -> TaskSubtask {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return try db.write { database in
            let nextOrder = try Int.fetchOne(database,
                sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM task_subtasks WHERE taskId = ?",
                arguments: [taskId]) ?? 0
            let subtask = TaskSubtask(taskId: taskId, title: trimmed, sortOrder: nextOrder)
            try subtask.insert(database)
            return subtask
        }
    }

    /// Renames a checklist item.
    func renameSubtask(id: String, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try db.write { database in
            try database.execute(
                sql: "UPDATE task_subtasks SET title = ? WHERE id = ?",
                arguments: [trimmed, id])
        }
    }

    /// Sets a checklist item's completed flag.
    func setSubtaskCompleted(id: String, isCompleted: Bool) throws {
        try db.write { database in
            try database.execute(
                sql: "UPDATE task_subtasks SET isCompleted = ? WHERE id = ?",
                arguments: [isCompleted, id])
        }
    }

    func deleteSubtask(id: String) throws {
        try db.write { _ = try TaskSubtask.deleteOne($0, key: id) }
    }

    /// Persists a new manual ordering for a task's checklist. Ids not belonging
    /// to `taskId` are skipped so scopes stay independent.
    func reorderSubtasks(_ orderedIds: [String], in taskId: String) throws {
        try db.write { database in
            for (index, id) in orderedIds.enumerated() {
                try database.execute(
                    sql: "UPDATE task_subtasks SET sortOrder = ? WHERE id = ? AND taskId = ?",
                    arguments: [index, id, taskId])
            }
        }
    }

    /// Emits a task's checklist whenever the `task_subtasks` table changes.
    func observeSubtasks(taskId: String) -> DatabasePublishers.Value<[TaskSubtask]> {
        let observation = ValueObservation.tracking { database -> [TaskSubtask] in
            try Self.subtasks(database, for: taskId)
        }
        return observation.publisher(in: db, scheduling: .async(onQueue: .main))
    }

    /// Batch progress chips for a set of tasks: keyed by task id, only includes
    /// tasks that actually have subtasks. Single grouped query (no N+1).
    func subtaskProgress(for ids: [String]) throws -> [String: SubtaskProgress] {
        guard !ids.isEmpty else { return [:] }
        return try db.read { database in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(database, sql: """
                SELECT taskId,
                       COUNT(*) AS total,
                       SUM(CASE WHEN isCompleted THEN 1 ELSE 0 END) AS completed
                FROM task_subtasks
                WHERE taskId IN (\(placeholders))
                GROUP BY taskId
                """, arguments: StatementArguments(ids))
            var out: [String: SubtaskProgress] = [:]
            for row in rows {
                let taskId: String = row["taskId"]
                let total: Int = row["total"]
                let completed: Int = row["completed"] ?? 0
                out[taskId] = SubtaskProgress(completed: completed, total: total)
            }
            return out
        }
    }
}

