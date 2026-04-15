import Foundation
import Speech
import AVFoundation
import Combine

// MARK: - TranscriptionMode

/// Identifies which transcription backend is in use.
///
/// Both ``TranscriptionEngine`` (whisper.cpp) and ``SpeechRecognizerEngine``
/// (Apple Speech) produce ``TranscriptionSegment`` values, so the app can
/// switch between them at runtime.
enum TranscriptionMode: String, CaseIterable, Identifiable {
    case whisper = "Whisper (whisper.cpp)"
    case apple  = "Apple Speech (on-device)"

    var id: String { rawValue }

    /// Short name suitable for menu items.
    var displayName: String {
        switch self {
        case .whisper: return "Whisper"
        case .apple:   return "Apple Speech"
        }
    }

    /// User-facing explanation of the mode.
    var description: String {
        switch self {
        case .whisper:
            return "High-accuracy transcription powered by whisper.cpp. Requires a downloaded model."
        case .apple:
            return "On-device transcription using Apple's built-in speech recognition. No model download needed."
        }
    }
}

// MARK: - SpeechRecognizerEngine

/// Alternative transcription engine using Apple's `SFSpeechRecognizer` for
/// on-device speech recognition. Requires no model download — uses the
/// system's built-in speech recognition models.
///
/// Available on macOS 13+. Uses on-device recognition
/// (`requiresOnDeviceRecognition = true`) to ensure no audio leaves the
/// device, matching Scribe's privacy guarantees.
///
/// ## Streaming vs. Chunked
///
/// `SFSpeechRecognizer` natively supports streaming audio through
/// ``appendAudioBuffer(_:speaker:)``. The engine also exposes
/// ``processAudioChunk(samples:speaker:chunkOffsetMs:)`` for backward
/// compatibility with ``AudioBufferManager``'s chunk-based pipeline.
final class SpeechRecognizerEngine: ObservableObject {

    // MARK: - Published Properties

    /// Whether the engine is currently processing audio.
    @Published var isProcessing: Bool = false

    /// The language code in use for the current session.
    @Published var currentLanguage: String?

    /// Whether the underlying `SFSpeechRecognizer` reports itself as available.
    @Published var isAvailable: Bool = false

    /// Live partial transcription result, updated as the user speaks.
    @Published var partialResult: String = ""

    // MARK: - Properties

    /// The Apple speech recognizer instance.
    private var speechRecognizer: SFSpeechRecognizer?

    /// The in-flight audio buffer recognition request.
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    /// The in-flight recognition task.
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Timestamp when the current session began, used to compute session-relative offsets.
    private var sessionStartTime: Date?

    /// The number of segments already delivered for the current recognition task.
    ///
    /// Each final result contains *all* segments recognised so far, so we keep
    /// track of how many we have already emitted to avoid duplicates.
    private var emittedSegmentCount: Int = 0

    /// The speaker label most recently provided via an audio-append call.
    private var currentSpeaker: String = "unknown"

    /// Manual language override. When `nil`, the system default locale is used.
    var language: String?

    /// Callback invoked on the main thread for each finalised transcription segment.
    var onSegmentTranscribed: ((TranscriptionSegment) -> Void)?

    /// Callback invoked on the main thread when a partial (non-final) result arrives.
    var onPartialResult: ((String) -> Void)?

    // MARK: - Initializer

    /// Creates a new `SpeechRecognizerEngine`.
    ///
    /// - Parameter language: BCP-47 language code (e.g. `"en"`, `"de"`).
    ///   Pass `nil` or `"auto"` to use the system default locale.
    init(language: String? = nil) {
        self.language = language
        configureSpeechRecognizer(for: language)
    }

    // MARK: - Static Helpers

