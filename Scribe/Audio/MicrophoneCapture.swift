import AVFoundation
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
            var nameRef: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            let nameStatus = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef)
            guard nameStatus == noErr else { continue }

            results.append((id: deviceID, name: nameRef as String))
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

        // Apply selected device if specified.
        if let deviceID = selectedDeviceID {
            try setInputDevice(deviceID)
        }

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0 else {
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

        // Create a converter from the hardware format to the target format.
        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw MicrophoneCaptureError.noInputAvailable
        }

        let bufferCapacity = AVAudioFrameCount(sampleRate * 0.1) // 100 ms output buffer

        // One-shot log of the raw hardware format + first-buffer peak so we
        // can distinguish "mic delivers silence" from "our converter loses
        // the audio". Both symptoms produce 0.0 peaks downstream.
        var diagnosticsPrinted = false
        var rawTapCount = 0

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, time in
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
                print("[MicrophoneCapture] Hardware tap installed — format: \(hardwareFormat); first raw buffer peak: \(String(format: "%.4f", rawPeak))")
            }
            rawTapCount += 1
            if rawTapCount % 100 == 0 {
                print("[MicrophoneCapture] Raw hardware peak after \(rawTapCount) taps: \(String(format: "%.4f", rawPeak))")
            }

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
