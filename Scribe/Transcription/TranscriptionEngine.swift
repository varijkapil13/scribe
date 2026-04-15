import Foundation
import Combine

/// A single transcribed segment with speaker and session-relative timing.
struct TranscriptionSegment: Identifiable, Equatable {
    let id: UUID
    /// Offset in milliseconds from the start of the recording session.
    let sessionOffsetMs: Int
    /// Segment start time in milliseconds (relative to the audio chunk).
    let startMs: Int
    /// Segment end time in milliseconds (relative to the audio chunk).
    let endMs: Int
    /// Speaker label (e.g. "Speaker 1").
    let speaker: String
    /// Transcribed text.
    let text: String
}

/// Coordinates chunked transcription using `WhisperContext`.
///
/// Audio chunks are submitted via `processAudioChunk` and transcribed on a
/// dedicated serial queue. Completed segments are delivered through the
/// `onSegmentTranscribed` callback on the main thread.
final class TranscriptionEngine: ObservableObject {

    // MARK: - Published Properties

    /// Whether the engine is currently processing an audio chunk.
    @Published var isProcessing: Bool = false

    /// The language detected or set for the current session.
    @Published var currentLanguage: String?

    // MARK: - Properties

    /// The loaded Whisper model context.
    private var whisperContext: WhisperContext?

    /// Serial queue for transcription work.
    private let processingQueue = DispatchQueue(
        label: "com.scribe.transcription",
        qos: .userInitiated
    )

    /// Timestamp when the current recording session began.
    private var sessionStartTime: Date?

    /// Manual language override. When `nil`, language is auto-detected.
    var language: String?

    /// Callback invoked on the main thread for each transcribed segment.
    var onSegmentTranscribed: ((TranscriptionSegment) -> Void)?

    // MARK: - Model Management

    /// Load a Whisper model from the given file path.
    ///
    /// - Parameter path: Absolute path to the `.bin` model file.
    /// - Throws: `WhisperError` if the model cannot be loaded.
    func loadModel(path: String) throws {
        whisperContext = try WhisperContext(modelPath: path)
    }

    /// Unload the current model and release its resources.
    func unloadModel() {
        whisperContext = nil
    }

    /// Whether a model is currently loaded and ready for transcription.
    var isModelLoaded: Bool {
        whisperContext != nil
    }

    // MARK: - Session Lifecycle

    /// Begin a new transcription session, recording the start time.
    func startSession() {
        sessionStartTime = Date()
        DispatchQueue.main.async {
            self.currentLanguage = self.language
        }
    }

    /// End the current transcription session.
    func stopSession() {
        sessionStartTime = nil
    }

    // MARK: - Audio Processing

    /// Submit an audio chunk for transcription.
    ///
    /// The chunk is processed asynchronously on a serial queue. Each resulting
    /// segment is delivered via `onSegmentTranscribed` on the main thread.
    ///
    /// - Parameters:
    ///   - samples: 16 kHz mono Float audio samples.
    ///   - speaker: Speaker label to attach to all segments in this chunk.
    ///   - chunkOffsetMs: The offset of this chunk's start relative to the session start, in milliseconds.
    func processAudioChunk(samples: [Float], speaker: String, chunkOffsetMs: Int) {
        processingQueue.async { [weak self] in
            guard let self, let whisperContext = self.whisperContext else { return }

            DispatchQueue.main.async {
                self.isProcessing = true
            }

            defer {
                DispatchQueue.main.async {
                    self.isProcessing = false
                }
            }

            do {
                let results = try whisperContext.transcribe(
                    samples: samples,
                    language: self.language
                )

                for result in results {
                    // Skip empty or whitespace-only segments.
                    let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    let segment = TranscriptionSegment(
                        id: UUID(),
                        sessionOffsetMs: chunkOffsetMs + result.startMs,
                        startMs: result.startMs,
                        endMs: result.endMs,
                        speaker: speaker,
                        text: trimmed
                    )

                    DispatchQueue.main.async {
                        self.onSegmentTranscribed?(segment)
                    }
                }
            } catch {
                // In a production app this would surface through an error publisher.
                print("[TranscriptionEngine] Transcription error: \(error.localizedDescription)")
            }
        }
    }
}
