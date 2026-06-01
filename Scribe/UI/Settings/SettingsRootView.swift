import SwiftUI

/// Root of the native macOS Settings scene (⌘,). Renders the existing
/// `SettingsPane`s as a standard preferences-window TabView, so Settings lives
/// in its own panel-style window (HIG) instead of clobbering the main window's
/// working note/task. Opened via `@Environment(\.openSettings)` / the standard
/// Settings… menu item.
struct SettingsRootView: View {
    @ObservedObject var audioManager: AudioSessionManager

    var body: some View {
        TabView {
            ForEach(SettingsPane.allCases) { pane in
                SettingsPaneView(pane: pane, audioManager: audioManager)
                    .tabItem { Label(pane.title, systemImage: pane.systemImage) }
                    .tag(pane)
            }
        }
        .frame(width: 640, height: 540)
    }
}
