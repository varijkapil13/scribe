import XCTest
import Combine
import GRDB
@testable import Scribe

/// Real GRDB integration tests using an in-memory SQLite database.
///
/// These tests exercise the full storage stack — migrations, FTS5 triggers,
/// foreign-key cascades, JSON-encoded columns, and the Combine observation
/// pipeline — to catch regressions a pure unit test against mocks would miss.
final class DatabaseIntegrationTests: XCTestCase {

    // MARK: - Fixture

    private var manager: DatabaseManager!
    private var store: TranscriptStore!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        // Each test gets a fresh in-memory DB so they're independent.
        manager = try DatabaseManager(path: ":memory:")
        store = TranscriptStore(databaseManager: manager)
        cancellables.removeAll()
    }

    override func tearDown() {
        cancellables.removeAll()
        store = nil
        manager = nil
    }

    // MARK: - Session lifecycle

    func testCreateThenFetchSessionRoundTrip() throws {
        let created = try store.createSession(title: "Standup")

        let fetched = try store.fetchSession(id: created.id)
        XCTAssertEqual(fetched?.id, created.id)
        XCTAssertEqual(fetched?.title, "Standup")
        XCTAssertNil(fetched?.endedAt)
        XCTAssertNil(fetched?.durationSeconds)
        XCTAssertEqual(fetched?.tags, [])
    }

    func testEndSessionStampsDurationAndEndedAt() throws {
        let session = try store.createSession(title: "Brief")
        // Simulate a small delay so duration is non-zero.
        Thread.sleep(forTimeInterval: 1.05)

        try store.endSession(id: session.id)

        let updated = try XCTUnwrap(store.fetchSession(id: session.id))
        XCTAssertNotNil(updated.endedAt)
        XCTAssertGreaterThanOrEqual(updated.durationSeconds ?? 0, 1)
    }

    func testEndSessionOnMissingIdIsNoOp() throws {
        // Should not throw — ends are tolerant of stale IDs (e.g. crash recovery).
        XCTAssertNoThrow(try store.endSession(id: "nope"))
    }

    func testFetchAllSessionsOrderedNewestFirst() throws {
        let first = try store.createSession(title: "First")
        Thread.sleep(forTimeInterval: 0.02)
        let second = try store.createSession(title: "Second")
        Thread.sleep(forTimeInterval: 0.02)
        let third = try store.createSession(title: "Third")

        let all = try store.fetchAllSessions()
        XCTAssertEqual(all.map(\.id), [third.id, second.id, first.id])
    }

    func testUpdateSessionPersistsTitleAndTags() throws {
        var session = try store.createSession(title: "Tmp")
        session.title = "Q3 Roadmap"
        session.tags = ["planning", "exec", "q3"]
        try store.updateSession(session)

        let fetched = try XCTUnwrap(store.fetchSession(id: session.id))
        XCTAssertEqual(fetched.title, "Q3 Roadmap")
        XCTAssertEqual(fetched.tags.sorted(), ["exec", "planning", "q3"])
    }

    func testTagsSurviveJSONRoundTripWithUnicode() throws {
        var session = try store.createSession(title: "Localized")
        session.tags = ["日本語", "café", "🚀"]
        try store.updateSession(session)

        let reloaded = try XCTUnwrap(store.fetchSession(id: session.id))
        XCTAssertEqual(reloaded.tags, ["日本語", "café", "🚀"])
    }

    // MARK: - Segments

    func testAddAndFetchSegmentsOrderedByStartMs() throws {
        let session = try store.createSession(title: "Order")

        // Insert deliberately out of order — store must still return ordered.
        try store.addSegment(sessionId: session.id, startMs: 5_000, endMs: 6_000, speaker: "you", text: "third")
        try store.addSegment(sessionId: session.id, startMs: 1_000, endMs: 2_000, speaker: "remote", text: "first")
        try store.addSegment(sessionId: session.id, startMs: 3_000, endMs: 4_000, speaker: "you", text: "second")

        let segments = try store.fetchSegments(sessionId: session.id)
        XCTAssertEqual(segments.map(\.text), ["first", "second", "third"])
        XCTAssertEqual(segments.map(\.speaker), ["remote", "you", "you"])

        // ID auto-increment populated.
        for s in segments {
            XCTAssertNotNil(s.id)
            XCTAssertGreaterThan(s.id ?? 0, 0)
        }
    }

    func testDeleteSessionCascadesToSegments() throws {
        let session = try store.createSession(title: "Cascade")
        try store.addSegment(sessionId: session.id, startMs: 0, endMs: 1, speaker: "you", text: "hi")
        try store.addSegment(sessionId: session.id, startMs: 1, endMs: 2, speaker: "you", text: "again")

        try store.deleteSession(id: session.id)

        XCTAssertNil(try store.fetchSession(id: session.id))
        XCTAssertEqual(try store.fetchSegments(sessionId: session.id), [])
    }

    func testSegmentsWithSpecialCharsPersistVerbatim() throws {
        let session = try store.createSession(title: "Quotes")
        let weird = #"O'Reilly said "let's ship it"; tag: <foo>"#
        try store.addSegment(sessionId: session.id, startMs: 0, endMs: 1, speaker: "you", text: weird)

        let segments = try store.fetchSegments(sessionId: session.id)
        XCTAssertEqual(segments.first?.text, weird)
    }

    func testBulkDeleteAllRemovesAllSessionsAndSegments() throws {
        let s1 = try store.createSession(title: "A")
        let s2 = try store.createSession(title: "B")
        try store.addSegment(sessionId: s1.id, startMs: 0, endMs: 1, speaker: "you", text: "x")
        try store.addSegment(sessionId: s2.id, startMs: 0, endMs: 1, speaker: "you", text: "y")

        try store.deleteAllData()

        XCTAssertEqual(try store.fetchAllSessions(), [])
        XCTAssertEqual(try store.fetchSegments(sessionId: s1.id), [])
    }

    // MARK: - Full-Text Search (FTS5)

    func testSearchTranscriptsMatchesSegmentAcrossSessions() throws {
        let alpha = try store.createSession(title: "Alpha")
        let beta = try store.createSession(title: "Beta")
        try store.addSegment(sessionId: alpha.id, startMs: 0, endMs: 1, speaker: "you", text: "Discussed roadmap and budget")
        try store.addSegment(sessionId: alpha.id, startMs: 1, endMs: 2, speaker: "remote", text: "OK")
        try store.addSegment(sessionId: beta.id, startMs: 0, endMs: 1, speaker: "you", text: "No relevant content here")

        let hits = try store.searchTranscripts(query: "budget")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.0.id, alpha.id)
        XCTAssertEqual(hits.first?.1.first?.text, "Discussed roadmap and budget")
    }

    func testSearchTranscriptsReflectsUpdatesViaTriggers() throws {
        let session = try store.createSession(title: "Mutate")
        try store.addSegment(
            sessionId: session.id,
            startMs: 0, endMs: 1,
            speaker: "you",
            text: "original content"
        )

        // No match yet.
        XCTAssertTrue(try store.searchTranscripts(query: "rewritten").isEmpty)

        // Update via the canonical UPDATE statement to exercise the AU trigger
        // — fetchOne ensures the segment row carries its auto-increment id.
        try manager.database.write { db in
            var fetched = try Segment
                .filter(Column("sessionId") == session.id)
                .fetchOne(db)!
            fetched.text = "rewritten content"
            try fetched.update(db)
        }

        let hits = try store.searchTranscripts(query: "rewritten")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.1.first?.text, "rewritten content")

        // Old text no longer matches (delete trigger fired).
        XCTAssertTrue(try store.searchTranscripts(query: "original").isEmpty)
    }

    func testSearchEmptyResultsForUnknownTerm() throws {
        let s = try store.createSession(title: "Empty")
        try store.addSegment(sessionId: s.id, startMs: 0, endMs: 1, speaker: "you", text: "hello")
        XCTAssertEqual(try store.searchTranscripts(query: "xyzzy").count, 0)
    }

    // MARK: - Combine Observation

    func testObserveSegmentsEmitsOnInsert() throws {
        let session = try store.createSession(title: "Live")
        let exp = expectation(description: "publisher emits initial then updated")
        exp.expectedFulfillmentCount = 2

        var snapshots: [[Segment]] = []
        store.observeSegments(sessionId: session.id)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { value in
                    snapshots.append(value)
                    exp.fulfill()
                }
            )
            .store(in: &cancellables)

        try store.addSegment(sessionId: session.id, startMs: 0, endMs: 1, speaker: "you", text: "live one")
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(snapshots.first?.count, 0)
        XCTAssertEqual(snapshots.last?.count, 1)
        XCTAssertEqual(snapshots.last?.first?.text, "live one")
    }

    // MARK: - Meeting Summaries

    func testSaveAndFetchSummaryWithActionItems() throws {
        let session = try store.createSession(title: "Strategy")
        let summary = MeetingSummary(
            id: UUID(),
            sessionId: session.id,
            summary: "Quarterly priorities aligned.",
            keyDecisions: ["Ship v1 by EOM", "Defer iOS app"],
            actionItems: [
                ActionItem(
                    id: UUID(),
                    description: "Draft launch plan",
                    assignee: "Alex",
                    deadline: "Friday",
                    priority: .high,
                    sourceText: "Alex will draft the launch plan by Friday."
                ),
                ActionItem(
                    id: UUID(),
                    description: "Update pricing page",
                    assignee: nil,
                    deadline: nil,
                    priority: .medium,
                    sourceText: "We need to refresh the pricing page."
                ),
            ],
            keyTopics: ["Launch", "Pricing"],
            followUpQuestions: ["Who owns docs?"],
            createdAt: Date()
        )

        try store.saveSummary(summary)

        let loaded = try XCTUnwrap(store.fetchSummary(sessionId: session.id))
        XCTAssertEqual(loaded.summary, "Quarterly priorities aligned.")
        XCTAssertEqual(loaded.keyDecisions, ["Ship v1 by EOM", "Defer iOS app"])
        XCTAssertEqual(loaded.keyTopics, ["Launch", "Pricing"])
        XCTAssertEqual(loaded.followUpQuestions, ["Who owns docs?"])
        XCTAssertEqual(loaded.actionItems.count, 2)
        XCTAssertEqual(Set(loaded.actionItems.map(\.description)),
                       Set(["Draft launch plan", "Update pricing page"]))
    }

    func testSaveSummaryReplacesExistingSummary() throws {
        let session = try store.createSession(title: "Replace")
        let first = MeetingSummary(
            id: UUID(),
            sessionId: session.id,
            summary: "Initial",
            keyDecisions: [],
            actionItems: [],
            keyTopics: [],
            followUpQuestions: [],
            createdAt: Date()
        )
        try store.saveSummary(first)

        // INSERT OR REPLACE should kick in via session_id key.
        let replacement = MeetingSummary(
            id: UUID(),
            sessionId: session.id,
            summary: "Revised",
            keyDecisions: ["A"],
            actionItems: [],
            keyTopics: [],
            followUpQuestions: [],
            createdAt: Date()
        )
        try store.saveSummary(replacement)

        let loaded = try XCTUnwrap(store.fetchSummary(sessionId: session.id))
        XCTAssertEqual(loaded.summary, "Revised")
        XCTAssertEqual(loaded.keyDecisions, ["A"])
    }

    func testDeleteSummaryRemovesRow() throws {
        let session = try store.createSession(title: "Cleanup")
        let summary = MeetingSummary(
            id: UUID(),
            sessionId: session.id,
            summary: "Summary",
            keyDecisions: [],
            actionItems: [],
            keyTopics: [],
            followUpQuestions: [],
            createdAt: Date()
        )
        try store.saveSummary(summary)
        XCTAssertNotNil(try store.fetchSummary(sessionId: session.id))

        try store.deleteSummary(sessionId: session.id)
        XCTAssertNil(try store.fetchSummary(sessionId: session.id))
    }

    // MARK: - Action Items

    func testToggleActionItemCompletionFlipsState() throws {
        let session = try store.createSession(title: "Toggle")
        let item = ActionItem(
            id: UUID(),
            description: "Send recap",
            assignee: "Sam",
            deadline: nil,
            priority: .low,
            sourceText: "Sam will send the recap."
        )
        try store.saveActionItems([item], sessionId: session.id, summaryId: nil)

        XCTAssertTrue(try store.fetchCompletedActionItemIds(sessionId: session.id).isEmpty)

        try store.toggleActionItemCompletion(id: item.id.uuidString)
        XCTAssertEqual(try store.fetchCompletedActionItemIds(sessionId: session.id), [item.id])

        // Toggle again — should clear.
        try store.toggleActionItemCompletion(id: item.id.uuidString)
        XCTAssertTrue(try store.fetchCompletedActionItemIds(sessionId: session.id).isEmpty)
    }

    func testFetchAllPendingActionItemsExcludesCompleted() throws {
        let s1 = try store.createSession(title: "Active")
        let s2 = try store.createSession(title: "Other")
        let pending = ActionItem(
            id: UUID(), description: "Open task",
            assignee: nil, deadline: nil, priority: .medium, sourceText: ""
        )
        let done = ActionItem(
            id: UUID(), description: "Done task",
            assignee: nil, deadline: nil, priority: .high, sourceText: ""
        )
        try store.saveActionItems([pending], sessionId: s1.id, summaryId: nil)
        try store.saveActionItems([done], sessionId: s2.id, summaryId: nil)
        try store.toggleActionItemCompletion(id: done.id.uuidString)

        let allPending = try store.fetchAllPendingActionItems()
        XCTAssertEqual(allPending.count, 1)
        XCTAssertEqual(allPending.first?.0.description, "Open task")
        XCTAssertEqual(allPending.first?.1.id, s1.id)
    }

    func testSaveActionItemsReplacesPriorWithoutSummary() throws {
        let s = try store.createSession(title: "Replace items")
        let v1 = ActionItem(id: UUID(), description: "Old", assignee: nil, deadline: nil, priority: nil, sourceText: "")
        try store.saveActionItems([v1], sessionId: s.id, summaryId: nil)
        XCTAssertEqual(try store.fetchActionItems(sessionId: s.id).count, 1)

        let v2 = ActionItem(id: UUID(), description: "New", assignee: nil, deadline: nil, priority: nil, sourceText: "")
        try store.saveActionItems([v2], sessionId: s.id, summaryId: nil)

        let items = try store.fetchActionItems(sessionId: s.id)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.description, "New")
    }

    // MARK: - Entities

    func testSaveEntitiesReplacesAllExisting() throws {
        let s = try store.createSession(title: "Entities")
        let first = [
            ExtractedEntity(id: UUID(), text: "Alice", type: .person, range: nil, segmentId: nil),
            ExtractedEntity(id: UUID(), text: "ACME", type: .organization, range: nil, segmentId: nil),
        ]
        try store.saveEntities(first, sessionId: s.id)
        XCTAssertEqual(try store.fetchEntities(sessionId: s.id).count, 2)

        let second = [
            ExtractedEntity(id: UUID(), text: "Bob", type: .person, range: nil, segmentId: nil),
        ]
        try store.saveEntities(second, sessionId: s.id)

        let loaded = try store.fetchEntities(sessionId: s.id)
        XCTAssertEqual(loaded.map(\.text), ["Bob"])
    }

    // MARK: - Migrations

    func testMigrationsCreateAllTables() throws {
        // If the migrator ran cleanly, all expected tables and the FTS shadow exist.
        let names: [String] = try manager.database.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table','view') ORDER BY name")
        }
        for expected in ["sessions", "segments", "segments_fts", "meeting_summaries", "action_items", "extracted_entities"] {
            XCTAssertTrue(names.contains(expected), "missing table: \(expected) in \(names)")
        }
    }
}
