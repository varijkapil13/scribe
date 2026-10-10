//  ScribeiOSApp.swift
//
//  iPhone / iPad entry point. Reuses the shared data layer (TaskStore /
//  NoteStore / GRDB / CloudKit sync) compiled into this target — see
//  docs/ICLOUD-MULTIPLATFORM-DESIGN.md. The shell (navigation, iPad windows,
//  entry points, keyboard commands) lives in ScribeiOS/Shell.

import SwiftUI

@main
struct ScribeiOSApp: App {
    // Launch setup (database, notifications, tasks, notes vault, sync,
    // recorder hooks, widgets / Spotlight / Share) runs once, in
    // ScribeiOSBootstrap.run(), from the delegate's didFinishLaunching.
    @UIApplicationDelegateAdaptor(ScribeiOSAppDelegate.self) private var appDelegate

    var body: some Scene {
        // Main window. On iPad every new window (Stage Manager, Split View,
        // App Exposé "+") is another instance with its own tab selection.
        WindowGroup {
            RootTabView()
                .scribeSystemIntegration() // ios-system: widgets, Share import, Spotlight, Quick Capture
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
