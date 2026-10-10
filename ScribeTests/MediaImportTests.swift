import XCTest
import AVFoundation
@testable import Scribe

final class MediaImportFormatsTests: XCTestCase {

    func testSupportedExtensions() {
        for name in ["a.m4a", "b.MP3", "c.wav", "d.aiff", "e.aif", "f.caf", "g.mp4", "h.MOV", "i.m4v"] {
            XCTAssertTrue(MediaImportFormats.isSupported(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        for name in ["a.txt", "b.md", "c", "d.pdf", "e.flac"] {
            XCTAssertFalse(MediaImportFormats.isSupported(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        XCTAssertTrue(MediaImportFormats.isVideo(URL(fileURLWithPath: "/tmp/x.mov")))
        XCTAssertFalse(MediaImportFormats.isVideo(URL(fileURLWithPath: "/tmp/x.m4a")))
    }

    func testSupportedFiltersAndDeduplicates() {
        let urls = ["/tmp/a.m4a", "/tmp/b.txt", "/tmp/a.m4a", "/tmp/./c.mov"].map { URL(fileURLWithPath: $0) }
        XCTAssertEqual(MediaImportFormats.supported(urls).map(\.lastPathComponent), ["a.m4a", "c.mov"])
    }

    func testNoteTitle() {
        XCTAssertEqual(MediaImportFormats.noteTitle(for: URL(fileURLWithPath: "/tmp/team_sync  2026.m4a")), "team sync 2026")
        XCTAssertEqual(MediaImportFormats.noteTitle(for: URL(fileURLWithPath: "/tmp/Interview.with.Ana.mp4")), "Interview.with.Ana")
        XCTAssertEqual(MediaImportFormats.noteTitle(for: URL(fileURLWithPath: "/tmp/___.wav")), "Imported recording")
    }

    func testNoteHeaderNamesTheFile() {
        let header = MediaImportController.noteHeader(for: URL(fileURLWithPath: "/tmp/call.m4a"), date: Date())
        XCTAssertTrue(header.contains("*call.m4a*"))
    }

    func testErrorsHaveDescriptions() {
        let errors: [ScribeMediaImportError] = [
            .unsupportedFile("x.txt"), .noAudioTrack("y.mov"), .unreadable("bad"),
            .recordingInProgress, .speechNotAuthorized, .nothingTranscribed
        ]
        for error in errors {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
        }
    }

    func testMakeBufferCopiesSamples() throws {
        let samples: [Float] = [0, 0.5, -0.5, 1]
        let buffer = try XCTUnwrap(MediaImportDecoder.makeBuffer(samples))
        XCTAssertEqual(buffer.frameLength, 4)
        XCTAssertEqual(buffer.format.sampleRate, 16_000)
        XCTAssertEqual(buffer.format.channelCount, 1)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: channel, count: 4)), samples)
        XCTAssertNil(MediaImportDecoder.makeBuffer([]))
    }

    func testDecodesAWaveFileTo16kMono() async throws {
        // A 0.5 s, 44.1 kHz stereo sine file.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-import-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames: AVAudioFrameCount = 22_050
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
            buffer.frameLength = frames
            for channel in 0..<2 {
                let data = try XCTUnwrap(buffer.floatChannelData?[channel])
                for i in 0..<Int(frames) {
                    data[i] = sinf(Float(i) * 2 * .pi * 440 / 44_100) * 0.5
                }
            }
            try file.write(from: buffer)
        }

        let collected = SampleCollector()
        try await MediaImportDecoder.decode(
            url: url,
            chunkFrames: 4_000,
            onStart: { seconds in await collected.setDuration(seconds) },
            onChunk: { samples in await collected.append(samples) }
        )
        let duration = await collected.duration
        let total = await collected.total
        let chunkSizes = await collected.chunkSizes
        XCTAssertEqual(duration, 0.5, accuracy: 0.05)
        // ~8000 frames at 16 kHz (resampler edges may add/drop a few).
        XCTAssertEqual(Double(total), 8_000, accuracy: 400)
        XCTAssertTrue(chunkSizes.dropLast().allSatisfy { $0 == 4_000 })
    }

    func testDecodeRejectsAFileWithoutAudio() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-import-\(UUID().uuidString).m4a")
        try? Data("not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try await MediaImportDecoder.decode(url: url, onStart: { _ in }, onChunk: { _ in })
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error is ScribeMediaImportError)
        }
    }
}

