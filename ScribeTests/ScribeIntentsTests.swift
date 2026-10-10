import XCTest
import GRDB
@testable import Scribe

/// Pure helpers behind the App Intents layer (`ScribeIntentsText`), the
/// Focus-filter preferences, and the `NoteAIEdit.appendText` replay edit.
final class ScribeIntentsTextTests: XCTestCase {

    // MARK: - Append

    func testAppendAddsParagraphAfterTrimmedBody() {
        XCTAssertEqual(ScribeIntentsText.append("Second", to: "First\n\n\n"), "First\n\nSecond\n")
    }

    func testAppendToEmptyBody() {
        XCTAssertEqual(ScribeIntentsText.append("  Hello  ", to: ""), "Hello\n")
        XCTAssertEqual(ScribeIntentsText.append("Hello", to: " \n "), "Hello\n")
    }

    func testAppendBlankTextLeavesBodyUnchanged() {
        XCTAssertEqual(ScribeIntentsText.append(" \n", to: "Body"), "Body")
    }

    func testNoteAIEditAppendTextUsesSameRule() {
        XCTAssertEqual(NoteAIEdit.appendText("More").apply(to: "Body\n"), "Body\n\nMore\n")
    }

    // MARK: - Titles / matching

    func testDisplayTitleFallback() {
        XCTAssertEqual(ScribeIntentsText.displayTitle("  Plan  ", fallback: "Untitled"), "Plan")
        XCTAssertEqual(ScribeIntentsText.displayTitle(" \n", fallback: "Untitled"), "Untitled")
    }

    func testMatchesRequiresEveryToken() {
        XCTAssertTrue(ScribeIntentsText.matches(query: "weekly sync", in: ["Weekly Team Sync"]))
        XCTAssertTrue(ScribeIntentsText.matches(query: "cafe", in: ["Café chat"]))
        XCTAssertTrue(ScribeIntentsText.matches(query: "budget ana", in: ["Budget", "with Ana"]))
        XCTAssertFalse(ScribeIntentsText.matches(query: "weekly retro", in: ["Weekly Team Sync"]))
        XCTAssertTrue(ScribeIntentsText.matches(query: "  ", in: ["Anything"]))
    }

    func testSessionsMatchingTitleEventOrAttendee() {
        let standup = Session(id: "1", title: "Standup")
        let planning = Session(id: "2", title: "Recording", calendarEventTitle: "Q3 Planning")
        let oneOnOne = Session(id: "3", title: "1:1", attendees: [CalendarAttendee(name: "Dana Scully")])

        let all = [standup, planning, oneOnOne]
        XCTAssertEqual(ScribeIntentsText.sessions(all, matching: "standup").map(\.id), ["1"])
        XCTAssertEqual(ScribeIntentsText.sessions(all, matching: "planning").map(\.id), ["2"])
        XCTAssertEqual(ScribeIntentsText.sessions(all, matching: "scully").map(\.id), ["3"])
        XCTAssertEqual(ScribeIntentsText.sessions(all, matching: "").map(\.id), ["1", "2", "3"])
    }

    func testOrderedFollowsRequestedIds() {
        let items = ["b", "a", "c"]
        let ordered = ScribeIntentsText.ordered(items, byIds: ["c", "missing", "a", "c"], id: { $0 })
        XCTAssertEqual(ordered, ["c", "a"])
    }

    // MARK: - Summary text

    func testSummaryTextSections() {
        let summary = MeetingSummary(
            id: UUID(),
            sessionId: "s",
            summary: "We agreed on the plan.",
            keyDecisions: ["Ship Friday"],
            actionItems: [
                ActionItem(id: UUID(), description: "Write notes", assignee: "Ana", deadline: "Monday", priority: nil, sourceText: ""),
            ],
            keyTopics: ["Release"],
            followUpQuestions: ["Who owns QA?"],
            createdAt: Date()
        )
        let text = ScribeIntentsText.summaryText(summary, title: "Sync")
        XCTAssertTrue(text.hasPrefix("Sync\n\nWe agreed on the plan."))
        XCTAssertTrue(text.contains("Decisions:\n• Ship Friday"))
        XCTAssertTrue(text.contains("• Write notes (Ana) — Monday"))
        XCTAssertTrue(text.contains("Open questions:\n• Who owns QA?"))
    }

    func testSummaryTextOmitsEmptySections() {
        let summary = MeetingSummary(
            id: UUID(), sessionId: "s", summary: "Short.", keyDecisions: [], actionItems: [],
            keyTopics: [], followUpQuestions: [], createdAt: Date()
        )
        XCTAssertEqual(ScribeIntentsText.summaryText(summary, title: nil), "Short.")
    }
}

