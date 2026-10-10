import Foundation

/// Recognises calendar events that are Scribe's own mirrored time blocks
/// (`TaskCalendarMirrorService` on the Mac writes one event per scheduled
/// task), so a planner that has no link rows for them — the iPhone / iPad,
/// which sees the Mac's blocks through the synced calendar — doesn't draw each
/// task twice. Pure.
enum PlannerMirroredEventFilter {

    /// Seconds of slack when comparing an event to a task block (calendar
    /// servers may round to the minute).
    static let tolerance: TimeInterval = 60

    /// Ids of timed events matching a scheduled open task's block exactly:
    /// same title, start and end (within `tolerance`).
    static func hiddenEventIds(
        events: [CalendarEventInfo],
        tasks: [TodoTask],
        calendar: Calendar
    ) -> Set<String> {
        let drafts = tasks.compactMap { TaskCalendarMirrorPlanner.draft(for: $0, calendar: calendar) }
        guard !drafts.isEmpty else { return [] }
        var hidden = Set<String>()
        for event in events where !event.isAllDay {
            let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = drafts.contains { draft in
                draft.title == title
                    && abs(draft.start.timeIntervalSince(event.start)) <= tolerance
                    && abs(draft.end.timeIntervalSince(event.end)) <= tolerance
            }
            if matches { hidden.insert(event.id) }
        }
        return hidden
    }
}
