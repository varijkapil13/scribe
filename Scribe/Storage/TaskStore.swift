import Foundation
import GRDB
import Combine

enum TaskStoreError: LocalizedError {
    case recurringTaskRequiresDueDate
    /// A synced task is filed under a project this device doesn't have
    /// (projects aren't synced yet); the upsert was skipped.
    case syncedTaskProjectMissing(String)

    var errorDescription: String? {
        switch self {
        case .recurringTaskRequiresDueDate:
            return "A recurring task must have a due date."
        case .syncedTaskProjectMissing:
            return "A synced task belongs to a project that isn't on this device."
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
        /// Active tasks parked in the Someday bucket.
        case someday
        /// Active tasks in an Area: filed directly under it, or in one of its
        /// projects.
        case area(String)
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

    // MARK: - Areas (v20)

    @discardableResult
    func createArea(name: String, symbol: String? = nil) throws -> TaskArea {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try db.write { database in
            let nextOrder = try Int.fetchOne(database,
                sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM areas") ?? 0
            let area = TaskArea(name: trimmed, sortOrder: nextOrder, symbol: symbol)
            try area.insert(database)
            return area
        }
    }

    func updateArea(_ area: TaskArea) throws {
        try db.write { try area.update($0) }
    }

    /// Deletes an area. Its projects and loose tasks stay, un-grouped (the
    /// FKs are `ON DELETE SET NULL`; cleared explicitly too so affected tasks
    /// get a fresh `updatedAt` for sync).
    func deleteArea(id: String) throws {
        try db.write { database in
            try database.execute(
                sql: "UPDATE tasks SET areaId = NULL, updatedAt = ? WHERE areaId = ?",
                arguments: [Date(), id])
            try database.execute(sql: "UPDATE projects SET areaId = NULL WHERE areaId = ?", arguments: [id])
            _ = try TaskArea.deleteOne(database, key: id)
        }
    }

    func fetchAreas() throws -> [TaskArea] {
        try db.read { try Self.fetchAreas($0) }
    }

    fileprivate static func fetchAreas(_ database: Database) throws -> [TaskArea] {
        try TaskArea
            .order(Column("sortOrder").asc, Column("name").asc)
            .fetchAll(database)
    }

    /// Persists a new manual ordering for the sidebar's Areas list.
    func reorderAreas(_ orderedIds: [String]) throws {
        try db.write { database in
            for (index, id) in orderedIds.enumerated() {
                try database.execute(sql: "UPDATE areas SET sortOrder = ? WHERE id = ?",
                                     arguments: [index, id])
            }
        }
    }

    /// Files a project under an area (or removes it from any area when nil).
    func setArea(_ areaId: String?, forProject projectId: String) throws {
        try db.write { database in
            try database.execute(sql: "UPDATE projects SET areaId = ? WHERE id = ?",
                                 arguments: [areaId, projectId])
        }
    }

    func observeAreas() -> DatabasePublishers.Value<[TaskArea]> {
        let observation = ValueObservation.tracking { database -> [TaskArea] in
            try Self.fetchAreas(database)
        }
        return observation.publisher(in: db, scheduling: .async(onQueue: .main))
    }

    // MARK: - Project headings (v20)

    @discardableResult
    func createHeading(in projectId: String, title: String) throws -> ProjectHeading {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return try db.write { database in
            let nextOrder = try Int.fetchOne(database,
                sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM project_headings WHERE projectId = ?",
                arguments: [projectId]) ?? 0
            let heading = ProjectHeading(projectId: projectId, title: trimmed, sortOrder: nextOrder)
            try heading.insert(database)
            return heading
        }
    }

    func renameHeading(id: String, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try db.write { database in
            try database.execute(sql: "UPDATE project_headings SET title = ? WHERE id = ?",
                                 arguments: [trimmed, id])
        }
    }

    /// Deletes a heading; its tasks stay in the project, un-headed.
    func deleteHeading(id: String) throws {
        try db.write { database in
            try database.execute(
                sql: "UPDATE tasks SET headingId = NULL, updatedAt = ? WHERE headingId = ?",
                arguments: [Date(), id])
            _ = try ProjectHeading.deleteOne(database, key: id)
        }
    }

    func headings(in projectId: String) throws -> [ProjectHeading] {
        try db.read { try Self.headings($0, in: projectId) }
    }

    fileprivate static func headings(_ database: Database, in projectId: String) throws -> [ProjectHeading] {
        try ProjectHeading
            .filter(Column("projectId") == projectId)
            .order(Column("sortOrder").asc, Column("title").asc)
            .fetchAll(database)
    }

    /// Persists a new heading order within one project. Ids belonging to a
    /// different project are skipped.
    func reorderHeadings(_ orderedIds: [String], in projectId: String) throws {
        try db.write { database in
            for (index, id) in orderedIds.enumerated() {
                try database.execute(
                    sql: "UPDATE project_headings SET sortOrder = ? WHERE id = ? AND projectId = ?",
                    arguments: [index, id, projectId])
            }
        }
    }

    /// Files a task under a heading (nil = no heading). Filing under a heading
    /// also moves the task into the heading's project.
    func setHeading(_ headingId: String?, forTask taskId: String) throws {
        try db.write { database in
            guard var task = try TodoTask.fetchOne(database, key: taskId) else { return }
            if let headingId {
                guard let heading = try ProjectHeading.fetchOne(database, key: headingId) else { return }
                if task.projectId != heading.projectId {
                    Self.applyProjectMove(&task, to: heading.projectId)
                }
                task.headingId = heading.id
            } else {
                task.headingId = nil
            }
            task.updatedAt = Date()
            try task.update(database)
        }
    }

    func observeHeadings(projectId: String) -> DatabasePublishers.Value<[ProjectHeading]> {
        let observation = ValueObservation.tracking { database -> [ProjectHeading] in
            try Self.headings(database, in: projectId)
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
        tags: [String] = [],
        startAt: Date? = nil,
        scheduleBucket: TaskScheduleBucket = .anytime,
        estimatedMinutes: Int? = nil,
        areaId: String? = nil,
        headingId: String? = nil
    ) throws -> TodoTask {
        try validateRecurrence(rule: recurrenceRule, dueAt: dueAt)
        return try db.write { database in
            let nextOrder = try Int.fetchOne(database,
                sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM tasks WHERE projectId IS ?",
                arguments: [projectId]) ?? 0

            // A heading only lives inside its own project.
            var validHeadingId: String? = nil
            if let headingId, let projectId,
               let heading = try ProjectHeading.fetchOne(database, key: headingId),
               heading.projectId == projectId {
                validHeadingId = heading.id
            }

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
                sourceActionItemId: sourceActionItemId,
                startAt: startAt,
                scheduleBucket: scheduleBucket,
                estimatedMinutes: estimatedMinutes.map { max(0, $0) },
                // A task inside a project inherits the project's area.
                areaId: projectId == nil ? areaId : nil,
                headingId: validHeadingId
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
            Self.applyProjectMove(&task, to: projectId)
            task.sortOrder = nextOrder
            task.updatedAt = Date()
            try task.update(database)
        }
    }

    /// Re-files a task under `projectId`, keeping the planning links
    /// consistent: a heading only lives inside its own project, and a task in
    /// a project inherits the project's area instead of its own.
    fileprivate static func applyProjectMove(_ task: inout TodoTask, to projectId: String?) {
        if task.projectId != projectId { task.headingId = nil }
        task.projectId = projectId
        if projectId != nil { task.areaId = nil }
    }

    /// Marks a task complete. For recurring tasks, advances `dueAt` to the
    /// next occurrence and clears `completedAt`; for one-off tasks, sets
    /// `completedAt`. Either way a `task_completions` history row is written.
    func completeTask(id: String, at date: Date = Date()) throws {
        try db.write { database in
            guard let task = try TodoTask.fetchOne(database, key: id) else { return }
            try TaskCompletion(taskId: id, completedAt: date).insert(database)
            // Advance in the user's local calendar: dueAt carries local
            // wall-clock semantics, so weekday/month extraction and DST
            // handling must use Calendar.current, not UTC.
            let completed = try Self.completing(task, at: date, calendar: .current)
            try completed.update(database)
        }
    }

    /// Pure completion transition (no I/O). For a recurring task whose series
    /// continues, advances `dueAt` to the next occurrence (honouring
    /// X-SCRIBE-FROM=COMPLETION, UNTIL and COUNT — COUNT is decremented in the
    /// stored rule), shifts any `startAt` by the same number of calendar days
    /// so the defer offset is kept, drops an explicit Today plan, and leaves
    /// the task open. Otherwise — one-off, or the series just ended — marks it
    /// completed. Completion always clears a cancellation.
    static func completing(_ task: TodoTask, at date: Date, calendar: Calendar) throws -> TodoTask {
        var task = task
        task.updatedAt = date
        task.cancelledAt = nil
        guard let ruleStr = task.recurrenceRule, let due = task.dueAt else {
            task.completedAt = date
            return task
        }
        let rule = try RecurrenceRule.parse(ruleStr)
        guard let step = RecurrenceEngine.nextOccurrence(dueAt: due, completedAt: date,
                                                         rule: rule, calendar: calendar) else {
            // Series ended (COUNT exhausted / past UNTIL): complete for good.
            task.completedAt = date
            return task
        }
        if let start = task.startAt {
            let dayShift = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: due),
                to: calendar.startOfDay(for: step.dueAt)
            ).day ?? 0
            task.startAt = calendar.date(byAdding: .day, value: dayShift, to: start) ?? start
        }
        task.dueAt = step.dueAt
        // Only rewrite the stored rule when its state changed (COUNT), so a
        // rule written by another tool keeps its original spelling.
        if step.rule.count != rule.count { task.recurrenceRule = step.rule.rruleString }
        if task.scheduleBucket == .today { task.scheduleBucket = .anytime }
        task.completedAt = nil
        return task
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
            // Someday tasks have been triaged (parked), so they leave the Inbox.
            request = request
                .filter(Column("projectId") == nil)
                .filter(Column("completedAt") == nil)
                .filter(Column("scheduleBucket") != TaskScheduleBucket.someday.rawValue)
        case .today:
            // Half-open window `dueAt < startOfTomorrow` includes overdue and
            // every dueAt today regardless of sub-second precision. Mirrors
            // `TaskPlanningRules.isInToday`: not deferred (startAt before
            // tomorrow), and either due by today, explicitly planned for
            // Today, or an undated This-Evening task.
            let startOfTomorrow = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!)
            let available = Column("startAt") == nil || Column("startAt") < startOfTomorrow
            let dueByToday = Column("dueAt") != nil && Column("dueAt") < startOfTomorrow
            let plannedToday = Column("scheduleBucket") == TaskScheduleBucket.today.rawValue
            let undatedEvening = Column("scheduleBucket") == TaskScheduleBucket.evening.rawValue
                && Column("dueAt") == nil
            request = request
                .filter(Column("completedAt") == nil)
                .filter(available)
                .filter(dueByToday || plannedToday || undatedEvening)
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
            // Tasks deferred to start inside the window (no due date needed)
            // are listed on their start day too — mirrors
            // `TaskPlanningRules.isInUpcoming`.
            let startOfTomorrow = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!)
            let endOfWindow = calendar.date(byAdding: .day, value: 7, to: startOfTomorrow)!
            let dueInWindow = Column("dueAt") != nil && Column("dueAt") < endOfWindow
            let startsInWindow = Column("startAt") != nil
                && Column("startAt") >= startOfTomorrow
                && Column("startAt") < endOfWindow
            request = request
                .filter(Column("completedAt") == nil)
                .filter(dueInWindow || startsInWindow)
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
        case .someday:
            request = request
                .filter(Column("completedAt") == nil)
                .filter(Column("scheduleBucket") == TaskScheduleBucket.someday.rawValue)
        case .area(let id):
            request = request
                .filter(Column("completedAt") == nil)
                .filter(sql: "(areaId = ? OR projectId IN (SELECT p.id FROM projects AS p WHERE p.areaId = ?))",
                        arguments: [id, id])
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
                guard let task = try TodoTask.fetchOne(database, key: id) else { continue }
                try TaskCompletion(taskId: id, completedAt: date).insert(database)
                let completed = try Self.completing(task, at: date, calendar: .current)
                try completed.update(database)
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
    ///
    /// Areas and headings are local-only (not synced), so an area / heading id
    /// written on another device may not exist here; those links are dropped
    /// rather than letting the foreign key abort the whole sync write.
    ///
    /// Because those ids only resolve on the device that created them, a
    /// remote record without a usable link (written by a device that never
    /// knew the area / heading) must not wipe the local one: the existing
    /// local link is kept when it's still consistent with the incoming
    /// `projectId` (an area only for project-less tasks; a heading only inside
    /// its own project).
    ///
    /// Projects are local too: a task filed under a project missing here
    /// throws `TaskStoreError.syncedTaskProjectMissing` without writing, so
    /// the coordinator can skip it instead of the foreign key aborting the
    /// round (and without un-filing the task for the devices that have it).
    func upsertFromSync(_ task: TodoTask) throws {
        try db.write { database in
            var task = task
            if let projectId = task.projectId, try Project.fetchOne(database, key: projectId) == nil {
                throw TaskStoreError.syncedTaskProjectMissing(projectId)
            }
            let existing = try TodoTask.fetchOne(database, key: task.id)

            if let areaId = task.areaId, try TaskArea.fetchOne(database, key: areaId) == nil {
                task.areaId = nil
            }
            if task.projectId != nil { task.areaId = nil }
            if task.areaId == nil, task.projectId == nil,
               let localArea = existing?.areaId,
               try TaskArea.fetchOne(database, key: localArea) != nil {
                task.areaId = localArea
            }

            if let headingId = task.headingId {
                let heading = try ProjectHeading.fetchOne(database, key: headingId)
                if heading == nil || heading?.projectId != task.projectId { task.headingId = nil }
            }
            if task.headingId == nil, let projectId = task.projectId,
               let localHeading = existing?.headingId,
               let heading = try ProjectHeading.fetchOne(database, key: localHeading),
               heading.projectId == projectId {
                task.headingId = localHeading
            }

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
                Self.applyProjectMove(&task, to: projectId)
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

