//  ScribeiOSApp.swift
//
//  iPhone / iPad entry point. The notes + tasks client (recording is macOS
//  only). Reuses the shared data layer (TaskStore / NoteStore / GRDB) compiled
//  into this target — see docs/ICLOUD-MULTIPLATFORM-DESIGN.md.

import SwiftUI

@main
struct ScribeiOSApp: App {
    init() { TasksIOSBootstrap.start() } // ios-tasks: reminder actions, badge, Reminders sync
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}
