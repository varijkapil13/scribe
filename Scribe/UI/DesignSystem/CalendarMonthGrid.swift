// Scribe/UI/DesignSystem/CalendarMonthGrid.swift
import Foundation

/// Builds a flat array of `Date?` cells representing a single month laid
/// out in week rows. Used by `TaskCalendarView` and `NoteCalendarView` —
/// the same logic was previously duplicated (and one copy had a subtle
/// bug: it assumed Sunday-first regardless of the user's locale).
///
/// `nil` entries are padding cells: positions before the 1st of the month
/// to align it under the correct weekday header, and (optionally) after
/// the last day to keep every row complete.
enum CalendarMonthGrid {

    /// - Parameters:
    ///   - month: Any date inside the month to render. The function uses
    ///     `Calendar.dateInterval(of: .month, for:)` to find the first/last
    ///     days, so passing the 1st or the 17th yields the same result.
    ///   - calendar: Locale-aware calendar (firstWeekday respects user
    ///     preference — Sunday in `en_US`, Monday in most European
    ///     locales).
    ///   - padTrailing: When `true`, fill the last row with `nil` cells
    ///     so the array length is a multiple of 7. Matches
    ///     `TaskCalendarView`'s grid; `NoteCalendarView` passes `false`.
    /// - Returns: `[Date?]` ordered left-to-right, top-to-bottom.
    static func cells(
        forMonth month: Date,
        calendar: Calendar = .current,
        padTrailing: Bool = true
    ) -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else {
            return []
        }
        let firstOfMonth = interval.start
        let weekdayOfFirst = calendar.component(.weekday, from: firstOfMonth)
        // (weekday − firstWeekday + 7) % 7 lands at 0 when the 1st falls
        // on the locale's first weekday. The `+ 7` handles negative
        // values for the `% 7` operator on non-Sunday-first calendars.
        let leadingBlanks = (weekdayOfFirst - calendar.firstWeekday + 7) % 7

        var cells: [Date?] = Array(repeating: nil, count: leadingBlanks)
        var cursor = firstOfMonth
        while cursor < interval.end {
            cells.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        if padTrailing {
            while cells.count % 7 != 0 {
                cells.append(nil)
            }
        }
        return cells
    }

    /// Convenience that matches `TaskCalendarViewModel.CalendarCell`'s
    /// shape — `(date, isCurrentMonth)` tuples. Sugar over `cells(forMonth:)`
    /// so the view can keep its current row-cell wrapper without
    /// re-implementing the grid math.
    struct LabelledCell: Equatable {
        let date: Date?
        let isCurrentMonth: Bool
    }

    static func labelledCells(
        forMonth month: Date,
        calendar: Calendar = .current,
        padTrailing: Bool = true
    ) -> [LabelledCell] {
        cells(forMonth: month, calendar: calendar, padTrailing: padTrailing)
            .map { LabelledCell(date: $0, isCurrentMonth: $0 != nil) }
    }
}
