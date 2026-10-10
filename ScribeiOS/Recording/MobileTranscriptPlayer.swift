// ScribeiOS/Recording/MobileTranscriptPlayer.swift
//
// Plays a recording's retained audio (AVAudioPlayer) for the transcript
// detail screen: play / pause, tap a line to seek, the current position to
// highlight the line being heard.

import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class MobileTranscriptPlayer {

    private(set) var isAvailable = false
    private(set) var isPlaying = false
    /// Seconds into the file.
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    var currentMs: Int { Int(currentTime * 1_000) }

    /// Loads `url` (nil → no audio for this recording).
    func load(url: URL?) {
        stop()
        player = nil
        isAvailable = false
        duration = 0
        currentTime = 0
        guard let url else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            isAvailable = true
        } catch {
            Log.audio.error("Couldn't open the recording's audio: \(error.localizedDescription, privacy: .public)")
        }
    }

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard let player else { return }
        activatePlaybackSession()
        if player.play() {
            isPlaying = true
            startTicking()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        ticker?.cancel()
        ticker = nil
        currentTime = player?.currentTime ?? currentTime
    }

    /// Jumps to `ms` and plays from there.
    func seek(toMs ms: Int) {
        guard let player else { return }
        let target = min(max(0, Double(ms) / 1_000), max(0, player.duration - 0.05))
        player.currentTime = target
        currentTime = target
        play()
    }

    func skip(by seconds: Double) {
        guard let player else { return }
        seek(toMs: Int((player.currentTime + seconds) * 1_000))
    }

    func stop() {
        player?.stop()
        isPlaying = false
        ticker?.cancel()
        ticker = nil
    }

    // MARK: - Private

    /// Playback goes to the speaker / headphones. Left alone while a
    /// recording is running (it owns the `.playAndRecord` session).
    private func activatePlaybackSession() {
        guard !MobileRecordingController.shared.isActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            Log.audio.error("Couldn't set up playback: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying {
            // Reached the end.
            isPlaying = false
            ticker?.cancel()
            ticker = nil
        }
    }
}
