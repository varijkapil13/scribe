import Foundation
import Combine
import AVFoundation

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
    @Published var transcriptStore = TranscriptStore()
    @Published var overlaySegments: [TranscriptionSegment] = []
    @Published var currentSessionId: String?
    @Published var isTranscribing: Bool = false

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    private var audioBufferManager = AudioBufferManager()

    /// One-shot flags so we don't spam the console with per-buffer logs but
    /// still confirm in the Xcode console that audio is flowing.
    private var hasLoggedFirstMicBuffer = false
    private var hasLoggedFirstSystemBuffer = false

    // MARK: - Singleton

    static let shared = AppState()

    // MARK: - Initialization

    init() {
        wireAudioPipeline()
        wireTranscriptionResults()
    }

    // MARK: - Pipeline Wiring

    /// Connects microphone audio directly to Apple Speech.
    ///
    /// SFSpeechRecognizer is a streaming API — it handles silence detection and
    /// segmentation internally, so we bypass ``AudioBufferManager`` and append
    /// every buffer as it arrives. This removes the 5-second initial delay
    /// that the chunking introduced and lets partial results surface within
    /// a few hundred milliseconds of speaking.
    ///
    /// System audio is captured but NOT fed into the same recognizer — a
    /// single SFSpeech instance can't distinguish two speakers, and even
    /// silent system-audio buffers would clobber the speaker label on mic
    /// segments. Proper dual-speaker transcription requires two independent
    /// SFSpeechRecognizer instances; for now we transcribe the user's mic
    /// only.
    private func wireAudioPipeline() {
        audioManager.onMicBuffer = { [weak self] buffer in
            guard let self else { return }
            if !self.hasLoggedFirstMicBuffer {
                self.hasLoggedFirstMicBuffer = true
                print("[AppState] First mic buffer received — frames: \(buffer.frameLength), format: \(buffer.format)")
            }
            self.speechEngine.appendAudioBuffer(buffer, speaker: "you")
        }

        audioManager.onSystemBuffer = { [weak self] buffer in
            guard let self else { return }
            if !self.hasLoggedFirstSystemBuffer {
                self.hasLoggedFirstSystemBuffer = true
                print("[AppState] First system audio buffer received — frames: \(buffer.frameLength) (not fed to recognizer)")
            }
            // Intentionally not forwarded to speechEngine — see doc comment.
        }
    }

    /// Connects transcription engine output to storage and the overlay display.
    private func wireTranscriptionResults() {
        speechEngine.onSegmentTranscribed = { [weak self] segment in
            guard let self else { return }
            // Persist the segment.
            if let sessionId = self.currentSessionId {
                try? self.transcriptStore.addSegment(
                    sessionId: sessionId,
                    startMs: segment.sessionOffsetMs,
                    endMs: segment.sessionOffsetMs + (segment.endMs - segment.startMs),
                    speaker: segment.speaker,
                    text: segment.text
                )
            }

            // Update the overlay with recent segments (keep last 20 for performance).
            self.overlaySegments.append(segment)
            if self.overlaySegments.count > 20 {
                self.overlaySegments.removeFirst(self.overlaySegments.count - 20)
            }
        }
    }

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

        // Reset overlay and diagnostic flags.
        overlaySegments.removeAll()
        hasLoggedFirstMicBuffer = false
        hasLoggedFirstSystemBuffer = false

        // Reset audio buffers.
        audioBufferManager.reset()

        // Start Apple Speech recognition FIRST so the recognition request is
        // ready to accept buffers as soon as the audio engine starts producing
        // them. (Reversed order previously dropped the first ~100 ms of audio.)
        speechEngine.startSession()

        // Start audio capture.
        try await audioManager.startRecording()

        isTranscribing = true
        print("[AppState] Session started — id: \(session.id), language: \(speechEngine.currentLanguage ?? "system default")")
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
