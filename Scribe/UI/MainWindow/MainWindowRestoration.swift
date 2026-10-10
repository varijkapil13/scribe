import SwiftUI

// State restoration for the main window: the selected sidebar destination and
// the sidebar's column visibility are kept in `@SceneStorage` (per window,
// restored by the system on relaunch) as plain strings. The encode/decode
// helpers are pure and unit-tested; the modifier only wires them up.

/// String form of a `MainSelection` for `@SceneStorage`.
///
/// Format: `kind[/sub][/payload]`, e.g. `today`, `note/<id>`,
/// `tasks/project/<id>`, `notes/tag/<tag>`. The payload is always the last
/// component and may itself contain `/` (tags can). Unknown or malformed
/// strings decode to nil, so a stale value never breaks launch.
enum MainSelectionCodec {

    nonisolated static func encode(_ selection: MainSelection) -> String {
        switch selection {
        case .live:              return "live"
        case .today:             return "today"
        case .recordings:        return "recordings"
        case .taskCalendar:      return "taskCalendar"
        case .bases:             return "bases"
        case .ask:               return "ask"
        case .people:            return "people"
        case .task(let id):      return "task/\(id)"
        case .note(let id):      return "note/\(id)"
        case .session(let id):   return "session/\(id)"
        case .tasks(let filter): return "tasks/\(encode(filter))"
        case .notes(let filter): return "notes/\(encode(filter))"
        }
    }

    nonisolated static func decode(_ string: String) -> MainSelection? {
        let (kind, rest) = split(string)
        switch kind {
        case "live":         return rest == nil ? .live : nil
        case "today":        return rest == nil ? .today : nil
        case "recordings":   return rest == nil ? .recordings : nil
        case "taskCalendar": return rest == nil ? .taskCalendar : nil
        case "bases":        return rest == nil ? .bases : nil
        case "ask":          return rest == nil ? .ask : nil
        case "people":       return rest == nil ? .people : nil
        case "task":         return nonEmpty(rest).map { .task($0) }
        case "note":         return nonEmpty(rest).map { .note($0) }
        case "session":      return nonEmpty(rest).map { .session($0) }
        case "tasks":        return rest.flatMap(decodeTaskFilter).map { .tasks($0) }
        case "notes":        return rest.flatMap(decodeNotesFilter).map { .notes($0) }
        default:             return nil
        }
    }

    // MARK: Task filters

    nonisolated static func encode(_ filter: TaskStore.Filter) -> String {
        switch filter {
        case .inbox:            return "inbox"
        case .today:            return "today"
        case .upcoming:         return "upcoming"
        case .all:              return "all"
        case .completed:        return "completed"
        case .someday:          return "someday"
        case .area(let id):     return "area/\(id)"
        case .project(let id):  return "project/\(id)"
        case .tag(let tag):     return "tag/\(tag)"
        case .dueOn(let date):  return "dueOn/\(Int(date.timeIntervalSince1970.rounded()))"
        }
    }

    nonisolated static func decodeTaskFilter(_ string: String) -> TaskStore.Filter? {
        let (kind, rest) = split(string)
        switch kind {
        case "inbox":     return rest == nil ? .inbox : nil
        case "today":     return rest == nil ? .today : nil
        case "upcoming":  return rest == nil ? .upcoming : nil
        case "all":       return rest == nil ? .all : nil
        case "completed": return rest == nil ? .completed : nil
        case "someday":   return rest == nil ? .someday : nil
        case "area":      return nonEmpty(rest).map { .area($0) }
        case "project":   return nonEmpty(rest).map { .project($0) }
        case "tag":       return nonEmpty(rest).map { .tag($0) }
        case "dueOn":
            guard let raw = rest, let seconds = Int(raw) else { return nil }
            return .dueOn(Date(timeIntervalSince1970: TimeInterval(seconds)))
        default:          return nil
        }
    }

