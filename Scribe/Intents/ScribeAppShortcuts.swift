import AppIntents

/// Siri / Spotlight / Shortcuts-gallery phrases. App Shortcuts are capped at
/// ten per app; every phrase must name the app via `.applicationName`.
struct ScribeAppShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
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
            intent: ToggleDictationIntent(),
            phrases: [
                "Toggle dictation in \(.applicationName)",
                "Dictate with \(.applicationName)",
            ],
            shortTitle: "Dictation",
            systemImageName: "mic"
        )
        AppShortcut(
            intent: CreateNoteIntent(),
            phrases: [
                "Create a note in \(.applicationName)",
                "New \(.applicationName) note",
            ],
            shortTitle: "New Note",
            systemImageName: "square.and.pencil"
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
            intent: CreateTaskIntent(),
            phrases: [
                "Add a task in \(.applicationName)",
                "Create a \(.applicationName) task",
            ],
            shortTitle: "New Task",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: ListTodayTasksIntent(),
            phrases: [
                "What's on my \(.applicationName) list today",
                "Show today's tasks in \(.applicationName)",
            ],
            shortTitle: "Today's Tasks",
            systemImageName: "calendar"
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
