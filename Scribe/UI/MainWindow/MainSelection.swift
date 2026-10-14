import Foundation

// The navigation/selection model. Kept in its OWN file (in the SwiftPM target)
// rather than in MainWindowView.swift, because the editor rewrite excludes the
// SwiftUI view layer (MainWindowView et al.) from the `swift test` target.
// Kept logic — NavigationCoordinator, RecordingNavigationPolicy, CommandRegistry
// — depends on these types, so they must remain compiled in the test target.

/// Destination a user can navigate to from the main window's sidebar. Combines
/// transcript sessions with settings panes and, while a session is running,
/// the live-recording view so there's only ever one window to look at.
enum MainSelection: Hashable {
    case live
    case today
    case recordings             // transcript archive (browsable session library)
    case tasks(TaskStore.Filter)
    case taskCalendar
    case task(String)           // taskId — command-bar deep-link
    case note(String)           // noteId
    case notes(NotesFilter)
    case bases                  // cross-note property views (Obsidian-style Bases)
    case session(String)        // sessionId — transcript reader deep-link
    case ask                    // "Ask Scribe" — chat across meetings
    case people                 // people seen across meetings
}

enum NotesFilter: Hashable {
    case all
    case inbox
    case daily
    case notebook(String)   // notebookId
    case tag(String)
    case graph
}
