import Foundation
import GRDB

/// One scheduled task ↔ the calendar event Scribe created to mirror its time
/// block (the `task_calendar_blocks` table, migration
/// `v26_task_calendar_blocks`).
///
/// This table is the ONLY way Scribe knows an event is its own: the time-
/// blocking mirror never updates or deletes an event whose identifier isn't
/// recorded here. Like `task_reminder_links`, the row has no foreign key to
/// `tasks` — it must outlive a deleted task so the mirror can remove the
/// task's event.
///
/// Portable (GRDB + Foundation only) — compiled into the iOS target too.
struct TaskCalendarBlockLink: Codable, Equatable, Hashable, Sendable {
    /// Scribe task id (primary key: a task has at most one block).
    var taskId: String
    /// `EKEvent.eventIdentifier` of the mirrored event (unique).
    var eventIdentifier: String
    /// `EKCalendar.calendarIdentifier` the event was written to.
    var calendarId: String
    /// What Scribe last wrote, so an unchanged task causes no write (and an
    /// edit made in Calendar survives until the task itself changes).
    var lastStart: Date
    var lastEnd: Date
    var lastTitle: String

    init(taskId: String, eventIdentifier: String, calendarId: String,
         lastStart: Date, lastEnd: Date, lastTitle: String) {
        self.taskId = taskId
        self.eventIdentifier = eventIdentifier
        self.calendarId = calendarId
        self.lastStart = lastStart
        self.lastEnd = lastEnd
        self.lastTitle = lastTitle
    }
}

extension TaskCalendarBlockLink: FetchableRecord, PersistableRecord {
    static let databaseTableName = "task_calendar_blocks"
}

// MARK: - Migration

extension DatabaseManager {

    /// Registers `v26_task_calendar_blocks`. Additive: one new table plus a
    /// unique index; never touches existing tables. Called from
    /// `makeMigrator()` after every earlier migration.
    static func registerTaskCalendarBlocksMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v26_task_calendar_blocks") { db in
            try db.create(table: "task_calendar_blocks") { t in
                t.column("taskId", .text).notNull().primaryKey()
                t.column("eventIdentifier", .text).notNull()
                t.column("calendarId", .text).notNull()
                t.column("lastStart", .datetime).notNull()
                t.column("lastEnd", .datetime).notNull()
                t.column("lastTitle", .text).notNull().defaults(to: "")
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX task_calendar_blocks_event_idx
                ON task_calendar_blocks (eventIdentifier)
                """)
        }
    }
}

// MARK: - Store

/// Reads/writes `task_calendar_blocks`.
final class TaskCalendarBlockLinkStore: Sendable {

    private let dbManager: DatabaseManager

    private var db: DatabaseQueue { dbManager.database }

    init(databaseManager: DatabaseManager) {
        self.dbManager = databaseManager
    }

    /// Every link, ordered by task id (deterministic planning order).
    func fetchAllLinks() throws -> [TaskCalendarBlockLink] {
        try db.read { database in
            try TaskCalendarBlockLink.order(Column("taskId")).fetchAll(database)
        }
    }

    func link(forTaskId taskId: String) throws -> TaskCalendarBlockLink? {
        try db.read { try TaskCalendarBlockLink.fetchOne($0, key: taskId) }
    }

    /// Identifiers of every event Scribe created (the planner hides these so
    /// a block isn't drawn twice).
    func mirroredEventIdentifiers() throws -> Set<String> {
        try db.read { database in
            Set(try String.fetchAll(database, sql: "SELECT eventIdentifier FROM task_calendar_blocks"))
        }
    }

    /// Inserts or replaces the link for `link.taskId`. Any other row claiming
    /// the same event is removed first so the unique index never trips.
    func upsert(_ link: TaskCalendarBlockLink) throws {
        try db.write { database in
            try database.execute(
                sql: "DELETE FROM task_calendar_blocks WHERE eventIdentifier = ? AND taskId != ?",
                arguments: [link.eventIdentifier, link.taskId]
            )
            try link.save(database)
        }
    }

    func deleteLink(taskId: String) throws {
        try db.write { database in
            _ = try TaskCalendarBlockLink.deleteOne(database, key: taskId)
        }
    }

    /// Every task row — completed and cancelled included — for planning.
    func fetchAllTasks() throws -> [TodoTask] {
        try db.read { database in
            try TodoTask.order(Column("createdAt"), Column("id")).fetchAll(database)
        }
    }
}
