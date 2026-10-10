import Foundation

/// Pure field conversions between Scribe tasks and Apple Reminders.
enum RemindersFieldMapping {

    // MARK: Priority

    /// EventKit priority → Scribe priority. EventKit: 0 none, 1–4 high,
    /// 5 medium, 6–9 low (the Reminders app writes 1 / 5 / 9).
    static func scribePriority(fromReminderPriority value: Int) -> TodoTask.Priority? {
        switch value {
        case 1...4: return .high
        case 5:     return .medium
        case 6...9: return .low
        default:    return nil
        }
    }

    /// Scribe priority → EventKit priority (1 / 5 / 9, 0 for none).
    static func reminderPriority(from priority: TodoTask.Priority?) -> Int {
        switch priority {
        case .high?:   return 1
        case .medium?: return 5
        case .low?:    return 9
        case nil:      return 0
        }
    }

    // MARK: Due dates

    /// A Scribe `dueAt` → Reminders due. Scribe stores a date-only due as
    /// local midnight, so midnight means "date-only".
    static func due(fromTaskDueAt dueAt: Date?, calendar: Calendar) -> RemindersSyncDue? {
        guard let dueAt else { return nil }
        let isMidnight = calendar.startOfDay(for: dueAt) == dueAt
        return RemindersSyncDue(date: dueAt, hasTime: !isMidnight)
    }

    /// A Reminders due → Scribe `dueAt` (date-only → local midnight).
    static func taskDueAt(from due: RemindersSyncDue?, calendar: Calendar) -> Date? {
        guard let due else { return nil }
        return due.hasTime ? due.date : calendar.startOfDay(for: due.date)
    }

    /// Comparison key for a due date: the calendar day for date-only (or
    /// midnight) dues, the minute for timed ones. Two dues are "the same" when
    /// their keys match.
    static func dueKey(_ due: RemindersSyncDue?, calendar: Calendar) -> String {
        guard let due else { return "-" }
        let isMidnight = calendar.startOfDay(for: due.date) == due.date
        if due.hasTime && !isMidnight {
            let minutes = Int((due.date.timeIntervalSince1970 / 60).rounded(.down))
            return "t:\(minutes)"
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: due.date)
        return "d:\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    static func dueEqual(_ a: RemindersSyncDue?, _ b: RemindersSyncDue?, calendar: Calendar) -> Bool {
        dueKey(a, calendar: calendar) == dueKey(b, calendar: calendar)
    }

    // MARK: Recurrence

    /// Normalises an RRULE string. `supported` is false when the rule can't be
    /// parsed by `RecurrenceRule` (then it must be left alone); otherwise
    /// `rule` is the canonical string (weekdays Monday-first), or nil for none.
    static func normalizedRecurrence(_ raw: String?) -> (supported: Bool, rule: String?) {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return (true, nil) }
        guard let parsed = try? RecurrenceRule.parse(raw) else { return (false, nil) }
        // Rules using the extended parts (YEARLY, BYMONTHDAY, BYSETPOS,
        // UNTIL, COUNT, after-completion) have no simple Reminders mapping:
        // leave them alone rather than canonicalise them into a lossy form.
        guard !Self.usesExtendedRecurrence(parsed) else { return (false, nil) }
        let order = RecurrenceRule.Weekday.allCases
        let sortedDays = parsed.byDay.sorted {
            (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0)
        }
        let canonical = RecurrenceRule(
            frequency: parsed.frequency,
            interval: parsed.interval,
            byDay: sortedDays,
            byOrdinalWeekday: parsed.byOrdinalWeekday
        )
        return (true, canonical.rruleString)
    }

    /// Whether `rule` uses recurrence parts beyond the simple daily / weekly /
    /// monthly forms this mapping round-trips.
    static func usesExtendedRecurrence(_ rule: RecurrenceRule) -> Bool {
        rule.frequency == .yearly || !rule.byMonthDay.isEmpty || !rule.bySetPos.isEmpty
            || rule.until != nil || rule.count != nil || rule.fromCompletion
    }

    // MARK: Matching

    /// Key used on first contact to pair an unlinked task with an unlinked
    /// reminder: normalised title + due key.
    static func matchKey(title: String, due: RemindersSyncDue?, calendar: Calendar) -> String {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive], locale: nil)
            .lowercased()
        return normalizedTitle + "\u{1F}" + dueKey(due, calendar: calendar)
    }

    // MARK: Whole records

    /// The reminder fields a task maps to.
    static func reminderFields(from task: TodoTask, calendar: Calendar) -> RemindersSyncFields {
        RemindersSyncFields(
            title: task.title,
            notes: task.notes,
            due: due(fromTaskDueAt: task.dueAt, calendar: calendar),
            priority: reminderPriority(from: task.priority),
            recurrenceRule: normalizedRecurrence(task.recurrenceRule).rule
        )
    }

    /// The reminder's current fields, as-is.
    static func currentFields(of reminder: RemindersSyncReminder) -> RemindersSyncFields {
        RemindersSyncFields(
            title: reminder.title,
            notes: reminder.notes,
            due: reminder.due,
            priority: reminder.priority,
            recurrenceRule: reminder.recurrenceRule
        )
    }

    /// The task fields a reminder maps to, for a brand-new task in
    /// `projectId`. A recurrence without a due date is dropped (Scribe requires
    /// recurring tasks to have one).
    static func taskChanges(
        from reminder: RemindersSyncReminder,
        projectId: String?,
        calendar: Calendar
    ) -> RemindersSyncTaskChanges {
        let dueAt = taskDueAt(from: reminder.due, calendar: calendar)
        let rule = reminder.hasUnsupportedRecurrence ? nil : normalizedRecurrence(reminder.recurrenceRule).rule
        return RemindersSyncTaskChanges(
            title: reminder.title.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: reminder.notes,
            dueAt: dueAt,
            priority: scribePriority(fromReminderPriority: reminder.priority),
            recurrenceRule: dueAt == nil ? nil : rule,
            projectId: projectId
        )
    }

    /// Done in Scribe terms: completed or cancelled ("Won't do").
    static func isDone(_ task: TodoTask) -> Bool {
        task.completedAt != nil || task.cancelledAt != nil
    }
}

