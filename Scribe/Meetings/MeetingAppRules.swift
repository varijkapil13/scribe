import Foundation

/// The user's per-app overrides for meeting detection: catalog apps they've
/// switched off ("never count Slack") and non-catalog apps they've opted in
/// ("always count this softphone").
///
/// Matching is by exact bundle ID or dotted prefix, the same way the catalog
/// matches, so opting in `com.example.phone` also covers the
/// `com.example.phone.helper` process CoreAudio may report. Kept free of
/// AppKit/CoreAudio so CI can pin it down; persisted as string arrays in
/// `UserDefaults` (no database involved).
struct MeetingAppRules: Equatable, Sendable {

    static let disabledKey = "meetingDetectionDisabledApps"
    static let alwaysCountedKey = "meetingDetectionAlwaysCountApps"

    /// Bundle IDs that never count as a meeting, even if they're in the catalog.
    var disabled: Set<String>
    /// Non-catalog bundle IDs that always count, even with "any other app" off.
    var alwaysCounted: Set<String>

    init(disabled: Set<String> = [], alwaysCounted: Set<String> = []) {
        self.disabled = disabled
        self.alwaysCounted = alwaysCounted
    }

    func isDisabled(_ bundleID: String) -> Bool {
        Self.set(disabled, covers: bundleID)
    }

    func isAlwaysCounted(_ bundleID: String) -> Bool {
        Self.set(alwaysCounted, covers: bundleID)
    }

    /// Whether a non-catalog app counts, given the "any other app" setting.
    func countsOtherApp(_ bundleID: String, includeOtherApps: Bool) -> Bool {
        guard !isDisabled(bundleID) else { return false }
        return includeOtherApps || isAlwaysCounted(bundleID)
    }

    /// Flips a non-catalog app on or off. Turning it on opts it in (and lifts
    /// any block); turning it off removes the opt-in and — when "any other
    /// app" is on, where removing the opt-in alone would change nothing —
    /// blocks it explicitly.
    mutating func setOtherApp(_ bundleID: String, counted: Bool, includeOtherApps: Bool) {
        if counted {
            alwaysCounted.insert(bundleID)
            disabled.remove(bundleID)
        } else {
            alwaysCounted.remove(bundleID)
            if includeOtherApps { disabled.insert(bundleID) }
        }
    }

    /// Enables or disables a catalog app (all of its bundle IDs at once, e.g.
    /// classic + new Teams).
    mutating func setCatalogApp(_ bundleIDs: [String], enabled: Bool) {
        for id in bundleIDs {
            if enabled { disabled.remove(id) } else { disabled.insert(id) }
        }
    }

    /// Exact match or `bundleID` is a dotted child of an entry.
    static func set(_ ids: Set<String>, covers bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        if ids.contains(bundleID) { return true }
        return ids.contains { !$0.isEmpty && bundleID.hasPrefix($0 + ".") }
    }

    // MARK: - Persistence

    static func load(from defaults: UserDefaults = .standard) -> MeetingAppRules {
        MeetingAppRules(
            disabled: Set(defaults.stringArray(forKey: disabledKey) ?? []),
            alwaysCounted: Set(defaults.stringArray(forKey: alwaysCountedKey) ?? [])
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(disabled.sorted(), forKey: Self.disabledKey)
        defaults.set(alwaysCounted.sorted(), forKey: Self.alwaysCountedKey)
    }
}

/// One process seen holding the microphone: its bundle ID as CoreAudio
/// reports it, and a display name when one could be resolved.
struct MeetingProcessSample: Equatable, Sendable {
    let bundleID: String
    let name: String?

    init(bundleID: String, name: String? = nil) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Pure combination of every detection input into "which meeting apps are
/// active right now", the input to `MeetingDetectionPolicy`.
enum MeetingSignals {

    /// Settings key for using the camera as a meeting signal (default on).
    static let useCameraKey = "meetingDetectionUseCamera"

