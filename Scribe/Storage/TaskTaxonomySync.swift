import Foundation
import GRDB

// CloudKit sync for the task taxonomy: areas, projects, project headings and
// task tags. Portable (Foundation + GRDB only) — compiled into the iOS target
// too. The wire format lives in `Scribe/Sync/TaxonomyCloudRecord.swift`; the
// round is driven by `TaskSyncCoordinator`.
//
// Change tracking: every taxonomy row carries an `updatedAt` (migration
// `v27_taxonomy_sync`). `TaskStore` stamps it on each local edit; an AFTER
// INSERT trigger stamps rows inserted without one. Rows written from sync
// keep the remote timestamp, so last-writer-wins compares real edit times.
//
// Deletions leave tombstones (`area_tombstones`, `project_tombstones`,
// `project_heading_tombstones`), mirroring `task_tombstones`.
//
// References that can't be resolved yet — a pulled task filed under a
// project this device hasn't received, a heading whose project hasn't
// arrived — are never dropped: the row is written with a safe fallback
// (task → Inbox, project → no area) and the intended target is kept in
// `taxonomy_sync_pending_refs` (or the heading in
// `taxonomy_sync_parked_headings`) until a later pull delivers it. Pushes send
// the intended reference, so the fallback never leaks to other devices.

// MARK: - Model

/// The taxonomy row types synced alongside tasks in the CloudKit 'Tasks' zone.
enum TaxonomySyncKind: String, CaseIterable, Sendable {
    case area
    case project
    case heading

    /// The live table.
    var tableName: String {
        switch self {
        case .area: return "areas"
        case .project: return "projects"
        case .heading: return "project_headings"
        }
    }

    /// The deletion tombstone table (same shape as `task_tombstones`).
    var tombstoneTableName: String {
        switch self {
        case .area: return "area_tombstones"
        case .project: return "project_tombstones"
        case .heading: return "project_heading_tombstones"
        }
    }

    /// The task / project column that references a row of this kind.
    var referenceField: String {
        switch self {
        case .area: return "areaId"
        case .project: return "projectId"
        case .heading: return "headingId"
        }
    }
}

/// One synced taxonomy row plus its last-modified time. The app's model
/// structs (`Project`, `TaskArea`, `ProjectHeading`) don't carry `updatedAt`
/// — it's a sync-only column — so sync pairs them here.
struct TaxonomySyncEntry<Item: Equatable>: Equatable {
    var item: Item
    var updatedAt: Date
}

/// Local last-writer-wins state per taxonomy kind: live rows (not deleted),
/// tombstones (deleted) and parked headings (live, waiting for a project).
struct TaxonomySyncSides: Equatable {
    var areas: [String: SyncMergePolicy.Side] = [:]
    var projects: [String: SyncMergePolicy.Side] = [:]
    var headings: [String: SyncMergePolicy.Side] = [:]

    func sides(for kind: TaxonomySyncKind) -> [String: SyncMergePolicy.Side] {
        switch kind {
        case .area: return areas
        case .project: return projects
        case .heading: return headings
        }
    }
}

/// What this device holds for sync, for the status rows in Settings.
struct TaxonomySyncCounts: Equatable, Sendable {
    var tasks = 0
    var projects = 0
    var areas = 0
    var headings = 0
    /// Tasks shown in Inbox because the project they're filed under hasn't
    /// reached this device yet.
    var tasksAwaitingProject = 0
    /// Every reference still waiting for its target (task / project links
    /// plus headings waiting for their project).
    var waitingReferences = 0

    /// "12 tasks · 3 projects · 2 areas · 4 headings".
    var summaryText: String {
        [
            Self.counted(tasks, "task", "tasks"),
            Self.counted(projects, "project", "projects"),
            Self.counted(areas, "area", "areas"),
            Self.counted(headings, "heading", "headings")
        ].joined(separator: " · ")
    }

    /// A short note about references still waiting, or nil when none are.
    var waitingText: String? {
        guard waitingReferences > 0 else { return nil }
        if tasksAwaitingProject > 0 {
            return "\(Self.counted(tasksAwaitingProject, "task", "tasks")) in Inbox until \(tasksAwaitingProject == 1 ? "its" : "their") project syncs"
        }
        return "\(Self.counted(waitingReferences, "item", "items")) waiting for related items to sync"
    }

