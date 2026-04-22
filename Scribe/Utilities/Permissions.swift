import AVFoundation
import CoreGraphics
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

    /// Checks whether the app has screen-recording permission by asking
    /// CoreGraphics directly (the underlying TCC API). If the permission has
    /// not yet been requested, this triggers the system prompt.
    ///
    /// - Note: macOS does not hot-reload screen-recording permission into a
    ///   running process. When a user toggles it on in System Settings, the
    ///   app must be fully quit and relaunched before ScreenCaptureKit calls
    ///   will succeed.
    ///
    /// - Returns: `true` if the current process has screen-recording access
    ///   according to TCC.
    static func checkScreenCapturePermission() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        // Trigger the system prompt. The return value reflects only the
        // pre-prompt state; the user's response takes effect after relaunch.
        return CGRequestScreenCaptureAccess()
    }

    /// Returns `true` when the OS has granted screen-recording access to this
    /// process. Unlike ``checkScreenCapturePermission()`` this never prompts
    /// and never performs I/O — use it for UI that decides whether to show
    /// a "relaunch required" hint.
    static func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
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
