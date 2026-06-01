import SwiftUI

/// Builds the context-aware "Actions" rows for the ⌘K command palette — the
/// verbs that make Scribe's palette an Arc-style command bar rather than a
/// search box. `navigate` routes through the window's `NavigationCoordinator`;
/// recording verbs drive `AppDelegate`; create verbs use the stores +
/// `QuickAddParser`. This is the single source of verbs; the menu-bar tree
/// (Phase 1d) invokes the same closures so menu and palette never diverge.
@MainActor
enum CommandRegistry {

    static func actions(
        query: String,
        appState: AppState,
        appDelegate: AppDelegate,
        navigate: @escaping (MainSelection) -> Void
    ) -> [CommandItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var items: [CommandItem] = []

        // Recording — state-aware; live verbs pinned to the top during a meeting.
        if appState.isTranscribing {
            items.append(CommandItem(
                id: "rec.stop", title: "Stop Recording", subtitle: "End the current session",
                systemImage: "stop.circle.fill", shortcut: ["⇧", "⌘", "R"],
                kind: .action { Task { await appDelegate.toggleRecording() } }))
            if appState.audioManager.isPaused {
                items.append(CommandItem(
                    id: "rec.resume", title: "Resume Recording", systemImage: "play.fill",
                    kind: .action { Task { await appDelegate.resumeRecording() } }))
            } else {
                items.append(CommandItem(
                    id: "rec.pause", title: "Pause Recording", systemImage: "pause.fill",
                    kind: .action { appDelegate.pauseRecording() }))
            }
            items.append(CommandItem(
                id: "rec.jump", title: "Jump to Live", systemImage: "waveform",
                kind: .navigate(.live)))
        } else {
            items.append(CommandItem(
                id: "rec.start", title: "Start Recording", subtitle: "Capture a new meeting",
                systemImage: "record.circle", shortcut: ["⇧", "⌘", "R"],
                kind: .action { Task { await appDelegate.toggleRecording() } }))
        }

        // Capture from the typed query — the marquee speed win (Arc + QuickAdd).
        if !q.isEmpty {
            items.append(CommandItem(
                id: "new.task.q", title: "New Task: \(q)",
                subtitle: "Parses #tag +project !priority and dates",
                systemImage: "plus.circle.fill",
                kind: .action {
                    let parsed = QuickAddParser.parse(q)
                    let projectId = parsed.projectName.flatMap { name in
                        (try? TaskStore.shared.fetchProjects())?
                            .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
                    }
                    _ = try? TaskStore.shared.createTask(
                        title: parsed.title, projectId: projectId,
                        priority: parsed.priority, dueAt: parsed.dueAt, tags: parsed.tags)
                }))
            items.append(CommandItem(
                id: "new.note.q", title: "New Note: \(q)", systemImage: "square.and.pencil",
                kind: .action {
                    if let note = try? NoteStore.shared.createNote(title: q, body: "") {
                        navigate(.note(note.id))
                    }
                }))
        }

        // Create (static).
        items.append(CommandItem(
            id: "new.note", title: "New Note", systemImage: "square.and.pencil", shortcut: ["⌘", "N"],
            kind: .action {
                if let note = try? NoteStore.shared.createNote(title: "", body: "") {
                    navigate(.note(note.id))
                }
            }))
        items.append(CommandItem(
            id: "new.daily", title: "New Daily Note", systemImage: "sun.max",
            kind: .action {
                if let note = try? NoteStore.shared.dailyNote(for: Date()) {
                    navigate(.note(note.id))
                }
            }))

        // Navigate.
        items.append(CommandItem(id: "go.today", title: "Go to Today", systemImage: "sun.max", kind: .navigate(.today)))
        items.append(CommandItem(id: "go.tasks", title: "Go to Tasks", systemImage: "tray", kind: .navigate(.tasks(.inbox))))
        items.append(CommandItem(id: "go.notes", title: "Go to Notes", systemImage: "doc.on.doc", kind: .navigate(.notes(.all))))
        items.append(CommandItem(id: "go.calendar", title: "Task Calendar", systemImage: "calendar", kind: .navigate(.taskCalendar)))
        items.append(CommandItem(id: "go.graph", title: "Notes Graph", systemImage: "circle.hexagongrid", kind: .navigate(.notes(.graph))))
        items.append(CommandItem(id: "go.completed", title: "Completed Tasks", systemImage: "checkmark.circle", kind: .navigate(.tasks(.completed))))
        items.append(CommandItem(
            id: "go.settings", title: "Open Settings", systemImage: "gearshape", shortcut: ["⌘", ","],
            kind: .action { NotificationCenter.default.post(name: .openScribeSettings, object: SettingsPane.general) }))

        guard !q.isEmpty else { return items }
        let lower = q.lowercased()
        // Always keep the dynamic "New …: <q>" rows; filter the rest by title.
        return items.filter { $0.id.hasSuffix(".q") || $0.title.lowercased().contains(lower) }
    }
}