    /// Request speech recognition authorization and return the resulting status.
    ///
    /// On first launch the system will present a permission dialog. Subsequent
    /// calls return the cached status.
    ///
    /// - Returns: The current `SFSpeechRecognizerAuthorizationStatus`.
    static func checkAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Check whether on-device recognition is available for the given language.
    ///
    /// - Parameter language: BCP-47 language code, or `nil` for the system default.
    /// - Returns: `true` if the device supports on-device recognition for that locale.
    static func isOnDeviceRecognitionAvailable(for language: String?) -> Bool {
        let recognizer: SFSpeechRecognizer?
        if let locale = Self.locale(for: language) {
            recognizer = SFSpeechRecognizer(locale: locale)
        } else {
            recognizer = SFSpeechRecognizer()
        }
        return recognizer?.supportsOnDeviceRecognition ?? false
    }

    // MARK: - Session Lifecycle

    /// Begin a new transcription session.
    ///
    /// Creates a fresh `SFSpeechAudioBufferRecognitionRequest` and starts a
    /// recognition task. Partial results are delivered continuously; final
    /// results are split into ``TranscriptionSegment`` values and forwarded
    /// via ``onSegmentTranscribed``.
    func startSession() {
        guard let speechRecognizer else {
            print("[SpeechRecognizerEngine] Cannot start session — no speech recognizer configured.")
            return
        }

        // Reset state from any previous session.
        stopSession()

        sessionStartTime = Date()
        emittedSegmentCount = 0

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        if #available(macOS 15, *) {
            request.addsPunctuation = true
        }

        recognitionRequest = request

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let error {
                // The task may deliver an error alongside a final result, so
                // process the result first before handling the error.
                if result == nil {
                    print("[SpeechRecognizerEngine] Recognition error: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.isProcessing = false
                    }
                    return
                }
            }

            guard let result else { return }

