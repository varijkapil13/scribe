import Foundation

/// Which preferences go into a backup's `settings.plist`, and which are put
/// back on restore.
///
/// Export takes Scribe's own preferences domain and drops system keys
/// (window frames, AppKit state) plus:
///
/// - machine-specific values (vault / storage paths, microphone id), which
///   would point at folders or devices that may not exist after a restore —
///   a restore always lands in the *current* vault location;
/// - switches that run code, open a network listener or send data off the
///   Mac (meeting hooks, MCP server, remote PlantUML rendering, iCloud).
///   A backup file can come from anywhere, so restoring one never turns those
///   on; the user re-enables them in Settings;
/// - bookkeeping (onboarding progress, backup schedule state).
///
/// Keys are spelled out as literals because some of the owning types are
/// main-actor isolated; ScribeBackupSettingsTests pins them to the real
/// constants.
enum ScribeBackupSettings {

    static let excludedKeys: Set<String> = [
        // Machine-specific locations / devices
        "notesVaultPath",
        "storageLocation",
        "selectedMicrophoneID",
        // Features that run code, listen on the network or upload data
        "postMeetingHooksEnabled",
        "postMeetingHookPaths",
        "mcpEnabled",
        "mcpPort",
        "editor.plantUMLRemoteRendering",
        "speakerDiarizationAllowModelDownload",
        "iCloudSyncEnabled",
        "iCloudNotesEnabled",
        "cloudKitSyncEnabled",
        // Bookkeeping
        "calendarScheduledReminderIds",
        "hasCompletedOnboarding",
        "settings.selectedPane",
    ]

    /// Prefixes of keys never exported: system/AppKit state and Scribe's own
    /// backup + onboarding bookkeeping.
    static let excludedPrefixes: [String] = [
        "NS", "Apple", "com.apple.", "AK", "WebKit", "PK", "MSV", "_",
        "backup.", "onboarding.",
    ]

    /// Whether `key` may be exported / restored.
    nonisolated static func isIncluded(key: String) -> Bool {
        if excludedKeys.contains(key) { return false }
        return !excludedPrefixes.contains { key.hasPrefix($0) }
    }

    /// The subset of `dictionary` that goes into a backup: allowed keys whose
    /// values are property-list representable.
    nonisolated static func exportable(from dictionary: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dictionary where isIncluded(key: key) {
            if PropertyListSerialization.propertyList(value, isValidFor: .xml) {
                result[key] = value
            }
        }
        return result
    }

    nonisolated static func encode(_ dictionary: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    /// Decodes a backup's settings plist, re-applying the key filter so a
    /// hand-edited file can't set excluded keys.
    nonisolated static func decodeRestorable(_ data: Data) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = object as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return exportable(from: dictionary)
    }

    /// Scribe's own preferences (not the global domain).
    nonisolated static func currentPreferences(defaults: UserDefaults = .standard) -> [String: Any] {
        if let bundleId = Bundle.main.bundleIdentifier,
           let domain = defaults.persistentDomain(forName: bundleId) {
            return domain
        }
        // No bundle id (e.g. a command-line host): fall back to the merged
        // view; the prefix filter drops the global-domain noise.
        return defaults.dictionaryRepresentation()
    }

    /// Encoded `settings.plist` contents plus the number of keys in it.
    nonisolated static func currentSettingsPlist(defaults: UserDefaults = .standard) -> (data: Data, count: Int)? {
        let exportable = exportable(from: currentPreferences(defaults: defaults))
        guard let data = try? encode(exportable) else { return nil }
        return (data, exportable.count)
    }

    /// Writes restorable keys from a backup into `defaults`. Returns the
    /// number of keys applied. Keys not in the backup are left as they are.
    @discardableResult
    nonisolated static func apply(_ data: Data, to defaults: UserDefaults = .standard) throws -> Int {
        let values = try decodeRestorable(data)
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
        return values.count
    }
}
