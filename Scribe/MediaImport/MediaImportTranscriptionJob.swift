// Scribe/MediaImport/MediaImportTranscriptionJob.swift
import AVFoundation
import Foundation

/// The transcription state of one imported file: the speech pipeline it feeds,
/// the session recorder its audio goes to, and what the recognizer produced.
///
/// Portable core of `MediaImportController` (macOS) — the iPhone / iPad
/// importer (ScribeiOS/Recording) drives the same job. Main-actor only, like
/// the `TranscriptionPipeline` it owns.
@MainActor
final class MediaImportTranscriptionJob {
    let pipeline: TranscriptionPipeline
    let recorder: SessionAudioRecorder

    var durationSeconds: Double = 0
    var fedFrames = 0
    private(set) var segments: [TranscriptionSegment] = []
    private(set) var error: Error?
    private var lastSegmentEndMs = 0
    private var lastActivity = ContinuousClock.now

    init(pipeline: TranscriptionPipeline, recorder: SessionAudioRecorder) {
        self.pipeline = pipeline
        self.recorder = recorder
    }

    var fedMs: Int { Int(Double(fedFrames) / MediaImportDecoder.sampleRate * 1_000) }
    var transcribedMs: Int { lastSegmentEndMs }
    var quietForMs: Int {
        let elapsed = ContinuousClock.now - lastActivity
        return Int(elapsed.components.seconds * 1_000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    func wire(onPreview: @escaping (String) -> Void) {
        pipeline.onSegment = { [weak self] segment in
            guard let self else { return }
            self.segments.append(segment)
            self.lastSegmentEndMs = max(self.lastSegmentEndMs, segment.endMs)
            self.lastActivity = ContinuousClock.now
            onPreview(segment.text)
        }
        pipeline.onPartialUpdate = { [weak self] text in
            guard let self else { return }
            self.lastActivity = ContinuousClock.now
            if !text.isEmpty { onPreview(text) }
        }
        pipeline.onError = { [weak self] error in
            self?.error = error
        }
    }

    /// Hands one decoded chunk (`frames` frames) to the audio file — as the
    /// session's "system" track — and to the recognizer.
    func feed(_ buffer: AVAudioPCMBuffer, frames: Int) {
        recorder.appendSystem(buffer)
        pipeline.append(buffer)
        fedFrames += frames
    }

    /// Waits while the recognizer is far behind and still busy (see
    /// `ImportPacing`), at most `ImportPacing.maxWaitMs`.
    func waitWhileRecognizerIsBehind() async throws {
        var waitedMs = 0
        while ImportPacing.shouldWait(fedMs: fedMs, transcribedMs: transcribedMs, quietForMs: quietForMs),
              waitedMs < ImportPacing.maxWaitMs {
            try await Task.sleep(for: .milliseconds(100))
            waitedMs += 100
        }
    }

    /// Feeds trailing silence so the recognizer finalizes the last words,
    /// then waits until it has been quiet for a moment (it caught up).
    func drain() async throws {
        if let silence = MediaImportDecoder.makeBuffer([Float](repeating: 0, count: Int(MediaImportDecoder.sampleRate * 2))) {
            pipeline.append(silence)
        }
        lastActivity = ContinuousClock.now
        var waitedMs = 0
        while !ImportPacing.isDrained(quietForMs: quietForMs, waitedMs: waitedMs) {
            try await Task.sleep(for: .milliseconds(250))
            waitedMs += 250
            if error != nil { return }
        }
    }

    /// The recognized results merged into transcript segments, stamped with
    /// `speaker` (see `ImportedTranscriptCoalescer`).
    func mergedPieces(speaker: String?) -> [ImportedTranscriptCoalescer.Piece] {
        let pieces = segments.map {
            ImportedTranscriptCoalescer.Piece(startMs: $0.startMs, endMs: $0.endMs,
                                              speaker: speaker ?? $0.speaker, text: $0.text)
        }
        return ImportedTranscriptCoalescer.coalesce(pieces)
    }
}
