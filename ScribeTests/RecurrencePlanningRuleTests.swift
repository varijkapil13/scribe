import XCTest
@testable import Scribe

/// Parsing / serialisation of the RRULE parts added with v20 task planning.
final class RecurrencePlanningRuleTests: XCTestCase {

    private func utc(_ year: Int, _ month: Int, _ day: Int, _ h: Int = 0, _ m: Int = 0, _ s: Int = 0) -> Date {
        Calendar.utcCalendar.date(from: DateComponents(year: year, month: month, day: day,
                                                       hour: h, minute: m, second: s))!
    }

    func testParseYearly() throws {
        let rule = try RecurrenceRule.parse("FREQ=YEARLY;INTERVAL=2")
        XCTAssertEqual(rule.frequency, .yearly)
        XCTAssertEqual(rule.interval, 2)
    }

    func testParseUntilDateTime() throws {
        let rule = try RecurrenceRule.parse("FREQ=DAILY;UNTIL=20261231T235959Z")
        XCTAssertEqual(rule.until, utc(2026, 12, 31, 23, 59, 59))
    }

    func testParseUntilDateOnlyMeansEndOfDay() throws {
        let rule = try RecurrenceRule.parse("FREQ=DAILY;UNTIL=20261231")
        XCTAssertEqual(rule.until, utc(2026, 12, 31, 23, 59, 59))
    }

    func testParseCount() throws {
        XCTAssertEqual(try RecurrenceRule.parse("FREQ=WEEKLY;COUNT=5").count, 5)
        XCTAssertThrowsError(try RecurrenceRule.parse("FREQ=WEEKLY;COUNT=0"))
        XCTAssertThrowsError(try RecurrenceRule.parse("FREQ=WEEKLY;COUNT=x"))
    }

    func testCountAndUntilTogetherKeepUntil() throws {
        // RFC 5545 forbids both; normalise (UNTIL wins) rather than reject.
        let rule = try RecurrenceRule.parse("FREQ=DAILY;COUNT=3;UNTIL=20261231")
        XCTAssertNil(rule.count)
        XCTAssertEqual(rule.until, utc(2026, 12, 31, 23, 59, 59))
    }

    func testParseByMonthDayList() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYMONTHDAY=1,15,-1")
        XCTAssertEqual(rule.byMonthDay, [1, 15, -1])
        XCTAssertThrowsError(try RecurrenceRule.parse("FREQ=MONTHLY;BYMONTHDAY=0"))
        XCTAssertThrowsError(try RecurrenceRule.parse("FREQ=MONTHLY;BYMONTHDAY=32"))
    }

    func testParseBySetPos() throws {
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1")
        XCTAssertEqual(rule.bySetPos, [-1])
        XCTAssertEqual(rule.byDay, [.mo, .tu, .we, .th, .fr])
    }

    func testBySetPosWithoutSetIsDropped() throws {
        XCTAssertEqual(try RecurrenceRule.parse("FREQ=MONTHLY;BYSETPOS=-1").rruleString, "FREQ=MONTHLY")
    }

    func testMonthScopedPartsIgnoredForWeekly() throws {
        // Legacy rules (written when these parts were ignored) still parse.
        XCTAssertEqual(try RecurrenceRule.parse("FREQ=WEEKLY;BYMONTHDAY=3").rruleString, "FREQ=WEEKLY")
        XCTAssertEqual(try RecurrenceRule.parse("FREQ=WEEKLY;BYDAY=MO;BYSETPOS=1").rruleString,
                       "FREQ=WEEKLY;BYDAY=MO")
        XCTAssertNil(try RecurrenceRule.parse("FREQ=WEEKLY;BYDAY=2MO").byOrdinalWeekday)
    }

    func testParseFromCompletionExtension() throws {
        XCTAssertTrue(try RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=2;X-SCRIBE-FROM=COMPLETION").fromCompletion)
        XCTAssertFalse(try RecurrenceRule.parse("FREQ=WEEKLY;X-SCRIBE-FROM=SCHEDULE").fromCompletion)
        XCTAssertFalse(try RecurrenceRule.parse("FREQ=WEEKLY").fromCompletion)
    }

    func testParseIsCaseInsensitiveAndAcceptsRRulePrefix() throws {
        let rule = try RecurrenceRule.parse("RRULE:freq=monthly;byday=-1fr")
        XCTAssertEqual(rule.frequency, .monthly)
        XCTAssertEqual(rule.byOrdinalWeekday?.ordinal, -1)
        XCTAssertEqual(rule.byOrdinalWeekday?.weekday, .fr)
    }

    // MARK: - Round trips

    func testRoundTrips() throws {
        let rules = [
            "FREQ=YEARLY",
            "FREQ=YEARLY;INTERVAL=2",
            "FREQ=MONTHLY;BYMONTHDAY=1,15",
            "FREQ=MONTHLY;BYMONTHDAY=-1",
            "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1",
            "FREQ=WEEKLY;COUNT=5",
            "FREQ=DAILY;UNTIL=20261231T235959Z",
            "FREQ=WEEKLY;INTERVAL=2;X-SCRIBE-FROM=COMPLETION",
            "FREQ=MONTHLY;BYDAY=2TU;COUNT=3;X-SCRIBE-FROM=COMPLETION",
        ]
        for raw in rules {
            XCTAssertEqual(try RecurrenceRule.parse(raw).rruleString, raw, raw)
        }
    }

    func testBuiltRuleSerialises() {
        let rule = RecurrenceRule(frequency: .monthly, byDay: RecurrenceRule.Weekday.weekdays, bySetPos: [-1])
        XCTAssertEqual(rule.rruleString, "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1")
    }

    // MARK: - Summary

    func testSummary() throws {
        XCTAssertEqual(try RecurrenceRule.parse("FREQ=YEARLY").summary, "Every year")
        XCTAssertEqual(try RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=2;X-SCRIBE-FROM=COMPLETION").summary,
                       "Every 2 weeks · after completion")
        XCTAssertEqual(try RecurrenceRule.parse("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR").summary,
                       "Every week on weekdays")
        XCTAssertEqual(try RecurrenceRule.parse("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1").summary,
                       "Every month on the last weekday")
        XCTAssertEqual(try RecurrenceRule.parse("FREQ=WEEKLY;COUNT=3").summary, "Every week · 3 left")
    }
}
