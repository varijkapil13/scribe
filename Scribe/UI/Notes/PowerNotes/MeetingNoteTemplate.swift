// Scribe/UI/Notes/PowerNotes/MeetingNoteTemplate.swift
import Foundation

extension AppDelegate {
    /// Initial body for an auto-created meeting note: the Settings-chosen
    /// meeting template when one is set (filled with the event / meeting
    /// details), else the calendar header used before templates existed
    /// (`calendarHeader`, empty when the note isn't named after an event).
    static func meetingNoteInitialBody(
        event: CalendarEventInfo?,
        namesNote: Bool,
        meetingName: String?,
        now: Date
    ) -> String {
        let fallback = namesNote ? (event.map(CalendarNoteFormatter.noteHeader(for:)) ?? "") : ""
        let title: String
        if namesNote, let event {
            title = CalendarNoteFormatter.noteTitle(for: event, date: now)
        } else {
            title = event?.displayTitle ?? meetingName ?? "Meeting"
        }
        return NoteTemplateDefaults.meetingNoteBody(
            fileStore: NoteStore.shared.fileStore,
            fallback: fallback,
            title: title,
            meetingTitle: event?.displayTitle ?? meetingName,
            attendees: event?.attendees.map(\.displayName) ?? [],
            date: now
        )
    }
}
