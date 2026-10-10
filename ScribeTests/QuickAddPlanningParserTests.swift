import XCTest
@testable import Scribe

/// Quick-add planning phrases: recurrence ("every …", "after completion",
/// "until …", "for N times"), start dates ("starting …"), when-buckets
/// ("someday", "this evening") and durations ("~30m", "for 1h"). Uses a
/// fixed `now` (Sat 2026-10-10 10:00) and no NSDataDetector so results are
/// deterministic.
final class QuickAddPlanningParserTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 10))!
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func parse(_ text: String) -> QuickAddParser.ParsedQuickAdd {
        QuickAddParser.parse(text, detector: nil, now: now, calendar: calendar)
    }

    private func rule(_ parsed: QuickAddParser.ParsedQuickAdd) throws -> RecurrenceRule {
        try RecurrenceRule.parse(try XCTUnwrap(parsed.recurrenceRule))
    }

    // MARK: - Recurrence

    func testEveryYear() throws {
        let parsed = parse("Renew passport every year")
        XCTAssertEqual(parsed.title, "Renew passport")
        XCTAssertEqual(parsed.recurrenceRule, "FREQ=YEARLY")
        // Recurring tasks always get a due date: today when no BY* pattern.
        XCTAssertEqual(parsed.dueAt, day(2026, 10, 10))
    }

    func testEveryTwoWeeksAfterCompletion() throws {
        let parsed = parse("Water plants every 2 weeks after completion")
        XCTAssertEqual(parsed.title, "Water plants")
        XCTAssertEqual(parsed.recurrenceRule, "FREQ=WEEKLY;INTERVAL=2;X-SCRIBE-FROM=COMPLETION")
    }

    func testEveryOtherDay() throws {
        XCTAssertEqual(parse("Run every other day").recurrenceRule, "FREQ=DAILY;INTERVAL=2")
    }

    func testEveryMonth() throws {
        XCTAssertEqual(parse("Pay rent every month").recurrenceRule, "FREQ=MONTHLY")
    }

    func testEveryWeekdayList() throws {
        let parsed = parse("Gym every mon, wed and fri")
        XCTAssertEqual(parsed.title, "Gym")
        XCTAssertEqual(parsed.recurrenceRule, "FREQ=WEEKLY;BYDAY=MO,WE,FR")
        // First matching day after Sat Oct 10 is Mon Oct 12.
        XCTAssertEqual(parsed.dueAt, day(2026, 10, 12))
    }

    func testEveryWeekday() throws {
        let parsed = parse("Standup every weekday")
        XCTAssertEqual(parsed.recurrenceRule, "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
        XCTAssertEqual(parsed.title, "Standup")
    }

    func testEveryLastWeekdayOfTheMonth() throws {
        let parsed = parse("Invoice clients every last weekday of the month")
        XCTAssertEqual(parsed.title, "Invoice clients")
        XCTAssertEqual(parsed.recurrenceRule, "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1")
        XCTAssertEqual(parsed.dueAt, day(2026, 10, 30))
    }

    func testEverySecondTuesday() throws {
        let parsed = parse("Board meeting every 2nd tuesday")
        XCTAssertEqual(parsed.recurrenceRule, "FREQ=MONTHLY;BYDAY=2TU")
        // Oct 2026 Tuesdays: 6, 13 → the 13th.
        XCTAssertEqual(parsed.dueAt, day(2026, 10, 13))
    }

    func testEveryLastDayOfMonth() throws {
        XCTAssertEqual(parse("Backup every last day of the month").recurrenceRule,
                       "FREQ=MONTHLY;BYMONTHDAY=-1")
    }

    func testUntilMonthDay() throws {
        let parsed = parse("Stretch every day until Dec 31")
        XCTAssertEqual(parsed.title, "Stretch")
        let r = try rule(parsed)
        XCTAssertEqual(r.frequency, .daily)
        let until = try XCTUnwrap(r.until)
        // Inclusive: the very end of Dec 31 (local).
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: until)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2026, 12, 31, 23, 59])
    }

    func testUntilPastMonthDayRollsToNextYear() throws {
        let r = try rule(parse("Read every week until March 1"))
        let c = calendar.dateComponents([.year, .month, .day], from: try XCTUnwrap(r.until))
        XCTAssertEqual([c.year, c.month, c.day], [2027, 3, 1])
    }

    func testForNTimes() throws {
        let parsed = parse("Physio every week for 5 times")
        XCTAssertEqual(parsed.title, "Physio")
        XCTAssertEqual(parsed.recurrenceRule, "FREQ=WEEKLY;COUNT=5")
    }

    func testModifiersWithoutRecurrenceStayInTitle() {
        let parsed = parse("Review after completion of draft")
        XCTAssertNil(parsed.recurrenceRule)
        XCTAssertEqual(parsed.title, "Review after completion of draft")
    }

    func testEveryWordInsideTitleDoesNotRecurWithoutUnit() {
        let parsed = parse("Read everything")
        XCTAssertNil(parsed.recurrenceRule)
        XCTAssertEqual(parsed.title, "Read everything")
    }

    // MARK: - Start dates

    func testStartingFriday() {
        let parsed = parse("Prep slides starting friday")
        XCTAssertEqual(parsed.title, "Prep slides")
        XCTAssertEqual(parsed.startAt, day(2026, 10, 16))
        XCTAssertNil(parsed.dueAt)
    }

    func testStartingSameWeekdayMeansNextWeek() {
        // Today is Saturday: "starting saturday" defers a full week.
        XCTAssertEqual(parse("Clean garage starting saturday").startAt, day(2026, 10, 17))
    }

    func testStartingTomorrowAndIsoDate() {
        XCTAssertEqual(parse("A starting tomorrow").startAt, day(2026, 10, 11))
        XCTAssertEqual(parse("B starts on 2026-11-02").startAt, day(2026, 11, 2))
        XCTAssertEqual(parse("C starting in 3 days").startAt, day(2026, 10, 13))
    }

    func testRecurringWithStartSeedsFirstOccurrenceFromStart() {
        let parsed = parse("Review budget every month starting Nov 1")
        XCTAssertEqual(parsed.startAt, day(2026, 11, 1))
        XCTAssertEqual(parsed.dueAt, day(2026, 11, 1))
        XCTAssertEqual(parsed.recurrenceRule, "FREQ=MONTHLY")
    }

    // MARK: - Buckets

    func testSomeday() {
        let parsed = parse("Learn piano someday")
        XCTAssertEqual(parsed.title, "Learn piano")
        XCTAssertEqual(parsed.scheduleBucket, .someday)
    }

    func testThisEveningAndTonight() {
        let evening = parse("Call mom this evening")
        XCTAssertEqual(evening.title, "Call mom")
        XCTAssertEqual(evening.scheduleBucket, .evening)
        XCTAssertEqual(parse("Pack bag tonight").scheduleBucket, .evening)
    }

    // MARK: - Durations

    func testTildeMinutes() {
        let parsed = parse("Email Sam ~30m")
        XCTAssertEqual(parsed.title, "Email Sam")
        XCTAssertEqual(parsed.estimatedMinutes, 30)
    }

    func testForOneHour() {
        let parsed = parse("Deep work for 1h")
        XCTAssertEqual(parsed.title, "Deep work")
        XCTAssertEqual(parsed.estimatedMinutes, 60)
    }

    func testCompoundAndFractionalHours() {
        XCTAssertEqual(parse("Write ~1h30m").estimatedMinutes, 90)
        XCTAssertEqual(parse("Write ~1.5h").estimatedMinutes, 90)
        XCTAssertEqual(parse("Write for 2 hours").estimatedMinutes, 120)
        XCTAssertEqual(parse("Write for 45 min").estimatedMinutes, 45)
    }

    func testDurationNeedsUnit() {
        let parsed = parse("Buy ~3 apples")
        XCTAssertNil(parsed.estimatedMinutes)
        XCTAssertEqual(parsed.title, "Buy ~3 apples")
    }

    // MARK: - Combined

    func testEverythingAtOnce() throws {
        let parsed = parse("Plan sprint every 2 weeks after completion starting monday ~45m #work +Team !high")
        XCTAssertEqual(parsed.title, "Plan sprint")
        XCTAssertEqual(parsed.tags, ["work"])
        XCTAssertEqual(parsed.projectName, "Team")
        XCTAssertEqual(parsed.priority, .high)
        XCTAssertEqual(parsed.estimatedMinutes, 45)
        XCTAssertEqual(parsed.startAt, day(2026, 10, 12))
        XCTAssertEqual(parsed.dueAt, day(2026, 10, 12))
        let r = try rule(parsed)
        XCTAssertEqual(r.frequency, .weekly)
        XCTAssertEqual(r.interval, 2)
        XCTAssertTrue(r.fromCompletion)
    }

    func testPlanningPhrasesAreHighlighted() {
        let text = "Gym every monday ~30m someday"
        let ranges = QuickAddPlanningParser.ranges(in: text).map { String(text[$0]) }
        XCTAssertTrue(ranges.contains("every monday"))
        XCTAssertTrue(ranges.contains("~30m"))
        XCTAssertTrue(ranges.contains("someday"))
    }

    // MARK: - Date phrase resolution

    func testResolveDatePhrases() {
        let resolve = { (phrase: String) in
            QuickAddPlanningParser.resolveDate(phrase, now: self.now, calendar: self.calendar)
        }
        XCTAssertEqual(resolve("today"), day(2026, 10, 10))
        XCTAssertEqual(resolve("tmr"), day(2026, 10, 11))
        XCTAssertEqual(resolve("next week"), day(2026, 10, 17))
        XCTAssertEqual(resolve("next friday"), day(2026, 10, 16))
        XCTAssertEqual(resolve("December 31st, 2027"), day(2027, 12, 31))
        XCTAssertNil(resolve("Feb 30"))
        XCTAssertNil(resolve("someday"))
    }
}
