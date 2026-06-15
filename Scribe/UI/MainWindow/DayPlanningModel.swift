import Foundation
import Observation

/// Single source of truth for the day the user is planning. Shared between the
/// unified ``TodayView`` and ``TaskCalendarView`` so navigating to a date in
/// one surface keeps the other in sync — the "one day model" half of Slice E1.
///
/// Lives in its own file (in the SwiftPM test target) because `TodayView` is
/// excluded from that target by the editor rewrite, while `TaskCalendarView`/
/// `TaskCalendarViewModel` and `DayPlanningModelTests` — which stay in the
/// target — depend on this model.
///
/// The date is always normalised to the start of its calendar day, so equality
/// comparisons and `yyyy-MM-dd` bucketing line up no matter what time-of-day a
/// caller passes in. Injected via `@Environment`; surfaces that want isolated
/// state (previews, the legacy standalone daily note) can simply not read it.
@MainActor
@Observable
final class DayPlanningModel {

    /// The currently-planned day, normalised to its start-of-day instant.
    private(set) var selectedDate: Date

    private let calendar: Calendar

    init(selectedDate: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        self.selectedDate = Self.normalize(selectedDate, calendar: calendar)
    }

    /// Move the shared day to `date` (normalised). No-op when it already points
    /// at the same calendar day, so redundant taps don't churn observers.
    func select(_ date: Date) {
        let normalised = Self.normalize(date, calendar: calendar)
        guard normalised != selectedDate else { return }
        selectedDate = normalised
    }

    var isToday: Bool { calendar.isDateInToday(selectedDate) }

    // MARK: - Pure helpers (unit-tested in DayPlanningModelTests)

    /// Start-of-day for `date` in `calendar`. Pulled out so the normalisation
    /// invariant is testable without spinning up the `@Observable`.
    static func normalize(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    /// The `TaskStore.Filter` a day-scoped surface should use for `date`:
    /// `.today` for the current day (keeps overdue tasks visible), the strict
    /// same-day `.dueOn` window otherwise. The single decision point both the
    /// Today rail and any day-scoped task list route through.
    static func taskFilter(for date: Date, calendar: Calendar = .current, now: Date = Date()) -> TaskStore.Filter {
        if calendar.isDate(date, inSameDayAs: now) {
            return .today
        }
        return .dueOn(normalize(date, calendar: calendar))
    }
}
