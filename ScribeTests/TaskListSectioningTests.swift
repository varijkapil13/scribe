import XCTest
@testable import Scribe

/// The iOS task lists' pure rules: destination membership, sections per
/// list, tag filtering, counts and manual reordering.
final class TaskListSectioningTests: XCTestCase {

    private static let cal: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    private var cal: Calendar { Self.cal }

    /// Wednesday, 2026-03-11 10:00 UTC.
    private var now: Date { date(11, 10) }

    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, month: Int = 3) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))
            ?? Date(timeIntervalSince1970: 0)
    }

    private func task(_ id: String,
                      project: String? = nil,
                      area: String? = nil,
                      heading: String? = nil,
                      due: Date? = nil,
                      bucket: TaskScheduleBucket = .anytime,
                      startAt: Date? = nil,
                      completedAt: Date? = nil,
                      cancelledAt: Date? = nil) -> TodoTask {
        TodoTask(id: id, title: "Task \(id)", projectId: project, dueAt: due,
                 completedAt: completedAt, cancelledAt: cancelledAt, startAt: startAt,
                 scheduleBucket: bucket, areaId: area, headingId: heading)
    }

    private func ids(_ section: TaskListSection) -> [String] { section.tasks.map(\.id) }

    // MARK: - Destinations

    func testStoreFilters() {
        XCTAssertEqual(TaskListDestination.inbox.storeFilter, .inbox)
        XCTAssertEqual(TaskListDestination.today.storeFilter, .today)
        XCTAssertEqual(TaskListDestination.upcoming.storeFilter, .all)
        XCTAssertEqual(TaskListDestination.logbook.storeFilter, .completed)
        XCTAssertEqual(TaskListDestination.project("p").storeFilter, .project("p"))
        XCTAssertEqual(TaskListDestination.tag("work").storeFilter, .tag("work"))
    }

    func testAnytimeExcludesSomedayAndDeferred() {
        let open = task("a")
        let someday = task("b", bucket: .someday)
        let deferred = task("c", startAt: date(14))
        let startsToday = task("d", startAt: date(11, 8))
        let done = task("e", completedAt: date(10))
        let dest = TaskListDestination.anytime
        XCTAssertTrue(dest.includes(open, now: now, calendar: cal))
        XCTAssertFalse(dest.includes(someday, now: now, calendar: cal))
        XCTAssertFalse(dest.includes(deferred, now: now, calendar: cal))
        XCTAssertTrue(dest.includes(startsToday, now: now, calendar: cal))
        XCTAssertFalse(dest.includes(done, now: now, calendar: cal))
    }

    func testIdsAreDistinct() {
        let all: [TaskListDestination] = TaskListDestination.smartLists
            + [.area("x"), .project("x"), .tag("x"), .planner]
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
    }

    // MARK: - Today

    func testTodaySectionsSplitOverdueTodayEvening() {
        let tasks = [
            task("overdue", due: date(9)),
            task("due", due: date(11, 15)),
            task("planned", bucket: .today),
            task("evening", bucket: .evening),
            task("eveningDue", due: date(11, 19), bucket: .evening),
            task("tomorrow", due: date(12)),
            task("deferredToday", bucket: .today, startAt: date(13)),
        ]
        let sections = TaskListSectioning.sections(for: .today, tasks: tasks, calendar: cal, now: now)
        XCTAssertEqual(sections.map(\.kind), [.overdue, .today, .evening])
        XCTAssertEqual(ids(sections[0]), ["overdue"])
        XCTAssertEqual(ids(sections[1]), ["due", "planned"])
        XCTAssertEqual(ids(sections[2]), ["evening", "eveningDue"])
    }

    func testOverdueEveningTaskLeadsInOverdue() {
        let tasks = [task("late", due: date(10, 19), bucket: .evening)]
        let sections = TaskListSectioning.todaySections(tasks, calendar: cal, now: now)
        XCTAssertEqual(sections.map(\.kind), [.overdue])
    }

    // MARK: - Upcoming

    func testUpcomingGroupsByDayThenMonth() {
        let tasks = [
            task("today", due: date(11, 9)),
            task("tomorrowLate", due: date(12, 18)),
            task("tomorrow", due: date(12)),
            task("friday", due: date(13)),
            task("deferred", due: date(11), startAt: date(15)),
            task("nextMonth", due: date(2, month: 4)),
            task("lateInMonth", due: date(30)),
            task("done", due: date(12), completedAt: date(10)),
            task("undated"),
        ]
        let sections = TaskListSectioning.sections(for: .upcoming, tasks: tasks, calendar: cal, now: now)
        XCTAssertEqual(sections.map(\.kind), [
            .day(date(12)), .day(date(13)), .day(date(15)),
            .month(date(1)), .month(date(1, month: 4)),
        ])
        XCTAssertEqual(sections[0].title, "Tomorrow")
        XCTAssertEqual(ids(sections[0]), ["tomorrowLate", "tomorrow"])
        XCTAssertEqual(ids(sections[2]), ["deferred"])
        XCTAssertEqual(ids(sections[3]), ["lateInMonth"])
        XCTAssertEqual(ids(sections[4]), ["nextMonth"])
    }

    func testUpcomingDateUsesStartWhenDeferred() {
        let deferred = task("d", due: date(20), startAt: date(14, 9))
        XCTAssertEqual(TaskListSectioning.upcomingDate(of: deferred, now: now, calendar: cal), date(14))
        XCTAssertNil(TaskListSectioning.upcomingDate(of: task("t", due: date(11, 23)), now: now, calendar: cal))
    }

    // MARK: - Containers

    func testAnytimeGroupsByProjectInProjectOrder() {
        let projects = [Project(id: "p1", name: "Work"), Project(id: "p2", name: "Home")]
        let tasks = [task("a", project: "p2"), task("b"), task("c", project: "p1"), task("d", project: "gone")]
        let sections = TaskListSectioning.sections(for: .anytime, tasks: tasks, projects: projects,
                                                   calendar: cal, now: now)
        XCTAssertEqual(sections.map(\.kind), [.project(nil), .project("p1"), .project("p2")])
        XCTAssertEqual(ids(sections[0]), ["b", "d"])
        XCTAssertEqual(sections[1].title, "Work")
    }

    func testAreaSectionsListLooseTasksThenItsProjects() {
        let projects = [Project(id: "p1", name: "Work", areaId: "a1"), Project(id: "p2", name: "Other")]
        let tasks = [task("loose", area: "a1"), task("inWork", project: "p1")]
        let sections = TaskListSectioning.sections(for: .area("a1"), tasks: tasks, projects: projects,
                                                   calendar: cal, now: now)
        XCTAssertEqual(sections.map(\.kind), [.areaTasks("a1"), .project("p1")])
    }

    func testProjectSectionsKeepEmptyHeadingsInOrder() {
        let h1 = ProjectHeading(id: "h1", projectId: "p", title: "Later", sortOrder: 1)
        let h0 = ProjectHeading(id: "h0", projectId: "p", title: "First", sortOrder: 0)
        let tasks = [task("x", project: "p", heading: "h1"), task("y", project: "p"),
                     task("z", project: "p", heading: "missing")]
        let sections = TaskListSectioning.sections(for: .project("p"), tasks: tasks, headings: [h1, h0],
                                                   calendar: cal, now: now)
        XCTAssertEqual(sections.map(\.kind), [.noHeading, .heading(h0), .heading(h1)])
        XCTAssertEqual(ids(sections[0]), ["y", "z"])
        XCTAssertTrue(sections[1].tasks.isEmpty)
        XCTAssertEqual(ids(sections[2]), ["x"])
    }

    func testInboxIsOnePlainSection() {
        let sections = TaskListSectioning.sections(for: .inbox, tasks: [task("a"), task("b")],
                                                   calendar: cal, now: now)
        XCTAssertEqual(sections.map(\.kind), [.plain])
        XCTAssertTrue(TaskListSectioning.sections(for: .inbox, tasks: [], calendar: cal, now: now).isEmpty)
    }

    // MARK: - Logbook

    func testLogbookGroupsByFinishDayNewestFirst() {
        let tasks = [
            task("old", completedAt: date(9, 8)),
            task("todayEarly", completedAt: date(11, 7)),
            task("todayLate", completedAt: date(11, 9)),
            task("wontDo", cancelledAt: date(10, 12)),
        ]
        let sections = TaskListSectioning.sections(for: .logbook, tasks: tasks, calendar: cal, now: now)
        XCTAssertEqual(sections.map(\.kind), [.finishedDay(date(11)), .finishedDay(date(10)), .finishedDay(date(9))])
        XCTAssertEqual(sections[0].title, "Today")
        XCTAssertEqual(sections[1].title, "Yesterday")
        XCTAssertEqual(ids(sections[0]), ["todayLate", "todayEarly"])
    }

    // MARK: - Tags + counts

    func testTagFilterRequiresEveryTag() {
        let tasks = [task("a"), task("b"), task("c")]
        let tags = ["a": ["work", "urgent"], "b": ["work"]]
        XCTAssertEqual(TaskListSectioning.filter(tasks, requiringTags: [], tagsByTask: tags).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(TaskListSectioning.filter(tasks, requiringTags: ["work"], tagsByTask: tags).map(\.id), ["a", "b"])
        XCTAssertEqual(TaskListSectioning.filter(tasks, requiringTags: ["work", "urgent"], tagsByTask: tags).map(\.id), ["a"])
    }

    func testCountsAndBadge() {
        let tasks = [
            task("inbox"),
            task("inProject", project: "p", due: date(11)),
            task("overdue", due: date(8)),
            task("someday", bucket: .someday),
            task("done", completedAt: date(10)),
        ]
        XCTAssertEqual(TaskListSectioning.count(for: .inbox, in: tasks, now: now, calendar: cal), 2)
        XCTAssertEqual(TaskListSectioning.count(for: .today, in: tasks, now: now, calendar: cal), 2)
        XCTAssertNil(TaskListSectioning.count(for: .logbook, in: tasks, now: now, calendar: cal))
        XCTAssertEqual(TaskListSectioning.overdueCount(in: tasks, now: now, calendar: cal), 1)
        XCTAssertEqual(TaskListSectioning.appBadgeCount(tasks, now: now, calendar: cal), 2)
    }

    // MARK: - Reordering

    func testReorderedFollowsOnMoveSemantics() {
        let ids = ["a", "b", "c", "d"]
        XCTAssertEqual(TaskListSectioning.reordered(ids, moving: IndexSet(integer: 0), to: 3), ["b", "c", "a", "d"])
        XCTAssertEqual(TaskListSectioning.reordered(ids, moving: IndexSet(integer: 3), to: 0), ["d", "a", "b", "c"])
        XCTAssertEqual(TaskListSectioning.reordered(ids, moving: IndexSet([0, 2]), to: 4), ["b", "d", "a", "c"])
        XCTAssertEqual(TaskListSectioning.reordered(ids, moving: IndexSet(integer: 9), to: 0), ids)
    }

    func testOrderScopesSplitsByProject() {
        let tasks = [task("a"), task("b", project: "p"), task("c"), task("d", project: "p")]
        let scopes = TaskListSectioning.orderScopes(["d", "a", "b", "c", "zzz"], tasks: tasks)
        XCTAssertEqual(scopes.count, 2)
        XCTAssertEqual(scopes[0].projectId, "p")
        XCTAssertEqual(scopes[0].ids, ["d", "b"])
        XCTAssertNil(scopes[1].projectId)
        XCTAssertEqual(scopes[1].ids, ["a", "c"])
    }

    // MARK: - Drag token

    func testDragTokenRoundTrip() {
        XCTAssertEqual(TaskDragToken.decode(TaskDragToken.encode("abc")), "abc")
        XCTAssertNil(TaskDragToken.decode("abc"))
        XCTAssertNil(TaskDragToken.decode(TaskDragToken.prefix))
    }
}