    /// Resolves mic-holding processes to meeting apps.
    ///
    /// On top of the plain catalog match, a camera in use is treated as a
    /// strong "this is a video call" signal: a browser or unknown app holding
    /// the mic while a camera runs counts even when browsers / other apps are
    /// excluded. Once a meeting is in progress, the app it's attributed to
    /// keeps counting while it holds the mic, so turning the camera off
    /// mid-call doesn't end the meeting. Apps the user disabled never count.
    static func activeMeetingApps(
        processes: [MeetingProcessSample],
        includeBrowsers: Bool,
        includeOtherApps: Bool,
        rules: MeetingAppRules,
        cameraInUse: Bool,
        currentMeeting: MeetingApp? = nil
    ) -> [MeetingApp] {
        processes.compactMap { process in
            if let app = MeetingAppCatalog.match(
                bundleID: process.bundleID,
                includeBrowsers: includeBrowsers,
                includeOtherApps: includeOtherApps,
                fallbackName: process.name,
                rules: rules
            ) {
                return app
            }
            // Relaxed match: any non-ignored, non-disabled app.
            guard let relaxed = MeetingAppCatalog.match(
                bundleID: process.bundleID,
                includeBrowsers: true,
                includeOtherApps: true,
                fallbackName: process.name,
                rules: rules
            ) else { return nil }
            if cameraInUse { return relaxed }
            if let currentMeeting, currentMeeting.bundleID == relaxed.bundleID { return relaxed }
            return nil
        }
    }
}

/// Remembers non-catalog apps that have used the microphone, so Settings can
/// offer them for "always count as a meeting". Stored as a
/// `[bundleID: name]` dictionary in `UserDefaults`.
enum MeetingAppHistory {

    static let defaultsKey = "meetingDetectionSeenApps"
    /// Cap so a stream of odd helper processes can't grow the list forever.
    static let maxEntries = 100

    /// `seen` with any new non-catalog apps from `samples` added (or a
    /// missing name filled in), or `nil` when nothing changed — so callers
    /// only write `UserDefaults` when there's news.
    static func merged(_ seen: [String: String], with samples: [MeetingProcessSample]) -> [String: String]? {
        var result = seen
        for sample in samples {
            // Only non-catalog, non-ignored apps: the catalog is listed in
            // Settings already, and system speech daemons are never meetings.
            guard MeetingAppCatalog.match(
                bundleID: sample.bundleID, includeBrowsers: true, includeOtherApps: true
            )?.kind == .other else { continue }
            let name = sample.name.flatMap { $0.isEmpty ? nil : $0 }
            if let existing = result[sample.bundleID] {
                // Upgrade a bundle-ID placeholder to a real name.
                if existing == sample.bundleID, let name, name != existing {
                    result[sample.bundleID] = name
                }
            } else if result.count < maxEntries {
                result[sample.bundleID] = name ?? sample.bundleID
            }
        }
        return result == seen ? nil : result
    }

    static func load(from defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    static func record(_ samples: [MeetingProcessSample], in defaults: UserDefaults = .standard) {
        guard !samples.isEmpty, let updated = merged(load(from: defaults), with: samples) else { return }
        defaults.set(updated, forKey: defaultsKey)
    }

    static func forget(_ bundleID: String, in defaults: UserDefaults = .standard) {
        var seen = load(from: defaults)
        guard seen.removeValue(forKey: bundleID) != nil else { return }
        defaults.set(seen, forKey: defaultsKey)
    }
}

extension MeetingAppCatalog {

    /// One row in the "Meeting apps" settings list: a display name and every
    /// catalog bundle ID that shares it (classic + new Teams, Safari + the
    /// WebKit GPU process…).
    struct Entry: Equatable, Identifiable, Sendable {
        let name: String
        let bundleIDs: [String]
        let kind: MeetingApp.Kind
        var id: String { name + "|" + kind.rawValue }
    }

    /// Catalog apps of one kind, grouped by display name, sorted by name.
    static func entries(kind: MeetingApp.Kind) -> [Entry] {
        let table: [String: String]
        switch kind {
        case .conferencing: table = conferencing
        case .browser:      table = browsers
        case .other:        return []
        }
        var grouped: [String: [String]] = [:]
        for (id, name) in table { grouped[name, default: []].append(id) }
        return grouped
            .map { Entry(name: $0.key, bundleIDs: $0.value.sorted(), kind: kind) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
