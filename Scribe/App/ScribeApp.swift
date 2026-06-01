import SwiftUI

/// Main entry point for the Scribe macOS meeting transcription application.
///
/// A primary window (transcript library + notes + tasks in one
/// `NavigationSplitView`) plus a native `Settings` scene. The menu-bar command
/// tree is the canonical, VoiceOver-announced home of the app's shortcuts;
/// items post to the main window, which performs them through its
/// `NavigationCoordinator` / command palette.
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
        .commands { scribeCommands }

        Settings {
            SettingsRootView(audioManager: appState.audioManager)
                .environmentObject(appState)
                .environmentObject(appDelegate)
        }
    }

    // MARK: - Menu-bar command tree

    @CommandsBuilder
    private var scribeCommands: some Commands {
        // File → creation verbs (replaces the default "New").
        CommandGroup(replacing: .newItem) {
            Button("New Note") { post(.scribeNewNote) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Daily Note") { post(.scribeNewDailyNote) }
                .keyboardShortcut("n", modifiers: [.command, .control])
        }

        // Recording transport. Start/Stop stays shortcutless so it doesn't
        // double-bind the global ⇧⌘R registered via KeyboardShortcuts.
        CommandMenu("Recording") {
            Button(appState.isTranscribing ? "Stop Recording" : "Start Recording") {
                Task { await appDelegate.toggleRecording() }
            }
            if appState.isTranscribing {
                Button(appState.audioManager.isPaused ? "Resume" : "Pause") {
                    if appState.audioManager.isPaused {
                        Task { await appDelegate.resumeRecording() }
                    } else {
                        appDelegate.pauseRecording()
                    }
                }
                Button("Jump to Live") { go(.live) }
            }
        }

        // Go → the command bar + history + surface jumps.
        CommandMenu("Go") {
            Button("Command Bar…") { post(.scribeToggleCommandBar) }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Back") { post(.scribeGoBack) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { post(.scribeGoForward) }
                .keyboardShortcut("]", modifiers: .command)
            Divider()
            Button("Today") { go(.today) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Notes") { go(.notes(.all)) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Tasks") { go(.tasks(.inbox)) }
                .keyboardShortcut("3", modifiers: .command)
        }

        // View → focus mode (sidebar collapse).
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") { post(.scribeToggleSidebar) }
                .keyboardShortcut("s", modifiers: [.command, .control])
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    private func go(_ selection: MainSelection) {
        NotificationCenter.default.post(name: .scribeNavigate, object: selection)
    }
}