    static func counted(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(n == 1 ? singular : plural)"
    }
}

// MARK: - Migration

extension DatabaseManager {

    /// Sentinel default for the new `updatedAt` columns; the AFTER INSERT
    /// triggers replace it with the insert time.
    static let taxonomyUnsetTimestamp = "1970-01-01 00:00:00.000"

    /// Registers `v27_taxonomy_sync`: `updatedAt` on areas / projects /
    /// headings (existing rows stamped with the migration time so the first
    /// round uploads them), insert-stamping triggers, tombstone tables, and
    /// the pending-reference tables. Additive only.
    static func registerTaxonomySyncMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v27_taxonomy_sync") { db in
            let now = Date()
            for kind in TaxonomySyncKind.allCases {
                let table = kind.tableName
                try db.execute(sql: """
                    ALTER TABLE \(table) ADD COLUMN updatedAt DATETIME NOT NULL \
                    DEFAULT '\(DatabaseManager.taxonomyUnsetTimestamp)'
                    """)
                try db.execute(sql: "UPDATE \(table) SET updatedAt = ?", arguments: [now])
                // Same text format GRDB uses for `Date` ("yyyy-MM-dd HH:mm:ss.SSS", UTC).
                try db.execute(sql: """
                    CREATE TRIGGER \(table)_sync_stamp_insert AFTER INSERT ON \(table)
                    FOR EACH ROW WHEN NEW.updatedAt <= '\(DatabaseManager.taxonomyUnsetTimestamp)'
                    BEGIN
                        UPDATE \(table) SET updatedAt = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE id = NEW.id;
                    END
                    """)
                try db.create(table: kind.tombstoneTableName) { t in
                    t.column("id", .text).primaryKey()
                    t.column("deletedAt", .datetime).notNull()
                }
            }
            // A reference from a task / project to a row that hasn't arrived.
            try db.create(table: "taxonomy_sync_pending_refs") { t in
                t.column("ownerType", .text).notNull()   // "task" | "project"
                t.column("ownerId", .text).notNull()
                t.column("field", .text).notNull()       // "projectId" | "areaId" | "headingId"
                t.column("targetId", .text).notNull()
                t.primaryKey(["ownerType", "ownerId", "field"])
            }
            try db.create(index: "taxonomy_sync_pending_refs_target_idx",
                          on: "taxonomy_sync_pending_refs",
                          columns: ["targetId"])
            // A pulled heading whose project isn't on this device yet (the
            // live table's NOT NULL foreign key can't hold it).
            try db.create(table: "taxonomy_sync_parked_headings") { t in
                t.column("id", .text).primaryKey()
                t.column("projectId", .text).notNull()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("updatedAt", .datetime).notNull()
            }
        }
    }
}

// MARK: - Local sync operations

/// Local side of taxonomy sync, abstracted for tests. `TaskStore` conforms.
protocol LocalTaxonomySyncing {
    func localTaxonomySides() throws -> TaxonomySyncSides
    func areasForSyncPush(ids: [String]) throws -> [TaxonomySyncEntry<TaskArea>]
    func projectsForSyncPush(ids: [String]) throws -> [TaxonomySyncEntry<Project>]
    func headingsForSyncPush(ids: [String]) throws -> [TaxonomySyncEntry<ProjectHeading>]
    /// Live tasks for a push, with references still waiting locally restored
    /// to the values the task was synced with.
    func tasksForSyncPush(ids: [String]) throws -> [TodoTask]
    /// Normalized, sorted tags for every requested task (empty when none).
    func tagsForSyncPush(taskIDs: [String]) throws -> [String: [String]]
    func applyRemoteArea(_ entry: TaxonomySyncEntry<TaskArea>) throws
    func applyRemoteProject(_ entry: TaxonomySyncEntry<Project>) throws
    func applyRemoteHeading(_ entry: TaxonomySyncEntry<ProjectHeading>) throws
    /// Writes a pulled task. `tags` nil = the record predates tag sync: keep
    /// local tags, and keep local area / heading links it can't speak for.
    func applyRemoteTask(_ task: TodoTask, tags: [String]?) throws
    /// Same task version on both sides (equal `updatedAt`): union the tags.
    func mergeRemoteTagsOnTie(taskID: String, tags: [String]) throws
    func applyRemoteTaxonomyDelete(_ kind: TaxonomySyncKind, id: String) throws
    /// Resolves waiting references whose targets have arrived. Returns how
    /// many were applied.
    @discardableResult
    func resolvePendingTaxonomyReferences() throws -> Int
    func taxonomySyncCounts() throws -> TaxonomySyncCounts
}

