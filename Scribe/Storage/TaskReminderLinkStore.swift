import Foundation
import GRDB

/// One Scribe task ↔ Apple Reminders reminder pairing (the `task_reminder_links`
/// table, migration `v21_reminders_link`).
///
/// The row deliberately has NO foreign key to `tasks`: it must outlive a
/// deleted task, because "the link exists but the task vanished" is exactly how
/// the Reminders sync knows a task was deleted in Scribe (and may delete the
/// paired reminder). Likewise a reminder that vanished from Reminders is only
/// ever propagated as a delete when its link row exists.
///
/// Portable (GRDB + Foundation only) — compiled into the iOS target too.
struct TaskReminderLink: Codable, Equatable, Hashable, Sendable {
    /// Scribe task id (primary key: a task pairs with at most one reminder).
    var taskId: String
    /// `EKCalendarItem.calendarItemIdentifier` (unique: a reminder pairs with
    /// at most one task).
    var calendarItemIdentifier: String
    /// `EKCalendarItem.calendarItemExternalIdentifier`, used to re-find the
    /// reminder when its local identifier changes (e.g. after a full re-sync
    /// of the Reminders account).
    var externalIdentifier: String?
    /// The task's `updatedAt` when the pair was last reconciled.
    var lastSyncedTaskUpdatedAt: Date?
    /// The reminder's `lastModifiedDate` when the pair was last reconciled.
    var lastSyncedReminderModifiedAt: Date?

    init(
        taskId: String,
        calendarItemIdentifier: String,
        externalIdentifier: String? = nil,
        lastSyncedTaskUpdatedAt: Date? = nil,
        lastSyncedReminderModifiedAt: Date? = nil
    ) {
        self.taskId = taskId
        self.calendarItemIdentifier = calendarItemIdentifier
        self.externalIdentifier = externalIdentifier
        self.lastSyncedTaskUpdatedAt = lastSyncedTaskUpdatedAt
        self.lastSyncedReminderModifiedAt = lastSyncedReminderModifiedAt
    }
}

extension TaskReminderLink: FetchableRecord, PersistableRecord {
    static let databaseTableName = "task_reminder_links"
}

// MARK: - Migration

extension DatabaseManager {

    /// Registers `v21_reminders_link`. Self-contained and additive: a brand-new
    /// table plus a unique index; never touches existing tables. Called from
    /// `makeMigrator()` after every earlier migration.
    static func registerRemindersLinkMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v21_reminders_link") { db in
            try db.create(table: "task_reminder_links") { t in
                t.column("taskId", .text).notNull().primaryKey()
                t.column("calendarItemIdentifier", .text).notNull()
                t.column("externalIdentifier", .text)
                t.column("lastSyncedTaskUpdatedAt", .datetime)
                t.column("lastSyncedReminderModifiedAt", .datetime)
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX task_reminder_links_calendarItem_idx
                ON task_reminder_links (calendarItemIdentifier)
                """)
        }
    }
}

// MARK: - Store

/// Reads/writes `task_reminder_links` and supplies the task snapshot the
/// Reminders sync plans against.
final class TaskReminderLinkStore: Sendable {

    private let dbManager: DatabaseManager

    private var db: DatabaseQueue { dbManager.database }

    init(databaseManager: DatabaseManager) {
        self.dbManager = databaseManager
    }

    /// Every link, ordered by task id (deterministic planning order).
    func fetchAllLinks() throws -> [TaskReminderLink] {
        try db.read { database in
            try TaskReminderLink.order(Column("taskId")).fetchAll(database)
        }
    }

    func link(forTaskId taskId: String) throws -> TaskReminderLink? {
        try db.read { try TaskReminderLink.fetchOne($0, key: taskId) }
    }

    /// Inserts or replaces the link for `link.taskId`. Any other row claiming
    /// the same reminder is removed first so the unique index never trips
    /// (a reminder pairs with at most one task).
    func upsert(_ link: TaskReminderLink) throws {
        try db.write { database in
            try database.execute(
                sql: "DELETE FROM task_reminder_links WHERE calendarItemIdentifier = ? AND taskId != ?",
                arguments: [link.calendarItemIdentifier, link.taskId]
            )
            try link.save(database)
        }
    }

    func deleteLink(taskId: String) throws {
        try db.write { database in
            _ = try TaskReminderLink.deleteOne(database, key: taskId)
        }
    }

    /// Forgets every pairing (used when the user resets the Reminders sync).
    func deleteAllLinks() throws {
        try db.write { database in
            _ = try TaskReminderLink.deleteAll(database)
        }
    }

    /// Every task row — completed and cancelled included — for planning.
    func fetchAllTasks() throws -> [TodoTask] {
        try db.read { database in
            try TodoTask.order(Column("createdAt"), Column("id")).fetchAll(database)
        }
    }
}
