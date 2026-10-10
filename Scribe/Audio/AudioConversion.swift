// AVFAudio's converter-input block is annotated `@Sendable`, but
// `AVAudioConverter.convert` invokes it synchronously on the calling thread —
// there is no real concurrency. `@preconcurrency` strips those imported
// Sendable annotations so capturing the (non-Sendable) source buffer in the
// block is not flagged.
@preconcurrency import AVFoundation

/// Feeds one capture buffer through a long-lived `AVAudioConverter`.
///
/// Two rules every converter use in Scribe must follow:
///
/// 1. **Hand the input over exactly once.** The input block is called until
///    the output buffer is full or the block reports no data. A block that
///    always answers `.haveData` with the same buffer makes the converter
///    re-read it, duplicating audio (the old mic resampler did this: a fixed
///    100 ms output buffer fed from ~85 ms hardware buffers repeated ~15 ms
///    of every buffer). After the first hand-over the block answers
///    `.noDataNow`, which keeps the converter's resampler state for the next
///    buffer of the same stream.
/// 2. **Size the output for the rate change.** `ceil(inFrames × outRate /
///    inRate)` plus headroom for whatever the resampler held back from the
///    previous buffer, so one input buffer never needs two output buffers.
enum AudioConversion {

    /// Extra output frames beyond the exact rate-converted length: room for
    /// samples the resampler carried over from the previous buffer.
    static let outputHeadroomFrames: AVAudioFrameCount = 256

    /// Output frame capacity for converting `inputFrames` frames from
    /// `inputRate` to `outputRate`: `ceil(inputFrames × outputRate /
    /// inputRate) + headroom`. Falls back to `inputFrames + headroom` for a
    /// nonsensical (zero/negative) rate.
    static func outputCapacity(
        inputFrames: AVAudioFrameCount,
        inputRate: Double,
        outputRate: Double,
        headroom: AVAudioFrameCount = outputHeadroomFrames
    ) -> AVAudioFrameCount {
        guard inputRate > 0, outputRate > 0 else { return inputFrames &+ headroom }
        let scaled = (Double(inputFrames) * outputRate / inputRate).rounded(.up)
        let limit = Double(AVAudioFrameCount.max - headroom)
        return AVAudioFrameCount(min(scaled, limit)) + headroom
    }

    /// Converts `buffer` with `converter`, handing the buffer to the
    /// converter exactly once. Reuse the same converter for consecutive
    /// buffers of one stream so the resampler stays continuous. Returns `nil`
    /// on error or when the converter produced nothing yet (it may hold a
    /// few frames back until the next buffer).
    static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let outputFormat = converter.outputFormat
        let capacity = outputCapacity(
            inputFrames: buffer.frameLength,
            inputRate: buffer.format.sampleRate,
            outputRate: outputFormat.sampleRate
        )
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        // A class flag mutated through a `let` binding (rather than a captured
        // `var`) avoids the captured-var-mutation diagnostic. `@unchecked
        // Sendable` is sound: `convert` runs the block synchronously on this
        // thread, so the gate never crosses a concurrency boundary.
        let gate = ConverterInputGate()
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

/// Deliver-once flag for an `AVAudioConverter` input block (see
/// ``AudioConversion``).
final class ConverterInputGate: @unchecked Sendable {
    var delivered = false
}
