import XCTest
import GRDB
@testable import Scribe

/// `TaskStore` planning behaviour (v20): Today / Upcoming / Inbox / Someday /
/// Area filtering with start dates and when-buckets, area + heading CRUD,
/// recurring completion (COUNT / UNTIL / after completion / start shift),
/// and the SQL filters agreeing with `TaskPlanningRules`.
final class TaskPlanningStoreTests: XCTestCase {

    private var manager: DatabaseManager!
    private var store: TaskStore!
    private let cal = Calendar(identifier: .gregorian)

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: ":memory:")
        store = TaskStore(databaseManager: manager)
    }

    override func tearDown() {
        store = nil
        manager = nil
    }

    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 5, day: 6, hour: 14))! }
    private func days(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: now)! }
    private func startOfDay(_ n: Int) -> Date { cal.startOfDay(for: days(n)) }

    private func ids(_ filter: TaskStore.Filter) throws -> Set<String> {
        Set(try store.fetchTasks(filter: filter, calendar: cal, now: now).map(\.id))
    }

    // MARK: - Today

    func testFutureStartHidesTaskFromToday() throws {
        let deferred = try store.createTask(title: "Deferred", dueAt: days(-1), startAt: startOfDay(2))
        let startsToday = try store.createTask(title: "Starts today", dueAt: now, startAt: startOfDay(0))
        let plain = try store.createTask(title: "Plain", dueAt: now)

        XCTAssertEqual(try ids(.today), [startsToday.id, plain.id])
        XCTAssertFalse(try ids(.today).contains(deferred.id))
    }

    func testExplicitTodayAndUndatedEveningJoinToday() throws {
        let planned = try store.createTask(title: "Planned", dueAt: days(5), scheduleBucket: .today)
        let evening = try store.createTask(title: "Tonight", scheduleBucket: .evening)
        let datedEvening = try store.createTask(title: "Fri evening", dueAt: days(2), scheduleBucket: .evening)
        let anytime = try store.createTask(title: "Anytime")
        let someday = try store.createTask(title: "Parked", scheduleBucket: .someday)

        let today = try ids(.today)
        XCTAssertTrue(today.contains(planned.id))
        XCTAssertTrue(today.contains(evening.id))
        XCTAssertFalse(today.contains(datedEvening.id), "a dated evening task waits for its day")
        XCTAssertFalse(today.contains(anytime.id))
        XCTAssertFalse(today.contains(someday.id))
    }

    func testDeferredExplicitTodayStillHidden() throws {
        let task = try store.createTask(title: "Later", startAt: startOfDay(3), scheduleBucket: .today)
        XCTAssertFalse(try ids(.today).contains(task.id))
    }

    // MARK: - Upcoming / Inbox / Someday

    func testUpcomingIncludesTasksStartingInWindow() throws {
        let starts = try store.createTask(title: "Starts in 3", startAt: startOfDay(3))
        let startsLate = try store.createTask(title: "Starts in 10", startAt: startOfDay(10))
        let due = try store.createTask(title: "Due in 2", dueAt: days(2))

        let upcoming = try ids(.upcoming)
        XCTAssertTrue(upcoming.contains(starts.id))
        XCTAssertTrue(upcoming.contains(due.id))
        XCTAssertFalse(upcoming.contains(startsLate.id))
    }

    func testSomedayLeavesInboxAndHasItsOwnList() throws {
        let inbox = try store.createTask(title: "Inbox")
        let someday = try store.createTask(title: "Someday", scheduleBucket: .someday)
        let done = try store.createTask(title: "Done someday", scheduleBucket: .someday)
        try store.completeTask(id: done.id)

        XCTAssertEqual(try ids(.inbox), [inbox.id])
        XCTAssertEqual(try ids(.someday), [someday.id])
    }

    // MARK: - Areas

    func testAreaFilterIncludesAreaProjectsAndLooseTasks() throws {
        let area = try store.createArea(name: "Home")
        let other = try store.createArea(name: "Work")
        let homeProject = try store.createProject(name: "Garden")
        try store.setArea(area.id, forProject: homeProject.id)
        let workProject = try store.createProject(name: "Launch")
        try store.setArea(other.id, forProject: workProject.id)

        let inProject = try store.createTask(title: "Plant", projectId: homeProject.id)
        let loose = try store.createTask(title: "Fix tap", areaId: area.id)
        _ = try store.createTask(title: "Ship", projectId: workProject.id)
        _ = try store.createTask(title: "Inbox")

        XCTAssertEqual(try ids(.area(area.id)), [inProject.id, loose.id])
    }

    func testAreaCrudAndOrdering() throws {
        let a = try store.createArea(name: "  Alpha ")
        let b = try store.createArea(name: "Beta", symbol: "house")
        XCTAssertEqual(try store.fetchAreas().map(\.name), ["Alpha", "Beta"])

        try store.reorderAreas([b.id, a.id])
        XCTAssertEqual(try store.fetchAreas().map(\.id), [b.id, a.id])

        var renamed = a
        renamed.name = "Admin"
        try store.updateArea(renamed)
        XCTAssertEqual(try store.fetchAreas().first { $0.id == a.id }?.name, "Admin")
        XCTAssertEqual(try store.fetchAreas().first { $0.id == b.id }?.symbol, "house")
    }

    func testProjectTaskDropsOwnArea() throws {
        let area = try store.createArea(name: "Home")
        let project = try store.createProject(name: "P")
        let task = try store.createTask(title: "T", projectId: project.id, areaId: area.id)
        XCTAssertNil(try store.fetchTask(id: task.id)?.areaId, "a project task inherits the project's area")

        let loose = try store.createTask(title: "Loose", areaId: area.id)
        try store.moveTask(id: loose.id, toProject: project.id)
        XCTAssertNil(try store.fetchTask(id: loose.id)?.areaId)
    }

    // MARK: - Headings

    func testHeadingCrudAndReorder() throws {
        let project = try store.createProject(name: "P")
        let h1 = try store.createHeading(in: project.id, title: "Design")
        let h2 = try store.createHeading(in: project.id, title: "Build")
        XCTAssertEqual(try store.headings(in: project.id).map(\.title), ["Design", "Build"])

        try store.reorderHeadings([h2.id, h1.id], in: project.id)
        XCTAssertEqual(try store.headings(in: project.id).map(\.id), [h2.id, h1.id])

        try store.renameHeading(id: h1.id, title: " Discovery ")
        XCTAssertEqual(try store.headings(in: project.id).last?.title, "Discovery")
    }

    func testSetHeadingMovesTaskIntoHeadingProject() throws {
        let p1 = try store.createProject(name: "One")
        let p2 = try store.createProject(name: "Two")
        let heading = try store.createHeading(in: p2.id, title: "Next")
        let task = try store.createTask(title: "T", projectId: p1.id)

        try store.setHeading(heading.id, forTask: task.id)
        let filed = try XCTUnwrap(store.fetchTask(id: task.id))
        XCTAssertEqual(filed.projectId, p2.id)
        XCTAssertEqual(filed.headingId, heading.id)

        // Moving to another project drops the heading.
        try store.moveTask(id: task.id, toProject: p1.id)
        XCTAssertNil(try store.fetchTask(id: task.id)?.headingId)
    }

    // MARK: - Recurring completion

    func testCompletingCountedSeriesEndsIt() throws {
        let due = cal.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 9))!
        let task = try store.createTask(title: "Physio", dueAt: due, recurrenceRule: "FREQ=WEEKLY;COUNT=2")

        try store.completeTask(id: task.id, at: due)
        let second = try XCTUnwrap(store.fetchTask(id: task.id))
        XCTAssertNil(second.completedAt)
        XCTAssertEqual(second.recurrenceRule, "FREQ=WEEKLY;COUNT=1")
        XCTAssertNotNil(second.dueAt)

        try store.completeTask(id: task.id, at: try XCTUnwrap(second.dueAt))
        let finished = try XCTUnwrap(store.fetchTask(id: task.id))
        XCTAssertNotNil(finished.completedAt, "the last counted occurrence completes the task")
    }

    func testCompletingPastUntilEndsSeries() throws {
        let due = cal.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 9))!
        let task = try store.createTask(title: "Daily", dueAt: due,
                                        recurrenceRule: "FREQ=DAILY;UNTIL=20260101T000000Z")
        try store.completeTask(id: task.id, at: due)
        XCTAssertNotNil(try store.fetchTask(id: task.id)?.completedAt)
    }

    func testCompletingShiftsStartAndClearsTodayPlan() throws {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(identifier: "America/New_York")!
        let due = local.date(from: DateComponents(year: 2026, month: 5, day: 8, hour: 9))!
        let start = local.date(from: DateComponents(year: 2026, month: 5, day: 6))!
        let task = TodoTask(title: "Report", dueAt: due, recurrenceRule: "FREQ=WEEKLY",
                            startAt: start, scheduleBucket: .today)

        let next = try TaskStore.completing(task, at: due, calendar: local)
        XCTAssertNil(next.completedAt)
        XCTAssertEqual(next.dueAt, local.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 9)))
        XCTAssertEqual(next.startAt, local.date(from: DateComponents(year: 2026, month: 5, day: 13)))
        XCTAssertEqual(next.scheduleBucket, .anytime)
        XCTAssertEqual(next.recurrenceRule, "FREQ=WEEKLY", "rule untouched without COUNT")
    }

    func testCompletingAfterCompletionRule() throws {
        let due = cal.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 9))!
        let doneAt = cal.date(from: DateComponents(year: 2026, month: 5, day: 7, hour: 18))!
        let task = TodoTask(title: "Water", dueAt: due,
                            recurrenceRule: "FREQ=WEEKLY;INTERVAL=2;X-SCRIBE-FROM=COMPLETION")
        let next = try TaskStore.completing(task, at: doneAt, calendar: cal)
        XCTAssertEqual(next.dueAt, cal.date(from: DateComponents(year: 2026, month: 5, day: 21, hour: 9)))
    }

    func testCompletingOneOffClearsCancellation() throws {
        let task = TodoTask(title: "One-off", cancelledAt: Date(timeIntervalSince1970: 5))
        let done = try TaskStore.completing(task, at: Date(timeIntervalSince1970: 10), calendar: cal)
        XCTAssertEqual(done.completedAt, Date(timeIntervalSince1970: 10))
        XCTAssertNil(done.cancelledAt)
    }

    // MARK: - Planning fields round-trip + sync

    func testPlanningFieldsRoundTrip() throws {
        let start = startOfDay(1)
        let task = try store.createTask(title: "Plan", startAt: start, scheduleBucket: .evening,
                                        estimatedMinutes: 45)
        let read = try XCTUnwrap(store.fetchTask(id: task.id))
        XCTAssertEqual(read.startAt, start)
        XCTAssertEqual(read.scheduleBucket, .evening)
        XCTAssertEqual(read.estimatedMinutes, 45)

        var edited = read
        edited.scheduleBucket = .someday
        edited.estimatedMinutes = nil
        try store.updateTask(edited)
        let reread = try XCTUnwrap(store.fetchTask(id: task.id))
        XCTAssertEqual(reread.scheduleBucket, .someday)
        XCTAssertNil(reread.estimatedMinutes)
    }

    func testSyncUpsertDropsUnknownAreaAndHeading() throws {
        let remote = TodoTask(id: "remote-1", title: "From another Mac",
                              createdAt: Date(timeIntervalSince1970: 1),
                              updatedAt: Date(timeIntervalSince1970: 2),
                              scheduleBucket: .someday, estimatedMinutes: 15,
                              areaId: "missing-area", headingId: "missing-heading")
        try store.upsertFromSync(remote)
        let local = try XCTUnwrap(store.fetchTask(id: "remote-1"))
        XCTAssertNil(local.areaId)
        XCTAssertNil(local.headingId)
        XCTAssertEqual(local.scheduleBucket, .someday)
        XCTAssertEqual(local.estimatedMinutes, 15)
        XCTAssertEqual(local.updatedAt, Date(timeIntervalSince1970: 2))
    }

    // MARK: - SQL ⇄ TaskPlanningRules agreement

    func testSQLFiltersMatchPlanningRules() throws {
        let buckets: [TaskScheduleBucket] = [.anytime, .today, .evening, .someday]
        let dues: [Date?] = [nil, days(-2), now, days(1), days(4), days(9)]
        let starts: [Date?] = [nil, startOfDay(-1), startOfDay(0), startOfDay(2), startOfDay(12)]
        var all: [TodoTask] = []
        for bucket in buckets {
            for due in dues {
                for start in starts {
                    all.append(try store.createTask(title: "t", dueAt: due, startAt: start, scheduleBucket: bucket))
                }
            }
        }
        let expectedToday = Set(all.filter { TaskPlanningRules.isInToday($0, now: now, calendar: cal) }.map(\.id))
        let expectedUpcoming = Set(all.filter { TaskPlanningRules.isInUpcoming($0, now: now, calendar: cal) }.map(\.id))
        let expectedInbox = Set(all.filter { TaskPlanningRules.isInInbox($0) }.map(\.id))
        let expectedSomeday = Set(all.filter { TaskPlanningRules.isInSomeday($0) }.map(\.id))

        XCTAssertEqual(try ids(.today), expectedToday)
        XCTAssertEqual(try ids(.upcoming), expectedUpcoming)
        XCTAssertEqual(try ids(.inbox), expectedInbox)
        XCTAssertEqual(try ids(.someday), expectedSomeday)
        XCTAssertFalse(expectedToday.isEmpty)
    }
}
