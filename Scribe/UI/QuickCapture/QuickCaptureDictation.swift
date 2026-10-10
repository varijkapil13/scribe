@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Speech

/// Dictation into the Quick Capture field.
///
/// `DictationController` types its result into whichever app has focus via
/// `TextInserter`, which is wrong here (the capture panel is non-activating,
/// so the frontmost app is someone else's). This drives the same building
/// blocks directly instead: its own `MicrophoneCapture` feeding one
/// `TranscriptionPipeline`, with `DictationTextFormatter` for the text.
/// `liveText` updates as you speak; the model streams it into the field.
@MainActor
final class QuickCaptureDictation: ObservableObject {

    enum Phase: Equatable {
        case idle
        case preparing
        case listening
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Finalized segments plus the current partial, joined.
    @Published private(set) var liveText: String = ""

    /// Called on the main actor whenever `liveText` changes while
    /// listening, so the owner can stream it into its text field.
    var onLiveText: ((String) -> Void)?

    var isActive: Bool {
        phase == .preparing || phase == .listening
    }

    private var pipeline: TranscriptionPipeline?
    private var mic: MicrophoneCapture?
    private var feedTask: Task<Void, Never>?
    private var continuation: AsyncStream<QuickCaptureAudioBox>.Continuation?
    private var segments: [String] = []
    private var partial: String = ""
    /// Bumped on every start, so a `begin()` still awaiting permission or
    /// the speech model from an earlier, already stopped session gives up
    /// instead of starting a second pipeline or failing the new one.
    private var generation = 0

    init() {}

    func start() {
        guard !isActive else { return }
        segments = []
        partial = ""
        liveText = ""
        phase = .preparing
        generation &+= 1
        let session = generation
        Task { await begin(session) }
    }

    /// Stops listening. Returns the final, cleaned text (fillers removed per
    /// the Dictation setting), or "" when nothing was heard.
    @discardableResult
    func stop() async -> String {
        guard isActive else { return liveText }
        let wasListening = phase == .listening
        // A `begin()` still loading the model must not open the mic.
        generation &+= 1
        teardownCapture()
        if wasListening { await feedTask?.value }
        feedTask = nil
        // Stays current while it finalizes, so the last result it flushes
        // still reaches `segments` (stale-pipeline callbacks are ignored).
        let pipeline = self.pipeline
        await pipeline?.stop()
        if self.pipeline === pipeline { self.pipeline = nil }
        phase = .idle

        var pieces = segments
        if !partial.isEmpty { pieces.append(partial) }
        let removeFillers = UserDefaults.standard.object(forKey: DictationController.removeFillersKey) as? Bool ?? true
        let text = DictationTextFormatter.finalText(segments: pieces, removeFillers: removeFillers)
        liveText = text
        return text
    }

    /// Stops without waiting for the final result (panel closing).
    func cancel() {
        guard isActive else { return }
        generation &+= 1
        teardownCapture()
        feedTask = nil
        let pipeline = self.pipeline
        self.pipeline = nil
        Task { await pipeline?.stop() }
        phase = .idle
    }

    // MARK: - Private

    private func begin(_ session: Int) async {
        let micGranted = await Permissions.checkMicrophonePermission() == .granted
        // Stopped (or restarted) while asking for permission.
        guard phase == .preparing, generation == session else { return }
        guard micGranted else {
            return fail("Microphone access is off for Scribe.")
        }
        let speechAuthorized = await SpeechRecognizerEngine.checkAuthorization() == .authorized
        guard phase == .preparing, generation == session else { return }
        guard speechAuthorized else {
            return fail("Speech recognition access is off for Scribe.")
        }

        // Callbacks from a pipeline that is no longer current (a stopped
        // session flushing its last result) must not touch the new session.
        let pipeline = TranscriptionPipeline(speaker: "dictation")
        pipeline.onSegment = { [weak self, weak pipeline] segment in
            guard let self, let pipeline, self.pipeline === pipeline else { return }
            self.segments.append(segment.text)
            self.refreshLiveText()
        }
        pipeline.onPartialUpdate = { [weak self, weak pipeline] text in
            guard let self, let pipeline, self.pipeline === pipeline else { return }
            self.partial = text
            self.refreshLiveText()
        }
        pipeline.onError = { [weak self, weak pipeline] error in
            guard let self, let pipeline, self.pipeline === pipeline else { return }
            self.fail("Dictation stopped: \(error.localizedDescription)")
        }
        self.pipeline = pipeline

        let language = UserDefaults.standard.string(forKey: "selectedLanguage")
        do {
            try await pipeline.start(locale: SpeechRecognizerEngine.resolveLocale(language))
        } catch {
            guard generation == session, self.pipeline === pipeline else { return }
            return fail("Couldn't start dictation: \(error.localizedDescription)")
        }
        // Cancelled while the speech model was loading.
        guard phase == .preparing, generation == session, self.pipeline === pipeline else {
            await pipeline.stop()
            return
        }

        let mic = MicrophoneCapture()
        if let pinned = UInt32(UserDefaults.standard.string(forKey: "selectedMicrophoneID") ?? "") {
            mic.selectedDeviceID = AudioDeviceID(pinned)
        }
        let (stream, continuation) = AsyncStream<QuickCaptureAudioBox>.makeStream()
        mic.onAudioBuffer = Self.forwarder(to: continuation)
        self.continuation = continuation
        feedTask = Task { [weak self] in
            for await box in stream {
                guard let self else { return }
                self.pipeline?.append(box.buffer)
            }
        }
        do {
            try mic.startCapture()
        } catch {
            return fail("Couldn't open the microphone: \(error.localizedDescription)")
        }
        self.mic = mic
        phase = .listening
    }

    private func refreshLiveText() {
        liveText = DictationTextFormatter.join(segments + [partial])
        onLiveText?(liveText)
    }

    private func teardownCapture() {
        mic?.onAudioBuffer = nil
        mic?.stopCapture()
        mic = nil
        continuation?.finish()
        continuation = nil
    }

    private func fail(_ message: String) {
        Log.speech.error("Quick Capture dictation failed: \(message, privacy: .public)")
        teardownCapture()
        feedTask = nil
        let pipeline = self.pipeline
        self.pipeline = nil
        Task { await pipeline?.stop() }
        phase = .failed(message)
    }

    /// Built outside the main actor so the closure isn't main-actor
    /// isolated; it runs on the audio thread and only yields into the stream.
    nonisolated private static func forwarder(
        to continuation: AsyncStream<QuickCaptureAudioBox>.Continuation
    ) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in continuation.yield(QuickCaptureAudioBox(buffer: buffer)) }
    }
}

/// Carries a mic buffer off the audio thread. `MicrophoneCapture` allocates
/// a fresh buffer per callback, so handing it across without copying is
/// safe (same reasoning as `DictationController.SendableBuffer`).
struct QuickCaptureAudioBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}
