import Foundation

/// Launch hook for the meeting copilot: the live copilot follows recordings
/// (and owns the ⌃⌥M "Mark moment" hotkey), and pre-meeting briefs follow
/// the calendar. Called once from `AppDelegate`.
@MainActor
enum MeetingCopilot {
    static func install(appState: AppState) {
        LiveCopilotController.shared.install(appState: appState)
        // No calendar / notifications under UI tests.
        if !AppLaunchEnvironment.isUITesting {
            MeetingBriefService.shared.start()
        }
    }
}
