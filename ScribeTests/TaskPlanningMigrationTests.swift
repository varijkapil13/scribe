import XCTest
import GRDB
@testable import Scribe

/// The v20 `v20_task_planning` migration on an in-memory database: legacy
/// rows read back with planning defaults, and the new tables / foreign keys
/// behave (area delete un-groups, project delete cascades headings, heading
/// delete un-files tasks).
final class TaskPlanningMigrationTests: XCTestCase {

    func testLegacyTaskAndProjectReadBackWithDefaults() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        let migrator = DatabaseManager.makeMigrator()
        // The last migration registered before v20.
        try migrator.migrate(queue, upTo: "v18_speaker_names")

        let now = Date()
        try queue.write { database in
            try database.execute(sql: """
                INSERT INTO projects (id, name, createdAt, sortOrder)
                VALUES ('p1', 'Legacy project', ?, 0)
                """, arguments: [now])
            try database.execute(sql: """
                INSERT INTO tasks (id, title, notes, projectId, createdAt, updatedAt, sortOrder)
                VALUES ('t1', 'Legacy task', '', 'p1', ?, ?, 0)
                """, arguments: [now, now])
        }

        try migrator.migrate(queue)

        let task = try XCTUnwrap(try queue.read { try TodoTask.fetchOne($0, key: "t1") })
        XCTAssertEqual(task.title, "Legacy task")
        XCTAssertNil(task.startAt)
        XCTAssertEqual(task.scheduleBucket, .anytime)
        XCTAssertNil(task.estimatedMinutes)
        XCTAssertNil(task.areaId)
        XCTAssertNil(task.headingId)

        let project = try XCTUnwrap(try queue.read { try Project.fetchOne($0, key: "p1") })
        XCTAssertNil(project.areaId)

        let stored = try queue.read { database in
            try String.fetchOne(database, sql: "SELECT scheduleBucket FROM tasks WHERE id = 't1'")
        }
        XCTAssertEqual(stored, "none")
    }

    func testMigrationCreatesTablesAndColumns() throws {
        let manager = try DatabaseManager(path: ":memory:")
        try manager.database.read { database in
            XCTAssertTrue(try database.tableExists("areas"))
            XCTAssertTrue(try database.tableExists("project_headings"))
            let taskColumns = Set(try database.columns(in: "tasks").map(\.name))
            for column in ["startAt", "scheduleBucket", "estimatedMinutes", "areaId", "headingId"] {
                XCTAssertTrue(taskColumns.contains(column), "tasks.\(column) missing")
            }
            let projectColumns = Set(try database.columns(in: "projects").map(\.name))
            XCTAssertTrue(projectColumns.contains("areaId"))
        }
    }

    func testForeignKeys() throws {
        let manager = try DatabaseManager(path: ":memory:")
        let store = TaskStore(databaseManager: manager)

        let area = try store.createArea(name: "Work")
        let project = try store.createProject(name: "Launch")
        try store.setArea(area.id, forProject: project.id)
        let heading = try store.createHeading(in: project.id, title: "Phase 1")
        let task = try store.createTask(title: "Draft", projectId: project.id, headingId: heading.id)
        let loose = try store.createTask(title: "Loose", areaId: area.id)

        XCTAssertEqual(try store.fetchTask(id: task.id)?.headingId, heading.id)
        XCTAssertEqual(try store.fetchTask(id: loose.id)?.areaId, area.id)
        XCTAssertEqual(try store.fetchProjects().first?.areaId, area.id)

        // Deleting the heading un-files the task (it stays in the project).
        try store.deleteHeading(id: heading.id)
        let unfiled = try XCTUnwrap(store.fetchTask(id: task.id))
        XCTAssertNil(unfiled.headingId)
        XCTAssertEqual(unfiled.projectId, project.id)

        // Deleting a project cascades its headings.
        _ = try store.createHeading(in: project.id, title: "Phase 2")
        try store.deleteProject(id: project.id)
        let headingCount = try manager.database.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM project_headings") ?? -1
        }
        XCTAssertEqual(headingCount, 0)

        // Deleting the area un-groups loose tasks.
        try store.deleteArea(id: area.id)
        XCTAssertNil(try store.fetchTask(id: loose.id)?.areaId)
        XCTAssertTrue(try store.fetchAreas().isEmpty)
    }
}
