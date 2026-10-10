import SwiftUI

// TEMPORARY AREA PLACEHOLDERS — DELETE THIS FILE when the real area roots
// land (ios-notes → NotesRootView, ios-tasks → TasksRootView,
// ios-recording → RecordingsRootView). The shell (RootTabView) only refers
// to those three type names, so deleting this file is the whole migration.
// When replacing, keep the shell contract (ScribeiOSNavigator.swift):
//   • apply `.onScribeOpenRequest(.note / .task / .meeting) { … }` to the
//     area's NavigationStack so links, Handoff, Spotlight and ⌘N land;
//   • `.scribeHandoff(.note/.task, id:title:)` on detail screens;
//   • `.scribeNoteRowAffordances(noteId:title:)` on note rows (iPad
//     windows, drag, hover);
//   • the Record area reads `navigator.recordRequest` for
//     scribe://record/start|stop.

// MARK: Placeholder — Notes (replaced by ios-notes' NotesRootView)

/// Placeholder: the existing notes list + editor.
struct NotesRootView: View {
    var body: some View {
        NotesScreen()
    }
}

// MARK: Placeholder — Tasks (replaced by ios-tasks' TasksRootView)

/// Placeholder: the existing task list + detail.
struct TasksRootView: View {
    var body: some View {
        TasksScreen()
    }
}

// MARK: Placeholder — Recording (replaced by ios-recording's RecordingsRootView)

/// Placeholder: recording isn't on iOS yet.
struct RecordingsRootView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Recording",
                systemImage: "waveform",
                description: Text("Recording and transcription are coming to iPhone and iPad.")
            )
            .navigationTitle("Record")
        }
    }
}
