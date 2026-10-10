// ScribeTests/NoteVersionHistoryTests.swift
import GRDB
import XCTest
@testable import Scribe

final class NoteVersionPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func decide(previous: String = "old", new: String = "new",
                        reason: NoteVersionReason = .edit,
                        lastAt: Date? = nil, lastHash: String? = nil) -> Bool {
        NoteVersionPolicy.shouldSnapshot(
            previousBody: previous,
            newBody: new,
            previousHash: NoteVersionStore.hash(previous),
            reason: reason,
            lastSnapshotAt: lastAt,
            lastSnapshotHash: lastHash,
            now: now
        )
    }

    func testFirstChangeSnapshots() {
        XCTAssertTrue(decide())
    }

    func testUnchangedOrEmptyNeverSnapshots() {
        XCTAssertFalse(decide(previous: "same", new: "same"))
        XCTAssertFalse(decide(previous: "  \n", new: "text"))
        XCTAssertFalse(decide(previous: "same", new: "same", reason: .restore))
    }

    func testThrottleWithinFiveMinutes() {
        XCTAssertFalse(decide(lastAt: now.addingTimeInterval(-60), lastHash: "other"))
        XCTAssertTrue(decide(lastAt: now.addingTimeInterval(-5 * 60), lastHash: "other"))
    }

    func testForcedReasonsBypassThrottle() {
        for reason in [NoteVersionReason.externalChange, .aiEdit, .restore] {
            XCTAssertTrue(decide(reason: reason, lastAt: now.addingTimeInterval(-10), lastHash: "other"), "\(reason)")
        }
    }

    func testDuplicateOfNewestIsSkippedEvenWhenForced() {
        XCTAssertFalse(decide(reason: .aiEdit, lastAt: now.addingTimeInterval(-3600),
                              lastHash: NoteVersionStore.hash("old")))
    }
}

final class NoteVersionRetentionTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 2026-10-10 12:00:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_633_600)

    private func item(_ id: String, hoursAgo: Double) -> NoteVersionRetention.Item {
        NoteVersionRetention.Item(id: id, createdAt: now.addingTimeInterval(-hoursAgo * 3600))
    }

    func testKeepsEverythingFromLastDay() {
        let items = (0..<30).map { item("r\($0)", hoursAgo: Double($0) * 0.5) }
        XCTAssertTrue(NoteVersionRetention.idsToDelete(items, now: now, calendar: calendar).isEmpty)
    }

    func testKeepsNewestPerHourForAWeek() {
        let items = [
            item("h1-new", hoursAgo: 30.1),
            item("h1-old", hoursAgo: 30.6),   // same clock hour as h1-new
            item("h2", hoursAgo: 31.5),
        ]
        // 30.1h and 30.6h before 12:00 are 05:54 and 05:24 on the previous day.
        XCTAssertEqual(NoteVersionRetention.idsToDelete(items, now: now, calendar: calendar), ["h1-old"])
    }

    func testKeepsNewestPerDayForThreeMonths() {
        let items = [
            item("d-new", hoursAgo: 24 * 10 + 1),
            item("d-old", hoursAgo: 24 * 10 + 3),
            item("d-other", hoursAgo: 24 * 12),
        ]
        XCTAssertEqual(NoteVersionRetention.idsToDelete(items, now: now, calendar: calendar), ["d-old"])
    }

    func testDropsOlderThanNinetyDays() {
        let items = [item("ancient", hoursAgo: 24 * 91), item("recent", hoursAgo: 1)]
        XCTAssertEqual(NoteVersionRetention.idsToDelete(items, now: now, calendar: calendar), ["ancient"])
    }

    func testFutureVersionsAreKept() {
        let items = [item("future", hoursAgo: -5)]
        XCTAssertTrue(NoteVersionRetention.idsToDelete(items, now: now, calendar: calendar).isEmpty)
    }
}

final class NoteVersionStoreTests: XCTestCase {

