import AppIntents
import Foundation

/// Starts recording a meeting — the same path as the menu bar's
/// "Start Recording" (permission checks, note binding, calendar matching).
struct StartRecordingIntent: AppIntent {

    static var title: LocalizedStringResource { "Start Recording" }

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let started = try await ScribeIntentsBridge.startRecording()
        let dialog: IntentDialog = started ? "Scribe is recording." : "Scribe is already recording."
        return .result(dialog: dialog)
    }
}

/// Stops the running recording.
struct StopRecordingIntent: AppIntent {

    static var title: LocalizedStringResource { "Stop Recording" }

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let stopped = try await ScribeIntentsBridge.stopRecording()
        let dialog: IntentDialog = stopped ? "Recording stopped." : "Scribe isn't recording."
        return .result(dialog: dialog)
    }
}

/// Starts or stops dictation into the focused app.
struct ToggleDictationIntent: AppIntent {

    static var title: LocalizedStringResource { "Toggle Dictation" }

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let active = await ScribeIntentsBridge.toggleDictation()
        let dialog: IntentDialog = active ? "Dictation started." : "Dictation stopped."
        return .result(dialog: dialog)
    }
}
