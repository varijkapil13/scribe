import AVFoundation
import Combine
import SwiftUI

/// Plays back a session's retained audio: the mic and system tracks are two
/// `AVAudioPlayer`s scheduled on the same device clock, so they stay in sync
/// and are heard mixed. Seek, play/pause and speed apply to both.
///
/// Positions are on the session clock (the timeline transcript segments use).
/// Each file starts at its track's offset on that clock, read from the
/// session's `timing.json` (``SessionAudioTiming``) — system audio typically
/// starts a few hundred ms after the mic — so a track is started at the
/// matching point in its file, or scheduled to start later when the position
/// is before its first sample. Sessions without `timing.json` play both files
/// from 0, as before.
@MainActor
final class SessionAudioPlayer: ObservableObject {

    @Published private(set) var hasAudio = false
    @Published private(set) var isPlaying = false
    /// Current position in seconds.
    @Published private(set) var currentTime: TimeInterval = 0
    /// Length of the session audio (end of the latest-ending track), in seconds.
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var rate: Float = 1.0

    /// One file and where it starts on the session clock.
    private struct Track {
        let player: AVAudioPlayer
        let offset: TimeInterval
        var end: TimeInterval { offset + player.duration }
    }

    private var tracks: [Track] = []
    private var loadedDirectory: String?
    private var progressTimer: Timer?

    /// Session position and device time at which the current playback run
    /// starts; the live position is derived from these and the rate, so it
    /// is right even while a track is still waiting for its scheduled start.
    private var runStartPosition: TimeInterval = 0
    private var runStartDeviceTime: TimeInterval = 0

    /// Current position in milliseconds (segment time base).
    var currentTimeMs: Int { Int(currentTime * 1000) }

    // MARK: - Loading

    /// Loads the session's tracks. Cheap to call repeatedly: does nothing if
    /// the same folder is already loaded.
    func load(session: Session) {
        guard session.audioDirectory != loadedDirectory || tracks.isEmpty else { return }
        unload()
        loadedDirectory = session.audioDirectory
        guard let path = session.audioDirectory else { return }

        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let timing = SessionAudioTiming.load(from: directory)
        let files: [(url: URL, offset: TimeInterval)] = [
            (SessionAudioStorage.micFileURL(in: directory), timing?.micStartOffsetSeconds ?? 0),
            (SessionAudioStorage.systemFileURL(in: directory), timing?.systemStartOffsetSeconds ?? 0)
        ]
        var loaded: [Track] = []
        for file in files where FileManager.default.fileExists(atPath: file.url.path) {
            do {
                let player = try AVAudioPlayer(contentsOf: file.url)
                player.enableRate = true
                player.rate = rate
                player.prepareToPlay()
                loaded.append(Track(player: player, offset: max(0, file.offset)))
            } catch {
                Log.ui.error("Couldn't open session audio \(file.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)")
            }
        }
        tracks = loaded
        duration = loaded.map(\.end).max() ?? 0
        currentTime = 0
        hasAudio = !loaded.isEmpty && duration > 0
    }

    /// Stops playback and releases the files.
    func unload() {
        stop()
        tracks = []
        loadedDirectory = nil
        hasAudio = false
        duration = 0
        currentTime = 0
    }

