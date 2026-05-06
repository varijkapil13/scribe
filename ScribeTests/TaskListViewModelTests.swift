import XCTest
@testable import Scribe

/// Tests the pure date-bucketing logic used by `TaskListViewModel` to group
/// tasks under Today / Tomorrow / This week / Later / No date / Completed.
final class TaskListViewModelTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func task(title: String, dueAt: Date? = nil, completed: Date? = nil) -> TodoTask {
        TodoTask(title: title, dueAt: dueAt, completedAt: completed)
    }

    func testBucketsCoverEveryWindow() {
        let now = date(2026, 5, 6)
        let yesterday = date(2026, 5, 5)
        let later2026 = date(2026, 5, 20)
        let inFiveDays = date(2026, 5, 11)
        let tomorrow = date(2026, 5, 7)

        let tasks: [TodoTask] = [
            task(title: "Overdue", dueAt: yesterday),
            task(title: "Today", dueAt: now),
            task(title: "Tomorrow", dueAt: tomorrow),
            task(title: "This week", dueAt: inFiveDays),
            task(title: "Later", dueAt: later2026),
            task(title: "No date"),
            task(title: "Done", completed: yesterday)
        ]

        let groups = TaskListViewModel.bucket(tasks: tasks, calendar: calendar, now: now)
        let map = Dictionary(uniqueKeysWithValues: groups.map { ($0.bucket, $0.tasks.map(\.title)) })

        XCTAssertEqual(map[.overdue], ["Overdue"])
        XCTAssertEqual(map[.today], ["Today"])
        XCTAssertEqual(map[.tomorrow], ["Tomorrow"])
        XCTAssertEqual(map[.thisWeek], ["This week"])
        XCTAssertEqual(map[.later], ["Later"])
        XCTAssertEqual(map[.noDate], ["No date"])
        XCTAssertEqual(map[.completed], ["Done"])
    }

    func testEmptyBucketsAreOmitted() {
        let now = date(2026, 5, 6)
        let groups = TaskListViewModel.bucket(
            tasks: [task(title: "Just an inbox task")],
            calendar: calendar,
            now: now
        )
        XCTAssertEqual(groups.map(\.bucket), [.noDate])
    }

    func testCompletedAlwaysGoesToCompletedBucketEvenWithDueDate() {
        let now = date(2026, 5, 6)
        let tasks = [task(title: "Old + done", dueAt: date(2026, 5, 4), completed: date(2026, 5, 5))]
        let groups = TaskListViewModel.bucket(tasks: tasks, calendar: calendar, now: now)
        XCTAssertEqual(groups.map(\.bucket), [.completed])
    }
}
