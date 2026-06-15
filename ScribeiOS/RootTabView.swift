import SwiftUI

/// Top-level iPhone/iPad navigation. On compact width (iPhone) this is a bottom
/// `TabView` mapping to the three product surfaces that exist on iOS — Today,
/// Notes, Tasks (Capture/recording is macOS-only and intentionally absent) plus
/// Settings. On regular width (iPad) it adapts to a `NavigationSplitView` with a
/// sidebar. Each screen roots its own `NavigationStack`.
struct RootTabView: View {
    enum Tab: Hashable, CaseIterable, Identifiable {
        case today, notes, tasks, settings

        var id: Self { self }

        var title: String {
            switch self {
            case .today: return "Today"
            case .notes: return "Notes"
            case .tasks: return "Tasks"
            case .settings: return "Settings"
            }
        }

        var systemImage: String {
            switch self {
            case .today: return "sun.max"
            case .notes: return "doc.text"
            case .tasks: return "checklist"
            case .settings: return "gearshape"
            }
        }
    }

    @State private var selection: Tab = .today
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                splitView
            } else {
                tabView
            }
        }
        // Opportunistic sync when the app returns to the foreground. No-op
        // unless the user enabled iCloud sync (CloudKitSyncService.isEnabled).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { try? await TaskSyncCoordinator.live.sync() }
            }
        }
    }

    /// Compact-width (iPhone) layout: the original bottom tab bar.
    private var tabView: some View {
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
    }

    /// Regular-width (iPad) layout: a sidebar listing the destinations and a
    /// detail column showing the selected screen.
    private var splitView: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $selection) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .navigationTitle("Scribe")
        } detail: {
            // Each screen owns its own NavigationStack, so show it directly.
            switch selection {
            case .today: TodayScreen()
            case .notes: NotesScreen()
            case .tasks: TasksScreen()
            case .settings: SettingsScreen()
            }
        }
    }
}
