import Foundation

// Pure navigation model for the iPhone / iPad shell (ScribeiOS/Shell).
//
// This file lives in Scribe/App so the macOS `swift test` job compiles and
// tests it (ScribeMobileRoutingTests); project.yml also compiles it into the
// ScribeiOS target. Foundation only — no SwiftUI, UIKit or AppKit — and it
// never touches app state: it only maps entry points (scribe:// links, Handoff
// activities, Spotlight results) to a destination the shell then shows.

// MARK: - Tabs

/// The top-level destinations of the iOS shell's `TabView` (a tab bar on
/// iPhone, a collapsible sidebar on iPad).
enum ScribeMobileTab: String, CaseIterable, Codable, Sendable, Hashable {
    case today
    case notes
    case tasks
    case record
    case search
    case settings

    nonisolated var title: String {
        switch self {
        case .today:    return "Today"
        case .notes:    return "Notes"
        case .tasks:    return "Tasks"
        case .record:   return "Record"
        case .search:   return "Search"
        case .settings: return "Settings"
        }
    }

    nonisolated var systemImage: String {
        switch self {
        case .today:    return "sun.max"
        case .notes:    return "doc.text"
        case .tasks:    return "checklist"
        case .record:   return "waveform"
        case .search:   return "magnifyingglass"
        case .settings: return "gearshape"
        }
    }

    /// Stable identifier for `TabViewCustomization` (persisted in
    /// UserDefaults). NEVER rename: a changed id silently drops the user's
    /// saved sidebar/tab-bar arrangement.
    nonisolated var customizationID: String {
        "com.varij.scribe.tab." + rawValue
    }

    /// The tab a scene restores to from its `@SceneStorage` raw value;
    /// `.today` for a missing or unknown value (e.g. a tab removed in an
    /// update).
    nonisolated static func restored(from raw: String?) -> ScribeMobileTab {
        guard let raw, let tab = ScribeMobileTab(rawValue: raw) else { return .today }
        return tab
    }

    /// The tab for the Go menu's ⌘1… shortcuts (1-based), nil when out of
    /// range.
    nonisolated static func forShortcutNumber(_ number: Int) -> ScribeMobileTab? {
        let ordered: [ScribeMobileTab] = [.today, .notes, .tasks, .record]
        guard number >= 1, number <= ordered.count else { return nil }
        return ordered[number - 1]
    }
}

// MARK: - Routes

/// What a capture entry point asks the Record tab to do.
enum ScribeMobileRecordCommand: String, Equatable, Sendable {
    case start
    case stop
}

/// A destination (or action) the iOS shell should show / perform, mapped
/// from an external entry point.
enum ScribeMobileRoute: Equatable, Sendable {
    case tab(ScribeMobileTab)
    case note(id: String)
    case noteByTitle(String)
    case newNote(title: String?, body: String?)
    case task(id: String)
    case newTask(title: String, due: String?)
    case search(query: String)
    case record(ScribeMobileRecordCommand)
    case meeting(sessionId: String)

    /// The tab the route lands on.
    nonisolated var tab: ScribeMobileTab {
        switch self {
        case .tab(let tab):              return tab
        case .note, .noteByTitle, .newNote: return .notes
        case .task, .newTask:            return .tasks
        case .search:                    return .search
        case .record, .meeting:          return .record
        }
    }

    // MARK: scribe:// links

    /// Maps a parsed `scribe://` link. Every link has an iOS meaning:
    /// dictation (a Mac-only feature) opens the Record tab, and
    /// `import-share` lands on Notes (the Share extension inbox is imported
    /// by the notes area).
    nonisolated static func from(_ link: ScribeDeepLink) -> ScribeMobileRoute {
        switch link {
        case .note(let id):                 return .note(id: id)
        case .noteByTitle(let title):       return .noteByTitle(title)
        case .newNote(let title, let body): return .newNote(title: title, body: body)
        case .task(let id):                 return .task(id: id)
        case .newTask(let title, let due):  return .newTask(title: title, due: due)
        case .meeting(let sessionId):       return .meeting(sessionId: sessionId)
        case .startRecording:               return .record(.start)
        case .stopRecording:                return .record(.stop)
        case .dictate:                      return .tab(.record)
        case .search(let query):            return .search(query: query)
        case .today:                        return .tab(.today)
        case .importShared:                 return .tab(.notes)
        }
    }

