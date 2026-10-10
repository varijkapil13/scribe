import Foundation

/// `NSUserActivity` types Scribe publishes for Handoff and system search
/// (declared under `NSUserActivityTypes` in Info.plist), plus the pure
/// mapping from a continued activity back to a main-window destination.
enum ScribeUserActivity {
    nonisolated static let viewNote = "com.varij.scribe.viewNote"
    nonisolated static let viewTask = "com.varij.scribe.viewTask"

    /// `userInfo` key carrying the note / task id.
    nonisolated static let idKey = "id"

    nonisolated static var allTypes: [String] { [viewNote, viewTask] }

    #if os(macOS)
    /// The destination a continued activity should open, or nil when the
    /// type is not Scribe's or the id is missing / blank. (`MainSelection` is
    /// the macOS main window's model; the iOS shell maps activities through
    /// `ScribeMobileRoute.fromActivity(type:userInfo:)` instead.)
    nonisolated static func destination(activityType: String, userInfo: [AnyHashable: Any]?) -> MainSelection? {
        guard let raw = userInfo?[idKey] as? String else { return nil }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        switch activityType {
        case viewNote: return .note(id)
        case viewTask: return .task(id)
        default:       return nil
        }
    }
    #endif
}

/// UserDefaults keys for the "Links & Handoff" settings pane.
enum EntryPointSettings {
    /// Whether `scribe://record/…` and `scribe://dictate` links may start or
    /// stop capture. (The Dock menu is always allowed — it's a direct click.)
    nonisolated static let allowCaptureLinksKey = "links.allowCaptureControl"
    /// Whether open notes/tasks are advertised for Handoff and search.
    nonisolated static let handoffEnabledKey = "handoff.enabled"

    nonisolated static func bool(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? true
    }
}
