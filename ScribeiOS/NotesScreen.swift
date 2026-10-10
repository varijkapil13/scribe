import SwiftUI

/// iOS Notes surface. Kept as the name the app shell's tab / sidebar uses;
/// the Notes area itself is `NotesRootView` (ScribeiOS/Notes/): a three-column
/// split view on iPad, a navigation stack on iPhone, the shared CodeMirror
/// editor, iCloud vault sync and locked notes.
struct NotesScreen: View {
    var body: some View {
        NotesRootView()
    }
}
