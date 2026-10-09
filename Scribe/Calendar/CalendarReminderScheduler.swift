import AppKit
import Foundation
import UserNotifications

/// Pre-meeting reminders: a local notification ~1 minute before each upcoming
/// event with at least two attendees — "Weekly Sync starts in 1 min" — with a
/// "Start Recording" action and, when the invite has a video-call link, a
/// "Join & Record" action that opens the link and starts recording.
///
/// `CalendarService` calls `reschedule(events:)` after every refresh. Responses
/// arrive through `NotificationRouter` (the shared delegate lives in
/// `TaskReminderScheduler`).
@MainActor
final class CalendarReminderScheduler {

    static let shared = CalendarReminderScheduler()

    // MARK: - Notification identifiers

    nonisolated static let categoryId = "scribe.calendar.reminder"
    nonisolated static let categoryWithLinkId = "scribe.calendar.reminder-link"
    nonisolated static let actionStart = "scribe.calendar.start"
    nonisolated static let actionJoin = "scribe.calendar.join"
    nonisolated static let userInfoEventId = "eventId"
    nonisolated static let userInfoTitle = "title"
    nonisolated static let userInfoStart = "start"
    nonisolated static let userInfoEnd = "end"
    nonisolated static let userInfoURL = "url"

    /// Reminder lead time.
    static let leadTime: TimeInterval = 60

    /// Ids of the reminders currently scheduled, persisted so a relaunch can
    /// cancel reminders for events that were since moved or deleted.
    private static let scheduledIdsKey = "calendarScheduledReminderIds"

    static var notificationCategories: Set<UNNotificationCategory> {
        let start = UNNotificationAction(identifier: actionStart, title: "Start Recording", options: [])
        let join = UNNotificationAction(identifier: actionJoin, title: "Join & Record", options: [])
        return [
            UNNotificationCategory(identifier: categoryId, actions: [start],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: categoryWithLinkId, actions: [join, start],
                                   intentIdentifiers: [], options: []),
        ]
    }

    // MARK: - Wiring

    private var startRecording: (@MainActor (CalendarEventInfo) async -> Void)?

    /// Supplies the app's "record this event" action (AppDelegate).
    func configure(startRecording: @escaping @MainActor (CalendarEventInfo) async -> Void) {
        self.startRecording = startRecording
    }

    // MARK: - Scheduling

    /// Replaces all pending calendar reminders with ones for `events`.
    func reschedule(events: [CalendarEventInfo]) {
        let reminders = CalendarReminderPlanner.plan(
            events: events, now: Date(), leadTime: Self.leadTime
        )
        let newIds = reminders.map(\.identifier)
        let previousIds = UserDefaults.standard.stringArray(forKey: Self.scheduledIdsKey) ?? []
        let stale = previousIds.filter { !newIds.contains($0) }

        if !stale.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: stale)
        }
        if previousIds != newIds {
            UserDefaults.standard.set(newIds, forKey: Self.scheduledIdsKey)
        }
        guard !reminders.isEmpty else { return }

        let payloads = reminders.map { reminder in
            CalendarReminderPayload(
                identifier: reminder.identifier,
                title: CalendarReminderPlanner.reminderTitle(for: reminder.event, leadTime: Self.leadTime),
                body: Self.body(for: reminder.event),
                categoryId: reminder.event.meetingURL == nil ? Self.categoryId : Self.categoryWithLinkId,
                userInfo: Self.userInfo(for: reminder.event),
                fireDate: reminder.fireDate
            )
        }
        Task {
            guard await TaskReminderScheduler.shared.ensureAuthorized() else {
                Log.app.info("Calendar reminders skipped — notifications not authorized.")
                return
            }
            for payload in payloads {
                CalendarReminderPayload.schedule(payload)
            }
        }
    }

    // MARK: - Responses

    /// Routed from `NotificationRouter` for the calendar categories.
    func handleNotificationResponse(categoryId: String, actionId: String, userInfo: [String: String]) {
        guard actionId == Self.actionStart || actionId == Self.actionJoin else { return }
        guard let event = Self.event(from: userInfo) else { return }

        let link = event.meetingURL ?? userInfo[Self.userInfoURL].flatMap { URL(string: $0) }
        if actionId == Self.actionJoin, let link {
            NSWorkspace.shared.open(link)
        }
        Task { await startRecording?(event) }
    }

    // MARK: - Helpers

    private static func body(for event: CalendarEventInfo) -> String {
        let names = event.attendees.map(\.displayName).filter { !$0.isEmpty }
        if names.isEmpty { return "Start transcribing with Scribe?" }
        let shown = names.prefix(3).joined(separator: ", ")
        let more = names.count > 3 ? " +\(names.count - 3)" : ""
        return "With \(shown)\(more). Start transcribing?"
    }

    private static func userInfo(for event: CalendarEventInfo) -> [String: String] {
        var info: [String: String] = [
            userInfoEventId: event.id,
            userInfoTitle: event.title,
            userInfoStart: String(event.start.timeIntervalSince1970),
            userInfoEnd: String(event.end.timeIntervalSince1970),
        ]
        if let url = event.meetingURL { info[userInfoURL] = url.absoluteString }
        return info
    }

    /// The full event (attendees, notes) when it's still in the upcoming list,
    /// otherwise a minimal one rebuilt from the notification.
    private static func event(from userInfo: [String: String]) -> CalendarEventInfo? {
        guard let id = userInfo[userInfoEventId] else { return nil }
        let start = userInfo[userInfoStart].flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
        if let live = CalendarService.shared.upcomingEvent(id: id, start: start) {
            return live
        }
        let startDate = start ?? Date()
        let end = userInfo[userInfoEnd].flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
        return CalendarEventInfo(
            id: id,
            title: userInfo[userInfoTitle] ?? "",
            start: startDate,
            end: end ?? startDate.addingTimeInterval(30 * 60),
            url: userInfo[userInfoURL].flatMap { URL(string: $0) }
        )
    }
}

/// Sendable bundle for one reminder; builds the (non-Sendable)
/// `UNNotificationRequest` outside the main actor so the completion handler
/// never inherits main-actor isolation.
struct CalendarReminderPayload: Sendable {
    let identifier: String
    let title: String
    let body: String
    let categoryId: String
    let userInfo: [String: String]
    let fireDate: Date

    static func schedule(_ payload: CalendarReminderPayload) {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.categoryIdentifier = payload.categoryId
        content.userInfo = payload.userInfo
        content.sound = .default
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: payload.fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: payload.identifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.app.error("Failed to schedule calendar reminder: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
