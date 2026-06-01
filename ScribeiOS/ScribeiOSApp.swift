//  ScribeiOSApp.swift
//
//  Milestone 0 foundation — the iPhone / iPad entry point.
//
//  This is a standalone SwiftUI stub on purpose: it exists so the
//  multiplatform Xcode project compiles and links *today*, ahead of the real
//  notes + tasks UI that lands in Milestone 1. The shared logic (storage,
//  tasks, navigation, markdown) will arrive via the `ScribeCore` package
//  (see docs/IOS-MIGRATION-PLAN.md).
//
//  By design this target contains NO audio / ScreenCaptureKit / recording
//  code — recording is a macOS-only feature. The iOS app is the notes + tasks
//  half of Scribe (Craft × TickTick).

import SwiftUI

@main
struct ScribeiOSApp: App {
    var body: some Scene {
        WindowGroup {
            ScribeiOSPlaceholderView()
        }
    }
}

struct ScribeiOSPlaceholderView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "note.text")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            Text("Scribe")
                .font(.largeTitle.weight(.semibold))
            Text("Notes + tasks for iPhone & iPad.\nArriving in Milestone 1.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

#Preview {
    ScribeiOSPlaceholderView()
}
