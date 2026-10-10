import Combine
import EventKit
import Foundation
import SwiftUI
import UIKit

/// Calendar events for the iOS Today screen and day planner. Off until the
/// user turns "Show calendar events" on (Settings → Tasks, or the prompt row
/// in Today / the planner) — only then is calendar access requested.
@MainActor
final class TasksCalendarEventsModel: ObservableObject {
    static let shared = TasksCalendarEventsModel()

    /// UserDefaults key for the opt-in.
    nonisolated static let enabledKey = "iosTasksShowCalendarEvents"

    @Published private(set) var isGranted: Bool
    @Published private(set) var isEnabled: Bool
    /// Bumped whenever the calendar database changes, so screens reload.
    @Published private(set) var revision = 0

    private lazy var source = TasksCalendarEventSource()
    private var storeObserver: (any NSObjectProtocol)?

    init() {
        isGranted = TasksCalendarEventSource.hasFullAccess()
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.revision += 1 }
        }
    }

    /// Whether events can be shown right now.
    var isActive: Bool { isEnabled && isGranted }

    /// Turns the feature on, asking for full calendar access if undecided.
    func enable() async {
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        isEnabled = true
        if !TasksCalendarEventSource.hasFullAccess() {
            _ = await source.requestFullAccess()
        }
        refreshAccess()
        revision += 1
    }

    func disable() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        isEnabled = false
    }

    func refreshAccess() {
        let granted = TasksCalendarEventSource.hasFullAccess()
        if granted != isGranted { isGranted = granted }
        let enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if enabled != isEnabled { isEnabled = enabled }
    }

    /// Events overlapping `day` (all calendars), soonest first. Empty while
    /// the feature is off.
    func events(on day: Date) -> [CalendarEventInfo] {
        guard isActive else { return [] }
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return source.events(from: start, to: end).sorted { a, b in
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            return a.start != b.start ? a.start < b.start : a.id < b.id
        }
    }
}

/// Owns the `EKEventStore` outside any actor (EventKit calls its completion
/// handlers on arbitrary queues) and maps `EKEvent` into `CalendarEventInfo`.
final class TasksCalendarEventSource: @unchecked Sendable {
    private let store = EKEventStore()

    static func hasFullAccess() -> Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func requestFullAccess() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            store.requestFullAccessToEvents { granted, error in
                if let error {
                    Log.app.error("Calendar access request failed: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: granted)
            }
        }
    }

    func events(from start: Date, to end: Date) -> [CalendarEventInfo] {
        guard end > start, Self.hasFullAccess() else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap(Self.info(for:))
    }

    private static func info(for event: EKEvent) -> CalendarEventInfo? {
        // Typed as optionals so this works whether the SDK imports these as
        // implicitly-unwrapped or non-optional.
        let startDate: Date? = event.startDate
        let endDate: Date? = event.endDate
        guard let start = startDate, let end = endDate else { return nil }
        let identifier: String? = event.eventIdentifier
        let title: String? = event.title
        let attendees: [CalendarAttendee] = (event.attendees ?? []).compactMap { participant in
            let url: URL? = participant.url
            var email: String?
            if let url, url.scheme?.lowercased() == "mailto" {
                let address = url.absoluteString.dropFirst("mailto:".count)
                email = address.removingPercentEncoding ?? String(address)
            }
            let name = participant.name ?? ""
            if name.isEmpty && (email ?? "").isEmpty { return nil }
            return CalendarAttendee(name: name, email: email)
        }
        return CalendarEventInfo(
            id: identifier ?? "\(title ?? "event")@\(Int(start.timeIntervalSince1970))",
            title: title ?? "",
            start: start,
            end: end,
            attendees: attendees,
            notes: event.notes,
            url: event.url,
            location: event.location,
            isAllDay: event.isAllDay
        )
    }
}

/// "Show calendar events" prompt row for Today / the planner.
struct TasksCalendarPromptRow: View {
    @ObservedObject var calendar: TasksCalendarEventsModel

    var body: some View {
        if !calendar.isEnabled {
            Button {
                Task { await calendar.enable() }
            } label: {
                Label("Show calendar events", systemImage: "calendar.badge.plus")
            }
        } else if !calendar.isGranted {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Allow calendar access in Settings", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// One calendar event row (time, title, location, join link for meetings).
struct TasksCalendarEventRow: View {
    let event: CalendarEventInfo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isMeeting ? Color.purple : Color.accentColor)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.displayTitle).font(.subheadline.weight(.medium))
                Text(timeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let location = event.location, !location.isEmpty, event.meetingURL == nil {
                    Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let url = event.meetingURL {
                Link(destination: url) {
                    Label("Join", systemImage: "video.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var isMeeting: Bool { event.hasMultipleAttendees || event.meetingURL != nil }

    private var timeText: String {
        if event.isAllDay { return "All day" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }
}
