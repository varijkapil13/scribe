// Scribe/Storage/AudioRetentionPolicy.swift
import Foundation

/// How long retained session audio is kept before the launch-time sweep
/// deletes it. The transcript itself is never touched — only the audio folder.
///
/// Pure and platform-neutral (compiled into the iOS target via Storage/).
enum AudioRetentionPolicy: String, CaseIterable, Identifiable, Sendable {
    case forever
    case days7 = "7"
    case days30 = "30"
    case days90 = "90"

    /// UserDefaults key the Settings picker writes.
    static let defaultsKey = "audioRetentionPolicy"
    static let defaultValue: AudioRetentionPolicy = .forever

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forever: return "Keep forever"
        case .days7:   return "Delete after 7 days"
        case .days30:  return "Delete after 30 days"
        case .days90:  return "Delete after 90 days"
        }
    }

    /// Number of days audio is kept, or `nil` for ``forever``.
    var retentionDays: Int? {
        switch self {
        case .forever: return nil
        case .days7:   return 7
        case .days30:  return 30
        case .days90:  return 90
        }
    }

    /// Sessions created strictly before this date have expired audio.
    /// `nil` means nothing ever expires.
    func expirationCutoff(now: Date) -> Date? {
        guard let days = retentionDays else { return nil }
        return now.addingTimeInterval(-TimeInterval(days) * 86_400)
    }

    /// Whether audio for a session created at `createdAt` should be deleted.
    func isExpired(createdAt: Date, now: Date) -> Bool {
        guard let cutoff = expirationCutoff(now: now) else { return false }
        return createdAt < cutoff
    }

    /// The policy stored in `defaults`, falling back to ``defaultValue`` for
    /// missing or unrecognised values.
    static func current(in defaults: UserDefaults = .standard) -> AudioRetentionPolicy {
        guard let raw = defaults.string(forKey: defaultsKey),
              let policy = AudioRetentionPolicy(rawValue: raw) else {
            return defaultValue
        }
        return policy
    }
}
