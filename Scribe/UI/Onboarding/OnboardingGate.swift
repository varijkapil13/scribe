import Foundation

/// Decides whether the first-run onboarding sheet is shown.
///
/// Completion is stored as a version number so a materially new flow can be
/// shown once more by bumping ``currentVersion``. The original single Bool
/// (`hasCompletedOnboarding`) counts as version 1.
enum OnboardingGate {
    static let completedVersionKey = "onboarding.completedVersion"
    static let legacyCompletedKey = "hasCompletedOnboarding"
    /// v2: paged flow with live permission status, meeting detection and
    /// vault location.
    static let currentVersion = 2

    nonisolated static func shouldShow(
        completedVersion: Int,
        legacyCompleted: Bool,
        currentVersion: Int = OnboardingGate.currentVersion
    ) -> Bool {
        let effective = max(completedVersion, legacyCompleted ? 1 : 0)
        return effective < currentVersion
    }

    nonisolated static func shouldShow(defaults: UserDefaults = .standard) -> Bool {
        shouldShow(
            completedVersion: defaults.integer(forKey: completedVersionKey),
            legacyCompleted: defaults.bool(forKey: legacyCompletedKey)
        )
    }

    /// Records the current flow as seen (finished or skipped).
    nonisolated static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(currentVersion, forKey: completedVersionKey)
        defaults.set(true, forKey: legacyCompletedKey)
    }
}

/// The pages of the onboarding flow, in order.
enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome
    case permissions
    case meetings
    case vault
    case done

    var id: Int { rawValue }

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
    var isFirst: Bool { previous == nil }
    var isLast: Bool { next == nil }

    var symbol: String {
        switch self {
        case .welcome:     return "text.quote"
        case .permissions: return "lock.shield"
        case .meetings:    return "person.2.wave.2"
        case .vault:       return "folder"
        case .done:        return "checkmark.seal"
        }
    }

    var title: String {
        switch self {
        case .welcome:     return String(localized: "Welcome to Scribe")
        case .permissions: return String(localized: "A few permissions")
        case .meetings:    return String(localized: "Meetings, noticed")
        case .vault:       return String(localized: "Where your notes live")
        case .done:        return String(localized: "Ready when you are")
        }
    }

    var body: String {
        switch self {
        case .welcome:
            return "Record conversations, transcribe them on your Mac, and turn them into notes and tasks. Everything stays private — transcription and AI run on-device."
        case .permissions:
            return "macOS asks before Scribe can listen. Allow what you need now; you can change any of these later in Settings → Privacy."
        case .meetings:
            return "Scribe can notice when a call starts in Zoom, Teams, Meet and similar apps, and offer to record it."
        case .vault:
            return "Notes are plain Markdown files in a folder you can open with any editor or sync however you like."
        case .done:
            return "Your first recording downloads a small on-device speech model — about a minute, just once."
        }
    }
}
