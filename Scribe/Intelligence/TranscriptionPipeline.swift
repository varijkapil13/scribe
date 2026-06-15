import Foundation
// See MicrophoneCapture: AVFAudio's converter-input block is `@Sendable`, but
// `AVAudioConverter.convert` runs it synchronously. `@preconcurrency` strips
// the imported Sendable annotations so capturing the source buffer and the
// local `delivered` flag in the block is not flagged as a data race.
@preconcurrency import AVFoundation
import Speech
import CoreMedia

/// One streaming speech-to-text pipeline using Apple's macOS 26
/// `SpeechAnalyzer` + `SpeechTranscriber` APIs.
///
/// Scribe runs two of these in parallel — one bound to the user's microphone
/// (`speaker = "you"`) and one to captured system audio (`speaker = "remote"`)
/// — so each stream transcribes independently with correct, non-racy speaker
/// labels and without the silence-timeout restart gymnastics SFSpeech forced
/// on us.
///
/// The pipeline:
/// 1. Builds a `SpeechTranscriber` for the requested locale (downloads the
///    on-device model via `AssetInventory` if needed).
/// 2. Spawns an `AsyncStream<AnalyzerInput>` that the audio-capture layer
///    feeds into via ``append(_:)``.
/// 3. Starts a `SpeechAnalyzer` with that input stream + the transcriber.
/// 4. Consumes the transcriber's `results` async sequence on a Task,
///    emitting finalized text as ``TranscriptionSegment`` values and volatile
///    (partial) text via ``onPartialUpdate``.
@MainActor
final class TranscriptionPipeline {

    // MARK: - Public surface

    /// Speaker label stamped onto every segment emitted from this pipeline
    /// (typically `"you"` or `"remote"`).
    let speaker: String

    /// Fired on the main queue for each finalized transcription segment.
    var onSegment: ((TranscriptionSegment) -> Void)?

    /// Fired on the main queue for live volatile results (partial, evolving
    /// text). Use this to drive an "as-you-speak" live view.
    var onPartialUpdate: ((String) -> Void)?

    /// Fired on the main queue when the analyzer errors out. The pipeline is
    /// considered dead after this — the caller should recreate it.
    var onError: ((Error) -> Void)?

    /// Non-nil once the analyzer has actually started accepting audio.
    private(set) var isRunning: Bool = false

    /// The resolved locale currently in use (e.g. `en-US`, `de-DE`).
    private(set) var locale: Locale?

    // MARK: - Private state

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    /// The audio format `SpeechAnalyzer` wants input in — queried from the
    /// framework at start time. On macOS 26 this is typically 16 kHz mono
    /// Int16 PCM; our capture path delivers Float32, so we convert each
    /// buffer before yielding it.
    private var analyzerFormat: AVAudioFormat?

    /// Lazy converter built the first time we see an input format. Recreated
    /// if the input format changes mid-session (e.g. user switches mic to a
    /// device with a different native rate).
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    /// Session start time in audio-clock seconds — subtracted from result
    /// range start so `sessionOffsetMs` lines up with the recording duration
    /// displayed in the UI rather than a CoreMedia timeline.
    private var sessionStart: Date?

    // MARK: - Init

    init(speaker: String) {
        self.speaker = speaker
    }

    // MARK: - Lifecycle

    /// Builds the transcriber for `locale`, ensures the on-device model is
    /// installed, and starts the analyzer. Throws if the locale isn't
    /// supported on this device or if asset installation fails.
    func start(locale: Locale) async throws {
        // Tear down any prior run first so `start` is idempotent.
        await stop()

        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription
        )
        self.transcriber = transcriber

        try await ensureAssetsInstalled(for: transcriber)

