import AppKit
import Combine

// MARK: - RecordingState

/// Represents the current state of the transcription recording session.
enum RecordingState: Equatable {
    case idle
    case recording
    case paused
}

// MARK: - MenuBarController

/// Manages the NSStatusItem in the macOS menu bar, reflecting current recording state
/// and providing quick access to transcription controls.
@MainActor
final class MenuBarController: NSObject, ObservableObject {

    // MARK: - Published Properties

    @Published var recordingState: RecordingState = .idle

    // MARK: - Properties

    private(set) var statusItem: NSStatusItem?

    /// Callbacks for menu actions. Consumers set these to wire up actual logic.
    var onStartTranscription: (() -> Void)?
    var onStopTranscription: (() -> Void)?
    var onPauseTranscription: (() -> Void)?
    var onResumeTranscription: (() -> Void)?
    var onViewTranscripts: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    // MARK: - Menu Items (retained for dynamic updates)

    private var toggleItem: NSMenuItem?
    private var pauseResumeItem: NSMenuItem?
    private var sessionDurationItem: NSMenuItem?

    // MARK: - Duration Tracking

    private var durationTimer: Timer?
    private var sessionStartDate: Date?
    private var accumulatedDuration: TimeInterval = 0

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Setup

    /// Creates the status item and configures the initial menu.
    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        updateMenuBarIcon()
        updateMenu()

        // Observe state changes to keep icon and menu in sync.
        $recordingState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenuBarIcon()
                self?.updateMenu()
            }
            .store(in: &cancellables)
    }

    // MARK: - Icon Updates

    /// Updates the menu bar icon based on the current recording state.
    func updateMenuBarIcon() {
        guard let button = statusItem?.button else { return }

        let symbolName: String
        let accessibilityDescription: String

        switch recordingState {
        case .idle:
            symbolName = "waveform.circle"
            accessibilityDescription = "Scribe - Idle"
        case .recording:
            symbolName = "waveform.circle.fill"
            accessibilityDescription = "Scribe - Recording"
        case .paused:
            symbolName = "pause.circle.fill"
            accessibilityDescription = "Scribe - Paused"
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        button.image = image?.withSymbolConfiguration(config)

        // Apply red tint when recording.
        if recordingState == .recording {
            button.contentTintColor = .systemRed
        } else {
            button.contentTintColor = nil
        }

        button.toolTip = accessibilityDescription
    }

    // MARK: - Menu Construction

    /// Rebuilds the menu to reflect the current recording state.
    func updateMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Toggle transcription
        let toggleTitle: String
        switch recordingState {
        case .idle:
            toggleTitle = "Start Transcription"
        case .recording, .paused:
            toggleTitle = "Stop Transcription"
        }
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(toggleTranscriptionAction), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = true
        menu.addItem(toggle)
        toggleItem = toggle

        // Pause / Resume (only when recording or paused)
        if recordingState == .recording || recordingState == .paused {
            let pauseTitle = recordingState == .paused ? "Resume" : "Pause"
            let pauseResume = NSMenuItem(title: pauseTitle, action: #selector(pauseResumeAction), keyEquivalent: "")
            pauseResume.target = self
            pauseResume.isEnabled = true
            menu.addItem(pauseResume)
            pauseResumeItem = pauseResume
        } else {
            pauseResumeItem = nil
        }

        menu.addItem(.separator())

        // Session duration (disabled informational item, shown when recording or paused)
        if recordingState == .recording || recordingState == .paused {
            let durationText = "Session: \(formattedDuration)"
            let durationItem = NSMenuItem(title: durationText, action: nil, keyEquivalent: "")
            durationItem.isEnabled = false
            menu.addItem(durationItem)
            sessionDurationItem = durationItem

            menu.addItem(.separator())
        } else {
            sessionDurationItem = nil
        }

        // View Transcripts
        let viewTranscripts = NSMenuItem(title: "View Transcripts\u{2026}", action: #selector(viewTranscriptsAction), keyEquivalent: "")
        viewTranscripts.target = self
        viewTranscripts.isEnabled = true
        menu.addItem(viewTranscripts)

        // Settings
        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        settings.keyEquivalentModifierMask = .command
        settings.isEnabled = true
        menu.addItem(settings)

        menu.addItem(.separator())

        // Quit
        let quit = NSMenuItem(title: "Quit Scribe", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = .command
        quit.isEnabled = true
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    // MARK: - Duration Helpers

    /// Starts the duration timer for the current session.
    func startSessionTimer() {
        sessionStartDate = Date()
        accumulatedDuration = 0
        startDurationTimer()
    }

    /// Pauses the duration timer, preserving accumulated time.
    func pauseSessionTimer() {
        if let start = sessionStartDate {
            accumulatedDuration += Date().timeIntervalSince(start)
        }
        stopDurationTimer()
        sessionStartDate = nil
    }

    /// Resumes the duration timer from the accumulated offset.
    func resumeSessionTimer() {
        sessionStartDate = Date()
        startDurationTimer()
    }

    /// Stops and resets the duration timer.
    func resetSessionTimer() {
        stopDurationTimer()
        sessionStartDate = nil
        accumulatedDuration = 0
    }

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDurationMenuItem()
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private var currentDuration: TimeInterval {
        var total = accumulatedDuration
        if let start = sessionStartDate {
            total += Date().timeIntervalSince(start)
        }
        return total
    }

    private var formattedDuration: String {
        let total = Int(currentDuration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func refreshDurationMenuItem() {
        sessionDurationItem?.title = "Session: \(formattedDuration)"
    }

    // MARK: - Actions

    @objc private func toggleTranscriptionAction() {
        switch recordingState {
        case .idle:
            onStartTranscription?()
        case .recording, .paused:
            onStopTranscription?()
        }
    }

    @objc private func pauseResumeAction() {
        switch recordingState {
        case .recording:
            onPauseTranscription?()
        case .paused:
            onResumeTranscription?()
        case .idle:
            break
        }
    }

    @objc private func viewTranscriptsAction() {
        onViewTranscripts?()
    }

    @objc private func openSettingsAction() {
        onOpenSettings?()
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
