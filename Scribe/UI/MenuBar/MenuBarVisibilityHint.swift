import AppKit
import SwiftUI

/// Whether Scribe's menu-bar item is actually on screen. On macOS 27 the
/// system's menu bar management (System Settings › Menu Bar / Control Center)
/// can hide third-party menu bar extras even while "Show in menu bar" is on.
enum MenuBarItemVisibility: Sendable, Equatable {
    case visible
    case hidden
    /// The probe couldn't tell (no status-bar window found).
    case unknown
}

/// Pure decision for the one-time "your menu bar item is hidden" hint.
enum MenuBarHintPolicy {
    /// Set once the hint has been displayed, so it never nags.
    static let shownKey = "menuBarHiddenHintShown"

    /// Show only when the user wants the icon, it's demonstrably hidden, and
    /// the hint hasn't been shown before. `.unknown` never triggers it.
    nonisolated static func shouldShow(prefersIcon: Bool,
                                       visibility: MenuBarItemVisibility,
                                       alreadyShown: Bool) -> Bool {
        prefersIcon && visibility == .hidden && !alreadyShown
    }
}

/// Best-effort probe for the menu bar item's visibility.
@MainActor
enum MenuBarVisibilityProbe {
    /// SwiftUI's `MenuBarExtra` is backed by an `NSStatusItem`, whose button
    /// lives in a private status-bar window listed in `NSApp.windows`. If that
    /// window exists but isn't visible on any screen, the system is hiding it.
    /// (Heuristic by design — it relies on the window's class name, so it
    /// answers `.unknown` rather than guessing when nothing matches.)
    static func current() -> MenuBarItemVisibility {
        // An auto-hidden / full-screen menu bar hides every status item; that
        // is not "macOS is hiding Scribe", so don't guess.
        guard NSMenu.menuBarVisible() else { return .unknown }
        let statusWindows = NSApp.windows.filter {
            NSStringFromClass(type(of: $0)).contains("StatusBarWindow")
        }
        guard !statusWindows.isEmpty else { return .unknown }
        let anyVisible = statusWindows.contains {
            $0.isVisible && $0.occlusionState.contains(.visible)
        }
        return anyVisible ? .visible : .hidden
    }

    /// Opens the System Settings pane that controls which apps may show in the
    /// menu bar. (The pane identifier is the only uncertain bit; an unknown
    /// identifier still opens System Settings.)
    static func openMenuBarSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// One-time onboarding hint shown when "Show in menu bar" is on but macOS is
/// hiding Scribe's menu bar item. Renders nothing otherwise.
struct MenuBarHiddenHint: View {
    @AppStorage(MenuBarPreferences.showIconKey) private var showMenuBarIcon = true
    @AppStorage(MenuBarHintPolicy.shownKey) private var hintShown = false
    @State private var visibility: MenuBarItemVisibility = .unknown

    private var isShowing: Bool {
        MenuBarHintPolicy.shouldShow(prefersIcon: showMenuBarIcon,
                                     visibility: visibility,
                                     alreadyShown: hintShown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            if isShowing {
                Label {
                    Text("Don’t see Scribe in the menu bar? macOS may be hiding it. Allow Scribe in System Settings › Menu Bar.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "menubar.rectangle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Button("Open Menu Bar Settings") {
                    MenuBarVisibilityProbe.openMenuBarSettings()
                }
                .controlSize(.small)
            }
        }
        .task {
            // Give the menu bar extra a moment to be placed before probing.
            try? await Task.sleep(for: .milliseconds(400))
            visibility = MenuBarVisibilityProbe.current()
        }
        .onDisappear {
            if isShowing { hintShown = true }
        }
    }
}
