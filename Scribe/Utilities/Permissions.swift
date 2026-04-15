import AVFoundation
import ScreenCaptureKit
import AppKit

// MARK: - PermissionStatus

/// Represents the authorization state for a system permission.
enum PermissionStatus {
    case granted
    case denied
    case notDetermined
}

// MARK: - Permissions

/// Utilities for checking and requesting macOS system permissions required by Scribe.
struct Permissions {

    // MARK: - Microphone

    /// Checks the current microphone permission status.
    ///
    /// If the user has not yet been prompted, this method requests permission and
    /// returns the resulting status.
    ///
    /// - Returns: The current ``PermissionStatus`` for microphone access.
    static func checkMicrophonePermission() async -> PermissionStatus {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            return granted ? .granted : .denied
        @unknown default:
            return .notDetermined
        }
    }

    /// Requests microphone permission and returns whether it was granted.
    ///
    /// - Returns: `true` if permission is (or was already) granted.
    static func requestMicrophonePermission() async -> Bool {
        let status = await checkMicrophonePermission()
        return status == .granted
    }

    // MARK: - Screen Capture

    /// Checks whether the app has permission to capture screen content.
    ///
    /// ScreenCaptureKit does not offer a dedicated authorization-status API.
    /// Instead, we attempt to retrieve the shareable content and treat any thrown
    /// error as a denial.
    ///
    /// - Returns: `true` if screen capture permission is available.
    static func checkScreenCapturePermission() async -> Bool {
        do {
            _ = try await SCShareableContent.current
            return true
        } catch {
            return false
        }
    }

    // MARK: - System Preferences

    /// Opens System Settings to the specified preference pane.
    ///
    /// Common panel identifiers:
    /// - `"Privacy_Microphone"` - Microphone access
    /// - `"Privacy_ScreenCapture"` - Screen recording access
    ///
    /// - Parameter panel: The preference pane identifier to open.
    static func openSystemPreferences(for panel: String) {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?\(panel)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
