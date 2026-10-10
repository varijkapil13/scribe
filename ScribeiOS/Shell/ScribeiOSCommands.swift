import SwiftUI

/// Hardware-keyboard shortcuts and the iPadOS menu bar. Acts on the key
/// scene's navigator (published by RootTabView with `.focusedSceneValue`);
/// every command is disabled while no main window is key (e.g. a standalone
/// note window).
struct ScribeiOSCommands: Commands {
    @FocusedValue(\.scribeiOSNavigator) private var navigator: ScribeiOSNavigator?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Note") { navigator?.newNote() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(navigator == nil)
            Button("New Task") { navigator?.presentNewTask() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(navigator == nil)
        }

        CommandMenu("Go") {
            Button("Today") { navigator?.show(.tab(.today)) }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(navigator == nil)
            Button("Notes") { navigator?.show(.tab(.notes)) }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(navigator == nil)
            Button("Tasks") { navigator?.show(.tab(.tasks)) }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(navigator == nil)
            Button("Record") { navigator?.show(.tab(.record)) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(navigator == nil)
            Divider()
            Button("Search") { navigator?.focusSearch(query: "") }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(navigator == nil)
            Button("Quick Open") { navigator?.focusSearch(query: "") }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(navigator == nil)
            Divider()
            // Deliberately no ⌘, so it can't clash with a binding the
            // system app menu may own.
            Button("Settings") { navigator?.show(.tab(.settings)) }
                .disabled(navigator == nil)
        }
    }
}
