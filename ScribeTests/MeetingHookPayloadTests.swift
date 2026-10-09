import XCTest
@testable import Scribe

/// Post-meeting hooks: the stdin JSON contract and the process runner.
final class MeetingHookPayloadTests: XCTestCase {

    private func fixture(summary: MeetingSummary? = nil, completed: Set<UUID> = []) -> MeetingHookPayload {
        let session = Session(
            id: "session-1",
            title: "Weekly sync",
            createdAt: Date(timeIntervalSince1970: 1_715_000_000),
            endedAt: Date(timeIntervalSince1970: 1_715_000_090),
            durationSeconds: 90,
            language: "en-US",
            tags: ["team"],
            noteId: "note-1"
        )
        let segments = [
            Segment(sessionId: "session-1", startMs: 0, endMs: 1_500, speaker: "you", text: "Morning."),
            Segment(sessionId: "session-1", startMs: 1_500, endMs: 3_000, speaker: "remote", text: "Hi!"),
            Segment(sessionId: "session-1", startMs: 3_000, endMs: 4_000, speaker: "remote", text: "Me.",
                    speakerOverride: "Sam"),
        ]
        let resolver = SpeakerNameResolver(sessionNames: ["remote": "Priya"], defaultYouName: "Varij")
        return MeetingHookPayload.make(
            session: session,
            segments: segments,
            speakerNames: resolver,
            noteTitle: "Weekly sync",
            notePath: "/tmp/Weekly sync.md",
            summary: summary,
            completedActionItemIds: completed
        )
    }

    private func jsonObject(_ payload: MeetingHookPayload) throws -> [String: Any] {
        let data = try payload.jsonData()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTopLevelKeysAreStableAndAlwaysPresent() throws {
        let object = try jsonObject(fixture())
        XCTAssertEqual(Set(object.keys), [
            "schema_version", "event", "session_id", "title", "note_id", "note_title", "note_path",
            "started_at", "ended_at", "duration_seconds", "language", "tags", "speakers", "segments",
            "summary", "action_items", "transcript_markdown",
        ])
        XCTAssertTrue(object["summary"] is NSNull, "absent summary is an explicit null")
        XCTAssertEqual((object["action_items"] as? [Any])?.count, 0)
    }

    func testValues() throws {
        let object = try jsonObject(fixture())
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(object["event"] as? String, "meeting.ended")
        XCTAssertEqual(object["session_id"] as? String, "session-1")
        XCTAssertEqual(object["note_id"] as? String, "note-1")
        XCTAssertEqual(object["note_path"] as? String, "/tmp/Weekly sync.md")
        XCTAssertEqual(object["started_at"] as? String, "2024-05-06T12:53:20Z")
        XCTAssertEqual(object["ended_at"] as? String, "2024-05-06T12:54:50Z")
        XCTAssertEqual(object["duration_seconds"] as? Int, 90)
        XCTAssertEqual(object["speakers"] as? [String], ["Varij", "Priya", "Sam"])

        let segments = try XCTUnwrap(object["segments"] as? [[String: Any]])
        XCTAssertEqual(Set(segments[0].keys), ["start_ms", "end_ms", "speaker", "speaker_key", "text"])
        XCTAssertEqual(segments[1]["speaker"] as? String, "Priya")
        XCTAssertEqual(segments[1]["speaker_key"] as? String, "remote")
        XCTAssertEqual(segments[2]["speaker"] as? String, "Sam")
        XCTAssertEqual(segments[2]["speaker_key"] as? String, "Sam")

        let markdown = try XCTUnwrap(object["transcript_markdown"] as? String)
        XCTAssertTrue(markdown.hasPrefix("# Weekly sync"))
        XCTAssertTrue(markdown.contains("Priya:"))
    }

    func testSummaryAndActionItems() throws {
        let done = UUID()
        let summary = MeetingSummary(
            id: UUID(),
            sessionId: "session-1",
            summary: "We agreed to ship.",
            keyDecisions: ["Ship Friday"],
            actionItems: [
                ActionItem(id: done, description: "Send deck", assignee: "Priya", deadline: nil,
                           priority: .high, sourceText: "…"),
                ActionItem(id: UUID(), description: "Book room", assignee: nil, deadline: "Mon",
                           priority: nil, sourceText: "…"),
            ],
            keyTopics: ["Launch"],
            followUpQuestions: [],
            createdAt: Date()
        )
        let object = try jsonObject(fixture(summary: summary, completed: [done]))
        let summaryObject = try XCTUnwrap(object["summary"] as? [String: Any])
        XCTAssertEqual(Set(summaryObject.keys), ["text", "key_decisions", "key_topics", "follow_up_questions"])
        XCTAssertEqual(summaryObject["text"] as? String, "We agreed to ship.")

        let items = try XCTUnwrap(object["action_items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items[1].keys), ["description", "assignee", "deadline", "priority", "completed"])
        XCTAssertEqual(items[0]["priority"] as? String, "High")
        XCTAssertEqual(items[0]["completed"] as? Bool, true)
        XCTAssertTrue(items[1]["assignee"] is NSNull)
        XCTAssertEqual(items[1]["completed"] as? Bool, false)
    }

    func testOutputIsDeterministicAndRoundTrips() throws {
        let payload = fixture()
        let first = try payload.jsonData()
        XCTAssertEqual(first, try payload.jsonData())
        let text = try XCTUnwrap(String(data: first, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("{\"action_items\":"), "keys are sorted")
        XCTAssertTrue(text.contains("/tmp/Weekly sync.md"), "slashes are not escaped")
        XCTAssertEqual(try JSONDecoder().decode(MeetingHookPayload.self, from: first), payload)
    }

    // MARK: - Runner

    private func makeScript(_ body: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-hook-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testRunnerPipesStdinAndEnvironment() async throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-hook-out-\(UUID().uuidString).json")
        let script = try makeScript("cat > \"$SCRIBE_NOTE_PATH\"; test \"$SCRIBE_SESSION_ID\" = \"abc\"")
        defer {
            try? FileManager.default.removeItem(atPath: script)
            try? FileManager.default.removeItem(at: out)
        }
        let input = Data("{\"hello\":1}".utf8)
        let result = await MeetingHookRunner.run(
            executablePath: script,
            stdin: input,
            environment: ["SCRIBE_NOTE_PATH": out.path, "SCRIBE_SESSION_ID": "abc"],
            timeout: 10
        )
        XCTAssertTrue(result.succeeded, result.failureDescription)
        XCTAssertEqual(try Data(contentsOf: out), input)
    }

    func testRunnerReportsFailureStatusAndStderr() async throws {
        let script = try makeScript("echo boom >&2; exit 3")
        defer { try? FileManager.default.removeItem(atPath: script) }
        let result = await MeetingHookRunner.run(executablePath: script, stdin: Data(), environment: [:], timeout: 10)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertTrue(result.stderr.contains("boom"))
    }

    func testRunnerTimesOut() async throws {
        let script = try makeScript("sleep 30")
        defer { try? FileManager.default.removeItem(atPath: script) }
        let result = await MeetingHookRunner.run(executablePath: script, stdin: Data(), environment: [:], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
    }

    func testRunnerRejectsNonExecutable() async {
        let result = await MeetingHookRunner.run(executablePath: "/nonexistent/hook", stdin: Data(),
                                                 environment: [:], timeout: 1)
        XCTAssertNotNil(result.launchError)
        XCTAssertFalse(result.succeeded)
    }
}
