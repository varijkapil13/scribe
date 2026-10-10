import Foundation

extension Notification.Name {
    /// Posted (main thread) after an in-app writer other than the note's
    /// editor rewrote a note file, e.g. Quick Capture appending to the daily
    /// note. `userInfo[NoteVaultChange.noteIdsKey]` is a `Set<String>` of
    /// note ids. An open editor reloads (or, with unsaved edits, keeps both
    /// versions) instead of overwriting the change with stale content.
    static let scribeNoteChangedInApp = Notification.Name("scribe.noteChangedInApp")
}

enum QuickCaptureSaveError: LocalizedError {
    /// Today's daily note exists but its file couldn't be read.
    case dailyNoteUnreadable

    var errorDescription: String? {
        switch self {
        case .dailyNoteUnreadable:
            return "Today's daily note couldn't be read from the vault, so nothing was added to it."
        }
    }
}

/// What a Quick Capture save produced: where it went (for "save and open")
/// and the toast text.
struct QuickCaptureSaveOutcome: Equatable {
    enum Destination: Equatable {
        case note(id: String)
        case task(id: String)
    }

    let destination: Destination
    let message: String

    /// Main-window destination for "save and open" (⌘Return).
    var selection: MainSelection {
        switch destination {
        case .note(let id): return .note(id)
        case .task(let id): return .task(id)
        }
    }
}

/// Persists a `QuickCaptureRequest` through the existing stores: notes via
/// `NoteStore.createNote`, tasks via `TaskStore.createTask` (project hint
/// resolved against existing projects), and daily-note entries appended to
/// the body of `NoteStore.dailyNote(for:)`.
///
/// Stores are passed in so tests can use an in-memory database.
struct QuickCaptureSaver {

    let noteStore: NoteStore
    let taskStore: TaskStore

    init(noteStore: NoteStore, taskStore: TaskStore) {
        self.noteStore = noteStore
        self.taskStore = taskStore
    }

    func save(_ request: QuickCaptureRequest, now: Date, timeZone: TimeZone) throws -> QuickCaptureSaveOutcome {
        switch request {
        case .note(let title, let body):
            let note = try noteStore.createNote(title: title, body: body)
            return QuickCaptureSaveOutcome(
                destination: .note(id: note.id),
                message: QuickCaptureComposer.confirmation(for: request, resolvedProject: nil)
            )

        case .task(let draft):
            var project: Project?
            if let name = draft.projectName {
                project = try Self.matchingProject(named: name, in: taskStore.fetchProjects())
            }
            let task = try taskStore.createTask(
                title: draft.title,
                notes: draft.notes,
                projectId: project?.id,
                priority: draft.priority,
                dueAt: draft.dueAt,
                tags: draft.tags
            )
            return QuickCaptureSaveOutcome(
                destination: .task(id: task.id),
                message: QuickCaptureComposer.confirmation(for: request, resolvedProject: project?.name)
            )

        case .appendToDaily(let text):
            let daily = try noteStore.dailyNote(for: now)
            // `dailyNote(for:)` returns the DB row, whose body is only a
            // placeholder; the real body lives on disk. With a vault, refuse
            // to append when the file can't be read: appending to the
            // placeholder would overwrite the day's note with one line.
            var note = daily
            if noteStore.fileStore != nil {
                guard let entry = noteStore.diskEntry(forNoteId: daily.id) else {
                    throw QuickCaptureSaveError.dailyNoteUnreadable
                }
                note.body = entry.file.body
            } else {
                note = try noteStore.fetchNote(id: daily.id) ?? daily
            }
            let entry = QuickCaptureComposer.dailyEntry(text: text, at: now, timeZone: timeZone)
            note.body = QuickCaptureComposer.appendingDailyEntry(entry, to: note.body)
            let tags = try noteStore.tags(for: note.id)
            try noteStore.updateNote(note, tags: tags)
            NotificationCenter.default.post(
                name: .scribeNoteChangedInApp,
                object: nil,
                userInfo: [NoteVaultChange.noteIdsKey: Set([note.id])]
            )
            return QuickCaptureSaveOutcome(
                destination: .note(id: note.id),
                message: QuickCaptureComposer.confirmation(for: request, resolvedProject: nil)
            )
        }
    }

    /// The project whose name matches `name` case-insensitively, if any.
    nonisolated static func matchingProject(named name: String, in projects: [Project]) -> Project? {
        projects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