    /// `scribe://…` → route; nil for any other URL or an unknown route.
    nonisolated static func from(url: URL) -> ScribeMobileRoute? {
        ScribeDeepLink.parse(url).map { from($0) }
    }

    // MARK: Handoff / NSUserActivity

    /// A continued Handoff activity (`com.varij.scribe.viewNote` /
    /// `viewTask`, published by the Mac and by the iOS detail screens) or a
    /// note-window drag activity → route. Nil when the type is not Scribe's
    /// or the id is missing / blank.
    nonisolated static func fromActivity(type: String, userInfo: [AnyHashable: Any]?) -> ScribeMobileRoute? {
        guard let raw = userInfo?[ScribeUserActivity.idKey] as? String else { return nil }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        switch type {
        case ScribeUserActivity.viewNote, ScribeMobileWindows.openNoteWindowActivityType:
            return .note(id: id)
        case ScribeUserActivity.viewTask:
            return .task(id: id)
        default:
            return nil
        }
    }

    // MARK: Spotlight

    /// Spotlight item prefixes. Must match `SpotlightItemID` (macOS indexer,
    /// Scribe/Intents) — `ScribeMobileRoutingTests` pins the agreement.
    nonisolated static let spotlightNotePrefix = "note:"
    nonisolated static let spotlightTaskPrefix = "task:"

    /// A continued Spotlight result's unique identifier (`note:<id>` /
    /// `task:<id>`) → route; nil for anything else or an empty id.
    nonisolated static func fromSpotlightIdentifier(_ raw: String) -> ScribeMobileRoute? {
        if raw.hasPrefix(spotlightNotePrefix) {
            let id = String(raw.dropFirst(spotlightNotePrefix.count))
            return id.isEmpty ? nil : .note(id: id)
        }
        if raw.hasPrefix(spotlightTaskPrefix) {
            let id = String(raw.dropFirst(spotlightTaskPrefix.count))
            return id.isEmpty ? nil : .task(id: id)
        }
        return nil
    }
}

// MARK: - Windows (iPad)

/// Identifiers for the iPad's extra note windows.
enum ScribeMobileWindows {
    /// `WindowGroup(id:for:)` id of the standalone note window.
    nonisolated static let noteWindowGroupID = "scribe-note-window"

    /// Activity type a note row registers on its drag item, so dropping it
    /// at the screen edge opens a new note window. Distinct from the Handoff
    /// `viewNote` type so a Handoff from the Mac continues in the existing
    /// window instead of spawning a new one.
    nonisolated static let openNoteWindowActivityType = "com.varij.scribe.openNoteWindow"

    /// `targetContentIdentifier` of that drag activity; the note window
    /// scene matches it via `handlesExternalEvents(matching:)`.
    nonisolated static let noteWindowTargetContentIdentifier = "scribe-note-window"

    /// Every activity type the iOS app continues (Info.plist
    /// `NSUserActivityTypes`, set in project.yml's ScribeiOS `info:` block).
    nonisolated static var continuedActivityTypes: [String] {
        ScribeUserActivity.allTypes + [openNoteWindowActivityType]
    }
}

// MARK: - Appearance

/// iOS Settings › Appearance: the colour scheme override.
enum ScribeMobileAppearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    nonisolated static let storageKey = "ios.appearance"

    nonisolated var title: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    nonisolated static func resolved(from raw: String) -> ScribeMobileAppearance {
        ScribeMobileAppearance(rawValue: raw) ?? .system
    }
}
