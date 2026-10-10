import XCTest
import GRDB
@testable import Scribe

/// Meeting copilot bookmarks: the `v22_session_bookmarks` table, the store,
/// and the pure formatting (highlights, prompt emphasis, timeline markers).
final class SessionBookmarkTests: XCTestCase {

    // MARK: - Fixtures

    private func makeStores() throws -> (DatabaseManager, SessionBookmarkStore, TranscriptStore, Session) {
        let dbm = try DatabaseManager(path: ":memory:")
        let session = Session(title: "Weekly Sync")
        try dbm.database.write { try session.insert($0) }
        return (dbm, SessionBookmarkStore(databaseManager: dbm), TranscriptStore(databaseManager: dbm), session)
    }

    private func segment(_ start: Int, _ end: Int, _ speaker: String, _ text: String) -> Segment {
        Segment(sessionId: "s", startMs: start, endMs: end, speaker: speaker, text: text)
    }

    private func bookmark(_ offset: Int, _ label: String? = nil, id: Int64? = nil) -> SessionBookmark {
        SessionBookmark(id: id, sessionId: "s", offsetMs: offset, label: label, createdAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Migration / store

    func testMigrationCreatesBookmarksTable() throws {
        let dbm = try DatabaseManager(path: ":memory:")
        try dbm.database.read { db in
            XCTAssertTrue(try db.tableExists("session_bookmarks"))
            let columns = Set(try db.columns(in: "session_bookmarks").map(\.name))
            XCTAssertEqual(columns, ["id", "sessionId", "offsetMs", "label", "createdAt"])
            let applied = try DatabaseManager.makeMigrator().appliedMigrations(db)
            XCTAssertTrue(applied.contains("v22_session_bookmarks"))
        }
    }

    func testAddFetchRenameDelete() throws {
        let (_, store, _, session) = try makeStores()
        try store.add(sessionId: session.id, offsetMs: 5_000, label: "  Pricing   call ", createdAt: Date())
        try store.add(sessionId: session.id, offsetMs: 1_000, label: "   ", createdAt: Date())
        try store.add(sessionId: session.id, offsetMs: -20, label: nil, createdAt: Date())

        var fetched = try store.fetch(sessionId: session.id)
        XCTAssertEqual(fetched.map(\.offsetMs), [0, 1_000, 5_000])
        XCTAssertEqual(fetched.map(\.label), [nil, nil, "Pricing call"])
        XCTAssertTrue(fetched.allSatisfy { $0.id != nil })

        let target = try XCTUnwrap(fetched.first { $0.offsetMs == 1_000 })
        let targetId = try XCTUnwrap(target.id)
        try store.updateLabel(id: targetId, label: "Deadline")
        fetched = try store.fetch(sessionId: session.id)
        XCTAssertEqual(fetched.first(where: { $0.offsetMs == 1_000 })?.label, "Deadline")

        try store.delete(id: targetId)
        fetched = try store.fetch(sessionId: session.id)
        XCTAssertEqual(fetched.map(\.offsetMs), [0, 5_000])
        XCTAssertEqual(try store.fetch(sessionId: "other"), [])
    }

    func testDeletingSessionRemovesBookmarks() throws {
        let (_, store, transcripts, session) = try makeStores()
        try store.add(sessionId: session.id, offsetMs: 2_000, label: "x", createdAt: Date())
        XCTAssertEqual(try store.fetch(sessionId: session.id).count, 1)
        try transcripts.deleteSession(id: session.id)
        XCTAssertEqual(try store.fetch(sessionId: session.id).count, 0)
    }

    func testNormalizedLabel() {
        XCTAssertNil(SessionBookmarkStore.normalizedLabel(nil))
        XCTAssertNil(SessionBookmarkStore.normalizedLabel(" \n "))
        XCTAssertEqual(SessionBookmarkStore.normalizedLabel(" a \n b "), "a b")
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(SessionBookmarkStore.normalizedLabel(long)?.count, SessionBookmarkStore.maxLabelLength)
    }

    // MARK: - Timestamps

    func testTimestamps() {
        XCTAssertEqual(SessionBookmarkFormatter.shortTimestamp(ms: 0), "0:00")
        XCTAssertEqual(SessionBookmarkFormatter.shortTimestamp(ms: 65_400), "1:05")
        XCTAssertEqual(SessionBookmarkFormatter.shortTimestamp(ms: 3_723_000), "1:02:03")
        XCTAssertEqual(SessionBookmarkFormatter.shortTimestamp(ms: -5), "0:00")
        XCTAssertEqual(SessionBookmarkFormatter.promptTimestamp(ms: 65_000), "[00:01:05]")
        XCTAssertEqual(SessionBookmarkFormatter.promptTimestamp(ms: 3_723_000), "[01:02:03]")
    }

    // MARK: - Context

    func testContextIndex() {
        let segments = [
            segment(1_000, 5_000, "you", "Hello"),
            segment(10_000, 20_000, "remote", "We ship on the 14th."),
        ]
        XCTAssertNil(SessionBookmarkFormatter.contextIndex(offsetMs: 500, in: segments))
        XCTAssertEqual(SessionBookmarkFormatter.contextIndex(offsetMs: 3_000, in: segments), 0)
        XCTAssertEqual(SessionBookmarkFormatter.contextIndex(offsetMs: 15_000, in: segments), 1)
        // Shortly after the line ended: still that line.
        XCTAssertEqual(SessionBookmarkFormatter.contextIndex(offsetMs: 25_000, in: segments), 1)
        // Long silence: no context.
        XCTAssertNil(SessionBookmarkFormatter.contextIndex(offsetMs: 60_000, in: segments))
        XCTAssertNil(SessionBookmarkFormatter.contextIndex(offsetMs: 1_000, in: []))
    }

    func testQuoteShortensLongText() {
        XCTAssertEqual(SessionBookmarkFormatter.quote("  a   b  "), "a b")
        let quoted = SessionBookmarkFormatter.quote(String(repeating: "word ", count: 100), maxChars: 20)
        XCTAssertLessThanOrEqual(quoted.count, 20)
        XCTAssertTrue(quoted.hasSuffix("…"))
    }

    // MARK: - Highlights

    func testHighlightLineVariants() {
        let segments = [segment(60_000, 70_000, "remote", "We ship on the 14th.")]
        let name: (Segment) -> String = { _ in "Priya" }

        XCTAssertEqual(
            SessionBookmarkFormatter.highlightLine(bookmark(65_000, "Pricing"), segments: segments, speakerName: name),
            "- **1:05** Pricing — Priya: “We ship on the 14th.”"
        )
        XCTAssertEqual(
            SessionBookmarkFormatter.highlightLine(bookmark(65_000), segments: segments, speakerName: name),
            "- **1:05** Priya: “We ship on the 14th.”"
        )
        XCTAssertEqual(
            SessionBookmarkFormatter.highlightLine(bookmark(5_000), segments: segments, speakerName: name),
            "- **0:05** Marked moment"
        )
        XCTAssertEqual(
            SessionBookmarkFormatter.highlightLine(bookmark(5_000, "Intro"), segments: segments, speakerName: name),
            "- **0:05** Intro"
        )
    }

    func testHighlightsMarkdownSortsAndNoteBlock() {
        let segments = [segment(0, 2_000, "you", "Hi")]
        let list = SessionBookmarkFormatter.highlightsMarkdown(
            bookmarks: [bookmark(90_000, "B"), bookmark(1_000, "A")],
            segments: segments,
            speakerName: { $0.speaker }
        )
        XCTAssertEqual(list, "- **0:01** A — you: “Hi”\n- **1:30** B")

        XCTAssertNil(SessionBookmarkFormatter.noteBlockContent(bookmarks: [], segments: segments, speakerName: { $0.speaker }))
        let block = SessionBookmarkFormatter.noteBlockContent(
            bookmarks: [bookmark(1_000, "A")], segments: segments, speakerName: { $0.speaker }
        )
        XCTAssertEqual(block, "## Highlights\n\n- **0:01** A — you: “Hi”")
    }

    func testHighlightsBlockUpsertsIntoNoteBody() {
        let first = NoteAIEdit.upsertBlock(kind: SessionBookmarkFormatter.noteBlockKind, id: "s1", markdown: "## Highlights\n\n- one")
            .apply(to: "My notes\n")
        XCTAssertTrue(first.hasPrefix("My notes"))
        XCTAssertTrue(first.contains("<!-- scribe:highlights:s1 -->"))
        XCTAssertTrue(first.contains("- one"))

        let second = NoteAIEdit.upsertBlock(kind: SessionBookmarkFormatter.noteBlockKind, id: "s1", markdown: "## Highlights\n\n- two")
            .apply(to: first)
        XCTAssertFalse(second.contains("- one"))
        XCTAssertTrue(second.contains("- two"))
        XCTAssertEqual(NoteScribeBlocks.blocks(in: second).count, 1)
    }

    // MARK: - Prompt emphasis

    func testEmphasisSection() throws {
        XCTAssertNil(SessionBookmarkFormatter.emphasisSection(bookmarks: []))
        let section = try XCTUnwrap(SessionBookmarkFormatter.emphasisSection(
            bookmarks: [bookmark(120_000), bookmark(65_000, "Pricing")]
        ))
        XCTAssertTrue(section.hasPrefix("HIGHLIGHTED MOMENTS:"))
        let pricing = try XCTUnwrap(section.range(of: "- [00:01:05] Pricing"))
        let unlabeled = try XCTUnwrap(section.range(of: "- [00:02:00] (no label)"))
        XCTAssertLessThan(pricing.lowerBound, unlabeled.lowerBound, "Moments are listed in order")

        let many = (0..<30).map { bookmark($0 * 1_000) }
        let capped = try XCTUnwrap(SessionBookmarkFormatter.emphasisSection(bookmarks: many, limit: 5))
        XCTAssertEqual(capped.components(separatedBy: "\n- [").count - 1, 5)
    }

    // MARK: - Markers

    func testMarkerFraction() {
        XCTAssertEqual(SessionBookmarkFormatter.markerFraction(offsetMs: 30_000, durationSeconds: 60), 0.5)
        XCTAssertEqual(SessionBookmarkFormatter.markerFraction(offsetMs: 90_000, durationSeconds: 60), 1)
        XCTAssertEqual(SessionBookmarkFormatter.markerFraction(offsetMs: -1, durationSeconds: 60), 0)
        XCTAssertNil(SessionBookmarkFormatter.markerFraction(offsetMs: 1_000, durationSeconds: 0))
        XCTAssertNil(SessionBookmarkFormatter.markerFraction(offsetMs: 1_000, durationSeconds: .nan))
    }

    // MARK: - Settings

    func testCopilotSettingsDefaultsAndClamping() throws {
        let suite = "CopilotSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(CopilotSettings.liveSummaryEnabled(defaults))
        XCTAssertEqual(CopilotSettings.intervalMinutes(defaults), 2)
        XCTAssertTrue(CopilotSettings.highlightsInNote(defaults))
        XCTAssertTrue(CopilotSettings.briefNotificationsEnabled(defaults))
        XCTAssertEqual(CopilotSettings.briefLeadMinutes(defaults), 5)

        defaults.set(false, forKey: CopilotSettings.liveSummaryEnabledKey)
        defaults.set(50, forKey: CopilotSettings.liveSummaryIntervalKey)
        defaults.set(0, forKey: CopilotSettings.briefLeadMinutesKey)
        XCTAssertFalse(CopilotSettings.liveSummaryEnabled(defaults))
        XCTAssertEqual(CopilotSettings.intervalMinutes(defaults), 10)
        XCTAssertEqual(CopilotSettings.briefLeadMinutes(defaults), 1)
    }
}
