import XCTest
@testable import Scribe

/// The planner's pure overlap layout (`TimeGridLayout`) and vertical
/// geometry / 15-minute snapping (`TimeGridGeometry`).
final class TimeGridLayoutTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func interval(_ id: String, _ startMinute: Int, _ endMinute: Int) -> TimeGridInterval {
        TimeGridInterval(id: id,
                         start: base.addingTimeInterval(TimeInterval(startMinute * 60)),
                         end: base.addingTimeInterval(TimeInterval(endMinute * 60)))
    }

    private func layout(_ intervals: [TimeGridInterval]) -> [String: TimeGridPlacement] {
        TimeGridLayout.layout(intervals, minimumDuration: TimeGridLayout.defaultMinimumDuration)
    }

    // MARK: - Layout

    func testEmptyInputHasNoPlacements() {
        XCTAssertTrue(layout([]).isEmpty)
    }

    func testSeparateBlocksTakeFullWidth() {
        let result = layout([interval("a", 60, 120), interval("b", 120, 180)])
        XCTAssertEqual(result["a"], TimeGridPlacement(column: 0, columnCount: 1, span: 1))
        XCTAssertEqual(result["b"], TimeGridPlacement(column: 0, columnCount: 1, span: 1))
    }

    func testTwoOverlappingBlocksSplitIntoTwoColumns() {
        let result = layout([interval("a", 60, 120), interval("b", 90, 150)])
        XCTAssertEqual(result["a"], TimeGridPlacement(column: 0, columnCount: 2, span: 1))
        XCTAssertEqual(result["b"], TimeGridPlacement(column: 1, columnCount: 2, span: 1))
        XCTAssertEqual(result["b"]?.leadingFraction ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(result["b"]?.widthFraction ?? -1, 0.5, accuracy: 0.0001)
    }

    func testLongerBlockGoesFirstWhenStartsTie() {
        let result = layout([interval("short", 60, 90), interval("long", 60, 180)])
        XCTAssertEqual(result["long"]?.column, 0)
        XCTAssertEqual(result["short"]?.column, 1)
    }

    func testFreedColumnIsReusedAndChainFormsOneCluster() {
        // a overlaps b, b overlaps c, a ends before c starts → c reuses column 0.
        let result = layout([interval("a", 0, 60), interval("b", 30, 120), interval("c", 60, 90)])
        XCTAssertEqual(result["a"], TimeGridPlacement(column: 0, columnCount: 2, span: 1))
        XCTAssertEqual(result["b"], TimeGridPlacement(column: 1, columnCount: 2, span: 1))
        XCTAssertEqual(result["c"], TimeGridPlacement(column: 0, columnCount: 2, span: 1))
    }

    func testBlockWidensIntoFreeColumnsToItsRight() {
        // a, b, c overlap at 60–90 (3 columns). d starts after a and b end
        // but while c (column 2) runs, so d takes column 0 and widens into 1.
        let result = layout([
            interval("a", 0, 90),
            interval("b", 30, 90),
            interval("c", 60, 240),
            interval("d", 120, 180),
        ])
        XCTAssertEqual(result["a"], TimeGridPlacement(column: 0, columnCount: 3, span: 1))
        XCTAssertEqual(result["b"], TimeGridPlacement(column: 1, columnCount: 3, span: 1))
        XCTAssertEqual(result["c"], TimeGridPlacement(column: 2, columnCount: 3, span: 1))
        XCTAssertEqual(result["d"], TimeGridPlacement(column: 0, columnCount: 3, span: 2))
    }

    func testLaterClusterIsIndependent() {
        let result = layout([interval("a", 0, 60), interval("b", 30, 90), interval("c", 600, 660)])
        XCTAssertEqual(result["c"], TimeGridPlacement(column: 0, columnCount: 1, span: 1))
    }

    func testMinimumDurationMakesTinyBlocksCollide() {
        // A 5-minute block is laid out as 15 minutes, so a block starting 10
        // minutes later overlaps it.
        let result = layout([interval("tiny", 60, 65), interval("next", 70, 100)])
        XCTAssertEqual(result["tiny"]?.columnCount, 2)
        XCTAssertEqual(result["next"]?.column, 1)

        let exact = TimeGridLayout.layout([interval("tiny", 60, 65), interval("next", 70, 100)],
                                          minimumDuration: 0)
        XCTAssertEqual(exact["next"]?.columnCount, 1)
    }

    func testEveryIntervalIsPlaced() {
        let intervals = (0..<12).map { interval("i\($0)", $0 * 20, $0 * 20 + 45) }
        let result = layout(intervals)
        XCTAssertEqual(result.count, intervals.count)
        for placement in result.values {
            XCTAssertGreaterThanOrEqual(placement.span, 1)
            XCTAssertLessThanOrEqual(placement.column + placement.span, placement.columnCount)
        }
    }

    // MARK: - Geometry + snapping

    private let geometry = TimeGridGeometry(hourHeight: 60, snapMinutes: 15)

    func testPointsAndMinutesRoundTrip() {
        XCTAssertEqual(geometry.totalHeight, 1440, accuracy: 0.001)
        XCTAssertEqual(geometry.y(forMinute: 90), 90, accuracy: 0.001)
        XCTAssertEqual(geometry.minute(forY: 30), 30, accuracy: 0.001)

        let tall = TimeGridGeometry(hourHeight: 120, snapMinutes: 15)
        XCTAssertEqual(tall.y(forMinute: 30), 60, accuracy: 0.001)
        XCTAssertEqual(tall.minute(forY: 60), 30, accuracy: 0.001)
    }

    func testSnapRoundsToNearestQuarterHour() {
        XCTAssertEqual(geometry.snap(0), 0)
        XCTAssertEqual(geometry.snap(7), 0)
        XCTAssertEqual(geometry.snap(8), 15)
        XCTAssertEqual(geometry.snap(22), 15)
        XCTAssertEqual(geometry.snap(23), 30)
        XCTAssertEqual(geometry.snap(9 * 60 + 52), 9 * 60 + 45)
        XCTAssertEqual(geometry.snap(9 * 60 + 53), 10 * 60)
    }

    func testDropPointSnapsAndStaysInsideTheDay() {
        XCTAssertEqual(geometry.startMinute(forY: 9 * 60 + 5, durationMinutes: 30), 9 * 60)
        XCTAssertEqual(geometry.startMinute(forY: 9 * 60 + 10, durationMinutes: 30), 9 * 60 + 15)
        XCTAssertEqual(geometry.startMinute(forY: -40, durationMinutes: 30), 0)
        // A 30-minute block dropped at 23:55 starts at 23:30 at the latest.
        XCTAssertEqual(geometry.startMinute(forY: 23 * 60 + 55, durationMinutes: 30), 23 * 60 + 30)
        // A block that can't fit at all starts at midnight.
        XCTAssertEqual(geometry.startMinute(forY: 600, durationMinutes: 2000), 0)
    }

    func testMovingABlockSnapsTheNewStart() {
        XCTAssertEqual(geometry.movedStart(startMinute: 600, durationMinutes: 30, deltaY: 20), 615)
        XCTAssertEqual(geometry.movedStart(startMinute: 600, durationMinutes: 30, deltaY: 5), 600)
        XCTAssertEqual(geometry.movedStart(startMinute: 600, durationMinutes: 30, deltaY: -38), 555)
        XCTAssertEqual(geometry.movedStart(startMinute: 600, durationMinutes: 30, deltaY: 10_000), 1410)
        XCTAssertEqual(geometry.movedStart(startMinute: 30, durationMinutes: 30, deltaY: -10_000), 0)
    }

    func testResizingSnapsAndKeepsAtLeastOneStep() {
        XCTAssertEqual(geometry.resizedDuration(startMinute: 600, durationMinutes: 30, deltaY: 20), 45)
        XCTAssertEqual(geometry.resizedDuration(startMinute: 600, durationMinutes: 30, deltaY: -100), 15)
        // Never past midnight.
        XCTAssertEqual(geometry.resizedDuration(startMinute: 23 * 60, durationMinutes: 30, deltaY: 500), 60)
    }

    func testClampKeepsLatestStartOnTheSnapGrid() {
        let odd = TimeGridGeometry(hourHeight: 60, snapMinutes: 15)
        // 1440 − 50 = 1390, snapped down to 1380.
        XCTAssertEqual(odd.clampStart(1430, durationMinutes: 50), 1380)
        XCTAssertEqual(odd.clampStart(-5, durationMinutes: 50), 0)
    }

    func testMinuteOfDayAndDateAtMinute() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let day = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10)) ?? base
        let at930 = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9, minute: 30)) ?? base

        XCTAssertEqual(TimeGridGeometry.minuteOfDay(for: at930, on: day, calendar: calendar), 570)
        XCTAssertEqual(TimeGridGeometry.date(atMinute: 570, on: day, calendar: calendar), at930)

        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: day) ?? base
        XCTAssertEqual(TimeGridGeometry.minuteOfDay(for: nextMidnight, on: day, calendar: calendar), 1440)
        XCTAssertEqual(TimeGridGeometry.date(atMinute: 1440, on: day, calendar: calendar), nextMidnight)

        let previousEvening = day.addingTimeInterval(-3_600)
        XCTAssertEqual(TimeGridGeometry.minuteOfDay(for: previousEvening, on: day, calendar: calendar), -60)
    }
}