            if result.isFinal {
                self.handleFinalResult(result)
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.partialResult = ""
                }
            } else {
                let partial = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.partialResult = partial
                    self.onPartialResult?(partial)
                }
            }
        }

        DispatchQueue.main.async {
            self.isProcessing = true
            self.currentLanguage = self.language
        }
    }

    /// Stop the current transcription session, releasing resources.
    ///
    /// Any in-flight recognition is cancelled. It is safe to call this even
    /// when no session is active.
    func stopSession() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil
        sessionStartTime = nil

        DispatchQueue.main.async {
            self.isProcessing = false
            self.partialResult = ""
        }
    }

    // MARK: - Audio Processing

    /// Append an `AVAudioPCMBuffer` to the active recognition request.
    ///
    /// This is the preferred streaming interface. `SFSpeechRecognizer` handles
    /// chunking and silence detection internally, so there is no need for the
    /// caller to split audio into fixed-duration windows.
    ///
    /// - Parameters:
    ///   - buffer: A PCM audio buffer in a format compatible with `SFSpeechRecognizer`
    ///     (typically 16 kHz mono Float32).
    ///   - speaker: Speaker label to attach to segments generated from this audio
    ///     (e.g. `"you"` or `"remote"`).
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, speaker: String) {
        currentSpeaker = speaker
        recognitionRequest?.append(buffer)
    }

    /// Convert raw Float samples to an `AVAudioPCMBuffer` and append them to
    /// the active recognition request.
    ///
    /// This method provides backward compatibility with ``AudioBufferManager``,
    /// which delivers audio as `[Float]` chunks.
    ///
    /// - Parameters:
    ///   - samples: 16 kHz mono Float audio samples (range -1.0 ... 1.0).
    ///   - speaker: Speaker label for segment attribution.
    ///   - chunkOffsetMs: Offset of this chunk from the session start, in
    ///     milliseconds. (Informational — `SFSpeechRecognizer` tracks timing
    ///     internally.)
    func processAudioChunk(samples: [Float], speaker: String, chunkOffsetMs: Int) {
        guard !samples.isEmpty else { return }

        currentSpeaker = speaker

        guard let buffer = Self.pcmBuffer(from: samples, sampleRate: 16_000) else {
            print("[SpeechRecognizerEngine] Failed to create AVAudioPCMBuffer from samples.")
            return
        }

        recognitionRequest?.append(buffer)
    }

    // MARK: - Language

    /// Change the recognition language.
    ///
    /// If a session is currently active the engine will stop and restart it
    /// with the new language.
    ///
    /// - Parameter code: BCP-47 language code (e.g. `"en"`, `"de"`), or `nil`
    ///   to fall back to the system default.
    func setLanguage(_ code: String?) {
        let wasActive = recognitionTask != nil
        language = code

        configureSpeechRecognizer(for: code)

        if wasActive {
            startSession()
        }
    }

    // MARK: - Private Helpers

    /// Instantiate (or re-instantiate) the `SFSpeechRecognizer` for a given
    /// language code.
    private func configureSpeechRecognizer(for languageCode: String?) {
        if let locale = Self.locale(for: languageCode) {
            speechRecognizer = SFSpeechRecognizer(locale: locale)
        } else {
            speechRecognizer = SFSpeechRecognizer()
        }

        speechRecognizer?.defaultTaskHint = .dictation

        if let speechRecognizer {
            // On-device only — no audio leaves the machine.
            if speechRecognizer.supportsOnDeviceRecognition {
                speechRecognizer.supportsOnDeviceRecognition = true
            }

            DispatchQueue.main.async {
                self.isAvailable = speechRecognizer.isAvailable
            }
        } else {
            DispatchQueue.main.async {
                self.isAvailable = false
            }
        }
    }

    /// Process a final recognition result by extracting new segments and
    /// delivering them via ``onSegmentTranscribed``.
    private func handleFinalResult(_ result: SFSpeechRecognitionResult) {
        let transcription = result.bestTranscription
        let segments = transcription.segments

        // Only emit segments we have not already delivered.
        let newSegments = segments.dropFirst(emittedSegmentCount)
        emittedSegmentCount = segments.count

        let speaker = currentSpeaker

        for sfSegment in newSegments {
            let trimmed = sfSegment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let startMs = Int(sfSegment.timestamp * 1000)
            let endMs   = Int((sfSegment.timestamp + sfSegment.duration) * 1000)

            let segment = TranscriptionSegment(
                id: UUID(),
                sessionOffsetMs: startMs,
                startMs: startMs,
                endMs: endMs,
                speaker: speaker,
                text: trimmed
            )

            DispatchQueue.main.async { [onSegmentTranscribed] in
                onSegmentTranscribed?(segment)
            }
        }
    }

    /// Map a short language code to a full `Locale`.
    ///
    /// Handles common shorthand codes used elsewhere in Scribe. Returns `nil`
    /// when the engine should fall back to the system default (i.e. `nil` or
    /// `"auto"`).
    private static func locale(for code: String?) -> Locale? {
        guard let code, !code.isEmpty, code.lowercased() != "auto" else {
            return nil
        }

        // Map short codes to full BCP-47 identifiers the recogniser expects.
        let mapping: [String: String] = [
            "en": "en-US",
            "de": "de-DE",
            "fr": "fr-FR",
            "es": "es-ES",
            "it": "it-IT",
            "pt": "pt-BR",
            "ja": "ja-JP",
            "ko": "ko-KR",
            "zh": "zh-CN",
            "ru": "ru-RU",
            "nl": "nl-NL",
            "pl": "pl-PL",
            "sv": "sv-SE",
            "da": "da-DK",
            "fi": "fi-FI",
            "nb": "nb-NO",
            "tr": "tr-TR",
            "uk": "uk-UA",
            "ar": "ar-SA",
            "he": "he-IL",
            "hi": "hi-IN",
            "th": "th-TH",
            "id": "id-ID",
            "ms": "ms-MY",
            "vi": "vi-VN",
        ]

        let resolved = mapping[code.lowercased()] ?? code
        return Locale(identifier: resolved)
    }

    /// Create an `AVAudioPCMBuffer` from a raw Float sample array.
    ///
    /// - Parameters:
    ///   - samples: Audio samples in the range -1.0 ... 1.0.
    ///   - sampleRate: The sample rate of the audio (e.g. 16 000).
    /// - Returns: A new PCM buffer, or `nil` if the format or buffer could not
    ///   be created.
    static func pcmBuffer(from samples: [Float], sampleRate: Double = 16_000) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)

        guard let channelData = buffer.floatChannelData else {
            return nil
        }

        samples.withUnsafeBufferPointer { src in
            channelData[0].update(from: src.baseAddress!, count: samples.count)
        }

        return buffer
    }
}
