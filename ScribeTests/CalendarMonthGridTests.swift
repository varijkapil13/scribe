// ScribeTests/CalendarMonthGridTests.swift
import XCTest
@testable import Scribe

/// Locks down the locale-aware month grid math. The original duplicated
/// copies hardcoded `weekday - 1` (Sunday-first), which broke any locale
/// where firstWeekday != 1. The tests below run with explicit calendars
/// so they're independent of the host's regional settings.
final class CalendarMonthGridTests: XCTestCase {

    /// Returns a `Calendar` set to a specific firstWeekday + UTC so the
    /// tests are deterministic regardless of host locale.
    private func calendar(firstWeekday: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = firstWeekday
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: - Sunday-first (en_US)

    func testFebruary2026SundayFirstHasNoLeadingBlanks() {
        // Feb 1 2026 is a Sunday → with firstWeekday=1 there are 0 blanks.
        let cal = calendar(firstWeekday: 1)
        let grid = CalendarMonthGrid.cells(
            forMonth: date(2026, 2, 15, calendar: cal),
            calendar: cal,
            padTrailing: true
        )
        XCTAssertNotNil(grid.first ?? nil, "First cell should be Feb 1, not blank.")
        XCTAssertEqual(grid.count % 7, 0, "padTrailing must complete week rows.")
        let nonNil = grid.compactMap { $0 }
        XCTAssertEqual(nonNil.count, 28, "Feb 2026 has 28 days.")
    }

    func testMay2026SundayFirstHasFiveLeadingBlanks() {
        // May 1 2026 is a Friday → with Sunday-first that's 5 leading
        // blanks (Sun Mon Tue Wed Thu).
        let cal = calendar(firstWeekday: 1)
        let grid = CalendarMonthGrid.cells(
            forMonth: date(2026, 5, 17, calendar: cal),
            calendar: cal,
            padTrailing: true
        )
        let leadingBlanks = grid.prefix(while: { $0 == nil }).count
        XCTAssertEqual(leadingBlanks, 5)
    }

    // MARK: - Monday-first (most of Europe)

    func testMay2026MondayFirstHasFourLeadingBlanks() {
        // Same May 2026 but firstWeekday=2 (Monday) → blanks shift by 1.
        let cal = calendar(firstWeekday: 2)
        let grid = CalendarMonthGrid.cells(
            forMonth: date(2026, 5, 17, calendar: cal),
            calendar: cal,
            padTrailing: true
        )
        let leadingBlanks = grid.prefix(while: { $0 == nil }).count
        XCTAssertEqual(leadingBlanks, 4,
                       "Friday on a Monday-first calendar leaves 4 leading blanks.")
    }

    func testMondayFirstWithSunday1stProduces6LeadingBlanks() {
        // Worst case for Monday-first: Feb 2026 starts on a Sunday →
        // 6 blanks before the 1st.
        let cal = calendar(firstWeekday: 2)
        let grid = CalendarMonthGrid.cells(
            forMonth: date(2026, 2, 1, calendar: cal),
            calendar: cal,
            padTrailing: true
        )
        let leadingBlanks = grid.prefix(while: { $0 == nil }).count
        XCTAssertEqual(leadingBlanks, 6)
    }

    // MARK: - Edge cases

    func testPadTrailingFalseLeavesTailUnpadded() {
        // NoteCalendarView relies on this — it doesn't want trailing nil
        // placeholders because it lays out cells inline without forcing
        // a grid. Pick May 2026 (5 leading blanks + 31 days = 36) so the
        // result isn't accidentally a multiple of 7.
        let cal = calendar(firstWeekday: 1)
        let grid = CalendarMonthGrid.cells(
            forMonth: date(2026, 5, 17, calendar: cal),
            calendar: cal,
            padTrailing: false
        )
        XCTAssertEqual(grid.count, 36,
                       "Should be 5 leading blanks + 31 day cells, with no trailing pad.")
        XCTAssertNotEqual(grid.count % 7, 0,
                          "Without trailing pad, May 2026 doesn't complete the last week row.")
        XCTAssertEqual(grid.compactMap { $0 }.count, 31)
    }

    func testLeapYearFebHas29DayCells() {
        let cal = calendar(firstWeekday: 1)
        let grid = CalendarMonthGrid.cells(
            forMonth: date(2024, 2, 15, calendar: cal),
            calendar: cal,
            padTrailing: false
        )
        XCTAssertEqual(grid.compactMap { $0 }.count, 29)
    }

    func testLabelledCellsCarryIsCurrentMonthFlag() {
        let cal = calendar(firstWeekday: 1)
        let labelled = CalendarMonthGrid.labelledCells(
            forMonth: date(2026, 5, 17, calendar: cal),
            calendar: cal,
            padTrailing: true
        )
        let blanks = labelled.filter { !$0.isCurrentMonth }
        let real = labelled.filter { $0.isCurrentMonth }
        XCTAssertEqual(real.count, 31, "May 2026 has 31 days.")
        // 5 leading + N trailing blanks summing to a multiple of 7.
        XCTAssertEqual((real.count + blanks.count) % 7, 0)
    }
}
