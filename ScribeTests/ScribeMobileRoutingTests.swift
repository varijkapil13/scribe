// ScribeTests/ScribeMobileRoutingTests.swift
import XCTest
@testable import Scribe

/// The iOS shell's pure navigation model (Scribe/App/ScribeMobileRouting.swift)
/// and universal search / quick task helpers (ScribeMobileSearch.swift).
final class ScribeMobileRoutingTests: XCTestCase {

    // MARK: - Tabs

    func testTabCustomizationIDsAreStableAndUnique() {
        // Persisted in UserDefaults via TabViewCustomization: never rename.
        XCTAssertEqual(ScribeMobileTab.today.customizationID, "com.varij.scribe.tab.today")
        XCTAssertEqual(ScribeMobileTab.notes.customizationID, "com.varij.scribe.tab.notes")
        XCTAssertEqual(ScribeMobileTab.tasks.customizationID, "com.varij.scribe.tab.tasks")
        XCTAssertEqual(ScribeMobileTab.record.customizationID, "com.varij.scribe.tab.record")
        XCTAssertEqual(ScribeMobileTab.search.customizationID, "com.varij.scribe.tab.search")
        XCTAssertEqual(ScribeMobileTab.settings.customizationID, "com.varij.scribe.tab.settings")
        let ids = ScribeMobileTab.allCases.map(\.customizationID)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testTabRestoresFromSceneStorageRawValue() {
        for tab in ScribeMobileTab.allCases {
            XCTAssertEqual(ScribeMobileTab.restored(from: tab.rawValue), tab)
        }
        XCTAssertEqual(ScribeMobileTab.restored(from: nil), .today)
        XCTAssertEqual(ScribeMobileTab.restored(from: ""), .today)
        XCTAssertEqual(ScribeMobileTab.restored(from: "capture"), .today)
    }

    func testTabCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(ScribeMobileTab.allCases)
        XCTAssertEqual(try JSONDecoder().decode([ScribeMobileTab].self, from: data), ScribeMobileTab.allCases)
    }

    func testShortcutNumbers() {
        XCTAssertEqual(ScribeMobileTab.forShortcutNumber(1), .today)
        XCTAssertEqual(ScribeMobileTab.forShortcutNumber(2), .notes)
        XCTAssertEqual(ScribeMobileTab.forShortcutNumber(3), .tasks)
        XCTAssertEqual(ScribeMobileTab.forShortcutNumber(4), .record)
        XCTAssertNil(ScribeMobileTab.forShortcutNumber(0))
        XCTAssertNil(ScribeMobileTab.forShortcutNumber(5))
    }

    // MARK: - Deep links

    private func route(_ string: String) -> ScribeMobileRoute? {
        guard let url = URL(string: string) else { return nil }
        return ScribeMobileRoute.from(url: url)
    }

    func testDeepLinksMapToRoutes() {
        XCTAssertEqual(route("scribe://note/abc-123"), .note(id: "abc-123"))
        XCTAssertEqual(route("scribe://note?title=Weekly%20Sync"), .noteByTitle("Weekly Sync"))
        XCTAssertEqual(route("scribe://new-note?title=Hi&body=There"), .newNote(title: "Hi", body: "There"))
        XCTAssertEqual(route("scribe://task/t1"), .task(id: "t1"))
        XCTAssertEqual(route("scribe://new-task?title=Ship&due=tomorrow"), .newTask(title: "Ship", due: "tomorrow"))
        XCTAssertEqual(route("scribe://meeting/s1"), .meeting(sessionId: "s1"))
        XCTAssertEqual(route("scribe://record/start"), .record(.start))
        XCTAssertEqual(route("scribe://record/stop"), .record(.stop))
        XCTAssertEqual(route("scribe://dictate"), .tab(.record))
        XCTAssertEqual(route("scribe://search?q=budget"), .search(query: "budget"))
        XCTAssertEqual(route("scribe://today"), .tab(.today))
        XCTAssertEqual(route("scribe://import-share"), .tab(.notes))
    }

    func testUnknownLinksAreIgnored() {
        XCTAssertNil(route("https://example.com/note/abc"))
        XCTAssertNil(route("scribe://nope"))
        XCTAssertNil(route("scribe://note/"))
    }

