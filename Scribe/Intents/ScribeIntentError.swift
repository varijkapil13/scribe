import Foundation

// Portable (macOS + iOS): the intents compiled into both apps throw these.
// The platform bridges (ScribeIntentsBridge on macOS, ScribeiOS/System/
// IOSIntentsBridge.swift on iOS) throw them too.

/// Errors App Intents surface to Shortcuts / Siri.
enum ScribeIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noteNotFound
    case noteUnreadable
    case taskNotFound
    case meetingNotFound
    case noMeetings
    case noSummary
    case noTranscript
    case emptyTitle
    case appNotReady
    case recordingDidNotStart

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noteNotFound:         return "That note no longer exists."
        case .noteUnreadable:       return "Scribe couldn't read that note's file, so nothing was added."
        case .taskNotFound:         return "That task no longer exists."
        case .meetingNotFound:      return "That meeting no longer exists."
        case .noMeetings:           return "There are no recorded meetings yet."
        case .noSummary:            return "That meeting doesn't have a summary yet."
        case .noTranscript:         return "That meeting has no transcript."
        case .emptyTitle:           return "Please give it a title."
        case .appNotReady:          return "Scribe is still starting up. Try again in a moment."
        case .recordingDidNotStart: return "Scribe couldn't start recording."
        }
    }
}
