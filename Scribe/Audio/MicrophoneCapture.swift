// `@preconcurrency`: AVFAudio's tap and converter blocks carry imported
// `@Sendable` annotations that don't reflect how they're actually invoked
// (see AudioConversion).
@preconcurrency import AVFoundation
import CoreAudio

// MARK: - Errors

enum MicrophoneCaptureError: LocalizedError {
    case engineStartFailed(underlying: Error)
    case deviceNotFound(AudioDeviceID)
    case noInputAvailable

    var errorDescription: String? {
        switch self {
        case .engineStartFailed(let underlying):
            return "Failed to start audio engine: \(underlying.localizedDescription)"
        case .deviceNotFound(let id):
            return "Audio input device with ID \(id) not found."
        case .noInputAvailable:
            return "No audio input device is available."
        }
    }
}

// MARK: - MicrophoneCapture

/// Captures microphone input using AVAudioEngine, resampling to 16 kHz mono Float32.
///
/// Declared `@unchecked Sendable` so it can be held by a main-actor
/// ``AudioSessionManager`` and still have its tap callbacks run on
/// AVAudioEngine's internal rendering thread without triggering Swift 6
/// sending-risks-data-race diagnostics.
final class MicrophoneCapture: @unchecked Sendable {

    // MARK: - Properties

    private let audioEngine = AVAudioEngine()

    /// Whether the engine is currently capturing audio.
    private(set) var isCapturing = false

    /// The CoreAudio device ID to use for capture. `nil` uses the system
    /// default (unless ``autoDetectActiveInput`` is set).
    var selectedDeviceID: AudioDeviceID?

    /// When `true` and no device is pinned, capture follows the microphone a
    /// call/conferencing app (Teams, Zoom, …) is currently using — i.e. the
    /// input device CoreAudio reports as running somewhere. This is the mic the
    /// user is actually speaking into, which may differ from the system
    /// default. Falls back to the system default when nothing else is in use.
    var autoDetectActiveInput: Bool = false

    /// When `true`, ``startCapture`` turns on Apple's voice processing
    /// (acoustic echo cancellation) on the input node, so audio playing from
    /// the speakers — e.g. the remote side of a call — isn't picked up again
    /// by the mic. Off by default: dictation's separate capture leaves it off.
    /// Takes effect on the next ``startCapture``. Best-effort — if the device
    /// or engine rejects it, capture continues without it.
    var voiceProcessing: Bool = false

    /// Whether voice processing is actually active for the current capture.
    private(set) var isVoiceProcessingActive = false

    /// The CoreAudio device ID the engine is currently capturing from (whatever
    /// was resolved at the last ``startCapture``). Used to avoid counting our
    /// own input usage when detecting which mic a call app is using.
    private(set) var currentCaptureDeviceID: AudioDeviceID?

    /// Called on each captured audio buffer (already resampled to the requested format).
    var onAudioBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    /// Called on each captured *raw hardware* buffer with its linear peak
    /// amplitude (0…1). Computed cheaply in the tap before conversion — the
    /// same value previously only logged for diagnostics. ``AudioSessionManager``
    /// forwards this onto the main actor to drive the live input-level meter.
    /// Fired on AVAudioEngine's render thread, so consumers must hop to their
    /// own actor before touching UI state.
    var onLevel: ((Float) -> Void)?

    /// Called (on the main queue) when the *system default* input device
    /// changes while we are following the default — i.e. ``selectedDeviceID``
    /// is `nil`. The owner should restart capture so the new device is picked
    /// up live. Not fired when the user has pinned a specific device.
    var onDefaultInputDeviceChanged: (() -> Void)?

    /// Backing handle for the default-input-device CoreAudio listener so it can
    /// be removed again in ``stopObservingDefaultInputDevice()``.
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    /// Called (on the main queue) when the set of in-use input devices changes
    /// while ``autoDetectActiveInput`` is on, so the owner can re-resolve and
    /// switch to the mic a call app just started using. Fired on any input
    /// device's running-state change or when devices are added/removed.
    var onActiveInputDeviceChanged: (() -> Void)?

