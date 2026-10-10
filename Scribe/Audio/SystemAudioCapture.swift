// See AudioConversion: AVFAudio's converter-input block is `@Sendable`, but
// `AVAudioConverter.convert` runs it synchronously. `@preconcurrency` strips
// the imported Sendable annotations.
@preconcurrency import AVFoundation
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
/// Audio is delivered through the ``onAudioBuffer`` callback as 16 kHz mono
/// Float32 buffers, in capture order, on a private serial queue. The
/// `AVAudioTime` passed alongside carries the buffer's start on the host clock
/// so the session can line the remote track up with the microphone.
///
/// Declared `@unchecked Sendable` so it can be used across actor boundaries.
/// Control state (`stream`, `isCapturing`, the output format) is guarded by a
/// lock because ScreenCaptureKit's delegate and output callbacks run on
/// background queues. ``startCapture(sampleRate:)`` / ``stopCapture()`` are
/// not meant to overlap: ``AudioSessionManager`` runs them one at a time.
final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {

    // MARK: - Properties

    /// Guards `_stream`, `_isCapturing`, `_outputFormat` and the callbacks.
    private let stateLock = NSLock()
    private var _stream: SCStream?
    private var _isCapturing = false
    private var _outputFormat: AVAudioFormat?

    /// Serial queue for audio sample delivery, so buffers reach
    /// ``onAudioBuffer`` one at a time and in order (a global concurrent
    /// queue gives neither guarantee). Also the only queue that touches
    /// `converter`.
    private let audioQueue = DispatchQueue(label: "com.varij.scribe.system-audio", qos: .userInitiated)

    /// Long-lived resampler for when ScreenCaptureKit delivers a format other
    /// than the requested one. Only touched on `audioQueue`.
    private var converter: AVAudioConverter?

    /// Whether the capture is currently running.
    var isCapturing: Bool {
        stateLock.withLock { _isCapturing }
    }

    /// Called on each captured audio buffer (16 kHz mono Float32) with the
    /// buffer's start time on the host clock.
    ///
    /// Lock-guarded: the session re-points it from the main actor (on resume
    /// or a mid-session toggle) while a stream that is still stopping may be
    /// reading it on `audioQueue`.
    var onAudioBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)? {
        get { stateLock.withLock { _onAudioBuffer } }
        set { stateLock.withLock { _onAudioBuffer = newValue } }
    }
    private var _onAudioBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    /// Called when the capture stream stops unexpectedly mid-session — most
    /// commonly because the Screen Recording permission was revoked (which
    /// macOS does silently whenever the app binary is rebuilt). Without this,
    /// remote-audio transcription would simply go dead with no signal anywhere.
    /// Invoked on an arbitrary background queue; hop to your actor before
    /// touching UI state. Lock-guarded like ``onAudioBuffer``.
    var onStreamError: ((Error) -> Void)? {
        get { stateLock.withLock { _onStreamError } }
        set { stateLock.withLock { _onStreamError = newValue } }
    }
    private var _onStreamError: ((Error) -> Void)?

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

        // Set the output format before the first buffer can arrive.
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )
        stateLock.withLock { _outputFormat = format }

        let captureStream = SCStream(filter: filter, configuration: config, delegate: self)
        try captureStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        // Register a no-op screen output so SCStream doesn't log an error for
        // every video frame it produces internally.
        try captureStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .utility))
        try await captureStream.startCapture()

        stateLock.withLock {
            _stream = captureStream
            _isCapturing = true
        }
    }

    /// Stops the system audio capture.
    func stopCapture() async {
        // `withLock` (not lock/unlock): this is an async context.
        let captureStream = stateLock.withLock { _isCapturing ? _stream : nil }
        guard let captureStream else { return }
        do {
            try await captureStream.stopCapture()
        } catch {
            // Best-effort stop; the stream may already have been invalidated.
        }
        stateLock.withLock {
            if _stream === captureStream {
                _stream = nil
                _isCapturing = false
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        // Stamp arrival before any conversion work.
        let arrivalHostSeconds = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        guard let callback = onAudioBuffer else { return }

        let outputFormat = stateLock.withLock { _outputFormat }

        guard let source = Self.makePCMBuffer(from: sampleBuffer) else { return }
        let output: AVAudioPCMBuffer
        if let outputFormat, !source.format.isEqual(outputFormat) {
            // Reuse the converter while the formats hold so the resampler
            // stays continuous across buffers.
            let reusable = converter.map {
                $0.inputFormat.isEqual(source.format) && $0.outputFormat.isEqual(outputFormat)
            } ?? false
            if !reusable {
                converter = AVAudioConverter(from: source.format, to: outputFormat)
            }
            guard let converter, let converted = AudioConversion.convert(source, using: converter) else { return }
            output = converted
        } else {
            output = source
        }

        let startSeconds = Self.startHostSeconds(
            presentationSeconds: Self.presentationSeconds(of: sampleBuffer),
            arrivalHostSeconds: arrivalHostSeconds,
            durationSeconds: Double(source.frameLength) / max(source.format.sampleRate, 1)
        )
        let time = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: max(0, startSeconds)))
        callback(output, time)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Ignore a late error from a stream we already replaced or stopped.
        let isCurrent = stateLock.withLock { () -> Bool in
            guard _stream === stream else { return false }
            _isCapturing = false
            _stream = nil
            return true
        }
        guard isCurrent else { return }
        Log.audio.error("System audio stream stopped unexpectedly: \(error.localizedDescription, privacy: .public)")
        onStreamError?(error)
    }

    // MARK: - Timing

    /// The sample buffer's presentation time in seconds, or `nil` when it has
    /// none. ScreenCaptureKit stamps audio on the host clock; that is checked
    /// (not assumed) by ``startHostSeconds(presentationSeconds:arrivalHostSeconds:durationSeconds:)``.
    private static func presentationSeconds(of sampleBuffer: CMSampleBuffer) -> Double? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric else { return nil }
        return pts.seconds
    }

    /// Largest gap between a buffer's presentation time and its arrival for
    /// the presentation time to be trusted as host-clock seconds.
    static let maxPresentationSkewSeconds: Double = 5

    /// Best estimate of when a buffer's first sample was captured, in host
    /// clock seconds. Uses the presentation time when it is plausibly on the
    /// host clock (within ``maxPresentationSkewSeconds`` before arrival);
    /// otherwise assumes the buffer's last sample was captured just before it
    /// arrived (`arrival − duration`).
    static func startHostSeconds(
        presentationSeconds: Double?,
        arrivalHostSeconds: Double,
        durationSeconds: Double
    ) -> Double {
        if let presentationSeconds,
           presentationSeconds.isFinite,
           presentationSeconds <= arrivalHostSeconds,
           arrivalHostSeconds - presentationSeconds <= maxPresentationSkewSeconds {
            return presentationSeconds
        }
        return arrivalHostSeconds - max(0, durationSeconds)
    }

    // MARK: - Sample Buffer Conversion

    /// Copies a `CMSampleBuffer` (from ScreenCaptureKit) into an
    /// `AVAudioPCMBuffer` in the sample buffer's own format.
    ///
    /// Returns `nil` if the buffer contains no audio samples or can't be read.
    static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = sampleBuffer.formatDescription,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let sourceFormat = AVAudioFormat(streamDescription: streamDescription) else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
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
        } else if let int16Data = pcmBuffer.int16ChannelData {
            memcpy(int16Data[0], dataPointer, min(lengthOut, Int(pcmBuffer.frameLength) * MemoryLayout<Int16>.size))
        } else {
            return nil
        }
        return pcmBuffer
    }
}
