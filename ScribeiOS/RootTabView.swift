import SwiftUI

/// Top-level iPhone/iPad navigation. A bottom `TabView` mapping to the three
/// product surfaces that exist on iOS — Today, Notes, Tasks (Capture/recording
/// is macOS-only and intentionally absent). Each tab roots its own
/// `NavigationStack`. On iPad this still reads well; a `NavigationSplitView`
/// refinement for regular width can come later.
struct RootTabView: View {
    enum Tab: Hashable { case today, notes, tasks, settings }

    @State private var selection: Tab = .today
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selection) {
            TodayScreen()
                .tabItem { Label("Today", systemImage: "sun.max") }
                .tag(Tab.today)

            NotesScreen()
                .tabItem { Label("Notes", systemImage: "doc.text") }
                .tag(Tab.notes)

            TasksScreen()
                .tabItem { Label("Tasks", systemImage: "checklist") }
                .tag(Tab.tasks)

            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // Opportunistic sync when the app returns to the foreground. No-op
        // unless the user enabled iCloud sync (CloudKitSyncService.isEnabled).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { try? await TaskSyncCoordinator.live.sync() }
            }
        }
    }
}
