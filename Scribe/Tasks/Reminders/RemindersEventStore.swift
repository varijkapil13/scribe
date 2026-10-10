#if os(macOS)
import EventKit
import Foundation

/// Owns the `EKEventStore` used for the Reminders sync, outside any actor so
/// EventKit's completion handlers (called on arbitrary queues) never inherit
/// main-actor isolation. Converts `EKReminder` into the Sendable
/// `RemindersSyncReminder` snapshots the planner works on, and applies plan
/// steps given as plain values. No `EKReminder` ever leaves this type.
///
/// `@unchecked Sendable`: `EKEventStore` is documented as safe to use from
/// multiple threads; this class adds no mutable state of its own.
final class RemindersEventStore: @unchecked Sendable {

    private let store = EKEventStore()

    // MARK: - Access

    enum Access: Equatable, Sendable {
        case notDetermined, granted, denied, restricted, writeOnly

        var label: String {
            switch self {
            case .notDetermined: return "Not requested"
            case .granted:       return "Full access granted"
            case .denied:        return "Denied"
            case .restricted:    return "Restricted"
            case .writeOnly:     return "Add-only (needs full access)"
            }
        }
    }

    static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .notDetermined: return .notDetermined
        case .fullAccess:    return .granted
        case .writeOnly:     return .writeOnly
        case .restricted:    return .restricted
        case .denied:        return .denied
        @unknown default:    return .denied
        }
    }

    func requestFullAccess() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            store.requestFullAccessToReminders { granted, error in
                if let error {
                    Log.app.error("Reminders access request failed: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Lists

    /// Every Reminders list the user can edit, sorted by title.
    func reminderLists() -> [RemindersListInfo] {
        store.calendars(for: .reminder)
            .filter { $0.allowsContentModifications }
            .map { RemindersListInfo(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The list Reminders adds new reminders to by default.
    func defaultListId() -> String? {
        store.defaultCalendarForNewReminders()?.calendarIdentifier
    }

    // MARK: - Snapshot

    /// Every reminder in every list (read-only ones too, so a linked reminder
    /// whose list became read-only doesn't look deleted), completed ones
    /// included. Nil when EventKit couldn't deliver them (the round must then
    /// do nothing — an incomplete snapshot would look like deletions).
    func fetchReminderSnapshots(calendar: Calendar) async -> [RemindersSyncReminder]? {
        let lists = store.calendars(for: .reminder)
        guard !lists.isEmpty else { return [] }
        let predicate = store.predicateForReminders(in: lists)
        return await withCheckedContinuation { (continuation: CheckedContinuation<[RemindersSyncReminder]?, Never>) in
            _ = store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(returning: nil)
                    return
                }
                let snapshots = reminders.compactMap { Self.snapshot(of: $0, calendar: calendar) }
                continuation.resume(returning: snapshots)
            }
        }
    }

    private static func snapshot(of reminder: EKReminder, calendar: Calendar) -> RemindersSyncReminder? {
        // Typed as optionals so this works whether the SDK imports these as
        // implicitly-unwrapped or non-optional.
        let listCalendar: EKCalendar? = reminder.calendar
        guard let listId = listCalendar?.calendarIdentifier else { return nil }
        let title: String? = reminder.title
        let external: String? = reminder.calendarItemExternalIdentifier

        let rules = reminder.recurrenceRules ?? []
        var rrule: String?
        var unsupported = false
        if rules.count == 1, let rule = rules.first {
            rrule = descriptor(for: rule).rrule
            unsupported = rrule == nil
        } else if rules.count > 1 {
            unsupported = true
        }

        return RemindersSyncReminder(
            calendarItemIdentifier: reminder.calendarItemIdentifier,
            externalIdentifier: external,
            listId: listId,
            title: title ?? "",
            notes: reminder.notes ?? "",
            due: due(from: reminder.dueDateComponents, calendar: calendar),
            priority: reminder.priority,
            isCompleted: reminder.isCompleted,
            completionDate: reminder.completionDate,
            recurrenceRule: rrule,
            hasUnsupportedRecurrence: unsupported,
            lastModifiedAt: reminder.lastModifiedDate,
            creationDate: reminder.creationDate
        )
    }

    // MARK: - Writes (each committed immediately)

    struct Stamp: Sendable {
        var calendarItemIdentifier: String
        var externalIdentifier: String?
        var modifiedAt: Date
    }

    /// Creates a reminder; returns its identifier.
    func createReminder(
        listId: String,
        fields: RemindersSyncFields,
        isCompleted: Bool,
        completionDate: Date?,
        calendar: Calendar
    ) throws -> String? {
        guard let list = store.calendar(withIdentifier: listId) else { return nil }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        Self.apply(fields, to: reminder, includeRecurrence: true, calendar: calendar)
        if isCompleted {
            reminder.isCompleted = true
            reminder.completionDate = completionDate ?? Date()
        }
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    /// Overwrites a reminder's fields. Returns false when it no longer exists.
    func updateReminder(
        id: String,
        moveToListId: String?,
        fields: RemindersSyncFields,
        includeRecurrence: Bool,
        calendar: Calendar
    ) throws -> Bool {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return false }
        if let moveToListId, let list = store.calendar(withIdentifier: moveToListId) {
            reminder.calendar = list
        }
        Self.apply(fields, to: reminder, includeRecurrence: includeRecurrence, calendar: calendar)
        try store.save(reminder, commit: true)
        return true
    }

    func setCompletion(id: String, isCompleted: Bool, completionDate: Date?) throws -> Bool {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return false }
        reminder.isCompleted = isCompleted
        reminder.completionDate = isCompleted ? (completionDate ?? Date()) : nil
        try store.save(reminder, commit: true)
        return true
    }

    /// Deletes a reminder. Returns false when it was already gone.
    func removeReminder(id: String) throws -> Bool {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return false }
        try store.remove(reminder, commit: true)
        return true
    }

    /// Current identifiers + modification stamp of a reminder (for the link).
    func stamp(id: String) -> Stamp? {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return nil }
        let external: String? = reminder.calendarItemExternalIdentifier
        return Stamp(
            calendarItemIdentifier: reminder.calendarItemIdentifier,
            externalIdentifier: external,
            modifiedAt: reminder.lastModifiedDate ?? reminder.creationDate ?? RemindersSyncService.unknownStamp
        )
    }

    /// Drops cached objects so the next fetch sees other apps' edits.
    func reset() {
        store.reset()
    }

    // MARK: - Field conversion

    private static func apply(
        _ fields: RemindersSyncFields,
        to reminder: EKReminder,
        includeRecurrence: Bool,
        calendar: Calendar
    ) {
        reminder.title = fields.title
        reminder.notes = fields.notes.isEmpty ? nil : fields.notes
        reminder.priority = fields.priority
        reminder.dueDateComponents = dueComponents(for: fields.due, calendar: calendar)
        if includeRecurrence {
            if let raw = fields.recurrenceRule,
               fields.due != nil,
               let descriptor = RemindersRecurrenceDescriptor(rrule: raw),
               let rule = recurrenceRule(for: descriptor) {
                reminder.recurrenceRules = [rule]
            } else {
                reminder.recurrenceRules = nil
            }
        }
    }

    /// Date-only → year/month/day; date-time → down to the second, with the
    /// calendar's time zone.
    static func dueComponents(for due: RemindersSyncDue?, calendar: Calendar) -> DateComponents? {
        guard let due else { return nil }
        if due.hasTime {
            var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: due.date)
            parts.timeZone = calendar.timeZone
            return parts
        }
        return calendar.dateComponents([.year, .month, .day], from: due.date)
    }

    /// Components without an hour are date-only (local midnight).
    static func due(from components: DateComponents?, calendar: Calendar) -> RemindersSyncDue? {
        guard let components, let year = components.year, let month = components.month, let day = components.day else {
            return nil
        }
        if let hour = components.hour {
            var parts = DateComponents()
            parts.year = year
            parts.month = month
            parts.day = day
            parts.hour = hour
            parts.minute = components.minute ?? 0
            parts.second = components.second ?? 0
            parts.timeZone = components.timeZone ?? calendar.timeZone
            guard let date = calendar.date(from: parts) else { return nil }
            return RemindersSyncDue(date: date, hasTime: true)
        }
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        return RemindersSyncDue(date: calendar.startOfDay(for: date), hasTime: false)
    }

    // MARK: - Recurrence conversion (the only EventKit-specific bits)

    static func descriptor(for rule: EKRecurrenceRule) -> RemindersRecurrenceDescriptor {
        let frequency: RemindersRecurrenceDescriptor.Frequency
        switch rule.frequency {
        case .daily:   frequency = .daily
        case .weekly:  frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly:  frequency = .yearly
        @unknown default: frequency = .yearly   // treated as unsupported
        }
        let days = (rule.daysOfTheWeek ?? []).map {
            RemindersRecurrenceDescriptor.DayOfWeek(weekday: $0.dayOfTheWeek.rawValue, weekNumber: $0.weekNumber)
        }
        let other = !(rule.daysOfTheMonth ?? []).isEmpty
            || !(rule.monthsOfTheYear ?? []).isEmpty
            || !(rule.weeksOfTheYear ?? []).isEmpty
            || !(rule.daysOfTheYear ?? []).isEmpty
            || !(rule.setPositions ?? []).isEmpty
        return RemindersRecurrenceDescriptor(
            frequency: frequency,
            interval: rule.interval,
            daysOfWeek: days,
            hasEnd: rule.recurrenceEnd != nil,
            hasOtherConstraints: other
        )
    }

    static func recurrenceRule(for descriptor: RemindersRecurrenceDescriptor) -> EKRecurrenceRule? {
        let frequency: EKRecurrenceFrequency
        switch descriptor.frequency {
        case .daily:   frequency = .daily
        case .weekly:  frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly:  frequency = .yearly
        }
        var days: [EKRecurrenceDayOfWeek] = []
        for day in descriptor.daysOfWeek {
            guard let weekday = EKWeekday(rawValue: day.weekday) else { return nil }
            days.append(EKRecurrenceDayOfWeek(dayOfTheWeek: weekday, weekNumber: day.weekNumber))
        }
        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: max(1, descriptor.interval),
            daysOfTheWeek: days.isEmpty ? nil : days,
            daysOfTheMonth: nil,
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: nil
        )
    }
}
#endif
