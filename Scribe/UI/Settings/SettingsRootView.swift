import SwiftUI

/// Root of the native macOS Settings scene (⌘,). A sidebar-style settings
/// window: a `List` of panes grouped by `SettingsPaneGroup` on the left and the
/// selected `SettingsPane` on the right. Settings lives in its own panel-style
/// window (HIG) instead of clobbering the main window's working note/task.
/// Opened via `@Environment(\.openSettings)` / the standard Settings… menu item.
///
/// (A 640-pt TabView could not fit the pane count — toolbar tabs overflowed
/// into a chevron menu — so the window uses a sidebar instead.)
struct SettingsRootView: View {
    @ObservedObject var audioManager: AudioSessionManager

    /// Remembers the last pane across openings of the Settings window.
    @AppStorage("settings.selectedPane") private var selectedPaneRaw: String = SettingsPane.general.rawValue

    private var selection: Binding<SettingsPane?> {
        Binding(
            get: { SettingsPane(rawValue: selectedPaneRaw) ?? .general },
            set: { newValue in
                if let newValue { selectedPaneRaw = newValue.rawValue }
            }
        )
    }

    private var selectedPane: SettingsPane {
        SettingsPane(rawValue: selectedPaneRaw) ?? .general
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(SettingsPaneGroup.allCases) { group in
                    if let header = group.header {
                        Section(header) { rows(for: group) }
                    } else {
                        Section { rows(for: group) }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            SettingsPaneView(pane: selectedPane, audioManager: audioManager)
        }
        // Settings windows don't collapse their sidebar.
        .toolbar(removing: .sidebarToggle)
        .frame(width: 760, height: 560)
        // Settings lives in its own window, so it needs its own host for the
        // unified feedback banner/toast (vault move/open outcomes route here via
        // AppState — see FeedbackPolicy). The main window has its own host.
        .errorBanner(.shared)
    }

    @ViewBuilder
    private func rows(for group: SettingsPaneGroup) -> some View {
        ForEach(group.panes) { pane in
            Label(pane.title, systemImage: pane.systemImage)
                .tag(Optional(pane))
        }
    }
}
