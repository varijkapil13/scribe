import Foundation

/// Editable form of a `RecurrenceRule` for the iOS repeat editor: frequency +
/// interval, weekdays (weekly), the day-of-month pattern (monthly / yearly),
/// the end (never / until a date / after N times) and "after completion".
///
/// Pure value type: `init(rule:anchor:calendar:)` reads a stored rule,
/// `rule()` writes one. A rule using parts the editor can't show (BYSETPOS,
/// several month days, daily-with-weekdays…) is flagged `isLossy`, so the UI
/// can warn before replacing it.
struct TaskRecurrenceDraft: Equatable, Sendable {

    enum EndMode: String, CaseIterable, Identifiable, Sendable {
        case never, until, count
        var id: String { rawValue }
        var title: String {
            switch self {
            case .never: return "Never"
            case .until: return "On Date"
            case .count: return "After"
            }
        }
    }

    /// How a monthly / yearly rule picks its day.
    enum MonthPattern: String, CaseIterable, Identifiable, Sendable {
        /// The due date's own day (no BY parts).
        case sameDay
        /// A fixed day of the month (`BYMONTHDAY=n`).
        case dayOfMonth
        /// The last day of the month (`BYMONTHDAY=-1`).
        case lastDay
        /// The Nth / last weekday (`BYDAY=2MO`, `BYDAY=-1FR`).
        case ordinalWeekday
        var id: String { rawValue }
        var title: String {
            switch self {
            case .sameDay:        return "Same Day"
            case .dayOfMonth:     return "Day of Month"
            case .lastDay:        return "Last Day"
            case .ordinalWeekday: return "Weekday"
            }
        }
    }

    static let frequencies: [RecurrenceRule.Frequency] = [.daily, .weekly, .monthly, .yearly]
    /// Ordinals offered for "the Nth weekday" (-1 = last).
    static let ordinals: [Int] = [1, 2, 3, 4, -1]

    var frequency: RecurrenceRule.Frequency
    var interval: Int
    var weekdays: Set<RecurrenceRule.Weekday>
    var monthPattern: MonthPattern
    var monthDay: Int
    var ordinal: Int
    var ordinalWeekday: RecurrenceRule.Weekday
    var endMode: EndMode
    var untilDate: Date
    var count: Int
    var fromCompletion: Bool

    /// True when the rule this draft was read from can't be reproduced
    /// exactly by `rule()`.
    private(set) var isLossy: Bool = false

    /// A fresh "every week on the anchor's weekday" draft.
    init(anchor: Date, calendar: Calendar) {
        let weekday = RecurrenceRule.Weekday.from(calendarWeekday: calendar.component(.weekday, from: anchor)) ?? .mo
        let day = calendar.component(.day, from: anchor)
        self.frequency = .weekly
        self.interval = 1
        self.weekdays = [weekday]
        self.monthPattern = .sameDay
        self.monthDay = day
        self.ordinal = Self.ordinal(forDay: day)
        self.ordinalWeekday = weekday
        self.endMode = .never
        self.untilDate = Self.endOfDay(calendar.date(byAdding: .month, value: 3, to: anchor) ?? anchor, calendar: calendar)
        self.count = 10
        self.fromCompletion = false
    }

    /// Reads `rule` (anchored at the task's due date for the defaults the rule
    /// doesn't carry).
    init(rule: RecurrenceRule, anchor: Date, calendar: Calendar) {
        self.init(anchor: anchor, calendar: calendar)
        frequency = rule.frequency
        interval = max(1, rule.interval)
        fromCompletion = rule.fromCompletion

        switch rule.frequency {
        case .daily:
            break
        case .weekly:
            // Empty = "on the due date's weekday" (no BYDAY).
            weekdays = Set(rule.byDay)
        case .monthly, .yearly:
            if let ord = rule.byOrdinalWeekday {
                monthPattern = .ordinalWeekday
                ordinal = ord.ordinal
                ordinalWeekday = ord.weekday
            } else if rule.byMonthDay == [-1] {
                monthPattern = .lastDay
            } else if rule.byMonthDay.count == 1, let day = rule.byMonthDay.first, day > 0 {
                monthPattern = .dayOfMonth
                monthDay = day
            } else {
                monthPattern = .sameDay
            }
        }

        if let until = rule.until {
            endMode = .until
            untilDate = until
        } else if let remaining = rule.count {
            endMode = .count
            count = remaining
        } else {
            endMode = .never
        }

        isLossy = !Self.isEquivalent(self.rule(), rule)
    }

    /// Same rule up to weekday-list order.
    static func isEquivalent(_ a: RecurrenceRule, _ b: RecurrenceRule) -> Bool {
        var left = a
        var right = b
        left.byDay = RecurrenceRule.Weekday.allCases.filter { a.byDay.contains($0) }
        right.byDay = RecurrenceRule.Weekday.allCases.filter { b.byDay.contains($0) }
        return left == right
    }

