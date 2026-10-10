import SwiftUI

/// Main entry point for the Scribe macOS meeting transcription application.
///
/// A primary window (transcript library + notes + tasks in one
/// `NavigationSplitView`), a native `Settings` scene, and a menu-bar item. The menu-bar command
/// tree is the canonical, VoiceOver-announced home of the app's shortcuts;
/// items post to the main window, which performs them through its
/// `NavigationCoordinator` / command palette.
@main
struct ScribeApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject var appState = AppState.shared
    @AppStorage(MenuBarPreferences.showIconKey) private var showMenuBarIcon = true

    // MARK: - Scene

    var body: some Scene {
        Window("Scribe", id: "main") {
            MainWindowView()
                .environmentObject(appState)
                .environmentObject(appDelegate)
        }
        .commands { scribeCommands }
        .commands { ScribeMenuCommands() }

        // Standalone note windows (File › Open in New Window, ⌥⌘O). Restored
        // with their note on relaunch.
        WindowGroup("Note", id: NoteWindowValue.windowID, for: NoteWindowValue.self) { $value in
            NoteWindowRoot(value: $value)
                .environmentObject(appState)
                .environmentObject(appDelegate)
        }

        // Help › Keyboard Shortcuts.
        Window("Keyboard Shortcuts", id: ShortcutReferenceWindow.windowID) {
            ShortcutReferenceView()
        }

        Settings {
            SettingsRootView(audioManager: appState.audioManager)
                .environmentObject(appState)
                .environmentObject(appDelegate)
        }

        // Menu-bar item: recording/dictation status and controls. While it's
        // shown, closing the main window keeps Scribe running.
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarContent(audioManager: appState.audioManager)
                .environmentObject(appState)
                .environmentObject(appDelegate)
        } label: {
            MenuBarLabel(appState: appState, audioManager: appState.audioManager)
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

        // View → Show/Hide Sidebar (⌃⌘S) comes from SidebarCommands in
        // ScribeMenuCommands.
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    private func go(_ selection: MainSelection) {
        NotificationCenter.default.post(name: .scribeNavigate, object: selection)
    }
}
