import SwiftUI

// Scene-focused values the menu bar reads (`@FocusedValue`) so its commands
// act on — and enable/disable for — whatever the key window is showing. Views
// publish them with `.focusedSceneValue(...)`; a scene value is visible to
// commands whenever its window is key, even while keyboard focus sits inside
// an AppKit-hosted view such as the editor's WKWebView.

/// The note shown in the key window, plus the hooks note-level commands use.
struct NoteCommandContext {
    let noteId: String
    let title: String
    /// Shows/hides the note inspector (View › Show Inspector).
    let isInspectorPresented: Binding<Bool>
}

struct ScribeNoteCommandContextKey: FocusedValueKey {
    typealias Value = NoteCommandContext
}

struct ScribeEditorCommandsKey: FocusedValueKey {
    typealias Value = EditorCommandBridge
}

extension FocusedValues {
    /// The note open in the key window (main window detail or a note window).
    var scribeNote: NoteCommandContext? {
        get { self[ScribeNoteCommandContextKey.self] }
        set { self[ScribeNoteCommandContextKey.self] = newValue }
    }

    /// The note editor in the key window — the Format and Find menus' target.
    var scribeEditorCommands: EditorCommandBridge? {
        get { self[ScribeEditorCommandsKey.self] }
        set { self[ScribeEditorCommandsKey.self] = newValue }
    }
}
