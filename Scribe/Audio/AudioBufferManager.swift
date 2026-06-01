import Foundation

/// Accumulates PCM audio samples and emits fixed-duration chunks suitable for transcription.
///
/// Each chunk contains ``chunkDurationSeconds`` worth of audio. When a chunk is emitted the last
/// ``overlapDurationSeconds`` of samples are kept so consecutive chunks share a small overlap,
/// which helps the transcription model maintain context across boundaries.
final class AudioBufferManager: @unchecked Sendable {

    // MARK: - Configuration

    /// Sample rate of incoming audio (samples per second).
    let sampleRate: Int

    /// Duration of each emitted chunk in seconds.
    let chunkDurationSeconds: Double

    /// Duration of overlap between consecutive chunks in seconds.
    let overlapDurationSeconds: Double

    /// Called when a full chunk is ready for transcription.
    ///
    /// Parameters are `(samples, speaker)` where `speaker` is `"you"` for mic audio
    /// and `"remote"` for system audio.
    var onChunkReady: ((_ samples: [Float], _ speaker: String) -> Void)?

    /// Called on each appended batch of system-audio samples with their linear
    /// peak amplitude (0…1). Mirrors ``MicrophoneCapture/onLevel`` for the
    /// remote source so the live meter can visualize *you* vs *remote*.
    /// Invoked on whatever thread feeds samples in, so consumers must hop to
    /// their own actor before touching UI state.
    var onSystemLevel: ((Float) -> Void)?

    // MARK: - Private Buffers

    private var micBuffer: [Float] = []
    private var systemBuffer: [Float] = []
    private let lock = NSLock()

    // MARK: - Init

    /// Creates a new buffer manager.
    ///
    /// - Parameters:
    ///   - sampleRate: Expected sample rate. Defaults to 16 000 Hz.
    ///   - chunkDurationSeconds: Length of each emitted chunk. Defaults to 5.0 s.
    ///   - overlapDurationSeconds: Overlap between consecutive chunks. Defaults to 1.0 s.
    init(sampleRate: Int = 16000, chunkDurationSeconds: Double = 5.0, overlapDurationSeconds: Double = 1.0) {
        self.sampleRate = sampleRate
        self.chunkDurationSeconds = chunkDurationSeconds
        self.overlapDurationSeconds = overlapDurationSeconds
    }

    // MARK: - Public Interface

    /// Appends microphone samples (labeled as `"you"`).
    func appendMicSamples(_ samples: [Float]) {
        lock.lock()
        micBuffer.append(contentsOf: samples)
        checkAndEmitChunk(buffer: &micBuffer, speaker: "you")
        lock.unlock()
    }

    /// Appends system audio samples (labeled as `"remote"`).
    func appendSystemSamples(_ samples: [Float]) {
        let peak = Self.peak(of: samples)
        lock.lock()
        systemBuffer.append(contentsOf: samples)
        checkAndEmitChunk(buffer: &systemBuffer, speaker: "remote")
        lock.unlock()
        // Report peak outside the lock so a slow consumer can't stall the
        // audio feed.
        if let onSystemLevel { onSystemLevel(peak) }
    }

    /// Linear peak amplitude (0…1) of a sample batch.
    private static func peak(of samples: [Float]) -> Float {
        var peak: Float = 0
        for s in samples {
            let v = abs(s)
            if v > peak { peak = v }
        }
        return peak
    }

    /// Clears all accumulated samples.
    func reset() {
        lock.lock()
        micBuffer.removeAll(keepingCapacity: true)
        systemBuffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    // MARK: - Private

    /// If `buffer` has accumulated enough samples for a full chunk, emit it and retain the overlap.
    private func checkAndEmitChunk(buffer: inout [Float], speaker: String) {
        let chunkSampleCount = Int(chunkDurationSeconds * Double(sampleRate))
        let overlapSampleCount = Int(overlapDurationSeconds * Double(sampleRate))

        while buffer.count >= chunkSampleCount {
            let chunk = Array(buffer.prefix(chunkSampleCount))
            onChunkReady?(chunk, speaker)

            // Keep the last `overlapSampleCount` samples for context continuity.
            let dropCount = chunkSampleCount - overlapSampleCount
            buffer.removeFirst(max(dropCount, 0))
        }
    }
}