    // MARK: Notes filters

    nonisolated static func encode(_ filter: NotesFilter) -> String {
        switch filter {
        case .all:                 return "all"
        case .inbox:               return "inbox"
        case .daily:               return "daily"
        case .graph:               return "graph"
        case .notebook(let id):    return "notebook/\(id)"
        case .tag(let tag):        return "tag/\(tag)"
        }
    }

    nonisolated static func decodeNotesFilter(_ string: String) -> NotesFilter? {
        let (kind, rest) = split(string)
        switch kind {
        case "all":      return rest == nil ? .all : nil
        case "inbox":    return rest == nil ? .inbox : nil
        case "daily":    return rest == nil ? .daily : nil
        case "graph":    return rest == nil ? .graph : nil
        case "notebook": return nonEmpty(rest).map { .notebook($0) }
        case "tag":      return nonEmpty(rest).map { .tag($0) }
        default:         return nil
        }
    }

    // MARK: Restoration policy

    /// The selection to restore at launch from a stored string, or nil to keep
    /// the default. `.live` is never restored (no session is running at
    /// launch), and nothing is restored while a recording is already active —
    /// the recording navigation policy owns the initial destination then.
    nonisolated static func restoredSelection(from stored: String, isRecording: Bool) -> MainSelection? {
        guard !isRecording, let selection = decode(stored) else { return nil }
        if case .live = selection { return nil }
        return selection
    }

    // MARK: Helpers

    /// Splits on the FIRST `/`: `"a/b/c"` → `("a", "b/c")`, `"a"` → `("a", nil)`.
    nonisolated private static func split(_ string: String) -> (String, String?) {
        guard let slash = string.firstIndex(of: "/") else { return (string, nil) }
        return (String(string[..<slash]), String(string[string.index(after: slash)...]))
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// String form of the main window's sidebar column visibility.
@MainActor
enum ColumnVisibilityCodec {
    static func encode(_ visibility: NavigationSplitViewVisibility) -> String {
        if visibility == .detailOnly { return "detailOnly" }
        if visibility == .doubleColumn { return "doubleColumn" }
        if visibility == .all { return "all" }
        return "automatic"
    }

    /// Only the two states the main window toggles between are restored.
    /// For this two-column split, `.doubleColumn` (which View › Show Sidebar
    /// may report) is the same as `.all`.
    static func decode(_ string: String) -> NavigationSplitViewVisibility? {
        switch string {
        case "detailOnly":          return .detailOnly
        case "all", "doubleColumn": return .all
        default:                    return nil
        }
    }
}

/// Persists and restores the main window's selection + sidebar visibility.
struct MainWindowRestorationModifier: ViewModifier {
    let nav: NavigationCoordinator
    @Binding var columnVisibility: NavigationSplitViewVisibility
    let isRecording: Bool

    @SceneStorage("scribe.main.selection") private var storedSelection: String = ""
    @SceneStorage("scribe.main.columnVisibility") private var storedColumns: String = ""
    @State private var didRestore = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !didRestore else { return }
                didRestore = true
                // UI tests expect every launch to start from the default
                // destination, whatever a previous run left in scene storage.
                guard !AppLaunchEnvironment.isUITesting,
                      !AppLaunchEnvironment.usesUITestFixtures else { return }
                if let selection = MainSelectionCodec.restoredSelection(from: storedSelection,
                                                                        isRecording: isRecording) {
                    // No Back entry: the user didn't navigate, the window did.
                    nav.replaceCurrent(selection)
                }
                if let visibility = ColumnVisibilityCodec.decode(storedColumns) {
                    columnVisibility = visibility
                }
            }
            .onChange(of: nav.current) { _, newValue in
                storedSelection = MainSelectionCodec.encode(newValue)
            }
            .onChange(of: columnVisibility) { _, newValue in
                storedColumns = ColumnVisibilityCodec.encode(newValue)
            }
    }
}
