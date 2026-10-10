// ScribeiOS/Recording/MobileAudioCapture.swift
//
// Microphone capture on iPhone / iPad. iOS only lets an app record the
// microphone — no other app's or system audio — so this is the whole capture
// stack there ("In-person / speakerphone"). The Mac's CoreAudio /
// ScreenCaptureKit stack (Scribe/Audio) is not compiled into this target.

// `@preconcurrency`: AVFAudio's tap and converter blocks carry imported
// `@Sendable` annotations that don't reflect how they're invoked (see
// Scribe/Audio/AudioConversion.swift).
@preconcurrency import AVFoundation
import Foundation

// MARK: - Errors

enum MobileAudioCaptureError: LocalizedError {
    case microphoneDenied
    case speechDenied
    case noInput
    case sessionFailed(String)
    case engineFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Scribe needs microphone access to record. Turn it on in Settings › Privacy & Security › Microphone."
        case .speechDenied:
            return "Scribe needs speech recognition access to transcribe. Turn it on in Settings › Privacy & Security › Speech Recognition."
        case .noInput:
            return "No microphone is available right now."
        case .sessionFailed(let detail):
            return "Couldn't set up audio recording: \(detail)"
        case .engineFailed(let detail):
            return "Couldn't start the microphone: \(detail)"
        }
    }
}

// MARK: - Audio session

/// Owns the shared `AVAudioSession` for a recording and turns its
/// notifications (interruptions, route changes, engine reconfiguration,
/// media-services resets) into main-actor callbacks.
@MainActor
final class MobileAudioSessionCoordinator {

    var onInterruption: ((MobileAudioInterruption) -> Void)?
    var onRouteChange: ((MobileAudioRouteChange) -> Void)?
    var onEngineConfigurationChange: (() -> Void)?
    var onMediaServicesReset: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    /// Microphone permission (iOS 17+ `AVAudioApplication`). `nonisolated`
    /// so the system's reply on a background queue never asserts main-actor
    /// isolation (see `SpeechRecognizerEngine.checkAuthorization`).
    nonisolated static func requestMicrophonePermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// `.playAndRecord` / `.spokenAudio`, Bluetooth headset mics allowed
    /// (AirPods), playback NOT forced to the speaker, then activates the
    /// session. With `UIBackgroundModes: audio` an active recording session
    /// keeps running when the app goes to the background or the screen locks.
    func activateForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: Self.recordingOptions)
            try session.setActive(true)
        } catch {
            throw MobileAudioCaptureError.sessionFailed(error.localizedDescription)
        }
    }

    /// CI-COMPILE NOTE: `.allowBluetoothHFP` is the iOS 26+ name of the
    /// former `.allowBluetooth` (hands-free profile: the AirPods mic). If the
    /// SDK doesn't know it, use `.allowBluetooth`. `.defaultToSpeaker` is
    /// deliberately absent.
    nonisolated static var recordingOptions: AVAudioSession.CategoryOptions {
        [.allowBluetoothHFP]
    }

    /// Releases the session so other apps' audio can resume.
    func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Log.audio.error("Couldn't deactivate the audio session: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The current input's name (e.g. "iPhone Microphone", "AirPods Pro").
    var currentInputName: String? {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
    }

    func startObserving(engine: AVAudioEngine) {
        stopObserving()
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let typeRaw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let optionsRaw = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue
            MainActor.assumeIsolated {
                guard let event = MobileAudioInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw) else { return }
                self?.onInterruption?(event)
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reasonRaw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
            MainActor.assumeIsolated {
                self?.onRouteChange?(MobileAudioRouteChange(rawReason: reasonRaw))
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onMediaServicesReset?() }
        })

        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEngineConfigurationChange?() }
        })
    }

    func stopObserving() {
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }
}

// MARK: - Capture

/// Hand-off of one converted capture buffer from the render thread to the
/// main actor. `@unchecked Sendable`: capture allocates a fresh buffer per
/// callback that is only read afterwards (same contract as the Mac's
/// `CapturedAudioBuffer`).
struct MobileCapturedBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// Peak level shared between the render thread (writer) and the main
/// actor's meter (reader): keeps the loudest peak since the last read.
final class MobileLevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0

    func record(_ value: Float) {
        lock.lock()
        if value > peak { peak = value }
        lock.unlock()
    }

    func drain() -> Float {
        lock.lock()
        defer { lock.unlock() }
        let value = peak
        peak = 0
        return value
    }
}

/// Whether captured audio is kept. Paused recordings keep the engine running
/// (so the app stays alive in the background and can resume from the Live
/// Activity) and simply drop audio here.
final class MobileCaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    func set(open value: Bool) {
        lock.lock()
        open = value
        lock.unlock()
    }
}

/// `AVAudioEngine` input tap → 16 kHz mono Float32 buffers (the format the
/// transcription pipeline and `SessionAudioRecorder` take).
///
/// `@unchecked Sendable`: the tap runs on the engine's render thread; the
/// converter is only touched there, and start / stop are called on the main
/// actor while no tap is installed or before the tap is removed.
final class MobileMicrophoneCapture: @unchecked Sendable {

    let engine = AVAudioEngine()
    private(set) var isRunning = false
    /// The input format when the tap was installed (main actor only).
    private var startedSampleRate: Double = 0
    private var startedChannelCount: AVAudioChannelCount = 0

    /// Render-thread only (rebuilt when the input format changes, e.g. when
    /// AirPods connect).
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )

    /// Starts the tap. `deliver` and `level` run on the render thread — build
    /// them outside the main actor (see `MobileRecordingController`).
    func start(
        deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        level: @escaping @Sendable (Float) -> Void
    ) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let targetFormat else {
            throw MobileAudioCaptureError.noInput
        }
        converter = nil
        startedSampleRate = format.sampleRate
        startedChannelCount = format.channelCount

        // `format: nil` taps the bus's live format (a stale one right after a
        // route change would throw inside AVFAudio).
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self, buffer.frameLength > 0 else { return }
            level(Self.peak(of: buffer))
            if self.converter == nil || self.converter?.inputFormat != buffer.format {
                self.converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            }
            guard let converter = self.converter,
                  let converted = AudioConversion.convert(buffer, using: converter) else { return }
            deliver(converted)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MobileAudioCaptureError.engineFailed(error.localizedDescription)
        }
        isRunning = true
    }

    /// True when the tap should be rebuilt: the engine stopped (a call, a
    /// reconfiguration) or the input hardware format changed (new route).
    var needsRestart: Bool {
        guard isRunning else { return false }
        if !engine.isRunning { return true }
        let format = engine.inputNode.outputFormat(forBus: 0)
        return format.sampleRate != startedSampleRate || format.channelCount != startedChannelCount
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    /// Linear peak (0…1) of the first channel.
    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        var peak: Float = 0
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<frames {
                let value = abs(channel[index])
                if value > peak { peak = value }
            }
        } else if let channel = buffer.int16ChannelData?[0] {
            for index in 0..<frames {
                let value = abs(Float(channel[index]) / 32_768)
                if value > peak { peak = value }
            }
        }
        return peak
    }
}
