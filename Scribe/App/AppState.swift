import Foundation
import Combine
import AVFoundation

/// Central application state that coordinates audio capture, transcription, and storage.
///
/// `AppState` wires together the audio pipeline, transcription engine, and persistent
/// storage so that higher-level UI code can simply call `startSession` / `stopSession`.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Published Properties

    @Published var audioManager = AudioSessionManager()
    @Published var modelManager = ModelManager()
    @Published var transcriptionEngine = TranscriptionEngine()
    @Published var transcriptStore = TranscriptStore()
    @Published var overlaySegments: [TranscriptionSegment] = []
    @Published var currentSessionId: String?
    @Published var isTranscribing: Bool = false

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    private var audioBufferManager = AudioBufferManager()

    // MARK: - Singleton

    static let shared = AppState()

    // MARK: - Initialization

    init() {
        wireAudioPipeline()
        wireTranscriptionResults()
    }

    // MARK: - Pipeline Wiring

    /// Connects microphone and system audio buffers to the chunk manager.
    private func wireAudioPipeline() {
        // Microphone audio -> buffer manager
        audioManager.onMicBuffer = { [weak self] buffer in
            guard let self else { return }
            let samples = buffer.floatArray
            guard !samples.isEmpty else { return }
            self.audioBufferManager.appendMicSamples(samples)
        }

        // System audio -> buffer manager
        audioManager.onSystemBuffer = { [weak self] buffer in
            guard let self else { return }
            let samples = buffer.floatArray
            guard !samples.isEmpty else { return }
            self.audioBufferManager.appendSystemSamples(samples)
        }

        // When a chunk is ready, feed it to the transcription engine.
        audioBufferManager.onChunkReady = { [weak self] samples, speaker in
            guard let self else { return }
            // Compute the approximate session offset from the recording duration.
            let offsetMs = Int(self.audioManager.recordingDuration * 1000)
            self.transcriptionEngine.processAudioChunk(
                samples: samples,
                speaker: speaker,
                chunkOffsetMs: offsetMs
            )
        }
    }

    /// Connects transcription engine output to storage and the overlay display.
    private func wireTranscriptionResults() {
        transcriptionEngine.onSegmentTranscribed = { [weak self] segment in
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
    /// Loads the Whisper model (if not already loaded), creates a database session,
    /// starts audio capture, and begins the transcription engine.
    ///
    /// - Parameter title: Display title for the session. Defaults to `"Untitled Session"`.
    /// - Throws: If the model cannot be loaded or audio capture fails.
    func startSession(title: String = "Untitled Session") async throws {
        // Load the Whisper model if needed.
        if !transcriptionEngine.isModelLoaded {
            guard let modelPath = modelManager.selectedModelPath() else {
                throw AppStateError.noModelAvailable
            }
            try transcriptionEngine.loadModel(path: modelPath)
        }

        // Create a persistent session.
        let session = try transcriptStore.createSession(title: title)
        currentSessionId = session.id

        // Reset overlay.
        overlaySegments.removeAll()

        // Reset audio buffers.
        audioBufferManager.reset()

        // Start audio capture.
        try await audioManager.startRecording()

        // Start the transcription engine session.
        transcriptionEngine.startSession()

        isTranscribing = true
    }

    /// Stops the current transcription session.
    ///
    /// Halts audio capture, stops the transcription engine, and finalizes the
    /// session record in the database.
    func stopSession() async {
        await audioManager.stopRecording()
        transcriptionEngine.stopSession()

        if let sessionId = currentSessionId {
            try? transcriptStore.endSession(id: sessionId)
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
}

// MARK: - AppStateError

/// Errors specific to `AppState` session management.
enum AppStateError: LocalizedError {
    case noModelAvailable

    var errorDescription: String? {
        switch self {
        case .noModelAvailable:
            return "No Whisper model is available. Please download a model in Settings."
        }
    }
}