    func testRouteLandingTabs() {
        XCTAssertEqual(ScribeMobileRoute.note(id: "n").tab, .notes)
        XCTAssertEqual(ScribeMobileRoute.noteByTitle("x").tab, .notes)
        XCTAssertEqual(ScribeMobileRoute.newNote(title: nil, body: nil).tab, .notes)
        XCTAssertEqual(ScribeMobileRoute.task(id: "t").tab, .tasks)
        XCTAssertEqual(ScribeMobileRoute.newTask(title: "t", due: nil).tab, .tasks)
        XCTAssertEqual(ScribeMobileRoute.search(query: "").tab, .search)
        XCTAssertEqual(ScribeMobileRoute.record(.start).tab, .record)
        XCTAssertEqual(ScribeMobileRoute.meeting(sessionId: "s").tab, .record)
        XCTAssertEqual(ScribeMobileRoute.tab(.settings).tab, .settings)
    }

    // MARK: - Handoff

    func testHandoffActivitiesMapToRoutes() {
        XCTAssertEqual(
            ScribeMobileRoute.fromActivity(type: ScribeUserActivity.viewNote, userInfo: ["id": " n1 "]),
            .note(id: "n1")
        )
        XCTAssertEqual(
            ScribeMobileRoute.fromActivity(type: ScribeUserActivity.viewTask, userInfo: ["id": "t1"]),
            .task(id: "t1")
        )
        XCTAssertEqual(
            ScribeMobileRoute.fromActivity(type: ScribeMobileWindows.openNoteWindowActivityType, userInfo: ["id": "n2"]),
            .note(id: "n2")
        )
    }

    func testHandoffActivitiesWithoutIdOrUnknownTypeAreIgnored() {
        XCTAssertNil(ScribeMobileRoute.fromActivity(type: ScribeUserActivity.viewNote, userInfo: nil))
        XCTAssertNil(ScribeMobileRoute.fromActivity(type: ScribeUserActivity.viewNote, userInfo: ["id": "  "]))
        XCTAssertNil(ScribeMobileRoute.fromActivity(type: ScribeUserActivity.viewNote, userInfo: ["id": 42]))
        XCTAssertNil(ScribeMobileRoute.fromActivity(type: "com.example.other", userInfo: ["id": "n1"]))
    }

    func testActivityKeysMatchTheMacApp() {
        // The iOS shell publishes the same types / key the Mac continues.
        XCTAssertEqual(ScribeUserActivity.idKey, "id")
        XCTAssertTrue(ScribeMobileWindows.continuedActivityTypes.contains(ScribeUserActivity.viewNote))
        XCTAssertTrue(ScribeMobileWindows.continuedActivityTypes.contains(ScribeUserActivity.viewTask))
        XCTAssertTrue(ScribeMobileWindows.continuedActivityTypes.contains(ScribeMobileWindows.openNoteWindowActivityType))
        XCTAssertNotEqual(ScribeMobileWindows.openNoteWindowActivityType, ScribeUserActivity.viewNote)
    }

    // MARK: - Spotlight

    func testSpotlightIdentifiers() {
        XCTAssertEqual(ScribeMobileRoute.fromSpotlightIdentifier("note:abc"), .note(id: "abc"))
        XCTAssertEqual(ScribeMobileRoute.fromSpotlightIdentifier("task:xyz"), .task(id: "xyz"))
        XCTAssertNil(ScribeMobileRoute.fromSpotlightIdentifier("note:"))
        XCTAssertNil(ScribeMobileRoute.fromSpotlightIdentifier("meeting:1"))
        XCTAssertNil(ScribeMobileRoute.fromSpotlightIdentifier(""))
    }

    func testSpotlightPrefixesMatchTheMacIndexer() {
        XCTAssertEqual(ScribeMobileRoute.spotlightNotePrefix, SpotlightItemID.notePrefix)
        XCTAssertEqual(ScribeMobileRoute.spotlightTaskPrefix, SpotlightItemID.taskPrefix)
        XCTAssertEqual(
            ScribeMobileRoute.fromSpotlightIdentifier(SpotlightItemID.note("n9").uniqueIdentifier),
            .note(id: "n9")
        )
        XCTAssertEqual(
            ScribeMobileRoute.fromSpotlightIdentifier(SpotlightItemID.task("t9").uniqueIdentifier),
            .task(id: "t9")
        )
    }

