import Foundation

// MARK: - Overview
//
// A recording has two capture tracks that start at different moments: the
// mic comes up within ~100 ms, while ScreenCaptureKit's system-audio stream
// starts hundreds of ms later — and late again after every resume, or
// whenever system audio is switched on mid-session. Each track's
// transcription pipeline only sees the audio it was fed, so its timestamps
// drift from the other track's by those start-up delays.
//
// Everything here lines both tracks up on one **session clock**: host-clock
// seconds since recording started, with paused time removed (the same notion
// of "elapsed" the live duration shows).
//
// - Each track records the session-clock position of its first sample — its
//   *start offset*. The leading offset is never written into the audio files;
//   it is persisted in `timing.json` (``SessionAudioTiming``) so playback and
//   diarization can place each file on the session clock.
// - Later gaps (resume start-up, a mid-session restart, the stream skipping)
//   are *padded*: silence is written into the track's file so the file stays
//   continuous on the session clock, and an anchor is recorded so positions
//   in the transcription pipeline's (unpadded) audio can be mapped onto the
//   session clock.
//
// All of it is pure value logic (unit-tested); ``AudioStreamAligner`` adds a
// lock so the audio threads and the main actor can share one instance.

// MARK: - SessionClock

/// Host-clock time with paused stretches removed.
struct SessionClock: Equatable, Sendable {
    /// Active seconds accumulated by runs that have ended (i.e. before the
    /// last pause).
    private(set) var accumulatedSeconds: Double = 0
    /// Host-clock seconds at which the current run began; `nil` while paused
    /// or before the session started.
    private(set) var runStartHostSeconds: Double?

    var isRunning: Bool { runStartHostSeconds != nil }

    /// Starts (or resumes) the clock. No-op while already running.
    mutating func beginRun(atHostSeconds hostSeconds: Double) {
        guard runStartHostSeconds == nil else { return }
        runStartHostSeconds = hostSeconds
    }

    /// Pauses the clock. No-op while not running.
    mutating func endRun(atHostSeconds hostSeconds: Double) {
        guard let start = runStartHostSeconds else { return }
        accumulatedSeconds += max(0, hostSeconds - start)
        runStartHostSeconds = nil
    }

    /// Session-clock seconds at a host-clock instant. While paused (or for an
    /// instant before the current run began) the clock reads the time
    /// accumulated so far.
    func sessionSeconds(atHostSeconds hostSeconds: Double) -> Double {
        guard let start = runStartHostSeconds else { return accumulatedSeconds }
        return accumulatedSeconds + max(0, hostSeconds - start)
    }
}

// MARK: - AudioTrackTimeline

/// Where one capture track's audio sits on the session clock.
///
/// Positions are in frames at the capture sample rate. *Track* frames count
/// only real captured audio — exactly what the track's transcription pipeline
/// was fed. *Session* frames are positions on the session clock. Each anchor
/// says "track frame `trackFrame` is session frame `sessionFrame`"; frames
/// after it follow one-to-one until the next anchor.
struct AudioTrackTimeline: Equatable, Sendable {

    struct Anchor: Equatable, Sendable {
        let trackFrame: Int64
        let sessionFrame: Int64
    }

    /// Ascending in both `trackFrame` and `sessionFrame`. Empty until the
    /// first buffer is placed.
    private(set) var anchors: [Anchor] = []

    /// Real frames placed so far.
    private(set) var fedFrames: Int64 = 0

    /// Silence frames requested so far to fill gaps (written into the
    /// track's file, never fed to transcription).
    private(set) var paddedFrames: Int64 = 0

    /// Session position of the track's first frame.
    var startOffsetFrames: Int64? { anchors.first?.sessionFrame }

    /// Session position the next placed frame would land on, without padding.
    var nextSessionFrame: Int64? {
        guard let last = anchors.last else { return nil }
        return last.sessionFrame + (fedFrames - last.trackFrame)
    }

    /// Places a buffer of `frameCount` frames whose first sample was
    /// captured at session position `expectedSessionFrame`.
    ///
    /// The first buffer only fixes the start offset. After that, if the
    /// buffer is late by more than `tolerance` frames, the gap is padded:
    /// the returned number of silence frames (capped at `maxGap`) must be
    /// written to the track's file just before this buffer. A buffer that is
    /// early (the track ran ahead, e.g. a few buffers trickled in after a
    /// pause) is placed as-is; the next gap absorbs the difference.
    ///
    /// - Returns: Silence frames to insert before this buffer (0 for none).
    mutating func place(
        frameCount: Int64,
        expectedSessionFrame: Int64,
        tolerance: Int64,
        maxGap: Int64
    ) -> Int64 {
        guard frameCount > 0 else { return 0 }
        let expected = max(0, expectedSessionFrame)
        guard let next = nextSessionFrame else {
            anchors.append(Anchor(trackFrame: 0, sessionFrame: expected))
            fedFrames = frameCount
            return 0
        }
        var gap: Int64 = 0
        let lateness = expected - next
        if lateness > max(0, tolerance) {
            gap = min(lateness, max(0, maxGap))
            if gap > 0 {
                anchors.append(Anchor(trackFrame: fedFrames, sessionFrame: next + gap))
                paddedFrames += gap
            }
        }
        fedFrames += frameCount
        return gap
    }

