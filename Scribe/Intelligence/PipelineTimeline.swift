import Foundation

// MARK: - Generation token

/// Monotonic token that lets an async start notice it has been superseded.
///
/// `SpeechRecognizerEngine.startSession` awaits model installation and
/// analyzer start-up. If `stopSession` (or another start / language switch)
/// runs meanwhile, the in-flight start must not install its pipelines
/// afterwards. Every start and stop advances the generation; a start keeps
/// the token it got and checks it after each await.
struct SessionGeneration: Equatable, Sendable {

    private(set) var current: UInt64 = 0

    /// Invalidates every outstanding token and returns a fresh one.
    @discardableResult
    mutating func advance() -> UInt64 {
        current &+= 1
        return current
    }

    /// Whether `token` is still the latest one.
    func isCurrent(_ token: UInt64) -> Bool {
        token == current
    }
}

// MARK: - Audio ledger

/// Per-source bookkeeping that keeps transcript timestamps continuous across
/// a pipeline swap (e.g. switching language mid-recording) and keeps audio
/// that arrives while the new pipeline spins up.
///
/// `SpeechAnalyzer` timestamps results relative to the first buffer it was
/// fed, so a fresh pipeline starts at 0. The ledger counts how much audio the
/// engine has received for its source this session; when a new pipeline goes
/// live, its base offset is the session time of the first buffer it will see.
///
/// While `isHolding`, received buffers are queued (bounded by
/// `maxHeldSeconds`, oldest dropped first) and handed to the new pipeline
/// when holding ends. Generic over the buffer type so tests can use plain
/// values.
struct AudioSwapLedger<Buffer> {

    /// Upper bound on queued audio. Older audio beyond this is dropped; the
    /// base offset still accounts for it, so timestamps stay correct.
    let maxHeldSeconds: Double

    /// Seconds of audio received for this source since the session started
    /// (fed, held or dropped).
    private(set) var receivedSeconds: Double = 0

    /// Whether incoming audio is currently being held for a pipeline that
    /// isn't live yet.
    private(set) var isHolding = false

    private var held: [(buffer: Buffer, seconds: Double)] = []

    /// Seconds of audio currently held.
    private(set) var heldSeconds: Double = 0

    init(maxHeldSeconds: Double = 60) {
        self.maxHeldSeconds = maxHeldSeconds
    }

    /// Number of buffers currently held.
    var heldCount: Int { held.count }

    /// Records a received buffer. Returns `true` when the caller should feed it
    /// to the live pipeline right away, `false` when it was held instead.
    mutating func receive(_ buffer: Buffer, seconds: Double) -> Bool {
        let duration = max(0, seconds)
        receivedSeconds += duration
        guard isHolding else { return true }
        held.append((buffer, duration))
        heldSeconds += duration
        while heldSeconds > maxHeldSeconds, !held.isEmpty {
            let dropped = held.removeFirst()
            heldSeconds -= dropped.seconds
        }
        if held.isEmpty { heldSeconds = 0 }
        return false
    }

    /// Starts holding incoming audio. Idempotent: a second call while already
    /// holding keeps what is queued.
    mutating func beginHolding() {
        guard !isHolding else { return }
        isHolding = true
        held = []
        heldSeconds = 0
    }

    /// Stops holding and returns what the new pipeline needs: the session
    /// offset (in milliseconds) of the first buffer it will be fed, and the
    /// held buffers to feed it first, in order.
    mutating func endHolding() -> (baseOffsetMs: Int, buffers: [Buffer]) {
        let baseSeconds = max(0, receivedSeconds - heldSeconds)
        let buffers = held.map { $0.buffer }
        held = []
        heldSeconds = 0
        isHolding = false
        return (Self.milliseconds(baseSeconds), buffers)
    }

    /// Drops held audio without ending the session timeline.
    mutating func discardHeld() {
        held = []
        heldSeconds = 0
        isHolding = false
    }

    /// Forgets everything (new session).
    mutating func reset() {
        discardHeld()
        receivedSeconds = 0
    }

    static func milliseconds(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds * 1000).rounded())
    }
}

// MARK: - Offsets

enum PipelineTimestamps {

    /// Converts an analyzer result range (seconds since the pipeline's first
    /// buffer) into session-relative milliseconds by adding the pipeline's
    /// base offset.
    nonisolated static func sessionOffsets(
        rangeStartSeconds: Double,
        rangeEndSeconds: Double,
        baseOffsetMs: Int
    ) -> (startMs: Int, endMs: Int) {
        let base = max(0, baseOffsetMs)
        let start = rangeStartSeconds.isFinite ? max(0, Int(rangeStartSeconds * 1000)) : 0
        let end = rangeEndSeconds.isFinite ? max(start, Int(rangeEndSeconds * 1000)) : start
        return (base + start, base + end)
    }
}
