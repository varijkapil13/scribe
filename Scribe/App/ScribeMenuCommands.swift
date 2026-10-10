import SwiftUI

/// Standard macOS menus plus Scribe's note-level commands: View (sidebar,
/// toolbar, inspector), Edit (text editing, find in note), Format, File
/// (open in new window, print, export as PDF) and Help.
///
/// Note commands read the key window's focused values (`FocusedValues.scribeNote`
/// / `.scribeEditorCommands`) so they act on whichever window — main or a
/// standalone note window — is in front, and disable themselves otherwise.
/// Menu items are small Views so they can use `@FocusedValue` / `@Environment`.
struct ScribeMenuCommands: Commands {

    var body: some Commands {
        // View › Show/Hide Sidebar (⌃⌘S), View › toolbar items incl. Customize
        // Toolbar…, Edit › Find / Spelling / Substitutions / Transformations / Speech.
        SidebarCommands()
        ToolbarCommands()
        TextEditingCommands()

        // File: note-window + output commands, after the creation verbs.
        CommandGroup(after: .newItem) {
            Divider()
            OpenNoteInNewWindowMenuItem()
        }
        CommandGroup(replacing: .printItem) {
            NoteExportPDFMenuItem()
            NotePrintMenuItem()
        }

        // View › Show/Hide Inspector (⌥⌘I).
        CommandGroup(after: .sidebar) {
            NoteInspectorMenuItem()
        }

        // Edit › Find in Note — the CodeMirror editor's own find, placed ahead
        // of the standard Find submenu so its shortcuts win while a note editor
        // is in the key window.
        CommandGroup(before: .textEditing) {
            EditorFindMenu()
        }

        CommandMenu("Format") {
            EditorFormatMenuItems()
        }

        CommandGroup(replacing: .help) {
            ScribeHelpMenuItems()
        }
    }
}

// MARK: - File

private struct OpenNoteInNewWindowMenuItem: View {
    @FocusedValue(\.scribeNote) private var note
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open in New Window") {
            guard let note else { return }
            openWindow(id: NoteWindowValue.windowID, value: NoteWindowValue(noteId: note.noteId))
        }
        .keyboardShortcut("o", modifiers: [.command, .option])
        .disabled(note == nil)
    }
}

private struct NoteExportPDFMenuItem: View {
    @FocusedValue(\.scribeNote) private var note

    var body: some View {
        Button("Export as PDF…") {
            guard let note else { return }
            NotePrintRenderer.exportPDF(noteId: note.noteId)
        }
        .disabled(note == nil)
    }
}

private struct NotePrintMenuItem: View {
    @FocusedValue(\.scribeNote) private var note

    var body: some View {
        Button("Print…") {
            guard let note else { return }
            NotePrintRenderer.printNote(id: note.noteId)
        }
        .keyboardShortcut("p", modifiers: .command)
        .disabled(note == nil)
    }
}

// MARK: - View

private struct NoteInspectorMenuItem: View {
    @FocusedValue(\.scribeNote) private var note

    var body: some View {
        Button(note?.isInspectorPresented.wrappedValue == true ? "Hide Inspector" : "Show Inspector") {
            if let presented = note?.isInspectorPresented {
                presented.wrappedValue.toggle()
            }
        }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .disabled(note == nil)
    }
}

// MARK: - Edit › Find in Note

private struct EditorFindMenu: View {
    @FocusedValue(\.scribeEditorCommands) private var editor

    var body: some View {
        Menu("Find in Note") {
            item("Find…", .find, key: "f", modifiers: .command)
            item("Find and Replace…", .findAndReplace, key: "f", modifiers: [.command, .option])
            item("Find Next", .findNext, key: "g", modifiers: .command)
            item("Find Previous", .findPrevious, key: "g", modifiers: [.command, .shift])
        }
        .disabled(editor == nil)
        Divider()
    }

    /// The shortcut is only attached while a note editor is in the key window,
    /// so ⌘F / ⌘G keep reaching the standard Find items (e.g. search fields)
    /// everywhere else.
    private func item(_ title: String, _ command: EditorCommand,
                      key: KeyEquivalent, modifiers: EventModifiers) -> some View {
        Button(title) { editor?.perform(command) }
            .keyboardShortcut(editor == nil ? nil : KeyboardShortcut(key, modifiers: modifiers))
            .disabled(editor == nil)
    }
}

// MARK: - Format

private struct EditorFormatMenuItems: View {
    @FocusedValue(\.scribeEditorCommands) private var editor

    var body: some View {
        item("Bold", .bold, key: "b", modifiers: .command)
        item("Italic", .italic, key: "i", modifiers: .command)
        item("Strikethrough", .strikethrough, key: "x", modifiers: [.command, .shift])
        item("Inline Code", .inlineCode, key: "c", modifiers: [.command, .option])
        item("Link", .link, key: "k", modifiers: [.command, .shift])
        Divider()
        item("Body Text", .heading(0), key: "0", modifiers: [.command, .option])
        item("Heading 1", .heading(1), key: "1", modifiers: [.command, .option])
        item("Heading 2", .heading(2), key: "2", modifiers: [.command, .option])
        item("Heading 3", .heading(3), key: "3", modifiers: [.command, .option])
        Divider()
        item("Bulleted List", .bulletedList, key: "8", modifiers: [.command, .shift])
        item("Numbered List", .numberedList, key: "7", modifiers: [.command, .shift])
        item("Checklist", .checklist, key: "u", modifiers: [.command, .shift])
        item("Quote", .quote, key: ".", modifiers: [.command, .shift])
    }

    private func item(_ title: String, _ command: EditorCommand,
                      key: KeyEquivalent, modifiers: EventModifiers) -> some View {
        Button(title) { editor?.perform(command) }
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(editor == nil)
    }
}

// MARK: - Help

private struct ScribeHelpMenuItems: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Scribe Help") {
            openURL(ScribeHelpLinks.readme)
        }
        Button("Keyboard Shortcuts") {
            openWindow(id: ShortcutReferenceWindow.windowID)
        }
    }
}

/// Where Help › Scribe Help goes.
enum ScribeHelpLinks {
    static let readme = URL(string: "https://github.com/varijkapil13/scribe#readme")!
}
