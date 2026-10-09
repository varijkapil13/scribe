import Foundation

// Pure calendar logic: no EventKit / AppKit here so everything is unit-testable
// without calendar permission. `CalendarService` maps `EKEvent`s into
// `CalendarEventInfo` values and hands them to these helpers.

/// A calendar event, decoupled from EventKit.
struct CalendarEventInfo: Identifiable, Equatable, Hashable, Sendable {
    typealias Attendee = CalendarAttendee

    /// EventKit event identifier (shared by every occurrence of a recurring
    /// event — pair with `start` when an occurrence must be unique).
    var id: String
    var title: String
    var start: Date
    var end: Date
    var attendees: [Attendee]
    var notes: String?
    var url: URL?
    var location: String?
    var isAllDay: Bool

    init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        attendees: [Attendee] = [],
        notes: String? = nil,
        url: URL? = nil,
        location: String? = nil,
        isAllDay: Bool = false
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.notes = notes
        self.url = url
        self.location = location
        self.isAllDay = isAllDay
    }

    /// The video-call link found in the event's URL, notes or location.
    var meetingURL: URL? {
        MeetingLinkExtractor.meetingURL(url: url, notes: notes, location: location)
    }

    /// True for events with at least two attendees — i.e. an actual meeting
    /// rather than a personal block.
    var hasMultipleAttendees: Bool { attendees.count >= 2 }

    /// Title with a fallback for untitled events.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Meeting" : trimmed
    }
}

// MARK: - Matching

/// Picks the calendar event a recording belongs to.
enum CalendarEventMatcher {

    /// How far from an event's start a recording still counts as "for" it.
    static let defaultWindow: TimeInterval = 15 * 60

    /// True when `event` is a candidate for a recording at `now`: not all-day,
    /// and either in progress or starting/started within `window` of `now`.
    static func isCandidate(
        _ event: CalendarEventInfo,
        at now: Date,
        window: TimeInterval = defaultWindow
    ) -> Bool {
        guard !event.isAllDay else { return false }
        let inProgress = event.start <= now && now < event.end
        let nearStart = abs(event.start.timeIntervalSince(now)) <= window
        return inProgress || nearStart
    }

    /// The best-matching event for a recording at `now`, or nil.
    ///
    /// Among candidates, prefers (in order): events with ≥2 attendees, events
    /// with a video-call link, then the event whose start is closest to `now`.
    static func bestMatch(
        in events: [CalendarEventInfo],
        at now: Date,
        window: TimeInterval = defaultWindow
    ) -> CalendarEventInfo? {
        let candidates = events.filter { isCandidate($0, at: now, window: window) }
        return candidates.min { lhs, rhs in
            if lhs.hasMultipleAttendees != rhs.hasMultipleAttendees {
                return lhs.hasMultipleAttendees
            }
            let lhsLink = lhs.meetingURL != nil
            let rhsLink = rhs.meetingURL != nil
            if lhsLink != rhsLink { return lhsLink }
            let lhsDistance = abs(lhs.start.timeIntervalSince(now))
            let rhsDistance = abs(rhs.start.timeIntervalSince(now))
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs.id < rhs.id
        }
    }

    /// The next `limit` timed events that haven't ended yet and start today
    /// (in `calendar`'s time zone), soonest first. Used by the menu bar.
    static func upcomingToday(
        _ events: [CalendarEventInfo],
        now: Date,
        limit: Int = 3,
        calendar: Calendar = .current
    ) -> [CalendarEventInfo] {
        let upcoming = events
            .filter { !$0.isAllDay && $0.end > now && calendar.isDate($0.start, inSameDayAs: now) }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        return Array(upcoming.prefix(max(0, limit)))
    }
}

// MARK: - Meeting links

/// Finds Zoom / Google Meet / Teams / Webex (and similar) join links.
enum MeetingLinkExtractor {

    /// Host suffixes that identify a video-call join link.
    static let meetingHosts: [String] = [
        "zoom.us",
        "zoom.com",
        "zoomgov.com",
        "meet.google.com",
        "teams.microsoft.com",
        "teams.live.com",
        "webex.com",
        "gotomeeting.com",
        "meet.goto.com",
        "whereby.com",
        "meet.jit.si",
        "chime.aws",
    ]

