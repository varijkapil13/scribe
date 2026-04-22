import AVFoundation
import Combine
import CoreAudio
import ScreenCaptureKit

// MARK: - Errors

enum AudioSessionError: LocalizedError {
    case micCaptureFailure(underlying: Error)
    case systemCaptureFailure(underlying: Error)
    case systemAudioPermissionDenied
    case notRecording

    var errorDescription: String? {
        switch self {
        case .micCaptureFailure(let error):
            return "Microphone capture failed: \(error.localizedDescription)"
        case .systemCaptureFailure(let error):
            return "System audio capture failed: \(error.localizedDescription)"
        case .systemAudioPermissionDenied:
            return "Permission to capture system audio was denied."
        case .notRecording:
            return "No recording is in progress."
        }
    }
}

// MARK: - AudioSessionManager

/// Coordinates microphone and system audio capture, feeding buffers to the transcription engine.
@MainActor
final class AudioSessionManager: ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var currentSessionId: String?

    // MARK: - Capture Engines

    let micCapture = MicrophoneCapture()
    let systemCapture = SystemAudioCapture()

    // MARK: - Callbacks

    /// Called when a microphone audio buffer is captured.
    var onMicBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Called when a system audio buffer is captured.
    var onSystemBuffer: ((AVAudioPCMBuffer) -> Void)?

    // MARK: - Internal State

    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    private var accumulatedDuration: TimeInterval = 0
    var shouldCaptureSystemAudio: Bool = true

    // MARK: - Recording Control

    /// Starts recording from the microphone and, optionally, system audio.
    ///
    /// - Parameters:
    ///   - micDeviceID: The CoreAudio device ID for the microphone. `nil` uses the system default.
    ///   - captureSystemAudio: Whether to capture system / desktop audio alongside the mic.
    ///     Pass `nil` to use the value of ``shouldCaptureSystemAudio`` (defaults to `true`),
    ///     allowing callers to toggle behavior via the property before starting.
    func startRecording(micDeviceID: AudioDeviceID? = nil, captureSystemAudio: Bool? = nil) async throws {
        guard !isRecording else { return }

        let captureSystemAudio = captureSystemAudio ?? shouldCaptureSystemAudio
        shouldCaptureSystemAudio = captureSystemAudio

        // Configure microphone capture.
        if let deviceID = micDeviceID {
            micCapture.selectDevice(id: deviceID)
        }

        micCapture.onAudioBuffer = { [weak self] buffer, _ in
            self?.onMicBuffer?(buffer)
        }

        do {
            try micCapture.startCapture()
        } catch {
            throw AudioSessionError.micCaptureFailure(underlying: error)
        }

        // Configure system audio capture.
        if captureSystemAudio {
            let hasPermission = await systemCapture.checkPermission()
            guard hasPermission else {
                micCapture.stopCapture()
                throw AudioSessionError.systemAudioPermissionDenied
            }

            systemCapture.onAudioBuffer = { [weak self] buffer, _ in
                self?.onSystemBuffer?(buffer)
            }

            do {
                try await systemCapture.startCapture()
            } catch {
                micCapture.stopCapture()
                throw AudioSessionError.systemCaptureFailure(underlying: error)
            }
        }

        currentSessionId = UUID().uuidString
        recordingStartTime = Date()
        accumulatedDuration = 0
        isRecording = true
        isPaused = false
        startDurationTimer()
    }

    /// Stops recording completely and tears down all capture resources.
    func stopRecording() async {
        guard isRecording else { return }

        micCapture.stopCapture()
        await systemCapture.stopCapture()

        stopDurationTimer()
        isRecording = false
        isPaused = false
        currentSessionId = nil
        recordingStartTime = nil
        accumulatedDuration = 0
        recordingDuration = 0
    }

    /// Pauses recording without ending the session. Capture taps are removed but the session stays alive.
    func pauseRecording() {
        guard isRecording, !isPaused else { return }

        micCapture.stopCapture()
        // System capture is stopped synchronously from the caller's perspective;
        // we fire-and-forget the async stop since pause should feel instant.
        if shouldCaptureSystemAudio {
            Task { await systemCapture.stopCapture() }
        }

        // Accumulate elapsed time so far.
        if let start = recordingStartTime {
            accumulatedDuration += Date().timeIntervalSince(start)
        }
        stopDurationTimer()
        isPaused = true
    }

    /// Resumes a paused recording.
    func resumeRecording() async throws {
        guard isRecording, isPaused else { return }

        do {
            try micCapture.startCapture()
        } catch {
            throw AudioSessionError.micCaptureFailure(underlying: error)
        }

        if shouldCaptureSystemAudio {
            do {
                try await systemCapture.startCapture()
            } catch {
                micCapture.stopCapture()
                throw AudioSessionError.systemCaptureFailure(underlying: error)
            }
        }

        recordingStartTime = Date()
        isPaused = false
        startDurationTimer()
    }

    // MARK: - Device Enumeration

    /// Returns the available microphone input devices.
    func availableMicrophones() -> [(id: AudioDeviceID, name: String)] {
        micCapture.availableInputDevices()
    }

    // MARK: - Duration Timer

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStartTime else { return }
                self.recordingDuration = self.accumulatedDuration + Date().timeIntervalSince(start)
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }
}
