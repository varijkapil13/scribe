// ScribeiOS/System/ScribeiOSAppShortcuts.swift
//
// Siri / Spotlight / Shortcuts-gallery phrases on iPhone and iPad (the Mac's
// ScribeAppShortcuts isn't compiled here: it lists the Mac-only dictation
// action). At most ten App Shortcuts per app; every phrase names the app.

import AppIntents

struct ScribeiOSAppShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ScribeQuickCaptureIntent(),
            phrases: [
                "Quick capture in \(.applicationName)",
                "Capture with \(.applicationName)",
                "Jot something down in \(.applicationName)",
            ],
            shortTitle: "Quick Capture",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start recording in \(.applicationName)",
                "Record a meeting with \(.applicationName)",
                "Start a \(.applicationName) recording",
            ],
            shortTitle: "Start Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: [
                "Stop recording in \(.applicationName)",
                "Stop the \(.applicationName) recording",
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: ScribeTodayAgendaIntent(),
            phrases: [
                "What's on my \(.applicationName) list today",
                "Show today in \(.applicationName)",
            ],
            shortTitle: "Today",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: CreateNoteIntent(),
            phrases: [
                "Create a note in \(.applicationName)",
                "New \(.applicationName) note",
            ],
            shortTitle: "New Note",
            systemImageName: "doc.badge.plus"
        )
        AppShortcut(
            intent: CreateTaskIntent(),
            phrases: [
                "Add a task in \(.applicationName)",
                "Create a \(.applicationName) task",
            ],
            shortTitle: "New Task",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: OpenNoteIntent(),
            phrases: [
                "Open a note in \(.applicationName)",
            ],
            shortTitle: "Open Note",
            systemImageName: "doc.text"
        )
        AppShortcut(
            intent: SearchNotesIntent(),
            phrases: [
                "Search notes in \(.applicationName)",
                "Search \(.applicationName) notes",
            ],
            shortTitle: "Search Notes",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: GetMeetingSummaryIntent(),
            phrases: [
                "Summarize my last meeting in \(.applicationName)",
                "Get the meeting summary from \(.applicationName)",
            ],
            shortTitle: "Meeting Summary",
            systemImageName: "text.append"
        )
        AppShortcut(
            intent: GetMeetingTranscriptIntent(),
            phrases: [
                "Get the meeting transcript from \(.applicationName)",
            ],
            shortTitle: "Meeting Transcript",
            systemImageName: "text.quote"
        )
    }
}
