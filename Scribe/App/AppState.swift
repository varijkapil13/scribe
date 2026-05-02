import Foundation
import Combine
import AVFoundation
import CoreAudio

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
    /// Surfaces the most recent error from the recording / transcription / persistence
    /// pipelines so the UI can show a banner. `nil` means "nothing wrong right now".
    @Published var lastError: String?

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    private var audioBufferManager = AudioBufferManager()

    /// One-shot flags so we don't spam the console with per-buffer logs but
    /// still confirm in the Xcode console that audio is flowing.
    private var hasLoggedFirstMicBuffer = false
    private var hasLoggedFirstSystemBuffer = false

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

    // MARK: - Singleton

    static let shared = AppState()

    // MARK: - Initialization

    /// - Parameter transcriptStore: Inject a custom store for tests. Defaults to
    ///   the shared on-disk store backing the running app.
    init(transcriptStore: TranscriptStore = TranscriptStore()) {
        self.transcriptStore = transcriptStore
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

        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .compactMap { _ in UserDefaults.standard.string(forKey: "selectedMicrophoneID") }
            .removeDuplicates()
            .sink { [weak self] stored in
                guard let self else { return }
                let deviceID = Self.parseMicDeviceID(stored)
                let label = stored.isEmpty ? "System Default" : stored
                Log.audio.info("Microphone preference changed → \(label, privacy: .public).")
                self.audioManager.setInputDevice(deviceID)
            }
            .store(in: &cancellables)
    }

    private func applyStoredMicrophoneDevice() {
        let stored = UserDefaults.standard.string(forKey: "selectedMicrophoneID") ?? ""
        audioManager.setInputDevice(Self.parseMicDeviceID(stored))
    }

    /// Parses the string-encoded `selectedMicrophoneID` UserDefault. Empty
    /// string or unparseable value means "use the system default".
    private static func parseMicDeviceID(_ stored: String) -> AudioDeviceID? {
        guard !stored.isEmpty, let id = AudioDeviceID(stored) else { return nil }
        return id
    }

    // MARK: - System Audio Preference

    /// Starts/stops the ScreenCaptureKit stream live when the user flips the
    /// "Capture system audio" toggle (in Settings or the live view), without
    /// interrupting microphone capture.
    private func observeSystemAudioPreference() {
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .compactMap { _ in UserDefaults.standard.object(forKey: "captureSystemAudio") as? Bool }
            .removeDuplicates()
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
    }

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
            self?.ingestTranscribedSegment(segment)
        }
        speechEngine.onSessionError = { [weak self] error in
            self?.lastError = error.localizedDescription
        }
    }

    /// Adds a raw SFSpeech segment to the current coalesce buffer, flushing it
    /// first if the speaker changed or the time window has elapsed.
    /// Internal (not private) so tests can drive the coalescing logic directly.
    func ingestTranscribedSegment(_ segment: TranscriptionSegment) {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

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
            // the segment. The UI listens to `lastError` and shows a banner.
            lastError = "Failed to save segment: \(error.localizedDescription)"
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

    // MARK: - Session Lifecycle

    /// Starts a new transcription session.
    ///
    /// Creates a database session, starts audio capture, and begins on-device
    /// speech recognition via Apple Speech.
    ///
    /// - Parameter title: Display title for the session. Defaults to `"Untitled Session"`.
    /// - Throws: If audio capture fails.
    func startSession(title: String = "Untitled Session") async throws {
        // Create a persistent session.
        let session = try transcriptStore.createSession(title: title)
        currentSessionId = session.id

        // Reset live view buffer, coalesce buffer, and diagnostic flags.
        overlaySegments.removeAll()
        pendingSegment = nil
        hasLoggedFirstMicBuffer = false
        hasLoggedFirstSystemBuffer = false

        // Reset audio buffers.
        audioBufferManager.reset()

        // The language preference is kept in sync continuously via
        // observeLanguagePreference() — no need to re-apply here.

        // Start the parallel speech pipelines FIRST so they're ready to
        // accept audio as soon as the engine starts producing it. This also
        // triggers on-demand model download if the locale's model isn't
        // installed yet — await handles that.
        await speechEngine.startSession()

        // Start audio capture.
        try await audioManager.startRecording()

        isTranscribing = true
        Log.app.info("Session started — id: \(session.id, privacy: .public), language: \(self.speechEngine.currentLanguage ?? "system default", privacy: .public)")
    }

    /// Stops the current transcription session.
    ///
    /// Halts audio capture, stops speech recognition, and finalizes the session
    /// record in the database. Triggers auto-analysis and auto-summarization if
    /// enabled in settings.
    func stopSession() async {
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

        if let sessionId = finishedSessionId {
            try? transcriptStore.endSession(id: sessionId)
            autoTitleIfNeeded(sessionId: sessionId)
        }

        // Auto-analyze transcript (NaturalLanguage framework — runs on any Apple Silicon).
        if UserDefaults.standard.bool(forKey: "autoAnalyze"), let sessionId = finishedSessionId {
            let segments = (try? transcriptStore.fetchSegments(sessionId: sessionId)) ?? []
            if !segments.isEmpty {
                Task {
                    let analysis = await Task.detached(priority: .userInitiated) {
                        TranscriptAnalyzer.analyzeTranscript(segments: segments)
                    }.value
                    try? self.transcriptStore.saveEntities(analysis.entities, sessionId: sessionId)
                }
            }
        }

        // Auto-summarize (Foundation Models — on-device Apple Intelligence).
        if UserDefaults.standard.bool(forKey: "autoSummarize"), let sessionId = finishedSessionId {
            Task {
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
            }
        }

        currentSessionId = nil
        isTranscribing = false
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
