// ScribeiOS/System/ScribeRecordingControl.swift
//
// The hook system entry points (Siri / Shortcuts recording intents, the
// Control Center "Start Recording" control, the widgets' recording state)
// use to reach the iOS recorder without depending on its type.
//
// RECORDING AREA: make the recorder conform and register it once it exists,
// e.g. in MobileRecordingController's init:
//
//     extension MobileRecordingController: ScribeRecordingControl { … }
//     ScribeRecordingControlRegistry.register(self)
//
// and call `ScribeRecordingControlRegistry.recordingStateDidChange()` when
// recording starts or stops so the widgets refresh. Until something is
// registered, "start recording" falls back to opening scribe://record/start
// (the shell routes it to the Record tab).

import Foundation

/// What the system integration needs from the recorder.
@MainActor
protocol ScribeRecordingControl: AnyObject {
    /// A recording is running (or starting).
    var isRecordingActive: Bool { get }
    /// When the running recording started; nil when idle.
    var activeRecordingStartedAt: Date? { get }
    /// Starts a recording. Throws when it couldn't start (permissions, …).
    func startRecordingFromSystem() async throws
    /// Stops the running recording.
    func stopRecordingFromSystem() async
}

@MainActor
enum ScribeRecordingControlRegistry {

    /// The registered recorder (held weakly; it owns itself).
    private(set) static weak var current: (any ScribeRecordingControl)?

    static func register(_ control: any ScribeRecordingControl) {
        current = control
        recordingStateDidChange()
    }

    /// Recording started / stopped: refresh the widget snapshot.
    static func recordingStateDidChange() {
        IOSSystemIntegration.shared.recordingStateDidChange()
    }

    /// The recorder, waiting up to `timeout` for it to register (an intent
    /// that just launched the app runs before the Record area is set up).
    static func awaitControl(timeout: Duration) async -> (any ScribeRecordingControl)? {
        if let control = current { return control }
        let step: Duration = .milliseconds(100)
        var waited: Duration = .zero
        while waited < timeout {
            try? await Task.sleep(for: step)
            waited += step
            if let control = current { return control }
        }
        return nil
    }
}