/// Collects decoder output across the decoder's `@Sendable` callbacks.
private actor SampleCollector {
    var duration: Double = 0
    var total = 0
    var chunkSizes: [Int] = []

    func setDuration(_ seconds: Double) { duration = seconds }

    func append(_ samples: [Float]) {
        total += samples.count
        chunkSizes.append(samples.count)
    }
}

final class ImportedTranscriptAssemblyTests: XCTestCase {

    private typealias Piece = ImportedTranscriptCoalescer.Piece

    func testMergesSameSpeakerWithinGapAndSpan() {
        let pieces = [
            Piece(startMs: 0, endMs: 1_000, speaker: "remote", text: "Hello"),
            Piece(startMs: 1_500, endMs: 3_000, speaker: "remote", text: "there."),
            Piece(startMs: 10_000, endMs: 11_000, speaker: "remote", text: "Later."),
            Piece(startMs: 11_200, endMs: 12_000, speaker: "you", text: "Me."),
        ]
        let merged = ImportedTranscriptCoalescer.coalesce(pieces, maxSpanMs: 60_000, maxGapMs: 4_000)
        XCTAssertEqual(merged, [
            Piece(startMs: 0, endMs: 3_000, speaker: "remote", text: "Hello there."),
            Piece(startMs: 10_000, endMs: 11_000, speaker: "remote", text: "Later."),
            Piece(startMs: 11_200, endMs: 12_000, speaker: "you", text: "Me."),
        ])
    }

    func testSpanLimitSplitsLongMonologues() {
        let pieces = (0..<10).map { Piece(startMs: $0 * 10_000, endMs: $0 * 10_000 + 9_000, speaker: "remote", text: "p\($0)") }
        let merged = ImportedTranscriptCoalescer.coalesce(pieces, maxSpanMs: 30_000, maxGapMs: 2_000)
        XCTAssertGreaterThan(merged.count, 1)
        for piece in merged {
            XCTAssertLessThanOrEqual(piece.endMs - piece.startMs, 30_000)
        }
        XCTAssertEqual(merged.map(\.text).joined(separator: " "), (0..<10).map { "p\($0)" }.joined(separator: " "))
    }

    func testSortsAndDropsEmptyText() {
        let pieces = [
            Piece(startMs: 5_000, endMs: 6_000, speaker: "remote", text: "second"),
            Piece(startMs: 0, endMs: 1_000, speaker: "remote", text: "  "),
            Piece(startMs: 1_000, endMs: 900, speaker: "you", text: " first "),
        ]
        let merged = ImportedTranscriptCoalescer.coalesce(pieces)
        XCTAssertEqual(merged.map(\.text), ["first", "second"])
        XCTAssertEqual(merged.first?.endMs, 1_000)  // end clamped to start
    }

    func testPacing() {
        // Far behind and busy: wait.
        XCTAssertTrue(ImportPacing.shouldWait(fedMs: 200_000, transcribedMs: 10_000, quietForMs: 100))
        // Far behind but quiet (silence / done): keep feeding.
        XCTAssertFalse(ImportPacing.shouldWait(fedMs: 200_000, transcribedMs: 10_000, quietForMs: 5_000))
        // Close enough: keep feeding.
        XCTAssertFalse(ImportPacing.shouldWait(fedMs: 50_000, transcribedMs: 10_000, quietForMs: 0))

        XCTAssertTrue(ImportPacing.isDrained(quietForMs: 3_000, waitedMs: 0))
        XCTAssertTrue(ImportPacing.isDrained(quietForMs: 0, waitedMs: 120_000))
        XCTAssertFalse(ImportPacing.isDrained(quietForMs: 1_000, waitedMs: 1_000))

        XCTAssertEqual(ImportPacing.fraction(fedFrames: 8_000, totalSeconds: 1, sampleRate: 16_000), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ImportPacing.fraction(fedFrames: 99_999, totalSeconds: 1, sampleRate: 16_000), 1)
        XCTAssertEqual(ImportPacing.fraction(fedFrames: 10, totalSeconds: 0, sampleRate: 16_000), 0)
    }
}
