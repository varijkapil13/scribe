import Foundation

/// A system permission Scribe can use, with the copy and System Settings deep
/// link shown on the Privacy dashboard and in onboarding. Pure (tested in
/// PrivacyDashboardTests); the live status lookup is `PrivacyPermissionProbe`.
enum PrivacyPermissionKind: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case screenAndSystemAudio
    case speechRecognition
    case calendars
    case reminders
    case notifications
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone:           return "Microphone"
        case .screenAndSystemAudio: return "Screen & System Audio Recording"
        case .speechRecognition:    return "Speech Recognition"
        case .calendars:            return "Calendars"
        case .reminders:            return "Reminders"
        case .notifications:        return "Notifications"
        case .accessibility:        return "Accessibility"
        }
    }

    /// Why Scribe asks, in one sentence.
    var purpose: String {
        switch self {
        case .microphone:
            return "Records your voice in meetings and for dictation."
        case .screenAndSystemAudio:
            return "Captures other participants' audio from your Mac's output. Scribe never records your screen."
        case .speechRecognition:
            return "Transcribes recordings and dictation on this Mac."
        case .calendars:
            return "Names meeting notes after events and reminds you before meetings."
        case .reminders:
            return "Adds meeting action items and tasks to Reminders when you choose to."
        case .notifications:
            return "Meeting-detected prompts, task reminders and recording alerts."
        case .accessibility:
            return "Pastes dictated text into other apps with ⌘V."
        }
    }

    var systemImage: String {
        switch self {
        case .microphone:           return "mic"
        case .screenAndSystemAudio: return "speaker.wave.2"
        case .speechRecognition:    return "waveform"
        case .calendars:            return "calendar"
        case .reminders:            return "checklist"
        case .notifications:        return "bell"
        case .accessibility:        return "accessibility"
        }
    }

    /// `x-apple.systempreferences:` URL that opens the matching System
    /// Settings page.
    var settingsURLString: String {
        let privacy = "x-apple.systempreferences:com.apple.preference.security?"
        switch self {
        case .microphone:           return privacy + "Privacy_Microphone"
        case .screenAndSystemAudio: return privacy + "Privacy_ScreenCapture"
        case .speechRecognition:    return privacy + "Privacy_SpeechRecognition"
        case .calendars:            return privacy + "Privacy_Calendars"
        case .reminders:            return privacy + "Privacy_Reminders"
        case .accessibility:        return privacy + "Privacy_Accessibility"
        case .notifications:        return "x-apple.systempreferences:com.apple.preference.notifications"
        }
    }

    var settingsURL: URL? { URL(string: settingsURLString) }

    /// Permissions the onboarding flow asks for up front. The rest are asked
    /// for when the feature that needs them is turned on.
    static let onboardingKinds: [PrivacyPermissionKind] = [
        .microphone, .screenAndSystemAudio, .speechRecognition, .notifications,
    ]
}

/// Authorization state, normalised across the frameworks' own enums.
enum PrivacyPermissionState: Equatable, Sendable {
    case granted
    /// Partly granted (calendar write-only, provisional notifications).
    case limited
    case denied
    case notDetermined
    case unknown

    var label: String {
        switch self {
        case .granted:       return "Allowed"
        case .limited:       return "Limited"
        case .denied:        return "Not allowed"
        case .notDetermined: return "Not asked yet"
        case .unknown:       return "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .granted:       return "checkmark.circle.fill"
        case .limited:       return "circle.lefthalf.filled"
        case .denied:        return "xmark.circle.fill"
        case .notDetermined: return "questionmark.circle"
        case .unknown:       return "questionmark.circle"
        }
    }

    /// Whether an in-app "Allow" button can still trigger the system prompt
    /// (otherwise the only path is System Settings).
    var canPrompt: Bool { self == .notDetermined }
}
