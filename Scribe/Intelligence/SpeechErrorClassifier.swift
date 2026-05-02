import Foundation

/// Classifies speech-recognition errors into categories that determine UX.
///
/// Most engine failures are best surfaced as a non-modal banner so the app
/// stays usable. A small number — chiefly the "Siri & Dictation are disabled"
/// state — require a guided modal because the user can't fix them without
/// jumping to System Settings.
enum SpeechErrorCategory: Equatable {
    /// Default: surface in the banner, stop recording, no modal.
    case generic
    /// On-device speech recognition needs Siri or Dictation toggled on.
    /// Show a guided modal with a "Open Dictation Settings" button.
    case siriOrDictationDisabled
}

enum SpeechErrorClassifier {
    /// Decides which category an error belongs to. Pure function — easy to
    /// unit-test, no UI side effects.
    static func category(for error: Error) -> SpeechErrorCategory {
        let message = error.localizedDescription.lowercased()
        if message.contains("siri") && message.contains("dictation") {
            return .siriOrDictationDisabled
        }
        return .generic
    }
}
