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
    /// Segment start time in milliseconds.
    let startMs: Int
    /// Segment end time in milliseconds.
    let endMs: Int
    /// Speaker label (e.g. "you", "remote").
    let speaker: String
    /// Transcribed text.
    let text: String
}

// MARK: - SpeechRecognizerEngine

/// Two-pipeline streaming speech recognizer built on macOS 26's
/// `SpeechAnalyzer` + `SpeechTranscriber` APIs.
///
/// Each audio source runs through its own ``TranscriptionPipeline`` so the
/// user's microphone and the remote participants' audio transcribe in
/// parallel with correct, non-racy speaker labels. This replaces the older
/// single-`SFSpeechRecognizer` design that silently dropped long-form audio,
/// raced on speaker labelling, and timed out on silence.
///
/// Public API stays deliberately close to the previous engine so
/// ``AppState`` is largely untouched.
@MainActor
final class SpeechRecognizerEngine: ObservableObject {

    // MARK: - Published properties

    /// `true` while at least one of the two pipelines is actively analyzing.
    @Published var isProcessing: Bool = false

    /// The resolved locale identifier currently used by the pipelines
    /// (e.g. `"en-US"`). Presented in the live view header so the user can
    /// see which model is live.
    @Published var currentLanguage: String?

    /// Whether the speech subsystem is usable at all on this device. In the
    /// new architecture we treat this as "the user granted speech auth and
    /// macOS 26 is available"; per-locale availability is checked per-session.
    @Published var isAvailable: Bool = true

    /// Latest volatile (partial) transcription text, reconstructed from both
    /// pipelines for display in the live view.
    @Published var partialResult: String = ""

    /// True while the on-device speech model is being installed for a session.
    /// First-recording UX uses this to show "Downloading speech model…" instead
    /// of an empty waveform animation.
    @Published var isDownloadingModel: Bool = false

    // MARK: - Callbacks

    /// Fired on the main queue for each finalized transcription segment.
    var onSegmentTranscribed: ((TranscriptionSegment) -> Void)?

    /// Fired on the main queue when a partial result arrives. Useful for
    /// driving live text in the UI.
    var onPartialResult: ((String) -> Void)?

    /// Fired on the main queue when a pipeline errors out during a session.
    /// The caller typically surfaces this to the user as an alert.
    var onSessionError: ((Error) -> Void)?

    // MARK: - Language preference

    /// User-selected language code (e.g. `"en"`, `"de"`, or `"auto"`/nil for
    /// the system default locale). Setting this while a session is active
    /// tears down and rebuilds both pipelines with the new locale.
    var language: String?

    // MARK: - Pipelines

    private var micPipeline: TranscriptionPipeline?
    private var remotePipeline: TranscriptionPipeline?

    /// The most recent per-pipeline volatile text, so the live view can
    /// show whichever speaker is currently mid-utterance.
    private var micPartial: String = ""
    private var remotePartial: String = ""

    /// Advanced by every start, swap and stop so a superseded async start
    /// can't install its pipelines after `stopSession` (see
    /// ``SessionGeneration``).
    private var generation = SessionGeneration()

    /// Per-source audio accounting: keeps timestamps continuous across a
    /// language switch and holds audio while new pipelines spin up.
    private var micLedger = AudioSwapLedger<AVAudioPCMBuffer>()
    private var remoteLedger = AudioSwapLedger<AVAudioPCMBuffer>()

    /// Finalization of pipelines being replaced by a language switch.
    /// `stopSession` awaits it so their last segments land before the
    /// session is closed.
    private var retiringTask: Task<Void, Never>?

    // MARK: - Init

    init(language: String? = nil) {
        self.language = language
    }

    // MARK: - Authorization

    /// Requests speech-recognition authorization. Still required in macOS 26 —
    /// the newer `SpeechAnalyzer` API goes through the same TCC entitlement.
    ///
    /// `nonisolated` is required because this class is `@MainActor`, and
    /// without it the continuation closure is inferred as main-actor. TCC
    /// invokes the reply on a background dispatch queue, which triggers
    /// `_dispatch_assert_queue_fail` in Swift 6 strict concurrency mode.
    nonisolated static func checkAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - Session lifecycle

    /// Starts both transcription pipelines for a new recording. Async
    /// because the `SpeechAnalyzer` actor requires awaiting, and because the
    /// required speech model may need to be downloaded first.
    ///
    /// - Returns: `true` when both pipelines are live. `false` when starting
    ///   failed (already reported through ``onSessionError``) or was
    ///   superseded by a `stopSession` that ran meanwhile.
    @discardableResult
    func startSession() async -> Bool {
        // Stop any previous session cleanly.
        await stopSession()

        let token = generation.advance()
        // A new recording: timestamps start at 0. Audio that arrives before
        // the pipelines are live is held and fed to them first.
        micLedger.reset()
        remoteLedger.reset()
        micLedger.beginHolding()
        remoteLedger.beginHolding()

        let locale = Self.resolveLocale(language)
        guard await startPipelines(locale: locale, token: token) else { return false }

        // The language preference changed while we were starting (setLanguage
        // only records it when nothing is running yet): apply it now.
        if generation.isCurrent(token), Self.resolveLocale(language).identifier != locale.identifier {
            await swapPipelines()
        }
        return true
    }

