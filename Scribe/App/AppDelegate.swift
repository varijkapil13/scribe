import AppKit
import Combine
import SwiftUI

/// AppKit delegate that manages the menu bar status item, overlay panel,
/// keyboard shortcuts, and coordinates high-level recording actions.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    // MARK: - Properties

    private var menuBarController: MenuBarController!
    private var overlayManager = OverlayManager()
    private var appState: AppState!
    private var cancellables = Set<AnyCancellable>()

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register default values so UserDefaults queries return sensible results
        // before the user has visited Settings.
        UserDefaults.standard.register(defaults: [
            "showOverlayOnRecord": true,
            "captureSystemAudio": true,
            "alwaysOnTop": true,
            "selectedLanguage": "auto"
        ])

        // Use the shared singleton so every component references the same state.
        appState = AppState.shared

        setupMenuBar()
        registerKeyboardShortcuts()
    }

    // MARK: - Menu Bar Setup

    /// Configures the ``MenuBarController`` and wires its action callbacks
    /// to the corresponding delegate methods.
    private func setupMenuBar() {
        menuBarController = MenuBarController()
        menuBarController.setup()

        menuBarController.onStartTranscription = { [weak self] in
            guard let self else { return }
            Task { await self.startRecording() }
        }

        menuBarController.onStopTranscription = { [weak self] in
            guard let self else { return }
            Task { await self.stopRecording() }
        }

        menuBarController.onPauseTranscription = { [weak self] in
            self?.pauseRecording()
        }

        menuBarController.onResumeTranscription = { [weak self] in
            guard let self else { return }
            Task { await self.resumeRecording() }
        }

        menuBarController.onViewTranscripts = { [weak self] in
            self?.openTranscriptViewer()
        }

        menuBarController.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
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
    private func toggleRecording() async {
        if appState.isTranscribing {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    /// Starts a new transcription session, updates the menu bar, and shows the overlay.
    func startRecording() async {
        do {
            try await appState.startSession()

            menuBarController.recordingState = .recording
            menuBarController.startSessionTimer()

            // Show the floating overlay if the user has it enabled.
            if UserDefaults.standard.bool(forKey: "showOverlayOnRecord") {
                let overlayView = OverlayView(audioManager: appState.audioManager)
                overlayManager.showOverlay(with: overlayView)
            }
        } catch {
            print("[AppDelegate] Failed to start recording: \(error.localizedDescription)")
        }
    }

    /// Stops the active transcription session, updates the menu bar, and hides the overlay.
    func stopRecording() async {
        await appState.stopSession()

        menuBarController.recordingState = .idle
        menuBarController.resetSessionTimer()
        overlayManager.hideOverlay()
    }

    /// Pauses audio capture without ending the session.
    func pauseRecording() {
        appState.pauseSession()

        menuBarController.recordingState = .paused
        menuBarController.pauseSessionTimer()
    }

    /// Resumes audio capture after a pause.
    func resumeRecording() async {
        do {
            try await appState.resumeSession()

            menuBarController.recordingState = .recording
            menuBarController.resumeSessionTimer()
        } catch {
            print("[AppDelegate] Failed to resume recording: \(error.localizedDescription)")
        }
    }

    // MARK: - Navigation Actions

    /// Opens the transcript viewer window via its SwiftUI scene identifier.
    func openTranscriptViewer() {
        if let url = URL(string: "scribe://transcripts") {
            NSWorkspace.shared.open(url)
        }
        // Bring the app to the foreground so the window is visible.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens the Settings window using the standard AppKit preferences action.
    func openSettings() {
        NSApp.mainMenu?.item(withTitle: "Scribe")?.submenu?.item(withTitle: "Settings…")?.performAction()
            ?? NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Terminates the application.
    func quitApp() {
        NSApp.terminate(nil)
    }
}
