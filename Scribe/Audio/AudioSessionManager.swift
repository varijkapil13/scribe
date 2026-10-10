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
    /// Core Audio process tap, with ScreenCaptureKit as the fallback.
    let systemCapture = SystemAudioRouter()

    // MARK: - Callbacks

    /// Called on the main actor, in capture order, for each microphone
    /// buffer (16 kHz mono Float32). Buffers are hopped off the audio render
    /// thread through an `AsyncStream`, so consumers may touch main-actor
    /// state directly.
    var onMicBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Called on the main actor, in capture order, for each system-audio
    /// buffer (16 kHz mono Float32). See ``onMicBuffer``.
    var onSystemBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Called on the main actor when the system-audio capture stream stops
    /// unexpectedly mid-session (typically a revoked Screen Recording grant).
    var onSystemError: ((Error) -> Void)?

    // MARK: - Internal State

    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    private var accumulatedDuration: TimeInterval = 0
    var shouldCaptureSystemAudio: Bool = true

    /// Writes the session's audio to disk when "Retain raw audio recordings"
    /// is on. Set by ``AppState`` before ``startRecording(micDeviceID:captureSystemAudio:)``;
    /// finished (files closed) and cleared by ``stopRecording()``, or by a
    /// failed start.
    var audioRecorder: SessionAudioRecorder?

    /// Lines the mic and system tracks up on one session clock (host time,
    /// pauses removed): measures each track's start offset, asks the recorder
    /// to pad gaps with silence, and maps transcript timestamps. Reset at
    /// every ``startRecording(micDeviceID:captureSystemAudio:)``; kept after
    /// stop so late transcription results can still be mapped.
    private let aligner = AudioStreamAligner()

    /// Feeds captured buffers from the capture threads to the main actor, in
    /// order. Open from start to stop (pauses just stop the flow).
    private var bufferContinuation: AsyncStream<CapturedAudioBuffer>.Continuation?
    private var deliveryTask: Task<Void, Never>?

    /// Tail of the chain that runs system-capture starts and stops strictly
    /// one after another. Without it, pause's fire-and-forget stop could
    /// still be running when resume's start found `isCapturing` true and
    /// returned early — after which the stop tore the stream down and remote
    /// audio silently died.
    private var systemCaptureOperation: Task<Void, Never>?
    /// Bumped whenever a start/stop is queued, so a caller can tell whether
    /// another operation was queued after its own.
    private var systemCaptureGeneration = 0

    /// True while ``stopRecording()`` is tearing down, so nothing restarts
    /// capture in the meantime.
    private var isTearingDown = false

    /// UserDefaults key of the "Echo cancellation" setting (registered
    /// default: on).
    static let echoCancellationKey = "echoCancellation"

    /// Whether the mic should run Apple's voice processing (echo
    /// cancellation). It only matters while system audio is captured: then the
    /// remote side coming out of the speakers would otherwise be picked up by
    /// the mic and transcribed twice (once as "you").
    nonisolated static func shouldUseVoiceProcessing(setting: Bool, captureSystemAudio: Bool) -> Bool {
        setting && captureSystemAudio
    }

    /// Closes and drops the session recorder, if any, saving each track's
    /// session-clock start offset next to the files. Idempotent.
    private func finishAudioRecorder() {
        audioRecorder?.finish(timing: aligner.timing)
        audioRecorder = nil
    }

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
        guard !isRecording, !isTearingDown else { return }

        let captureSystemAudio = captureSystemAudio ?? shouldCaptureSystemAudio
        shouldCaptureSystemAudio = captureSystemAudio

        // Fresh session clock, and an ordered hop to the main actor for the
        // buffers about to flow.
        aligner.reset()
        startBufferDelivery()

        // If starting fails part-way, close any audio files already opened
        // and the buffer hand-off.
        var didStart = false
        defer {
            if !didStart {
                endBufferDelivery()
                finishAudioRecorder()
            }
        }

        // Echo cancellation for the mic (applied on the next startCapture).
        let echoSetting = UserDefaults.standard.object(forKey: Self.echoCancellationKey) as? Bool ?? true
        micCapture.voiceProcessing = Self.shouldUseVoiceProcessing(
            setting: echoSetting,
            captureSystemAudio: captureSystemAudio
        )

        // Surface an unexpectedly-stopped system-audio stream (e.g. revoked
        // Screen Recording grant) instead of letting remote capture die
        // silently. `systemCapture` is a single long-lived instance, so wiring
        // this once per session start also covers mid-session toggle/resume.
        systemCapture.onStreamError = Self.makeStreamErrorForwarder(to: WeakAudioSessionManager(self))
        // A tap rebuild or a backend switch leaves a hole in the system
        // track; its next buffer measures it.
        systemCapture.onCaptureWillRestart = Self.makeCaptureRestartForwarder(aligner)

        // Configure microphone capture.
        if let deviceID = micDeviceID {
            micCapture.selectDevice(id: deviceID)
        }

        installMicForwarder()

        // Forward the raw per-buffer peak (render thread) into the lock-boxed
        // holder; the main-actor `levelTimer` drains + smooths it for the UI.
        micCapture.onLevel = Self.makeMicLevelForwarder(rawLevelBox)

        // Fresh session: forget the device captured last time so automatic
        // detection considers all in-use mics afresh (otherwise re-recording
        // with the same call mic would exclude it and fall back to default).
        micCapture.resetCaptureBaseline()

        // The session clock starts now; each track's first buffer measures
        // how long its capture took to come up.
        let runStart = Date()
        aligner.beginRun(atHostSeconds: Self.hostSecondsNow())

        do {
            try micCapture.startCapture()
        } catch {
            throw AudioSessionError.micCaptureFailure(underlying: error)
        }

        // Start following the active input mode live: in automatic mode track
        // whichever mic a call app is using; in system-default mode track the OS
        // default. Started after capture so our own device is the baseline that
        // active-mic detection excludes.
        startObservingMicForCurrentMode()

        // Configure system audio capture.
        if captureSystemAudio {
            let hasPermission = await systemCapture.checkPermission()
            guard hasPermission else {
                abortMicCapture()
                throw AudioSessionError.systemAudioPermissionDenied
            }

            installSystemForwarder()

            do {
                try await enqueueSystemCaptureStart().value
            } catch {
                abortMicCapture()
                throw AudioSessionError.systemCaptureFailure(underlying: error)
            }
        }

        didStart = true

        currentSessionId = UUID().uuidString
        recordingStartTime = runStart
        accumulatedDuration = 0
        isRecording = true
        isPaused = false
        startDurationTimer()
        startLevelTimer()
    }

    /// Undoes the mic side of a failed start.
    private func abortMicCapture() {
        micCapture.stopObservingDefaultInputDevice()
        micCapture.stopObservingActiveInputDevice()
        micCapture.stopCapture()
    }

    /// Stops recording completely and tears down all capture resources.
    func stopRecording() async {
        guard isRecording, !isTearingDown else { return }
        isTearingDown = true
        defer { isTearingDown = false }

        micCapture.stopObservingDefaultInputDevice()
        micCapture.stopObservingActiveInputDevice()
        micCapture.stopCapture()
        // Waits for any start/stop still in flight (e.g. a pause's stop).
        await enqueueSystemCaptureStop().value
        if !isPaused {
            aligner.endRun(atHostSeconds: Self.hostSecondsNow())
        }
        // Both captures are stopped, so no more buffers arrive. Hand every
        // buffer still queued to the consumers before they are torn down
        // (AppState stops transcription right after this returns), then
        // flush and close the retained-audio files.
        await endBufferDelivery()?.value
        finishAudioRecorder()

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
        guard isRecording, !isPaused, !isTearingDown else { return }

        micCapture.stopCapture()
        // Pause should feel instant, so the async system-capture stop isn't
        // awaited here — but it is queued, so a quick resume's start waits
        // for it instead of racing it. (A no-op when system audio is off.)
        enqueueSystemCaptureStop()
        // Paused time isn't part of the session clock.
        aligner.endRun(atHostSeconds: Self.hostSecondsNow())

        // Accumulate elapsed time so far.
        if let start = recordingStartTime {
            accumulatedDuration += Date().timeIntervalSince(start)
        }
        stopDurationTimer()
        stopLevelTimer()
        isPaused = true
    }

    /// How the microphone input device is chosen.
    enum MicSelection: Equatable {
        /// Follow the mic a call/conferencing app is actively using — the one
        /// the user is really speaking into. Falls back to the system default
        /// when nothing else is in use.
        case automatic
        /// Follow the system default input device live.
        case systemDefault
        /// A specific pinned device.
        case device(AudioDeviceID)
    }

    /// Applies a microphone selection. If a session is in progress the mic tap
    /// is restarted for the new selection and the appropriate live-follow
    /// observer is (re)installed — so the user can change how the mic is chosen
    /// mid-call without losing the session.
    func setMicSelection(_ selection: MicSelection) {
        switch selection {
        case .automatic:
            micCapture.selectedDeviceID = nil
            micCapture.autoDetectActiveInput = true
        case .systemDefault:
            micCapture.selectedDeviceID = nil
            micCapture.autoDetectActiveInput = false
        case .device(let id):
            micCapture.selectDevice(id: id)
            micCapture.autoDetectActiveInput = false
        }

        guard isRecording, !isPaused else { return }
        // onAudioBuffer is a stored property on micCapture so the forwarding
        // callback survives the restart.
        restartMicCapture(reason: "selection changed")
        startObservingMicForCurrentMode()
    }

    /// Installs the live-follow observer that matches the current mic mode:
    /// nothing for a pinned device, the in-use-mic watcher for automatic, the
    /// default-device watcher for system-default. Tears down any previous
    /// observer first so it's safe to call on every selection/recording change.
    private func startObservingMicForCurrentMode() {
        micCapture.stopObservingDefaultInputDevice()
        micCapture.stopObservingActiveInputDevice()

        if micCapture.selectedDeviceID != nil {
            return // pinned — nothing to follow
        }

        if micCapture.autoDetectActiveInput {
            micCapture.onActiveInputDeviceChanged = { [weak self] in
                Task { @MainActor [weak self] in self?.followActiveInputDeviceChange() }
            }
            micCapture.startObservingActiveInputDevice()
        } else {
            micCapture.onDefaultInputDeviceChanged = { [weak self] in
                Task { @MainActor [weak self] in self?.followDefaultInputDeviceChange() }
            }
            micCapture.startObservingDefaultInputDevice()
        }
    }

    /// Reacts to the mic a call app is using changing (automatic mode), e.g. a
    /// Teams call starting on a different mic than the system default, or the
    /// call app switching mics mid-session. Switches capture to it live.
    private func followActiveInputDeviceChange() {
        guard isRecording, !isPaused,
              micCapture.selectedDeviceID == nil, micCapture.autoDetectActiveInput else { return }
        // Only switch when a *different* in-use mic is now available; staying
        // put when nothing new is in use avoids churn when a call ends.
        guard let target = micCapture.activeInputDeviceID(),
              target != micCapture.currentCaptureDeviceID else { return }
        restartMicCapture(reason: "active input device changed")
    }

    /// Reacts to a change of the system default input device while following the
    /// default (system-default mode). Restarts the mic tap so the newly-selected
    /// input takes effect live, mid-session.
    private func followDefaultInputDeviceChange() {
        guard isRecording, !isPaused,
              micCapture.selectedDeviceID == nil, !micCapture.autoDetectActiveInput else { return }
        restartMicCapture(reason: "system default input device changed")
    }

    /// Tears down and restarts the mic tap in place, preserving the forwarding
    /// callbacks (they're stored properties on `micCapture`).
    private func restartMicCapture(reason: String) {
        Log.audio.info("Restarting mic capture — \(reason, privacy: .public).")
        micCapture.stopCapture()
        // The restart leaves a short hole in the mic track; its next buffer
        // measures it so the recording is padded and stays aligned.
        aligner.trackWillStart(.mic)
        do {
            try micCapture.startCapture()
        } catch {
            Log.audio.error("Failed to restart mic capture: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Turns system-audio capture on or off mid-session without interrupting
    /// microphone capture. Called by ``AppState`` when the user flips the
    /// "Capture system audio" toggle in Settings or the live view.
    func setSystemAudioCaptureEnabled(_ enabled: Bool) async {
        shouldCaptureSystemAudio = enabled
        guard isRecording, !isPaused, !isTearingDown else { return }

        if enabled {
            installSystemForwarder()
            let start = enqueueSystemCaptureStart()
            let generation = systemCaptureGeneration
            do {
                try await start.value
            } catch {
                Log.audio.error("Failed to start system audio mid-session: \(error.localizedDescription, privacy: .private)")
                // Don't let the toggle silently lie: the switch flipped on
                // but capture never started. Surface it via onSystemError so
                // AppState raises the "not capturing remote audio" banner.
                onSystemError?(AudioSessionError.systemCaptureFailure(underlying: error))
            }
            // The session may have been paused/stopped, or the toggle flipped
            // back, while the stream was starting. If nothing queued its own
            // start/stop since, settle the stream to match.
            if generation == systemCaptureGeneration,
               !(isRecording && !isPaused && !isTearingDown && shouldCaptureSystemAudio) {
                enqueueSystemCaptureStop()
            }
        } else {
            await enqueueSystemCaptureStop().value
            // No more remote audio — let the meter decay to silence.
            smoothedSystem = 0
            systemLevel = 0
        }
    }

    /// Resumes a paused recording.
    func resumeRecording() async throws {
        guard isRecording, isPaused, !isTearingDown else { return }

        // The session clock runs again from now; both tracks' first buffers
        // measure their restart delay, which the recorder pads with silence.
        let runStart = Date()
        aligner.beginRun(atHostSeconds: Self.hostSecondsNow())

        do {
            try micCapture.startCapture()
        } catch {
            aligner.endRun(atHostSeconds: Self.hostSecondsNow())
            throw AudioSessionError.micCaptureFailure(underlying: error)
        }

        // System audio is best-effort on resume: if it can't restart (e.g. the
        // Screen Recording grant was revoked while paused), keep the mic running
        // and surface the problem via the banner rather than tearing the whole
        // session back down — otherwise the user is stuck unable to resume at
        // all. Mirrors the mic-only fallback elsewhere in the pipeline.
        if shouldCaptureSystemAudio {
            // Re-installed so a stream first enabled while paused feeds this
            // session's recorder and hand-off rather than stale ones.
            installSystemForwarder()
            do {
                // Queued behind pause's stop, so it can't be swallowed by it.
                try await enqueueSystemCaptureStart().value
            } catch {
                Log.audio.error("Failed to restart system audio on resume: \(error.localizedDescription, privacy: .private)")
                onSystemError?(AudioSessionError.systemCaptureFailure(underlying: error))
            }
            // Recording may have been stopped while the stream was starting;
            // stopRecording has already torn everything down (its queued stop
            // runs after this start), so don't restart the timers or flip
            // `isPaused` on a finished session.
            guard isRecording, !isTearingDown else { return }
        }

        recordingStartTime = runStart
        isPaused = false
        startDurationTimer()
        startLevelTimer()
    }

    // MARK: - Session clock

    /// Maps a transcription segment's timestamps from its track's own audio
    /// (what that pipeline was fed) onto the shared session clock, so mic and
    /// remote segments — and the retained audio files — line up even though
    /// system audio starts later than the mic and again late after a resume.
    func alignedToSessionClock(_ segment: TranscriptionSegment) -> TranscriptionSegment {
        let track: AudioSessionAlignment.Track = segment.speaker.lowercased() == "remote" ? .system : .mic
        let start = aligner.sessionMs(forTrackMs: segment.startMs, track: track)
        let end = max(start, aligner.sessionMs(forTrackMs: segment.endMs, track: track))
        return TranscriptionSegment(
            id: segment.id,
            sessionOffsetMs: aligner.sessionMs(forTrackMs: segment.sessionOffsetMs, track: track),
            startMs: start,
            endMs: end,
            speaker: segment.speaker,
            text: segment.text
        )
    }

    /// Current host-clock time in seconds (the clock capture timestamps use).
    nonisolated static func hostSecondsNow() -> Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    /// Host-clock seconds of a captured buffer's first sample: the capture
    /// timestamp when it carries a host time, otherwise "now minus the
    /// buffer's duration".
    nonisolated static func bufferStartHostSeconds(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) -> Double {
        if time.isHostTimeValid {
            return AVAudioTime.seconds(forHostTime: time.hostTime)
        }
        return hostSecondsNow() - Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)
    }

    /// `buffer`'s length in frames at the aligner's sample rate.
    nonisolated static func alignerFrames(of buffer: AVAudioPCMBuffer, alignerRate: Double) -> Int64 {
        let rate = buffer.format.sampleRate
        guard rate > 0 else { return Int64(buffer.frameLength) }
        return Int64((Double(buffer.frameLength) * alignerRate / rate).rounded())
    }

    // MARK: - Buffer hand-off

    /// Opens the capture → main-actor hand-off. Buffers are delivered to
    /// ``onMicBuffer`` / ``onSystemBuffer`` in the order they were captured.
    private func startBufferDelivery() {
        endBufferDelivery()
        let (stream, continuation) = AsyncStream<CapturedAudioBuffer>.makeStream()
        bufferContinuation = continuation
        deliveryTask = Task { [weak self] in
            for await captured in stream {
                guard let self else { return }
                self.deliver(captured)
            }
        }
    }

    /// Closes the hand-off. The returned task finishes once every buffer
    /// already queued has been delivered.
    @discardableResult
    private func endBufferDelivery() -> Task<Void, Never>? {
        bufferContinuation?.finish()
        bufferContinuation = nil
        let task = deliveryTask
        deliveryTask = nil
        return task
    }

    private func deliver(_ captured: CapturedAudioBuffer) {
        switch captured.source {
        case .mic: onMicBuffer?(captured.buffer)
        case .system: onSystemBuffer?(captured.buffer)
        }
    }

    /// Points the mic tap at this session's recorder, aligner and hand-off.
    /// The forwarder is a stored property on `micCapture`, so it survives
    /// mid-session restarts.
    private func installMicForwarder() {
        guard let continuation = bufferContinuation else { return }
        micCapture.onAudioBuffer = Self.makeTrackForwarder(
            track: .mic,
            recorder: audioRecorder,
            aligner: aligner,
            levelBox: nil,
            continuation: continuation
        )
    }

    /// Points system capture at this session's recorder, aligner, level
    /// meter and hand-off.
    private func installSystemForwarder() {
        guard let continuation = bufferContinuation else { return }
        systemCapture.onAudioBuffer = Self.makeTrackForwarder(
            track: .system,
            recorder: audioRecorder,
            aligner: aligner,
            levelBox: rawLevelBox,
            continuation: continuation
        )
    }

    /// Builds the per-buffer callback run on a capture thread (the mic's
    /// render thread or ScreenCaptureKit's sample queue). Built outside the
    /// main actor so the closure isn't main-actor isolated. It places the
    /// buffer on the session clock, writes it (plus any gap-filling silence)
    /// to the recorder — whose own queue does the disk work, keeping it off
    /// both this thread and the main actor — and yields it to the main actor.
    nonisolated private static func makeTrackForwarder(
        track: AudioSessionAlignment.Track,
        recorder: SessionAudioRecorder?,
        aligner: AudioStreamAligner,
        levelBox: RawLevelBox?,
        continuation: AsyncStream<CapturedAudioBuffer>.Continuation
    ) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        let isMic = track == .mic
        let source: CapturedAudioBuffer.Source = isMic ? .mic : .system
        return { buffer, time in
            guard buffer.frameLength > 0 else { return }
            levelBox?.recordSystem(AudioSessionManager.peak(of: buffer))
            let padding = aligner.place(
                track,
                frameCount: AudioSessionManager.alignerFrames(of: buffer, alignerRate: aligner.sampleRate),
                startHostSeconds: AudioSessionManager.bufferStartHostSeconds(buffer, time: time)
            )
            if let recorder {
                if padding > 0 {
                    recorder.appendSilence(frames: padding, toMic: isMic)
                }
                if isMic {
                    recorder.appendMic(buffer)
                } else {
                    recorder.appendSystem(buffer)
                }
            }
            continuation.yield(CapturedAudioBuffer(buffer: buffer, source: source))
        }
    }

    /// Mic level callback (render thread) → lock-boxed raw peak.
    nonisolated private static func makeMicLevelForwarder(_ levelBox: RawLevelBox) -> (Float) -> Void {
        { peak in levelBox.recordMic(peak) }
    }

    /// System-stream error callback (background queue) → ``onSystemError``
    /// on the main actor.
    nonisolated private static func makeStreamErrorForwarder(
        to target: WeakAudioSessionManager
    ) -> (Error) -> Void {
        { error in
            Task { @MainActor in target.manager?.onSystemError?(error) }
        }
    }

    /// System-capture restart callback (background queue) → aligner.
    nonisolated private static func makeCaptureRestartForwarder(_ aligner: AudioStreamAligner) -> () -> Void {
        { aligner.trackWillStart(.system) }
    }

    // MARK: - Serialized system capture

    /// Queues a system-capture start behind any start/stop still running.
    /// The returned task finishes when this start has finished (or thrown).
    private func enqueueSystemCaptureStart() -> Task<Void, Error> {
        let previous = systemCaptureOperation
        let capture = systemCapture
        let aligner = self.aligner
        let start = Task { @MainActor in
            await previous?.value
            // Lets the tap narrow to the meeting app when that's enabled.
            capture.meetingBundleID = MeetingDetector.shared.currentMeeting?.bundleID
            if !capture.isCapturing {
                // Its first buffer measures the start-up delay precisely.
                aligner.trackWillStart(.system)
            }
            try await capture.startCapture()
        }
        systemCaptureOperation = Task { @MainActor in _ = await start.result }
        systemCaptureGeneration += 1
        return start
    }

    /// Queues a system-capture stop behind any start/stop still running. The
    /// returned task finishes when the stream is stopped. A no-op stop when
    /// nothing is capturing.
    @discardableResult
    private func enqueueSystemCaptureStop() -> Task<Void, Never> {
        let previous = systemCaptureOperation
        let capture = systemCapture
        let stop = Task { @MainActor in
            await previous?.value
            await capture.stopCapture()
        }
        systemCaptureOperation = stop
        systemCaptureGeneration += 1
        return stop
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

// MARK: - Capture hand-off types

/// A captured buffer on its way from a capture thread to the main actor.
/// `@unchecked Sendable`: capture allocates a fresh buffer per callback that
/// is only ever read afterwards, so handing it across without copying is safe.
struct CapturedAudioBuffer: @unchecked Sendable {
    enum Source: Sendable {
        case mic
        case system
    }

    let buffer: AVAudioPCMBuffer
    let source: Source
}

/// Weak reference to the manager that can be captured by callbacks running
/// off the main actor (the manager itself is only touched on the main actor).
final class WeakAudioSessionManager: @unchecked Sendable {
    weak var manager: AudioSessionManager?

    init(_ manager: AudioSessionManager) {
        self.manager = manager
    }
}