    /// Maps a position in the track's (unpadded) audio to the session clock.
    /// Before any audio was placed this is the identity.
    func sessionFrame(forTrackFrame trackFrame: Int64) -> Int64 {
        guard var anchor = anchors.first else { return trackFrame }
        for candidate in anchors.dropFirst() {
            guard candidate.trackFrame <= trackFrame else { break }
            anchor = candidate
        }
        return anchor.sessionFrame + (trackFrame - anchor.trackFrame)
    }
}

// MARK: - AudioSessionAlignment

/// Both capture tracks of one recording on one ``SessionClock``.
struct AudioSessionAlignment: Equatable, Sendable {

    enum Track: Hashable, Sendable {
        case mic
        case system
    }

    /// Frames per second of the placed buffers (the capture rate).
    let sampleRate: Double
    /// Lateness tolerated in steady state before a gap is padded. Generous so
    /// timestamp jitter never chops silence into the audio; a real stall
    /// (the stream skipping) is far longer.
    let steadyToleranceFrames: Int64
    /// Lateness tolerated on a track's first buffer after it (re)started —
    /// where a start-up delay is expected and should be measured precisely.
    let restartToleranceFrames: Int64
    /// Upper bound on one padded gap, so a bogus timestamp can't request
    /// hours of silence.
    let maxGapFrames: Int64

    private(set) var clock = SessionClock()
    private(set) var mic = AudioTrackTimeline()
    private(set) var system = AudioTrackTimeline()
    /// Tracks whose next buffer is the first since they (re)started.
    private var restarting: Set<Track> = []

    init(
        sampleRate: Double = 16_000,
        steadyToleranceSeconds: Double = 0.5,
        restartToleranceSeconds: Double = 0.02,
        maxGapSeconds: Double = 6 * 3600
    ) {
        self.sampleRate = sampleRate
        self.steadyToleranceFrames = Int64((steadyToleranceSeconds * sampleRate).rounded())
        self.restartToleranceFrames = Int64((restartToleranceSeconds * sampleRate).rounded())
        self.maxGapFrames = Int64((maxGapSeconds * sampleRate).rounded())
    }

    func timeline(_ track: Track) -> AudioTrackTimeline {
        switch track {
        case .mic: return mic
        case .system: return system
        }
    }

    /// Recording started or resumed: the clock runs and the mic's next buffer
    /// measures its start-up delay. (System audio is marked separately, when
    /// its stream actually (re)starts — see ``trackWillStart(_:)``.)
    mutating func beginRun(atHostSeconds hostSeconds: Double) {
        clock.beginRun(atHostSeconds: hostSeconds)
        restarting.insert(.mic)
    }

    /// Recording paused.
    mutating func endRun(atHostSeconds hostSeconds: Double) {
        clock.endRun(atHostSeconds: hostSeconds)
    }

    /// The track's capture is about to (re)start mid-session, so its next
    /// buffer's lateness is a start-up delay to pad precisely.
    mutating func trackWillStart(_ track: Track) {
        restarting.insert(track)
    }

    /// Places a captured buffer whose first sample was captured at
    /// `startHostSeconds` (host clock).
    ///
    /// - Returns: Silence frames to write to the track's file before it.
    mutating func place(_ track: Track, frameCount: Int64, startHostSeconds: Double) -> Int64 {
        guard frameCount > 0 else { return 0 }
        let expected = Int64((clock.sessionSeconds(atHostSeconds: startHostSeconds) * sampleRate).rounded())
        let tolerance = restarting.remove(track) != nil ? restartToleranceFrames : steadyToleranceFrames
        switch track {
        case .mic:
            return mic.place(frameCount: frameCount, expectedSessionFrame: expected,
                             tolerance: tolerance, maxGap: maxGapFrames)
        case .system:
            return system.place(frameCount: frameCount, expectedSessionFrame: expected,
                                tolerance: tolerance, maxGap: maxGapFrames)
        }
    }

    /// Maps a timestamp from a track's transcription pipeline (milliseconds
    /// into the audio it was fed) to milliseconds on the session clock.
    func sessionMs(forTrackMs trackMs: Int, track: Track) -> Int {
        let frame = Int64((Double(trackMs) * sampleRate / 1000).rounded())
        let mapped = timeline(track).sessionFrame(forTrackFrame: frame)
        return Int((Double(mapped) * 1000 / sampleRate).rounded())
    }

    /// Session-clock position of a track's first sample, in milliseconds, or
    /// `nil` if the track captured nothing.
    func startOffsetMs(_ track: Track) -> Int? {
        timeline(track).startOffsetFrames.map { Int((Double($0) * 1000 / sampleRate).rounded()) }
    }

