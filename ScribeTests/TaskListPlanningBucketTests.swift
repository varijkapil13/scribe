import XCTest
@testable import Scribe

/// Planning-aware grouping in `TaskListViewModel.bucket` (This Evening,
/// explicit Today, Someday, start-date placement, project headings) plus the
/// quick-add due-date default and heading reorder helper.
final class TaskListPlanningBucketTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private var now: Date { date(2026, 5, 6) }

    private func titles(_ groups: [(bucket: TaskListViewModel.Bucket, tasks: [TodoTask])])
        -> [TaskListViewModel.Bucket: [String]] {
        Dictionary(uniqueKeysWithValues: groups.map { ($0.bucket, $0.tasks.map(\.title)) })
    }

    func testEveningSomedayAndExplicitToday() {
        let tasks = [
            TodoTask(title: "Tonight", scheduleBucket: .evening),
            TodoTask(title: "Evening due today", dueAt: now, scheduleBucket: .evening),
            TodoTask(title: "Evening due Friday", dueAt: date(2026, 5, 8), scheduleBucket: .evening),
            TodoTask(title: "Overdue evening", dueAt: date(2026, 5, 4), scheduleBucket: .evening),
            TodoTask(title: "Planned today, due later", dueAt: date(2026, 5, 20), scheduleBucket: .today),
            TodoTask(title: "Parked", scheduleBucket: .someday),
            TodoTask(title: "Loose"),
        ]
        let groups = TaskListViewModel.bucket(tasks: tasks, calendar: calendar, now: now)
        let map = titles(groups)

        XCTAssertEqual(map[.evening], ["Tonight", "Evening due today"])
        XCTAssertEqual(map[.overdue], ["Overdue evening"])
        XCTAssertEqual(map[.thisWeek], ["Evening due Friday"])
        XCTAssertEqual(map[.today], ["Planned today, due later"])
        XCTAssertEqual(map[.someday], ["Parked"])
        XCTAssertEqual(map[.noDate], ["Loose"])

        // Evening renders right after Today; Someday after No date.
        let order = groups.map(\.bucket)
        XCTAssertEqual(order, [.overdue, .today, .evening, .thisWeek, .noDate, .someday])
    }

    func testUndatedDeferredTaskPlacedByStartDate() {
        let tasks = [
            TodoTask(title: "Starts tomorrow", startAt: calendar.startOfDay(for: date(2026, 5, 7))),
            TodoTask(title: "Started already", startAt: calendar.startOfDay(for: date(2026, 5, 1))),
        ]
        let map = titles(TaskListViewModel.bucket(tasks: tasks, calendar: calendar, now: now))
        XCTAssertEqual(map[.tomorrow], ["Starts tomorrow"])
        XCTAssertEqual(map[.noDate], ["Started already"])
    }

    func testHeadingSectionsFollowUnheadedAndPrecedeCompleted() {
        let h1 = ProjectHeading(id: "h1", projectId: "p", title: "Design", sortOrder: 0)
        let h2 = ProjectHeading(id: "h2", projectId: "p", title: "Build", sortOrder: 1)
        let tasks = [
            TodoTask(title: "Unfiled", projectId: "p"),
            TodoTask(title: "Sketch", projectId: "p", headingId: "h1"),
            TodoTask(title: "Done in heading", projectId: "p",
                     completedAt: date(2026, 5, 5), headingId: "h1"),
            TodoTask(title: "Stale heading", projectId: "p", headingId: "gone"),
        ]
        let groups = TaskListViewModel.bucket(tasks: tasks, headings: [h1, h2], calendar: calendar, now: now)
        XCTAssertEqual(groups.map(\.bucket), [.noDate, .heading(h1), .heading(h2), .completed])
        let map = titles(groups)
        XCTAssertEqual(map[.noDate], ["Unfiled", "Stale heading"])
        XCTAssertEqual(map[.heading(h1)], ["Sketch"])
        XCTAssertEqual(map[.heading(h2)], [], "empty headings still render so they accept drops")
        XCTAssertEqual(map[.completed], ["Done in heading"])
    }

    func testNoHeadingsMatchesPlainBucketing() {
        let tasks = [TodoTask(title: "A", dueAt: now), TodoTask(title: "B")]
        let plain = TaskListViewModel.bucket(tasks: tasks, calendar: calendar, now: now).map(\.bucket)
        let withHeadings = TaskListViewModel.bucket(tasks: tasks, headings: [], calendar: calendar, now: now)
            .map(\.bucket)
        XCTAssertEqual(plain, withHeadings)
    }

    @MainActor
    func testBucketTitles() {
        XCTAssertEqual(TaskListViewModel.Bucket.evening.title, "This Evening")
        XCTAssertEqual(TaskListViewModel.Bucket.someday.title, "Someday")
        let heading = ProjectHeading(projectId: "p", title: "Ship")
        XCTAssertEqual(TaskListViewModel.Bucket.heading(heading).title, "Ship")
        XCTAssertEqual(TaskListViewModel.Bucket.heading(heading).heading, heading)
        XCTAssertNil(TaskListViewModel.Bucket.today.heading)
    }

    // MARK: - Quick-add default due date

    func testDefaultQuickAddDueDate() {
        let today = calendar.startOfDay(for: now)
        func due(_ filter: TaskStore.Filter, _ bucket: TaskScheduleBucket = .anytime, start: Date? = nil) -> Date? {
            TaskListViewModel.defaultQuickAddDueDate(filter: filter, bucket: bucket, startAt: start,
                                                     calendar: calendar, now: now)
        }
        XCTAssertEqual(due(.inbox), today)
        XCTAssertEqual(due(.today), today)
        XCTAssertEqual(due(.dueOn(date(2026, 5, 9))), calendar.startOfDay(for: date(2026, 5, 9)))
        XCTAssertNil(due(.someday))
        XCTAssertNil(due(.project("p")))
        XCTAssertNil(due(.area("a")))
        XCTAssertNil(due(.inbox, .someday))
        XCTAssertNil(due(.today, .evening))
        XCTAssertNil(due(.inbox, start: date(2026, 5, 9)))
    }

    // MARK: - Heading reorder helper

    func testMovingHeading() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(TaskListViewModel.movingHeading("b", by: -1, in: ids), ["b", "a", "c"])
        XCTAssertEqual(TaskListViewModel.movingHeading("b", by: 1, in: ids), ["a", "c", "b"])
        XCTAssertEqual(TaskListViewModel.movingHeading("a", by: -1, in: ids), ids)
        XCTAssertEqual(TaskListViewModel.movingHeading("c", by: 5, in: ids), ids)
        XCTAssertEqual(TaskListViewModel.movingHeading("zzz", by: 1, in: ids), ids)
    }
}
