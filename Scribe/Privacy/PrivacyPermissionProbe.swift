import AppKit
import AVFoundation
import CoreGraphics
import EventKit
import Speech
import UserNotifications

/// Reads (and, where the system allows, requests) the live authorization
/// state for each `PrivacyPermissionKind`. Each framework call sits in its own
/// small function so an SDK change is a one-line fix.
enum PrivacyPermissionProbe {

    // MARK: - Status

    /// Current state without prompting.
    @MainActor
    static func state(of kind: PrivacyPermissionKind) async -> PrivacyPermissionState {
        switch kind {
        case .microphone:
            return map(AVCaptureDevice.authorizationStatus(for: .audio))
        case .screenAndSystemAudio:
            // CoreGraphics can only say yes/no; "no" covers never-asked too.
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .speechRecognition:
            return map(SFSpeechRecognizer.authorizationStatus())
        case .calendars:
            return map(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return map(EKEventStore.authorizationStatus(for: .reminder))
        case .notifications:
            return await notificationState()
        case .accessibility:
            return TextInserter.hasAccessibilityPermission ? .granted : .denied
        }
    }

    /// States for several kinds at once.
    @MainActor
    static func states(of kinds: [PrivacyPermissionKind]) async -> [PrivacyPermissionKind: PrivacyPermissionState] {
        var result: [PrivacyPermissionKind: PrivacyPermissionState] = [:]
        for kind in kinds {
            result[kind] = await state(of: kind)
        }
        return result
    }

    // MARK: - Request

    /// Shows the system prompt when it can still be shown; otherwise opens
    /// System Settings at the right page. Calendars and Reminders are
    /// requested from Settings → Calendar, so they only deep-link here.
    @MainActor
    static func request(_ kind: PrivacyPermissionKind) async {
        let current = await state(of: kind)
        switch kind {
        case .microphone where current.canPrompt:
            _ = await Permissions.requestMicrophonePermission()
        case .screenAndSystemAudio:
            // Prompts the first time; afterwards macOS ignores it, so also
            // send the user to the settings page.
            if !CGRequestScreenCaptureAccess() {
                openSettings(for: kind)
            }
        case .speechRecognition where current.canPrompt:
            _ = await SpeechRecognizerEngine.checkAuthorization()
        case .notifications where current.canPrompt:
            _ = await requestNotifications()
        case .accessibility where current != .granted:
            if !TextInserter.requestAccessibilityPermission() {
                openSettings(for: kind)
            }
        default:
            openSettings(for: kind)
        }
    }

    @MainActor
    static func openSettings(for kind: PrivacyPermissionKind) {
        guard let url = kind.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Framework mapping

    nonisolated static func map(_ status: AVAuthorizationStatus) -> PrivacyPermissionState {
        switch status {
        case .authorized:           return .granted
        case .denied, .restricted:  return .denied
        case .notDetermined:        return .notDetermined
        @unknown default:           return .unknown
        }
    }

    nonisolated static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> PrivacyPermissionState {
        switch status {
        case .authorized:           return .granted
        case .denied, .restricted:  return .denied
        case .notDetermined:        return .notDetermined
        @unknown default:           return .unknown
        }
    }

    nonisolated static func map(_ status: EKAuthorizationStatus) -> PrivacyPermissionState {
        switch status {
        case .fullAccess:           return .granted
        case .writeOnly:            return .limited
        case .denied, .restricted:  return .denied
        case .notDetermined:        return .notDetermined
        default:                    return .unknown // incl. the deprecated `.authorized`
        }
    }

    nonisolated static func map(_ status: UNAuthorizationStatus) -> PrivacyPermissionState {
        switch status {
        case .authorized:           return .granted
        case .provisional:          return .limited
        case .denied:               return .denied
        case .notDetermined:        return .notDetermined
        default:                    return .unknown
        }
    }

    /// Nonisolated so the non-Sendable settings object never crosses actors.
    nonisolated static func notificationState() async -> PrivacyPermissionState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return map(settings.authorizationStatus)
    }

    nonisolated static func requestNotifications() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
}
