import Combine
import Foundation
import UserNotifications

/// Keeps pre-meeting briefs for the upcoming calendar events (menu-bar
/// "Upcoming" section) and schedules a brief notification a few minutes
/// before each meeting. Follows `CalendarService.upcomingEvents`; the
/// notifications reuse the calendar reminder category, so "Start Recording"
/// / "Join & Record" work exactly like the 1-minute reminder.
@MainActor
final class MeetingBriefService: ObservableObject {

    static let shared = MeetingBriefService(dbManager: .shared)

    /// Briefs keyed by `MeetingBriefBuilder.key(for:)`. Events without any
    /// related history have no entry.
    @Published private(set) var briefs: [String: MeetingBrief] = [:]

    private let repository: MeetingBriefRepository
    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var started = false

    /// Briefs are only built for events starting within this window.
    private static let horizon: TimeInterval = 24 * 60 * 60
    private static let maxEvents = 12
    nonisolated static let identifierPrefix = "scribe.calendar.brief."
    private static let scheduledIdsKey = "copilotBriefScheduledIds"

    init(dbManager: DatabaseManager) {
        self.repository = MeetingBriefRepository(dbManager: dbManager)
    }

    /// Starts following the calendar. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        CalendarService.shared.$upcomingEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] events in
                self?.refresh(events: events)
            }
            .store(in: &cancellables)
        // Re-plan notifications when the brief settings change.
        let initial = (CopilotSettings.briefNotificationsEnabled(.standard), CopilotSettings.briefLeadMinutes(.standard))
        // Hop to the main queue first: defaults can change on any thread.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .map { _ in
                (CopilotSettings.briefNotificationsEnabled(.standard), CopilotSettings.briefLeadMinutes(.standard))
            }
            .prepend(initial)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleNotifications(events: CalendarService.shared.upcomingEvents)
            }
            .store(in: &cancellables)
    }

    /// The brief for `event`, if it has one.
    func brief(for event: CalendarEventInfo) -> MeetingBrief? {
        briefs[MeetingBriefBuilder.key(for: event)]
    }

    /// Rebuilds briefs for `events` off the main actor, then reschedules the
    /// brief notifications.
    func refresh(events: [CalendarEventInfo]) {
        let now = Date()
        let relevant = Array(
            events
                .filter { !$0.isAllDay && $0.end > now && $0.start.timeIntervalSince(now) <= Self.horizon }
                .prefix(Self.maxEvents)
        )
        refreshTask?.cancel()
        let repository = self.repository
        refreshTask = Task { [weak self] in
            let built = await Task.detached(priority: .utility) { () -> [String: MeetingBrief] in
                var out: [String: MeetingBrief] = [:]
                for event in relevant {
                    guard let candidates = try? repository.candidates(for: event, now: now) else { continue }
                    let brief = MeetingBriefBuilder.build(event: event, candidates: candidates, now: now)
                    if !brief.isEmpty { out[MeetingBriefBuilder.key(for: event)] = brief }
                }
                return out
            }.value
            guard !Task.isCancelled, let self else { return }
            self.briefs = built
            self.scheduleNotifications(events: relevant)
        }
    }

    // MARK: Notifications

    private func scheduleNotifications(events: [CalendarEventInfo]) {
        let enabled = CopilotSettings.briefNotificationsEnabled(.standard)
            && CalendarService.isEnabled
            && CalendarService.remindersEnabled
        let lead = TimeInterval(CopilotSettings.briefLeadMinutes(.standard) * 60)
        let planned = enabled
            ? CalendarReminderPlanner.plan(events: events, now: Date(), leadTime: lead)
            : []
        let payloads: [CalendarReminderPayload] = planned.compactMap { reminder in
            guard let brief = self.brief(for: reminder.event) else { return nil }
            return CalendarReminderPayload(
                identifier: Self.identifier(for: reminder.event),
                title: Self.title(for: reminder.event, leadMinutes: Int(lead / 60)),
                body: brief.notificationBody,
                categoryId: reminder.event.meetingURL == nil
                    ? CalendarReminderScheduler.categoryId
                    : CalendarReminderScheduler.categoryWithLinkId,
                userInfo: Self.userInfo(for: reminder.event),
                fireDate: reminder.fireDate
            )
        }

        let newIds = payloads.map(\.identifier)
        let previousIds = UserDefaults.standard.stringArray(forKey: Self.scheduledIdsKey) ?? []
        let stale = previousIds.filter { !newIds.contains($0) }
        if !stale.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: stale)
        }
        if previousIds != newIds {
            UserDefaults.standard.set(newIds, forKey: Self.scheduledIdsKey)
        }
        guard !payloads.isEmpty else { return }
        Task {
            guard await TaskReminderScheduler.shared.ensureAuthorized() else { return }
            for payload in payloads {
                CalendarReminderPayload.schedule(payload)
            }
        }
    }

    /// Notification id for one occurrence (distinct from the 1-minute
    /// reminder's id so both can be pending).
    nonisolated static func identifier(for event: CalendarEventInfo) -> String {
        identifierPrefix + MeetingBriefBuilder.key(for: event)
    }

    /// "Brief: Weekly Sync in 5 min".
    nonisolated static func title(for event: CalendarEventInfo, leadMinutes: Int) -> String {
        "Brief: \(event.displayTitle) in \(max(1, leadMinutes)) min"
    }

    /// Same keys `CalendarReminderScheduler` reads back for its actions.
    nonisolated static func userInfo(for event: CalendarEventInfo) -> [String: String] {
        var info: [String: String] = [
            CalendarReminderScheduler.userInfoEventId: event.id,
            CalendarReminderScheduler.userInfoTitle: event.title,
            CalendarReminderScheduler.userInfoStart: String(event.start.timeIntervalSince1970),
            CalendarReminderScheduler.userInfoEnd: String(event.end.timeIntervalSince1970),
        ]
        if let url = event.meetingURL {
            info[CalendarReminderScheduler.userInfoURL] = url.absoluteString
        }
        return info
    }
}
