import Foundation
import whisper

/// Result from a single Whisper transcription segment.
struct TranscriptionResult {
    /// Segment start time in milliseconds.
    let startMs: Int
    /// Segment end time in milliseconds.
    let endMs: Int
    /// Transcribed text for this segment.
    let text: String
}

/// Errors that can occur during Whisper model loading or transcription.
enum WhisperError: LocalizedError {
    case modelLoadFailed(String)
    case transcriptionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path):
            return "Failed to load Whisper model at path: \(path)"
        case .transcriptionFailed(let code):
            return "Whisper transcription failed with error code: \(code)"
        }
    }
}

/// Swift wrapper around the whisper.cpp C API.
final class WhisperContext {

    // MARK: - Properties

    /// Opaque pointer to the underlying whisper_context.
    private var context: OpaquePointer?

    // MARK: - Initializer

    /// Load a Whisper model from disk.
    ///
    /// - Parameter modelPath: Absolute file path to the `.bin` model file.
    /// - Throws: `WhisperError.modelLoadFailed` if the model cannot be loaded.
    init(modelPath: String) throws {
        var params = whisper_context_default_params()
        params.use_gpu = true // Enable Metal acceleration on Apple Silicon

        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            throw WhisperError.modelLoadFailed(modelPath)
        }
        self.context = ctx
    }

    deinit {
        if let context {
            whisper_free(context)
        }
    }

    // MARK: - Transcription

    /// Transcribe audio samples and return an array of timed segments.
    ///
    /// - Parameters:
    ///   - samples: 16 kHz mono Float audio samples (range -1.0 ... 1.0).
    ///   - language: BCP-47 language code (e.g. `"en"`). Pass `nil` for auto-detection.
    /// - Returns: An array of `TranscriptionResult` with timing and text.
    /// - Throws: `WhisperError.transcriptionFailed` if `whisper_full` returns an error.
    func transcribe(samples: [Float], language: String? = nil) throws -> [TranscriptionResult] {
        guard let context else {
            throw WhisperError.modelLoadFailed("Context has been freed")
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        // Threading: use active processor count, capped at 8.
        let threadCount = min(ProcessInfo.processInfo.activeProcessorCount, 8)
        params.n_threads = Int32(threadCount)

        // We want transcription, not translation.
        params.translate = false

        // Language configuration.
        if language != nil {
            params.detect_language = false
        } else {
            params.detect_language = true
        }

        // Run the full transcription pipeline.
        // The language C string must remain valid for the entire whisper_full call,
        // so we set params.language inside withCString to keep the pointer alive.
        let langString = language ?? "auto"
        let result: Int32 = langString.withCString { langPtr in
            params.language = langPtr
            return samples.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return Int32(-1) }
                return whisper_full(context, params, baseAddress, Int32(samples.count))
            }
        }

        guard result == 0 else {
            throw WhisperError.transcriptionFailed(result)
        }

        // Extract segments from the results.
        let segmentCount = whisper_full_n_segments(context)
        var results: [TranscriptionResult] = []
        results.reserveCapacity(Int(segmentCount))

        for i in 0..<segmentCount {
            let t0 = whisper_full_get_segment_t0(context, i)
            let t1 = whisper_full_get_segment_t1(context, i)

            var text = ""
            if let cStr = whisper_full_get_segment_text(context, i) {
                text = String(cString: cStr)
            }

            // whisper.cpp times are in centiseconds; multiply by 10 to get milliseconds.
            let segment = TranscriptionResult(
                startMs: Int(t0) * 10,
                endMs: Int(t1) * 10,
                text: text
            )
            results.append(segment)
        }

        return results
    }
}
