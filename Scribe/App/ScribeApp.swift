import SwiftUI

/// Main entry point for the Scribe macOS meeting transcription application.
///
/// Single primary window that combines the transcript library and all settings
/// panes in one `NavigationSplitView`. Closing the window quits the app.
@main
struct ScribeApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject var appState = AppState.shared

    // MARK: - Scene

    var body: some Scene {
        Window("Scribe", id: "main") {
            MainWindowView()
                .environmentObject(appState)
                .environmentObject(appDelegate)
        }
        .commands {
            // Route the standard Settings… menu item (Cmd-,) to the Settings
            // section of the main window instead of opening a separate scene.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(
                        name: .openScribeSettings,
                        object: SettingsPane.general
                    )
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}
