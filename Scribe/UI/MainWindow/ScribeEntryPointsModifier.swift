import SwiftUI

/// Connects the main window to `ScribeEntryRouter`: hands over destinations
/// parked while the window was closed, opens the command bar for
/// `scribe://search`, and continues Handoff / search activities for notes and
/// tasks. Applied once on `MainWindowView`.
struct ScribeEntryPointsModifier: ViewModifier {
    let nav: NavigationCoordinator
    @Binding var showCommandBar: Bool
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onAppear {
                let request = ScribeEntryRouter.shared.mainWindowDidAppear(openWindow: openWindow)
                guard request.selection != nil || request.openCommandBar else { return }
                // Next main-actor turn, so the window's own onAppear (initial
                // destination, live-recording override) runs first and a
                // link's destination wins.
                let nav = self.nav
                let commandBar = $showCommandBar
                let selection = request.selection
                let openCommandBar = request.openCommandBar
                Task { @MainActor in
                    if let selection {
                        nav.navigate(to: selection)
                    }
                    if openCommandBar {
                        commandBar.wrappedValue = true
                    }
                }
            }
            .onDisappear {
                ScribeEntryRouter.shared.mainWindowDidDisappear()
            }
            .onReceive(NotificationCenter.default.publisher(for: .scribeOpenCommandBar)) { _ in
                showCommandBar = true
            }
            .onContinueUserActivity(ScribeUserActivity.viewNote) { activity in
                _ = ScribeEntryRouter.shared.continueActivity(activity)
            }
            .onContinueUserActivity(ScribeUserActivity.viewTask) { activity in
                _ = ScribeEntryRouter.shared.continueActivity(activity)
            }
    }
}