    /// What gets persisted next to the audio files.
    var timing: SessionAudioTiming {
        SessionAudioTiming(micStartOffsetMs: startOffsetMs(.mic), systemStartOffsetMs: startOffsetMs(.system))
    }
}

// MARK: - AudioStreamAligner

/// Thread-safe ``AudioSessionAlignment``: the mic tap thread and the
/// ScreenCaptureKit sample queue place buffers while the main actor drives
/// the clock and maps transcript timestamps.
final class AudioStreamAligner: @unchecked Sendable {
    private let lock = NSLock()
    private var state: AudioSessionAlignment

    /// Frames per second of placed buffers. Immutable, so readable without
    /// the lock.
    let sampleRate: Double

    init(sampleRate: Double = 16_000) {
        self.sampleRate = sampleRate
        state = AudioSessionAlignment(sampleRate: sampleRate)
    }

    /// Forgets the previous recording.
    func reset() {
        lock.lock()
        state = AudioSessionAlignment(sampleRate: sampleRate)
        lock.unlock()
    }

    func beginRun(atHostSeconds hostSeconds: Double) {
        lock.lock()
        state.beginRun(atHostSeconds: hostSeconds)
        lock.unlock()
    }

    func endRun(atHostSeconds hostSeconds: Double) {
        lock.lock()
        state.endRun(atHostSeconds: hostSeconds)
        lock.unlock()
    }

    func trackWillStart(_ track: AudioSessionAlignment.Track) {
        lock.lock()
        state.trackWillStart(track)
        lock.unlock()
    }

    /// See ``AudioSessionAlignment/place(_:frameCount:startHostSeconds:)``.
    func place(_ track: AudioSessionAlignment.Track, frameCount: Int64, startHostSeconds: Double) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return state.place(track, frameCount: frameCount, startHostSeconds: startHostSeconds)
    }

    func sessionMs(forTrackMs trackMs: Int, track: AudioSessionAlignment.Track) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return state.sessionMs(forTrackMs: trackMs, track: track)
    }

    var timing: SessionAudioTiming {
        lock.lock()
        defer { lock.unlock() }
        return state.timing
    }
}

// MARK: - SessionAudioTiming

/// Where each retained audio file starts on the session clock, persisted as
/// `timing.json` beside `mic.m4a` / `system.m4a`.
///
/// Gaps after a track's first sample are already silence in its file, so a
/// file position `p` is session position `startOffset + p`. Sessions recorded
/// before this file existed have none; their tracks are treated as starting
/// at 0, which is how they were always played.
struct SessionAudioTiming: Codable, Equatable, Sendable {
    static let fileName = "timing.json"
    static let currentVersion = 1

    let version: Int
    /// Session-clock position (ms) of the first sample in `mic.m4a`; `nil`
    /// when the mic captured nothing.
    let micStartOffsetMs: Int?
    /// Session-clock position (ms) of the first sample in `system.m4a`;
    /// `nil` when system audio captured nothing.
    let systemStartOffsetMs: Int?

    init(micStartOffsetMs: Int?, systemStartOffsetMs: Int?) {
        self.version = Self.currentVersion
        self.micStartOffsetMs = micStartOffsetMs
        self.systemStartOffsetMs = systemStartOffsetMs
    }

    static func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// The timing saved in `directory`, or `nil` when there is none (older
    /// sessions) or it can't be read.
    static func load(from directory: URL) -> SessionAudioTiming? {
        guard let data = try? Data(contentsOf: fileURL(in: directory)) else { return nil }
        return try? JSONDecoder().decode(SessionAudioTiming.self, from: data)
    }

    func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.fileURL(in: directory), options: .atomic)
    }

    /// Start offset in seconds of the system track (0 when unknown).
    var systemStartOffsetSeconds: Double { Double(systemStartOffsetMs ?? 0) / 1000 }

    /// Start offset in seconds of the mic track (0 when unknown).
    var micStartOffsetSeconds: Double { Double(micStartOffsetMs ?? 0) / 1000 }
}

// MARK: - TrackPlaybackPlan

/// How to start one track so it plays in step with the session clock.
struct TrackPlaybackPlan: Equatable, Sendable {
    /// Position in the track's file to start from.
    let filePosition: TimeInterval
    /// Session-clock seconds to wait before starting (the track starts later
    /// in the session than the requested position).
    let delay: TimeInterval

    /// Plan for playing a track that starts `trackOffset` seconds into the
    /// session and lasts `trackDuration` seconds, from session position
    /// `sessionPosition`. `nil` when the track has already ended there.
    static func make(
        sessionPosition: TimeInterval,
        trackOffset: TimeInterval,
        trackDuration: TimeInterval
    ) -> TrackPlaybackPlan? {
        let local = sessionPosition - max(0, trackOffset)
        if local < 0 {
            return trackDuration > 0 ? TrackPlaybackPlan(filePosition: 0, delay: -local) : nil
        }
        guard local < trackDuration else { return nil }
        return TrackPlaybackPlan(filePosition: local, delay: 0)
    }
}
