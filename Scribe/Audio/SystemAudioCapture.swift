import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

// MARK: - Errors

enum SystemAudioCaptureError: LocalizedError {
    case permissionDenied
    case noDisplayFound
    case streamCreationFailed
    case bufferConversionFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen capture permission is required to capture system audio."
        case .noDisplayFound:
            return "No display found for system audio capture."
        case .streamCreationFailed:
            return "Failed to create the system audio capture stream."
        case .bufferConversionFailed:
            return "Failed to convert the captured audio sample buffer."
        }
    }
}

// MARK: - SystemAudioCapture

/// Captures system / desktop audio using ScreenCaptureKit (macOS 13+).
///
/// Audio is delivered through the ``onAudioBuffer`` callback as 16 kHz mono Float32 buffers.
///
/// Declared `@unchecked Sendable` so it can be used across actor boundaries.
/// Callers are expected to configure the capture from a single actor and the
/// SCStreamOutput callbacks run on a dedicated serial queue supplied at
/// `addStreamOutput` time.
final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {

    // MARK: - Properties

    private var stream: SCStream?

    /// Whether the capture is currently running.
    private(set) var isCapturing = false

    /// Called on each captured audio buffer (16 kHz mono Float32).
    var onAudioBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    /// The audio format used for output delivery.
    private var outputFormat: AVAudioFormat?

    // MARK: - Permission

    /// Checks whether the app has permission to capture screen content (which
    /// includes system audio). Uses CoreGraphics' TCC preflight — the same
    /// signal ScreenCaptureKit consults — and never triggers a prompt or I/O.
    func checkPermission() async -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    // MARK: - Capture Control

    /// Starts capturing system audio at the given sample rate.
    ///
    /// - Parameter sampleRate: Target sample rate. Defaults to 16 000 Hz.
    func startCapture(sampleRate: Double = 16000) async throws {
        guard !isCapturing else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplayFound
        }

        // Filter: capture the entire display but exclude this app's own windows.
        let excludedWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        // Configure the stream for audio-focused capture. We can't fully
        // disable video, but we can throttle it to near-zero cost and drop the
        // frames with a no-op output so the framework doesn't spam
        // "stream output NOT found" for every dropped frame.
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.capturesAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = 1
        // Effectively 1 frame per minute — we discard them anyway.
        config.minimumFrameInterval = CMTime(seconds: 60, preferredTimescale: 600)

        let captureStream = SCStream(filter: filter, configuration: config, delegate: self)
        try captureStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        // Register a no-op screen output so SCStream doesn't log an error for
        // every video frame it produces internally.
        try captureStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .utility))
        try await captureStream.startCapture()

        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )

        stream = captureStream
        isCapturing = true
    }

    /// Stops the system audio capture.
    func stopCapture() async {
        guard isCapturing, let captureStream = stream else { return }
        do {
            try await captureStream.stopCapture()
        } catch {
            // Best-effort stop; the stream may already have been invalidated.
        }
        stream = nil
        isCapturing = false
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let callback = onAudioBuffer else { return }
        guard let pcmBuffer = Self.convertToPCMBuffer(sampleBuffer: sampleBuffer, outputFormat: outputFormat) else {
            return
        }
        let time = AVAudioTime(sampleTime: 0, atRate: pcmBuffer.format.sampleRate)
        callback(pcmBuffer, time)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isCapturing = false
        self.stream = nil
    }

    // MARK: - Sample Buffer Conversion

    /// Converts a `CMSampleBuffer` (from ScreenCaptureKit) into an `AVAudioPCMBuffer`.
    ///
    /// Returns `nil` if the conversion fails or the buffer contains no audio samples.
    static func convertToPCMBuffer(sampleBuffer: CMSampleBuffer, outputFormat: AVAudioFormat?) -> AVAudioPCMBuffer? {
        guard let formatDescription = sampleBuffer.formatDescription,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let sourceFormat = AVAudioFormat(streamDescription: streamDescription)

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0, let sourceFormat else { return nil }

        // If we have a target output format and it differs from the source, convert.
        if let outputFormat, sourceFormat != outputFormat {
            // First create a buffer in the source format.
            guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
                return nil
            }
            sourceBuffer.frameLength = AVAudioFrameCount(frameCount)

            // Copy sample data into the source buffer.
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
            var lengthOut = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &lengthOut, dataPointerOut: &dataPointer)
            guard status == kCMBlockBufferNoErr, let dataPointer else { return nil }

            if let floatData = sourceBuffer.floatChannelData {
                memcpy(floatData[0], dataPointer, min(lengthOut, Int(sourceBuffer.frameLength) * MemoryLayout<Float>.size))
            } else if let int16Data = sourceBuffer.int16ChannelData {
                memcpy(int16Data[0], dataPointer, min(lengthOut, Int(sourceBuffer.frameLength) * MemoryLayout<Int16>.size))
            }

            // Convert to target format.
            guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else { return nil }
            let ratio = outputFormat.sampleRate / sourceFormat.sampleRate
            let convertedCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 1
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: convertedCapacity) else {
                return nil
            }

            var error: NSError?
            var consumed = false
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = AVAudioConverterInputStatus.noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = AVAudioConverterInputStatus.haveData
                return sourceBuffer
            }
            guard error == nil, convertedBuffer.frameLength > 0 else { return nil }
            return convertedBuffer
        }

        // Source format matches target (or no target specified) -- wrap directly.
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var lengthOut = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &lengthOut, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let dataPointer else { return nil }

        if let floatData = pcmBuffer.floatChannelData {
            memcpy(floatData[0], dataPointer, min(lengthOut, Int(pcmBuffer.frameLength) * MemoryLayout<Float>.size))
        }

        return pcmBuffer
    }
}
