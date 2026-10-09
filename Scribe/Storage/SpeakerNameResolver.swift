import Foundation

/// Resolves the human-readable name shown for a transcript segment's speaker.
///
/// At capture time Scribe only knows which *source* produced a
/// segment — the microphone (`"you"`) or captured system audio (`"remote"`).
/// Naming works on top of that:
///
/// - Per-session names (`session_speakers` table) rename a source key for one
///   session, e.g. `"remote"` → `"Priya"`.
/// - Per-segment overrides (`segments.speakerOverride`) reassign a segment to
///   another speaker key — either a built-in key or a custom speaker whose
///   key is simply its name (see `key(forNewSpeakerNamed:)`).
/// - A global default for `"you"` (Settings → Vocabulary → Speakers, defaults
///   to the macOS account's full name).
///
/// On macOS, post-meeting diarization (`Scribe/Diarization/`) splits the
/// remote stream into "Speaker 1…N" keys stored as segment overrides; this
/// resolver treats them like any other custom key.
///
/// Pure value type (Foundation only) so it is shared with the iOS target and
/// pinned by tests.
struct SpeakerNameResolver: Equatable, Sendable {

    static let youKey = "you"
    static let remoteKey = "remote"

    /// Session-specific names keyed by speaker key.
    var sessionNames: [String: String]
    /// Global display name for `"you"`; `nil`/empty falls back to "You".
    var defaultYouName: String?

    init(sessionNames: [String: String] = [:], defaultYouName: String? = nil) {
        self.sessionNames = sessionNames
        self.defaultYouName = defaultYouName
    }

    // MARK: - Keys

    /// The speaker key a segment is attributed to after any reassignment.
    static func effectiveKey(speaker: String, override: String?) -> String {
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return canonicalKey(override)
        }
        return canonicalKey(speaker)
    }

    static func effectiveKey(for segment: Segment) -> String {
        effectiveKey(speaker: segment.speaker, override: segment.speakerOverride)
    }

    /// Built-in source keys are matched case-insensitively ("You", "REMOTE");
    /// custom keys are kept verbatim.
    static func canonicalKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case youKey: return youKey
        case remoteKey: return remoteKey
        default: return trimmed
        }
    }

    /// Key for a speaker the user adds by name while reassigning segments.
    /// Typing "you"/"remote" maps back onto the built-in sources.
    static func key(forNewSpeakerNamed name: String) -> String {
        canonicalKey(name)
    }

    // MARK: - Names

    func displayName(forKey rawKey: String) -> String {
        let key = Self.canonicalKey(rawKey)
        if let custom = sessionNames[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        switch key {
        case Self.youKey:
            if let name = defaultYouName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return name
            }
            return "You"
        case Self.remoteKey:
            return "Remote"
        case "":
            return "Unknown"
        default:
            return key
        }
    }

    func displayName(for segment: Segment) -> String {
        displayName(forKey: Self.effectiveKey(for: segment))
    }

    func displayName(speaker: String, override: String?) -> String {
        displayName(forKey: Self.effectiveKey(speaker: speaker, override: override))
    }

    /// Speaker keys to offer in the UI: "you" and "remote" first, then every
    /// other key used by a segment or named for the session, de-duplicated in
    /// first-seen order.
    func availableKeys(in segments: [Segment]) -> [String] {
        var ordered = [Self.youKey, Self.remoteKey]
        var seen = Set(ordered)
        for segment in segments {
            for key in [Self.canonicalKey(segment.speaker), Self.effectiveKey(for: segment)]
            where !key.isEmpty && seen.insert(key).inserted {
                ordered.append(key)
            }
        }
        for key in sessionNames.keys.sorted() where seen.insert(key).inserted {
            ordered.append(key)
        }
        return ordered
    }
}

// MARK: - Preferences

/// Settings for speaker naming.
enum SpeakerNamePreferences {

    /// UserDefaults key for the global "you" display name. Absent or empty
    /// means "use the account's full name" (macOS), else "You".
    static let defaultYouNameKey = "speakerDefaultYouName"

    /// The configured default name for `"you"`.
    static func defaultYouName(defaults: UserDefaults = .standard) -> String {
        let stored = (defaults.string(forKey: defaultYouNameKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }
        return systemFullName() ?? "You"
    }

    /// The macOS account's full name, if any. iOS has no meaningful
    /// equivalent, so it falls back to "You" there.
    static func systemFullName() -> String? {
        #if os(macOS)
        let name = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
        #else
        return nil
        #endif
    }

    /// A resolver for `sessionNames` using the current global defaults.
    static func resolver(sessionNames: [String: String] = [:],
                         defaults: UserDefaults = .standard) -> SpeakerNameResolver {
        SpeakerNameResolver(sessionNames: sessionNames, defaultYouName: defaultYouName(defaults: defaults))
    }
}
