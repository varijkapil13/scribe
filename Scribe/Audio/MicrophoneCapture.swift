// AVFAudio's converter-input block is annotated `@Sendable`, but
// `AVAudioConverter.convert` invokes it synchronously on the calling thread —
// there is no real concurrency. `@preconcurrency` strips those imported
// Sendable annotations so capturing the (non-Sendable) source buffer in the
// block is not flagged.
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

    /// The CoreAudio device ID to use for capture. `nil` uses the system default.
    var selectedDeviceID: AudioDeviceID?

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

        // Bind the input device. A user-pinned device is mandatory — failing to
        // select it is a real error. When following the system default we bind
        // explicitly to the *current* default instead of relying on the engine,
        // because the input audio unit latches whatever device was current when
        // it was first instantiated; restarting capture after the default
        // changes only re-points the engine if we set the device ourselves.
        if let deviceID = selectedDeviceID {
            try setInputDevice(deviceID)
        } else if let defaultID = Self.defaultInputDeviceID() {
            // Best-effort: if the default vanished out from under us, fall back
            // to whatever input the engine already has rather than failing.
            try? setInputDevice(defaultID)
        }

        let inputNode = audioEngine.inputNode

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

        let bufferCapacity = AVAudioFrameCount(sampleRate * 0.1) // 100 ms output buffer

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

            // (Re)build the converter when first seen or when the input format
            // changes under us, so a mid-session mic switch never crashes.
            if converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            }
            guard let converter else { return }

            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: bufferCapacity
            ) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error, error == nil, convertedBuffer.frameLength > 0 else { return }
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
