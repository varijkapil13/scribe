import KeyboardShortcuts

// MARK: - Shortcut Names

extension KeyboardShortcuts.Name {

    /// Global shortcut to toggle recording on or off.
    static let toggleRecording = Self(
        "toggleRecording",
        default: .init(.r, modifiers: [.command, .shift])
    )

    /// Global shortcut for dictation into the focused app. Toggle or
    /// hold-to-talk depending on `DictationController.Mode`.
    static let dictation = Self(
        "dictation",
        default: .init(.d, modifiers: [.option, .command])
    )
}

// MARK: - KeyboardShortcutManager

/// Registers and manages global keyboard shortcuts for the application.
struct KeyboardShortcutManager {

    /// Registers all global keyboard shortcuts.
    ///
    /// - Parameter onToggleRecording: Closure invoked when the user presses the
    ///   toggle-recording shortcut (default: Command+Shift+R).
    ///   - onDictationDown / onDictationUp: Press and release of the
    ///     dictation shortcut (default: Option+Command+D). Both are needed for
    ///     hold-to-talk.
    static func registerShortcuts(
        onToggleRecording: @escaping () -> Void,
        onDictationDown: @escaping () -> Void,
        onDictationUp: @escaping () -> Void
    ) {
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) {
            onToggleRecording()
        }
        KeyboardShortcuts.onKeyDown(for: .dictation) {
            onDictationDown()
        }
        KeyboardShortcuts.onKeyUp(for: .dictation) {
            onDictationUp()
        }
    }
}
