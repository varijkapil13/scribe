import XCTest
@testable import Scribe

/// Task inspector planning fields (start date, when-bucket, duration, area,
/// heading) persist through `TaskEditorViewModel.save()` and keep the
/// project / area / heading links consistent.
final class TaskEditorPlanningTests: XCTestCase {

    @MainActor
    func testSavePersistsPlanningFields() throws {
        let manager = try DatabaseManager(path: ":memory:")
        let store = TaskStore(databaseManager: manager)
        let area = try store.createArea(name: "Home")
        let original = try store.createTask(title: "Fix fence")

        let vm = TaskEditorViewModel(task: original, store: store, reminderScheduler: NoOpTaskReminderScheduler())
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_900_000_000))
        vm.startAt = start
        vm.setScheduleBucket(.evening)
        vm.estimatedMinutes = 45
        vm.areaId = area.id
        XCTAssertTrue(vm.save())

        let saved = try XCTUnwrap(store.fetchTask(id: original.id))
        XCTAssertEqual(saved.startAt, start)
        XCTAssertEqual(saved.scheduleBucket, .evening)
        XCTAssertEqual(saved.estimatedMinutes, 45)
        XCTAssertEqual(saved.areaId, area.id)
    }

    @MainActor
    func testSomedayClearsStartDate() throws {
        let manager = try DatabaseManager(path: ":memory:")
        let store = TaskStore(databaseManager: manager)
        let original = try store.createTask(title: "Learn piano", startAt: Date(timeIntervalSince1970: 1_900_000_000))

        let vm = TaskEditorViewModel(task: original, store: store, reminderScheduler: NoOpTaskReminderScheduler())
        vm.setScheduleBucket(.someday)
        XCTAssertNil(vm.startAt)
        XCTAssertTrue(vm.save())

        let saved = try XCTUnwrap(store.fetchTask(id: original.id))
        XCTAssertEqual(saved.scheduleBucket, .someday)
        XCTAssertNil(saved.startAt)
    }

    @MainActor
    func testHeadingFollowsProjectAndProjectDropsArea() throws {
        let manager = try DatabaseManager(path: ":memory:")
        let store = TaskStore(databaseManager: manager)
        let area = try store.createArea(name: "Work")
        let launch = try store.createProject(name: "Launch")
        let other = try store.createProject(name: "Other")
        let heading = try store.createHeading(in: launch.id, title: "Phase 1")
        let original = try store.createTask(title: "Draft", areaId: area.id)

        let vm = TaskEditorViewModel(task: original, store: store, reminderScheduler: NoOpTaskReminderScheduler())
        vm.selectProject(launch.id)
        XCTAssertEqual(vm.availableHeadings.map(\.id), [heading.id])
        vm.headingId = heading.id
        XCTAssertTrue(vm.save())

        var saved = try XCTUnwrap(store.fetchTask(id: original.id))
        XCTAssertEqual(saved.projectId, launch.id)
        XCTAssertEqual(saved.headingId, heading.id)
        XCTAssertNil(saved.areaId, "a project task uses its project's area")

        // Switching project clears the heading (it belongs to Launch).
        vm.selectProject(other.id)
        XCTAssertNil(vm.headingId)
        XCTAssertTrue(vm.availableHeadings.isEmpty)
        XCTAssertTrue(vm.save())
        saved = try XCTUnwrap(store.fetchTask(id: original.id))
        XCTAssertEqual(saved.projectId, other.id)
        XCTAssertNil(saved.headingId)
    }
}
