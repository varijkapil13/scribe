// ScribeiOS/Recording/MobileCalendarLookup.swift
//
// Names a new recording after the calendar event in progress, when the user
// allowed it. Reuses the portable Mac pieces: `CalendarStore` (EventKit
// wrapper) and `CalendarEventMatcher` (pure matching). The Mac's
// `CalendarService` (refresh loop + reminder notifications) is not used here.

import EventKit
import Foundation

@MainActor
enum MobileCalendarLookup {

    /// Settings › Recording › "Name recordings after calendar events".
    static var isEnabled: Bool { MobileRecordingSettings.useCalendar }

    /// Whether Scribe can read events.
    static var hasFullAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Asks for full calendar access (only when not decided yet). Returns
    /// whether events can be read.
    static func requestAccess() async -> Bool {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            _ = await CalendarStore().requestFullAccess()
        }
        return hasFullAccess
    }

    /// The event a recording starting at `date` belongs to, or nil when the
    /// feature is off, access isn't granted, or nothing matches. Never prompts.
    static func matchingEvent(at date: Date) -> CalendarEventInfo? {
        guard isEnabled, hasFullAccess else { return nil }
        let window = CalendarEventMatcher.defaultWindow
        let events = CalendarStore().events(
            from: date.addingTimeInterval(-6 * 60 * 60),
            to: date.addingTimeInterval(window + 60)
        )
        return CalendarEventMatcher.bestMatch(in: events, at: date, window: window)
    }
}
