@preconcurrency import AVFoundation
import CoreAudio

// MARK: - MicInputSelection

/// How the recording session's microphone input device is chosen.
enum MicInputSelection: Equatable, Sendable {
    /// Follow the mic a call/conferencing app is actively using — the one
    /// the user is really speaking into. Falls back to the system default
    /// when nothing else is in use.
    case automatic
    /// Follow the system default input device live.
    case systemDefault
    /// A specific pinned device.
    case device(AudioDeviceID)
}

// MARK: - Rebind policy

/// Collapses bursts of CoreAudio device notifications into a single rebind.
/// The first request schedules a drain; later ones before the drain only
/// replace the reason, and the drain resolves the device from the state at
/// that moment, so the last change wins.
struct MicRebindCoalescer: Sendable {
    enum Reason: String, Sendable {
        case activeInputChanged = "active input device changed"
        case defaultInputChanged = "system default input device changed"
    }

    private(set) var pending: Reason?

    /// Returns `true` when the caller must schedule a drain.
    mutating func request(_ reason: Reason) -> Bool {
        defer { pending = reason }
        return pending == nil
    }

    mutating func take() -> Reason? {
        defer { pending = nil }
        return pending
    }

    /// Drops a pending request made obsolete by a start, stop or selection change.
    mutating func cancel() {
        pending = nil
    }

    static func shouldRebind(
        reason: Reason,
        selection: MicInputSelection,
        activeTarget: AudioDeviceID?,
        currentDevice: AudioDeviceID?
    ) -> Bool {
        switch (selection, reason) {
        case (.systemDefault, .defaultInputChanged):
            return true
        case (.automatic, .activeInputChanged):
            // Staying put when nothing new is in use avoids churn when a call ends.
            guard let activeTarget else { return false }
            return activeTarget != currentDevice
        default:
            return false
        }
    }
}

// MARK: - MicSessionController

/// Owns the recording session's ``MicrophoneCapture`` and runs every
/// reconfiguration of it (device binding, voice processing, engine start/stop,
/// CoreAudio listeners) on one serial queue. Binding a device on a
/// voice-processing I/O unit blocks inside CoreAudio, so none of it may run on
/// the main actor.
///
/// `@unchecked Sendable`: all mutable state, including `capture`, is touched only on `queue`.
final class MicSessionController: @unchecked Sendable {

    struct StartConfiguration: Sendable {
        var voiceProcessing: Bool
        var pinnedDevice: AudioDeviceID?
        var onAudioBuffer: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
        var onLevel: @Sendable (Float) -> Void
    }

    private static let slowRebindThreshold: Duration = .milliseconds(250)

    private let queue = DispatchQueue(label: "com.varij.scribe.mic-control", qos: .userInitiated)
    private let capture = MicrophoneCapture()
    private let aligner: AudioStreamAligner

    private var selection: MicInputSelection = .systemDefault
    /// Between a successful ``start(_:)`` and ``stop()``.
    private var sessionOpen = false
    /// Session open and not paused: device changes should be followed.
    private var wantsCapture = false
    private var coalescer = MicRebindCoalescer()

    init(aligner: AudioStreamAligner) {
        self.aligner = aligner
        capture.listenerQueue = queue
    }

    // MARK: Session control

    func start(_ configuration: StartConfiguration) async throws {
        try await performThrowing { try $0.startOnQueue(configuration) }
    }

    func resume() async throws {
        try await performThrowing { try $0.resumeOnQueue() }
    }

    /// Fire-and-forget so pausing feels instant; anything queued afterwards
    /// (a resume, a stop) still runs after it.
    func pause() {
        queue.async { [self] in
            wantsCapture = false
            coalescer.cancel()
            capture.stopCapture()
        }
    }

    func stop() async {
        await perform { $0.stopOnQueue() }
    }

    func setSelection(_ selection: MicInputSelection) {
        queue.async { [self] in applySelection(selection) }
    }

    // MARK: Queue-confined implementation

