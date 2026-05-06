import XCTest
@testable import Scribe

final class RecurrenceEngineTests: XCTestCase {

    private func utc(_ year: Int, _ month: Int, _ day: Int,
                     hour: Int = 0, minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = hour; c.minute = minute; c.second = 0
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar.utcCalendar.date(from: c)!
    }

    // MARK: - DAILY

    func testDailyAdvancesByOneDay() throws {
        let rule = try RecurrenceRule.parse("FREQ=DAILY")
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 1), rule: rule)
        XCTAssertEqual(next, utc(2026, 1, 2))
    }

    func testDailyWithIntervalThree() throws {
        let rule = try RecurrenceRule.parse("FREQ=DAILY;INTERVAL=3")
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 1), rule: rule)
        XCTAssertEqual(next, utc(2026, 1, 4))
    }

    func testDailyAcrossMonthBoundary() throws {
        let rule = try RecurrenceRule.parse("FREQ=DAILY")
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 31), rule: rule)
        XCTAssertEqual(next, utc(2026, 2, 1))
    }

    func testDailyAcrossYearBoundary() throws {
        let rule = try RecurrenceRule.parse("FREQ=DAILY")
        let next = RecurrenceEngine.nextDate(after: utc(2025, 12, 31), rule: rule)
        XCTAssertEqual(next, utc(2026, 1, 1))
    }

    // MARK: - WEEKLY

    func testWeeklySingleDayAdvancesByOneWeek() throws {
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY")
        // Monday 2026-01-05 → Monday 2026-01-12
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 5), rule: rule)
        XCTAssertEqual(next, utc(2026, 1, 12))
    }

    func testWeeklyIntervalTwoAdvancesByTwoWeeks() throws {
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=2")
        // Monday 2026-01-05 → Monday 2026-01-19
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 5), rule: rule)
        XCTAssertEqual(next, utc(2026, 1, 19))
    }

    func testWeeklyMultiDayAdvancesWithinWeek() throws {
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY;BYDAY=MO,WE,FR")
        // Monday 2026-01-05 → Wednesday 2026-01-07
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 5), rule: rule)
        XCTAssertEqual(next, utc(2026, 1, 7))
    }

    func testWeeklyMultiDayAdvancesWithinWeekMidWeek() throws {
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY;BYDAY=MO,WE,FR")
        // Wednesday 2026-01-07 → Friday 2026-01-09
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 7), rule: rule)
        XCTAssertEqual(next, utc(2026, 1, 9))
    }

    func testWeeklyMultiDayWrapsToNextWeek() throws {
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY;BYDAY=MO,WE,FR")
        // Friday 2026-01-09 → Monday 2026-01-12
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 9), rule: rule)
        XCTAssertEqual(next, utc(2026, 1, 12))
    }

    func testWeeklyMultiDayIntervalTwoWraps() throws {
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR")
        // Friday 2026-01-09 → Monday 2026-01-19 (skip week of Jan 12)
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 9), rule: rule)
        XCTAssertEqual(next, utc(2026, 1, 19))
    }

    func testWeeklyAcrossDSTSpringForward() throws {
        // US clocks spring forward 2026-03-08. Stored in UTC → no shift.
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY")
        let next = RecurrenceEngine.nextDate(after: utc(2026, 3, 7, hour: 2), rule: rule)
        XCTAssertEqual(next, utc(2026, 3, 14, hour: 2))
    }

    func testWeeklyAcrossDSTFallBack() throws {
        // US clocks fall back 2026-11-01. Stored in UTC → no shift.
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY")
        let next = RecurrenceEngine.nextDate(after: utc(2026, 10, 31, hour: 1), rule: rule)
        XCTAssertEqual(next, utc(2026, 11, 7, hour: 1))
    }

    // MARK: - MONTHLY

    func testMonthlyDayOfMonthAdvancesByOneMonth() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY")
        // 2026-01-15 → 2026-02-15
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 15), rule: rule)
        XCTAssertEqual(next, utc(2026, 2, 15))
    }

    func testMonthlyDayOfMonthIntervalTwo() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;INTERVAL=2")
        // 2026-01-15 → 2026-03-15
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 15), rule: rule)
        XCTAssertEqual(next, utc(2026, 3, 15))
    }

    func testMonthlyOrdinalSecondMonday() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=2MO")
        // Jan 2026: 2nd Monday = Jan 12. From Jan 12 → Feb 2026 2nd Monday = Feb 9.
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 12), rule: rule)
        XCTAssertEqual(next, utc(2026, 2, 9))
    }

    func testMonthlyOrdinalFirstWednesday() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=1WE")
        // Feb 2026: 1st Wednesday = Feb 4. From Feb 4 → Mar 4 (1st Wed of March).
        let next = RecurrenceEngine.nextDate(after: utc(2026, 2, 4), rule: rule)
        XCTAssertEqual(next, utc(2026, 3, 4))
    }

    func testMonthlyOrdinalLastFriday() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=-1FR")
        // Jan 2026 last Friday = Jan 30. → Feb 2026 last Friday = Feb 27.
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 30), rule: rule)
        XCTAssertEqual(next, utc(2026, 2, 27))
    }

    func testMonthlyOrdinalLastFridayFebruaryToMarch() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=-1FR")
        // Feb 2026 last Friday = Feb 27 → Mar 2026 last Friday = Mar 27.
        let next = RecurrenceEngine.nextDate(after: utc(2026, 2, 27), rule: rule)
        XCTAssertEqual(next, utc(2026, 3, 27))
    }

    func testMonthlyIntervalTwoOrdinal() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;INTERVAL=2;BYDAY=1MO")
        // Jan 2026 1st Monday = Jan 5 → skip Feb → Mar 2 (1st Mon of March).
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 5), rule: rule)
        XCTAssertEqual(next, utc(2026, 3, 2))
    }

    func testMonthlyFifthWeekdaySkipsMonthsWithoutIt() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=5MO")
        // Jan 2026 has 5 Mondays (Jan 5, 12, 19, 26 — wait, need to verify)
        // Jan 2026: Mon 5, 12, 19, 26 — only 4 Mondays. So from Jan 26 we need
        // to find the next month with a 5th Monday.
        // Feb 2026: Mon 2, 9, 16, 23 — 4 Mondays, no 5th.
        // Mar 2026: Mon 2, 9, 16, 23, 30 — 5 Mondays! Mar 30 is the 5th Monday.
        let next = RecurrenceEngine.nextDate(after: utc(2026, 1, 26), rule: rule)
        XCTAssertEqual(next, utc(2026, 3, 30))
    }

    func testMonthlyFifthWeekdayResultStaysInTargetMonth() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=5FR")
        // May 2026: Fri 1, 8, 15, 22, 29 — 5 Fridays. From May 29 →
        // Jun 2026: Fri 5, 12, 19, 26 — only 4. Skip.
        // Jul 2026: Fri 3, 10, 17, 24, 31 — 5 Fridays. Jul 31 is the 5th.
        let next = RecurrenceEngine.nextDate(after: utc(2026, 5, 29), rule: rule)
        XCTAssertEqual(next, utc(2026, 7, 31))
    }
}