extension TaskStore: LocalTaxonomySyncing {

    // MARK: Sides

    func localTaxonomySides() throws -> TaxonomySyncSides {
        try db.read { database in
            var sides = TaxonomySyncSides()
            sides.areas = try Self.syncSides(database, kind: .area)
            sides.projects = try Self.syncSides(database, kind: .project)
            var headings = try Self.syncSides(database, kind: .heading)
            let parked = try Row.fetchAll(database, sql: "SELECT id, updatedAt FROM taxonomy_sync_parked_headings")
            for row in parked {
                let id: String = row["id"]
                let updatedAt: Date = row["updatedAt"]
                if headings[id] == nil {
                    headings[id] = SyncMergePolicy.Side(updatedAt: updatedAt, isDeleted: false)
                }
            }
            sides.headings = headings
            return sides
        }
    }

    fileprivate static func syncSides(_ database: Database, kind: TaxonomySyncKind) throws -> [String: SyncMergePolicy.Side] {
        var sides: [String: SyncMergePolicy.Side] = [:]
        for row in try Row.fetchAll(database, sql: "SELECT id, updatedAt FROM \(kind.tableName)") {
            let id: String = row["id"]
            let updatedAt: Date = row["updatedAt"]
            sides[id] = SyncMergePolicy.Side(updatedAt: updatedAt, isDeleted: false)
        }
        // A tombstone overrides a live row for the same id.
        for row in try Row.fetchAll(database, sql: "SELECT id, deletedAt FROM \(kind.tombstoneTableName)") {
            let id: String = row["id"]
            let deletedAt: Date = row["deletedAt"]
            sides[id] = SyncMergePolicy.Side(updatedAt: deletedAt, isDeleted: true)
        }
        return sides
    }

    // MARK: Push payloads

    func areasForSyncPush(ids: [String]) throws -> [TaxonomySyncEntry<TaskArea>] {
        guard !ids.isEmpty else { return [] }
        return try db.read { database in
            let stamps = try Self.updatedAtStamps(database, kind: .area, ids: ids)
            return try TaskArea.fetchAll(database, keys: ids).compactMap { area in
                stamps[area.id].map { TaxonomySyncEntry(item: area, updatedAt: $0) }
            }
        }
    }

    func projectsForSyncPush(ids: [String]) throws -> [TaxonomySyncEntry<Project>] {
        guard !ids.isEmpty else { return [] }
        return try db.read { database in
            let stamps = try Self.updatedAtStamps(database, kind: .project, ids: ids)
            let waiting = try Self.pendingRefs(database, ownerType: Self.pendingOwnerProject, ownerIDs: ids)
            return try Project.fetchAll(database, keys: ids).compactMap { (project: Project) -> TaxonomySyncEntry<Project>? in
                guard let stamp = stamps[project.id] else { return nil }
                var project = project
                if project.areaId == nil, let areaId = waiting[project.id]?["areaId"] {
                    project.areaId = areaId
                }
                return TaxonomySyncEntry(item: project, updatedAt: stamp)
            }
        }
    }

    func headingsForSyncPush(ids: [String]) throws -> [TaxonomySyncEntry<ProjectHeading>] {
        guard !ids.isEmpty else { return [] }
        return try db.read { database in
            let stamps = try Self.updatedAtStamps(database, kind: .heading, ids: ids)
            return try ProjectHeading.fetchAll(database, keys: ids).compactMap { heading in
                stamps[heading.id].map { TaxonomySyncEntry(item: heading, updatedAt: $0) }
            }
        }
    }

