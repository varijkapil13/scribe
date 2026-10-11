import XCTest
import GRDB
@testable import Scribe

/// Local taxonomy edits (areas, projects, headings, tags, and their
/// deletions) must trigger a debounced sync round just like task edits.
@MainActor
final class TaxonomySyncSchedulerTests: XCTestCase {

    @MainActor
    private final class RoundCounter {
        var runs = 0
    }

    func testObservedTablesExistInTheSchema() async throws {
        let manager = try DatabaseManager(path: ":memory:")
        let names = try await manager.database.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        let tables = Set(names)
        for table in TaskSyncScheduler.observedTables {
            XCTAssertTrue(tables.contains(table), "\(table) is observed but missing")
        }
    }

    func testTaxonomyEditsTriggerARound() async throws {
        let counter = RoundCounter()
        let manager = try DatabaseManager(path: ":memory:")
        let store = TaskStore(databaseManager: manager)
        let scheduler = TaskSyncScheduler(
            policy: TaskSyncTriggerPolicy(activationInterval: 300, postSyncQuietPeriod: 0),
            localChangeDebounce: .milliseconds(50),
            isSyncAllowed: { true },
            isToggleOn: { false },
            runSync: { counter.runs += 1 }
        )
        scheduler.start(database: manager.database)
        await scheduler.inFlight?.value   // the launch round

        var taskID = ""
        var areaID = ""
        var projectID = ""
        try await expectRound(scheduler, counter, "task") { taskID = try store.createTask(title: "T").id }
        try await expectRound(scheduler, counter, "area") { areaID = try store.createArea(name: "A").id }
        try await expectRound(scheduler, counter, "project") { projectID = try store.createProject(name: "P").id }
        try await expectRound(scheduler, counter, "heading") { _ = try store.createHeading(in: projectID, title: "H") }
        try await expectRound(scheduler, counter, "tags") { try store.setTags(["x"], for: taskID) }
        try await expectRound(scheduler, counter, "area delete") { try store.deleteArea(id: areaID) }
        try await expectRound(scheduler, counter, "project delete") { try store.deleteProject(id: projectID) }
    }

    /// Runs `edit` and waits for the sync round it should trigger.
    private func expectRound(_ scheduler: TaskSyncScheduler, _ counter: RoundCounter, _ label: String,
                             _ edit: () throws -> Void) async throws {
        let baseline = counter.runs
        try edit()
        let deadline = Date().addingTimeInterval(3)
        while counter.runs == baseline, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        await scheduler.inFlight?.value
        XCTAssertGreaterThan(counter.runs, baseline, "A \(label) edit should trigger a sync round")
    }
}