/// The "Scribe Focus" filter's stored flags and how notification code reads
/// them.
final class ScribeFocusPreferencesTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ScribeFocusPreferencesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultsAreOff() {
        XCTAssertFalse(ScribeFocusPreferences.isMutingMeetingPrompts(defaults))
        XCTAssertFalse(ScribeFocusPreferences.isHidingReminders(defaults))
    }

    func testApplyStoresBothFlags() {
        ScribeFocusPreferences.apply(muteMeetingPrompts: true, hideReminders: false, defaults: defaults)
        XCTAssertTrue(ScribeFocusPreferences.isMutingMeetingPrompts(defaults))
        XCTAssertFalse(ScribeFocusPreferences.isHidingReminders(defaults))

        // Focus off: the system re-runs the filter with the defaults.
        ScribeFocusPreferences.apply(muteMeetingPrompts: false, hideReminders: false, defaults: defaults)
        XCTAssertFalse(ScribeFocusPreferences.isMutingMeetingPrompts(defaults))
    }

    func testSuppressesOnlyReminderCategoriesWhileHiding() {
        let taskCategory = TaskReminderScheduler.categoryId
        XCTAssertTrue(ScribeFocusPreferences.shouldSuppressPresentation(categoryId: taskCategory, hidingReminders: true))
        XCTAssertFalse(ScribeFocusPreferences.shouldSuppressPresentation(categoryId: taskCategory, hidingReminders: false))
        XCTAssertFalse(ScribeFocusPreferences.shouldSuppressPresentation(
            categoryId: MeetingDetector.startCategoryId, hidingReminders: true
        ))
    }

    func testReminderCategoriesCoverCalendarReminders() {
        XCTAssertTrue(ScribeFocusPreferences.reminderCategoryIds.contains(CalendarReminderScheduler.categoryId))
        XCTAssertTrue(ScribeFocusPreferences.reminderCategoryIds.contains(CalendarReminderScheduler.categoryWithLinkId))
        XCTAssertTrue(ScribeFocusPreferences.reminderCategoryIds.contains(TaskReminderScheduler.categoryId))
    }
}

/// `ScribeIntentsData` against an in-memory database.
final class ScribeIntentsDataTests: XCTestCase {

    private var manager: DatabaseManager!
    private var data: ScribeIntentsData!

    override func setUpWithError() throws {
        manager = try DatabaseManager(path: ":memory:")
        data = ScribeIntentsData(
            dbManager: manager,
            noteStore: NoteStore(databaseManager: manager, fileStore: nil),
            taskStore: TaskStore(databaseManager: manager),
            transcriptStore: TranscriptStore(databaseManager: manager)
        )
    }

    override func tearDown() {
        data = nil
        manager = nil
    }

    func testNotesByIdsKeepRequestedOrder() throws {
        let first = try data.createNote(title: "First", body: "one")
        let second = try data.createNote(title: "Second", body: "two")
        let fetched = try data.notes(ids: [second.id, "missing", first.id])
        XCTAssertEqual(fetched.map(\.title), ["Second", "First"])
        XCTAssertEqual(try data.notes(ids: []).count, 0)
    }

    func testSearchNotesUsesFullText() throws {
        _ = try data.createNote(title: "Groceries", body: "apples and pears")
        _ = try data.createNote(title: "Work", body: "quarterly report")
        XCTAssertEqual(try data.searchNotes("pears").map(\.title), ["Groceries"])
        // Blank query: recent notes.
        XCTAssertEqual(Set(try data.searchNotes("  ").map(\.title)), ["Groceries", "Work"])
    }

    func testTodayTasksAndSuggestions() throws {
        let calendar = Calendar.current
        let now = Date()
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))
        let dueToday = try data.taskStore.createTask(title: "Today", dueAt: now)
        _ = try data.taskStore.createTask(title: "Later", dueAt: tomorrow.addingTimeInterval(3_600))
        _ = try data.taskStore.createTask(title: "Someday")

        XCTAssertEqual(try data.todayTasks(now: now).map(\.id), [dueToday.id])

        let suggested = try data.suggestedTasks(now: now)
        XCTAssertEqual(suggested.first?.id, dueToday.id)
        XCTAssertEqual(suggested.count, 3)
        XCTAssertEqual(Set(suggested.map(\.id)).count, 3, "Today's tasks aren't listed twice")
    }

    func testTasksByIds() throws {
        let task = try data.taskStore.createTask(title: "Ship", priority: .high)
        let fetched = try data.tasks(ids: [task.id])
        XCTAssertEqual(fetched.map(\.title), ["Ship"])
        XCTAssertEqual(fetched.first?.priority, .high)
    }

    func testMeetingsMatchingAndLatestFinished() throws {
        let note = try data.noteStore.createNote(title: "Meeting note")
        let older = try data.transcriptStore.createSession(title: "Design review", noteId: note.id)
        try data.transcriptStore.endSession(id: older.id)
        var newer = try data.transcriptStore.createSession(title: "Standup", noteId: note.id)
        newer.createdAt = Date().addingTimeInterval(60)
        try data.transcriptStore.updateSession(newer)

        XCTAssertEqual(try data.sessions(matching: "design").map(\.id), [older.id])
        // The newer session is still recording (no endedAt).
        XCTAssertEqual(try data.latestFinishedSession()?.id, older.id)
        XCTAssertEqual(try data.sessions(ids: [newer.id, older.id]).map(\.id), [newer.id, older.id])
    }

    func testSummaryAndTranscriptText() throws {
        let note = try data.noteStore.createNote(title: "Meeting note")
        let session = try data.transcriptStore.createSession(title: "Kickoff", noteId: note.id)
        XCTAssertNil(try data.summaryText(sessionId: session.id))
        XCTAssertNil(try data.transcriptText(sessionId: session.id))

        try data.transcriptStore.addSegment(sessionId: session.id, startMs: 0, endMs: 1_000, speaker: "Speaker 1", text: "Welcome everyone")
        try data.transcriptStore.saveSummary(MeetingSummary(
            id: UUID(), sessionId: session.id, summary: "Kicked off the project.", keyDecisions: [],
            actionItems: [], keyTopics: [], followUpQuestions: [], createdAt: Date()
        ))

        let summary = try XCTUnwrap(data.summaryText(sessionId: session.id))
        XCTAssertTrue(summary.contains("Kickoff"))
        XCTAssertTrue(summary.contains("Kicked off the project."))

        let transcript = try XCTUnwrap(data.transcriptText(sessionId: session.id))
        XCTAssertTrue(transcript.contains("Kickoff"))
        XCTAssertTrue(transcript.contains("Welcome everyone"))

        XCTAssertNil(try data.transcriptText(sessionId: "missing"))
    }
}