    // MARK: - Transport

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard hasAudio, !tracks.isEmpty else { return }
        if currentTime >= duration - 0.05 {
            currentTime = 0
        }
        startPlayers(at: currentTime)
    }

    func pause() {
        guard isPlaying else { return }
        currentTime = livePosition()
        for track in tracks {
            // A track still waiting for its scheduled start (`play(atTime:)`)
            // is stopped rather than paused so it can't start on its own
            // later; play() re-schedules every track from `currentTime`.
            if currentTime < track.offset {
                track.player.stop()
            } else {
                track.player.pause()
            }
        }
        isPlaying = false
        stopProgressTimer()
    }

    /// Stops playback (keeps the position).
    func stop() {
        if isPlaying {
            currentTime = livePosition()
        }
        for track in tracks { track.player.stop() }
        isPlaying = false
        stopProgressTimer()
    }

    /// Jumps to `seconds`; keeps playing if playing.
    func seek(to seconds: TimeInterval) {
        let target = PlaybackTimeline.clampedSeek(seconds, duration: duration)
        currentTime = target
        if isPlaying {
            startPlayers(at: target)
        } else {
            for track in tracks {
                let plan = TrackPlaybackPlan.make(
                    sessionPosition: target,
                    trackOffset: track.offset,
                    trackDuration: track.player.duration
                )
                track.player.currentTime = plan?.filePosition ?? track.player.duration
            }
        }
    }

    /// Jumps to a segment start (milliseconds) and starts playing.
    func playFrom(ms: Int) {
        seek(to: PlaybackTimeline.seconds(fromMs: ms))
        if !isPlaying { play() }
    }

    func cycleRate() {
        setRate(PlaybackTimeline.nextRate(after: rate))
    }

    func setRate(_ newRate: Float) {
        guard newRate > 0 else { return }
        if isPlaying {
            // Re-schedule from the current position so tracks still waiting
            // for their start keep the right delay at the new speed.
            let position = livePosition()
            rate = newRate
            startPlayers(at: position)
        } else {
            rate = newRate
            for track in tracks { track.player.rate = newRate }
        }
    }

    // MARK: - Private

    /// (Re)starts every track at session position `position`, scheduled on
    /// the shared device clock a moment ahead so all tracks begin on the
    /// same sample. A track that starts later in the session is scheduled
    /// that much later (scaled by the playback rate).
    private func startPlayers(at position: TimeInterval) {
        for track in tracks { track.player.stop() }
        guard let reference = tracks.first?.player else { return }
        let startAt = reference.deviceCurrentTime + 0.05
        let speed = TimeInterval(max(rate, 0.01))
        var started = false
        for track in tracks {
            // A track that already ended (e.g. system audio switched off
            // early) only plays while the position is inside it.
            guard let plan = TrackPlaybackPlan.make(
                sessionPosition: position,
                trackOffset: track.offset,
                trackDuration: track.player.duration
            ) else { continue }
            track.player.currentTime = plan.filePosition
            track.player.rate = rate
            if track.player.play(atTime: startAt + plan.delay / speed) { started = true }
        }
        guard started else {
            isPlaying = false
            stopProgressTimer()
            return
        }
        runStartPosition = position
        runStartDeviceTime = startAt
        isPlaying = true
        startProgressTimer()
    }

    /// Session position now, derived from the device clock (falls back to
    /// the stored position when nothing is playing).
    private func livePosition() -> TimeInterval {
        guard isPlaying, let reference = tracks.first?.player else { return currentTime }
        let elapsed = max(0, reference.deviceCurrentTime - runStartDeviceTime)
        return min(duration, runStartPosition + elapsed * TimeInterval(rate))
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func tick() {
        guard isPlaying else {
            stopProgressTimer()
            return
        }
        let position = livePosition()
        // Right after scheduling, and while a track is still waiting for its
        // scheduled start, count it as running: playback only ends once the
        // position has passed every track.
        let deviceNow = tracks.first?.player.deviceCurrentTime ?? 0
        let warmingUp = deviceNow < runStartDeviceTime + 0.25
        let anyRunning = warmingUp || tracks.contains { $0.player.isPlaying || position < $0.offset }
        if position >= duration || !anyRunning {
            // Every track reached its end.
            for track in tracks { track.player.stop() }
            currentTime = position >= duration - 0.5 ? duration : position
            isPlaying = false
            stopProgressTimer()
        } else {
            currentTime = position
        }
    }
}

// MARK: - Player bar

/// Compact player shown above a transcript when the session has retained
/// audio: play/pause, scrubber with elapsed / total time, and a speed button.
struct SessionAudioPlayerBar: View {
    @ObservedObject var player: SessionAudioPlayer

    /// Scrubber position while the user drags (nil when not dragging), so the
    /// periodic progress updates don't fight the drag.
    @State private var scrubPosition: TimeInterval?

    /// Bookmarked moments drawn as ticks on the timeline (meeting copilot).
    @Environment(\.playbackBookmarkOffsets) private var bookmarkOffsets

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Button(action: { player.togglePlayPause() }) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(player.isPlaying ? "Pause recording" : "Play recording")

            Text(PlaybackTimeline.format(scrubPosition ?? player.currentTime))
                .font(DesignTokens.Typography.timestamp)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Slider(
                value: Binding(
                    get: { scrubPosition ?? player.currentTime },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(player.duration, 0.1),
                onEditingChanged: { editing in
                    if !editing, let target = scrubPosition {
                        player.seek(to: target)
                        scrubPosition = nil
                    }
                }
            )
            .controlSize(.small)
            .overlay {
                if !bookmarkOffsets.isEmpty {
                    BookmarkMarkersOverlay(offsetsMs: bookmarkOffsets, durationSeconds: player.duration)
                }
            }
            .accessibilityLabel("Playback position")

            Text(PlaybackTimeline.format(player.duration))
                .font(DesignTokens.Typography.timestamp)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button(PlaybackTimeline.rateLabel(player.rate)) { player.cycleRate() }
                .buttonStyle(.borderless)
                .font(.caption.monospacedDigit())
                .frame(minWidth: 32)
                .help("Playback speed")
                .accessibilityLabel("Playback speed \(PlaybackTimeline.rateLabel(player.rate))")
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(DesignTokens.Palette.surfaceSunken,
                    in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
    }
}
