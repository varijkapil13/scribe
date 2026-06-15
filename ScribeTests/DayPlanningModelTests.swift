// ScribeTests/DayPlanningModelTests.swift
import XCTest
@testable import Scribe

/// Pins the pure day-bucketing / filter-selection logic that backs the unified
/// "one day model" (Slice E1). The `.today` vs `.dueOn` decision is the only
/// behaviour the calendar/Today surfaces share, so it's the one we lock down —
/// per the plan's logic-first validation strategy (no local build).
@MainActor
final class DayPlanningModelTests: XCTestCase {

    /// Deterministic UTC gregorian calendar so the tests don't depend on the
    /// host's locale or time zone.
    private func calendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: - normalize

    func testNormalizeStripsTimeOfDay() {
        let cal = calendar()
        let noon = date(2026, 6, 15, 12, 30, calendar: cal)
        let normalised = DayPlanningModel.normalize(noon, calendar: cal)
        XCTAssertEqual(normalised, date(2026, 6, 15, 0, 0, calendar: cal))
    }

    func testNormalizeIsIdempotent() {
        let cal = calendar()
        let start = date(2026, 6, 15, 0, 0, calendar: cal)
        XCTAssertEqual(DayPlanningModel.normalize(start, calendar: cal), start)
    }

    // MARK: - taskFilter (.today vs .dueOn)

    func testTaskFilterReturnsTodayForTheCurrentDay() {
        let cal = calendar()
        let now = date(2026, 6, 15, 9, 0, calendar: cal)
        // Same day, different time-of-day → still the loose `.today` window
        // (which keeps overdue tasks visible).
        let sameDayLater = date(2026, 6, 15, 23, 59, calendar: cal)
        XCTAssertEqual(
            DayPlanningModel.taskFilter(for: sameDayLater, calendar: cal, now: now),
            .today
        )
    }

    func testTaskFilterReturnsDueOnForAPastDay() {
        let cal = calendar()
        let now = date(2026, 6, 15, 9, 0, calendar: cal)
        let yesterday = date(2026, 6, 14, 9, 0, calendar: cal)
        XCTAssertEqual(
            DayPlanningModel.taskFilter(for: yesterday, calendar: cal, now: now),
            .dueOn(date(2026, 6, 14, 0, 0, calendar: cal))
        )
    }

    func testTaskFilterReturnsDueOnForAFutureDay() {
        let cal = calendar()
        let now = date(2026, 6, 15, 9, 0, calendar: cal)
        let tomorrow = date(2026, 6, 16, 14, 0, calendar: cal)
        XCTAssertEqual(
            DayPlanningModel.taskFilter(for: tomorrow, calendar: cal, now: now),
            .dueOn(date(2026, 6, 16, 0, 0, calendar: cal))
        )
    }

    func testTaskFilterDueOnIsNormalisedToStartOfDay() {
        let cal = calendar()
        let now = date(2026, 6, 15, 9, 0, calendar: cal)
        // A future day passed with a time-of-day must still produce a
        // start-of-day `.dueOn` so the strict day window lines up.
        guard case .dueOn(let day) = DayPlanningModel.taskFilter(
            for: date(2026, 6, 20, 17, 45, calendar: cal), calendar: cal, now: now
        ) else {
            return XCTFail("Expected .dueOn for a non-today date.")
        }
        XCTAssertEqual(day, date(2026, 6, 20, 0, 0, calendar: cal))
    }

    // MARK: - select / instance behaviour

    func testInitNormalisesSelectedDate() {
        let cal = calendar()
        let model = DayPlanningModel(selectedDate: date(2026, 6, 15, 12, 0, calendar: cal), calendar: cal)
        XCTAssertEqual(model.selectedDate, date(2026, 6, 15, 0, 0, calendar: cal))
    }

    func testSelectNormalisesTheNewDate() {
        let cal = calendar()
        let model = DayPlanningModel(selectedDate: date(2026, 6, 15, calendar: cal), calendar: cal)
        model.select(date(2026, 7, 1, 18, 30, calendar: cal))
        XCTAssertEqual(model.selectedDate, date(2026, 7, 1, 0, 0, calendar: cal))
    }

    func testSelectSameDayDifferentTimeIsANoOp() {
        let cal = calendar()
        let model = DayPlanningModel(selectedDate: date(2026, 6, 15, 0, 0, calendar: cal), calendar: cal)
        let before = model.selectedDate
        model.select(date(2026, 6, 15, 22, 0, calendar: cal))
        // Already on that calendar day → unchanged (same normalised instant).
        XCTAssertEqual(model.selectedDate, before)
    }
}
