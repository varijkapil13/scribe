import AppKit
import Combine
import CoreGraphics
import Speech
import SwiftUI
import UserNotifications

/// AppKit delegate that coordinates high-level recording actions, global
/// keyboard shortcuts, and app-lifecycle policy.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    // MARK: - Properties

    private var appState: AppState!
    private var cancellables = Set<AnyCancellable>()

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register default values so UserDefaults queries return sensible results
        // before the user has visited Settings.
        UserDefaults.standard.register(defaults: [
            "captureSystemAudio": true,
            "selectedLanguage": "auto"
        ])

        // Use the shared singleton so every component references the same state.
        appState = AppState.shared

        // Recover any sessions left dangling by a previous crash. Setting their
        // endedAt + duration here means the sidebar doesn't show a permanent
        // "Now" entry for an extinct recording.
        do {
            let recovered = try appState.transcriptStore.recoverIncompleteSessions()
            if recovered > 0 {
                Log.app.info("Recovered \(recovered) incomplete session(s) from prior crash.")
            }
        } catch {
            Log.app.error("Crash recovery sweep failed: \(error.localizedDescription, privacy: .private)")
        }

        // Co-located attachments migration (Phase 5 — Slice 7). Moves
        // legacy ~/Library/Application Support/Scribe/attachments/ into
        // the notes vault. Runs *before* the SQLite-to-disk migration so
        // any note bodies written from this point reference attachments
        // at their new, vault-relative location.
        do {
            let moved = try AttachmentsMigrator.migrateProductionIfNeeded()
            if moved > 0 {
                Log.app.info("Moved \(moved) attachment folder(s) into the vault.")
            }
        } catch {
            Log.app.error("Attachments migration failed: \(error.localizedDescription, privacy: .private)")
        }

        // One-time SQLite-to-disk migration (Phase 5 — Slice 3). Idempotent
        // so it's safe to call on every launch; the no-op path is one
        // listAll + one DB fetch when nothing needs writing.
        do {
            let migrated = try NoteStore.shared.migrateNotesToDisk()
            if migrated > 0 {
                Log.app.info("Migrated \(migrated) note(s) from SQLite to disk.")
            }
        } catch {
            Log.app.error("Notes filesystem migration failed: \(error.localizedDescription, privacy: .private)")
        }

        // Reconcile DB against disk on launch + start FSEvents watcher
        // (Phase 5 — Slice 4/9). VaultCoordinator owns both so Settings
        // can hot-swap the location later without restarting the app.
        VaultCoordinator.shared.start()

        registerKeyboardShortcuts()
        observeMainWindowClose()
        observeSpeechErrors()

        // Start MCP server if the user had it enabled in a previous session.
        if UserDefaults.standard.bool(forKey: "mcpEnabled") {
            let port = UserDefaults.standard.integer(forKey: "mcpPort")
            MCPServer.shared.start(port: UInt16(port > 0 ? port : 3333))
        }
        // Reminder category + delegate. Authorization is requested lazily the
        // first time a task with `remindAt` is saved, not here — that keeps
        // first-launch silent for users who don't use the task layer.
        TaskReminderScheduler.shared.registerCategory()
        TaskReminderScheduler.shared.installDelegate()

        // Proactively request microphone and speech-recognition authorization
        // so the system prompts appear on first launch rather than silently
        // failing the first time the user hits Record.
        //
        // Deliberately NOT requesting Screen Recording here — on some macOS
        // configurations (especially dev builds whose code signature recently
        // changed) `CGRequestScreenCaptureAccess()` will re-trigger the system
        // prompt on every launch even when System Settings shows access as
        // granted. We defer the request to the moment the user actually hits
        // Record, at which point a single prompt is unavoidable and expected.
        //
        // Skipped under `--uitesting`: an XCUITest host has no way to satisfy a
        // TCC permission prompt and the request can crash a headless host.
        if !AppLaunchEnvironment.isUITesting {
            Task { @MainActor in
                _ = await Permissions.checkMicrophonePermission()
                _ = await SpeechRecognizerEngine.checkAuthorization()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task {
            try? await UNUserNotificationCenter.current().setBadgeCount(0)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Make sure an active session is flushed to disk before the process
        // dies — otherwise the last coalesced segment can be lost.
        if appState?.isTranscribing == true {
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                await appState.stopSession()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 2)
        }
    }

    // MARK: - Window Close → Quit

    /// The user explicitly asked: closing the main window quits the app. We
    /// observe ``NSWindow.willCloseNotification`` via Combine and terminate
    /// when the SwiftUI `Window("Scribe", id: "main")` scene goes away. We
    /// match on the window's identifier so alert and panel closes don't
    /// trigger quit.
    private func observeMainWindowClose() {
        NotificationCenter.default
            .publisher(for: NSWindow.willCloseNotification)
            .receive(on: RunLoop.main)
            .sink { notification in
                guard let window = notification.object as? NSWindow else { return }
                guard window.identifier?.rawValue == "main" else { return }
                NSApp.terminate(nil)
            }
            .store(in: &cancellables)
    }

    // MARK: - Keyboard Shortcuts

    /// Registers global keyboard shortcuts via ``KeyboardShortcutManager``.
    private func registerKeyboardShortcuts() {
        KeyboardShortcutManager.registerShortcuts { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.toggleRecording()
            }
        }
    }

    // MARK: - Recording Actions

    /// Toggles recording on or off depending on the current state.
    func toggleRecording() async {
        if appState.isTranscribing {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    /// Starts a new transcription session.
    func startRecording() async {
        // Verify permissions before touching audio hardware so we can show the
        // user a clear alert instead of silently failing.
        let micStatus = await Permissions.checkMicrophonePermission()
        guard micStatus == .granted else {
            showPermissionAlert(
                title: "Microphone Access Required",
                message: "Scribe needs microphone access to record. Grant permission in System Settings → Privacy & Security → Microphone.",
                panel: "Privacy_Microphone"
            )
            return
        }

        let speechStatus = await SpeechRecognizerEngine.checkAuthorization()
        guard speechStatus == .authorized else {
            showPermissionAlert(
                title: "Speech Recognition Required",
                message: "Scribe needs speech recognition access to transcribe audio. Grant permission in System Settings → Privacy & Security → Speech Recognition.",
                panel: "Privacy_SpeechRecognition"
            )
            return
        }

        // If the user wants system audio, check screen-recording permission.
        // If TCC has no record of Scribe yet (e.g. first launch after signing,
        // or after `tccutil reset`), we call CGRequestScreenCaptureAccess()
        // to register Scribe with TCC — this puts it in the System Settings
        // list and triggers the native "Allow" prompt. Then we show our own
        // alert with clear next steps.
        var captureSystemAudio = UserDefaults.standard.bool(forKey: "captureSystemAudio")
        if captureSystemAudio && !Permissions.hasScreenCapturePermission() {
            // Register Scribe with TCC and fire the OS prompt. Returns the
            // pre-response state, so we can't rely on the bool — we just need
            // the side effect of registering + prompting.
            _ = CGRequestScreenCaptureAccess()

            let choice = await promptScreenRecordingDenied()
            switch choice {
            case .openSettings:
                Permissions.openSystemPreferences(for: "Privacy_ScreenCapture")
                return
            case .continueMicOnly:
                captureSystemAudio = false
            case .cancel:
                return
            }
        }

        appState.audioManager.shouldCaptureSystemAudio = captureSystemAudio

        let resolved: ResolvedNoteContext
        do {
            resolved = try Self.resolveNoteContext(
                selection: appState.currentSelection,
                noteStore: .shared,
                now: Date()
            )
        } catch {
            // Surface the underlying createNote error to the user instead of
            // the generic "A note must exist…" message that would otherwise
            // come from AppStateError.sessionRequiresNoteId downstream.
            showPermissionAlert(
                title: "Couldn't Start Recording",
                message: error.localizedDescription,
                panel: nil
            )
            return
        }

        // Auto-create path: hand the freshly created meeting note to the window
        // so it routes a single atomic transition through `NavigationCoordinator`
        // (`replaceCurrent` via `RecordingNavigationPolicy.autoCreateDestination`).
        // We still post before `startSession` flips `isTranscribing` as
        // defense-in-depth, but correctness no longer *depends* on that
        // ordering: `.note(id)` is the only destination this path ever sets, so
        // the `isTranscribing` policy can never resolve to `.live` first. There
        // is no intermediate `.live` frame even if the two SwiftUI observation
        // callbacks were reordered or coalesced (B1.1).
        if resolved.didCreateNote {
            NotificationCenter.default.post(
                name: .scribeRequestNavigateToNote,
                object: nil,
                userInfo: ["noteId": resolved.noteId]
            )
        }

        do {
            try await appState.startSession(noteId: resolved.noteId)
        } catch {
            showPermissionAlert(
                title: "Couldn't Start Recording",
                message: error.localizedDescription,
                panel: nil
            )
        }
    }

    // MARK: - Speech Errors

    /// Observes speech-recognition failures via Combine on the speech engine's
    /// `onSessionError` callback. AppState already mirrors these into
    /// `lastError` for the banner; this delegate adds the bits the banner
    /// can't do — stop the session and, for the actionable
    /// "Siri & Dictation disabled" case, show a modal with a settings link.
    private func observeSpeechErrors() {
        // Wrap, don't replace: AppState's `wireTranscriptionResults` set its
        // own `onSessionError` to populate `lastError`. Calling that handler
        // here keeps the banner working alongside our delegate behavior.
        let stateHandler = appState.speechEngine.onSessionError
        appState.speechEngine.onSessionError = { [weak self] error in
            stateHandler?(error)
            self?.handleSpeechError(error)
        }
    }

    /// Handles a speech-recognition error: stops the session so state goes
    /// back to idle, and — for the user-actionable Siri/Dictation case —
    /// shows a guided modal alert. All other errors flow through the banner
    /// via `AppState.lastError`.
    private func handleSpeechError(_ error: Error) {
        Task { @MainActor in
            await stopRecording()
        }

        guard SpeechErrorClassifier.category(for: error) == .siriOrDictationDisabled else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Enable Dictation to Use Scribe"
        alert.informativeText = """
        Scribe uses Apple's on-device speech recognizer, which requires either Siri or Dictation to be turned on.

        Open System Settings → Keyboard → Dictation and flip the switch. You only need to do this once. Then launch Scribe again and hit Record.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Dictation Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Alerts

    /// User's response to the screen-recording-denied prompt.
    private enum ScreenRecordingChoice {
        case openSettings
        case continueMicOnly
        case cancel
    }

    /// Displays a modal alert with an optional button that opens the matching
    /// System Settings pane for the user to grant the missing permission.
    private func showPermissionAlert(title: String, message: String, panel: String?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        if let panel {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                Permissions.openSystemPreferences(for: panel)
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Displays an alert when screen-recording permission is missing. When the
    /// TCC flag is already set but the current process was launched before it
    /// was granted, the message directs the user to relaunch Scribe — macOS
    /// does not hot-reload screen-recording permission into a running process.
    private func promptScreenRecordingDenied() async -> ScreenRecordingChoice {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning

        if Permissions.hasScreenCapturePermission() {
            // Permission is granted at the OS level but this process still
            // sees it as denied — the classic "needs a relaunch" state.
            alert.messageText = "Quit and Reopen Scribe"
            alert.informativeText = "Screen Recording is enabled for Scribe in System Settings, but the change only takes effect after you quit and reopen the app. Quit now, launch Scribe again, then hit Record."
            alert.addButton(withTitle: "Quit Scribe")
            alert.addButton(withTitle: "Record Microphone Only")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                NSApp.terminate(nil)
                return .cancel
            case .alertSecondButtonReturn: return .continueMicOnly
            default:                       return .cancel
            }
        } else {
            alert.messageText = "Grant Screen Recording Permission"
            alert.informativeText = "Scribe needs Screen Recording permission to capture system audio (e.g. the other side of a meeting). macOS should have shown an \"Allow\" prompt — click it, or toggle Scribe on in System Settings. Then quit and reopen Scribe before recording."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Record Microphone Only")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:  return .openSettings
            case .alertSecondButtonReturn: return .continueMicOnly
            default:                       return .cancel
            }
        }
    }

    /// Stops the active transcription session. The main window observes
    /// `appState.isTranscribing` and navigates to the newest transcript.
    func stopRecording() async {
        await appState.stopSession()
    }

    /// Pauses audio capture without ending the session.
    func pauseRecording() {
        appState.pauseSession()
    }

    /// Resumes audio capture after a pause.
    func resumeRecording() async {
        do {
            try await appState.resumeSession()
        } catch {
            // Surface to the banner — otherwise the user clicks Resume, nothing
            // visibly happens, and the session sits paused with no explanation.
            appState.lastError = "Couldn't resume recording: \(error.localizedDescription)"
            Log.app.error("Failed to resume recording: \(error.localizedDescription, privacy: .private)")
        }
    }
}

// MARK: - Note resolution for global recording

enum NoteContextError: Error, LocalizedError {
    case autoCreateFailed(underlying: Error)
    var errorDescription: String? {
        switch self {
        case .autoCreateFailed(let err):
            return "Couldn't create a meeting note: \(err.localizedDescription)"
        }
    }
}

extension AppDelegate {

    struct ResolvedNoteContext {
        let noteId: String
        let didCreateNote: Bool
    }

    /// Pure resolver: decides which Note a new global recording should be
    /// bound to, creating a "Meeting on <datetime>" Note when no note is
    /// currently open. Throws `NoteContextError.autoCreateFailed` when the
    /// auto-create path fails — callers surface the underlying message so
    /// users see "disk full"-style errors instead of the downstream
    /// generic "A note must exist before starting a recording."
    /// Extracted as a static helper so it's unit-testable without booting
    /// audio.
    static func resolveNoteContext(
        selection: MainSelection?,
        noteStore: NoteStore,
        now: Date
    ) throws -> ResolvedNoteContext {
        if case .note(let noteId)? = selection {
            return ResolvedNoteContext(noteId: noteId, didCreateNote: false)
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let title = "Meeting on \(formatter.string(from: now))"
        do {
            let created = try noteStore.createNote(title: title, body: "")
            return ResolvedNoteContext(noteId: created.id, didCreateNote: true)
        } catch {
            Log.app.error("Failed to auto-create meeting note: \(error.localizedDescription, privacy: .private)")
            throw NoteContextError.autoCreateFailed(underlying: error)
        }
    }
}
