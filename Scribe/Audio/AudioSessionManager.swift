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

    /// Smoothed microphone input level in 0…1, suitable for driving a level
    /// meter. Attack-fast / decay-slow so the meter snaps up on speech and
    /// eases back down, and is reset to 0 on pause/stop. Updated on the main
    /// actor at ~13 Hz from the raw per-buffer peak forwarded by
    /// ``MicrophoneCapture/onLevel`` — no engine restart involved.
    @Published private(set) var inputLevel: Float = 0

    /// Smoothed system-audio (remote) level in 0…1, mirroring ``inputLevel``
    /// for the second source. Stays at 0 when system-audio capture is off.
    @Published private(set) var systemLevel: Float = 0

    // MARK: - Capture Engines

    let micCapture = MicrophoneCapture()
    let systemCapture = SystemAudioCapture()

    // MARK: - Callbacks

    /// Called when a microphone audio buffer is captured.
    var onMicBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Called when a system audio buffer is captured.
    var onSystemBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Called on the main actor when the system-audio capture stream stops
    /// unexpectedly mid-session (typically a revoked Screen Recording grant).
    var onSystemError: ((Error) -> Void)?

    // MARK: - Internal State

    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    private var accumulatedDuration: TimeInterval = 0
    var shouldCaptureSystemAudio: Bool = true

    // MARK: - Level metering

    /// Latest raw peaks reported from the audio render thread(s). Written off
    /// the main actor (engine render thread / sample-feed thread) and drained
    /// on the main actor by ``levelTimer``, so it carries its own lock.
    private let rawLevelBox = RawLevelBox()
    /// Drives the attack/decay smoothing + publishing of `inputLevel` /
    /// `systemLevel` at ~13 Hz. Independent of the engine — pausing or
    /// stopping simply tears it down and zeroes the levels.
    private var levelTimer: Timer?
    private var smoothedInput: Float = 0
    private var smoothedSystem: Float = 0

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

        // Surface an unexpectedly-stopped system-audio stream (e.g. revoked
        // Screen Recording grant) instead of letting remote capture die
        // silently. `systemCapture` is a single long-lived instance, so wiring
        // this once per session start also covers mid-session toggle/resume.
        systemCapture.onStreamError = { [weak self] error in
            Task { @MainActor [weak self] in self?.onSystemError?(error) }
        }

        // Configure microphone capture.
        if let deviceID = micDeviceID {
            micCapture.selectDevice(id: deviceID)
        }

        micCapture.onAudioBuffer = { [weak self] buffer, _ in
            self?.onMicBuffer?(buffer)
        }

        // Forward the raw per-buffer peak (render thread) into the lock-boxed
        // holder; the main-actor `levelTimer` drains + smooths it for the UI.
        let levelBox = rawLevelBox
        micCapture.onLevel = { peak in levelBox.recordMic(peak) }

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

            systemCapture.onAudioBuffer = { [weak self, levelBox] buffer, _ in
                levelBox.recordSystem(Self.peak(of: buffer))
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
        startLevelTimer()
    }

    /// Stops recording completely and tears down all capture resources.
    func stopRecording() async {
        guard isRecording else { return }

        micCapture.stopCapture()
        await systemCapture.stopCapture()

        stopDurationTimer()
        stopLevelTimer()
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
        stopLevelTimer()
        isPaused = true
    }

    /// Hot-swaps the microphone input device. If a session is in progress the
    /// mic tap is stopped, reconfigured for the new device, and restarted —
    /// so the user can switch mics mid-call without losing the session.
    /// Passing `nil` returns to the system default.
    func setInputDevice(_ deviceID: AudioDeviceID?) {
        if let deviceID {
            micCapture.selectDevice(id: deviceID)
        } else {
            micCapture.selectedDeviceID = nil
        }

        guard isRecording, !isPaused else { return }

        // Mid-session swap: tear down the current tap and restart with the
        // new device. onAudioBuffer is a stored property on micCapture so the
        // forwarding callback survives the restart.
        micCapture.stopCapture()
        do {
            try micCapture.startCapture()
        } catch {
            Log.audio.error("Failed to switch mic device: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Turns system-audio capture on or off mid-session without interrupting
    /// microphone capture. Called by ``AppState`` when the user flips the
    /// "Capture system audio" toggle in Settings or the live view.
    func setSystemAudioCaptureEnabled(_ enabled: Bool) async {
        shouldCaptureSystemAudio = enabled
        guard isRecording, !isPaused else { return }

        if enabled {
            if !systemCapture.isCapturing {
                let levelBox = rawLevelBox
                systemCapture.onAudioBuffer = { [weak self] buffer, _ in
                    levelBox.recordSystem(Self.peak(of: buffer))
                    self?.onSystemBuffer?(buffer)
                }
                do {
                    try await systemCapture.startCapture()
                } catch {
                    Log.audio.error("Failed to start system audio mid-session: \(error.localizedDescription, privacy: .private)")
                    // Don't let the toggle silently lie: the switch flipped on
                    // but capture never started. Surface it via onSystemError so
                    // AppState raises the "not capturing remote audio" banner.
                    onSystemError?(AudioSessionError.systemCaptureFailure(underlying: error))
                }
            }
        } else {
            if systemCapture.isCapturing {
                await systemCapture.stopCapture()
            }
            // No more remote audio — let the meter decay to silence.
            smoothedSystem = 0
            systemLevel = 0
        }
    }

    /// Resumes a paused recording.
    func resumeRecording() async throws {
        guard isRecording, isPaused else { return }

        do {
            try micCapture.startCapture()
        } catch {
            throw AudioSessionError.micCaptureFailure(underlying: error)
        }

        // System audio is best-effort on resume: if it can't restart (e.g. the
        // Screen Recording grant was revoked while paused), keep the mic running
        // and surface the problem via the banner rather than tearing the whole
        // session back down — otherwise the user is stuck unable to resume at
        // all. Mirrors the mic-only fallback elsewhere in the pipeline.
        if shouldCaptureSystemAudio {
            do {
                try await systemCapture.startCapture()
            } catch {
                Log.audio.error("Failed to restart system audio on resume: \(error.localizedDescription, privacy: .private)")
                onSystemError?(AudioSessionError.systemCaptureFailure(underlying: error))
            }
        }

        recordingStartTime = Date()
        isPaused = false
        startDurationTimer()
        startLevelTimer()
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

    // MARK: - Level Timer

    /// Attack coefficient — how fast the meter rises toward a louder peak.
    /// Higher = snappier. Chosen so speech onset reads as instant.
    private static let levelAttack: Float = 0.6
    /// Decay coefficient — how fast the meter eases back down once audio
    /// quiets. Lower than attack so the meter "falls" rather than flickers.
    private static let levelDecay: Float = 0.18

    private func startLevelTimer() {
        guard levelTimer == nil else { return }
        // ~13 Hz: smooth to the eye without being a CPU hog. The render thread
        // keeps the latest peak fresh in `rawLevelBox`; we only sample it here.
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 13.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickLevels()
            }
        }
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        // Snap both meters to silence so a paused/stopped session never leaves
        // a stale level frozen on screen.
        smoothedInput = 0
        smoothedSystem = 0
        inputLevel = 0
        systemLevel = 0
        rawLevelBox.reset()
    }

    /// Drains the latest raw peaks and applies attack-fast / decay-slow
    /// smoothing before publishing. Runs on the main actor at the timer cadence.
    private func tickLevels() {
        let (mic, sys) = rawLevelBox.drainPeaks()
        smoothedInput = Self.smooth(current: smoothedInput, target: mic)
        smoothedSystem = Self.smooth(current: smoothedSystem, target: sys)
        // Avoid publishing imperceptible jitter (and redundant view updates).
        if abs(smoothedInput - inputLevel) > 0.001 { inputLevel = smoothedInput }
        if abs(smoothedSystem - systemLevel) > 0.001 { systemLevel = smoothedSystem }
    }

    private static func smooth(current: Float, target: Float) -> Float {
        let coeff = target > current ? levelAttack : levelDecay
        let next = current + (target - current) * coeff
        return min(max(next, 0), 1)
    }

    /// Linear peak amplitude (0…1) of a PCM buffer's first channel.
    nonisolated static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        var peak: Float = 0
        let n = Int(buffer.frameLength)
        if let ch = buffer.floatChannelData?[0] {
            for i in 0..<n { let v = abs(ch[i]); if v > peak { peak = v } }
        } else if let ch = buffer.int16ChannelData?[0] {
            for i in 0..<n {
                let v = abs(Float(ch[i]) / 32768.0)
                if v > peak { peak = v }
            }
        }
        return peak
    }
}

// MARK: - RawLevelBox

/// Thread-safe holder for the most recent raw audio peaks. The audio render
/// thread (mic) and the system-capture feed write peaks; the main-actor level
/// timer drains the running max each tick. Carries its own lock so it can be
/// captured by the render-thread callbacks without crossing the actor boundary.
private final class RawLevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var micPeak: Float = 0
    private var systemPeak: Float = 0

    /// Record a mic peak, keeping the loudest seen since the last drain so a
    /// transient between ticks isn't lost.
    func recordMic(_ peak: Float) {
        lock.lock()
        if peak > micPeak { micPeak = peak }
        lock.unlock()
    }

    func recordSystem(_ peak: Float) {
        lock.lock()
        if peak > systemPeak { systemPeak = peak }
        lock.unlock()
    }

    /// Returns the peaks since the last drain and resets the accumulators.
    func drainPeaks() -> (mic: Float, system: Float) {
        lock.lock()
        defer {
            micPeak = 0
            systemPeak = 0
            lock.unlock()
        }
        return (micPeak, systemPeak)
    }

    func reset() {
        lock.lock()
        micPeak = 0
        systemPeak = 0
        lock.unlock()
    }
}