    /// Per-device "is running somewhere" listeners, keyed by device ID, plus the
    /// device-list listener — all removed in ``stopObservingActiveInputDevice()``.
    private var runningListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private var deviceListListener: AudioObjectPropertyListenerBlock?

    // MARK: - Device Enumeration

    /// Returns the list of available audio input devices via CoreAudio.
    func availableInputDevices() -> [(id: AudioDeviceID, name: String)] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        let getStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard getStatus == noErr else { return [] }

        var results: [(id: AudioDeviceID, name: String)] = []
        for deviceID in deviceIDs {
            // Check whether the device has input streams.
            var inputScope = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            let streamStatus = AudioObjectGetPropertyDataSize(deviceID, &inputScope, 0, nil, &streamSize)
            guard streamStatus == noErr, streamSize > 0 else { continue }

            // Get device name.
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            // CoreAudio returns kAudioObjectPropertyName as a +1-retained
            // CFStringRef. Reading it into an `Unmanaged<CFString>?` (a trivial
            // pointer-sized value) avoids forming a raw pointer to a variable
            // that holds an object reference, and `takeRetainedValue()` balances
            // the +1 so the string isn't leaked.
            var nameRef: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let nameStatus = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef)
            guard nameStatus == noErr, let name = nameRef?.takeRetainedValue() else { continue }

