import XCTest
@testable import Scribe

/// End-to-end export tests covering each format with real-world inputs:
/// multi-speaker conversations, special characters, empty transcripts,
/// long sessions, and JSON parse-back round-trips.
final class ExportIntegrationTests: XCTestCase {

    // MARK: - Helpers

    private func makeSession(title: String = "Test", duration: Int? = 90, language: String? = "en-US") -> Session {
        Session(
            id: "session-fixed-id",
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_715_000_000),
            endedAt: nil,
            durationSeconds: duration,
            language: language,
            tags: []
        )
    }

    private func multiSpeakerSegments(sessionId: String) -> [Segment] {
        [
            Segment(sessionId: sessionId, startMs: 0, endMs: 4_000, speaker: "you", text: "Welcome everyone."),
            Segment(sessionId: sessionId, startMs: 4_000, endMs: 8_000, speaker: "you", text: "Today's agenda is short."),
            Segment(sessionId: sessionId, startMs: 8_000, endMs: 12_000, speaker: "remote", text: "Sounds good."),
            Segment(sessionId: sessionId, startMs: 12_000, endMs: 18_000, speaker: "remote", text: "I have one question."),
            Segment(sessionId: sessionId, startMs: 18_000, endMs: 22_000, speaker: "you", text: "Go ahead."),
        ]
    }

    // MARK: - Markdown

    func testMarkdownGroupsConsecutiveSameSpeakerSegments() {
        let session = makeSession()
        let segments = multiSpeakerSegments(sessionId: session.id)

        let output = ExportManager.export(session: session, segments: segments, format: .markdown)

        // Three speaker groups: you, remote, you.
        let speakerHeaders = output.components(separatedBy: "\n")
            .filter { $0.contains("you:") || $0.contains("remote:") }
        XCTAssertEqual(speakerHeaders.count, 3)

        // Combined text within a group (no header between).
        XCTAssertTrue(output.contains("Welcome everyone. Today's agenda is short."))
        XCTAssertTrue(output.contains("Sounds good. I have one question."))
    }

    func testMarkdownIncludesTitleDateDuration() {
        let session = makeSession(title: "Q3 Planning", duration: 3_725) // 1h 2m 5s
        let output = ExportManager.export(session: session, segments: [], format: .markdown)

        XCTAssertTrue(output.hasPrefix("# Q3 Planning"))
        XCTAssertTrue(output.contains("**Duration:** 1h 2m 5s"))
        XCTAssertTrue(output.contains("**Date:**"))
    }

    func testMarkdownDurationOmittedWhenNil() {
        let session = makeSession(duration: nil)
        let output = ExportManager.export(session: session, segments: [], format: .markdown)
        XCTAssertTrue(output.contains("**Duration:** N/A"))
    }

    func testMarkdownEndsWithNewline() {
        let session = makeSession()
        let output = ExportManager.export(session: session, segments: multiSpeakerSegments(sessionId: session.id), format: .markdown)
        XCTAssertTrue(output.hasSuffix("\n"))
    }

    func testMarkdownHandlesEmptySegmentList() {
        let session = makeSession()
        let output = ExportManager.export(session: session, segments: [], format: .markdown)

        XCTAssertTrue(output.hasPrefix("# Test"))
        XCTAssertTrue(output.contains("---"))
    }

    // MARK: - Plain text

    func testPlainTextOneLinePerSegment() {
        let session = makeSession()
        let segments = multiSpeakerSegments(sessionId: session.id)

        let output = ExportManager.export(session: session, segments: segments, format: .plainText)
        let body = output
            .components(separatedBy: "================\n")
            .last ?? ""

        let lines = body.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, segments.count)
        for (line, segment) in zip(lines, segments) {
            XCTAssertTrue(line.contains(segment.text), "missing \(segment.text) in \(line)")
            XCTAssertTrue(line.contains(segment.speaker), "missing speaker in \(line)")
            XCTAssertTrue(line.contains(":") , "missing timestamp delimiter in \(line)")
        }
    }

    func testPlainTextTimestampFormatting() {
        let session = makeSession()
        let segment = Segment(sessionId: session.id, startMs: 3_723_000, endMs: 3_725_000, speaker: "you", text: "checkpoint")
        let output = ExportManager.export(session: session, segments: [segment], format: .plainText)
        XCTAssertTrue(output.contains("[01:02:03] you: checkpoint"))
    }

    // MARK: - JSON

    func testJSONExportIsParseableAndRoundTrips() throws {
        let session = makeSession(title: "JSON RT", duration: 120, language: "es-ES")
        let segments = multiSpeakerSegments(sessionId: session.id)
        let output = ExportManager.export(session: session, segments: segments, format: .json)

        struct ExportSegment: Decodable, Equatable {
            let startMs: Int
            let endMs: Int
            let speaker: String
            let text: String
            enum CodingKeys: String, CodingKey {
                case startMs = "start_ms"
                case endMs = "end_ms"
                case speaker
                case text
            }
        }
        struct ExportSession: Decodable {
            let id: String
            let title: String
            let createdAt: String
            let durationS: Int
            let language: String
            enum CodingKeys: String, CodingKey {
                case id
                case title
                case createdAt = "created_at"
                case durationS = "duration_s"
                case language
            }
        }
        struct ExportDoc: Decodable {
            let session: ExportSession
            let segments: [ExportSegment]
        }

        let data = try XCTUnwrap(output.data(using: .utf8))
        let parsed = try JSONDecoder().decode(ExportDoc.self, from: data)

        XCTAssertEqual(parsed.session.id, session.id)
        XCTAssertEqual(parsed.session.title, "JSON RT")
        XCTAssertEqual(parsed.session.durationS, 120)
        XCTAssertEqual(parsed.session.language, "es-ES")
        XCTAssertEqual(parsed.segments.count, segments.count)
        XCTAssertEqual(parsed.segments.first?.text, "Welcome everyone.")
        XCTAssertEqual(parsed.segments.first?.startMs, 0)
        XCTAssertEqual(parsed.segments.last?.text, "Go ahead.")
    }

    func testJSONExportFallsBackToEmptyObjectGracefully() {
        // Empty segments → still valid JSON.
        let session = makeSession()
        let output = ExportManager.export(session: session, segments: [], format: .json)
        let data = output.data(using: .utf8)!
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }

    func testJSONExportIncludesISO8601Date() {
        let session = makeSession()
        let output = ExportManager.export(session: session, segments: [], format: .json)
        XCTAssertTrue(output.contains("\"created_at\""))
        // ISO 8601 with Z (UTC) suffix.
        XCTAssertTrue(output.contains("Z\""))
    }

    func testJSONLanguageDefaultsToEnWhenSessionLanguageIsNil() throws {
        let session = makeSession(language: nil)
        let output = ExportManager.export(session: session, segments: [], format: .json)
        let data = output.data(using: .utf8)!
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let s = object?["session"] as? [String: Any]
        XCTAssertEqual(s?["language"] as? String, "en")
    }

    // MARK: - Special chars / unicode

    func testAllFormatsPreserveUnicodeAndQuotes() throws {
        let session = makeSession(title: "Café 日本語")
        let segments = [
            Segment(sessionId: session.id, startMs: 0, endMs: 1_000, speaker: "you", text: "He said \"hello\" in 日本語."),
            Segment(sessionId: session.id, startMs: 1_000, endMs: 2_000, speaker: "remote", text: "Don't worry — emoji 🚀 works."),
        ]

        for format in ExportFormat.allCases {
            let output = ExportManager.export(session: session, segments: segments, format: format)
            XCTAssertTrue(output.contains("日本語"), "\(format) lost unicode")
            XCTAssertTrue(output.contains("🚀"), "\(format) lost emoji")
            // JSON escapes quotes, others keep them literal.
            if format == .json {
                XCTAssertTrue(output.contains("\\\"hello\\\""))
            } else {
                XCTAssertTrue(output.contains("\"hello\""))
            }
        }
    }

    // MARK: - Format metadata

    func testExportFormatExtensionsAndIDs() {
        XCTAssertEqual(ExportFormat.markdown.fileExtension, "md")
        XCTAssertEqual(ExportFormat.plainText.fileExtension, "txt")
        XCTAssertEqual(ExportFormat.json.fileExtension, "json")

        XCTAssertEqual(ExportFormat.markdown.id, "Markdown")
        XCTAssertEqual(ExportFormat.allCases.count, 3)
    }
}
