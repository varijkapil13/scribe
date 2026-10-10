import Foundation

/// What the "Scribe Focus" filter (`Scribe/Intents/ScribeFocusFilter.swift`)
/// asked for while a Focus is on. The filter writes these flags to
/// `UserDefaults` when the system activates / deactivates the Focus (it calls
/// the filter again with the default values — all off — when the Focus ends);
/// notification code reads them through the helpers below.
///
/// Lives in `Scribe/Tasks` (Foundation only, iOS-safe) because the reminder
/// presentation hook is in `TaskReminderScheduler`, which the iOS target also
/// compiles. On iOS the flags are simply never set.
enum ScribeFocusPreferences {

    static let muteMeetingPromptsKey = "focusFilter.muteMeetingPrompts"
    static let hideRemindersKey = "focusFilter.hideReminders"

    /// Notification categories that count as "reminders": task reminders and
    /// calendar pre-meeting reminders (the latter mirror
    /// `CalendarReminderScheduler.categoryId` / `.categoryWithLinkId`, which are
    /// macOS-only and so can't be referenced from here; a test pins them).
    static let reminderCategoryIds: Set<String> = [
        TaskReminderScheduler.categoryId,
        "scribe.calendar.reminder",
        "scribe.calendar.reminder-link",
    ]

    /// True while the active Focus asks Scribe not to post meeting-detection
    /// prompts.
    nonisolated static func isMutingMeetingPrompts(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: muteMeetingPromptsKey)
    }

    /// True while the active Focus asks Scribe to hide reminder notifications.
    nonisolated static func isHidingReminders(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: hideRemindersKey)
    }

    /// Stores the filter's current values (called from the Focus filter's
    /// `perform()`).
    nonisolated static func apply(muteMeetingPrompts: Bool, hideReminders: Bool, defaults: UserDefaults = .standard) {
        defaults.set(muteMeetingPrompts, forKey: muteMeetingPromptsKey)
        defaults.set(hideReminders, forKey: hideRemindersKey)
    }

    /// Whether a notification in `categoryId` should be kept off screen while
    /// it would be presented (foreground delivery).
    nonisolated static func shouldSuppressPresentation(categoryId: String, hidingReminders: Bool) -> Bool {
        hidingReminders && reminderCategoryIds.contains(categoryId)
    }
}
