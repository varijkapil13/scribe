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
    case session(String)        // sessionId — transcript reader deep-link
}

enum NotesFilter: Hashable {
    case all
    case inbox
    case daily
    case notebook(String)   // notebookId
    case tag(String)
    case graph
}

/// Top-level product surface — the Arc-style grouping the sidebar filters by
/// and ⌘1/2/3 jump between. Derived from the active `MainSelection` so the
/// switcher highlight always follows navigation (no separate state to sync).
enum Surface: Int, CaseIterable, Identifiable {
    case capture = 1
    case notes = 2
    case tasks = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .capture: return "Capture"
        case .notes:   return "Notes"
        case .tasks:   return "Tasks"
        }
    }

    var systemImage: String {
        switch self {
        case .capture: return "waveform"
        case .notes:   return "doc.text"
        case .tasks:   return "checklist"
        }
    }

    /// The destination ⌘1/2/3 (and the switcher) jump to for this surface.
    var defaultSelection: MainSelection {
        switch self {
        case .capture: return .today
        case .notes:   return .notes(.all)
        case .tasks:   return .tasks(.inbox)
        }
    }
}

extension MainSelection {
    /// The product surface this destination belongs to — drives the sidebar
    /// switcher highlight and section filtering.
    var surface: Surface {
        switch self {
        case .live, .today, .session, .recordings: return .capture
        case .note, .notes:                        return .notes
        case .tasks, .taskCalendar, .task:         return .tasks
        }
    }
}