    /// True when `url` is an http(s) link on a known meeting host.
    static func isMeetingURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return false }
        return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The first meeting link in `text`, or nil.
    static func meetingURL(in text: String?) -> URL? {
        guard let text, !text.isEmpty else { return nil }
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            if let url = match.url, isMeetingURL(url) {
                return url
            }
        }
        return nil
    }

    /// The meeting link for an event: its URL field first, then the notes,
    /// then the location.
    static func meetingURL(url: URL?, notes: String?, location: String?) -> URL? {
        if let url, isMeetingURL(url) { return url }
        return meetingURL(in: notes) ?? meetingURL(in: location)
    }
}

// MARK: - Note formatting

/// Note title + body header for a recording that belongs to a calendar event.
enum CalendarNoteFormatter {

    /// Notes longer than this are truncated in the seeded header (invite
    /// bodies can carry pages of dial-in boilerplate).
    static let maxNotesLength = 2_000

    /// "Weekly Sync — Oct 9, 2026".
    static func noteTitle(
        for event: CalendarEventInfo,
        date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "\(event.displayTitle) — \(formatter.string(from: date))"
    }

    /// A small markdown header for the new note: attendees, agenda (the
    /// event's notes) and the join link. Empty when the event has none of
    /// them.
    static func noteHeader(for event: CalendarEventInfo) -> String {
        var sections: [String] = []

        let attendees = event.attendees.filter { !$0.displayName.isEmpty }
        if !attendees.isEmpty {
            let lines = attendees.map { attendee -> String in
                let name = attendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if let email = attendee.email, !email.isEmpty, !name.isEmpty, name != email {
                    return "- \(name) (\(email))"
                }
                return "- \(attendee.displayName)"
            }
            sections.append("**Attendees**\n" + lines.joined(separator: "\n"))
        }

        let notes = (event.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            let agenda = notes.count > maxNotesLength
                ? String(notes.prefix(maxNotesLength)) + "…"
                : notes
            sections.append("**Agenda**\n" + agenda)
        }

        if let link = event.meetingURL {
            sections.append("**Meeting link:** <\(link.absoluteString)>")
        }

        guard !sections.isEmpty else { return "" }
        return sections.joined(separator: "\n\n") + "\n\n---\n\n"
    }
}

// MARK: - Reminders

/// Decides which pre-meeting reminders to schedule.
enum CalendarReminderPlanner {

    struct Reminder: Equatable, Sendable {
        let identifier: String
        let fireDate: Date
        let event: CalendarEventInfo
    }

    static let identifierPrefix = "scribe.calendar.reminder."

    /// Reminder notification id for one occurrence of an event.
    static func identifier(for event: CalendarEventInfo) -> String {
        "\(identifierPrefix)\(event.id)@\(Int(event.start.timeIntervalSince1970))"
    }

    /// Reminders `leadTime` before each timed event with ≥2 attendees whose
    /// reminder time is still in the future and within `horizon` of `now`.
    static func plan(
        events: [CalendarEventInfo],
        now: Date,
        leadTime: TimeInterval = 60,
        horizon: TimeInterval = 24 * 60 * 60
    ) -> [Reminder] {
        var seen = Set<String>()
        return events
            .filter { !$0.isAllDay && $0.hasMultipleAttendees }
            .sorted { $0.start < $1.start }
            .compactMap { event -> Reminder? in
                let fire = event.start.addingTimeInterval(-leadTime)
                guard fire > now, fire.timeIntervalSince(now) <= horizon else { return nil }
                let id = identifier(for: event)
                guard seen.insert(id).inserted else { return nil }
                return Reminder(identifier: id, fireDate: fire, event: event)
            }
    }

    /// "Weekly Sync starts in 1 min".
    static func reminderTitle(for event: CalendarEventInfo, leadTime: TimeInterval = 60) -> String {
        let minutes = max(1, Int((leadTime / 60).rounded()))
        return "\(event.displayTitle) starts in \(minutes) min"
    }
}