    // MARK: - Appearance

    func testAppearanceResolution() {
        XCTAssertEqual(ScribeMobileAppearance.resolved(from: "dark"), .dark)
        XCTAssertEqual(ScribeMobileAppearance.resolved(from: "light"), .light)
        XCTAssertEqual(ScribeMobileAppearance.resolved(from: "system"), .system)
        XCTAssertEqual(ScribeMobileAppearance.resolved(from: "sepia"), .system)
    }

    // MARK: - Search

    private func makeStores() throws -> (NoteStore, TaskStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = try DatabaseManager(path: ":memory:")
        let notes = NoteStore(databaseManager: db,
                              fileStore: NoteFileStore(directory: NotesDirectory(root: root)))
        let tasks = TaskStore(databaseManager: db)
        return (notes, tasks, root)
    }

    func testBlankQueryReturnsNothing() throws {
        let (notes, tasks, root) = try makeStores()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try notes.createNote(title: "Budget review", body: "numbers")
        XCTAssertNil(ScribeMobileSearch.normalizedQuery("   \n"))
        XCTAssertTrue(ScribeMobileSearch.run(query: "  ", noteStore: notes, taskStore: tasks, limit: 10).isEmpty)
    }

    func testSearchFindsNotesAndTasks() throws {
        let (notes, tasks, root) = try makeStores()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try notes.createNote(title: "Budget review", body: "Quarterly numbers")
        _ = try notes.createNote(title: "Groceries", body: "milk")
        let task = try tasks.createTask(title: "Send budget deck")

        let results = ScribeMobileSearch.run(query: "budget", noteStore: notes, taskStore: tasks, limit: 10)
        XCTAssertEqual(results.notes.map(\.id), [note.id])
        XCTAssertEqual(results.tasks.map(\.id), [task.id])
        XCTAssertFalse(results.isEmpty)
    }

    func testSearchListsOpenTasksBeforeCompletedOnes() throws {
        let (notes, tasks, root) = try makeStores()
        defer { try? FileManager.default.removeItem(at: root) }
        let done = try tasks.createTask(title: "Budget draft")
        try tasks.completeTask(id: done.id)
        let open = try tasks.createTask(title: "Budget final")

        let results = ScribeMobileSearch.run(query: "budget", noteStore: notes, taskStore: tasks, limit: 10)
        XCTAssertEqual(results.tasks.map(\.id), [open.id, done.id])
    }

    // MARK: - Quick task creation

    func testQuickAddCreatesParsedTask() throws {
        let (_, tasks, root) = try makeStores()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try ScribeMobileTaskCreation.createTask(fromQuickAdd: "draft deck #work !high", store: tasks)
        let id = try XCTUnwrap(created?.id)
        let stored = try XCTUnwrap(try tasks.fetchTask(id: id))
        XCTAssertEqual(stored.title, "draft deck")
        XCTAssertEqual(stored.priority, .high)
    }

    func testQuickAddIgnoresBlankText() throws {
        let (_, tasks, root) = try makeStores()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(try ScribeMobileTaskCreation.createTask(fromQuickAdd: "  \n ", store: tasks))
        XCTAssertTrue(try tasks.fetchTasks(filter: .all).isEmpty)
    }

    func testLinkDueDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-10T09:00:00Z"))
        XCTAssertNil(ScribeMobileTaskCreation.dueDate(fromLinkValue: nil, now: now, calendar: calendar))
        XCTAssertEqual(
            ScribeMobileTaskCreation.dueDate(fromLinkValue: "2026-10-12", now: now, calendar: calendar),
            ISO8601DateFormatter().date(from: "2026-10-12T00:00:00Z")
        )
        XCTAssertEqual(
            ScribeMobileTaskCreation.dueDate(fromLinkValue: "tomorrow", now: now, calendar: calendar),
            ISO8601DateFormatter().date(from: "2026-10-11T00:00:00Z")
        )
    }
}
