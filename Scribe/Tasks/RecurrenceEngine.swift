import Foundation

extension Calendar {
    static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
}

enum RecurrenceEngine: Sendable {

    static func nextDate(
        after date: Date,
        rule: RecurrenceRule,
        calendar: Calendar = .utcCalendar
    ) -> Date {
        switch rule.frequency {
        case .daily:
            return safeAdd(.day, value: rule.interval, to: date, calendar: calendar)
        case .weekly:
            return nextWeeklyDate(after: date, rule: rule, calendar: calendar)
        case .monthly:
            return nextMonthlyDate(after: date, rule: rule, calendar: calendar)
        }
    }

    // MARK: - WEEKLY

    private static func nextWeeklyDate(
        after date: Date,
        rule: RecurrenceRule,
        calendar: Calendar
    ) -> Date {
        guard !rule.byDay.isEmpty else {
            return safeAdd(.weekOfYear, value: rule.interval, to: date, calendar: calendar)
        }

        let sorted = rule.byDay.sorted { $0.calendarWeekday < $1.calendarWeekday }
        let currentWeekday = calendar.component(.weekday, from: date)

        // If any BYDAY weekday comes later this week, advance to it.
        if let next = sorted.first(where: { $0.calendarWeekday > currentWeekday }) {
            return safeAdd(.day, value: next.calendarWeekday - currentWeekday, to: date, calendar: calendar)
        }

        // Wrap: days to first BYDAY in the next `interval` week(s).
        let firstWeekday = sorted.first!.calendarWeekday
        let daysToFirst = (firstWeekday - currentWeekday + 7) % 7
        let normalised = daysToFirst == 0 ? 7 : daysToFirst
        let total = normalised + (rule.interval - 1) * 7
        return safeAdd(.day, value: total, to: date, calendar: calendar)
    }

    // MARK: - MONTHLY

    private static func nextMonthlyDate(
        after date: Date,
        rule: RecurrenceRule,
        calendar: Calendar
    ) -> Date {
        var anchor = safeAdd(.month, value: rule.interval, to: date, calendar: calendar)
        guard let ordinal = rule.byOrdinalWeekday else { return anchor }

        // Loop until we find a month that actually contains the Nth occurrence.
        // Most months converge on the first try; ordinal=5 may skip once.
        while true {
            if let result = nthWeekdayInMonth(ordinal: ordinal.ordinal,
                                              weekday: ordinal.weekday,
                                              in: anchor,
                                              calendar: calendar) {
                return result
            }
            anchor = safeAdd(.month, value: rule.interval, to: anchor, calendar: calendar)
        }
    }

    /// Returns the Nth occurrence of `weekday` in the month containing `date`,
    /// or `nil` if the Nth occurrence doesn't exist in that month (e.g. 5th Monday
    /// in a month with only 4 Mondays). `ordinal` 1…5 = first…fifth; -1 = last.
    private static func nthWeekdayInMonth(
        ordinal: Int,
        weekday: RecurrenceRule.Weekday,
        in date: Date,
        calendar: Calendar
    ) -> Date? {
        let targetWeekday = weekday.calendarWeekday
        let monthStart = safeAdd(.day, value: 0, to: calendar.date(from: calendar.dateComponents([.year, .month], from: date))!, calendar: calendar)

        if ordinal > 0 {
            let firstWeekday = calendar.component(.weekday, from: monthStart)
            let offset = (targetWeekday - firstWeekday + 7) % 7
            let candidate = safeAdd(.day, value: offset + (ordinal - 1) * 7, to: monthStart, calendar: calendar)
            guard calendar.component(.month, from: candidate) == calendar.component(.month, from: monthStart) else {
                return nil
            }
            return candidate
        } else {
            // Negative ordinal: count back from last day of month.
            let nextMonthStart = safeAdd(.month, value: 1, to: monthStart, calendar: calendar)
            let lastDay = safeAdd(.day, value: -1, to: nextMonthStart, calendar: calendar)
            let lastWeekday = calendar.component(.weekday, from: lastDay)
            let offset = (lastWeekday - targetWeekday + 7) % 7
            return safeAdd(.day, value: -(offset + (abs(ordinal) - 1) * 7), to: lastDay, calendar: calendar)
        }
    }

    // MARK: - Helpers

    private static func safeAdd(_ component: Calendar.Component, value: Int, to date: Date, calendar: Calendar) -> Date {
        guard let result = calendar.date(byAdding: component, value: value, to: date) else {
            preconditionFailure("RecurrenceEngine: Calendar.date(byAdding: \(component), value: \(value)) returned nil — date out of representable range")
        }
        return result
    }
}
