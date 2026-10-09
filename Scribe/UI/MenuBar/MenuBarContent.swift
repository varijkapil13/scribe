import SwiftUI

/// Settings key for the menu-bar item. While it's shown, closing the main
/// window keeps Scribe running (so meeting detection, dictation and reminders
/// keep working); with it hidden, closing the window quits as before.
enum MenuBarPreferences {
    static let showIconKey = "showMenuBarIcon"
}

/// SF Symbol for the menu-bar icon, reflecting what Scribe is doing.
enum MenuBarIcon {
    static func symbol(isRecording: Bool, isPaused: Bool, isDictating: Bool) -> String {
        if isDictating { return "mic.fill" }
        if isRecording { return isPaused ? "pause.circle" : "record.circle.fill" }
        return "waveform"
    }
}

/// The menu shown from Scribe's menu-bar item: recording transport, the
/// detected meeting, dictation, and getting back to the main window.
struct MenuBarContent: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var appDelegate: AppDelegate
    @ObservedObject var audioManager: AudioSessionManager
    @ObservedObject private var detector = MeetingDetector.shared
    @ObservedObject private var dictation = DictationController.shared
    @ObservedObject private var calendar = CalendarService.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if appState.isTranscribing {
            Text(audioManager.isPaused
                 ? "Paused · \(Self.format(audioManager.recordingDuration))"
                 : "Recording · \(Self.format(audioManager.recordingDuration))")
            Button("Stop Recording") { Task { await appDelegate.stopRecording() } }
            Button(audioManager.isPaused ? "Resume" : "Pause") {
                if audioManager.isPaused {
                    Task { await appDelegate.resumeRecording() }
                } else {
                    appDelegate.pauseRecording()
                }
            }
            Button("Show Live Transcript") { open(.live) }
            Button("Copy Disclosure Message") { _ = ConsentDisclosure.copyToPasteboard() }
        } else {
            if let meeting = detector.currentMeeting {
                Button("Record \(MeetingDetector.meetingPhrase(for: meeting))") {
                    Task { await appDelegate.startRecording(detectedMeeting: meeting) }
                }
                Divider()
            }
            Button("Start Recording") { Task { await appDelegate.startRecording() } }
            UpcomingEventsMenuSection(events: calendar.upcomingEvents) { event in
                Task { await appDelegate.startRecording(calendarEvent: event) }
            }
        }

        Divider()

        Button(dictation.isActive ? "Stop Dictation" : "Start Dictation") { dictation.toggle() }
        if dictation.lastText != nil {
            Button("Paste Last Dictation") { dictation.pasteLast() }
        }

        Divider()

        Button("Open Scribe") { open(nil) }
        Button("Today") { open(.today) }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Scribe") { NSApp.terminate(nil) }
    }

    private func open(_ selection: MainSelection?) {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        if let selection {
            NotificationCenter.default.post(name: .scribeNavigate, object: selection)
        }
    }

    static func format(_ duration: TimeInterval) -> String {
        let total = Int(duration)
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The icon itself. Separate view so it observes the same state as the menu.
struct MenuBarLabel: View {
    @ObservedObject var appState: AppState
    @ObservedObject var audioManager: AudioSessionManager
    @ObservedObject private var dictation = DictationController.shared

    var body: some View {
        Image(systemName: MenuBarIcon.symbol(
            isRecording: appState.isTranscribing,
            isPaused: audioManager.isPaused,
            isDictating: dictation.isActive
        ))
        .accessibilityLabel("Scribe")
    }
}
