// ScribeTests/TodayAgendaSummaryTests.swift
import XCTest
@testable import Scribe

final class TodayAgendaSummaryTests: XCTestCase {

    private func calendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testTodaySplitsOverdueFromDue() {
        let cal = calendar()
        let now = date(2026, 10, 14, 10, calendar: cal)
        let tasks = [
            TodoTask(title: "older", dueAt: date(2026, 5, 18, calendar: cal)),
            TodoTask(title: "due", dueAt: date(2026, 10, 14, 9, calendar: cal)),
            TodoTask(title: "yesterday", dueAt: date(2026, 10, 13, calendar: cal)),
            TodoTask(title: "planned", scheduleBucket: .today),
        ]

        let summary = TodayAgendaSummary.make(tasks: tasks, day: now, now: now, calendar: cal)

        XCTAssertEqual(summary.due.map(\.title), ["due", "planned"])
        XCTAssertEqual(summary.overdueCount, 2)
        XCTAssertEqual(summary.oldestOverdue, date(2026, 5, 18, calendar: cal))
    }

    func testOtherDayListsEverythingAndNoOverdue() {
        let cal = calendar()
        let now = date(2026, 10, 14, 10, calendar: cal)
        let day = date(2026, 10, 16, calendar: cal)
        let tasks = [TodoTask(title: "a", dueAt: day), TodoTask(title: "b", dueAt: day)]

        let summary = TodayAgendaSummary.make(tasks: tasks, day: day, now: now, calendar: cal)

        XCTAssertEqual(summary.due.count, 2)
        XCTAssertEqual(summary.overdueCount, 0)
        XCTAssertNil(summary.oldestOverdue)
    }

    func testEmptyWhenNothingDue() {
        let cal = calendar()
        let now = date(2026, 10, 14, 10, calendar: cal)
        XCTAssertEqual(TodayAgendaSummary.make(tasks: [], day: now, now: now, calendar: cal), .empty)
    }
}
