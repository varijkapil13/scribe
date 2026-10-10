import XCTest
@testable import Scribe

/// Pure planner rules: which tasks are time blocks, what scheduling / moving
/// / resizing writes, the side list, and the combined event + task grid.
final class PlannerSchedulingTests: XCTestCase {

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
                      due: Date? = nil,
                      estimate: Int? = nil,
                      bucket: TaskScheduleBucket = .anytime,
                      startAt: Date? = nil,
                      completedAt: Date? = nil) -> TodoTask {
        TodoTask(id: id, title: "Task \(id)", dueAt: due, completedAt: completedAt,
                 startAt: startAt, scheduleBucket: bucket, estimatedMinutes: estimate)
    }

    // MARK: - Blocks

    func testOnlyTimedDueDatesAreScheduled() {
        XCTAssertTrue(PlannerScheduling.isScheduled(task("a", due: date(10, 9, 30)), calendar: cal))
        XCTAssertFalse(PlannerScheduling.isScheduled(task("b", due: date(10)), calendar: cal))
        XCTAssertFalse(PlannerScheduling.isScheduled(task("c"), calendar: cal))
    }

    func testDurationFallsBackToThirtyMinutes() {
        XCTAssertEqual(PlannerScheduling.durationMinutes(of: task("a", estimate: 45)), 45)
        XCTAssertEqual(PlannerScheduling.durationMinutes(of: task("b")), 30)
        XCTAssertEqual(PlannerScheduling.durationMinutes(of: task("c", estimate: 0)), 30)
    }

    func testTaskBlocksForADay() {
        let tasks = [
            task("late", due: date(10, 15), estimate: 60),
            task("early", due: date(10, 9)),
            task("dateOnly", due: date(10)),
            task("otherDay", due: date(11, 9)),
            task("done", due: date(10, 11), completedAt: date(10, 11, 30)),
        ]
        let blocks = PlannerScheduling.taskBlocks(tasks, on: date(10), calendar: cal)
        XCTAssertEqual(blocks.map(\.id), ["early", "late"])
        XCTAssertEqual(blocks.first?.durationMinutes, 30)
        XCTAssertEqual(blocks.first?.end, date(10, 9, 30))
        XCTAssertEqual(blocks.last?.end, date(10, 16))
    }

    // MARK: - Side list

    func testSideListForToday() {
        let now = date(10, 8)
        let tasks = [
            task("dueToday", due: date(10)),
            task("overdue", due: date(8)),
            task("plannedToday", bucket: .today),
            task("evening", bucket: .evening),
            task("undated"),
            task("someday", bucket: .someday),
            task("deferred", startAt: date(12)),
            task("scheduled", due: date(10, 9)),
            task("tomorrow", due: date(11)),
        ]
        let list = PlannerScheduling.sideList(tasks, for: date(10), calendar: cal, now: now)
        XCTAssertEqual(list.forDay.map(\.id), ["dueToday", "overdue", "plannedToday", "evening"])
        XCTAssertEqual(list.undated.map(\.id), ["undated"])
    }

    func testSideListForAnotherDayIgnoresTodayPlans() {
        let now = date(10, 8)
        let tasks = [
            task("dueThatDay", due: date(12)),
            task("overdue", due: date(8)),
            task("plannedToday", bucket: .today),
        ]
        let list = PlannerScheduling.sideList(tasks, for: date(12), calendar: cal, now: now)
        XCTAssertEqual(list.forDay.map(\.id), ["dueThatDay"])
        XCTAssertEqual(list.undated.map(\.id), ["plannedToday"])
    }

    // MARK: - Writes

    func testSchedulingSetsTimeAndDefaultEstimate() {
        let original = task("a", bucket: .someday, startAt: date(20))
        let scheduled = PlannerScheduling.scheduling(original, at: date(10, 14, 15), calendar: cal)
        XCTAssertEqual(scheduled.dueAt, date(10, 14, 15))
        XCTAssertEqual(scheduled.estimatedMinutes, PlannerScheduling.defaultDurationMinutes)
        XCTAssertEqual(scheduled.scheduleBucket, .anytime)
        XCTAssertNil(scheduled.startAt)
    }

    func testSchedulingKeepsAnExistingEstimateAndEarlierDeferDate() {
        let original = task("a", estimate: 90, bucket: .today, startAt: date(9))
        let scheduled = PlannerScheduling.scheduling(original, at: date(10, 14), calendar: cal)
        XCTAssertEqual(scheduled.estimatedMinutes, 90)
        XCTAssertEqual(scheduled.scheduleBucket, .today)
        XCTAssertEqual(scheduled.startAt, date(9))
    }

    func testResizeAndUnschedule() {
        let original = task("a", due: date(10, 9, 45), estimate: 30)
        XCTAssertEqual(PlannerScheduling.resizing(original, toMinutes: 75).estimatedMinutes, 75)
        let unscheduled = PlannerScheduling.unscheduling(original, calendar: cal)
        XCTAssertEqual(unscheduled.dueAt, date(10))
        XCTAssertFalse(PlannerScheduling.isScheduled(unscheduled, calendar: cal))
    }

    func testMidnightIsNotARepresentableStart() {
        XCTAssertEqual(PlannerScheduling.representableStartMinute(0, snapMinutes: 15), 15)
        XCTAssertEqual(PlannerScheduling.representableStartMinute(540, snapMinutes: 15), 540)
    }

    func testRestoringCopiesOnlyPlannerFields() {
        let snapshot = task("a", due: date(10, 9), estimate: 30, bucket: .someday)
        var current = task("a", due: date(10, 15), estimate: 60)
        current.title = "Renamed meanwhile"
        let restored = PlannerScheduling.restoring(from: snapshot, to: current)
        XCTAssertEqual(restored.dueAt, date(10, 9))
        XCTAssertEqual(restored.estimatedMinutes, 30)
        XCTAssertEqual(restored.scheduleBucket, .someday)
        XCTAssertEqual(restored.title, "Renamed meanwhile")
    }

    // MARK: - Grid

    func testGridLaysOutEventsAndTasksTogetherAndHidesMirroredEvents() {
        let meeting = CalendarEventInfo(id: "ev1", title: "Standup", start: date(10, 9), end: date(10, 10))
        let mirrored = CalendarEventInfo(id: "mirror", title: "Task a", start: date(10, 9, 30), end: date(10, 10))
        let allDay = CalendarEventInfo(id: "holiday", title: "Holiday", start: date(10), end: date(11), isAllDay: true)
        let items = PlannerGrid.items(
            events: [meeting, mirrored, allDay],
            hiddenEventIds: ["mirror"],
            tasks: [task("a", due: date(10, 9, 30))],
            day: date(10),
            calendar: cal
        )
        XCTAssertEqual(items.map(\.id), [PlannerGrid.eventItemId(meeting), PlannerGrid.taskItemId("a")])
        XCTAssertEqual(items.first?.startMinute, 540)
        XCTAssertEqual(items.first?.endMinute, 600)
        XCTAssertEqual(items.last?.startMinute, 570)
        XCTAssertEqual(items.last?.durationMinutes, 30)
        XCTAssertEqual(items.first?.placement.columnCount, 2)
        XCTAssertEqual(items.last?.placement.column, 1)

        XCTAssertEqual(PlannerGrid.allDayEvents([meeting, allDay], day: date(10), calendar: cal).map(\.id), ["holiday"])
    }

    func testGridClipsEventsCrossingMidnight() {
        let overnight = CalendarEventInfo(id: "ev", title: "Flight", start: date(9, 22), end: date(10, 2))
        let today = PlannerGrid.items(events: [overnight], hiddenEventIds: [], tasks: [], day: date(10), calendar: cal)
        XCTAssertEqual(today.first?.startMinute, 0)
        XCTAssertEqual(today.first?.endMinute, 120)

        let yesterday = PlannerGrid.items(events: [overnight], hiddenEventIds: [], tasks: [], day: date(9), calendar: cal)
        XCTAssertEqual(yesterday.first?.startMinute, 22 * 60)
        XCTAssertEqual(yesterday.first?.endMinute, 1440)

        let later = PlannerGrid.items(events: [overnight], hiddenEventIds: [], tasks: [], day: date(11), calendar: cal)
        XCTAssertTrue(later.isEmpty)
    }
}
