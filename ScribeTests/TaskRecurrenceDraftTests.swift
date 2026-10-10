import XCTest
@testable import Scribe

/// The iOS repeat editor's draft: reading rules, writing them back, and
/// flagging rules it can't represent.
final class TaskRecurrenceDraftTests: XCTestCase {

    private static let cal: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    private var cal: Calendar { Self.cal }

    /// Wednesday, 2026-03-11.
    private var anchor: Date {
        cal.date(from: DateComponents(year: 2026, month: 3, day: 11, hour: 9)) ?? Date(timeIntervalSince1970: 0)
    }

    private func draft(_ rrule: String) throws -> TaskRecurrenceDraft {
        try XCTUnwrap(TaskRecurrenceDraft(rrule: rrule, anchor: anchor, calendar: cal))
    }

    func testFreshDraftIsWeeklyOnAnchorWeekday() {
        let fresh = TaskRecurrenceDraft(anchor: anchor, calendar: cal)
        XCTAssertEqual(fresh.rruleString, "FREQ=WEEKLY;BYDAY=WE")
        XCTAssertEqual(fresh.ordinal, 2)
        XCTAssertEqual(fresh.monthDay, 11)
    }

    func testRoundTripsSupportedRules() throws {
        let rules = [
            "FREQ=DAILY",
            "FREQ=DAILY;INTERVAL=3",
            "FREQ=WEEKLY;BYDAY=MO,WE,FR",
            "FREQ=MONTHLY;BYMONTHDAY=15",
            "FREQ=MONTHLY;BYMONTHDAY=-1",
            "FREQ=MONTHLY;BYDAY=-1FR",
            "FREQ=YEARLY;INTERVAL=2",
            "FREQ=WEEKLY;COUNT=5",
            "FREQ=MONTHLY;UNTIL=20261231T235959Z",
            "FREQ=WEEKLY;INTERVAL=2;X-SCRIBE-FROM=COMPLETION",
        ]
        for raw in rules {
            let parsed = try RecurrenceRule.parse(raw)
            let edited = try draft(raw)
            XCTAssertFalse(edited.isLossy, raw)
            XCTAssertTrue(TaskRecurrenceDraft.isEquivalent(edited.rule(), parsed), raw)
        }
    }

    func testWeekdayOrderDoesNotCountAsLoss() throws {
        let edited = try draft("FREQ=WEEKLY;BYDAY=FR,MO")
        XCTAssertFalse(edited.isLossy)
        XCTAssertEqual(edited.rruleString, "FREQ=WEEKLY;BYDAY=MO,FR")
    }

    func testUnsupportedPartsAreFlagged() throws {
        XCTAssertTrue(try draft("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1").isLossy)
        XCTAssertTrue(try draft("FREQ=MONTHLY;BYMONTHDAY=1,15").isLossy)
        XCTAssertTrue(try draft("FREQ=DAILY;BYDAY=MO").isLossy)
    }

    func testReadsEndsAndCompletion() throws {
        let counted = try draft("FREQ=DAILY;COUNT=4;X-SCRIBE-FROM=COMPLETION")
        XCTAssertEqual(counted.endMode, .count)
        XCTAssertEqual(counted.count, 4)
        XCTAssertTrue(counted.fromCompletion)

        let until = try draft("FREQ=WEEKLY;UNTIL=20261231")
        XCTAssertEqual(until.endMode, .until)
        XCTAssertNil(until.rule().count)
        XCTAssertNotNil(until.rule().until)
    }

    func testEditsProduceRules() {
        var edited = TaskRecurrenceDraft(anchor: anchor, calendar: cal)
        edited.frequency = .monthly
        edited.monthPattern = .ordinalWeekday
        edited.ordinal = 2
        edited.ordinalWeekday = .tu
        edited.endMode = .count
        edited.count = 0
        XCTAssertEqual(edited.rruleString, "FREQ=MONTHLY;BYDAY=2TU;COUNT=1")

        edited.monthPattern = .dayOfMonth
        edited.monthDay = 40
        edited.endMode = .never
        edited.interval = 0
        XCTAssertEqual(edited.rruleString, "FREQ=MONTHLY;BYMONTHDAY=31")

        edited.frequency = .yearly
        edited.monthPattern = .sameDay
        edited.fromCompletion = true
        XCTAssertEqual(edited.rruleString, "FREQ=YEARLY;X-SCRIBE-FROM=COMPLETION")
    }

    func testPresets() {
        XCTAssertEqual(TaskRecurrenceDraft.preset(.weekdays, anchor: anchor, calendar: cal).rruleString,
                       "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
        XCTAssertEqual(TaskRecurrenceDraft.preset(.daily, anchor: anchor, calendar: cal).rruleString, "FREQ=DAILY")
        XCTAssertEqual(TaskRecurrenceDraft.preset(.monthly, anchor: anchor, calendar: cal).rruleString, "FREQ=MONTHLY")
    }

    func testHelpers() {
        XCTAssertEqual(TaskRecurrenceDraft.ordinal(forDay: 1), 1)
        XCTAssertEqual(TaskRecurrenceDraft.ordinal(forDay: 8), 2)
        XCTAssertEqual(TaskRecurrenceDraft.ordinal(forDay: 29), -1)
        XCTAssertEqual(TaskRecurrenceDraft.clampedOrdinal(7), 4)
        let end = TaskRecurrenceDraft.endOfDay(anchor, calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: end), 23)
        XCTAssertEqual(cal.component(.second, from: end), 59)
        XCTAssertTrue(cal.isDate(end, inSameDayAs: anchor))
        XCTAssertNil(TaskRecurrenceDraft(rrule: nil, anchor: anchor, calendar: cal))
        XCTAssertNil(TaskRecurrenceDraft(rrule: "garbage", anchor: anchor, calendar: cal))
    }
}
