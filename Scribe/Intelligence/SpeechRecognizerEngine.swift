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
    /// (e.g. `"en-US"`). Presented in the overlay header so the user can see
    /// which model is live.
    @Published var currentLanguage: String?

    /// Whether the speech subsystem is usable at all on this device. In the
    /// new architecture we treat this as "the user granted speech auth and
    /// macOS 26 is available"; per-locale availability is checked per-session.
    @Published var isAvailable: Bool = true

    /// Latest volatile (partial) transcription text, reconstructed from both
    /// pipelines for display in the overlay.
    @Published var partialResult: String = ""

    // MARK: - Callbacks

    /// Fired on the main queue for each finalized transcription segment.
    var onSegmentTranscribed: ((TranscriptionSegment) -> Void)?

    /// Fired on the main queue when a partial result arrives. Useful for
    /// driving live text in the overlay.
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

    /// The most recent per-pipeline volatile text, so the overlay can show
    /// whichever speaker is currently mid-utterance.
    private var micPartial: String = ""
    private var remotePartial: String = ""

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

    /// Starts both transcription pipelines. Async because the `SpeechAnalyzer`
    /// actor requires awaiting, and because the required speech model may
    /// need to be downloaded first.
    func startSession() async {
        // Stop any previous session cleanly.
        await stopSession()

        let locale = resolveLocale(language)
        currentLanguage = locale.identifier

        // Ensure the model is installed ONCE before spawning the two pipelines.
        // Kicking off two concurrent AssetInventory installs for the same
        // module has been seen to crash in Speech.framework internals.
        do {
            try await ensureModelInstalled(for: locale)
        } catch {
            print("[SpeechRecognizerEngine] Model install failed: \(error.localizedDescription)")
            onSessionError?(error)
            return
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
            print("[SpeechRecognizerEngine] Failed to start pipelines: \(error.localizedDescription)")
            onSessionError?(error)
            await mic.stop()
            await remote.stop()
            return
        }

        self.micPipeline = mic
        self.remotePipeline = remote
        self.isProcessing = true
        print("[SpeechRecognizerEngine] Session started (parallel pipelines, locale \(locale.identifier))")
    }

    /// Idempotent, single-threaded asset install for a given locale. Called
    /// once at session start before spawning any pipelines.
    private func ensureModelInstalled(for locale: Locale) async throws {
        let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let status = await AssetInventory.status(forModules: [probe])
        print("[SpeechRecognizerEngine] Model status for \(locale.identifier): \(status)")

        switch status {
        case .installed, .downloading:
            return
        case .supported:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                print("[SpeechRecognizerEngine] Downloading model for \(locale.identifier)…")
                try await request.downloadAndInstall()
                print("[SpeechRecognizerEngine] Model installed for \(locale.identifier).")
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
    /// utterances are emitted as segments before the UI clears.
    func stopSession() async {
        let mic = micPipeline
        let remote = remotePipeline
        micPipeline = nil
        remotePipeline = nil
        await mic?.stop()
        await remote?.stop()

        micPartial = ""
        remotePartial = ""
        partialResult = ""
        isProcessing = false
    }

    // MARK: - Audio input

    /// Routes a captured audio buffer to the pipeline matching the given
    /// speaker label. `"you"` → microphone pipeline, `"remote"` → system-audio
    /// pipeline. No speaker-detection heuristic is needed — the caller knows
    /// the source.
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, speaker: String) {
        switch speaker.lowercased() {
        case "you":
            micPipeline?.append(buffer)
        case "remote":
            remotePipeline?.append(buffer)
        default:
            // Unknown source — route to mic as a best-effort default.
            micPipeline?.append(buffer)
        }
    }

    // MARK: - Language switching

    /// Applies a new locale preference. If a session is currently running,
    /// both pipelines are torn down and rebuilt with the new locale so the
    /// change takes effect immediately.
    func setLanguage(_ code: String?) async {
        let wasActive = isProcessing
        language = code
        if wasActive {
            await stopSession()
            await startSession()
        }
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
    private func resolveLocale(_ code: String?) -> Locale {
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
