import Foundation
import Combine
import AVFoundation
import CoreAudio

enum AppStateError: Error, LocalizedError {
    case sessionRequiresNoteId
    /// A recording is already running or starting.
    case sessionAlreadyActive
    /// The speech pipelines didn't start. The cause was already reported
    /// through the speech engine's `onSessionError`.
    case speechStartFailed
    var errorDescription: String? {
        switch self {
        case .sessionRequiresNoteId:
            return "A note must exist before starting a recording."
        case .sessionAlreadyActive:
            return "A recording is already in progress."
        case .speechStartFailed:
            return "Speech recognition couldn't start."
        }
    }
}

/// Central application state that coordinates audio capture, transcription, and storage.
///
/// `AppState` wires together the audio pipeline, Apple Speech transcription engine,
/// and persistent storage so that higher-level UI code can simply call
/// `startSession` / `stopSession`.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Published Properties

    @Published var audioManager = AudioSessionManager()
    @Published var speechEngine = SpeechRecognizerEngine()
    @Published var transcriptStore: TranscriptStore
    @Published var overlaySegments: [TranscriptionSegment] = []
    @Published var currentSessionId: String?
    @Published var isTranscribing: Bool = false
    /// True while a recording is being started (permission checks, model
    /// download, audio start-up) but `isTranscribing` isn't set yet. Guards
    /// against two concurrent starts (see ``SessionStartGate``).
    @Published private(set) var isStartingSession: Bool = false
    /// The id of the session that most recently finished, set by `stopSession`
    /// before `currentSessionId` is cleared. Drives the post-stop navigation to
    /// the finished transcript (see `RecordingNavigationPolicy.stopDestination`).
    /// Cleared at the start of `startSession` so a new recording doesn't carry a
    /// stale destination.
    @Published var lastFinishedSessionId: String?
    /// Surfaces the most recent error from the recording / transcription / persistence
    /// pipelines so the UI can show a banner. `nil` means "nothing wrong right now".
    ///
    /// This is the `.banner` channel of the one-feedback-language convention
    /// (see `FeedbackPolicy`). Prefer `report(_:)` over assigning this directly.
    @Published var lastError: String?

    /// Speaker-diarization state for the current recording (nil when
    /// diarization is off or system audio isn't captured).
    var diarizationCapture: SpeakerDiarizationCapture?

    /// Surfaces a brief success confirmation (e.g. "Moved 12 files") so the UI
    /// can show a success toast. `nil` means "nothing to confirm right now".
    ///
    /// This is the `.toast` channel of the one-feedback-language convention
    /// (see `FeedbackPolicy`). Set via `notify(_:)`.
    @Published var lastNotice: String?

    /// The current sidebar selection in `MainWindowView`. Updated by the view
    /// on every selection change. `AppDelegate.startRecording` reads it when
    /// deciding which Note a new global recording should bind to.
    @Published var currentSelection: MainSelection?

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    private var audioBufferManager = AudioBufferManager()

    /// One-shot flags so we don't spam the console with per-buffer logs but
    /// still confirm in the Xcode console that audio is flowing.
    private var hasLoggedFirstMicBuffer = false
    private var hasLoggedFirstSystemBuffer = false

    /// Fires shortly after a session starts; if system-audio capture was
    /// requested but no buffer ever arrived, the Screen Recording grant is the
    /// likely culprit and we warn the user instead of failing silently.
    private var systemAudioWatchdog: Task<Void, Never>?

    /// Grace period before the watchdog concludes remote audio is dead.
    /// ScreenCaptureKit delivers buffers continuously (even during silence), so
    /// a complete absence past this window means capture isn't running.
    private static let systemAudioWatchdogDelay: Duration = .seconds(6)

    /// Accumulates consecutive same-speaker utterances into a single segment
    /// so the UI doesn't fill up with 1–3-word fragments every time SFSpeech
    /// detects an internal utterance boundary. Flushed when the speaker
    /// changes, the time window elapses, or the session ends.
    private struct PendingSegment {
        let speaker: String
        let startMs: Int
        var endMs: Int
        var text: String
        let startedAt: Date
    }
    private var pendingSegment: PendingSegment?

    /// Upper bound for a single coalesced segment, in seconds. Once exceeded,
    /// the segment is flushed and a new one begins even if the speaker hasn't
    /// changed — prevents 20-minute monologues from becoming one giant row.
    private let coalesceWindow: TimeInterval = 60

    /// "A start is in flight" bookkeeping; mirrored into `isStartingSession`.
    private var startGate = SessionStartGate()

    /// True while `startSession` itself is running, so a second call can't
    /// interleave with it even when the caller already holds `startGate`.
    private var startSessionInFlight = false

    /// Keeps the Mac awake from recording start until post-processing ends.
    private var recordingActivity: SystemActivityAssertion?

    /// Upper bound on how long post-processing may keep the Mac awake.
    private static let postProcessingAwakeLimit: Duration = .seconds(30 * 60)

    // MARK: - Singleton

    static let shared = AppState()

    // MARK: - Initialization

    /// - Parameter transcriptStore: Inject a custom store for tests. Defaults to
    ///   the shared on-disk store backing the running app.
    init(transcriptStore: TranscriptStore = TranscriptStore()) {
        self.transcriptStore = transcriptStore
        // Under `--uitesting`, skip everything that touches audio hardware,
        // CoreAudio device enumeration, or ScreenCaptureKit so XCUITest can
        // launch the app without booting the capture stack (which crashes a
        // headless test host). Production behavior is unchanged when the flag
        // is absent.
        guard !AppLaunchEnvironment.isUITesting else { return }
        wireAudioPipeline()
        wireTranscriptionResults()
        observeLanguagePreference()
        observeSystemAudioPreference()
        observeMicrophonePreference()
    }

    // MARK: - Microphone Preference

    /// Applies the stored microphone selection (by CoreAudio device ID) and
    /// reacts to live changes so switching mics in Settings or the live view
    /// takes effect immediately — even during a session.
    private func observeMicrophonePreference() {
        applyStoredMicrophoneDevice()

        // `didChangeNotification` fires for every defaults write, so compare
        // against the value just applied: only a real change of this key
        // restarts the mic (an unrelated setting must not).
        let initial = UserDefaults.standard.string(forKey: "selectedMicrophoneID") ?? ""
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in UserDefaults.standard.string(forKey: "selectedMicrophoneID") ?? "" }
            .changes(from: initial)
            .sink { [weak self] stored in
                guard let self else { return }
                let selection = Self.micSelection(from: stored)
                Log.audio.info("Microphone preference changed → \(Self.label(for: selection), privacy: .public).")
                self.audioManager.setMicSelection(selection)
            }
            .store(in: &cancellables)
    }

    private func applyStoredMicrophoneDevice() {
        // Absent preference defaults to the system default input — the device
        // the OS (and the user) selected, which reliably carries their voice.
        // Automatic ("follow the mic a call app is using") is opt-in: it keys
        // off "device running somewhere", which virtual/loopback inputs like
        // "Microsoft Teams Audio" trip, silently capturing a dead device.
        let stored = UserDefaults.standard.string(forKey: "selectedMicrophoneID") ?? ""
        audioManager.setMicSelection(Self.micSelection(from: stored))
    }

    /// Maps the string-encoded `selectedMicrophoneID` UserDefault to a mic
    /// selection: `"auto"` → automatic (mic in use by a call app), `""` →
    /// system default, a numeric ID → that pinned device. Anything unparseable
    /// falls back to the system default.
    private static func micSelection(from stored: String) -> AudioSessionManager.MicSelection {
        switch stored {
        case "auto": return .automatic
        case "": return .systemDefault
        default:
            if let id = AudioDeviceID(stored) { return .device(id) }
            return .systemDefault
        }
    }

    private static func label(for selection: AudioSessionManager.MicSelection) -> String {
        switch selection {
        case .automatic: return "Automatic (mic in use)"
        case .systemDefault: return "System Default"
        case .device(let id): return "device \(id)"
        }
    }

    // MARK: - System Audio Preference

    /// Starts/stops the ScreenCaptureKit stream live when the user flips the
    /// "Capture system audio" toggle (in Settings or the live view), without
    /// interrupting microphone capture.
    private func observeSystemAudioPreference() {
        // Only real changes of this key: an unrelated settings write must not
        // re-enable system audio for a session started mic-only.
        let initial = UserDefaults.standard.object(forKey: "captureSystemAudio") as? Bool
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in UserDefaults.standard.object(forKey: "captureSystemAudio") as? Bool }
            .changes(from: initial)
            .compactMap { $0 }
            .sink { [weak self] enabled in
                guard let self else { return }
                Task { @MainActor in
                    await self.audioManager.setSystemAudioCaptureEnabled(enabled)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Language Preference

    /// Applies the stored `selectedLanguage` preference immediately and keeps
    /// the speech engine in sync with any future changes. `setLanguage`
    /// hot-swaps the recognizer mid-session, so switching languages in
    /// Settings takes effect without stopping or restarting Scribe.
    private func observeLanguagePreference() {
        // Apply whatever is currently stored (covers app launch).
        applyStoredLanguage()

        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .compactMap { _ in UserDefaults.standard.string(forKey: "selectedLanguage") }
            .removeDuplicates()
            .sink { [weak self] newLanguage in
                guard let self else { return }
                if self.speechEngine.language != newLanguage {
                    Log.app.info("Language preference changed → \(newLanguage, privacy: .public). Re-tuning recogniser.")
                    Task { @MainActor in
                        await self.speechEngine.setLanguage(newLanguage)
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func applyStoredLanguage() {
        let stored = UserDefaults.standard.string(forKey: "selectedLanguage")
        Task { @MainActor in
            await speechEngine.setLanguage(stored)
        }
    }

    // MARK: - Pipeline Wiring

    /// Connects microphone and system-audio buffers to Apple Speech.
    ///
    /// Both streams are fed into a single `SFSpeechRecognizer` (Apple's API
    /// doesn't support two simultaneous on-device recognition tasks reliably).
    /// The engine only updates the "current speaker" label when a buffer has
    /// actual audio content — silent buffers from the idle stream don't
    /// clobber the label on the active stream, so mic utterances get tagged
    /// "you" and remote utterances get tagged "remote" most of the time.
    ///
    /// `AudioSessionManager` hops every buffer from the capture threads to the
    /// main actor (in capture order) before calling these, so they may touch
    /// main-actor state and the transcription pipelines directly; the retained
    /// audio files are written off the main actor before the hop.
    private func wireAudioPipeline() {
        audioManager.onMicBuffer = { [weak self] buffer in
            guard let self else { return }
            if !self.hasLoggedFirstMicBuffer {
                self.hasLoggedFirstMicBuffer = true
                Log.audio.debug("First mic buffer received — frames: \(buffer.frameLength), format: \(String(describing: buffer.format), privacy: .public)")
            }
            self.speechEngine.appendAudioBuffer(buffer, speaker: "you")
        }

        audioManager.onSystemBuffer = { [weak self] buffer in
            guard let self else { return }
            if !self.hasLoggedFirstSystemBuffer {
                self.hasLoggedFirstSystemBuffer = true
                Log.audio.debug("First system audio buffer received — frames: \(buffer.frameLength), format: \(String(describing: buffer.format), privacy: .public)")
            }
            self.speechEngine.appendAudioBuffer(buffer, speaker: "remote")
        }

        audioManager.onSystemError = { [weak self] _ in
            guard let self else { return }
            self.report(Self.systemAudioRevokedMessage)
        }
    }

    /// Shown when remote (system-audio) capture isn't producing audio — almost
    /// always a Screen Recording permission that macOS silently dropped after a
    /// rebuild. Mic capture is a separate grant and keeps working, which is why
    /// only the remote side goes quiet.
    static let systemAudioRevokedMessage =
        "Not capturing remote audio. Grant Scribe access under System Settings → "
        + "Privacy & Security → Screen & System Audio Recording, then stop and restart recording."

    /// Connects transcription engine output to coalescing + storage + live view.
    ///
    /// Raw segments from SFSpeech are small (often 1–5 words) because the
    /// recogniser resets its partial at every silence boundary. We group
    /// consecutive same-speaker chunks into a single "coalesced" segment that
    /// represents up to ``coalesceWindow`` seconds of continuous speech from
    /// one person, so the UI shows meaningful paragraphs instead of a wall of
    /// tiny fragments.
    private func wireTranscriptionResults() {
        speechEngine.onSegmentTranscribed = { [weak self] segment in
            guard let self else { return }
            // Each pipeline times segments by the audio it was fed; system
            // audio starts later than the mic (and late again on resume), so
            // put both on the shared session clock the audio files use.
            self.ingestTranscribedSegment(self.audioManager.alignedToSessionClock(segment))
        }
        speechEngine.onSessionError = { [weak self] error in
            self?.report(error)
        }
    }

    /// Adds a raw SFSpeech segment to the current coalesce buffer, flushing it
    /// first if the speaker changed or the time window has elapsed.
    /// Internal (not private) so tests can drive the coalescing logic directly.
    func ingestTranscribedSegment(_ segment: TranscriptionSegment) {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if SpeakerNameResolver.canonicalKey(segment.speaker) == SpeakerNameResolver.remoteKey {
            diarizationCapture?.record(segment, text: text)
        }

        let elapsedSessionMs = segment.sessionOffsetMs
        let segmentLengthMs = max(0, segment.endMs - segment.startMs)

        if var pending = pendingSegment {
            let elapsed = -pending.startedAt.timeIntervalSinceNow
            let sameSpeaker = pending.speaker == segment.speaker
            if sameSpeaker && elapsed < coalesceWindow {
                pending.text = pending.text.isEmpty ? text : "\(pending.text) \(text)"
                pending.endMs = elapsedSessionMs + segmentLengthMs
                pendingSegment = pending
                refreshOverlayWithPending()
                return
            }
            // Speaker changed or window exceeded — flush before starting fresh.
            flushPendingSegment()
        }

        pendingSegment = PendingSegment(
            speaker: segment.speaker,
            startMs: elapsedSessionMs,
            endMs: elapsedSessionMs + segmentLengthMs,
            text: text,
            startedAt: Date()
        )
        refreshOverlayWithPending()
    }

    /// Persists the current coalesced segment (if any) and drops it from the
    /// live view's pending slot. Called on speaker change, window expiry, and
    /// session end. Internal so tests can drive flush behavior.
    func flushPendingSegment() {
        guard let pending = pendingSegment else { return }
        pendingSegment = nil

        guard let sessionId = currentSessionId else { return }
        do {
            try transcriptStore.addSegment(
                sessionId: sessionId,
                startMs: pending.startMs,
                endMs: pending.endMs,
                speaker: pending.speaker,
                text: pending.text
            )
        } catch {
            // Surface the failure (e.g. disk full) instead of silently dropping
            // the segment. Recoverable/background → banner channel.
            report("Failed to save segment: \(error.localizedDescription)")
        }
    }

    /// Rebuilds ``overlaySegments`` to contain the persisted segments for this
    /// session plus the in-progress pending segment so the live view shows a
    /// single growing row for the current utterance instead of 10 fragments.
    private func refreshOverlayWithPending() {
        guard let pending = pendingSegment else { return }
        // Replace or append a synthetic segment representing the in-progress
        // coalesced utterance. We mark it via a stable identifier so the view
        // doesn't recreate the row every tick.
        let liveId = pendingSegmentId
        let liveSegment = TranscriptionSegment(
            id: liveId,
            sessionOffsetMs: pending.startMs,
            startMs: pending.startMs,
            endMs: pending.endMs,
            speaker: pending.speaker,
            text: pending.text
        )

        if let idx = overlaySegments.firstIndex(where: { $0.id == liveId }) {
            overlaySegments[idx] = liveSegment
        } else {
            overlaySegments.append(liveSegment)
            if overlaySegments.count > 20 {
                overlaySegments.removeFirst(overlaySegments.count - 20)
            }
        }
    }

    /// Stable identifier for the in-progress live row — re-using the same
    /// UUID keeps SwiftUI's diff happy so the row animates rather than flickers.
    private let pendingSegmentId = UUID()

    // MARK: - Feedback

    /// Reports a recoverable / transient / background failure through the unified
    /// banner channel. This is the one entry point callers should use instead of
    /// hand-rolling their own banner / alert / inline string — it keeps every
    /// surface speaking the same feedback language (see `FeedbackPolicy`).
    ///
    /// Asserts at the routing layer that the convention's `.recoverableFailure`
    /// really does map to the banner, so a future policy change can't silently
    /// reroute these. Genuine blocking failures (e.g. "couldn't open the
    /// database") should stay a `.alert` at their call site, not come through here.
    func report(_ message: String) {
        assert(FeedbackPolicy.channel(for: .recoverableFailure) == .banner)
        lastError = message
    }

    /// Reports a recoverable failure described by an `Error`, using its
    /// localized description. Convenience over `report(String)` for `catch` sites.
    func report(_ error: Error) {
        report(error.localizedDescription)
    }

    /// Shows a brief success confirmation through the unified toast channel
    /// (e.g. "Moved 12 files"). Routed through the same banner host with a
    /// success style rather than a bespoke widget (see `FeedbackPolicy`).
    func notify(_ message: String) {
        assert(FeedbackPolicy.channel(for: .success) == .toast)
        lastNotice = message
    }

    // MARK: - Session Lifecycle

    /// Claims the "starting a recording" gate. Call before the first await of
    /// a start (permission checks included) and pair with
    /// ``endStartingSession()``. Returns false when a recording is already
    /// running or starting — the caller must not start another.
    func beginStartingSession() -> Bool {
        let claimed = startGate.begin(isRunning: isTranscribing)
        isStartingSession = startGate.isStarting
        return claimed
    }

    /// Releases the gate claimed by ``beginStartingSession()``.
    func endStartingSession() {
        startGate.end()
        isStartingSession = false
    }

    /// Throws `CancellationError` when a stop arrived while starting.
    private func throwIfStartCancelled() throws {
        if startGate.stopRequested {
            Log.app.info("Recording start cancelled by a stop request.")
            throw CancellationError()
        }
    }

    /// Starts a new transcription session.
    ///
    /// Creates a database session, starts audio capture, and begins on-device
    /// speech recognition via Apple Speech. If any step fails (or a stop is
    /// requested while starting), everything done so far is rolled back: the
    /// session row is deleted, pipelines and capture are stopped and
    /// `currentSessionId` is cleared.
    ///
    /// - Parameter title: Display title for the session. Defaults to `"Untitled Session"`.
    /// - Throws: If audio capture or speech start-up fails,
    ///   `AppStateError.sessionAlreadyActive` when a recording is already
    ///   running/starting, or `CancellationError` when stopped while starting.
    func startSession(
        title: String = "Untitled Session",
        noteId: String? = nil
    ) async throws {
        // Every session belongs to a note. AppDelegate.startRecording resolves
        // (or auto-creates) a note before reaching this method; passing nil
        // here is a programmer error.
        guard let noteId else {
            throw AppStateError.sessionRequiresNoteId
        }
        guard !isTranscribing, !startSessionInFlight else { throw AppStateError.sessionAlreadyActive }
        // AppDelegate claims the gate before its permission prompts; direct
        // callers (tests) get it claimed here.
        let ownsGate = !startGate.isStarting
        if ownsGate {
            guard beginStartingSession() else { throw AppStateError.sessionAlreadyActive }
        }
        startSessionInFlight = true
        defer {
            startSessionInFlight = false
            if ownsGate { endStartingSession() }
        }
        try throwIfStartCancelled()

        // Retained audio: pick the session's folder up front so the row
        // records it from the start (see SessionAudioStorage).
        let sessionId = UUID().uuidString
        let audioDirectory = Self.audioDirectoryForNewSession(sessionId: sessionId)
        let session = try transcriptStore.createSession(
            title: title,
            noteId: noteId,
            id: sessionId,
            audioDirectory: audioDirectory?.path
        )
        currentSessionId = session.id
        // A fresh recording supersedes any prior post-stop destination.
        lastFinishedSessionId = nil

        // Reset live view buffer, coalesce buffer, and diagnostic flags.
        overlaySegments.removeAll()
        pendingSegment = nil
        hasLoggedFirstMicBuffer = false
        hasLoggedFirstSystemBuffer = false

        // Reset audio buffers.
        audioBufferManager.reset()

        // Keep the Mac awake for the whole recording (and its post-processing,
        // see stopSession). Ended on rollback too.
        recordingActivity?.end()
        recordingActivity = SystemActivityAssertion(reason: "Recording and transcribing a meeting")

        do {
            // The language preference is kept in sync continuously via
            // observeLanguagePreference() — no need to re-apply here.

            // Start the parallel speech pipelines FIRST so they're ready to
            // accept audio as soon as the engine starts producing it. This also
            // triggers on-demand model download if the locale's model isn't
            // installed yet — await handles that.
            let speechStarted = await speechEngine.startSession()
            try throwIfStartCancelled()
            guard speechStarted else { throw AppStateError.speechStartFailed }

            // Start audio capture (writing it to disk too when audio is retained;
            // the manager closes the files on stop or a failed start).
            // Diarization also needs the system-audio track; with retention off it
            // goes to a scratch folder that is deleted after diarization.
            if !audioManager.isRecording {
                diarizationCapture = SpeakerDiarizationCoordinator.makeCapture(
                    sessionId: sessionId,
                    retainedDirectory: audioDirectory,
                    capturesSystemAudio: audioManager.shouldCaptureSystemAudio
                )
                let recordingDirectory = audioDirectory ?? diarizationCapture?.audioDirectory
                audioManager.audioRecorder = recordingDirectory.map { SessionAudioRecorder(directory: $0) }
            }
            try await audioManager.startRecording()
            try throwIfStartCancelled()
        } catch {
            await rollBackFailedStart(sessionId: sessionId, error: error)
            throw error
        }

        isTranscribing = true
        startSystemAudioWatchdog()
        Log.app.info("Session started — id: \(session.id, privacy: .public), language: \(self.speechEngine.currentLanguage ?? "system default", privacy: .public)")
    }

    /// Undoes a partially started session: stops whatever was started,
    /// closes and discards its audio, and deletes the (empty) session row so
    /// no phantom "in progress" recording is left behind.
    private func rollBackFailedStart(sessionId: String, error: Error) async {
        Log.app.error("Session start failed, rolling back — id: \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .private)")
        systemAudioWatchdog?.cancel()
        systemAudioWatchdog = nil

        await audioManager.stopRecording()
        // A failed `startRecording` already closed the recorder; this covers a
        // recorder that was assigned but never handed to a running capture.
        audioManager.audioRecorder?.finish()
        audioManager.audioRecorder = nil
        await speechEngine.stopSession()

        if let capture = diarizationCapture, capture.sessionId == sessionId, capture.isScratch {
            try? FileManager.default.removeItem(at: capture.audioDirectory)
        }
        diarizationCapture = nil
        pendingSegment = nil
        overlaySegments.removeAll()

        do {
            // Also removes the session's retained-audio folder.
            try transcriptStore.deleteSession(id: sessionId)
        } catch {
            Log.app.error("Couldn't delete the failed session; ending it instead: \(error.localizedDescription, privacy: .private)")
            try? transcriptStore.endSession(id: sessionId)
        }
        if currentSessionId == sessionId {
            currentSessionId = nil
        }
        isTranscribing = false
        recordingActivity?.end()
        recordingActivity = nil
    }

    /// Starts a one-shot timer that flags missing remote audio. If system-audio
    /// capture was requested for this session but no buffer has arrived by the
    /// time it fires, capture isn't actually running — surface the likely fix.
    private func startSystemAudioWatchdog() {
        systemAudioWatchdog?.cancel()
        guard audioManager.shouldCaptureSystemAudio else { return }
        systemAudioWatchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.systemAudioWatchdogDelay)
            guard !Task.isCancelled, let self else { return }
            guard self.isTranscribing,
                  self.audioManager.shouldCaptureSystemAudio,
                  !self.hasLoggedFirstSystemBuffer else { return }
            Log.audio.error("No system-audio buffers after \(String(describing: Self.systemAudioWatchdogDelay), privacy: .public) — Screen Recording permission likely revoked (rebuild?).")
            self.report(Self.systemAudioRevokedMessage)
        }
    }

    /// Stops the current transcription session.
    ///
    /// Halts audio capture, stops speech recognition, and finalizes the session
    /// record in the database. Triggers auto-analysis and auto-summarization if
    /// enabled in settings. Called while a start is still in flight, it
    /// cancels that start instead (the start rolls itself back).
    func stopSession() async {
        if !isTranscribing, startGate.requestStop() {
            Log.app.info("Stop requested while the recording is still starting; cancelling the start.")
            // Supersede a speech start still in flight (its generation token
            // goes stale) so it doesn't bring pipelines up only to be torn
            // down again; the start then rolls itself back.
            await speechEngine.stopSession()
            return
        }
        systemAudioWatchdog?.cancel()
        systemAudioWatchdog = nil
        await audioManager.stopRecording()
        // Wait for SFSpeech to deliver its final result so the last utterance
        // becomes a persisted segment before we clear `currentSessionId` (the
        // onSegmentTranscribed callback keys off it).
        await speechEngine.stopSession()

        // Commit any in-progress coalesced segment BEFORE we clear
        // `currentSessionId` — otherwise flushPendingSegment can't write it.
        flushPendingSegment()

        // Store sessionId before clearing so post-session processing can use it.
        let finishedSessionId = currentSessionId

        // Post-processing work that should finish before the Mac may sleep.
        var postProcessing: [Task<Void, Never>] = []

        if let sessionId = finishedSessionId {
            try? transcriptStore.endSession(id: sessionId)
            let capture = diarizationCapture.flatMap { $0.sessionId == sessionId ? $0 : nil }
            diarizationCapture = nil
            postProcessing = runPostRecordingProcessing(sessionId: sessionId, diarization: capture)
        }

        // Post-meeting hooks (Settings → Hooks); runs in the background.
        MeetingHooks.sessionDidStop(sessionId: finishedSessionId, appState: self)

        // Let the Mac sleep again once post-processing is done (bounded, so a
        // stuck summary can't keep it awake forever).
        if let activity = recordingActivity {
            recordingActivity = nil
            Self.endActivity(activity, after: postProcessing)
        }

        // Expose the finished session so the UI can navigate to its transcript
        // once `isTranscribing` flips false. Set before clearing currentSessionId.
        lastFinishedSessionId = finishedSessionId
        currentSessionId = nil
        isTranscribing = false
    }

    /// The work that follows a finished recording (also used for imported
    /// recordings, see `MediaImportController`): speaker diarization (when a
    /// capture is given), auto-titling, transcript analysis and the summary.
    /// The session must already be ended and its audio files closed.
    ///
    /// - Returns: The background tasks, so callers can keep the Mac awake
    ///   until they finish.
    func runPostRecordingProcessing(sessionId: String, diarization capture: SpeakerDiarizationCapture?) -> [Task<Void, Never>] {
        var postProcessing: [Task<Void, Never>] = []

        // Split "Remote" into Speaker 1…N in the background (files are
        // closed by now: audioManager.stopRecording finished the recorder).
        if let capture, capture.sessionId == sessionId {
            postProcessing.append(SpeakerDiarizationCoordinator.sessionDidStop(capture, store: transcriptStore))
        }
        autoTitleIfNeeded(sessionId: sessionId)

        // Auto-analyze transcript (NaturalLanguage framework — runs on any Apple Silicon).
        if UserDefaults.standard.bool(forKey: "autoAnalyze") {
            let segments = (try? transcriptStore.fetchSegments(sessionId: sessionId)) ?? []
            if !segments.isEmpty {
                postProcessing.append(Task {
                    let analysis = await Task.detached(priority: .userInitiated) {
                        TranscriptAnalyzer.analyzeTranscript(segments: segments)
                    }.value
                    try? self.transcriptStore.saveEntities(analysis.entities, sessionId: sessionId)
                })
            }
        }

        // Auto-summarize (Foundation Models — on-device Apple Intelligence).
        if UserDefaults.standard.bool(forKey: "autoSummarize") {
            postProcessing.append(Task {
                let segments = (try? transcriptStore.fetchSegments(sessionId: sessionId)) ?? []
                guard !segments.isEmpty else { return }

                // Fetch the session so the summarizer sees the user-facing title.
                let title = (try? transcriptStore.fetchSession(id: sessionId))?.title ?? "Untitled"
                let segmentData = segments.map {
                    (speaker: $0.speaker, text: $0.text, timestamp: $0.formattedTimestamp)
                }
                if let summary = try? await MeetingSummarizer.summarize(
                    sessionId: sessionId,
                    title: title,
                    segments: segmentData
                ) {
                    try? transcriptStore.saveSummary(summary)
                }
                // Optional template summary block in the session's note.
                await TemplateAutoSummary.runIfEnabled(sessionId: sessionId, title: title, segments: segmentData, transcriptStore: transcriptStore)
            })
        }
        return postProcessing
    }

    /// Ends `activity` when every task in `work` has finished, or after
    /// ``postProcessingAwakeLimit`` — whichever comes first.
    private static func endActivity(_ activity: SystemActivityAssertion, after work: [Task<Void, Never>]) {
        guard !work.isEmpty else {
            activity.end()
            return
        }
        Task { @MainActor in
            for task in work { await task.value }
            activity.end()
        }
        Task { @MainActor in
            try? await Task.sleep(for: AppState.postProcessingAwakeLimit)
            if activity.isActive {
                Log.app.info("Post-processing still running after the keep-awake limit; allowing sleep.")
            }
            activity.end()
        }
    }

    /// Pauses the current recording without ending the session.
    func pauseSession() {
        audioManager.pauseRecording()
    }

    /// Resumes a previously paused recording.
    ///
    /// - Throws: If audio capture cannot be restarted.
    func resumeSession() async throws {
        try await audioManager.resumeRecording()
    }

    // MARK: - Auto-Titling

    /// Replaces a placeholder ("Untitled Session") with a title derived from
    /// the first ~8 words of the transcript, so the sidebar doesn't fill up
    /// with indistinguishable "Untitled Session" rows.
    private func autoTitleIfNeeded(sessionId: String) {
        guard let session = try? transcriptStore.fetchSession(id: sessionId) else { return }
        guard session.title.hasPrefix("Untitled") else { return }

        let segments = (try? transcriptStore.fetchSegments(sessionId: sessionId)) ?? []
        guard let firstSegment = segments.first else { return }

        let words = firstSegment.text
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(8)
            .joined(separator: " ")

        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Ellipsis if we truncated.
        let totalWords = firstSegment.text.split(whereSeparator: { $0.isWhitespace }).count
        let newTitle = totalWords > 8 ? "\(trimmed)…" : trimmed

        var updated = session
        updated.title = newTitle
        try? transcriptStore.updateSession(updated)
    }
}
