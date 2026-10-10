import AppKit
import Foundation

/// Errors App Intents surface to Shortcuts / Siri.
enum ScribeIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noteNotFound
    case noteUnreadable
    case taskNotFound
    case meetingNotFound
    case noMeetings
    case noSummary
    case noTranscript
    case emptyTitle
    case appNotReady
    case recordingDidNotStart

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noteNotFound:         return "That note no longer exists."
        case .noteUnreadable:       return "Scribe couldn't read that note's file, so nothing was added."
        case .taskNotFound:         return "That task no longer exists."
        case .meetingNotFound:      return "That meeting no longer exists."
        case .noMeetings:           return "There are no recorded meetings yet."
        case .noSummary:            return "That meeting doesn't have a summary yet."
        case .noTranscript:         return "That meeting has no transcript."
        case .emptyTitle:           return "Please give it a title."
        case .appNotReady:          return "Scribe is still starting up. Try again in a moment."
        case .recordingDidNotStart: return "Scribe couldn't start recording."
        }
    }
}

/// Main-actor entry points the App Intents call into: app state, the
/// recording/dictation controls the menu bar uses, and main-window navigation.
///
/// `AppDelegate` registers itself in `applicationDidFinishLaunching` (under
/// `@NSApplicationDelegateAdaptor`, `NSApp.delegate` is SwiftUI's own delegate,
/// so it can't be reached by casting).
@MainActor
enum ScribeIntentsBridge {

    private(set) static weak var appDelegate: AppDelegate?

    /// Called once from `AppDelegate.applicationDidFinishLaunching`.
    static func didFinishLaunching(_ delegate: AppDelegate) {
        appDelegate = delegate
        if !AppLaunchEnvironment.isUITesting {
            SpotlightIndexer.shared.start()
        }
    }

    /// The app delegate, waiting briefly when an intent launched the app and
    /// runs before launch finished.
    static func readyAppDelegate() async throws -> AppDelegate {
        for _ in 0..<50 {
            if let delegate = appDelegate { return delegate }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ScribeIntentError.appNotReady
    }

    // MARK: - Notes

    /// Note writes wait for launch to finish (vault set up, legacy bodies
    /// migrated to disk) so a note isn't written before the store is ready.
    static func createNote(title: String, body: String) async throws -> NoteEntity {
        _ = try await readyAppDelegate()
        let note = try ScribeIntentsData.live.createNote(title: title, body: body)
        return NoteEntity(note: note)
    }

    /// Appends through `NoteAIEditWriter` so an open editor replays the same
    /// edit in memory instead of overwriting it on its next autosave.
    static func append(_ text: String, toNoteId noteId: String) async throws -> NoteEntity {
        _ = try await readyAppDelegate()
        let store = NoteStore.shared
        guard let current = try store.fetchNote(id: noteId) else { throw ScribeIntentError.noteNotFound }
        // `fetchNote` falls back to an empty body when the note's file can't
        // be found or read; appending to that would overwrite the file with
        // just the new text. A non-empty excerpt means the note has content
        // we didn't get, so refuse instead of writing.
        if current.body.isEmpty, !(current.bodyExcerpt ?? "").isEmpty {
            throw ScribeIntentError.noteUnreadable
        }
        try NoteAIEditWriter.apply(.appendText(text), toNoteId: noteId, noteStore: store)
        guard let updated = try ScribeIntentsData.live.notes(ids: [noteId]).first else {
            throw ScribeIntentError.noteNotFound
        }
        return NoteEntity(note: updated)
    }

    static func openNote(id: String) async throws {
        _ = try await readyAppDelegate()
        guard try !ScribeIntentsData.live.notes(ids: [id]).isEmpty else { throw ScribeIntentError.noteNotFound }
        ScribeMainWindowNavigator.show(.note(id))
    }

    // MARK: - Tasks

    static func createTask(title: String, dueAt: Date?, priority: TodoTask.Priority?, notes: String) throws -> TaskEntity {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ScribeIntentError.emptyTitle }
        let task = try TaskStore.shared.createTask(
            title: trimmed,
            notes: notes,
            priority: priority,
            dueAt: dueAt
        )
        return TaskEntity(task: task)
    }

    /// Completes a task the way the task list does: recurring tasks advance to
    /// their next occurrence and re-arm their reminder; one-off tasks drop it.
    static func completeTask(id: String) async throws -> TaskEntity {
        let store = TaskStore.shared
        guard let existing = try store.fetchTask(id: id) else { throw ScribeIntentError.taskNotFound }
        // Already done: don't log a second completion or move completedAt.
        if existing.isCompleted { return TaskEntity(task: existing) }
        try store.completeTask(id: id)
        guard let refreshed = try store.fetchTask(id: id) else { throw ScribeIntentError.taskNotFound }
        if refreshed.isCompleted {
            await TaskReminderScheduler.shared.cancel(taskId: id)
        } else {
            await TaskReminderScheduler.shared.schedule(refreshed)
        }
        return TaskEntity(task: refreshed)
    }

    // MARK: - Recording / dictation

    /// Whether a recording is running or starting.
    static var isRecording: Bool {
        AppState.shared.isTranscribing || AppState.shared.isStartingSession
    }

    /// Starts a recording the way the menu bar's "Start Recording" does.
    /// Returns false when one was already running.
    static func startRecording() async throws -> Bool {
        let delegate = try await readyAppDelegate()
        guard !isRecording else { return false }
        guard await delegate.startRecordingSession() != nil else {
            throw ScribeIntentError.recordingDidNotStart
        }
        return true
    }

    /// Stops the running recording. Returns false when nothing was recording.
    static func stopRecording() async throws -> Bool {
        let delegate = try await readyAppDelegate()
        guard isRecording else { return false }
        await delegate.stopRecording()
        return true
    }

    /// Toggles dictation (menu bar "Start/Stop Dictation"). Returns whether
    /// dictation is now active.
    static func toggleDictation() -> Bool {
        let dictation = DictationController.shared
        dictation.toggle()
        return dictation.isActive
    }
}

/// Brings the main window forward and routes a destination through the
/// window's `NavigationCoordinator` (via the `.scribeNavigate` notification the
/// menu-bar items use).
@MainActor
enum ScribeMainWindowNavigator {

    static func show(_ selection: MainSelection) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow() {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            post(selection)
            return
        }
        // No main window (closed while Scribe keeps running in the menu bar,
        // or the app is still launching): ask for it, then navigate once it
        // exists so the window's `.onReceive` observer is installed.
        reopenMainWindow()
        Task { @MainActor in
            for _ in 0..<30 where mainWindow() == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(250))
            post(selection)
        }
    }

    private static func post(_ selection: MainSelection) {
        NotificationCenter.default.post(name: .scribeNavigate, object: selection)
    }

    /// The SwiftUI `Window("Scribe", id: "main")` window, when it is open.
    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { window in
            (window.identifier?.rawValue.hasPrefix("main") ?? false)
                && (window.isVisible || window.isMiniaturized)
        }
    }

    /// Re-opening the app bundle sends the running app a "reopen" event, which
    /// SwiftUI answers by showing the primary window when none is visible (the
    /// same thing a Dock click does). Isolated here: if this ever stops
    /// working, only this function needs changing.
    private static func reopenMainWindow() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration, completionHandler: nil)
    }
}
