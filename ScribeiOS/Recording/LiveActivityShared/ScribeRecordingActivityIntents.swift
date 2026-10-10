// ScribeiOS/Recording/LiveActivityShared/ScribeRecordingActivityIntents.swift
//
// The Live Activity's Stop / Pause buttons. Compiled into BOTH the ScribeiOS
// app and the ScribeRecordingActivity widget extension: the extension needs
// the types for `Button(intent:)`, and because the app target contains them
// too, iOS runs `perform()` in the app's process — where the recorder lives
// (it keeps running in the background while recording audio). Where no
// recorder installed `ScribeRecordingActivityCommands.handler`, a command
// just ends the leftover activity.

@preconcurrency import ActivityKit
import AppIntents
import Foundation

/// A command from the Live Activity.
enum ScribeRecordingActivityCommand: String, Sendable {
    case stop
    case togglePause
}

/// Hands Live Activity commands to the recorder. The app installs `handler`
/// at launch (`MobileRecordingController`).
@MainActor
enum ScribeRecordingActivityCommands {

    static var handler: (@MainActor (ScribeRecordingActivityCommand) async -> Void)?

    /// Runs `command`. Without a recorder (the extension, or an app launched
    /// cold after being killed mid-recording) there is nothing to stop, so a
    /// leftover activity is simply ended.
    static func dispatch(_ command: ScribeRecordingActivityCommand) async {
        if let handler {
            await handler(command)
            return
        }
        // App only: ActivityKit's lifecycle calls aren't meant for the
        // extension (it defines SCRIBE_WIDGET_EXTENSION in project.yml).
        #if !SCRIBE_WIDGET_EXTENSION
        for activity in Activity<ScribeRecordingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        #endif
    }
}

/// Stops the recording from the Lock Screen / Dynamic Island.
struct ScribeStopRecordingActivityIntent: LiveActivityIntent {

    static var title: LocalizedStringResource { "Stop Recording" }
    static var description: IntentDescription { IntentDescription("Stops the Scribe recording and starts its summary.") }

    init() {}

    func perform() async throws -> some IntentResult {
        await ScribeRecordingActivityCommands.dispatch(.stop)
        return .result()
    }
}

/// Pauses / resumes the recording from the Lock Screen / Dynamic Island.
struct ScribeToggleRecordingPauseActivityIntent: LiveActivityIntent {

    static var title: LocalizedStringResource { "Pause or Resume Recording" }
    static var description: IntentDescription { IntentDescription("Pauses the Scribe recording, or resumes it when paused.") }

    init() {}

    func perform() async throws -> some IntentResult {
        await ScribeRecordingActivityCommands.dispatch(.togglePause)
        return .result()
    }
}
