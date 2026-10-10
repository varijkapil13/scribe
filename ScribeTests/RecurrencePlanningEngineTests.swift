import XCTest
@testable import Scribe

/// Recurrence extensions added with v20 task planning: YEARLY, BYMONTHDAY,
/// BYSETPOS, UNTIL, COUNT, X-SCRIBE-FROM=COMPLETION, first-occurrence
/// seeding, and wall-clock (DST-safe) arithmetic in a local calendar.
final class RecurrencePlanningEngineTests: XCTestCase {

    private func utc(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = hour; c.minute = minute; c.second = 0
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar.utcCalendar.date(from: c)!
    }

    /// A US-Eastern calendar: DST starts 2026-03-08, ends 2026-11-01.
    private var eastern: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    private func local(_ cal: Calendar, _ year: Int, _ month: Int, _ day: Int,
                       hour: Int = 9, minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func parts(_ date: Date, _ cal: Calendar) -> [Int] {
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return [c.year!, c.month!, c.day!, c.hour!, c.minute!]
    }

    // MARK: - YEARLY

    func testYearlyAdvancesOneYear() throws {
        let rule = try RecurrenceRule.parse("FREQ=YEARLY")
        XCTAssertEqual(RecurrenceEngine.nextDate(after: utc(2026, 3, 15), rule: rule), utc(2027, 3, 15))
    }

    func testYearlyIntervalTwo() throws {
        let rule = try RecurrenceRule.parse("FREQ=YEARLY;INTERVAL=2")
        XCTAssertEqual(RecurrenceEngine.nextDate(after: utc(2026, 3, 15), rule: rule), utc(2028, 3, 15))
    }

    func testYearlyFromLeapDayClampsToFebruary28() throws {
        let rule = try RecurrenceRule.parse("FREQ=YEARLY")
        XCTAssertEqual(RecurrenceEngine.nextDate(after: utc(2028, 2, 29), rule: rule), utc(2029, 2, 28))
    }

    func testYearlyLastWeekdayOfDecember() throws {
        // Yearly + BYDAY/BYSETPOS expands within the anchor's month.
        let rule = try RecurrenceRule.parse("FREQ=YEARLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1")
        // 2026-12-31 is a Thursday → 2027-12-31 is a Friday.
        XCTAssertEqual(RecurrenceEngine.nextDate(after: utc(2026, 12, 31), rule: rule), utc(2027, 12, 31))
    }

    func testYearlyKeepsWallClockInLocalCalendar() throws {
        let cal = eastern
        let rule = try RecurrenceRule.parse("FREQ=YEARLY")
        let next = RecurrenceEngine.nextDate(after: local(cal, 2026, 7, 4, hour: 9), rule: rule, calendar: cal)
        XCTAssertEqual(parts(next, cal), [2027, 7, 4, 9, 0])
    }

    // MARK: - BYMONTHDAY

    func testMonthlyByMonthDayMovesToThatDay() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYMONTHDAY=15")
        // From Jan 20 the 15th has passed this month → Feb 15.
        XCTAssertEqual(RecurrenceEngine.nextDate(after: utc(2026, 1, 20), rule: rule), utc(2026, 2, 15))
        // From Jan 10 the 15th is still ahead → Jan 15.
        XCTAssertEqual(RecurrenceEngine.nextDate(after: utc(2026, 1, 10), rule: rule), utc(2026, 1, 15))
    }

