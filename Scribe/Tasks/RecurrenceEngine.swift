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

    // MARK: - WEEKLY (stub — Task 3)

    private static func nextWeeklyDate(
        after date: Date,
        rule: RecurrenceRule,
        calendar: Calendar
    ) -> Date {
        return calendar.date(byAdding: .weekOfYear, value: rule.interval, to: date)!
    }

    // MARK: - MONTHLY (stub — Task 4)

    private static func nextMonthlyDate(
        after date: Date,
        rule: RecurrenceRule,
        calendar: Calendar
    ) -> Date {
        return calendar.date(byAdding: .month, value: rule.interval, to: date)!
    }
}