    func tasksForSyncPush(ids: [String]) throws -> [TodoTask] {
        guard !ids.isEmpty else { return [] }
        return try db.read { database in
            let waiting = try Self.pendingRefs(database, ownerType: Self.pendingOwnerTask, ownerIDs: ids)
            return try TodoTask.fetchAll(database, keys: ids).map { (task: TodoTask) -> TodoTask in
                guard let refs = waiting[task.id] else { return task }
                return Self.overlayingPendingRefs(refs, on: task)
            }
        }
    }

    /// Restores the references a task is still waiting for, under the same
    /// validity rules `resolvePendingTaxonomyReferences` uses (a local re-file
    /// since the pull wins over the waiting value).
    static func overlayingPendingRefs(_ refs: [String: String], on task: TodoTask) -> TodoTask {
        var task = task
        if task.projectId == nil, task.areaId == nil, let projectId = refs["projectId"] {
            task.projectId = projectId
        }
        if task.headingId == nil, task.projectId != nil, let headingId = refs["headingId"] {
            task.headingId = headingId
        }
        if task.areaId == nil, task.projectId == nil, let areaId = refs["areaId"] {
            task.areaId = areaId
        }
        return task
    }

    func tagsForSyncPush(taskIDs: [String]) throws -> [String: [String]] {
        guard !taskIDs.isEmpty else { return [:] }
        let found = try fetchTagsForTasks(taskIDs)
        var out: [String: [String]] = [:]
        for id in taskIDs {
            out[id] = Self.normalisedTagList(found[id] ?? []).sorted()
        }
        return out
    }

    fileprivate static func updatedAtStamps(_ database: Database, kind: TaxonomySyncKind, ids: [String]) throws -> [String: Date] {
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(database,
            sql: "SELECT id, updatedAt FROM \(kind.tableName) WHERE id IN (\(placeholders))",
            arguments: StatementArguments(ids))
        var out: [String: Date] = [:]
        for row in rows {
            let id: String = row["id"]
            let updatedAt: Date = row["updatedAt"]
            out[id] = updatedAt
        }
        return out
    }

    // MARK: Apply pulled rows

    func applyRemoteArea(_ entry: TaxonomySyncEntry<TaskArea>) throws {
        let area = entry.item
        try db.write { database in
            if try Self.rowExists(database, kind: .area, id: area.id) {
                try database.execute(
                    sql: "UPDATE areas SET name = ?, sortOrder = ?, symbol = ?, updatedAt = ? WHERE id = ?",
                    arguments: [area.name, area.sortOrder, area.symbol, entry.updatedAt, area.id])
            } else {
                try database.execute(
                    sql: "INSERT INTO areas (id, name, sortOrder, symbol, updatedAt) VALUES (?, ?, ?, ?, ?)",
                    arguments: [area.id, area.name, area.sortOrder, area.symbol, entry.updatedAt])
            }
            try Self.clearTombstone(database, kind: .area, id: area.id)
        }
    }

    func applyRemoteProject(_ entry: TaxonomySyncEntry<Project>) throws {
        try db.write { database in
            var project = entry.item
            var waitingArea: String?
            if let areaId = project.areaId, try !Self.rowExists(database, kind: .area, id: areaId) {
                project.areaId = nil
                if try !Self.isTombstoned(database, kind: .area, id: areaId) { waitingArea = areaId }
            }
            if try Self.rowExists(database, kind: .project, id: project.id) {
                try database.execute(sql: """
                    UPDATE projects SET name = ?, color = ?, icon = ?, createdAt = ?, sortOrder = ?,
                        areaId = ?, updatedAt = ?
                    WHERE id = ?
                    """, arguments: [project.name, project.color, project.icon, project.createdAt,
                                     project.sortOrder, project.areaId, entry.updatedAt, project.id])
            } else {
                try database.execute(sql: """
                    INSERT INTO projects (id, name, color, icon, createdAt, sortOrder, areaId, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [project.id, project.name, project.color, project.icon,
                                     project.createdAt, project.sortOrder, project.areaId, entry.updatedAt])
            }
            try Self.clearTombstone(database, kind: .project, id: project.id)
            try Self.setPendingRef(database, ownerType: Self.pendingOwnerProject, ownerId: project.id,
                                   field: "areaId", targetId: waitingArea)
        }
    }

    func applyRemoteHeading(_ entry: TaxonomySyncEntry<ProjectHeading>) throws {
        let heading = entry.item
        try db.write { database in
            if try Self.rowExists(database, kind: .project, id: heading.projectId) {
                try Self.writeLiveHeading(database, heading, updatedAt: entry.updatedAt)
            } else if try Self.isTombstoned(database, kind: .project, id: heading.projectId) {
                // Its project was deleted here: the heading went with it.
                try database.execute(sql: "DELETE FROM taxonomy_sync_parked_headings WHERE id = ?",
                                     arguments: [heading.id])
            } else {
                // Project not here yet: park until a later pull delivers it.
                try database.execute(sql: """
                    INSERT OR REPLACE INTO taxonomy_sync_parked_headings (id, projectId, title, sortOrder, updatedAt)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [heading.id, heading.projectId, heading.title, heading.sortOrder, entry.updatedAt])
            }
        }
    }

