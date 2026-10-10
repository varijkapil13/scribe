import AppIntents
import Foundation

// Compiled into the macOS app AND the iOS app (project.yml → ScribeiOS).
// Both route through their platform's `ScribeIntentsBridge`; dictation is a
// Mac-only feature, so its intent is macOS-only.

/// Starts recording a meeting — the same path as the menu bar's
/// "Start Recording" (permission checks, note binding, calendar matching).
struct StartRecordingIntent: AppIntent {

    static var title: LocalizedStringResource { "Start Recording" }

    #if os(iOS)
    /// iOS only starts microphone capture from the foreground.
    static var openAppWhenRun: Bool { true }
    #endif

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

#if os(macOS)
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
#endif
