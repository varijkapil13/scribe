// Scribe/Audio/MediaImportDecoder.swift
import AVFoundation
import CoreMedia
import Foundation
import UniformTypeIdentifiers

// MARK: - Formats

/// Which files File › Import Recording… and drag-and-drop accept.
enum MediaImportFormats {

    /// Lower-case file extensions Scribe imports.
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "aifc", "caf"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    static var allExtensions: Set<String> { audioExtensions.union(videoExtensions) }

    /// Content types for the open panel.
    static var contentTypes: [UTType] {
        var types: [UTType] = [.audio, .movie, .mpeg4Audio, .mp3, .wav, .aiff, .mpeg4Movie, .quickTimeMovie]
        if let caf = UTType(filenameExtension: "caf") { types.append(caf) }
        if let m4v = UTType(filenameExtension: "m4v") { types.append(m4v) }
        return types
    }

    nonisolated static func isSupported(_ url: URL) -> Bool {
        allExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// The supported files among `urls`, de-duplicated, in order.
    nonisolated static func supported(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            isSupported(url) && seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    /// Note title for an imported file: its name without extension, with
    /// separators turned into spaces ("team_sync-2026.m4a" → "team sync 2026").
    nonisolated static func noteTitle(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let spaced = base.replacingOccurrences(of: "_", with: " ")
        let collapsed = spaced.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.isEmpty ? "Imported recording" : collapsed
    }
}

// MARK: - Errors

enum ScribeMediaImportError: LocalizedError, Equatable {
    case unsupportedFile(String)
    case noAudioTrack(String)
    case unreadable(String)
    case recordingInProgress
    case speechNotAuthorized
    case nothingTranscribed

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let name):
            return "“\(name)” isn’t an audio or video file Scribe can import (m4a, mp3, wav, aiff, caf, mp4, mov, m4v)."
        case .noAudioTrack(let name):
            return "“\(name)” has no audio track to transcribe."
        case .unreadable(let detail):
            return "Couldn’t read the file: \(detail)"
        case .recordingInProgress:
            return "Finish the current recording before importing one."
        case .speechNotAuthorized:
            return "Scribe needs speech recognition access to transcribe imported recordings. Grant it in System Settings → Privacy & Security → Speech Recognition."
        case .nothingTranscribed:
            return "No speech was recognized in the imported recording."
        }
    }
}

// MARK: - Decoder

/// Decodes the audio of a media file into 16 kHz mono Float32 samples, the
/// format the capture path feeds to transcription and the session recorder.
///
/// `AVAssetReaderAudioMixOutput` mixes every audio track down to one channel
/// and resamples, so audio files and the soundtrack of videos are handled
/// the same way. Everything AVFoundation-related stays local to
/// ``decode(url:chunkFrames:onStart:onChunk:)``; only `[Float]` chunks (which
/// are Sendable) leave it.
enum MediaImportDecoder {

    static let sampleRate: Double = 16_000

    /// ~1 s of audio per chunk.
    static let defaultChunkFrames = 16_000

    /// The PCM format of the decoded chunks.
    static func pcmFormat() -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    }

    /// Wraps decoded samples in a PCM buffer of ``pcmFormat()``.
    static func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let format = pcmFormat(),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    /// Decodes `url`, calling `onStart` with the duration in seconds once the
    /// file is open and then `onChunk` with consecutive sample chunks of
    /// `chunkFrames` frames (the last one may be shorter). Awaiting each
    /// callback gives the consumer back-pressure. Stops with
    /// `CancellationError` when the task is cancelled.
    static func decode(url: URL,
                       chunkFrames: Int = defaultChunkFrames,
                       onStart: @Sendable (Double) async -> Void,
                       onChunk: @Sendable ([Float]) async throws -> Void) async throws {
        let name = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        let duration: CMTime
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
        } catch {
            throw ScribeMediaImportError.unreadable(error.localizedDescription)
        }
        guard !tracks.isEmpty else { throw ScribeMediaImportError.noAudioTrack(name) }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ScribeMediaImportError.unreadable(error.localizedDescription)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ScribeMediaImportError.unreadable("The audio format isn’t supported.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ScribeMediaImportError.unreadable(reader.error?.localizedDescription ?? "The file couldn’t be opened.")
        }

        let seconds = duration.seconds
        await onStart(seconds.isFinite && seconds > 0 ? seconds : 0)

        let frames = max(chunkFrames, 1_024)
        var pending: [Float] = []
        pending.reserveCapacity(frames * 2)
        while reader.status == .reading {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            if let samples = floatSamples(of: sampleBuffer) {
                pending += samples
            }
            while pending.count >= frames {
                let chunk = Array(pending.prefix(frames))
                pending.removeFirst(frames)
                try await onChunk(chunk)
            }
        }
        if reader.status == .failed {
            throw ScribeMediaImportError.unreadable(reader.error?.localizedDescription ?? "Decoding failed.")
        }
        if Task.isCancelled { throw CancellationError() }
        if !pending.isEmpty {
            try await onChunk(pending)
        }
    }

    /// The Float32 samples of one decoded (mono, packed) sample buffer.
    private static func floatSamples(of sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        let count = length / MemoryLayout<Float>.size
        guard count > 0 else { return nil }
        var samples = [Float](repeating: 0, count: count)
        let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                              dataLength: count * MemoryLayout<Float>.size,
                                              destination: base)
        }
        return status == kCMBlockBufferNoErr ? samples : nil
    }
}
