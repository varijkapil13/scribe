// See MicrophoneCapture: AVFAudio's converter-input block is `@Sendable`, but
// `AVAudioConverter.convert` runs it synchronously. `@preconcurrency` strips
// the imported Sendable annotations so capturing the source buffer in the
// block is not flagged.
@preconcurrency import AVFoundation

/// Writes a recording session's audio to disk when "Retain raw audio
/// recordings" is on: the microphone and system audio go to separate AAC
/// files (`mic.m4a`, `system.m4a`) in the session's audio folder.
///
/// Fed the same 16 kHz mono Float32 buffers that go to transcription, so the
/// files contain exactly the audio the transcript was made from. Segment
/// timestamps are positions in that fed audio (pauses add nothing to either),
/// so a segment's `startMs` is its position in the file.
///
/// Threading: ``appendMic(_:)`` / ``appendSystem(_:)`` are called on the audio
/// render thread / ScreenCaptureKit's sample queue. They only hand the buffer
/// to a private serial queue, which owns every file and does all encoding and
/// disk I/O, so the render thread never blocks on the disk. ``finish()``
/// drains that queue and closes both files; it is idempotent.
///
/// Pause/resume needs nothing special: the files stay open while paused and
/// simply receive no buffers, so resumed audio is appended. Files are created
/// lazily on their first buffer, so a session without system audio has no
/// `system.m4a`.
final class SessionAudioRecorder: @unchecked Sendable {

    /// The folder this recorder writes into.
    let directory: URL

    private let queue = DispatchQueue(label: "com.varij.scribe.session-audio", qos: .utility)
    // All state below is only touched on `queue`.
    private let micTrack: TrackWriter
    private let systemTrack: TrackWriter
    private var isFinished = false

    /// Creates the recorder and its folder. Never throws: if the folder can't
    /// be created, the track writers log and drop audio instead of failing the
    /// recording.
    init(directory: URL) {
        self.directory = directory
        self.micTrack = TrackWriter(url: SessionAudioStorage.micFileURL(in: directory), label: "mic")
        self.systemTrack = TrackWriter(url: SessionAudioStorage.systemFileURL(in: directory), label: "system")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.audio.error("Couldn't create session audio folder: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Queues a microphone buffer (16 kHz mono Float32) for writing.
    func appendMic(_ buffer: AVAudioPCMBuffer) {
        enqueue(buffer, toMic: true)
    }

    /// Queues a system-audio buffer (16 kHz mono Float32) for writing.
    func appendSystem(_ buffer: AVAudioPCMBuffer) {
        enqueue(buffer, toMic: false)
    }

    /// Writes everything queued so far and closes both files. Blocks until
    /// done (a few ms of encoding at most). Safe to call more than once;
    /// buffers appended afterwards are dropped.
    func finish() {
        queue.sync {
            guard !isFinished else { return }
            isFinished = true
            micTrack.close()
            systemTrack.close()
        }
    }

    // MARK: - Private

    private func enqueue(_ buffer: AVAudioPCMBuffer, toMic: Bool) {
        guard buffer.frameLength > 0 else { return }
        // Capture hands us a freshly allocated buffer per callback that is
        // only ever read afterwards, so passing it across without copying is
        // safe. The box carries it into the `@Sendable` dispatch block.
        let box = BufferBox(buffer)
        queue.async { [self] in
            guard !isFinished else { return }
            if toMic {
                micTrack.write(box.buffer)
            } else {
                systemTrack.write(box.buffer)
            }
        }
    }
}

// MARK: - BufferBox

/// Carries a PCM buffer into a dispatch block. `@unchecked Sendable` because
/// the buffer is never mutated after capture hands it over (see
/// ``SessionAudioRecorder``).
private final class BufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

// MARK: - TrackWriter

/// One AAC file. Only used on ``SessionAudioRecorder``'s serial queue.
private final class TrackWriter {
    private let url: URL
    private let label: String
    private var file: AVAudioFile?
    /// Set after an unrecoverable error so we log once and stop trying.
    private var failed = false
    private var converter: AVAudioConverter?

    init(url: URL, label: String) {
        self.url = url
        self.label = label
    }

    /// AAC, 16 kHz mono — plenty for speech at roughly 1/8 the size of PCM.
    /// Computed (not a stored `static let`) because `[String: Any]` isn't
    /// Sendable.
    static var fileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard !failed else { return }
        do {
            let file = try openIfNeeded()
            let processingFormat = file.processingFormat
            if buffer.format.isEqual(processingFormat) {
                try file.write(from: buffer)
            } else if let converted = convert(buffer, to: processingFormat) {
                try file.write(from: converted)
            }
        } catch {
            failed = true
            Log.audio.error("Stopped writing \(self.label, privacy: .public) audio: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Finalises the file. AVAudioFile writes the AAC container's index and
    /// closes the file when its last reference goes away; this writer holds
    /// the only one, so this completes the file synchronously.
    func close() {
        file = nil
        converter = nil
    }

    private func openIfNeeded() throws -> AVAudioFile {
        if let file { return file }
        let created = try AVAudioFile(
            forWriting: url,
            settings: Self.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        file = created
        return created
    }

    /// Fallback for a buffer that isn't already in the file's processing
    /// format (capture normally delivers exactly 16 kHz mono Float32).
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if converter == nil || !(converter?.inputFormat.isEqual(buffer.format) ?? false) {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter, buffer.format.sampleRate > 0 else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 128
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        final class InputGate: @unchecked Sendable { var delivered = false }
        let gate = InputGate()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if gate.delivered {
                outStatus.pointee = .noDataNow
                return nil
            }
            gate.delivered = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
