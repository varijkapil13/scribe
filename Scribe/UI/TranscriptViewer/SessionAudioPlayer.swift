import AVFoundation
import Combine
import SwiftUI

/// Plays back a session's retained audio: the mic and system tracks are two
/// `AVAudioPlayer`s started together on the same device clock, so they stay
/// in sync and are heard mixed. Seek, play/pause and speed apply to both.
@MainActor
final class SessionAudioPlayer: ObservableObject {

    @Published private(set) var hasAudio = false
    @Published private(set) var isPlaying = false
    /// Current position in seconds.
    @Published private(set) var currentTime: TimeInterval = 0
    /// Length of the longer track, in seconds.
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var rate: Float = 1.0

    private var players: [AVAudioPlayer] = []
    private var loadedDirectory: String?
    private var progressTimer: Timer?

    /// Current position in milliseconds (segment time base).
    var currentTimeMs: Int { Int(currentTime * 1000) }

    // MARK: - Loading

    /// Loads the session's tracks. Cheap to call repeatedly: does nothing if
    /// the same folder is already loaded.
    func load(session: Session) {
        guard session.audioDirectory != loadedDirectory || players.isEmpty else { return }
        unload()
        loadedDirectory = session.audioDirectory
        guard let path = session.audioDirectory else { return }

        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let urls = [
            SessionAudioStorage.micFileURL(in: directory),
            SessionAudioStorage.systemFileURL(in: directory)
        ]
        var loaded: [AVAudioPlayer] = []
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.enableRate = true
                player.rate = rate
                player.prepareToPlay()
                loaded.append(player)
            } catch {
                Log.ui.error("Couldn't open session audio \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)")
            }
        }
        players = loaded
        duration = loaded.map(\.duration).max() ?? 0
        currentTime = 0
        hasAudio = !loaded.isEmpty && duration > 0
    }

    /// Stops playback and releases the files.
    func unload() {
        stop()
        players = []
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
        guard hasAudio, !players.isEmpty else { return }
        if currentTime >= duration - 0.05 {
            currentTime = 0
        }
        startPlayers(at: currentTime)
    }

    func pause() {
        guard isPlaying else { return }
        currentTime = livePosition()
        for player in players { player.pause() }
        isPlaying = false
        stopProgressTimer()
    }

    /// Stops playback (keeps the position).
    func stop() {
        if isPlaying {
            currentTime = livePosition()
        }
        for player in players { player.stop() }
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
            for player in players { player.currentTime = min(target, player.duration) }
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
        rate = newRate
        for player in players { player.rate = newRate }
    }

    // MARK: - Private

    /// (Re)starts every track at `position`, scheduled on the shared device
    /// clock a moment ahead so all tracks begin on the same sample.
    private func startPlayers(at position: TimeInterval) {
        for player in players { player.stop() }
        guard let reference = players.first else { return }
        let startAt = reference.deviceCurrentTime + 0.05
        var started = false
        for player in players {
            // A shorter track (e.g. system audio that started late) only plays
            // while the position is inside it.
            guard position < player.duration else { continue }
            player.currentTime = position
            player.rate = rate
            if player.play(atTime: startAt) { started = true }
        }
        guard started else {
            isPlaying = false
            stopProgressTimer()
            return
        }
        isPlaying = true
        startProgressTimer()
    }

    /// Position of the furthest-along playing track (falls back to the stored
    /// position when nothing is playing).
    private func livePosition() -> TimeInterval {
        let playing = players.filter(\.isPlaying)
        guard !playing.isEmpty else { return currentTime }
        return playing.map(\.currentTime).max() ?? currentTime
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
        if players.contains(where: \.isPlaying) {
            currentTime = livePosition()
        } else {
            // Every track reached its end.
            currentTime = duration
            isPlaying = false
            stopProgressTimer()
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
