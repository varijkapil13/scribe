import Foundation

/// UserDefaults-backed settings for the Apple Reminders sync (Settings →
/// Reminders). Off by default: nothing touches EventKit — and no permission
/// prompt appears — until the user turns the sync on.
enum RemindersSyncSettings {

    static let enabledKey = "remindersSyncEnabled"
    /// `EKCalendar.calendarIdentifier` of the list paired with the Scribe
    /// Inbox. Empty = the default Reminders list.
    static let inboxListKey = "remindersSyncInboxListId"
    /// Pair Scribe projects with Reminders lists of the same name.
    static let mapProjectsKey = "remindersSyncMapProjectsByName"
    /// `RemindersSyncDirection.rawValue`.
    static let directionKey = "remindersSyncDirection"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// The explicitly chosen Inbox list, or nil for "default list".
    static var inboxListId: String? {
        let value = UserDefaults.standard.string(forKey: inboxListKey) ?? ""
        return value.isEmpty ? nil : value
    }

    static var mapProjectsByName: Bool {
        UserDefaults.standard.bool(forKey: mapProjectsKey)
    }

    static var direction: RemindersSyncDirection {
        let raw = UserDefaults.standard.string(forKey: directionKey) ?? ""
        return RemindersSyncDirection(rawValue: raw) ?? .twoWay
    }

    /// Changes whenever any setting that affects what a round does changes
    /// (used to resync on settings edits without reacting to unrelated
    /// UserDefaults traffic).
    static var signature: String {
        "\(isEnabled)|\(inboxListId ?? "")|\(mapProjectsByName)|\(direction.rawValue)"
    }
}
