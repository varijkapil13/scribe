//  ScribeiOSApp.swift
//
//  iPhone / iPad entry point. Reuses the shared data layer (TaskStore /
//  NoteStore / GRDB / CloudKit sync) compiled into this target — see
//  docs/ICLOUD-MULTIPLATFORM-DESIGN.md. The shell (navigation, iPad windows,
//  entry points, keyboard commands) lives in ScribeiOS/Shell.

import SwiftUI

@main
struct ScribeiOSApp: App {
    @UIApplicationDelegateAdaptor(ScribeiOSAppDelegate.self) private var appDelegate

    init() { TasksIOSBootstrap.start() } // ios-tasks: reminder actions, badge, Reminders sync
    var body: some Scene {
        // Main window. On iPad every new window (Stage Manager, Split View,
        // App Exposé "+") is another instance with its own tab selection.
        WindowGroup {
            RootTabView()
        }
        .commands {
            ScribeiOSCommands()
        }

        // Standalone note window (iPad): "Open in New Window" on a note row,
        // or a note row dragged to the screen edge.
        WindowGroup("Note", id: ScribeMobileWindows.noteWindowGroupID, for: String.self) { $noteId in
            ScribeNoteWindowRoot(noteId: $noteId)
        }
        .handlesExternalEvents(matching: [ScribeMobileWindows.noteWindowTargetContentIdentifier])
        // Stage Manager honours the root's minimum frame (ScribeNoteWindowRoot).
        // CI-COMPILE NOTE: drop this line if `windowResizability` is
        // unavailable on iOS in the current SDK.
        .windowResizability(.contentMinSize)
    }
}
