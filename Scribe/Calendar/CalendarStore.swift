import EventKit
import Foundation

// Moved out of CalendarService.swift unchanged so the iPhone / iPad target
// can compile it: the EventKit wrapper is portable, while CalendarService
// itself drives the macOS-only CalendarReminderScheduler.

// MARK: - EventKit wrapper

/// Owns the `EKEventStore` outside any actor so EventKit's completion handlers
/// (called on arbitrary queues) never inherit main-actor isolation, and maps
/// `EKEvent` into the Sendable `CalendarEventInfo`. EKEventStore is safe to use
/// from multiple threads for reads.
final class CalendarStore: @unchecked Sendable {

    private let store = EKEventStore()

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

    /// Events overlapping `[start, end)` across all calendars.
    func events(from start: Date, to end: Date) -> [CalendarEventInfo] {
        guard end > start else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap(Self.info(for:))
    }

    private static func info(for event: EKEvent) -> CalendarEventInfo? {
        // Typed as optionals so this works whether the SDK imports these
        // properties as implicitly-unwrapped or non-optional.
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
