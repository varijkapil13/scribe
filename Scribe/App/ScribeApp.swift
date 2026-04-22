import SwiftUI

/// Main entry point for the Scribe macOS meeting transcription application.
///
/// Uses the SwiftUI App lifecycle with an `NSApplicationDelegateAdaptor` to bridge
/// into AppKit for menu bar management and system-level event handling.
@main
struct ScribeApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject var appState = AppState.shared

    // MARK: - Scene

    var body: some Scene {
        // Settings window (opened via the app menu or Command+,)
        Settings {
            SettingsView(audioManager: appState.audioManager)
        }

        // Transcript viewer window — opened via scribe://transcripts URL scheme
        // from the menu bar's "View Transcripts" action.
        Window("Transcripts", id: "transcripts") {
            TranscriptListView()
                .environmentObject(appState)
                .handlesExternalEvents(
                    preferring: ["transcripts"],
                    allowing: ["transcripts"]
                )
        }
        .handlesExternalEvents(matching: ["transcripts"])
    }
}
