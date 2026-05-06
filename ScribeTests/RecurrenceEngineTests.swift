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
}