        // Ask the framework what format it wants input in. Feeding the wrong
        // format (e.g. Float32 to an Int16-expecting transcriber) trips a
        // runtime precondition inside SpeechRecognizerWorker.preRunRecognition
        // on the first buffer.
        if let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) {
            self.analyzerFormat = best
            Log.speech.info("Pipeline[\(self.speaker, privacy: .public)] analyzer format: \(String(describing: best), privacy: .public)")
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Consume results on a detached task so we don't block `start`. The
        // task is cancelled on `stop()` to tear down cleanly.
        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    await self.handle(result: result)
                }
            } catch is CancellationError {
                // expected on stop
            } catch {
                await MainActor.run {
                    self.onError?(error)
                }
            }
        }

        try await analyzer.start(inputSequence: stream)
        self.sessionStart = Date()
        self.locale = locale
        self.isRunning = true
        Log.speech.info("Pipeline[\(self.speaker, privacy: .public)] started — locale: \(locale.identifier, privacy: .public)")
    }

    /// Ensures the speech model for this transcriber's locale is downloaded
    /// and installed. If macOS reports it can be installed on demand we kick
    /// off the download and await completion.
    private func ensureAssetsInstalled(for transcriber: SpeechTranscriber) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        Log.speech.info("Pipeline[\(self.speaker, privacy: .public)] asset status: \(String(describing: status), privacy: .public)")
        switch status {
        case .installed, .downloading:
            return
        case .supported:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Log.speech.info("Pipeline[\(self.speaker, privacy: .public)] downloading speech model…")
                try await request.downloadAndInstall()
                Log.speech.info("Pipeline[\(self.speaker, privacy: .public)] speech model installed.")
            }
        case .unsupported:
            throw NSError(
                domain: "TranscriptionPipeline", code: -10,
                userInfo: [NSLocalizedDescriptionKey:
                    "Speech recognition isn't supported for this locale on this device. Pick a different language in Settings."]
            )
        @unknown default:
            throw NSError(
                domain: "TranscriptionPipeline", code: -11,
                userInfo: [NSLocalizedDescriptionKey: "Unknown speech-model asset state."]
            )
        }
    }

    /// Feeds an audio buffer into the pipeline. Silently no-ops if the
    /// pipeline hasn't started yet — the audio-capture layer races startup.
    ///
    /// Incoming buffers are whatever the capture layer delivers (currently
    /// 16 kHz mono Float32). `SpeechAnalyzer` requires its own format —
    /// typically Int16 — so we convert on the fly.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let continuation = inputContinuation else { return }

        guard let analyzerFormat else {
            // Pipeline is up but we haven't resolved the analyzer's required
            // format yet — drop this buffer rather than risk a format
            // mismatch precondition inside Speech.framework.
            return
        }

        let converted: AVAudioPCMBuffer
        if buffer.format.isEqual(analyzerFormat) {
            converted = buffer
        } else if let result = convertBuffer(buffer, to: analyzerFormat) {
            converted = result
        } else {
            return
        }

        continuation.yield(AnalyzerInput(buffer: converted))
    }

    /// Converts an incoming capture buffer to the analyzer's expected format,
    /// lazily building (and reusing) an ``AVAudioConverter``. Returns `nil` on
    /// conversion failure, which callers treat as "drop this buffer".
    private func convertBuffer(_ buffer: AVAudioPCMBuffer,
                               to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        if converter == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterInputFormat = buffer.format
        }
        guard let converter else { return nil }

        // Output frame capacity must account for sample-rate conversion
        // (frames in × out-rate / in-rate), with a little headroom for any
        // converter latency/resampling rounding.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 128

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else { return nil }

        var error: NSError?
        // Reference box (see SystemAudioCapture): the converter-input block must
        // hand the source buffer over exactly once. A class flag mutated via a
        // `let` binding avoids the captured-var diagnostic; `@unchecked Sendable`
        // is sound because `convert` runs the block synchronously on the calling
        // thread, so the gate never crosses a concurrency boundary.
        final class InputGate: @unchecked Sendable { var delivered = false }
        let gate = InputGate()
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if gate.delivered {
                outStatus.pointee = .noDataNow
                return nil
            }
            gate.delivered = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil, outputBuffer.frameLength > 0 else {
            return nil
        }
        return outputBuffer
    }

    /// Finalises the current analysis and tears down the pipeline. Safe to
    /// call even when not running.
    func stop() async {
        isRunning = false
        inputContinuation?.finish()
        inputContinuation = nil

        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                Log.speech.error("Pipeline[\(self.speaker, privacy: .public)] finalize error: \(error.localizedDescription, privacy: .private)")
            }
        }

        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        sessionStart = nil
        locale = nil
        analyzerFormat = nil
        converter = nil
        converterInputFormat = nil
    }

    // MARK: - Result handling

    private func handle(result: SpeechTranscriber.Result) async {
        let rawText = String(result.text.characters)
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let isVolatile = isResultVolatile(result)

        if isVolatile {
            // Partial / evolving — do not persist. Just update live view.
            onPartialUpdate?(trimmed)
            return
        }

        // Finalized — emit as a segment.
        let (startMs, endMs) = offsetsForResult(result)
        let segment = TranscriptionSegment(
            id: UUID(),
            sessionOffsetMs: startMs,
            startMs: startMs,
            endMs: endMs,
            speaker: speaker,
            text: trimmed
        )
        onSegment?(segment)
        // Clear the partial preview slot once finalized.
        onPartialUpdate?("")
    }

    /// `SpeechTranscriber.Result` doesn't expose a boolean isFinal, but
    /// volatile results carry the `SpeechAttributes.audioTimeRange` attribute
    /// with `zeroDuration`-ish ranges, while finalized results land after
    /// `resultsFinalizationTime >= result.range.end`. We use that as the
    /// finalization signal.
    private func isResultVolatile(_ result: SpeechTranscriber.Result) -> Bool {
        return result.resultsFinalizationTime < result.range.end
    }

    /// Converts a `CMTimeRange` into session-relative millisecond offsets.
    /// The session start is captured in real time (not audio time) so the
    /// displayed timestamp matches the recording duration in the UI.
    private func offsetsForResult(_ result: SpeechTranscriber.Result) -> (Int, Int) {
        let rangeStart = result.range.start.seconds
        let rangeEnd   = result.range.end.seconds
        let startMs = max(0, Int(rangeStart * 1000))
        let endMs   = max(startMs, Int(rangeEnd * 1000))
        return (startMs, endMs)
    }
}
