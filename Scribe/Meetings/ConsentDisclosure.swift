import AppKit
import Foundation
import UserNotifications

/// A short "I'm transcribing this meeting" message the user can paste into a
/// call's chat, so the other participants know. Scribe never sends it
/// anywhere itself: it goes on the clipboard (from the menu bar, the live
/// session view, or automatically when a recording starts) and the user
/// decides where to paste it.
enum ConsentDisclosure {

    // MARK: - Settings

    static let textKey = "consentDisclosureText"
    static let copyOnStartKey = "consentDisclosureCopyOnStart"

    static let defaultText = "Heads up: I'm using Scribe to transcribe this meeting on my Mac for my notes. Nothing leaves my device."

    private static let copiedRequestId = "scribe.consent.copied"

    /// The message to share: the user's text, or the default when they've
    /// never set one or cleared it.
    static func text(from defaults: UserDefaults = .standard) -> String {
        resolvedText(defaults.string(forKey: textKey))
    }

    /// Pure fallback rule behind ``text(from:)``.
    static func resolvedText(_ stored: String?) -> String {
        let trimmed = (stored ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultText : trimmed
    }

    static func copiesOnStart(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: copyOnStartKey)
    }

    // MARK: - Actions

    /// Puts the disclosure on the general pasteboard.
    @MainActor
    @discardableResult
    static func copyToPasteboard(defaults: UserDefaults = .standard) -> String {
        let message = text(from: defaults)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message, forType: .string)
        return message
    }

    /// Called once a recording has actually started. When the user opted in,
    /// copies the disclosure and posts a notification saying so, so they know
    /// it's ready to paste into the meeting chat.
    @MainActor
    static func recordingDidStart() {
        guard copiesOnStart() else { return }
        copyToPasteboard()
        Task { @MainActor in
            guard await TaskReminderScheduler.shared.ensureAuthorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = "Disclosure message copied"
            content.body = "Paste it into the meeting chat to let everyone know you're transcribing."
            let request = UNNotificationRequest(identifier: copiedRequestId, content: content, trigger: nil)
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                Log.app.error("Failed to post disclosure notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
