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
}
