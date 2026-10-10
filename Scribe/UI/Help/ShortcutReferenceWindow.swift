import SwiftUI

// Help › Keyboard Shortcuts: a reference window listing Scribe's shortcuts.
// The list is plain data (`ShortcutReferenceCatalog`) so tests can check it for
// accidental duplicates when menus change.

/// One shortcut row. `keys` are the key caps in display order, e.g. ["⌥", "⌘", "I"].
struct ShortcutReferenceEntry: Hashable, Sendable {
    let title: String
    let keys: [String]

    /// The keys joined as they appear in menus ("⌥⌘I").
    var combination: String { keys.joined() }
}

struct ShortcutReferenceSection: Hashable, Sendable {
    let title: String
    let entries: [ShortcutReferenceEntry]
}

enum ShortcutReferenceCatalog {

    private static func entry(_ title: String, _ keys: String...) -> ShortcutReferenceEntry {
        ShortcutReferenceEntry(title: title, keys: keys)
    }

    static let sections: [ShortcutReferenceSection] = [
        ShortcutReferenceSection(title: "General", entries: [
            entry("Command Bar", "⌘", "K"),
            entry("New Note", "⌘", "N"),
            entry("New Daily Note", "⌃", "⌘", "N"),
            entry("New Note from Template", "⌥", "⌘", "N"),
            entry("Open Note in New Window", "⌥", "⌘", "O"),
            entry("Print Note", "⌘", "P"),
            entry("Settings", "⌘", ","),
            entry("Start / Stop Recording (anywhere)", "⇧", "⌘", "R"),
        ]),
        ShortcutReferenceSection(title: "Navigation", entries: [
            entry("Back", "⌘", "["),
            entry("Forward", "⌘", "]"),
            entry("Today", "⌘", "1"),
            entry("Notes", "⌘", "2"),
            entry("Tasks", "⌘", "3"),
            entry("Show / Hide Sidebar", "⌃", "⌘", "S"),
            entry("Show / Hide Inspector", "⌥", "⌘", "I"),
            entry("Focus Mode", "⌃", "⌘", "F"),
        ]),
        ShortcutReferenceSection(title: "Editing", entries: [
            entry("Undo", "⌘", "Z"),
            entry("Redo", "⇧", "⌘", "Z"),
            entry("Find in Note", "⌘", "F"),
            entry("Find and Replace", "⌥", "⌘", "F"),
            entry("Find Next", "⌘", "G"),
            entry("Find Previous", "⇧", "⌘", "G"),
            entry("Copy Block Link", "⌥", "⇧", "⌘", "C"),
        ]),
        ShortcutReferenceSection(title: "Format", entries: [
            entry("Bold", "⌘", "B"),
            entry("Italic", "⌘", "I"),
            entry("Strikethrough", "⇧", "⌘", "X"),
            entry("Inline Code", "⌥", "⌘", "C"),
            entry("Link", "⇧", "⌘", "K"),
            entry("Body Text", "⌥", "⌘", "0"),
            entry("Heading 1", "⌥", "⌘", "1"),
            entry("Heading 2", "⌥", "⌘", "2"),
            entry("Heading 3", "⌥", "⌘", "3"),
            entry("Bulleted List", "⇧", "⌘", "8"),
            entry("Numbered List", "⇧", "⌘", "7"),
            entry("Checklist", "⇧", "⌘", "U"),
            entry("Quote", "⇧", "⌘", "."),
        ]),
        ShortcutReferenceSection(title: "Tasks", entries: [
            entry("Toggle Complete (focused task)", "Space"),
            entry("Delete Task", "⌘", "⌫"),
        ]),
    ]
}

/// Scene + view for the Keyboard Shortcuts reference window.
enum ShortcutReferenceWindow {
    static let windowID = "keyboard-shortcuts"
}

struct ShortcutReferenceView: View {
    var body: some View {
        List {
            ForEach(ShortcutReferenceCatalog.sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.entries, id: \.self) { entry in
                        HStack {
                            Text(entry.title)
                            Spacer(minLength: DesignTokens.Spacing.md)
                            KeyCapGroup(keys: entry.keys)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 420, idealHeight: 560)
    }
}
