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
            return calendar.date(byAdding: .day, value: rule.interval, to: date)!
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
            return calendar.date(byAdding: .weekOfYear, value: rule.interval, to: date)!
        }

        let sorted = rule.byDay.sorted { $0.calendarWeekday < $1.calendarWeekday }
        let currentWeekday = calendar.component(.weekday, from: date)

        // If any BYDAY weekday comes later this week, advance to it.
        if let next = sorted.first(where: { $0.calendarWeekday > currentWeekday }) {
            return calendar.date(byAdding: .day,
                                 value: next.calendarWeekday - currentWeekday,
                                 to: date)!
        }

        // Wrap: days to first BYDAY in the next `interval` week(s).
        let firstWeekday = sorted.first!.calendarWeekday
        let daysToFirst = (firstWeekday - currentWeekday + 7) % 7
        let normalised = daysToFirst == 0 ? 7 : daysToFirst
        let total = normalised + (rule.interval - 1) * 7
        return calendar.date(byAdding: .day, value: total, to: date)!
    }

    // MARK: - MONTHLY

    private static func nextMonthlyDate(
        after date: Date,
        rule: RecurrenceRule,
        calendar: Calendar
    ) -> Date {
        let anchor = calendar.date(byAdding: .month, value: rule.interval, to: date)!
        guard let ordinal = rule.byOrdinalWeekday else { return anchor }
        return nthWeekdayInMonth(ordinal: ordinal.ordinal,
                                 weekday: ordinal.weekday,
                                 in: anchor,
                                 calendar: calendar)
    }

    /// Returns the Nth occurrence of `weekday` in the month containing `date`.
    /// `ordinal` 1…5 = first…fifth; -1 = last.
    private static func nthWeekdayInMonth(
        ordinal: Int,
        weekday: RecurrenceRule.Weekday,
        in date: Date,
        calendar: Calendar
    ) -> Date {
        let targetWeekday = weekday.calendarWeekday
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!

        if ordinal > 0 {
            let firstWeekday = calendar.component(.weekday, from: monthStart)
            let offset = (targetWeekday - firstWeekday + 7) % 7
            return calendar.date(byAdding: .day, value: offset + (ordinal - 1) * 7, to: monthStart)!
        } else {
            // Negative ordinal: count back from last day of month.
            let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart)!
            let lastDay = calendar.date(byAdding: .day, value: -1, to: nextMonthStart)!
            let lastWeekday = calendar.component(.weekday, from: lastDay)
            let offset = (lastWeekday - targetWeekday + 7) % 7
            return calendar.date(byAdding: .day, value: -(offset + (abs(ordinal) - 1) * 7), to: lastDay)!
        }
    }
}
