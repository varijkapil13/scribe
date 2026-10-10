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
            "selectedLanguage": "auto",
            MenuBarPreferences.showIconKey: true,
            "autoSummarize": true,
            "autoExtractActions": true,
            AudioSessionManager.echoCancellationKey: true
        ])

        // Screenshot / UI-test fixture mode: seed a deterministic dataset into
        // the (already-redirected) temp database + notes vault before any view
        // reads it. No-op on every production launch (see UITestFixtures /
        // AppLaunchEnvironment). Runs before VaultCoordinator.start() so the
        // launch reconciler indexes the seeded note files.
        UITestFixtures.seedIfNeeded()

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

        // Retained audio: apply the retention policy and drop folders of
        // sessions that no longer exist (background, best-effort).
        if !AppLaunchEnvironment.isUITesting {
            AppState.runAudioHousekeeping(store: appState.transcriptStore)
            // Diarization scratch audio left by a crash / quit mid-run.
            let launchedAt = Date()
            Task.detached(priority: .utility) {
                let removed = SpeakerDiarizationCapture.removeLeftoverScratch(createdBefore: launchedAt)
                if removed > 0 {
                    Log.app.info("Removed \(removed) leftover diarization scratch folder(s).")
                }
            }
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
        // App Intents (Shortcuts / Siri) entry points + Spotlight indexing.
        ScribeIntentsBridge.didFinishLaunching(self)
        observeMainWindowClose()
        observeSpeechErrors()
        // scribe:// links, opened Markdown files, Dock + Services menus.
        installEntryPoints()

        // Start MCP server if the user had it enabled in a previous session.
        if UserDefaults.standard.bool(forKey: "mcpEnabled") {
            // sanitize() never traps: unset/out-of-range values fall back to 3333.
            let port = MCPPortPolicy.sanitize(UserDefaults.standard.integer(forKey: "mcpPort"))
            MCPServer.shared.start(port: port)
        }
        // Reminder category + delegate. Authorization is requested lazily the
        // first time a task with `remindAt` is saved, not here — that keeps
        // first-launch silent for users who don't use the task layer.
        // Other features' notification categories share the scheduler's
        // delegate through NotificationRouter (one handler per category).
        NotificationRouter.shared.register(categories: MeetingDetector.notificationCategories) { categoryId, actionId, userInfo in
            MeetingDetector.shared.handleNotificationResponse(
                categoryId: categoryId, actionId: actionId, userInfo: userInfo
            )
        }
        NotificationRouter.shared.register(categories: CalendarReminderScheduler.notificationCategories) { categoryId, actionId, userInfo in
            CalendarReminderScheduler.shared.handleNotificationResponse(
                categoryId: categoryId, actionId: actionId, userInfo: userInfo
            )
        }
        NotificationRouter.shared.install(on: TaskReminderScheduler.shared)
        TaskReminderScheduler.shared.registerCategory()
        TaskReminderScheduler.shared.installDelegate()

        // Meeting auto-detection: watch for Zoom/Teams/Meet/… taking the mic
        // and offer to (or automatically) record. Not under `--uitesting`,
        // where there is no audio stack.
        if !AppLaunchEnvironment.isUITesting {
            MeetingDetector.shared.start(
                // A recording that is still starting counts as recording, so
                // detection never offers (or auto-starts) a second one.
                isRecording: { [weak self] in
                    guard let state = self?.appState else { return false }
                    return state.isTranscribing || state.isStartingSession
                },
                currentSessionId: { [weak self] in self?.appState?.currentSessionId },
                startRecording: { [weak self] app, forceNewNote in
                    await self?.startRecordingSession(detectedMeeting: app, forceNewNote: forceNewNote)
                },
                stopRecording: { [weak self] in await self?.stopRecording() }
            )
        }

        // Calendar integration: off until enabled in Settings → Calendar (no
        // permission prompt here). Refreshes events + pre-meeting reminders.
        if !AppLaunchEnvironment.isUITesting {
            CalendarReminderScheduler.shared.configure { [weak self] event in
                await self?.startRecording(calendarEvent: event)
            }
            CalendarService.shared.start()
        }

        // iCloud task sync on the Mac: launch / toggle-on / app-active
        // (throttled) / local edits (debounced). Self-gates on the opt-in
        // toggle and on a CloudKit-entitled build (CloudKitAvailability).
        if !AppLaunchEnvironment.isUITesting {
            TaskSyncScheduler.shared.start()
            RemindersSyncScheduler.shared.start(database: DatabaseManager.shared.database)
        }

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

    /// Spotlight results (and other continued activities) — routed to the
    /// note / task they point at.
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        SpotlightIndexer.handle(userActivity)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !AppLaunchEnvironment.isUITesting {
            TaskSyncScheduler.shared.appDidBecomeActive()
            RemindersSyncScheduler.shared.appDidBecomeActive()
        }
        Task {
            try? await UNUserNotificationCenter.current().setBadgeCount(0)
        }
    }

    /// Upper bound on how long quitting waits for an active session to stop
    /// cleanly before terminating anyway.
    static let terminationStopTimeout: Duration = .seconds(5)

    /// Set while a deferred quit is waiting on `stopSession`, so the reply is
    /// sent exactly once (by whichever of stop / timeout finishes first).
    private var pendingTerminationReply = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting mid-recording: stop the session properly first so the last
        // coalesced segment is persisted, the session is ended and retained
        // audio files are closed. `stopSession` is async on the main actor,
        // so it can't be awaited here (blocking the main thread would
        // deadlock it); defer the quit and reply when it finishes.
        guard appState?.isTranscribing == true else { return .terminateNow }
        guard !pendingTerminationReply else { return .terminateLater }
        pendingTerminationReply = true

        Task { @MainActor [weak self] in
            await self?.appState?.stopSession()
            self?.replyToPendingTermination()
        }
        // Safety net: never hang the quit on a stuck stop.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.terminationStopTimeout)
            if self?.pendingTerminationReply == true {
                Log.app.error("Session didn't stop within the quit timeout; quitting anyway.")
            }
            self?.replyToPendingTermination()
        }
        return .terminateLater
    }

    private func replyToPendingTermination() {
        guard pendingTerminationReply else { return }
        pendingTerminationReply = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Nothing blocking here: an active session was already stopped in
        // `applicationShouldTerminate`. Never wait on the main actor in this
        // callback — it runs on the main thread, so a Task awaiting it could
        // never run.
    }

    // MARK: - Window Close → Quit

    /// Closing the main window quits the app, unless the menu-bar item is
    /// shown: then Scribe keeps running in the menu bar so meeting detection,
    /// dictation and reminders keep working. We observe
    /// ``NSWindow.willCloseNotification`` via Combine and match on the
    /// window's identifier so alert and panel closes don't trigger quit.
    private func observeMainWindowClose() {
        NotificationCenter.default
            .publisher(for: NSWindow.willCloseNotification)
            .receive(on: RunLoop.main)
            .sink { notification in
                guard let window = notification.object as? NSWindow else { return }
                guard window.identifier?.rawValue == "main" else { return }
                guard !UserDefaults.standard.bool(forKey: MenuBarPreferences.showIconKey) else { return }
                NSApp.terminate(nil)
            }
            .store(in: &cancellables)
    }

    // MARK: - Keyboard Shortcuts

    /// Registers global keyboard shortcuts via ``KeyboardShortcutManager``.
    private func registerKeyboardShortcuts() {
        KeyboardShortcutManager.registerShortcuts(
            onToggleRecording: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    await self.toggleRecording()
                }
            },
            onDictationDown: {
                Task { @MainActor in DictationController.shared.shortcutPressed() }
            },
            onDictationUp: {
                Task { @MainActor in DictationController.shared.shortcutReleased() }
            }
        )
    }

    // MARK: - Recording Actions

    /// Toggles recording on or off depending on the current state.
    /// While a start is still in flight (e.g. downloading the speech model)
    /// the toggle cancels it.
    func toggleRecording() async {
        if appState.isTranscribing || appState.isStartingSession {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    /// Starts a new transcription session.
    ///
    /// - Parameters:
    ///   - detectedMeeting: Set when meeting detection triggered the start;
    ///     names an auto-created note after the meeting app.
    ///   - forceNewNote: Always create a fresh meeting note instead of binding
    ///     to the open one (auto-record, where nobody chose the context).
    ///   - calendarEvent: The calendar event to record (menu-bar "Upcoming",
    ///     reminder actions). Always gets a fresh note named after it. When
    ///     nil and calendar integration is on, the event in progress is used.
    func startRecording(
        detectedMeeting: MeetingApp? = nil,
        forceNewNote: Bool = false,
        calendarEvent: CalendarEventInfo? = nil
    ) async {
        await startRecordingSession(
            detectedMeeting: detectedMeeting,
            forceNewNote: forceNewNote,
            calendarEvent: calendarEvent
        )
    }

    /// ``startRecording(detectedMeeting:forceNewNote:calendarEvent:)``, but
    /// returns the id of the session *this call* started — nil when it was
    /// refused (another recording running or starting), cancelled or failed.
    /// Meeting detection uses it to know which recording is its own, so a
    /// manual start racing an auto-start is never mistaken for detection's.
    @discardableResult
    func startRecordingSession(
        detectedMeeting: MeetingApp? = nil,
        forceNewNote: Bool = false,
        calendarEvent: CalendarEventInfo? = nil
    ) async -> String? {
        // Claim the start gate before the first await: `isTranscribing` only
        // flips once audio is running, so two starts (auto-record + a click)
        // would otherwise both get through.
        guard appState.beginStartingSession() else {
            Log.app.info("Ignoring start request: a recording is already running or starting.")
            return nil
        }
        defer { appState.endStartingSession() }
        // Verify permissions before touching audio hardware so we can show the
        // user a clear alert instead of silently failing.
        let micStatus = await Permissions.checkMicrophonePermission()
        guard micStatus == .granted else {
            showPermissionAlert(
                title: "Microphone Access Required",
                message: "Scribe needs microphone access to record. Grant permission in System Settings → Privacy & Security → Microphone.",
                panel: "Privacy_Microphone"
            )
            return nil
        }

        let speechStatus = await SpeechRecognizerEngine.checkAuthorization()
        guard speechStatus == .authorized else {
            showPermissionAlert(
                title: "Speech Recognition Required",
                message: "Scribe needs speech recognition access to transcribe audio. Grant permission in System Settings → Privacy & Security → Speech Recognition.",
                panel: "Privacy_SpeechRecognition"
            )
            return nil
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
                return nil
            case .continueMicOnly:
                captureSystemAudio = false
            case .cancel:
                return nil
            }
        }

        appState.audioManager.shouldCaptureSystemAudio = captureSystemAudio

        let now = Date()
        let event = calendarEvent ?? CalendarService.shared.matchingEvent(at: now)
        // Name/seed the note after the event when the user picked the event
        // explicitly, or when "Name notes after calendar events" is on.
        let namesNote = event != nil && (calendarEvent != nil || CalendarService.nameNotesEnabled)
        let resolved: ResolvedNoteContext
        do {
            resolved = try Self.resolveNoteContext(
                selection: (forceNewNote || calendarEvent != nil) ? nil : appState.currentSelection,
                noteStore: .shared,
                now: now,
                meetingName: detectedMeeting.map(MeetingDetector.meetingPhrase(for:)),
                explicitTitle: namesNote ? event.map { CalendarNoteFormatter.noteTitle(for: $0, date: now) } : nil,
                initialBody: namesNote ? (event.map(CalendarNoteFormatter.noteHeader(for:)) ?? "") : ""
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
            return nil
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
            if let event {
                try await appState.startSession(title: event.displayTitle, noteId: resolved.noteId)
                if let sessionId = appState.currentSessionId {
                    do {
                        try appState.transcriptStore.setCalendarEvent(
                            sessionId: sessionId,
                            eventId: event.id,
                            eventTitle: event.title,
                            attendees: event.attendees
                        )
                    } catch {
                        Log.app.error("Failed to link session to calendar event: \(error.localizedDescription, privacy: .private)")
                    }
                }
            } else {
                try await appState.startSession(noteId: resolved.noteId)
            }
            ConsentDisclosure.recordingDidStart()
            return appState.currentSessionId
        } catch is CancellationError {
            // Stopped while starting: nothing to report.
            return nil
        } catch AppStateError.speechStartFailed {
            // Already surfaced through the speech engine's error handler.
            return nil
        } catch {
            showPermissionAlert(
                title: "Couldn't Start Recording",
                message: error.localizedDescription,
                panel: nil
            )
            return nil
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
    /// currently open (or "<meetingName> on <datetime>", e.g. "Zoom meeting
    /// on …", when meeting detection supplied one). Throws `NoteContextError.autoCreateFailed` when the
    /// auto-create path fails — callers surface the underlying message so
    /// users see "disk full"-style errors instead of the downstream
    /// generic "A note must exist before starting a recording."
    /// Extracted as a static helper so it's unit-testable without booting
    /// audio.
    ///
    /// `explicitTitle` / `initialBody` (calendar integration) override the
    /// generated title and seed the new note's body; they're ignored when an
    /// open note is reused.
    static func resolveNoteContext(
        selection: MainSelection?,
        noteStore: NoteStore,
        now: Date,
        meetingName: String? = nil,
        explicitTitle: String? = nil,
        initialBody: String = ""
    ) throws -> ResolvedNoteContext {
        if case .note(let noteId)? = selection {
            return ResolvedNoteContext(noteId: noteId, didCreateNote: false)
        }
        let title: String
        if let explicitTitle, !explicitTitle.isEmpty {
            title = explicitTitle
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            title = "\(meetingName ?? "Meeting") on \(formatter.string(from: now))"
        }
        do {
            let created = try noteStore.createNote(title: title, body: initialBody)
            return ResolvedNoteContext(noteId: created.id, didCreateNote: true)
        } catch {
            Log.app.error("Failed to auto-create meeting note: \(error.localizedDescription, privacy: .private)")
            throw NoteContextError.autoCreateFailed(underlying: error)
        }
    }
}
