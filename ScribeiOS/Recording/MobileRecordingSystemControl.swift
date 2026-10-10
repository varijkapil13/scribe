// ScribeiOS/Recording/MobileRecordingSystemControl.swift
//
// Connects the iOS recorder to the system entry points (ios-system):
// Siri / Shortcuts "Start / Stop Recording", the Control Center control,
// the Next Meeting widget's Record button and the widgets' recording state
// all go through `ScribeRecordingControlRegistry`. MobileRecordingController
// registers itself in its init (created at launch by ScribeiOSBootstrap) and
// reports start / stop with `recordingStateDidChange()`.

import Foundation

/// Why a recording started from Siri / a control didn't start.
struct MobileRecordingStartFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension MobileRecordingController: ScribeRecordingControl {

    /// Starting, recording or paused (not while finishing a stopped one).
    var isRecordingActive: Bool {
        switch phase {
        case .preparing, .recording, .paused: return true
        case .idle, .finishing: return false
        }
    }

    var activeRecordingStartedAt: Date? {
        isRecordingActive ? recordingStartedAt : nil
    }

    /// Same as the Record button: a new meeting note, named after the
    /// calendar event in progress when allowed.
    func startRecordingFromSystem() async throws {
        await perform(.start)
        guard phase == .recording || phase == .paused else {
            throw MobileRecordingStartFailure(message: errorMessage ?? "The recording didn't start.")
        }
    }

    func stopRecordingFromSystem() async {
        await perform(.stop)
    }
}
