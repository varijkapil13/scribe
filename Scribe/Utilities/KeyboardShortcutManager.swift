import KeyboardShortcuts

// MARK: - Shortcut Names

extension KeyboardShortcuts.Name {

    /// Global shortcut to toggle recording on or off.
    static let toggleRecording = Self(
        "toggleRecording",
        default: .init(.r, modifiers: [.command, .shift])
    )
}

// MARK: - KeyboardShortcutManager

/// Registers and manages global keyboard shortcuts for the application.
struct KeyboardShortcutManager {

    /// Registers all global keyboard shortcuts.
    ///
    /// - Parameter onToggleRecording: Closure invoked when the user presses the
    ///   toggle-recording shortcut (default: Command+Shift+R).
    static func registerShortcuts(onToggleRecording: @escaping () -> Void) {
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) {
            onToggleRecording()
        }
    }
}
