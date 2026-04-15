import XCTest
@testable import Scribe

final class ScribeTests: XCTestCase {

    // MARK: - Session Model Tests

    func testSessionCreation() {
        let session = Session(title: "Test Meeting")
        XCTAssertEqual(session.title, "Test Meeting")
        XCTAssertNil(session.endedAt)
        XCTAssertNil(session.durationSeconds)
        XCTAssertTrue(session.tags.isEmpty)
    }

    func testSessionWithTags() {
        let session = Session(title: "Tagged Session", tags: ["planning", "q3"])
        XCTAssertEqual(session.tags, ["planning", "q3"])
    }

    // MARK: - Segment Model Tests

    func testSegmentFormattedTimestamp() {
        let segment = Segment(
            sessionId: "test-id",
            startMs: 3_723_000,
            endMs: 3_728_000,
            speaker: "you",
            text: "Hello world"
        )
        XCTAssertEqual(segment.formattedTimestamp, "[01:02:03]")
    }

    func testSegmentZeroTimestamp() {
        let segment = Segment(
            sessionId: "test-id",
            startMs: 0,
            endMs: 5000,
            speaker: "remote",
            text: "Start of meeting"
        )
        XCTAssertEqual(segment.formattedTimestamp, "[00:00:00]")
    }

    // MARK: - Export Format Tests

    func testMarkdownExport() {
        let session = Session(title: "Test Export", durationSeconds: 120)
        let segments = [
            Segment(sessionId: session.id, startMs: 0, endMs: 5000, speaker: "you", text: "Hello"),
            Segment(sessionId: session.id, startMs: 5000, endMs: 10000, speaker: "remote", text: "Hi there"),
        ]

        let output = ExportManager.export(session: session, segments: segments, format: .markdown)
        XCTAssertTrue(output.contains("# Test Export"))
        XCTAssertTrue(output.contains("Hello"))
        XCTAssertTrue(output.contains("Hi there"))
    }

    func testPlainTextExport() {
        let session = Session(title: "Plain Text Test", durationSeconds: 60)
        let segments = [
            Segment(sessionId: session.id, startMs: 1000, endMs: 5000, speaker: "you", text: "Testing"),
        ]

        let output = ExportManager.export(session: session, segments: segments, format: .plainText)
        XCTAssertTrue(output.contains("Plain Text Test"))
        XCTAssertTrue(output.contains("Testing"))
    }

    func testJSONExport() {
        let session = Session(title: "JSON Test", durationSeconds: 300)
        let segments = [
            Segment(sessionId: session.id, startMs: 0, endMs: 5000, speaker: "you", text: "JSON test"),
        ]

        let output = ExportManager.export(session: session, segments: segments, format: .json)
        XCTAssertTrue(output.contains("\"title\""))
        XCTAssertTrue(output.contains("JSON Test"))
        XCTAssertTrue(output.contains("\"segments\""))
    }

    // MARK: - Extension Tests

    func testTimeIntervalFormattedDuration() {
        XCTAssertEqual(TimeInterval(65).formattedDuration, "01:05")
        XCTAssertEqual(TimeInterval(3661).formattedDuration, "01:01:01")
        XCTAssertEqual(TimeInterval(0).formattedDuration, "00:00")
    }

    func testIntFormattedTimestamp() {
        XCTAssertEqual(0.formattedTimestamp, "[00:00:00]")
        XCTAssertEqual(61_000.formattedTimestamp, "[00:01:01]")
        XCTAssertEqual(3_661_000.formattedTimestamp, "[01:01:01]")
    }

    func testIntFormattedDurationFromSeconds() {
        XCTAssertEqual(0.formattedDurationFromSeconds, "0 minutes")
        XCTAssertEqual(60.formattedDurationFromSeconds, "1 minute")
        XCTAssertEqual(7500.formattedDurationFromSeconds, "2 hours 5 minutes")
    }

    // MARK: - AudioBufferManager Tests

    func testAudioBufferChunkEmission() {
        let manager = AudioBufferManager()
        var emittedChunks: [([Float], String)] = []

        manager.onChunkReady = { samples, speaker in
            emittedChunks.append((samples, speaker))
        }

        // Feed enough samples for one chunk (5 seconds at 16kHz = 80,000 samples)
        let samples = [Float](repeating: 0.5, count: 80_000)
        manager.appendMicSamples(samples)

        XCTAssertEqual(emittedChunks.count, 1)
        XCTAssertEqual(emittedChunks[0].1, "you")
        XCTAssertEqual(emittedChunks[0].0.count, 80_000)
    }

    func testAudioBufferReset() {
        let manager = AudioBufferManager()
        var emitted = false
        manager.onChunkReady = { _, _ in emitted = true }

        // Feed partial data then reset
        manager.appendMicSamples([Float](repeating: 0.1, count: 1000))
        manager.reset()

        // Feed a full chunk — should need the full amount since we reset
        manager.appendMicSamples([Float](repeating: 0.5, count: 80_000))
        XCTAssertTrue(emitted)
    }

    // MARK: - WhisperModel Tests

    func testWhisperModelProperties() {
        let medium = WhisperModel.medium
        XCTAssertEqual(medium.fileName, "ggml-medium.bin")
        XCTAssertTrue(medium.displayName.contains("Medium"))

        let large = WhisperModel.largev3Turbo
        XCTAssertEqual(large.fileName, "ggml-large-v3-turbo.bin")
        XCTAssertTrue(large.displayName.contains("Large"))
    }

    func testExportFormatFileExtensions() {
        XCTAssertEqual(ExportFormat.markdown.fileExtension, "md")
        XCTAssertEqual(ExportFormat.plainText.fileExtension, "txt")
        XCTAssertEqual(ExportFormat.json.fileExtension, "json")
    }
}
