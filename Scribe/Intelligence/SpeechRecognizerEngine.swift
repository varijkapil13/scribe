import Foundation
import Speech
import AVFoundation
import Combine

// MARK: - TranscriptionSegment

/// A single transcribed segment with speaker and session-relative timing.
struct TranscriptionSegment: Identifiable, Equatable {
    let id: UUID
    /// Offset in milliseconds from the start of the recording session.
    let sessionOffsetMs: Int
    /// Segment start time in milliseconds (relative to the audio chunk).
    let startMs: Int
    /// Segment end time in milliseconds (relative to the audio chunk).
    let endMs: Int
    /// Speaker label (e.g. "you", "remote").
    let speaker: String
    /// Transcribed text.
    let text: String
}

// MARK: - SpeechRecognizerEngine

/// On-device transcription engine using Apple's `SFSpeechRecognizer`.
///
/// This is Scribe's sole transcription backend. It requires no model download —
/// speech recognition models are built into macOS. On-device recognition
/// (`requiresOnDeviceRecognition = true`) ensures no audio leaves the device,
/// matching Scribe's privacy guarantees.
///
/// ## Streaming vs. Chunked
///
/// `SFSpeechRecognizer` natively supports streaming audio through
/// ``appendAudioBuffer(_:speaker:)``. The engine also exposes
/// ``processAudioChunk(samples:speaker:chunkOffsetMs:)`` for compatibility
/// with ``AudioBufferManager``'s chunk-based pipeline.
final class SpeechRecognizerEngine: ObservableObject, @unchecked Sendable {

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

    /// Whether the caller currently wants recognition to be active. Used to
    /// distinguish an expected cancellation (we called `stopSession()`) from an
    /// unexpected mid-stream error, and to decide whether to auto-restart when
    /// SFSpeech's silence timeout fires.
    private var wantRecognitionActive: Bool = false

    /// Set to `true` on the main queue when the current recognition task has
    /// fully delivered its final result (or errored out). ``stopSession()``
    /// polls this flag so audio finalized by `endAudio()` has time to become
    /// persisted segments before the request/task are released.
    private var taskDidFinish: Bool = false

    /// The most recent partial transcription text we've seen. Used by the
    /// utterance-boundary detector to notice when SFSpeech resets its partial
    /// (signaling a new utterance has started) so we can commit the previous
    /// one as a segment before it's overwritten.
    private var lastPartialText: String = ""

    /// Manual language override. When `nil`, the system default locale is used.
    var language: String?

    /// Callback invoked on the main thread for each finalised transcription segment.
    var onSegmentTranscribed: ((TranscriptionSegment) -> Void)?

    /// Callback invoked on the main thread when a partial (non-final) result arrives.
    var onPartialResult: ((String) -> Void)?