    private var tempRoot: URL!
    private var dbManager: DatabaseManager!
    private var versions: NoteVersionStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        dbManager = try! DatabaseManager(path: ":memory:")
        versions = NoteVersionStore(dbManager: dbManager, directory: tempRoot.appendingPathComponent("Versions"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testMigrationIsRegistered() throws {
        try dbManager.database.read { db in
            let applied = try DatabaseManager.makeMigrator().appliedMigrations(db)
            XCTAssertTrue(applied.contains("v24_note_versions"))
            XCTAssertTrue(try db.tableExists("note_versions"))
        }
    }

    func testSnapshotRoundTripsCompressedContent() throws {
        let body = String(repeating: "Line of text ✍️\n", count: 200)
        let record = try XCTUnwrap(versions.recordSnapshotIfNeeded(
            noteId: "n/1", title: "T", previousBody: body, newBody: "new", reason: .edit))
        XCTAssertEqual(try versions.loadBody(record), body)
        XCTAssertEqual(record.byteCount, Data(body.utf8).count)
        XCTAssertFalse(record.fileName.contains("n/1"))
        let stored = try Data(contentsOf: versions.directory.appendingPathComponent(record.fileName))
        XCTAssertLessThan(stored.count, record.byteCount)
        XCTAssertEqual(try versions.versions(noteId: "n/1").map(\.id), [record.id])
    }

    func testThrottleAndForcedSnapshots() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNotNil(try versions.recordSnapshotIfNeeded(noteId: "n", title: "T", previousBody: "v1",
                                                            newBody: "v2", reason: .edit, now: t0))
        // Within five minutes: throttled.
        XCTAssertNil(try versions.recordSnapshotIfNeeded(noteId: "n", title: "T", previousBody: "v2",
                                                         newBody: "v3", reason: .edit, now: t0.addingTimeInterval(60)))
        // Forced reason bypasses the throttle.
        XCTAssertNotNil(try versions.recordSnapshotIfNeeded(noteId: "n", title: "T", previousBody: "v3",
                                                            newBody: "v4", reason: .aiEdit, now: t0.addingTimeInterval(90)))
        // After five minutes: snapshots again.
        XCTAssertNotNil(try versions.recordSnapshotIfNeeded(noteId: "n", title: "T", previousBody: "v4",
                                                            newBody: "v5", reason: .edit, now: t0.addingTimeInterval(400)))
        let all = try versions.versions(noteId: "n")
        XCTAssertEqual(try all.map { try versions.loadBody($0) }, ["v4", "v3", "v1"])
        XCTAssertEqual(all.first?.versionReason, .edit)
        XCTAssertEqual(all[1].versionReason, .aiEdit)
    }

    func testSnapshotSkipsDuplicateOfNewest() throws {
        XCTAssertNotNil(try versions.snapshot(noteId: "n", title: "T", body: "same", reason: .externalChange))
        XCTAssertNil(try versions.snapshot(noteId: "n", title: "T", body: "same", reason: .externalChange))
        XCTAssertEqual(try versions.versions(noteId: "n").count, 1)
    }

    func testRetentionRemovesFilesAndRows() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try XCTUnwrap(versions.snapshot(noteId: "n", title: "T", body: "old",
                                                  reason: .edit, now: now.addingTimeInterval(-100 * 86_400)))
        let url = versions.directory.appendingPathComponent(old.fileName)
        // Applying retention at the time of a later snapshot drops the old one.
        XCTAssertNotNil(try versions.snapshot(noteId: "n", title: "T", body: "new", reason: .edit, now: now))
        XCTAssertEqual(try versions.versions(noteId: "n").count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDeleteVersions() throws {
        try versions.snapshot(noteId: "n", title: "T", body: "a", reason: .edit)
        try versions.deleteVersions(noteId: "n")
        XCTAssertTrue(try versions.versions(noteId: "n").isEmpty)
    }

    func testFolderNameIsFileSystemSafe() {
        XCTAssertEqual(NoteVersionStore.folderName(forNoteId: "ab/c:d"), "ab_c_d")
        XCTAssertEqual(NoteVersionStore.folderName(forNoteId: ""), "_")
    }
}

/// `NoteStore` snapshots the on-disk content before saves.
final class NoteStoreVersioningTests: XCTestCase {

    private var tempRoot: URL!
    private var store: NoteStore!
    private var versions: NoteVersionStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = try! DatabaseManager(path: ":memory:")
        let fileStore = NoteFileStore(directory: NotesDirectory(root: tempRoot.appendingPathComponent("Vault")))
        versions = NoteVersionStore(dbManager: db, directory: tempRoot.appendingPathComponent("Versions"))
        store = NoteStore(databaseManager: db, fileStore: fileStore, versionStore: versions)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testSaveSnapshotsPreviousContentThrottled() throws {
        let created = try store.createNote(title: "Doc", body: "first")
        var note = try XCTUnwrap(store.fetchNote(id: created.id))
        note.body = "second"
        try store.updateNote(note, tags: [])
        note.body = "third"
        try store.updateNote(note, tags: [])   // throttled
        let all = try versions.versions(noteId: created.id)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(try versions.loadBody(try XCTUnwrap(all.first)), "first")
        XCTAssertEqual(all.first?.title, "Doc")
    }

    func testForcedReasonSnapshotsEveryTime() throws {
        let created = try store.createNote(title: "Doc", body: "first")
        var note = try XCTUnwrap(store.fetchNote(id: created.id))
        note.body = "second"
        try store.updateNote(note, tags: [])
        note.body = "third"
        try store.updateNote(note, tags: [], versionReason: .restore)
        let bodies = try versions.versions(noteId: created.id).map { try versions.loadBody($0) }
        XCTAssertEqual(Set(bodies), ["first", "second"])
    }

    func testSaveWithoutChangeTakesNoSnapshot() throws {
        let created = try store.createNote(title: "Doc", body: "same")
        let note = try XCTUnwrap(store.fetchNote(id: created.id))
        try store.updateNote(note, tags: ["tag"])
        XCTAssertTrue(try versions.versions(noteId: created.id).isEmpty)
    }

    func testDailyNoteSeed() throws {
        store.setDailyNoteSeed { _, _, title in "# \(title)\n\n- [ ] " }
        let (note, created) = try store.dailyNoteCreatingIfNeeded(for: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(created)
        XCTAssertTrue(note.body.hasPrefix("# Daily Note"))
        let disk = try XCTUnwrap(store.fetchNote(id: note.id))
        XCTAssertTrue(disk.body.hasPrefix("# Daily Note"))
        // An existing daily note is never re-seeded.
        let again = try store.dailyNoteCreatingIfNeeded(for: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertFalse(again.created)
    }

    func testUnlinkedMentionsViaFTS() throws {
        let target = try store.createNote(title: "Project Plan", body: "The plan itself.")
        let mentioning = try store.createNote(title: "Standup", body: "We discussed the project plan.\nAlso [[Project Plan]].")
        _ = try store.createNote(title: "Unrelated", body: "Nothing to see.")
        _ = try store.createNote(title: "Code", body: "```\nproject plan\n```")

        let results = try store.unlinkedMentions(ofNoteId: target.id, title: target.title, aliases: [])
        XCTAssertEqual(results.map { $0.note.id }, [mentioning.id])
        XCTAssertEqual(results.first?.mentions.map(\.matchedText), ["project plan"])

        // Linking rewrites the file through the store and creates the edge.
        var source = try XCTUnwrap(store.fetchNote(id: mentioning.id))
        let mention = try XCTUnwrap(results.first?.mentions.first)
        source.body = try XCTUnwrap(UnlinkedMentionMatcher.linking(mention, in: source.body, title: target.title))
        try store.updateNote(source, tags: [])
        XCTAssertEqual(try store.fetchNote(id: mentioning.id)?.body,
                       "We discussed the [[Project Plan|project plan]].\nAlso [[Project Plan]].")
        XCTAssertEqual(try store.backlinks(for: target.id).map(\.id), [mentioning.id])
        XCTAssertTrue(try store.unlinkedMentions(ofNoteId: target.id, title: target.title, aliases: []).isEmpty)
    }

    func testAliasesFromFrontmatter() throws {
        let note = try store.createNote(title: "Acme", body: "")
        let fileStore = try XCTUnwrap(store.fileStore)
        var file = try XCTUnwrap(try fileStore.locate(id: note.id)).file
        file.frontmatter.setExtra("aliases", "[Acme Corp, ACME Inc]")
        try fileStore.write(file)
        XCTAssertEqual(store.aliases(forNoteId: note.id), ["Acme Corp", "ACME Inc"])
    }
}

final class NoteLineDiffTests: XCTestCase {

    private func render(_ lines: [NoteLineDiff.Line]) -> [String] {
        lines.map { line in
            switch line.kind {
            case .unchanged: return "  \(line.text)"
            case .added: return "+ \(line.text)"
            case .removed: return "- \(line.text)"
            }
        }
    }

    func testIdenticalTextIsUnchanged() {
        let diff = NoteLineDiff.diff(old: "a\nb", new: "a\nb")
        XCTAssertEqual(render(diff), ["  a", "  b"])
        XCTAssertEqual(NoteLineDiff.summary(diff).added, 0)
    }

    func testInsertionDeletionAndReplacement() {
        let diff = NoteLineDiff.diff(old: "a\nb\nc\nd", new: "a\nc\nx\nd\ne")
        XCTAssertEqual(render(diff), ["  a", "- b", "  c", "+ x", "  d", "+ e"])
        let summary = NoteLineDiff.summary(diff)
        XCTAssertEqual(summary.added, 2)
        XCTAssertEqual(summary.removed, 1)
    }

    func testLineNumbers() {
        let diff = NoteLineDiff.diff(old: "a\nb", new: "z\na\nb")
        XCTAssertEqual(diff.map(\.oldNumber), [nil, 1, 2])
        XCTAssertEqual(diff.map(\.newNumber), [1, 2, 3])
    }

    func testEmptySides() {
        XCTAssertEqual(render(NoteLineDiff.diff(old: "", new: "a")), ["+ a"])
        XCTAssertEqual(render(NoteLineDiff.diff(old: "a", new: "")), ["- a"])
        XCTAssertTrue(NoteLineDiff.diff(old: "", new: "").isEmpty)
    }

    func testCRLFIsNormalised() {
        XCTAssertEqual(render(NoteLineDiff.diff(old: "a\r\nb", new: "a\nb")), ["  a", "  b"])
    }
}
