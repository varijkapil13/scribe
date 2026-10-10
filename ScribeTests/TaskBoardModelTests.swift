import XCTest
@testable import Scribe

/// The Kanban board's pure rules: column building per grouping, what a drop
/// on a column writes, undo restoration, and the scoped Done column.
final class TaskBoardModelTests: XCTestCase {

    private static let cal: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    private var cal: Calendar { Self.cal }

    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))
            ?? Date(timeIntervalSince1970: 0)
    }

    private func task(_ id: String,
                      project: String? = nil,
                      priority: TodoTask.Priority? = nil,
                      due: Date? = nil,
                      bucket: TaskScheduleBucket = .anytime,
                      startAt: Date? = nil,
                      completedAt: Date? = nil,
                      cancelledAt: Date? = nil) -> TodoTask {
        TodoTask(id: id, title: "Task \(id)", projectId: project, priority: priority, dueAt: due,
                 completedAt: completedAt, cancelledAt: cancelledAt, startAt: startAt,
                 scheduleBucket: bucket)
    }

    private let projects = [Project(id: "p1", name: "Work", color: "#FF8800"), Project(id: "p2", name: "Home")]

    // MARK: - Status

    func testStatusOfTask() {
        XCTAssertEqual(TaskBoardLayout.status(of: task("a")), .toDo)
        XCTAssertEqual(TaskBoardLayout.status(of: task("b", bucket: .today)), .today)
        XCTAssertEqual(TaskBoardLayout.status(of: task("c", bucket: .evening)), .evening)
        XCTAssertEqual(TaskBoardLayout.status(of: task("d", bucket: .someday)), .someday)
        XCTAssertEqual(TaskBoardLayout.status(of: task("e", bucket: .today, completedAt: date(1))), .done)
        XCTAssertEqual(TaskBoardLayout.status(of: task("f", cancelledAt: date(1))), .done)
    }

    // MARK: - Columns

    func testStatusColumnsIncludeEmptyOnesAndDedupeDone() {
        let active = [task("a"), task("b", bucket: .today), task("settling", completedAt: date(10))]
        let done = [task("settling", completedAt: date(10)), task("old", completedAt: date(9))]
        let columns = TaskBoardLayout.columns(active: active, done: done, grouping: .status, projects: projects)
        XCTAssertEqual(columns.map(\.key), TaskBoardStatus.allCases.map { TaskBoardColumnKey.status($0) })
        XCTAssertEqual(columns[0].tasks.map(\.id), ["a"])
        XCTAssertEqual(columns[1].tasks.map(\.id), ["b"])
        XCTAssertTrue(columns[2].tasks.isEmpty)
        XCTAssertTrue(columns[3].tasks.isEmpty)
        XCTAssertEqual(columns[4].tasks.map(\.id), ["settling", "old"])
    }

    func testProjectColumnsStartWithInboxAndSkipFinishedTasks() {
        let active = [
            task("a", project: "p2"),
            task("b"),
            task("c", project: "unknown"),
            task("d", project: "p1", completedAt: date(10)),
        ]
        let columns = TaskBoardLayout.columns(active: active, done: [], grouping: .project, projects: projects)
        XCTAssertEqual(columns.map(\.title), ["Inbox", "Work", "Home"])
        XCTAssertEqual(columns[0].tasks.map(\.id), ["b", "c"])
        XCTAssertTrue(columns[1].tasks.isEmpty)
        XCTAssertEqual(columns[1].colorHex, "#FF8800")
        XCTAssertEqual(columns[2].tasks.map(\.id), ["a"])
    }

    func testPriorityColumnsRunHighToNone() {
        let active = [task("a", priority: .low), task("b"), task("c", priority: .high)]
        let columns = TaskBoardLayout.columns(active: active, done: [], grouping: .priority, projects: [])
        XCTAssertEqual(columns.map(\.title), ["High", "Medium", "Low", "None"])
        XCTAssertEqual(columns.map { $0.tasks.map(\.id) }, [["c"], [], ["a"], ["b"]])
    }

    func testColumnKeysHaveStableDistinctIds() {
        let keys: [TaskBoardColumnKey] = [
            .status(.toDo), .project(nil), .project("p1"), .priority(nil), .priority(.high),
        ]
        XCTAssertEqual(Set(keys.map(\.stableId)).count, keys.count)
        XCTAssertEqual(TaskBoardColumnKey.project(nil).stableId, "project.inbox")
    }

    // MARK: - Drops

    func testDropOnSameColumnIsUnchanged() {
        let now = date(10, 12)
        XCTAssertEqual(TaskBoardMove.outcome(dropping: task("a", bucket: .today), into: .status(.today),
                                             calendar: cal, now: now), .unchanged)
        XCTAssertEqual(TaskBoardMove.outcome(dropping: task("a", project: "p1"), into: .project("p1"),
                                             calendar: cal, now: now), .unchanged)
        XCTAssertEqual(TaskBoardMove.outcome(dropping: task("a"), into: .priority(nil),
                                             calendar: cal, now: now), .unchanged)
    }

    func testDropOnDoneCompletes() {
        XCTAssertEqual(TaskBoardMove.outcome(dropping: task("a"), into: .status(.done),
                                             calendar: cal, now: date(10)), .complete)
    }

    func testDropOnProjectMovesTask() {
        XCTAssertEqual(TaskBoardMove.outcome(dropping: task("a", project: "p1"), into: .project(nil),
                                             calendar: cal, now: date(10)), .moveToProject(nil))
        XCTAssertEqual(TaskBoardMove.outcome(dropping: task("a"), into: .project("p2"),
                                             calendar: cal, now: date(10)), .moveToProject("p2"))
    }

    func testDropOnPriorityUpdatesPriority() {
        let outcome = TaskBoardMove.outcome(dropping: task("a", priority: .low), into: .priority(.high),
                                            calendar: cal, now: date(10))
        guard case .update(let updated) = outcome else { return XCTFail("Expected an update, got \(outcome)") }
        XCTAssertEqual(updated.priority, .high)
    }

    func testDropFromDoneReopensIntoTheTargetBucket() {
        let finished = task("a", bucket: .someday, startAt: date(20), completedAt: date(9))
        let outcome = TaskBoardMove.outcome(dropping: finished, into: .status(.today), calendar: cal, now: date(10, 12))
        guard case .update(let updated) = outcome else { return XCTFail("Expected an update, got \(outcome)") }
        XCTAssertNil(updated.completedAt)
        XCTAssertNil(updated.cancelledAt)
        XCTAssertEqual(updated.scheduleBucket, .today)
        XCTAssertNil(updated.startAt)
    }

    func testToDoKeepsDeferDate() {
        let reopened = TaskBoardMove.reopened(task("a", bucket: .today, startAt: date(12)), into: .toDo,
                                              calendar: cal, now: date(10))
        XCTAssertEqual(reopened.scheduleBucket, .anytime)
        XCTAssertEqual(reopened.startAt, date(12))
    }

    func testEveningMovesAnotherDaysDueToTodayKeepingTime() {
        let reopened = TaskBoardMove.reopened(task("a", due: date(14, 18, 30)), into: .evening,
                                              calendar: cal, now: date(10, 9))
        XCTAssertEqual(reopened.scheduleBucket, .evening)
        XCTAssertEqual(reopened.dueAt, date(10, 18, 30))

        let sameDay = TaskBoardMove.reopened(task("b", due: date(10, 20)), into: .evening,
                                             calendar: cal, now: date(10, 9))
        XCTAssertEqual(sameDay.dueAt, date(10, 20))
    }

    // MARK: - Undo

    func testRestoringCopiesOnlyTheGroupingsFields() {
        let snapshot = task("a", project: "p1", priority: .low, bucket: .someday)
        var current = task("a", project: "p2", priority: .high, bucket: .today, completedAt: date(10))
        current.title = "Edited meanwhile"

        let status = TaskBoardMove.restoring(.status, from: snapshot, to: current)
        XCTAssertEqual(status.scheduleBucket, .someday)
        XCTAssertNil(status.completedAt)
        XCTAssertEqual(status.priority, .high)
        XCTAssertEqual(status.projectId, "p2")
        XCTAssertEqual(status.title, "Edited meanwhile")

        let project = TaskBoardMove.restoring(.project, from: snapshot, to: current)
        XCTAssertEqual(project.projectId, "p1")
        XCTAssertEqual(project.scheduleBucket, .today)

        let priority = TaskBoardMove.restoring(.priority, from: snapshot, to: current)
        XCTAssertEqual(priority.priority, .low)
        XCTAssertEqual(priority.projectId, "p2")
    }

    // MARK: - Done column

    func testDoneTasksAreScopedToTheFilterAndWindow() {
        let finished = [
            task("inboxDone", completedAt: date(10, 9)),
            task("workDone", project: "p1", completedAt: date(10, 11)),
            task("homeCancelled", project: "p2", cancelledAt: date(9, 8)),
            task("ancient", project: "p1", completedAt: date(1)),
        ]
        let now = date(10, 12)
        func ids(_ filter: TaskStore.Filter, areas: [String: String] = [:]) -> [String] {
            TaskBoardLayout.doneTasks(finished, filter: filter, tagsByTask: ["workDone": ["urgent"]],
                                      projectAreaIds: areas, calendar: cal, now: now).map(\.id)
        }
        XCTAssertEqual(ids(.all), ["workDone", "inboxDone", "homeCancelled"])
        XCTAssertEqual(ids(.today), ["workDone", "inboxDone"])
        XCTAssertEqual(ids(.inbox), ["inboxDone"])
        XCTAssertEqual(ids(.project("p1")), ["workDone"])
        XCTAssertEqual(ids(.tag("urgent")), ["workDone"])
        XCTAssertEqual(ids(.area("a1"), areas: ["p2": "a1"]), ["homeCancelled"])
        XCTAssertEqual(ids(.completed), ["workDone", "inboxDone", "homeCancelled", "ancient"])
    }
}