    /// Callback invoked on the main thread if the recognition task fails with
    /// an error before producing a final result. Callers typically surface this
    /// via an alert so users know why transcription stopped.
    var onSessionError: ((Error) -> Void)?

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
            DispatchQueue.main.async { [weak self] in
                self?.onSessionError?(NSError(
                    domain: "SpeechRecognizerEngine", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No speech recognizer available for the selected language."]
                ))
            }
            return
        }

        guard speechRecognizer.isAvailable else {
            print("[SpeechRecognizerEngine] Recognizer exists but isAvailable == false; aborting.")
            DispatchQueue.main.async { [weak self] in
                self?.onSessionError?(NSError(
                    domain: "SpeechRecognizerEngine", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Speech recognition isn't available right now (try again in a moment, or check that on-device dictation is enabled in System Settings)."]
                ))
            }
            return
        }

        guard speechRecognizer.supportsOnDeviceRecognition else {
            print("[SpeechRecognizerEngine] On-device recognition not supported for \(language ?? "system default"); cannot start session.")
            DispatchQueue.main.async { [weak self] in
                self?.onSessionError?(NSError(
                    domain: "SpeechRecognizerEngine", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "On-device speech recognition isn't supported for this language on your Mac. Choose a different language in Settings or enable dictation for this locale in System Settings → Keyboard → Dictation."]
                ))
            }
            return
        }

        // Hard-reset any previous session synchronously. When starting a new
        // session we don't need to wait for the old task to finalize — its
        // output is no longer relevant.
        wantRecognitionActive = false
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        sessionStartTime = nil

        wantRecognitionActive = true
        sessionStartTime = Date()
        emittedSegmentCount = 0

        startRecognitionTask(on: speechRecognizer)

        DispatchQueue.main.async {
            self.isProcessing = true
            self.currentLanguage = self.language
        }
    }

    /// Creates a fresh `SFSpeechAudioBufferRecognitionRequest` + task and
    /// installs the result handler. Used both for initial session start and to
    /// transparently restart after SFSpeech's silence timeout, so meetings with
    /// natural pauses keep transcribing without user intervention.
    private func startRecognitionTask(on speechRecognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true

        recognitionRequest = request
        emittedSegmentCount = 0
        lastPartialText = ""

        print("[SpeechRecognizerEngine] Starting recognition task — locale: \(speechRecognizer.locale.identifier), supportsOnDevice: \(speechRecognizer.supportsOnDeviceRecognition)")

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let error {
                if result == nil {
                    self.handleRecognitionError(error)
                    return
                }
            }

            guard let result else { return }

            if result.isFinal {
                // handleFinalResult enqueues onSegmentTranscribed on the main
                // queue — those callbacks persist the segment to the DB.
                self.handleFinalResult(result)
                self.lastPartialText = ""
                DispatchQueue.main.async {
                    self.partialResult = ""
                }
                if self.wantRecognitionActive {
                    // Continuous meeting transcription: start a fresh task so
                    // the stream keeps producing segments.
                    self.scheduleRestart()
                } else {
                    // We're stopping. Mark done AFTER the segment dispatches
                    // above have been queued — DispatchQueue.main is serial
                    // so by the time this flag flips, the segment has been
                    // saved, and stopSession() can safely release resources.
                    DispatchQueue.main.async {
                        self.isProcessing = false
                        self.taskDidFinish = true
                    }
                }
            } else {
                let partial = result.bestTranscription.formattedString
                // Log only on meaningful changes to avoid spam.
                if partial.count % 20 == 0 || partial.count < 20 {
                    print("[SpeechRecognizerEngine] Partial (\(partial.count) chars): \"\(partial.prefix(80))\"")
                }
                self.handlePartialUpdate(partial)
            }
        }
    }

    /// Handles an error from the recognition task. Expected errors (our own
    /// cancel on stop, SFSpeech's silence timeout) are absorbed and, where
    /// appropriate, trigger a transparent restart. Unexpected errors are
    /// surfaced to the caller via ``onSessionError``.
    private func handleRecognitionError(_ error: Error) {
        let message = error.localizedDescription
        let lowered = message.lowercased()

        // User-initiated cancel: our own `stopSession` called endAudio and is
        // awaiting completion. Don't alert — this is the normal stop path.
        if !wantRecognitionActive || lowered.contains("cancel") {
            print("[SpeechRecognizerEngine] Recognition task ended (expected).")
            DispatchQueue.main.async { [weak self] in
                self?.isProcessing = false
                self?.taskDidFinish = true
            }
            return
        }

        // Silence timeout: SFSpeech gives up after ~60s of no speech. For a
        // meeting transcriber this is expected — restart transparently.
        if lowered.contains("no speech") {
            print("[SpeechRecognizerEngine] SFSpeech silence timeout — restarting task.")
            scheduleRestart()
            return
        }

        // Unexpected error — stop and surface to the caller.
        print("[SpeechRecognizerEngine] Recognition error: \(message)")
        wantRecognitionActive = false
        DispatchQueue.main.async { [weak self] in
            self?.isProcessing = false
            self?.onSessionError?(error)
            self?.taskDidFinish = true
        }
    }

    /// Starts a new recognition task after the current one ended (either via
    /// silence timeout or an `isFinal` result), as long as the caller still
    /// wants recognition. Runs on the main actor to avoid racing with
    /// ``stopSession()``.
    private func scheduleRestart() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantRecognitionActive, let recognizer = self.speechRecognizer else {
                return
            }
            // Clear the old handles; the previous task has already ended.
            self.recognitionRequest = nil
            self.recognitionTask = nil
            self.startRecognitionTask(on: recognizer)
        }
    }

    /// Stops the current transcription session gracefully, waiting for the
    /// active SFSpeech task to deliver its final result so any buffered audio
    /// becomes a persisted segment instead of being discarded.
    ///
    /// Calling `endAudio()` signals end-of-stream; SFSpeech then produces an
    /// `isFinal` result on its callback. We await a `taskDidFinish` flag (set
    /// by that callback) with a 2 s ceiling so stop can never hang.
    ///
    /// `wantRecognitionActive` is cleared first so the pending completion
    /// handler knows not to surface a "canceled" alert or restart the task.
    ///
    /// Safe to call when no session is active.
    func stopSession() async {
        wantRecognitionActive = false

        // Safety net: capture whatever SFSpeech has recognized so far as a
        // segment BEFORE we call endAudio. In practice, on-device SFSpeech
        // sometimes fails to emit an `isFinal` result in response to
        // `endAudio()` for short utterances — leaving the spoken text
        // trapped in `partialResult`. Emitting it here guarantees the user
        // sees their transcript even if SFSpeech never finalizes.
        emitPendingPartialAsSegment()

        // Nothing in flight — just clean local state.
        guard let request = recognitionRequest, recognitionTask != nil else {
            recognitionRequest = nil
            recognitionTask = nil
            sessionStartTime = nil
            await MainActor.run {
                self.isProcessing = false
                self.partialResult = ""
            }
            return
        }

        taskDidFinish = false
        request.endAudio()
        print("[SpeechRecognizerEngine] endAudio() called, awaiting final result…")

        // Poll for the handler to finish processing the final result (and its
        // `onSegmentTranscribed` callback to have fired on the main queue).
        // Bounded at 2 s so a stuck task never blocks the UI.
        let deadline = Date().addingTimeInterval(2.0)
        while !taskDidFinish && Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000) // 30 ms
        }
        print("[SpeechRecognizerEngine] stopSession finished — taskDidFinish: \(taskDidFinish)")

        recognitionRequest = nil
        recognitionTask = nil
        sessionStartTime = nil

        await MainActor.run {
            self.isProcessing = false
            self.partialResult = ""
        }
    }

    /// Processes a partial transcription update, detecting SFSpeech's internal
    /// utterance boundaries. Apple's on-device recognizer resets the partial
    /// text when it decides a new utterance has started — WITHOUT firing
    /// `isFinal` — so the only signal we have is that the partial text
    /// suddenly diverges from the previous one. When that happens we commit
    /// the previous partial as a finalized segment so it isn't lost.
    private func handlePartialUpdate(_ partial: String) {
        let previous = lastPartialText

        // Detect an utterance boundary: the new partial is significantly
        // shorter than the previous one AND doesn't share its opening words.
        // If so, SFSpeech has started a fresh utterance and the previous one
        // is effectively final.
        if !previous.isEmpty && !isContinuation(from: previous, to: partial) {
            print("[SpeechRecognizerEngine] Utterance boundary detected — committing previous partial (\(previous.count) chars).")
            emitSegmentFromPartial(previous)
        }

        lastPartialText = partial

        DispatchQueue.main.async {
            self.partialResult = partial
            self.onPartialResult?(partial)
        }
    }

    /// Heuristic: does `current` look like a continuation (growth or minor
    /// correction) of `previous`, or has a new utterance begun?
    private func isContinuation(from previous: String, to current: String) -> Bool {
        // Trivial prefix cases — clear continuation.
        if current.hasPrefix(previous) { return true }     // "Hello" -> "Hello world"
        if previous.hasPrefix(current) { return true }     // "Hello world" -> "Hello" (rare)

        // Compare the first word — SFSpeech occasionally re-capitalises or
        // adjusts punctuation within the same utterance, but the opening word
        // stays stable.
        let prevFirst = previous.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let curFirst = current.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let normalizedPrev = prevFirst.trimmingCharacters(in: .punctuationCharacters).lowercased()
        let normalizedCur = curFirst.trimmingCharacters(in: .punctuationCharacters).lowercased()
        if !normalizedPrev.isEmpty && normalizedPrev == normalizedCur {
            return true
        }

        return false
    }

    /// Emits the given text as a finalized transcription segment. Used both by
    /// the utterance-boundary detector and the stop-session safety net.
    private func emitSegmentFromPartial(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let speaker = currentSpeaker
        let offsetMs: Int
        if let start = sessionStartTime {
            offsetMs = Int(-start.timeIntervalSinceNow * 1000)
        } else {
            offsetMs = 0
        }

        let segment = TranscriptionSegment(
            id: UUID(),
            sessionOffsetMs: offsetMs,
            startMs: 0,
            endMs: 0,
            speaker: speaker,
            text: trimmed
        )

        DispatchQueue.main.async { [onSegmentTranscribed] in
            onSegmentTranscribed?(segment)
        }
    }

    /// Emits whatever is currently in ``lastPartialText`` as a finalized
    /// transcription segment. Used by ``stopSession`` so the last utterance
    /// is never lost if SFSpeech fails to deliver a proper `isFinal` result.
    ///
    /// We use `lastPartialText` (the value the recognition handler sees) rather
    /// than the `@Published partialResult` because the latter is updated via
    /// `DispatchQueue.main.async` and may lag behind what SFSpeech has
    /// actually produced.
    private func emitPendingPartialAsSegment() {
        let text = lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        print("[SpeechRecognizerEngine] Emitting pending partial as segment (\(text.count) chars): \(text.prefix(60))…")
        lastPartialText = ""
        emitSegmentFromPartial(text)
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
            if !speechRecognizer.supportsOnDeviceRecognition {
                print("[SpeechRecognizerEngine] WARNING: on-device recognition not supported for \(languageCode ?? "default"); transcription will fail because Scribe enforces on-device-only recognition.")
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
        let fullText = transcription.formattedString

        print("[SpeechRecognizerEngine] Final result received — segments: \(segments.count), text: \"\(fullText.prefix(80))\"")

        // If SFSpeech returns a transcription but with 0 segments (can happen
        // on short utterances), fall back to emitting the full text as one
        // segment so the user's words aren't silently discarded.
        if segments.isEmpty {
            let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                print("[SpeechRecognizerEngine] Final result had no segments and no text — nothing to save.")
                return
            }
            let speaker = currentSpeaker
            let segment = TranscriptionSegment(
                id: UUID(),
                sessionOffsetMs: 0,
                startMs: 0,
                endMs: 0,
                speaker: speaker,
                text: trimmed
            )
            DispatchQueue.main.async { [onSegmentTranscribed] in
                onSegmentTranscribed?(segment)
            }
            return
        }

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
