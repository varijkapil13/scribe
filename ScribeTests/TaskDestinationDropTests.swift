import XCTest
@testable import Scribe

/// What dropping a task on an iOS sidebar list or list section writes.
final class TaskDestinationDropTests: XCTestCase {

    private static let cal: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    private var cal: Calendar { Self.cal }
    private var now: Date { date(11, 10) }

    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))
            ?? Date(timeIntervalSince1970: 0)
    }

    private func task(project: String? = nil, area: String? = nil, heading: String? = nil,
                      due: Date? = nil, bucket: TaskScheduleBucket = .anytime,
                      startAt: Date? = nil, completedAt: Date? = nil) -> TodoTask {
        TodoTask(id: "t", title: "T", projectId: project, dueAt: due, completedAt: completedAt,
                 startAt: startAt, scheduleBucket: bucket, areaId: area, headingId: heading)
    }

    private func updated(_ outcome: TaskDestinationDropOutcome, file: StaticString = #filePath, line: UInt = #line) -> TodoTask? {
        guard case .update(let task) = outcome else {
            XCTFail("expected .update, got \(outcome)", file: file, line: line)
            return nil
        }
        return task
    }

    // MARK: - Lists

    func testInboxUnfilesAndUnparks() {
        let source = task(project: "p", heading: "h", bucket: .someday)
        let result = updated(TaskDestinationDrop.outcome(dropping: source, onto: .inbox, calendar: cal, now: now))
        XCTAssertNil(result?.projectId)
        XCTAssertNil(result?.headingId)
        XCTAssertEqual(result?.scheduleBucket, .anytime)
        XCTAssertEqual(TaskDestinationDrop.outcome(dropping: task(), onto: .inbox, calendar: cal, now: now), .unchanged)
    }

    func testTodayPlansAndDropsDeferral() {
        let source = task(startAt: date(20))
        let result = updated(TaskDestinationDrop.outcome(dropping: source, onto: .today, calendar: cal, now: now))
        XCTAssertEqual(result?.scheduleBucket, .today)
        XCTAssertNil(result?.startAt)
        XCTAssertEqual(TaskDestinationDrop.outcome(dropping: task(bucket: .today), onto: .today, calendar: cal, now: now),
                       .unchanged)
    }

    func testSomedayAnytimeAndLogbook() {
        XCTAssertEqual(updated(TaskDestinationDrop.outcome(dropping: task(), onto: .someday, calendar: cal, now: now))?.scheduleBucket,
                       .someday)
        let parked = task(bucket: .someday, startAt: date(20))
        let anytime = updated(TaskDestinationDrop.outcome(dropping: parked, onto: .anytime, calendar: cal, now: now))
        XCTAssertEqual(anytime?.scheduleBucket, .anytime)
        XCTAssertNil(anytime?.startAt)
        XCTAssertEqual(TaskDestinationDrop.outcome(dropping: task(), onto: .logbook, calendar: cal, now: now), .complete)
        XCTAssertEqual(TaskDestinationDrop.outcome(dropping: task(completedAt: date(10)), onto: .logbook, calendar: cal, now: now),
                       .unchanged)
    }

    func testDroppingFinishedTaskOnOpenListReopensIt() {
        let result = updated(TaskDestinationDrop.outcome(dropping: task(completedAt: date(10)), onto: .today,
                                                         calendar: cal, now: now))
        XCTAssertNil(result?.completedAt)
    }

    func testProjectAndArea() {
        XCTAssertEqual(TaskDestinationDrop.outcome(dropping: task(), onto: .project("p"), calendar: cal, now: now),
                       .moveToProject("p"))
        XCTAssertEqual(TaskDestinationDrop.outcome(dropping: task(project: "p"), onto: .project("p"), calendar: cal, now: now),
                       .unchanged)
        let filed = updated(TaskDestinationDrop.outcome(dropping: task(project: "p", heading: "h"), onto: .area("a"),
                                                        calendar: cal, now: now))
        XCTAssertNil(filed?.projectId)
        XCTAssertNil(filed?.headingId)
        XCTAssertEqual(filed?.areaId, "a")
        XCTAssertEqual(TaskDestinationDrop.outcome(dropping: task(area: "a"), onto: .area("a"), calendar: cal, now: now),
                       .unchanged)
    }

    func testUpcomingAndTagDropsAreIgnored() {
        XCTAssertEqual(TaskDestinationDrop.outcome(dropping: task(), onto: .upcoming, calendar: cal, now: now), .unchanged)
        XCTAssertEqual(TaskDestinationDrop.outcome(dropping: task(), onto: .tag("x"), calendar: cal, now: now), .unchanged)
    }

    // MARK: - Sections

    func testEveningMovesOtherDayToTodayKeepingTime() {
        let source = task(due: date(14, 18, 30))
        let result = updated(TaskDestinationDrop.outcome(dropping: source, ontoSection: .evening,
                                                         calendar: cal, now: now))
        XCTAssertEqual(result?.scheduleBucket, .evening)
        XCTAssertEqual(result?.dueAt, date(11, 18, 30))
    }

    func testDaySectionReschedulesKeepingTime() {
        let timed = updated(TaskDestinationDrop.outcome(dropping: task(due: date(11, 9, 15), bucket: .evening),
                                                        ontoSection: .day(date(13)), calendar: cal, now: now))
        XCTAssertEqual(timed?.dueAt, date(13, 9, 15))
        XCTAssertEqual(timed?.scheduleBucket, .anytime)

        let undated = updated(TaskDestinationDrop.outcome(dropping: task(startAt: date(20)),
                                                          ontoSection: .day(date(13)), calendar: cal, now: now))
        XCTAssertEqual(undated?.dueAt, date(13))
        XCTAssertNil(undated?.startAt)
    }

    func testHeadingSections() {
        let heading = ProjectHeading(id: "h", projectId: "p", title: "H")
        XCTAssertEqual(TaskDestinationDrop.outcome(dropping: task(project: "p"), ontoSection: .heading(heading),
                                                   calendar: cal, now: now), .setHeading("h"))
        XCTAssertEqual(TaskDestinationDrop.outcome(dropping: task(project: "p", heading: "h"),
                                                   ontoSection: .noHeading, calendar: cal, now: now), .setHeading(nil))
        XCTAssertEqual(TaskDestinationDrop.outcome(dropping: task(), ontoSection: .overdue,
                                                   calendar: cal, now: now), .unchanged)
    }
}