    private func startOnQueue(_ configuration: StartConfiguration) throws {
        if let pinned = configuration.pinnedDevice {
            selection = .device(pinned)
        }
        configureCapture(for: selection)
        capture.voiceProcessing = configuration.voiceProcessing
        capture.onAudioBuffer = configuration.onAudioBuffer
        capture.onLevel = configuration.onLevel
        // A fresh session considers every in-use mic again; a mid-session
        // restart must keep excluding our own device.
        capture.resetCaptureBaseline()
        coalescer.cancel()

        try Perf.measure("mic.start") { try capture.startCapture() }
        sessionOpen = true
        wantsCapture = true
        // After capture, so our own device is the baseline that active-mic
        // detection excludes.
        observeForCurrentMode()
    }

    private func resumeOnQueue() throws {
        guard sessionOpen else { return }
        coalescer.cancel()
        try Perf.measure("mic.start") { try capture.startCapture() }
        wantsCapture = true
    }

    private func stopOnQueue() {
        sessionOpen = false
        wantsCapture = false
        coalescer.cancel()
        capture.stopObservingDefaultInputDevice()
        capture.stopObservingActiveInputDevice()
        capture.stopCapture()
    }

    private func applySelection(_ newSelection: MicInputSelection) {
        selection = newSelection
        configureCapture(for: newSelection)
        guard sessionOpen else { return }
        coalescer.cancel()
        if wantsCapture {
            rebind(reason: "selection changed")
        }
        observeForCurrentMode()
    }

    private func configureCapture(for selection: MicInputSelection) {
        switch selection {
        case .automatic:
            capture.selectedDeviceID = nil
            capture.autoDetectActiveInput = true
        case .systemDefault:
            capture.selectedDeviceID = nil
            capture.autoDetectActiveInput = false
        case .device(let id):
            capture.selectedDeviceID = id
            capture.autoDetectActiveInput = false
        }
    }

    private func observeForCurrentMode() {
        capture.stopObservingDefaultInputDevice()
        capture.stopObservingActiveInputDevice()

        switch selection {
        case .device:
            return
        case .automatic:
            capture.onActiveInputDeviceChanged = { [weak self] in
                self?.requestRebind(.activeInputChanged)
            }
            capture.startObservingActiveInputDevice()
        case .systemDefault:
            capture.onDefaultInputDeviceChanged = { [weak self] in
                self?.requestRebind(.defaultInputChanged)
            }
            capture.startObservingDefaultInputDevice()
        }
    }

    /// Called on `queue` by the CoreAudio listeners.
    private func requestRebind(_ reason: MicRebindCoalescer.Reason) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard coalescer.request(reason) else { return }
        queue.async { [weak self] in self?.drainRebind() }
    }

    private func drainRebind() {
        guard let reason = coalescer.take(), wantsCapture else { return }
        let activeTarget = selection == .automatic ? capture.activeInputDeviceID() : nil
        guard MicRebindCoalescer.shouldRebind(
            reason: reason,
            selection: selection,
            activeTarget: activeTarget,
            currentDevice: capture.currentCaptureDeviceID
        ) else { return }
        rebind(reason: reason.rawValue)
    }

    private func rebind(reason: String) {
        Log.audio.info("Restarting mic capture — \(reason, privacy: .public).")
        let clock = ContinuousClock()
        let started = clock.now
        Perf.measure("mic.rebind") {
            capture.stopCapture()
            // The restart leaves a short hole in the mic track; its next
            // buffer measures it so the recording stays aligned.
            aligner.trackWillStart(.mic)
            do {
                try capture.startCapture()
            } catch {
                Log.audio.error("Failed to restart mic capture: \(error.localizedDescription, privacy: .private)")
            }
        }
        let elapsed = clock.now - started
        if elapsed > Self.slowRebindThreshold {
            Log.audio.notice("Slow mic rebind (\(reason, privacy: .public)): \(elapsed.inMilliseconds, privacy: .public) ms")
        }
    }

    // MARK: Queue bridging

    private func performThrowing(_ body: @escaping @Sendable (MicSessionController) throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                continuation.resume(with: Result { try body(self) })
            }
        }
    }

    private func perform(_ body: @escaping @Sendable (MicSessionController) -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                body(self)
                continuation.resume()
            }
        }
    }
}