// MARK: - Recurrence descriptor

/// EventKit-free description of an `EKRecurrenceRule`, so the conversion to and
/// from Scribe's RRULE subset is testable. The adapter fills it from (and
/// builds an `EKRecurrenceRule` out of) the real object.
struct RemindersRecurrenceDescriptor: Equatable, Sendable {

    enum Frequency: Equatable, Sendable {
        case daily, weekly, monthly, yearly
    }

    struct DayOfWeek: Equatable, Sendable {
        /// Gregorian weekday, Sunday = 1 … Saturday = 7 (same as EKWeekday).
        var weekday: Int
        /// 0 = every such weekday; 1…5 = the Nth; -1 = the last.
        var weekNumber: Int

        init(weekday: Int, weekNumber: Int = 0) {
            self.weekday = weekday
            self.weekNumber = weekNumber
        }
    }

    var frequency: Frequency
    var interval: Int
    var daysOfWeek: [DayOfWeek]
    /// The rule has an end (date or count).
    var hasEnd: Bool
    /// The rule uses days-of-month, months, weeks/days-of-year or set positions.
    var hasOtherConstraints: Bool

    init(
        frequency: Frequency,
        interval: Int = 1,
        daysOfWeek: [DayOfWeek] = [],
        hasEnd: Bool = false,
        hasOtherConstraints: Bool = false
    ) {
        self.frequency = frequency
        self.interval = interval
        self.daysOfWeek = daysOfWeek
        self.hasEnd = hasEnd
        self.hasOtherConstraints = hasOtherConstraints
    }

    /// The equivalent Scribe RRULE, or nil when Scribe can't represent it
    /// ("simple" = daily / weekly (optionally on weekdays) / monthly (optionally
    /// on the Nth weekday), with no end).
    var rrule: String? {
        guard !hasEnd, !hasOtherConstraints, interval >= 1 else { return nil }
        switch frequency {
        case .yearly:
            return nil
        case .daily:
            guard daysOfWeek.isEmpty else { return nil }
            return RecurrenceRule(frequency: .daily, interval: interval, byDay: [], byOrdinalWeekday: nil).rruleString
        case .weekly:
            var days: [RecurrenceRule.Weekday] = []
            for day in daysOfWeek {
                guard day.weekNumber == 0, let weekday = Self.weekday(day.weekday) else { return nil }
                if !days.contains(weekday) { days.append(weekday) }
            }
            let order = RecurrenceRule.Weekday.allCases
            days.sort { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
            return RecurrenceRule(frequency: .weekly, interval: interval, byDay: days, byOrdinalWeekday: nil).rruleString
        case .monthly:
            if daysOfWeek.isEmpty {
                return RecurrenceRule(frequency: .monthly, interval: interval, byDay: [], byOrdinalWeekday: nil).rruleString
            }
            guard daysOfWeek.count == 1,
                  let day = daysOfWeek.first,
                  day.weekNumber == -1 || (1...5).contains(day.weekNumber),
                  let weekday = Self.weekday(day.weekday) else { return nil }
            let ordinal = RecurrenceRule.OrdinalWeekday(ordinal: day.weekNumber, weekday: weekday)
            return RecurrenceRule(frequency: .monthly, interval: interval, byDay: [], byOrdinalWeekday: ordinal).rruleString
        }
    }

    /// Builds the descriptor for a Scribe RRULE (nil when it doesn't parse).
    init?(rrule: String) {
        guard let rule = try? RecurrenceRule.parse(rrule),
              !RemindersFieldMapping.usesExtendedRecurrence(rule) else { return nil }
        let frequency: Frequency
        switch rule.frequency {
        case .daily:   frequency = .daily
        case .weekly:  frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly:  return nil
        }
        var days: [DayOfWeek] = []
        if let ordinal = rule.byOrdinalWeekday {
            days = [DayOfWeek(weekday: ordinal.weekday.calendarWeekday, weekNumber: ordinal.ordinal)]
        } else {
            days = rule.byDay.map { DayOfWeek(weekday: $0.calendarWeekday, weekNumber: 0) }
        }
        self.init(frequency: frequency, interval: rule.interval, daysOfWeek: days)
    }

    private static func weekday(_ number: Int) -> RecurrenceRule.Weekday? {
        RecurrenceRule.Weekday.allCases.first { $0.calendarWeekday == number }
    }
}
