import Foundation
import KeyboardShortcuts

/// User preferences for the meeting copilot (Settings → Meeting Copilot).
/// Readers take a `UserDefaults` so tests can use a private suite.
enum CopilotSettings {

    nonisolated static let liveSummaryEnabledKey = "copilotLiveSummaryEnabled"
    nonisolated static let liveSummaryIntervalKey = "copilotLiveSummaryIntervalMinutes"
    nonisolated static let highlightsInNoteKey = "copilotHighlightsInNote"
    nonisolated static let briefNotificationsKey = "copilotBriefNotifications"
    nonisolated static let briefLeadMinutesKey = "copilotBriefLeadMinutes"
    nonisolated static let panelExpandedKey = "copilotPanelExpanded"

    nonisolated static let defaultIntervalMinutes = 2
    nonisolated static let intervalRange = 1...10
    nonisolated static let defaultBriefLeadMinutes = 5
    nonisolated static let briefLeadRange = 1...30

    /// Rolling live summary on (default on).
    nonisolated static func liveSummaryEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: liveSummaryEnabledKey) as? Bool ?? true
    }

    /// Refresh cadence in minutes, clamped to `intervalRange`.
    nonisolated static func intervalMinutes(_ defaults: UserDefaults) -> Int {
        let stored = defaults.object(forKey: liveSummaryIntervalKey) as? Int ?? defaultIntervalMinutes
        return min(max(stored, intervalRange.lowerBound), intervalRange.upperBound)
    }

    /// Write bookmarked moments into the meeting note when recording stops.
    nonisolated static func highlightsInNote(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: highlightsInNoteKey) as? Bool ?? true
    }

    /// Pre-meeting brief notification (default on; still needs Calendar).
    nonisolated static func briefNotificationsEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: briefNotificationsKey) as? Bool ?? true
    }

    /// Minutes before the meeting the brief arrives, clamped.
    nonisolated static func briefLeadMinutes(_ defaults: UserDefaults) -> Int {
        let stored = defaults.object(forKey: briefLeadMinutesKey) as? Int ?? defaultBriefLeadMinutes
        return min(max(stored, briefLeadRange.lowerBound), briefLeadRange.upperBound)
    }
}

// MARK: - Shortcut

extension KeyboardShortcuts.Name {
    /// Global shortcut that bookmarks the current moment of a recording.
    static let markMoment = Self(
        "markMoment",
        default: .init(.m, modifiers: [.control, .option])
    )
}