    /// Builds and starts both pipelines for `locale`, then — if `token` is
    /// still current — feeds them any held audio and makes them live.
    private func startPipelines(locale: Locale, token: UInt64) async -> Bool {
        currentLanguage = locale.identifier

        // Ensure the model is installed ONCE before spawning the two pipelines.
        // Kicking off two concurrent AssetInventory installs for the same
        // module has been seen to crash in Speech.framework internals.
        do {
            try await ensureModelInstalled(for: locale)
        } catch {
            guard generation.isCurrent(token) else { return false }
            Log.speech.error("Engine model install failed: \(error.localizedDescription, privacy: .private)")
            abandonStart()
            onSessionError?(error)
            return false
        }
        guard generation.isCurrent(token) else {
            Log.speech.info("Engine start superseded during model install; not starting pipelines.")
            return false
        }

        let mic = makePipeline(speaker: "you")
        let remote = makePipeline(speaker: "remote")

        do {
            // Now safe to start in parallel — both pipelines will see
            // AssetInventory status == .installed and skip the install path.
            async let micStart: Void = mic.start(locale: locale)
            async let remoteStart: Void = remote.start(locale: locale)
            _ = try await (micStart, remoteStart)
        } catch {
            await mic.stop()
            await remote.stop()
            guard generation.isCurrent(token) else { return false }
            Log.speech.error("Engine failed to start pipelines: \(error.localizedDescription, privacy: .private)")
            abandonStart()
            onSessionError?(error)
            return false
        }

        guard generation.isCurrent(token) else {
            // stopSession (or a newer start) ran while we were starting:
            // don't install these pipelines, just shut them down again.
            Log.speech.info("Engine start superseded; discarding freshly started pipelines.")
            await mic.stop()
            await remote.stop()
            return false
        }

        // Go live: the base offset is the session time of the first buffer
        // each pipeline sees (the oldest held one), so timestamps continue
        // where the previous pipelines left off after a language switch.
        let micRelease = micLedger.endHolding()
        let remoteRelease = remoteLedger.endHolding()
        mic.baseOffsetMs = micRelease.baseOffsetMs
        remote.baseOffsetMs = remoteRelease.baseOffsetMs
        micPipeline = mic
        remotePipeline = remote
        for buffer in micRelease.buffers { mic.append(buffer) }
        for buffer in remoteRelease.buffers { remote.append(buffer) }

        isProcessing = true
        Log.speech.info("Engine session started (parallel pipelines, locale \(locale.identifier, privacy: .public), offsets \(micRelease.baseOffsetMs)/\(remoteRelease.baseOffsetMs) ms)")
        return true
    }

    /// Clears the "starting" state after a failed (current) start.
    private func abandonStart() {
        micLedger.discardHeld()
        remoteLedger.discardHeld()
        isProcessing = false
    }