    func testMonthlyByMonthDayList() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYMONTHDAY=1,15")
        XCTAssertEqual(RecurrenceEngine.nextDate(after: utc(2026, 1, 1), rule: rule), utc(2026, 1, 15))
        XCTAssertEqual(RecurrenceEngine.nextDate(after: utc(2026, 1, 15), rule: rule), utc(2026, 2, 1))
    }

    func testMonthlyLastDayOfMonth() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYMONTHDAY=-1")
        XCTAssertEqual(RecurrenceEngine.nextDate(after: utc(2026, 1, 31), rule: rule), utc(2026, 2, 28))
        XCTAssertEqual(RecurrenceEngine.nextDate(after: utc(2026, 2, 28), rule: rule), utc(2026, 3, 31))
    }

    func testMonthlyThirtyFirstSkipsShortMonths() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYMONTHDAY=31")
        // February has no 31st → March 31.
        XCTAssertEqual(RecurrenceEngine.nextDate(after: utc(2026, 1, 31), rule: rule), utc(2026, 3, 31))
    }

    func testMonthlyByMonthDayKeepsTimeOfDay() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYMONTHDAY=10")
        XCTAssertEqual(RecurrenceEngine.nextDate(after: utc(2026, 1, 10, hour: 17, minute: 30), rule: rule),
                       utc(2026, 2, 10, hour: 17, minute: 30))
    }

    func testMonthlyByMonthDayWithInterval() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=5")
        XCTAssertEqual(RecurrenceEngine.nextDate(after: utc(2026, 1, 5), rule: rule), utc(2026, 4, 5))
    }

    // MARK: - BYSETPOS

    func testLastWeekdayOfMonth() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1")
        // Jan 2026 ends on a Saturday → last weekday Fri Jan 30.
        XCTAssertEqual(RecurrenceEngine.nextDate(after: utc(2026, 1, 5), rule: rule), utc(2026, 1, 30))
        XCTAssertEqual(RecurrenceEngine.nextDate(after: utc(2026, 1, 30), rule: rule), utc(2026, 2, 27))
        XCTAssertEqual(RecurrenceEngine.nextDate(after: utc(2026, 2, 27), rule: rule), utc(2026, 3, 31))
    }

    func testFirstWeekdayOfMonth() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=1")
        // Feb 1 2026 is a Sunday → first weekday Mon Feb 2.
        XCTAssertEqual(RecurrenceEngine.nextDate(after: utc(2026, 1, 1), rule: rule), utc(2026, 2, 2))
    }

    func testSecondToLastFriday() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=FR;BYSETPOS=-2")
        // May 2026 Fridays: 1, 8, 15, 22, 29 → second-to-last is May 22.
        XCTAssertEqual(RecurrenceEngine.nextDate(after: utc(2026, 5, 1), rule: rule), utc(2026, 5, 22))
    }

    func testCandidateDaysAppliesSetPosAfterFilters() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=1,-1")
        let days = RecurrenceEngine.candidateDays(inMonthOf: utc(2026, 10, 15), rule: rule,
                                                  calendar: .utcCalendar)
        XCTAssertEqual(days, [1, 30])
    }

    func testLastWeekdayIsDSTSafe() throws {
        let cal = eastern
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1")
        // Feb 27 (EST) → Mar 31 (EDT): still 09:00 wall-clock.
        let next = RecurrenceEngine.nextDate(after: local(cal, 2026, 2, 27), rule: rule, calendar: cal)
        XCTAssertEqual(parts(next, cal), [2026, 3, 31, 9, 0])
    }

    // MARK: - DST-safe basics in a local calendar

    func testDailyAcrossSpringForwardKeepsNineAM() throws {
        let cal = eastern
        let rule = try RecurrenceRule.parse("FREQ=DAILY")
        let due = local(cal, 2026, 3, 7)
        let next = RecurrenceEngine.nextDate(after: due, rule: rule, calendar: cal)
        XCTAssertEqual(parts(next, cal), [2026, 3, 8, 9, 0])
        // Only 23 real hours elapsed — wall-clock, not fixed-interval, math.
        XCTAssertEqual(next.timeIntervalSince(due), 23 * 3600)
    }

    func testWeeklyAcrossFallBackKeepsNineAM() throws {
        let cal = eastern
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY")
        let next = RecurrenceEngine.nextDate(after: local(cal, 2026, 10, 30), rule: rule, calendar: cal)
        XCTAssertEqual(parts(next, cal), [2026, 11, 6, 9, 0])
    }

    // MARK: - UNTIL

    func testUntilEndsSeries() throws {
        let rule = try RecurrenceRule.parse("FREQ=DAILY;UNTIL=20260110T235959Z")
        let cal = Calendar.utcCalendar
        let ongoing = RecurrenceEngine.nextOccurrence(dueAt: utc(2026, 1, 9), completedAt: utc(2026, 1, 9),
                                                      rule: rule, calendar: cal)
        XCTAssertEqual(ongoing?.dueAt, utc(2026, 1, 10))
        let ended = RecurrenceEngine.nextOccurrence(dueAt: utc(2026, 1, 10), completedAt: utc(2026, 1, 10),
                                                    rule: rule, calendar: cal)
        XCTAssertNil(ended)
    }

    func testDateOnlyUntilIsInclusiveOfThatDay() throws {
        let rule = try RecurrenceRule.parse("FREQ=DAILY;UNTIL=20260110")
        let step = RecurrenceEngine.nextOccurrence(dueAt: utc(2026, 1, 9, hour: 18), completedAt: utc(2026, 1, 9),
                                                   rule: rule, calendar: .utcCalendar)
        XCTAssertEqual(step?.dueAt, utc(2026, 1, 10, hour: 18))
    }

    // MARK: - COUNT

    func testCountDecrementsAndEnds() throws {
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY;COUNT=2")
        let cal = Calendar.utcCalendar
        let first = try XCTUnwrap(RecurrenceEngine.nextOccurrence(dueAt: utc(2026, 1, 5), completedAt: utc(2026, 1, 5),
                                                                  rule: rule, calendar: cal))
        XCTAssertEqual(first.dueAt, utc(2026, 1, 12))
        XCTAssertEqual(first.rule.count, 1)
        XCTAssertEqual(first.rule.rruleString, "FREQ=WEEKLY;COUNT=1")
        // The COUNT=1 occurrence is the last one.
        XCTAssertNil(RecurrenceEngine.nextOccurrence(dueAt: first.dueAt, completedAt: first.dueAt,
                                                     rule: first.rule, calendar: cal))
    }

    func testRuleWithoutBoundsKeepsRuleUnchanged() throws {
        let rule = try RecurrenceRule.parse("FREQ=DAILY;INTERVAL=2")
        let step = RecurrenceEngine.nextOccurrence(dueAt: utc(2026, 1, 1), completedAt: utc(2026, 1, 1),
                                                   rule: rule, calendar: .utcCalendar)
        XCTAssertEqual(step?.rule, rule)
        XCTAssertEqual(step?.dueAt, utc(2026, 1, 3))
    }

    // MARK: - After completion

    func testAfterCompletionSchedulesFromCompletionDay() throws {
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=2;X-SCRIBE-FROM=COMPLETION")
        // Due Mon Jan 5 09:00, done late on Wed Jan 14 → Wed Jan 28 at 09:00.
        let step = RecurrenceEngine.nextOccurrence(dueAt: utc(2026, 1, 5, hour: 9),
                                                   completedAt: utc(2026, 1, 14, hour: 15),
                                                   rule: rule, calendar: .utcCalendar)
        XCTAssertEqual(step?.dueAt, utc(2026, 1, 28, hour: 9))
    }

    func testAfterCompletionEarlyCompletion() throws {
        let rule = try RecurrenceRule.parse("FREQ=DAILY;INTERVAL=3;X-SCRIBE-FROM=COMPLETION")
        // Done two days early: the next one counts from the completion day.
        let step = RecurrenceEngine.nextOccurrence(dueAt: utc(2026, 1, 10, hour: 8),
                                                   completedAt: utc(2026, 1, 8, hour: 20),
                                                   rule: rule, calendar: .utcCalendar)
        XCTAssertEqual(step?.dueAt, utc(2026, 1, 11, hour: 8))
    }

    func testScheduleAnchoredIgnoresCompletionDate() throws {
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=2")
        let step = RecurrenceEngine.nextOccurrence(dueAt: utc(2026, 1, 5, hour: 9),
                                                   completedAt: utc(2026, 1, 14, hour: 15),
                                                   rule: rule, calendar: .utcCalendar)
        XCTAssertEqual(step?.dueAt, utc(2026, 1, 19, hour: 9))
    }

    func testAfterCompletionAcrossFallBackIsDSTSafe() throws {
        let cal = eastern
        let rule = try RecurrenceRule.parse("FREQ=DAILY;INTERVAL=3;X-SCRIBE-FROM=COMPLETION")
        let step = RecurrenceEngine.nextOccurrence(dueAt: local(cal, 2026, 10, 30, hour: 9),
                                                   completedAt: local(cal, 2026, 10, 31, hour: 20),
                                                   rule: rule, calendar: cal)
        XCTAssertEqual(parts(try XCTUnwrap(step?.dueAt), cal), [2026, 11, 3, 9, 0])
    }

    // MARK: - First occurrence (quick-add seeding)

    func testFirstOccurrencePlainRuleStartsThatDay() throws {
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=2")
        XCTAssertEqual(RecurrenceEngine.firstOccurrence(onOrAfter: utc(2026, 10, 10, hour: 14), rule: rule,
                                                        calendar: .utcCalendar),
                       utc(2026, 10, 10))
    }

    func testFirstOccurrenceWeeklyByDayIncludesToday() throws {
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=2;BYDAY=SA")
        // 2026-10-10 is a Saturday → today; interval doesn't push it out.
        XCTAssertEqual(RecurrenceEngine.firstOccurrence(onOrAfter: utc(2026, 10, 10), rule: rule,
                                                        calendar: .utcCalendar),
                       utc(2026, 10, 10))
        let monday = try RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO")
        XCTAssertEqual(RecurrenceEngine.firstOccurrence(onOrAfter: utc(2026, 10, 10), rule: monday,
                                                        calendar: .utcCalendar),
                       utc(2026, 10, 12))
    }

    func testFirstOccurrenceMonthlyOrdinalUsesCurrentMonth() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=-1FR")
        // Last Friday of Oct 2026 is the 30th.
        XCTAssertEqual(RecurrenceEngine.firstOccurrence(onOrAfter: utc(2026, 10, 10), rule: rule,
                                                        calendar: .utcCalendar),
                       utc(2026, 10, 30))
    }
}
