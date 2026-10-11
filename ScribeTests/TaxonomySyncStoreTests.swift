import XCTest
import GRDB
@testable import Scribe

/// The local half of taxonomy sync on a real (in-memory) database: the
/// `v27_taxonomy_sync` change tracking, tombstones, applying pulled rows,
/// pending references for out-of-order pulls, and tags.
final class TaxonomySyncStoreTests: XCTestCase {

    private var manager: DatabaseManager!
    private var store: TaskStore!

    private let old = Date(timeIntervalSince1970: 1_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t2 = Date(timeIntervalSince1970: 1_700_000_100)

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: ":memory:")
        store = TaskStore(databaseManager: manager)
    }

    override func tearDown() {
        store = nil
        manager = nil
    }

    // MARK: - Helpers

    /// Backdates every taxonomy row so a later stamp is unambiguous.
    private func backdateTaxonomy() throws {
        try manager.database.write { db in
            for kind in TaxonomySyncKind.allCases {
                try db.execute(sql: "UPDATE \(kind.tableName) SET updatedAt = ?", arguments: [old])
            }
            try db.execute(sql: "UPDATE tasks SET updatedAt = ?", arguments: [old])
        }
    }

    private func stamp(_ kind: TaxonomySyncKind, _ id: String) throws -> Date? {
        try store.localTaxonomySides().sides(for: kind)[id]?.updatedAt
    }

    private func isTombstoned(_ kind: TaxonomySyncKind, _ id: String) throws -> Bool {
        try store.localTaxonomySides().sides(for: kind)[id]?.isDeleted == true
    }

    private func remoteTask(_ id: String, projectId: String? = nil, areaId: String? = nil,
                            headingId: String? = nil, at date: Date) -> TodoTask {
        TodoTask(id: id, title: id, projectId: projectId, createdAt: date, updatedAt: date,
                 areaId: areaId, headingId: headingId)
    }

    // MARK: - Change tracking

    func testMigrationAddsUpdatedAtAndStampsNewRows() throws {
        let before = Date().addingTimeInterval(-5)
        let area = try store.createArea(name: "Home")
        let project = try store.createProject(name: "Kitchen")
        let heading = try store.createHeading(in: project.id, title: "Shopping")

        for (kind, id) in [(TaxonomySyncKind.area, area.id), (.project, project.id), (.heading, heading.id)] {
            let stamped = try XCTUnwrap(stamp(kind, id), "\(kind) row has a sync side")
            XCTAssertGreaterThan(stamped, before, "\(kind) insert is stamped, not left at the default")
        }
        let tables = try manager.database.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        for table in ["area_tombstones", "project_tombstones", "project_heading_tombstones",
                      "taxonomy_sync_pending_refs", "taxonomy_sync_parked_headings"] {
            XCTAssertTrue(tables.contains(table), table)
        }
    }

    func testMigrationStampsPreexistingRows() throws {
        let queue = try DatabaseQueue()
        let migrator = DatabaseManager.makeMigrator()
        try migrator.migrate(queue, upTo: "v20_task_planning")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO areas (id, name, sortOrder) VALUES ('a', 'A', 0)")
            try db.execute(sql: "INSERT INTO projects (id, name, createdAt, sortOrder, areaId) VALUES ('p', 'P', ?, 0, 'a')",
                           arguments: [old])
            try db.execute(sql: "INSERT INTO project_headings (id, projectId, title, sortOrder) VALUES ('h', 'p', 'H', 0)")
        }
        let before = Date().addingTimeInterval(-5)
        try migrator.migrate(queue)

        try queue.read { db in
            for kind in TaxonomySyncKind.allCases {
                let stamp = try XCTUnwrap(Date.fetchOne(db, sql: "SELECT updatedAt FROM \(kind.tableName)"))
                XCTAssertGreaterThan(stamp, before, "Existing \(kind) rows upload on the first round")
            }
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT areaId FROM projects"), "a", "Rows are kept as they were")
        }
    }

    func testLocalEditsStampUpdatedAt() throws {
        let area = try store.createArea(name: "Home")
        var project = try store.createProject(name: "Kitchen")
        let heading = try store.createHeading(in: project.id, title: "Shopping")
        try backdateTaxonomy()

        project.name = "Kitchen remodel"
        try store.updateProject(project)
        try store.renameHeading(id: heading.id, title: "Groceries")
        var renamed = area
        renamed.name = "House"
        try store.updateArea(renamed)

        XCTAssertGreaterThan(try XCTUnwrap(stamp(.project, project.id)), old)
        XCTAssertGreaterThan(try XCTUnwrap(stamp(.heading, heading.id)), old)
        XCTAssertGreaterThan(try XCTUnwrap(stamp(.area, area.id)), old)
    }

    func testReorderAndAreaFilingStampOnlyChangedRows() throws {
        let a = try store.createProject(name: "A")   // sortOrder 0
        let b = try store.createProject(name: "B")   // sortOrder 1
        let c = try store.createProject(name: "C")   // sortOrder 2
        let area = try store.createArea(name: "Work")
        try backdateTaxonomy()

        try store.reorderProjects([a.id, c.id, b.id])
        XCTAssertEqual(try stamp(.project, a.id), old, "Unmoved project keeps its stamp")
        XCTAssertGreaterThan(try XCTUnwrap(stamp(.project, b.id)), old)
        XCTAssertGreaterThan(try XCTUnwrap(stamp(.project, c.id)), old)

        try backdateTaxonomy()
        try store.setArea(area.id, forProject: a.id)
        try store.setArea(nil, forProject: b.id)   // already none: no change
        XCTAssertGreaterThan(try XCTUnwrap(stamp(.project, a.id)), old)
        XCTAssertEqual(try stamp(.project, b.id), old)
    }

    func testSetTagsStampsTheTaskOnlyWhenTagsChange() throws {
        let task = try store.createTask(title: "Tagged", tags: ["work"])
        try backdateTaxonomy()
        try store.setTags(["Work"], for: task.id)           // same after normalizing
        XCTAssertEqual(try XCTUnwrap(store.fetchTask(id: task.id)).updatedAt, old)
        try store.setTags(["work", "urgent"], for: task.id)
        XCTAssertGreaterThan(try XCTUnwrap(store.fetchTask(id: task.id)).updatedAt, old)
    }

    // MARK: - Local deletions

    func testDeletingAProjectTombstonesItAndItsHeadingsAndInboxesItsTasks() throws {
        let project = try store.createProject(name: "Doomed")
        let heading = try store.createHeading(in: project.id, title: "Phase")
        let task = try store.createTask(title: "Survivor", projectId: project.id, headingId: heading.id)
        try backdateTaxonomy()

        try store.deleteProject(id: project.id)

        XCTAssertTrue(try isTombstoned(.project, project.id))
        XCTAssertTrue(try isTombstoned(.heading, heading.id))
        let survivor = try XCTUnwrap(store.fetchTask(id: task.id), "Tasks are never lost with their project")
        XCTAssertNil(survivor.projectId)
        XCTAssertNil(survivor.headingId)
        XCTAssertGreaterThan(survivor.updatedAt, old, "The move to Inbox syncs")
    }

    func testDeletingAreasAndHeadingsTombstonesThem() throws {
        let area = try store.createArea(name: "Gone")
        let project = try store.createProject(name: "P")
        try store.setArea(area.id, forProject: project.id)
        let heading = try store.createHeading(in: project.id, title: "H")
        try backdateTaxonomy()

        try store.deleteArea(id: area.id)
        try store.deleteHeading(id: heading.id)

        XCTAssertTrue(try isTombstoned(.area, area.id))
        XCTAssertTrue(try isTombstoned(.heading, heading.id))
        XCTAssertGreaterThan(try XCTUnwrap(stamp(.project, project.id)), old, "Un-filed project syncs")
        XCTAssertNil(try store.fetchProjects().first?.areaId)
    }

    // MARK: - Applying pulled rows

    func testAppliedRowsKeepTheRemoteTimestampAndClearTombstones() throws {
        let area = try store.createArea(name: "Local")
        try store.deleteArea(id: area.id)
        XCTAssertTrue(try isTombstoned(.area, area.id))

        try store.applyRemoteArea(.init(item: TaskArea(id: area.id, name: "Restored", sortOrder: 4), updatedAt: t2))
        XCTAssertEqual(try store.fetchAreas().map(\.name), ["Restored"])
        XCTAssertEqual(try stamp(.area, area.id), t2)
        XCTAssertFalse(try isTombstoned(.area, area.id))

        try store.applyRemoteArea(.init(item: TaskArea(id: area.id, name: "Renamed", sortOrder: 4, symbol: "house"), updatedAt: t2.addingTimeInterval(1)))
        XCTAssertEqual(try store.fetchAreas().first?.symbol, "house")
    }

    func testProjectWaitsForItsAreaThenResolves() throws {
        let remote = Project(id: "p-1", name: "Remote", createdAt: t1, sortOrder: 0, areaId: "a-late")
        try store.applyRemoteProject(.init(item: remote, updatedAt: t1))

        XCTAssertNil(try store.fetchProjects().first?.areaId, "No area here yet")
        XCTAssertEqual(try store.projectsForSyncPush(ids: ["p-1"]).first?.item.areaId, "a-late",
                       "Pushes keep the intended area")

        try store.applyRemoteArea(.init(item: TaskArea(id: "a-late", name: "Late"), updatedAt: t1))
        XCTAssertEqual(try store.resolvePendingTaxonomyReferences(), 1)
        XCTAssertEqual(try store.fetchProjects().first?.areaId, "a-late")
        XCTAssertEqual(try stamp(.project, "p-1"), t1, "Resolving restores the synced value without a new stamp")
        XCTAssertEqual(try store.taxonomySyncCounts().waitingReferences, 0)
    }

    func testHeadingAndTaskWaitForTheirProject() throws {
        // Out of order: the task and its heading arrive before the project.
        try store.applyRemoteHeading(.init(item: ProjectHeading(id: "h-1", projectId: "p-1", title: "Phase 1"), updatedAt: t1))
        try store.applyRemoteTask(remoteTask("t-1", projectId: "p-1", headingId: "h-1", at: t1), tags: ["x"])

        let waiting = try XCTUnwrap(store.fetchTask(id: "t-1"))
        XCTAssertNil(waiting.projectId)
        XCTAssertNil(waiting.headingId)
        XCTAssertEqual(try store.tags(for: "t-1"), ["x"])
        XCTAssertEqual(try store.headings(in: "p-1"), [])
        let pushed = try XCTUnwrap(store.tasksForSyncPush(ids: ["t-1"]).first)
        XCTAssertEqual(pushed.projectId, "p-1")
        XCTAssertEqual(pushed.headingId, "h-1")
        let counts = try store.taxonomySyncCounts()
        XCTAssertEqual(counts.tasksAwaitingProject, 1)
        XCTAssertEqual(counts.waitingReferences, 3, "project + heading refs and the parked heading")
        XCTAssertEqual(try store.resolvePendingTaxonomyReferences(), 0, "Nothing to resolve yet")

        try store.applyRemoteProject(.init(item: Project(id: "p-1", name: "P", createdAt: t1), updatedAt: t1))
        XCTAssertEqual(try store.resolvePendingTaxonomyReferences(), 3)

        let resolved = try XCTUnwrap(store.fetchTask(id: "t-1"))
        XCTAssertEqual(resolved.projectId, "p-1")
        XCTAssertEqual(resolved.headingId, "h-1")
        XCTAssertEqual(resolved.updatedAt, t1)
        XCTAssertEqual(try store.headings(in: "p-1").map(\.title), ["Phase 1"])
        XCTAssertEqual(try store.taxonomySyncCounts().waitingReferences, 0)
    }

    func testTaskInADeletedProjectFallsBackToInboxForGood() throws {
        let project = try store.createProject(name: "Deleted here")
        try store.deleteProject(id: project.id)

        try store.applyRemoteTask(remoteTask("t-1", projectId: project.id, at: t2), tags: [])
        XCTAssertNil(try XCTUnwrap(store.fetchTask(id: "t-1")).projectId)
        XCTAssertEqual(try store.taxonomySyncCounts().waitingReferences, 0, "Nothing to wait for")
    }

    func testLocalRefileDropsAWaitingProject() throws {
        try store.applyRemoteTask(remoteTask("t-1", projectId: "p-never", at: t1), tags: [])
        let mine = try store.createProject(name: "Mine")
        try store.moveTask(id: "t-1", toProject: mine.id)
        try store.moveTask(id: "t-1", toProject: nil)

        XCTAssertNil(try store.tasksForSyncPush(ids: ["t-1"]).first?.projectId,
                     "The user's own move wins over the waiting project")
        XCTAssertEqual(try store.taxonomySyncCounts().tasksAwaitingProject, 0)
    }

    func testWaitingRefsGiveUpWhenTheTargetIsDeletedRemotely() throws {
        try store.applyRemoteTask(remoteTask("t-1", projectId: "p-1", at: t1), tags: [])
        try store.applyRemoteTaxonomyDelete(.project, id: "p-1")
        XCTAssertEqual(try store.taxonomySyncCounts().waitingReferences, 0)
        XCTAssertNil(try store.tasksForSyncPush(ids: ["t-1"]).first?.projectId)
    }

    // MARK: - Applying pulled deletions

    func testRemoteProjectDeleteInboxesTasksWithoutLosingThem() throws {
        let project = try store.createProject(name: "Shared")
        let heading = try store.createHeading(in: project.id, title: "H")
        let task = try store.createTask(title: "Keep me", projectId: project.id, headingId: heading.id)

        try store.applyRemoteTaxonomyDelete(.project, id: project.id)

        XCTAssertTrue(try store.fetchProjects().isEmpty)
        XCTAssertEqual(try store.headings(in: project.id), [])
        let kept = try XCTUnwrap(store.fetchTask(id: task.id))
        XCTAssertNil(kept.projectId)
        XCTAssertNil(kept.headingId)
        XCTAssertFalse(try isTombstoned(.project, project.id), "A remote delete isn't pushed back")
    }

    func testRemoteAreaAndHeadingDeletes() throws {
        let area = try store.createArea(name: "A")
        let task = try store.createTask(title: "Loose", areaId: area.id)
        let project = try store.createProject(name: "P")
        let heading = try store.createHeading(in: project.id, title: "H")

        try store.applyRemoteTaxonomyDelete(.area, id: area.id)
        try store.applyRemoteTaxonomyDelete(.heading, id: heading.id)

        XCTAssertTrue(try store.fetchAreas().isEmpty)
        XCTAssertEqual(try store.headings(in: project.id), [])
        XCTAssertNil(try XCTUnwrap(store.fetchTask(id: task.id)).areaId)
    }

    // MARK: - Tags

    func testRemoteTagsReplaceLocalTags() throws {
        let task = try store.createTask(title: "T", tags: ["old"])
        var remote = task
        remote.updatedAt = task.updatedAt.addingTimeInterval(60)
        try store.applyRemoteTask(remote, tags: ["New", "other"])
        XCTAssertEqual(try store.tags(for: task.id), ["new", "other"])

        remote.updatedAt = remote.updatedAt.addingTimeInterval(60)
        try store.applyRemoteTask(remote, tags: [])
        XCTAssertEqual(try store.tags(for: task.id), [], "A marked record with no tags clears them")
    }

    func testAbsentTagsKeepLocalTags() throws {
        let task = try store.createTask(title: "T", tags: ["keep", "me"])
        var remote = task
        remote.title = "Edited on an older client"
        remote.updatedAt = task.updatedAt.addingTimeInterval(60)
        try store.applyRemoteTask(remote, tags: nil)
        XCTAssertEqual(try XCTUnwrap(store.fetchTask(id: task.id)).title, "Edited on an older client")
        XCTAssertEqual(try store.tags(for: task.id), ["keep", "me"])
    }

    func testTieUnionsTagsAndStampsOnlyWhenSomethingWasAdded() throws {
        let task = try store.createTask(title: "T", tags: ["a"])
        try backdateTaxonomy()

        try store.mergeRemoteTagsOnTie(taskID: task.id, tags: ["a"])
        XCTAssertEqual(try XCTUnwrap(store.fetchTask(id: task.id)).updatedAt, old)

        try store.mergeRemoteTagsOnTie(taskID: task.id, tags: ["B"])
        XCTAssertEqual(try store.tags(for: task.id), ["a", "b"])
        XCTAssertGreaterThan(try XCTUnwrap(store.fetchTask(id: task.id)).updatedAt, old)
    }

    func testTagsForSyncPushListsEveryTaskSorted() throws {
        let tagged = try store.createTask(title: "T", tags: ["zeta", "alpha"])
        let bare = try store.createTask(title: "U")
        XCTAssertEqual(try store.tagsForSyncPush(taskIDs: [tagged.id, bare.id]),
                       [tagged.id: ["alpha", "zeta"], bare.id: []])
    }

    // MARK: - Counts

    func testCountsAndSummary() throws {
        let area = try store.createArea(name: "A")
        _ = area
        let project = try store.createProject(name: "P")
        _ = try store.createHeading(in: project.id, title: "H1")
        _ = try store.createHeading(in: project.id, title: "H2")
        _ = try store.createTask(title: "T")

        let counts = try store.taxonomySyncCounts()
        XCTAssertEqual(counts, TaxonomySyncCounts(tasks: 1, projects: 1, areas: 1, headings: 2,
                                                  tasksAwaitingProject: 0, waitingReferences: 0))
        XCTAssertEqual(counts.summaryText, "1 task · 1 project · 1 area · 2 headings")
        XCTAssertNil(counts.waitingText)

        let waiting = TaxonomySyncCounts(tasks: 3, tasksAwaitingProject: 2, waitingReferences: 2)
        XCTAssertEqual(waiting.waitingText, "2 tasks in Inbox until their project syncs")
    }
}
