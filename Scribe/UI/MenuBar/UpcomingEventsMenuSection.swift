import AppKit
import SwiftUI

/// "Upcoming" section of the menu-bar menu: the next three calendar events
/// today. Choosing one starts a recording whose note is named after it.
/// Events with a pre-meeting brief (related earlier meetings, open action
/// items — see `MeetingBriefService`) become a submenu showing the brief.
/// Renders nothing while calendar integration is off (no events).
struct UpcomingEventsMenuSection: View {
    let events: [CalendarEventInfo]
    let onSelect: (CalendarEventInfo) -> Void

    @ObservedObject private var briefs = MeetingBriefService.shared

    var body: some View {
        let today = CalendarEventMatcher.upcomingToday(events, now: Date(), limit: 3)
        if !today.isEmpty {
            Divider()
            Section("Upcoming") {
                ForEach(today, id: \.self) { event in
                    let title = "\(event.start.formatted(date: .omitted, time: .shortened))  \(event.displayTitle)"
                    if let brief = briefs.brief(for: event) {
                        Menu(title) {
                            Button("Start Recording") { onSelect(event) }
                            Divider()
                            MeetingBriefMenuItems(brief: brief)
                        }
                    } else {
                        Button(title) {
                            onSelect(event)
                        }
                        .help("Record \(event.displayTitle)")
                    }
                }
            }
        }
    }
}

/// The brief as menu items: headline, related meetings (open their note),
/// open action items and questions, and "Copy Brief".
struct MeetingBriefMenuItems: View {
    let brief: MeetingBrief

    /// `scribe://meeting/<id>` for meetings, `scribe://note/<id>` for notes.
    static func link(for candidate: MeetingBriefCandidate) -> URL? {
        switch candidate.kind {
        case .meeting: return ScribeDeepLink.meeting(sessionId: candidate.id).url
        case .note:    return ScribeDeepLink.noteURL(id: candidate.id)
        }
    }

    var body: some View {
        Section("Brief") {
            Text(brief.headline)
            ForEach(Array(brief.matches.enumerated()), id: \.offset) { _, match in
                let date = MeetingRetrieval.dayString(match.candidate.date)
                let why = match.reasons.isEmpty ? "" : " — " + match.reasons.joined(separator: ", ")
                if let url = Self.link(for: match.candidate) {
                    Button("\(match.candidate.displayTitle) (\(date))\(why)") {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    Text("\(match.candidate.displayTitle) (\(date))\(why)")
                }
            }
        }
        if !brief.openActionItems.isEmpty {
            Section("Open action items") {
                ForEach(brief.openActionItems, id: \.self) { item in
                    Text(SessionBookmarkFormatter.quote(item, maxChars: 80))
                }
            }
        }
        if !brief.openQuestions.isEmpty {
            Section("Open questions") {
                ForEach(brief.openQuestions, id: \.self) { question in
                    Text(SessionBookmarkFormatter.quote(question, maxChars: 80))
                }
            }
        }
        Divider()
        Button("Copy Brief") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(brief.markdown, forType: .string)
        }
    }
}
