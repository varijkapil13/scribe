import XCTest
@testable import Scribe

final class RecurrenceRuleTests: XCTestCase {

    // MARK: - Parsing

    func testParseDailyDefault() throws {
        let rule = try RecurrenceRule.parse("FREQ=DAILY")
        XCTAssertEqual(rule.frequency, .daily)
        XCTAssertEqual(rule.interval, 1)
        XCTAssertTrue(rule.byDay.isEmpty)
        XCTAssertNil(rule.byMonthDay)
    }

    func testParseDailyWithInterval() throws {
        let rule = try RecurrenceRule.parse("FREQ=DAILY;INTERVAL=3")
        XCTAssertEqual(rule.frequency, .daily)
        XCTAssertEqual(rule.interval, 3)
    }

    func testParseWeeklyMultiDay() throws {
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY;BYDAY=MO,WE,FR")
        XCTAssertEqual(rule.frequency, .weekly)
        XCTAssertEqual(rule.byDay, [.mo, .we, .fr])
        XCTAssertNil(rule.byMonthDay)
    }

    func testParseMonthlyOrdinalPositive() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=2MO")
        XCTAssertEqual(rule.frequency, .monthly)
        XCTAssertEqual(rule.byMonthDay?.ordinal, 2)
        XCTAssertEqual(rule.byMonthDay?.weekday, .mo)
        XCTAssertTrue(rule.byDay.isEmpty)
    }

    func testParseMonthlyOrdinalNegative() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=-1FR")
        XCTAssertEqual(rule.byMonthDay?.ordinal, -1)
        XCTAssertEqual(rule.byMonthDay?.weekday, .fr)
    }

    func testParseUnknownKeysIgnored() throws {
        let rule = try RecurrenceRule.parse("FREQ=DAILY;UNTIL=20261231T000000Z")
        XCTAssertEqual(rule.frequency, .daily)
    }

    func testParseMissingFreqThrows() {
        XCTAssertThrowsError(try RecurrenceRule.parse("INTERVAL=1")) { error in
            guard case RecurrenceError.invalidRule = error else {
                XCTFail("Expected RecurrenceError.invalidRule, got \(error)")
                return
            }
        }
    }

    func testParseInvalidFreqThrows() {
        XCTAssertThrowsError(try RecurrenceRule.parse("FREQ=YEARLY")) { error in
            guard case RecurrenceError.invalidRule = error else {
                XCTFail("Expected RecurrenceError.invalidRule")
                return
            }
        }
    }

    func testParseInvalidIntervalThrows() {
        XCTAssertThrowsError(try RecurrenceRule.parse("FREQ=DAILY;INTERVAL=0"))
        XCTAssertThrowsError(try RecurrenceRule.parse("FREQ=DAILY;INTERVAL=-1"))
        XCTAssertThrowsError(try RecurrenceRule.parse("FREQ=DAILY;INTERVAL=abc"))
    }

    func testParseInvalidBydayThrows() {
        XCTAssertThrowsError(try RecurrenceRule.parse("FREQ=WEEKLY;BYDAY=XX"))
    }

    // MARK: - Serialisation round-trips

    func testRoundTripDaily() throws {
        let original = "FREQ=DAILY"
        XCTAssertEqual(try RecurrenceRule.parse(original).rruleString, original)
    }

    func testRoundTripDailyInterval() throws {
        let original = "FREQ=DAILY;INTERVAL=3"
        XCTAssertEqual(try RecurrenceRule.parse(original).rruleString, original)
    }

    func testRoundTripWeeklyMultiDay() throws {
        let original = "FREQ=WEEKLY;BYDAY=MO,WE,FR"
        XCTAssertEqual(try RecurrenceRule.parse(original).rruleString, original)
    }

    func testRoundTripMonthlyOrdinal() throws {
        let original = "FREQ=MONTHLY;BYDAY=2MO"
        XCTAssertEqual(try RecurrenceRule.parse(original).rruleString, original)
    }

    func testRoundTripMonthlyLastFriday() throws {
        let original = "FREQ=MONTHLY;BYDAY=-1FR"
        XCTAssertEqual(try RecurrenceRule.parse(original).rruleString, original)
    }
}
