import Foundation

extension Calendar {
    static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
}

/// Result of advancing a recurring task past one completed occurrence.
struct RecurrenceStep: Equatable, Sendable {
    /// The next occurrence's due date.
    let dueAt: Date
    /// The rule to store for the next occurrence (COUNT decremented when set;
    /// otherwise identical to the input rule).
    let rule: RecurrenceRule
}

enum RecurrenceEngine: Sendable {

    /// Upper bound on the month-expansion search (BYMONTHDAY / BYSETPOS /
    /// ordinal rules that never match, e.g. `BYMONTHDAY=31` with an interval
    /// that only ever lands on 30-day months). 400 steps ≥ 33 years monthly.
    private static let maxExpansionSteps = 400

    /// The next date in the rule's *pattern* strictly after `date`. Ignores
    /// UNTIL / COUNT / X-SCRIBE-FROM — see `nextOccurrence` for the full
    /// task-advance semantics.
    ///
    /// All arithmetic is wall-clock arithmetic in `calendar` (day / month /
    /// year adds and component construction), so a 09:00 task stays at 09:00
    /// across DST transitions when `calendar` is the user's local calendar.
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
            if usesExpansion(rule) {
                return expandedNext(after: date, rule: rule, monthStep: rule.interval, calendar: calendar)
                    ?? safeAdd(.month, value: rule.interval, to: date, calendar: calendar)
            }
            return nextMonthlyDate(after: date, rule: rule, calendar: calendar)
        case .yearly:
            if usesExpansion(rule) || rule.byOrdinalWeekday != nil {
                // Yearly + BY* rules expand within the anchor's month of the
                // year, every `interval` years (e.g. "last weekday of every
                // December", "every year on the 2nd Sunday of May").
                return expandedNext(after: date, rule: rule, monthStep: 12 * rule.interval, calendar: calendar)
                    ?? safeAdd(.year, value: rule.interval, to: date, calendar: calendar)
            }
            return safeAdd(.year, value: rule.interval, to: date, calendar: calendar)
        }
    }

    /// Advances a recurring task past the occurrence due at `dueAt`, completed
    /// at `completedAt`. Returns nil when the series has ended (the completed
    /// occurrence was the last one under COUNT, or the next one falls after
    /// UNTIL) — the caller then completes the task for good.
    ///
    /// For `X-SCRIBE-FROM=COMPLETION` rules the pattern is applied from the
    /// completion *day*, keeping the original due time-of-day ("every 2 weeks
    /// after completion": done Wednesday → due Wednesday two weeks later).
    static func nextOccurrence(
        dueAt: Date,
        completedAt: Date,
        rule: RecurrenceRule,
        calendar: Calendar
    ) -> RecurrenceStep? {
        if let count = rule.count, count <= 1 { return nil }

        let base = rule.fromCompletion
            ? completionAnchor(dueAt: dueAt, completedAt: completedAt, calendar: calendar)
            : dueAt
        let next = nextDate(after: base, rule: rule, calendar: calendar)

        if let until = rule.until, next > until { return nil }

        var nextRule = rule
        if let count = rule.count { nextRule.count = count - 1 }
        return RecurrenceStep(dueAt: next, rule: nextRule)
    }

    /// The first day on or after `day` (at its start) that fits the rule's
    /// pattern — the natural first due date for a task created from a phrase
    /// like "every monday" or "every last weekday". Plain rules (no BY* parts)
    /// start on `day` itself.
    static func firstOccurrence(onOrAfter day: Date, rule: RecurrenceRule, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        guard let probeFrom = calendar.date(byAdding: .day, value: -1, to: start) else { return start }
        // Interval / bounds don't affect where the series starts.
        var probe = rule
        probe.interval = 1
        probe.count = nil
        probe.until = nil
        probe.fromCompletion = false
        switch rule.frequency {
        case .daily:
            return start
        case .weekly:
            return rule.byDay.isEmpty ? start : nextWeeklyDate(after: probeFrom, rule: probe, calendar: calendar)
        case .monthly, .yearly:
            guard usesExpansion(rule) || rule.byOrdinalWeekday != nil else { return start }
            let step = rule.frequency == .monthly ? 1 : 12
            return expandedNext(after: probeFrom, rule: probe, monthStep: step, calendar: calendar) ?? start
        }
    }

    /// The completion day at the due date's wall-clock time.
    static func completionAnchor(dueAt: Date, completedAt: Date, calendar: Calendar) -> Date {
        let time = calendar.dateComponents([.hour, .minute, .second], from: dueAt)
        var comps = calendar.dateComponents([.year, .month, .day], from: completedAt)
        comps.hour = time.hour
        comps.minute = time.minute
        comps.second = time.second
        return calendar.date(from: comps) ?? completedAt
    }

    // MARK: - WEEKLY

    private static func nextWeeklyDate(
        after date: Date,
        rule: RecurrenceRule,
        calendar: Calendar
    ) -> Date {
        guard let first = rule.byDay.min(by: { $0.calendarWeekday < $1.calendarWeekday }) else {
            return safeAdd(.weekOfYear, value: rule.interval, to: date, calendar: calendar)
        }

        let sorted = rule.byDay.sorted { $0.calendarWeekday < $1.calendarWeekday }
        let currentWeekday = calendar.component(.weekday, from: date)

        // If any BYDAY weekday comes later this week, advance to it.
        if let next = sorted.first(where: { $0.calendarWeekday > currentWeekday }) {
            return safeAdd(.day, value: next.calendarWeekday - currentWeekday, to: date, calendar: calendar)
        }

        // Wrap: days to first BYDAY in the next `interval` week(s).
        let firstWeekday = first.calendarWeekday
        let daysToFirst = (firstWeekday - currentWeekday + 7) % 7
        let normalised = daysToFirst == 0 ? 7 : daysToFirst
        let total = normalised + (rule.interval - 1) * 7
        return safeAdd(.day, value: total, to: date, calendar: calendar)
    }

    // MARK: - MONTHLY (legacy paths: plain + single ordinal weekday)

    private static func nextMonthlyDate(
        after date: Date,
        rule: RecurrenceRule,
        calendar: Calendar
    ) -> Date {
        var anchor = safeAdd(.month, value: rule.interval, to: date, calendar: calendar)
        guard let ordinal = rule.byOrdinalWeekday else { return anchor }

        // Loop until we find a month that actually contains the Nth occurrence.
        // Most months converge on the first try; ordinal=5 may skip once.
        for _ in 0..<maxExpansionSteps {
            if let result = nthWeekdayInMonth(ordinal: ordinal.ordinal,
                                              weekday: ordinal.weekday,
                                              in: anchor,
                                              calendar: calendar) {
                return result
            }
            anchor = safeAdd(.month, value: rule.interval, to: anchor, calendar: calendar)
        }
        return anchor
    }

    /// Returns the Nth occurrence of `weekday` in the month containing `date`
    /// (keeping `date`'s time-of-day), or `nil` if the Nth occurrence doesn't
    /// exist in that month (e.g. 5th Monday in a month with only 4 Mondays).
    /// `ordinal` 1…5 = first…fifth; -1 = last.
    private static func nthWeekdayInMonth(
        ordinal: Int,
        weekday: RecurrenceRule.Weekday,
        in date: Date,
        calendar: Calendar
    ) -> Date? {
        let days = monthDayNumbers(of: date, calendar: calendar)
        guard days.count > 0 else { return nil }
        let matching = days.filter { weekdayOf(day: $0, firstWeekday: days.firstWeekday) == weekday.calendarWeekday }
        guard let day = pick(position: ordinal, from: matching) else { return nil }
        return dateFor(day: day, inMonthOf: date, timeFrom: date, calendar: calendar)
    }

    // MARK: - Set expansion (BYMONTHDAY / BYDAY lists / BYSETPOS)

    private static func usesExpansion(_ rule: RecurrenceRule) -> Bool {
        !rule.byMonthDay.isEmpty || !rule.bySetPos.isEmpty || !rule.byDay.isEmpty
    }

    /// Walks months `monthStep` apart starting at `date`'s month, expands each
    /// month into candidate days, and returns the first candidate strictly
    /// after `date` (at `date`'s wall-clock time).
    private static func expandedNext(
        after date: Date,
        rule: RecurrenceRule,
        monthStep: Int,
        calendar: Calendar
    ) -> Date? {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) else {
            return nil
        }
        for step in 0..<maxExpansionSteps {
            guard let month = calendar.date(byAdding: .month, value: step * monthStep, to: monthStart) else {
                return nil
            }
            for day in candidateDays(inMonthOf: month, rule: rule, calendar: calendar) {
                if let candidate = dateFor(day: day, inMonthOf: month, timeFrom: date, calendar: calendar),
                   candidate > date {
                    return candidate
                }
            }
        }
        return nil
    }

    /// The rule's matching day numbers within the month containing `month`,
    /// ascending, after applying BYSETPOS.
    static func candidateDays(inMonthOf month: Date, rule: RecurrenceRule, calendar: Calendar) -> [Int] {
        let days = monthDayNumbers(of: month, calendar: calendar)
        let count = days.count
        guard count > 0 else { return [] }

        var set = Array(1...count)
        if !rule.byMonthDay.isEmpty {
            let resolved = Set(rule.byMonthDay.compactMap { value -> Int? in
                let day = value > 0 ? value : count + value + 1
                return (1...count).contains(day) ? day : nil
            })
            set = set.filter { resolved.contains($0) }
        }
        if !rule.byDay.isEmpty {
            let wanted = Set(rule.byDay.map(\.calendarWeekday))
            set = set.filter { wanted.contains(weekdayOf(day: $0, firstWeekday: days.firstWeekday)) }
        }
        if let ord = rule.byOrdinalWeekday {
            let matching = set.filter {
                weekdayOf(day: $0, firstWeekday: days.firstWeekday) == ord.weekday.calendarWeekday
            }
            set = pick(position: ord.ordinal, from: matching).map { [$0] } ?? []
        }
        if !rule.bySetPos.isEmpty {
            let picked = Set(rule.bySetPos.compactMap { pick(position: $0, from: set) })
            set = picked.sorted()
        }
        return set
    }

    // MARK: - Helpers

    private struct MonthDays {
        let count: Int
        /// Gregorian weekday (1 = Sunday) of day 1.
        let firstWeekday: Int
        var isEmpty: Bool { count == 0 }
        func filter(_ isIncluded: (Int) -> Bool) -> [Int] {
            count > 0 ? (1...count).filter(isIncluded) : []
        }
    }

    private static func monthDayNumbers(of date: Date, calendar: Calendar) -> MonthDays {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date)),
              let range = calendar.range(of: .day, in: .month, for: monthStart) else {
            return MonthDays(count: 0, firstWeekday: 1)
        }
        return MonthDays(count: range.count, firstWeekday: calendar.component(.weekday, from: monthStart))
    }

    private static func weekdayOf(day: Int, firstWeekday: Int) -> Int {
        ((firstWeekday - 1 + day - 1) % 7) + 1
    }

    /// 1-based position from the front, or negative from the back.
    private static func pick(position: Int, from values: [Int]) -> Int? {
        guard position != 0, !values.isEmpty else { return nil }
        let index = position > 0 ? position - 1 : values.count + position
        return values.indices.contains(index) ? values[index] : nil
    }

    /// `day` of the month containing `month`, at `timeFrom`'s wall-clock time.
    private static func dateFor(day: Int, inMonthOf month: Date, timeFrom: Date, calendar: Calendar) -> Date? {
        var comps = calendar.dateComponents([.year, .month], from: month)
        let time = calendar.dateComponents([.hour, .minute, .second], from: timeFrom)
        comps.day = day
        comps.hour = time.hour
        comps.minute = time.minute
        comps.second = time.second
        return calendar.date(from: comps)
    }

    private static func safeAdd(_ component: Calendar.Component, value: Int, to date: Date, calendar: Calendar) -> Date {
        guard let result = calendar.date(byAdding: component, value: value, to: date) else {
            preconditionFailure("RecurrenceEngine: Calendar.date(byAdding: \(component), value: \(value)) returned nil — date out of representable range")
        }
        return result
    }
}