    fileprivate static func writeLiveHeading(_ database: Database, _ heading: ProjectHeading, updatedAt: Date) throws {
        if try rowExists(database, kind: .heading, id: heading.id) {
            try database.execute(
                sql: "UPDATE project_headings SET projectId = ?, title = ?, sortOrder = ?, updatedAt = ? WHERE id = ?",
                arguments: [heading.projectId, heading.title, heading.sortOrder, updatedAt, heading.id])
        } else {
            try database.execute(sql: """
                INSERT INTO project_headings (id, projectId, title, sortOrder, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [heading.id, heading.projectId, heading.title, heading.sortOrder, updatedAt])
        }
        try database.execute(sql: "DELETE FROM taxonomy_sync_parked_headings WHERE id = ?", arguments: [heading.id])
        try clearTombstone(database, kind: .heading, id: heading.id)
    }

    func applyRemoteTask(_ task: TodoTask, tags: [String]?) throws {
        try db.write { database in
            try Self.writeSyncedTask(database, task, tags: tags)
        }
    }

    /// Writes a pulled task verbatim — preserving its remote `updatedAt` —
    /// and clears any local tombstone for it.
    ///
    /// A reference to a row this device doesn't have falls back (project →
    /// Inbox, area / heading → none) and is remembered as pending, unless the
    /// target was deleted here (then the fallback is final). A record from a
    /// writer that predates taxonomy sync (`tags` nil) can't speak for area /
    /// heading links it never knew, so it doesn't wipe the local ones.
    fileprivate static func writeSyncedTask(_ database: Database, _ incoming: TodoTask, tags: [String]?) throws {
        var task = incoming
        let linksAuthoritative = tags != nil
        let existing = try TodoTask.fetchOne(database, key: task.id)
        var waitingProject: String?
        var waitingArea: String?
        var waitingHeading: String?

        if let projectId = task.projectId, try !rowExists(database, kind: .project, id: projectId) {
            task.projectId = nil
            if try !isTombstoned(database, kind: .project, id: projectId) { waitingProject = projectId }
        }

        // A task inside a project inherits the project's area.
        let filedInProject = task.projectId != nil || waitingProject != nil
        if filedInProject {
            task.areaId = nil
        } else if let areaId = task.areaId, try !rowExists(database, kind: .area, id: areaId) {
            task.areaId = nil
            if try !isTombstoned(database, kind: .area, id: areaId) { waitingArea = areaId }
        }
        if !linksAuthoritative, !filedInProject, task.areaId == nil,
           let localArea = existing?.areaId, try rowExists(database, kind: .area, id: localArea) {
            task.areaId = localArea
        }

        // A heading only lives inside its own project.
        if let headingId = task.headingId {
            if let heading = try ProjectHeading.fetchOne(database, key: headingId) {
                if heading.projectId != task.projectId { task.headingId = nil }
            } else {
                task.headingId = nil
                if filedInProject, try !isTombstoned(database, kind: .heading, id: headingId) {
                    waitingHeading = headingId
                }
            }
        }
        if !linksAuthoritative, task.headingId == nil, let projectId = task.projectId,
           let localHeading = existing?.headingId,
           let heading = try ProjectHeading.fetchOne(database, key: localHeading),
           heading.projectId == projectId {
            task.headingId = localHeading
        }

        try task.save(database)
        try database.execute(sql: "DELETE FROM task_tombstones WHERE id = ?", arguments: [task.id])
        try setPendingRef(database, ownerType: pendingOwnerTask, ownerId: task.id,
                          field: "projectId", targetId: waitingProject)
        try setPendingRef(database, ownerType: pendingOwnerTask, ownerId: task.id,
                          field: "areaId", targetId: task.areaId == nil ? waitingArea : nil)
        try setPendingRef(database, ownerType: pendingOwnerTask, ownerId: task.id,
                          field: "headingId", targetId: task.headingId == nil ? waitingHeading : nil)

        if let tags {
            try database.execute(sql: "DELETE FROM task_tags WHERE taskId = ?", arguments: [task.id])
            for tag in normalisedTagList(tags) {
                try TaskTagRow(taskId: task.id, tag: tag).insert(database)
            }
        }
    }

    func mergeRemoteTagsOnTie(taskID: String, tags: [String]) throws {
        try db.write { database in
            guard try TodoTask.fetchOne(database, key: taskID) != nil else { return }
            let local = Set(try String.fetchAll(database,
                sql: "SELECT tag FROM task_tags WHERE taskId = ?", arguments: [taskID]))
            let missing = Self.normalisedTagList(tags).filter { !local.contains($0) }
            guard !missing.isEmpty else { return }
            for tag in missing {
                try TaskTagRow(taskId: taskID, tag: tag).insert(database)
            }
            // The union is a new version: stamp it so it propagates back.
            try database.execute(sql: "UPDATE tasks SET updatedAt = ? WHERE id = ?", arguments: [Date(), taskID])
        }
    }

    // MARK: Apply pulled deletions

    /// Applies a remote delete. No tombstone is written (nothing to re-push);
    /// references waiting for the deleted row give up (their fallback stays).
    /// Foreign keys un-file this device's tasks / projects (no `updatedAt`
    /// bump: the deleting device pushes its own re-filed rows).
    func applyRemoteTaxonomyDelete(_ kind: TaxonomySyncKind, id: String) throws {
        try db.write { database in
            switch kind {
            case .area:
                try database.execute(sql: "DELETE FROM areas WHERE id = ?", arguments: [id])
            case .project:
                try database.execute(sql: "DELETE FROM taxonomy_sync_parked_headings WHERE projectId = ?", arguments: [id])
                try database.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [id])
            case .heading:
                try database.execute(sql: "DELETE FROM taxonomy_sync_parked_headings WHERE id = ?", arguments: [id])
                try database.execute(sql: "DELETE FROM project_headings WHERE id = ?", arguments: [id])
            }
            try Self.clearTombstone(database, kind: kind, id: id)
            try database.execute(
                sql: "DELETE FROM taxonomy_sync_pending_refs WHERE field = ? AND targetId = ?",
                arguments: [kind.referenceField, id])
        }
    }

    // MARK: Pending references

    static let pendingOwnerTask = "task"
    static let pendingOwnerProject = "project"

    @discardableResult
    func resolvePendingTaxonomyReferences() throws -> Int {
        try db.write { database in
            var resolved = 0

            // 1. Parked headings whose project has arrived (or was deleted).
            for row in try Row.fetchAll(database, sql: "SELECT * FROM taxonomy_sync_parked_headings") {
                let id: String = row["id"]
                let projectId: String = row["projectId"]
                let title: String = row["title"]
                let sortOrder: Int = row["sortOrder"]
                let updatedAt: Date = row["updatedAt"]
                let heading = ProjectHeading(id: id, projectId: projectId, title: title, sortOrder: sortOrder)
                if try Self.rowExists(database, kind: .project, id: heading.projectId) {
                    try Self.writeLiveHeading(database, heading, updatedAt: updatedAt)
                    resolved += 1
                } else if try Self.isTombstoned(database, kind: .project, id: heading.projectId) {
                    try database.execute(sql: "DELETE FROM taxonomy_sync_parked_headings WHERE id = ?",
                                         arguments: [heading.id])
                }
            }

            // 2. Project → area.
            for row in try Row.fetchAll(database, sql: """
                SELECT ownerId, targetId FROM taxonomy_sync_pending_refs
                WHERE ownerType = ? AND field = 'areaId'
                """, arguments: [Self.pendingOwnerProject]) {
                let projectId: String = row["ownerId"]
                let areaId: String = row["targetId"]
                guard let project = try Project.fetchOne(database, key: projectId), project.areaId == nil else {
                    try Self.setPendingRef(database, ownerType: Self.pendingOwnerProject, ownerId: projectId,
                                           field: "areaId", targetId: nil)
                    continue
                }
                if try Self.rowExists(database, kind: .area, id: areaId) {
                    // Restores the synced value: no updatedAt bump.
                    try database.execute(sql: "UPDATE projects SET areaId = ? WHERE id = ?",
                                         arguments: [areaId, projectId])
                    try Self.setPendingRef(database, ownerType: Self.pendingOwnerProject, ownerId: projectId,
                                           field: "areaId", targetId: nil)
                    resolved += 1
                } else if try Self.isTombstoned(database, kind: .area, id: areaId) {
                    try Self.setPendingRef(database, ownerType: Self.pendingOwnerProject, ownerId: projectId,
                                           field: "areaId", targetId: nil)
                }
            }

            // 3. Task → project, then heading, then area.
            let taskIDs = try String.fetchAll(database, sql: """
                SELECT DISTINCT ownerId FROM taxonomy_sync_pending_refs WHERE ownerType = ? ORDER BY ownerId
                """, arguments: [Self.pendingOwnerTask])
            let waitingByTask = try Self.pendingRefs(database, ownerType: Self.pendingOwnerTask, ownerIDs: taskIDs)
            for taskID in taskIDs {
                resolved += try Self.resolveTaskRefs(database, taskID: taskID, refs: waitingByTask[taskID] ?? [:])
            }
            return resolved
        }
    }

    /// Resolves (or gives up on) one task's waiting references. Writes only
    /// the link columns, never `updatedAt`: it restores the synced value.
    fileprivate static func resolveTaskRefs(_ database: Database, taskID: String, refs: [String: String]) throws -> Int {
        func drop(_ field: String) throws {
            try setPendingRef(database, ownerType: pendingOwnerTask, ownerId: taskID, field: field, targetId: nil)
        }
        guard var task = try TodoTask.fetchOne(database, key: taskID) else {
            try database.execute(sql: "DELETE FROM taxonomy_sync_pending_refs WHERE ownerType = ? AND ownerId = ?",
                                 arguments: [pendingOwnerTask, taskID])
            return 0
        }
        var resolved = 0
        var stillWaitingForProject = false

        if let projectId = refs["projectId"] {
            if task.projectId != nil || task.areaId != nil {
                try drop("projectId")              // re-filed locally since
            } else if try rowExists(database, kind: .project, id: projectId) {
                task.projectId = projectId
                task.areaId = nil
                try database.execute(sql: "UPDATE tasks SET projectId = ?, areaId = NULL WHERE id = ?",
                                     arguments: [projectId, taskID])
                try drop("projectId")
                resolved += 1
            } else if try isTombstoned(database, kind: .project, id: projectId) {
                try drop("projectId")              // project deleted: Inbox it is
            } else {
                stillWaitingForProject = true
            }
        }

        if let headingId = refs["headingId"] {
            if task.headingId != nil {
                try drop("headingId")
            } else if let heading = try ProjectHeading.fetchOne(database, key: headingId) {
                if heading.projectId == task.projectId {
                    try database.execute(sql: "UPDATE tasks SET headingId = ? WHERE id = ?",
                                         arguments: [headingId, taskID])
                    resolved += 1
                }
                try drop("headingId")
            } else if try isTombstoned(database, kind: .heading, id: headingId)
                        || (task.projectId == nil && !stillWaitingForProject) {
                try drop("headingId")
            }
        }

        if let areaId = refs["areaId"] {
            if task.areaId != nil || task.projectId != nil || stillWaitingForProject {
                try drop("areaId")
            } else if try rowExists(database, kind: .area, id: areaId) {
                try database.execute(sql: "UPDATE tasks SET areaId = ? WHERE id = ?", arguments: [areaId, taskID])
                try drop("areaId")
                resolved += 1
            } else if try isTombstoned(database, kind: .area, id: areaId) {
                try drop("areaId")
            }
        }
        return resolved
    }

    /// Waiting references keyed by owner id, then field.
    fileprivate static func pendingRefs(_ database: Database, ownerType: String, ownerIDs: [String]) throws -> [String: [String: String]] {
        guard !ownerIDs.isEmpty else { return [:] }
        let placeholders = ownerIDs.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(database, sql: """
            SELECT ownerId, field, targetId FROM taxonomy_sync_pending_refs
            WHERE ownerType = ? AND ownerId IN (\(placeholders))
            """, arguments: StatementArguments([ownerType] + ownerIDs))
        var out: [String: [String: String]] = [:]
        for row in rows {
            let owner: String = row["ownerId"]
            let field: String = row["field"]
            let target: String = row["targetId"]
            out[owner, default: [:]][field] = target
        }
        return out
    }

    /// Sets (or, with a nil target, clears) one waiting reference.
    fileprivate static func setPendingRef(_ database: Database, ownerType: String, ownerId: String,
                                          field: String, targetId: String?) throws {
        if let targetId {
            try database.execute(sql: """
                INSERT OR REPLACE INTO taxonomy_sync_pending_refs (ownerType, ownerId, field, targetId)
                VALUES (?, ?, ?, ?)
                """, arguments: [ownerType, ownerId, field, targetId])
        } else {
            try database.execute(sql: """
                DELETE FROM taxonomy_sync_pending_refs WHERE ownerType = ? AND ownerId = ? AND field = ?
                """, arguments: [ownerType, ownerId, field])
        }
    }

    /// Forgets every waiting reference of a task (the user re-filed it).
    static func clearPendingSyncRefs(_ database: Database, taskID: String) throws {
        try database.execute(sql: "DELETE FROM taxonomy_sync_pending_refs WHERE ownerType = ? AND ownerId = ?",
                             arguments: [pendingOwnerTask, taskID])
    }

    // MARK: Tombstones + small helpers

    /// Records a local deletion so the next push propagates it.
    static func recordTaxonomyTombstone(_ database: Database, kind: TaxonomySyncKind, id: String, at date: Date) throws {
        try database.execute(
            sql: "INSERT OR REPLACE INTO \(kind.tombstoneTableName) (id, deletedAt) VALUES (?, ?)",
            arguments: [id, date])
    }

    fileprivate static func clearTombstone(_ database: Database, kind: TaxonomySyncKind, id: String) throws {
        try database.execute(sql: "DELETE FROM \(kind.tombstoneTableName) WHERE id = ?", arguments: [id])
    }

    fileprivate static func rowExists(_ database: Database, kind: TaxonomySyncKind, id: String) throws -> Bool {
        try Bool.fetchOne(database,
            sql: "SELECT EXISTS(SELECT 1 FROM \(kind.tableName) WHERE id = ?)", arguments: [id]) ?? false
    }

    fileprivate static func isTombstoned(_ database: Database, kind: TaxonomySyncKind, id: String) throws -> Bool {
        try Bool.fetchOne(database,
            sql: "SELECT EXISTS(SELECT 1 FROM \(kind.tombstoneTableName) WHERE id = ?)", arguments: [id]) ?? false
    }

    // MARK: Counts

    func taxonomySyncCounts() throws -> TaxonomySyncCounts {
        try db.read { database in
            func count(_ sql: String, _ arguments: StatementArguments = StatementArguments()) throws -> Int {
                try Int.fetchOne(database, sql: sql, arguments: arguments) ?? 0
            }
            var counts = TaxonomySyncCounts()
            counts.tasks = try count("SELECT COUNT(*) FROM tasks")
            counts.projects = try count("SELECT COUNT(*) FROM projects")
            counts.areas = try count("SELECT COUNT(*) FROM areas")
            counts.headings = try count("SELECT COUNT(*) FROM project_headings")
            counts.tasksAwaitingProject = try count(
                "SELECT COUNT(*) FROM taxonomy_sync_pending_refs WHERE ownerType = ? AND field = 'projectId'",
                [Self.pendingOwnerTask])
            counts.waitingReferences = try count("SELECT COUNT(*) FROM taxonomy_sync_pending_refs")
                + count("SELECT COUNT(*) FROM taxonomy_sync_parked_headings")
            return counts
        }
    }
}