            results.append((id: deviceID, name: name as String))
        }
        return results
    }

    /// Select a specific input device by its CoreAudio device ID.
    func selectDevice(id: AudioDeviceID) {
        selectedDeviceID = id
    }

    // MARK: - Capture Control

    /// Starts capturing from the microphone, resampling to the given sample rate as mono Float32.
    ///
    /// - Parameter sampleRate: Target sample rate. Defaults to 16 000 Hz (optimal for Whisper).
    func startCapture(sampleRate: Double = 16000) throws {
        guard !isCapturing else { return }

        // Voice processing swaps the input node's underlying audio unit, so it
        // has to be applied before the device is bound (which talks to that
        // unit) and before the tap/engine start.
        applyVoiceProcessing(voiceProcessing)

        do {
            try bindInputDevice()
        } catch {
            // Voice processing can refuse some devices; retry plainly rather
            // than failing the recording.
            guard isVoiceProcessingActive else { throw error }
            Log.audio.error("Binding the input device failed with echo cancellation on; retrying without it.")
            applyVoiceProcessing(false)
            try bindInputDevice()
        }

        do {
            try installTapAndStart(sampleRate: sampleRate)
        } catch {
            guard isVoiceProcessingActive else { throw error }
            Log.audio.error("Mic capture failed to start with echo cancellation on; retrying without it: \(error.localizedDescription, privacy: .public)")
            applyVoiceProcessing(false)
            try bindInputDevice()
            try installTapAndStart(sampleRate: sampleRate)
        }
    }

    /// Turns voice processing on/off on the input node (engine must be
    /// stopped). Errors are logged and leave it off.
    private func applyVoiceProcessing(_ enabled: Bool) {
        let inputNode = audioEngine.inputNode
        if inputNode.isVoiceProcessingEnabled != enabled {
            do {
                try inputNode.setVoiceProcessingEnabled(enabled)
            } catch {
                Log.audio.error("Couldn't \(enabled ? "enable" : "disable", privacy: .public) echo cancellation: \(error.localizedDescription, privacy: .public)")
            }
        }
        isVoiceProcessingActive = inputNode.isVoiceProcessingEnabled
        if isVoiceProcessingActive {
            // Voice processing ducks (turns down) other audio by default, which
            // would make the call itself quieter. Ask for the minimum.
            var ducking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration()
            ducking.enableAdvancedDucking = false
            ducking.duckingLevel = .min
            inputNode.voiceProcessingOtherAudioDuckingConfiguration = ducking
        }
    }

    /// Resolves and binds the input device for this capture.
    private func bindInputDevice() throws {
        // Resolve and bind the input device. We always set the device
        // explicitly rather than relying on the engine, because the input audio
        // unit latches whatever device was current when it was first
        // instantiated; restarting capture after the device changes only
        // re-points the engine if we set the device ourselves.
        if let deviceID = selectedDeviceID {
            // A user-pinned device is mandatory — failing to select it is a
            // real error.
            try setInputDevice(deviceID)
            currentCaptureDeviceID = deviceID
        } else {
            // Following either the mic a call app is using (auto-detect) or the
            // system default. Both are best-effort: if the device vanished out
            // from under us, fall back to whatever input the engine already has.
            let resolved = (autoDetectActiveInput ? activeInputDeviceID() : nil)
                ?? Self.defaultInputDeviceID()
            if let resolved {
                try? setInputDevice(resolved)
            }
            currentCaptureDeviceID = resolved
        }
    }

    /// Installs the converting tap and starts the engine. On failure the tap
    /// is removed again so a retry starts clean.
    private func installTapAndStart(sampleRate: Double) throws {
        let inputNode = audioEngine.inputNode
        let takeFirstChannelOnly = isVoiceProcessingActive

        // Sanity check that an input is actually available. We deliberately do
        // NOT reuse this format for the tap: immediately after switching the
        // CurrentDevice, `outputFormat(forBus:)` can lag the node's real input
        // format (e.g. report 48 kHz while the new device is natively 32 kHz).
        // Passing that stale format to `installTap` throws an uncaught
        // exception and faults the process. Instead we pass `format: nil`
        // (which always uses the bus's live format) and build the converter
        // lazily from the first buffer's actual format.
        guard inputNode.outputFormat(forBus: 0).sampleRate > 0 else {
            throw MicrophoneCaptureError.noInputAvailable
        }

        // Target format: 16 kHz, mono, Float32.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw MicrophoneCaptureError.noInputAvailable
        }

        // One-shot log of the raw hardware format + first-buffer peak so we
        // can distinguish "mic delivers silence" from "our converter loses
        // the audio". Both symptoms produce 0.0 peaks downstream.
        var diagnosticsPrinted = false
        var rawTapCount = 0

        // Built lazily from the first buffer's real format, and rebuilt if the
        // input format ever changes mid-session (e.g. the user switches mics).
        var converter: AVAudioConverter?

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, time in
            guard let self, let callback = self.onAudioBuffer else { return }

            // Measure the raw hardware buffer's peak before any conversion.
            var rawPeak: Float = 0
            if let ch = buffer.floatChannelData?[0] {
                let n = Int(buffer.frameLength)
                for i in 0..<n { let v = abs(ch[i]); if v > rawPeak { rawPeak = v } }
            } else if let ch = buffer.int16ChannelData?[0] {
                let n = Int(buffer.frameLength)
                for i in 0..<n {
                    let v = abs(Float(ch[i]) / 32768.0)
                    if v > rawPeak { rawPeak = v }
                }
            }

            if !diagnosticsPrinted {
                diagnosticsPrinted = true
                Log.audio.info("Mic hardware tap installed — format: \(String(describing: buffer.format), privacy: .public); first raw buffer peak: \(String(format: "%.4f", rawPeak), privacy: .public)")
            }
            rawTapCount += 1
            if rawTapCount % 100 == 0 {
                Log.audio.debug("Mic raw hardware peak after \(rawTapCount) taps: \(String(format: "%.4f", rawPeak), privacy: .public)")
            }

            // Forward the per-buffer peak so the session manager can drive a
            // smoothed input-level meter. Cheap (a single Float copy) and
            // already computed above — previously this value was only logged.
            self.onLevel?(rawPeak)

            // With voice processing on, the input node can report several
            // channels with the echo-cancelled signal in the first one; feed
            // only that channel so the result isn't diluted by a downmix.
            let source: AVAudioPCMBuffer
            if takeFirstChannelOnly, buffer.format.channelCount > 1,
               let mono = Self.firstChannel(of: buffer) {
                source = mono
            } else {
                source = buffer
            }

            // (Re)build the converter when first seen or when the input format
            // changes under us, so a mid-session mic switch never crashes.
            // Otherwise the same converter is reused so the resampler stays
            // continuous across buffers.
            if converter?.inputFormat != source.format {
                converter = AVAudioConverter(from: source.format, to: targetFormat)
            }
            guard let converter else { return }

            // Hands `source` to the converter exactly once, into an output
            // buffer sized for the rate change (see AudioConversion) — a
            // fixed-size output fed by an always-`.haveData` block re-read the
            // same hardware buffer and duplicated audio.
            guard let convertedBuffer = AudioConversion.convert(source, using: converter) else { return }
            callback(convertedBuffer, time)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw MicrophoneCaptureError.engineStartFailed(underlying: error)
        }
        isCapturing = true
    }

    /// Copies the first channel of a non-interleaved Float32 buffer into a
    /// mono buffer at the same sample rate. Returns nil for other layouts
    /// (the caller then converts the buffer as-is).
    private static func firstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData, !buffer.format.isInterleaved,
              let monoFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: buffer.format.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let destination = mono.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        destination[0].update(from: source[0], count: frames)
        mono.frameLength = buffer.frameLength
        return mono
    }

    /// Clears the record of which device we're capturing, so the next
    /// ``startCapture`` resolves active-input detection against *all* running
    /// devices afresh. Call at the start of a new recording session — but NOT on
    /// a mid-session restart, where the previously-captured device must stay
    /// excluded so detection picks the *other* (call app's) mic.
    func resetCaptureBaseline() {
        currentCaptureDeviceID = nil
    }

    /// Stops capturing and tears down the audio tap.
    func stopCapture() {
        guard isCapturing else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isCapturing = false
    }

    // MARK: - Following the System Default

    /// Starts watching the system default input device. While following the
    /// default (``selectedDeviceID`` is `nil`), a change fires
    /// ``onDefaultInputDeviceChanged`` so the owner can restart capture and
    /// track whatever the user just switched to (e.g. plugging in a headset).
    /// Idempotent.
    func startObservingDefaultInputDevice() {
        guard defaultDeviceListener == nil else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // A default change is only relevant when we're actually following
            // it; if the user pinned a device, leave their choice alone.
            guard self.selectedDeviceID == nil else { return }
            self.onDefaultInputDeviceChanged?()
        }

        var address = Self.defaultInputAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        guard status == noErr else {
            Log.audio.error("Failed to observe default input device (status \(status)).")
            return
        }
        defaultDeviceListener = block
    }

    /// Stops watching the system default input device. Idempotent.
    func stopObservingDefaultInputDevice() {
        guard let block = defaultDeviceListener else { return }
        var address = Self.defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        defaultDeviceListener = nil
    }

    /// CoreAudio address of the system default input device property.
    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// The CoreAudio device ID of the current system default input device, or
    /// `nil` if none is available.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = defaultInputAddress
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    // MARK: - Following the Active Input (mic in use by a call app)

    /// The input device the user is actually speaking into right now: the input
    /// device that is *running somewhere* (held open by another app such as
    /// Teams/Zoom) but is **not** the device we are currently capturing — i.e. a
    /// mic some call app deliberately opened. Returns `nil` when nothing other
    /// than our own capture is in use (caller should then fall back to the
    /// system default).
    ///
    /// This rule is deliberately stable: we only ever switch *to* a running
    /// device other than our own, never away when the set is empty. So when a
    /// call ends (the call app releases its mic) we simply keep recording from
    /// the device we adopted, and when the call app switches mics we follow.
    func activeInputDeviceID() -> AudioDeviceID? {
        let others = runningInputDeviceIDs()
            .subtracting(currentCaptureDeviceID.map { [$0] } ?? [])
        guard !others.isEmpty else { return nil }

        // Prefer a running device that isn't the system default — a call app
        // using the default mic is indistinguishable from "just the default",
        // whereas a running non-default device is a deliberate selection. If
        // several qualify, pick deterministically (lowest ID) to avoid churn.
        let def = Self.defaultInputDeviceID()
        let sorted = others.sorted()
        return sorted.first(where: { $0 != def }) ?? sorted.first
    }

    /// The set of *physical* input devices CoreAudio reports as currently
    /// running somewhere on the system (in use by any process, including us).
    /// Virtual/loopback and aggregate devices are excluded: call apps install
    /// virtual inputs (e.g. "Microsoft Teams Audio") that report as running but
    /// deliver silence, so following one would silently kill capture.
    func runningInputDeviceIDs() -> Set<AudioDeviceID> {
        var running = Set<AudioDeviceID>()
        for device in availableInputDevices()
        where Self.isDeviceRunningSomewhere(device.id) && Self.isPhysicalInputDevice(device.id) {
            running.insert(device.id)
        }
        return running
    }

    /// Whether a device is a real, physical capture source (built-in, USB,
    /// Bluetooth, …) rather than a virtual/loopback or aggregate device. Used to
    /// keep auto-detection from "following" a running-but-silent virtual input.
    private static func isPhysicalInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        guard status == noErr else { return false }
        switch transport {
        case kAudioDeviceTransportTypeVirtual,
             kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate:
            return false
        default:
            return true
        }
    }

    /// Whether a specific device's IO is running anywhere on the system.
    private static func isDeviceRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        var address = runningSomewhereAddress
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
        return status == noErr && isRunning != 0
    }

    private static let runningSomewhereAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Starts watching which input devices are in use so we can follow the mic
    /// a call app starts/stops using. Fires ``onActiveInputDeviceChanged`` on
    /// any change. Idempotent. Also re-syncs listeners when devices are
    /// added/removed (e.g. plugging in a headset).
    func startObservingActiveInputDevice() {
        guard deviceListListener == nil else { return }
        installRunningListeners()

        var address = Self.devicesAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // A new device may have appeared — make sure it's watched too — and
            // the in-use set may have changed.
            self.installRunningListeners()
            self.onActiveInputDeviceChanged?()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        guard status == noErr else {
            Log.audio.error("Failed to observe device list (status \(status)).")
            return
        }
        deviceListListener = block
    }

    /// Stops watching in-use input devices and removes every per-device
    /// listener. Idempotent.
    func stopObservingActiveInputDevice() {
        if let block = deviceListListener {
            var address = Self.devicesAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                block
            )
            deviceListListener = nil
        }
        var address = Self.runningSomewhereAddress
        for (deviceID, block) in runningListeners {
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        }
        runningListeners.removeAll()
    }

    /// Installs an "is running somewhere" listener on each current input device
    /// that isn't already watched. Called on start and whenever the device list
    /// changes.
    private func installRunningListeners() {
        var address = Self.runningSomewhereAddress
        for device in availableInputDevices() where runningListeners[device.id] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.onActiveInputDeviceChanged?()
            }
            let status = AudioObjectAddPropertyListenerBlock(
                device.id,
                &address,
                DispatchQueue.main,
                block
            )
            if status == noErr {
                runningListeners[device.id] = block
            }
        }
    }

    // MARK: - Private Helpers

    /// Sets the CoreAudio aggregate device on the audio engine's input node.
    private func setInputDevice(_ deviceID: AudioDeviceID) throws {
        // Verify the device exists among available inputs.
        let available = availableInputDevices()
        guard available.contains(where: { $0.id == deviceID }) else {
            throw MicrophoneCaptureError.deviceNotFound(deviceID)
        }

        var id = deviceID
        let inputNode = audioEngine.inputNode
        let audioUnit = inputNode.audioUnit!
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw MicrophoneCaptureError.deviceNotFound(deviceID)
        }
    }
}