    /// Reads a stored RRULE string; nil when there's none or it doesn't parse.
    init?(rrule: String?, anchor: Date, calendar: Calendar) {
        guard let rrule, let rule = try? RecurrenceRule.parse(rrule) else { return nil }
        self.init(rule: rule, anchor: anchor, calendar: calendar)
    }

    /// The rule this draft describes.
    func rule() -> RecurrenceRule {
        var byDay: [RecurrenceRule.Weekday] = []
        var byOrdinal: RecurrenceRule.OrdinalWeekday?
        var byMonthDay: [Int] = []

        switch frequency {
        case .daily:
            break
        case .weekly:
            // Mon…Sun order, so the stored rule reads naturally.
            byDay = RecurrenceRule.Weekday.allCases.filter { weekdays.contains($0) }
        case .monthly, .yearly:
            switch monthPattern {
            case .sameDay:        break
            case .dayOfMonth:     byMonthDay = [min(max(monthDay, 1), 31)]
            case .lastDay:        byMonthDay = [-1]
            case .ordinalWeekday: byOrdinal = RecurrenceRule.OrdinalWeekday(ordinal: Self.clampedOrdinal(ordinal),
                                                                            weekday: ordinalWeekday)
            }
        }

        return RecurrenceRule(
            frequency: frequency,
            interval: max(1, interval),
            byDay: byDay,
            byOrdinalWeekday: byOrdinal,
            byMonthDay: byMonthDay,
            until: endMode == .until ? untilDate : nil,
            count: endMode == .count ? max(1, count) : nil,
            fromCompletion: fromCompletion
        )
    }

    var rruleString: String { rule().rruleString }

    var summary: String { rule().summary }

    // MARK: - Presets

    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case daily, weekdays, weekly, monthly, yearly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .daily:    return "Every Day"
            case .weekdays: return "Every Weekday"
            case .weekly:   return "Every Week"
            case .monthly:  return "Every Month"
            case .yearly:   return "Every Year"
            }
        }
    }

    /// A preset draft anchored at `anchor` (the task's due date).
    static func preset(_ preset: Preset, anchor: Date, calendar: Calendar) -> TaskRecurrenceDraft {
        var draft = TaskRecurrenceDraft(anchor: anchor, calendar: calendar)
        switch preset {
        case .daily:
            draft.frequency = .daily
        case .weekdays:
            draft.frequency = .weekly
            draft.weekdays = Set(RecurrenceRule.Weekday.weekdays)
        case .weekly:
            draft.frequency = .weekly
        case .monthly:
            draft.frequency = .monthly
        case .yearly:
            draft.frequency = .yearly
        }
        return draft
    }

    // MARK: - Helpers

    /// 23:59:59 on `date`'s day — what an "until" date picker should store.
    static func endOfDay(_ date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return next.addingTimeInterval(-1)
    }

    /// Which Nth weekday a day of the month falls on (29+ reads as "last").
    static func ordinal(forDay day: Int) -> Int {
        let nth = (max(1, day) - 1) / 7 + 1
        return nth >= 5 ? -1 : nth
    }

    static func clampedOrdinal(_ value: Int) -> Int {
        if value == -1 { return -1 }
        return min(max(value, 1), 4)
    }

    /// Unit word for the interval stepper ("day" / "weeks"…).
    static func unitName(_ frequency: RecurrenceRule.Frequency, plural: Bool) -> String {
        let base: String
        switch frequency {
        case .daily:   base = "day"
        case .weekly:  base = "week"
        case .monthly: base = "month"
        case .yearly:  base = "year"
        }
        return plural ? base + "s" : base
    }

    static func frequencyTitle(_ frequency: RecurrenceRule.Frequency) -> String {
        switch frequency {
        case .daily:   return "Daily"
        case .weekly:  return "Weekly"
        case .monthly: return "Monthly"
        case .yearly:  return "Yearly"
        }
    }

    static func ordinalTitle(_ value: Int) -> String {
        switch value {
        case -1: return "Last"
        case 1:  return "First"
        case 2:  return "Second"
        case 3:  return "Third"
        case 4:  return "Fourth"
        default: return "\(value)th"
        }
    }

    static func weekdayTitle(_ day: RecurrenceRule.Weekday) -> String {
        switch day {
        case .mo: return "Monday"
        case .tu: return "Tuesday"
        case .we: return "Wednesday"
        case .th: return "Thursday"
        case .fr: return "Friday"
        case .sa: return "Saturday"
        case .su: return "Sunday"
        }
    }

    static func weekdayInitial(_ day: RecurrenceRule.Weekday) -> String {
        switch day {
        case .mo: return "M"
        case .tu: return "T"
        case .we: return "W"
        case .th: return "T"
        case .fr: return "F"
        case .sa: return "S"
        case .su: return "S"
        }
    }
}
