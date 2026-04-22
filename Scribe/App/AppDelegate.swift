import AppKit
import Combine
import CoreGraphics
import Speech
import SwiftUI

/// AppKit delegate that coordinates high-level recording actions, the overlay
/// panel, global keyboard shortcuts, and app-lifecycle policy.
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

        registerKeyboardShortcuts()
        observeMainWindowClose()

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
        Task { @MainActor in
            _ = await Permissions.checkMicrophonePermission()
            _ = await SpeechRecognizerEngine.checkAuthorization()
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
    /// match on the window's identifier so alert, panel, and overlay closes
    /// don't trigger quit.
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

    /// Starts a new transcription session and shows the overlay.
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

        // Wire the recognition-error alert BEFORE starting the session —
        // SFSpeech can deliver the first error almost immediately (e.g. when
        // Siri & Dictation are disabled) and we'd miss it otherwise.
        appState.speechEngine.onSessionError = { [weak self] error in
            self?.handleSpeechError(error)
        }

        do {
            try await appState.startSession()
            // The main window's live view observes `appState.isTranscribing`
            // and auto-navigates to the live transcript — no overlay needed.
        } catch {
            showPermissionAlert(
                title: "Couldn't Start Recording",
                message: error.localizedDescription,
                panel: nil
            )
        }
    }

    // MARK: - Speech Errors

    /// Handles a speech-recognition error by surfacing a targeted alert. The
    /// most common user-fixable cause on macOS is "Siri and Dictation are
    /// disabled" — on-device recognition won't initialize without at least one
    /// of those toggles on. We detect that string and guide the user straight
    /// to the right System Settings pane.
    private func handleSpeechError(_ error: Error) {
        // Also stop the session so state goes back to idle rather than
        // claiming to still be recording.
        Task { @MainActor in
            await stopRecording()
        }

        let message = error.localizedDescription
        let lowercased = message.lowercased()
        if lowercased.contains("siri") && lowercased.contains("dictation") {
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
            return
        }

        showPermissionAlert(
            title: "Transcription Stopped",
            message: message,
            panel: nil
        )
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
            print("[AppDelegate] Failed to resume recording: \(error.localizedDescription)")
        }
    }
}