    /// Idempotent, single-threaded asset install for a given locale. Called
    /// once at session start before spawning any pipelines.
    private func ensureModelInstalled(for locale: Locale) async throws {
        let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let status = await AssetInventory.status(forModules: [probe])
        Log.speech.info("Engine model status for \(locale.identifier, privacy: .public): \(String(describing: status), privacy: .public)")

        switch status {
        case .installed, .downloading:
            return
        case .supported:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                Log.speech.info("Engine downloading model for \(locale.identifier, privacy: .public)…")
                isDownloadingModel = true
                defer { isDownloadingModel = false }
                try await request.downloadAndInstall()
                Log.speech.info("Engine model installed for \(locale.identifier, privacy: .public).")
            }
        case .unsupported:
            throw NSError(
                domain: "SpeechRecognizerEngine", code: -20,
                userInfo: [NSLocalizedDescriptionKey:
                    "Speech recognition isn't supported for \(locale.identifier) on this Mac. Pick a different language."]
            )
        @unknown default:
            throw NSError(
                domain: "SpeechRecognizerEngine", code: -21,
                userInfo: [NSLocalizedDescriptionKey: "Unknown model asset state."]
            )
        }
    }

    /// Stops both pipelines, awaiting their finalization so any last
    /// utterances are emitted as segments before the UI clears. Also
    /// invalidates any start or language switch still in flight.
    func stopSession() async {
        generation.advance()
        // Cleared up front so a language change arriving while we finalize
        // doesn't start a swap (setLanguage only swaps while processing).
        isProcessing = false
        let mic = micPipeline
        let remote = remotePipeline
        micPipeline = nil
        remotePipeline = nil
        micLedger.reset()
        remoteLedger.reset()

        // Pipelines being retired by a language switch finish first (their
        // last segments belong before the new ones).
        if let retiring = retiringTask {
            await retiring.value
            retiringTask = nil
        }
        await mic?.stop()
        await remote?.stop()

        micPartial = ""
        remotePartial = ""
        partialResult = ""
    }

    // MARK: - Audio input

    /// Routes a captured audio buffer to the pipeline matching the given
    /// speaker label. `"you"` → microphone pipeline, `"remote"` → system-audio
    /// pipeline. No speaker-detection heuristic is needed — the caller knows
    /// the source.
    ///
    /// Every buffer is counted in the source's ``AudioSwapLedger`` so a
    /// pipeline created mid-recording knows its session offset; while new
    /// pipelines are starting the buffer is held instead of dropped.
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, speaker: String) {
        let seconds = Self.duration(of: buffer)
        if speaker.lowercased() == "remote" {
            guard remoteLedger.receive(buffer, seconds: seconds) else { return }
            remotePipeline?.append(buffer)
        } else {
            // "you", or an unknown source routed to the mic as a best-effort
            // default.
            guard micLedger.receive(buffer, seconds: seconds) else { return }
            micPipeline?.append(buffer)
        }
    }

    /// Length of `buffer` in seconds (0 for a malformed format).
    private static func duration(of buffer: AVAudioPCMBuffer) -> Double {
        let rate = buffer.format.sampleRate
        guard rate > 0 else { return 0 }
        return Double(buffer.frameLength) / rate
    }

    // MARK: - Language switching

    /// Applies a new locale preference. If a session is currently running,
    /// both pipelines are replaced with ones for the new locale so the change
    /// takes effect immediately. Timestamps continue from the audio already
    /// transcribed, and audio arriving during the swap is held and fed to the
    /// new pipelines rather than lost.
    func setLanguage(_ code: String?) async {
        let wasActive = isProcessing
        language = code
        if wasActive {
            await swapPipelines()
        }
    }

    /// Replaces the live pipelines without ending the session timeline.
    private func swapPipelines() async {
        let token = generation.advance()
        micLedger.beginHolding()
        remoteLedger.beginHolding()

        let oldMic = micPipeline
        let oldRemote = remotePipeline
        micPipeline = nil
        remotePipeline = nil
        micPartial = ""
        remotePartial = ""
        partialResult = ""

        // Finalize the old pipelines (their last segments keep their own
        // offsets). Chained after any earlier swap's retirement so segments
        // stay in order; stopSession awaits the same task.
        let previous = retiringTask
        let retiring = Task { @MainActor in
            await previous?.value
            await oldMic?.stop()
            await oldRemote?.stop()
        }
        retiringTask = retiring
        await retiring.value

        guard generation.isCurrent(token) else { return }
        _ = await startPipelines(locale: Self.resolveLocale(language), token: token)
    }

    // MARK: - Private helpers

    private func makePipeline(speaker: String) -> TranscriptionPipeline {
        let pipeline = TranscriptionPipeline(speaker: speaker)
        pipeline.onSegment = { [weak self] segment in
            guard let self else { return }
            self.onSegmentTranscribed?(segment)
        }
        pipeline.onPartialUpdate = { [weak self] text in
            guard let self else { return }
            self.updatePartial(for: speaker, text: text)
        }
        pipeline.onError = { [weak self] error in
            guard let self else { return }
            self.onSessionError?(error)
        }
        return pipeline
    }

    /// Merges per-pipeline volatile text into a single `partialResult`
    /// display string — whichever speaker most recently spoke wins.
    private func updatePartial(for speaker: String, text: String) {
        if speaker.lowercased() == "you" {
            micPartial = text
        } else {
            remotePartial = text
        }
        let merged = [remotePartial, micPartial]
            .filter { !$0.isEmpty }
            .joined(separator: "  ·  ")
        partialResult = merged
        onPartialResult?(merged)
    }

    /// Converts a user-supplied language code (e.g. `"en"`, `"de"`, `"auto"`,
    /// or `nil`) into a concrete `Locale`. Falls back to the system default.
    nonisolated static func resolveLocale(_ code: String?) -> Locale {
        guard let code, !code.isEmpty, code.lowercased() != "auto" else {
            return Locale.current
        }

        // Accept both short codes and full BCP-47 identifiers.
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
            "nl": "nl-NL",
            "ru": "ru-RU",
            "sv": "sv-SE",
            "da": "da-DK",
            "fi": "fi-FI",
            "pl": "pl-PL",
            "tr": "tr-TR",
            "uk": "uk-UA",
            "ar": "ar-SA",
            "he": "he-IL",
            "hi": "hi-IN",
            "th": "th-TH",
            "id": "id-ID",
            "ms": "ms-MY",
            "vi": "vi-VN",
            "nb": "nb-NO",
        ]
        let resolved = mapping[code.lowercased()] ?? code
        return Locale(identifier: resolved)
    }
}
