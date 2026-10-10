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
/// files contain exactly the audio the transcript was made from. Each file is
/// kept continuous on the session clock (see ``AudioSessionAlignment``):
/// gaps after a track's first sample — e.g. system audio coming back late
/// after a resume — are filled with silence via ``appendSilence(frames:toMic:)``,
/// and each track's start offset on the session clock is saved as
/// `timing.json` by ``finish(timing:)``. A file position `p` is therefore
/// session position `startOffset + p`, the timeline segment timestamps use.
///
/// Threading: ``appendMic(_:)`` / ``appendSystem(_:)`` are called on the audio
/// render thread / ScreenCaptureKit's sample queue. They only hand the buffer
/// to a private serial queue, which owns every file and does all encoding and
/// disk I/O, so the render thread never blocks on the disk. ``finish()``
/// drains that queue and closes both files; it is idempotent.
///
/// Pause/resume needs nothing special: the files stay open while paused and
/// simply receive no buffers (pauses are not part of the session clock), so
/// resumed audio is appended. Files are created
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

    /// Queues `frames` frames of silence for one track, filling a gap so the
    /// file stays continuous on the session clock. Written in chunks on the
    /// recorder's queue, never on the caller's (audio) thread.
    func appendSilence(frames: Int64, toMic: Bool) {
        guard frames > 0 else { return }
        queue.async { [self] in
            guard !isFinished else { return }
            if toMic {
                micTrack.writeSilence(frames: frames)
            } else {
                systemTrack.writeSilence(frames: frames)
            }
        }
    }

    /// Writes everything queued so far, closes both files and, when given,
    /// saves each track's session-clock start offset as `timing.json`.
    /// Blocks until done (a few ms of encoding at most). Safe to call more
    /// than once; buffers appended afterwards are dropped.
    func finish(timing: SessionAudioTiming? = nil) {
        queue.sync {
            guard !isFinished else { return }
            isFinished = true
            micTrack.close()
            systemTrack.close()
            if let timing, timing.micStartOffsetMs != nil || timing.systemStartOffsetMs != nil {
                do {
                    try timing.write(to: directory)
                } catch {
                    Log.audio.error("Couldn't save session audio timing: \(error.localizedDescription, privacy: .private)")
                }
            }
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

    /// Frames per silence chunk (~1 s at 16 kHz).
    private static let silenceChunkFrames: AVAudioFrameCount = 16_384

    /// Appends `frames` frames of silence (a no-op after an error). Gaps only
    /// ever follow real audio, so the file is normally open already; opening
    /// it here if needed keeps the call order-agnostic.
    func writeSilence(frames: Int64) {
        guard !failed, frames > 0 else { return }
        do {
            let file = try openIfNeeded()
            let format = file.processingFormat
            let chunk = Self.silenceChunkFrames
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
                  let channels = silence.floatChannelData else { return }
            for channel in 0..<Int(format.channelCount) {
                channels[channel].update(repeating: 0, count: Int(chunk))
            }
            var remaining = frames
            while remaining > 0 {
                let count = AVAudioFrameCount(min(Int64(chunk), remaining))
                silence.frameLength = count
                try file.write(from: silence)
                remaining -= Int64(count)
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
        // Deliver-once input + rate-scaled output capacity (AudioConversion).
        return AudioConversion.convert(buffer, using: converter)
    }
}
