// ScribeTests/NoteVaultSafetyTests.swift
import XCTest
import GRDB
@testable import Scribe

/// Data-safety contracts for the markdown vault: stable ids, rename
/// ordering, the id → path index, notebook frontmatter rewrites, trash on
/// delete, Templates exclusion and vault-move integrity.
final class NoteVaultSafetyTests: XCTestCase {

    private var tempRoot: URL!
    private var fileStore: NoteFileStore!
    private var dbManager: DatabaseManager!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        fileStore = NoteFileStore(directory: NotesDirectory(root: tempRoot), writeGuard: VaultWriteGuard())
        dbManager = try! DatabaseManager(path: ":memory:")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private var root: URL { fileStore.directory.root }

    private func note(_ id: String, _ title: String, body: String = "", notebookId: String? = nil) -> NoteFile {
        NoteFile(
            id: id,
            frontmatter: NoteFrontmatter(title: title, createdAt: Date(), updatedAt: Date(), notebookId: notebookId),
            body: body
        )
    }

    private func writeRaw(_ contents: String, to relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - Stable ids

    func testDerivedIdIsDeterministicAndUUIDShaped() {
        let a = NoteStableId.derivedId(forRelativePath: "Projects/Plan.md")
        XCTAssertEqual(a, NoteStableId.derivedId(forRelativePath: "Projects/Plan.md"))
        XCTAssertNotEqual(a, NoteStableId.derivedId(forRelativePath: "Projects/Other.md"))
        XCTAssertNotNil(UUID(uuidString: a))
        // NFD and NFC spellings of the same name agree.
        XCTAssertEqual(
            NoteStableId.derivedId(forRelativePath: "Cafe\u{0301}.md"),
            NoteStableId.derivedId(forRelativePath: "Caf\u{00E9}.md")
        )
    }

    func testIdLessFileReadsTheSameIdEveryTime() throws {
        let url = try writeRaw("Just a body.", to: "Loose.md")
        let first = try fileStore.read(at: url).id
        let second = try NoteFileStore(directory: NotesDirectory(root: tempRoot)).read(at: url).id
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, NoteStableId.derivedId(forRelativePath: "Loose.md"))
    }

    func testReconcilePinsIdOncePreservingTheRestOfTheFile() throws {
        let original = "---\ntitle: External\naliases: [x]\n---\n\nBody line 1\n\n\nBody line 2  \n"
        let url = try writeRaw(original, to: "Inbox/External.md")
        let reconciler = NoteIndexReconciler(fileStore: fileStore, dbManager: dbManager)

        let pass1 = try reconciler.reconcileDetailed()
        XCTAssertEqual(pass1.pinned, 1)
        let expectedId = NoteStableId.derivedId(forRelativePath: "Inbox/External.md")
        let pinned = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(pinned, "---\nid: \(expectedId)\ntitle: External\naliases: [x]\n---\n\nBody line 1\n\n\nBody line 2  \n")

        // Second pass: nothing left to pin, same id in the DB.
        let pass2 = try reconciler.reconcileDetailed()
        XCTAssertEqual(pass2.pinned, 0)
        let ids = try dbManager.database.read { try String.fetchAll($0, sql: "SELECT id FROM notes") }
        XCTAssertEqual(ids, [expectedId])

        // The id now survives a move/rename done outside Scribe.
        let moved = root.appendingPathComponent("Archive/Renamed.md")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: moved)
        XCTAssertEqual(try fileStore.read(at: moved).id, expectedId)
    }

    func testPinningFileWithoutFrontmatterPrependsBlock() {
        let pinned = NoteFrontmatterCodec.settingRawKeys([(key: "id", value: "abc")], in: "Hello\nworld")
        XCTAssertEqual(pinned, "---\nid: abc\n---\nHello\nworld")
        let decoded = NoteFrontmatterCodec.decodeFile(contents: pinned, fallbackTitle: "T", fallbackId: "fallback")
        XCTAssertEqual(decoded.id, "abc")
        XCTAssertEqual(decoded.body, "Hello\nworld")
    }

    func testPinningPreservesCRLFAndReplacesEmptyId() {
        let crlf = "---\r\nid:\r\ntitle: Win\r\n---\r\nBody\r\n"
        XCTAssertNil(NoteFrontmatterCodec.explicitId(in: crlf))
        let pinned = NoteFrontmatterCodec.settingRawKeys([(key: "id", value: "abc")], in: crlf)
        XCTAssertEqual(pinned, "---\r\nid: abc\r\ntitle: Win\r\n---\r\nBody\r\n")
        XCTAssertEqual(NoteFrontmatterCodec.explicitId(in: pinned), "abc")
    }

    // MARK: - Rename safety

    func testRenameStaysInTheNotesFolderAndRemovesOldFileAfterWriting() throws {
        let original = try writeRaw("---\nid: r1\ntitle: Old\n---\nbody", to: "Projects/Old.md")
        var file = try fileStore.read(at: original)
        file.frontmatter.title = "New"
        let renamed = try fileStore.write(file)

        XCTAssertEqual(renamed.lastPathComponent, "New.md")
        XCTAssertEqual(renamed.deletingLastPathComponent().lastPathComponent, "Projects",
                       "a rename must not move the note to the vault root")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try fileStore.read(at: renamed).body, "body")
    }

    func testRenameNeverDeletesAConflictCopy() throws {
        // iCloud duplicated the bytes (id included) into a conflict copy.
        let conflict = try writeRaw("---\nid: c1\ntitle: Meeting\n---\ntheirs",
                                    to: "Meeting (Mac's conflicted copy 2026-05-18).md")
        let written = try fileStore.write(note("c1", "Meeting", body: "ours"))
        XCTAssertEqual(written.lastPathComponent, "Meeting.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: conflict.path))
        XCTAssertEqual(try fileStore.read(at: conflict).body, "theirs")
    }

    func testSupersededFileRule() {
        XCTAssertTrue(NoteFileStore.shouldRemoveSupersededFile(relativePath: "A/Old.md", onDiskId: "x", expectedId: "x"))
        XCTAssertFalse(NoteFileStore.shouldRemoveSupersededFile(relativePath: "A/Old.md", onDiskId: "y", expectedId: "x"),
                       "a different note now lives at the old path")
        XCTAssertFalse(NoteFileStore.shouldRemoveSupersededFile(relativePath: "A/Old.md", onDiskId: nil, expectedId: "x"))
        XCTAssertFalse(NoteFileStore.shouldRemoveSupersededFile(
            relativePath: "Old (Mac's conflicted copy 2026-05-18).md", onDiskId: "x", expectedId: "x"))
    }

    func testRenameDoesNotOverwriteAnotherNote() throws {
        try fileStore.write(note("a", "Taken", body: "A"))
        try fileStore.write(note("b", "Other", body: "B"))
        let url = try fileStore.write(note("b", "Taken", body: "B"))
        XCTAssertEqual(url.lastPathComponent, "Taken 2.md")
        XCTAssertEqual(try fileStore.read(at: root.appendingPathComponent("Taken.md")).body, "A")
    }

    // MARK: - id → path index

    func testIndexFallsBackToScanWhenFileMovedExternally() throws {
        let url = try fileStore.write(note("m1", "Movable", body: "x"))
        _ = try fileStore.listEntries()
        let moved = root.appendingPathComponent("Sub/Movable.md")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: moved)

        let found = try fileStore.findURL(for: "m1")
        XCTAssertEqual(found.map { VaultWriteGuard.normalize($0.path) }, VaultWriteGuard.normalize(moved.path))
        XCTAssertEqual(fileStore.index.relativePath(for: "m1"), "Sub/Movable.md")
    }

    func testCompleteIndexAnswersMissWithoutScanning() throws {
        try fileStore.write(note("known", "Known"))
        _ = try fileStore.listEntries()
        XCTAssertTrue(fileStore.index.isComplete)
        XCTAssertNil(try fileStore.findURL(for: "never-written"))
        XCTAssertNotNil(try fileStore.findURL(for: "known"))
    }

    func testReconcilerPrefersRegularFileOverConflictCopy() throws {
        _ = try writeRaw("---\nid: d1\ntitle: Real\n---\nreal", to: "Real.md")
        _ = try writeRaw("---\nid: d1\ntitle: Copy\n---\ncopy", to: "Real (conflicted copy).md")
        for _ in 0..<2 {
            _ = try NoteIndexReconciler(fileStore: fileStore, dbManager: dbManager).reconcile()
            let title = try dbManager.database.read { try String.fetchOne($0, sql: "SELECT title FROM notes WHERE id = 'd1'") }
            XCTAssertEqual(title, "Real")
        }
    }

    func testIndexPrefersRegularFileThenFirstPath() {
        XCTAssertTrue(NoteVaultIndex.isPreferred("B.md", over: "A (conflicted copy).md"))
        XCTAssertFalse(NoteVaultIndex.isPreferred("A (conflicted copy).md", over: "B.md"))
        XCTAssertTrue(NoteVaultIndex.isPreferred("A.md", over: "B.md"))
        XCTAssertTrue(NoteVaultIndex.isPreferred("A (conflicted copy).md", over: "B (conflicted copy).md"))
    }

    func testWriteChainOnlyVouchesForScribesOwnDescendants() {
        let index = NoteVaultIndex()
        func fp(_ hash: String) -> NoteFileFingerprint {
            NoteFileFingerprint(modificationDate: nil, size: nil, contentHash: hash)
        }
        index.recordOwnWrite(fp("w1"), basedOn: fp("loaded"), for: "n")
        index.recordOwnWrite(fp("w2"), basedOn: fp("w1"), for: "n")
        XCTAssertEqual(index.lastWrittenFingerprint(for: "n", descendingFrom: fp("loaded"))?.contentHash, "w2")
        XCTAssertEqual(index.lastWrittenFingerprint(for: "n", descendingFrom: fp("w1"))?.contentHash, "w2")

        // A Scribe write on top of an *external* edit restarts the chain:
        // it must not vouch for the external version as Scribe's own.
        index.recordOwnWrite(fp("w3"), basedOn: fp("external"), for: "n")
        XCTAssertNil(index.lastWrittenFingerprint(for: "n", descendingFrom: fp("loaded")))
        XCTAssertEqual(index.lastWrittenFingerprint(for: "n", descendingFrom: fp("external"))?.contentHash, "w3")
        XCTAssertEqual(index.lastWrittenFingerprint(for: "n")?.contentHash, "w3")
    }

    // MARK: - Daily-date uniqueness

    func testDuplicateDailyDatesDoNotFailReconcile() throws {
        let header = "isDailyNote: true\ndailyDate: 2026-03-04\n---\n"
        _ = try writeRaw("---\nid: day-a\ntitle: A\n" + header + "a", to: "Daily/2026-03-04.md")
        _ = try writeRaw("---\nid: day-b\ntitle: B\n" + header + "b", to: "Elsewhere/2026-03-04.md")
        let reconciler = NoteIndexReconciler(fileStore: fileStore, dbManager: dbManager)

        var owners: [[String]] = []
        for _ in 0..<2 {
            XCTAssertNoThrow(try reconciler.reconcile())
            owners.append(try dbManager.database.read {
                try String.fetchAll($0, sql: "SELECT id FROM notes WHERE dailyDate IS NOT NULL")
            })
        }
        let count = try dbManager.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM notes") }
        XCTAssertEqual(count, 2, "both notes stay indexed")
        XCTAssertEqual(owners[0].count, 1, "exactly one note holds the day")
        XCTAssertEqual(owners[0], owners[1], "the owner is stable across passes")
    }

    func testExistingDailyOwnerKeepsItsDay() throws {
        let header = "isDailyNote: true\ndailyDate: 2026-03-05\n---\n"
        _ = try writeRaw("---\nid: zz-first\ntitle: First\n" + header + "first", to: "Zed/2026-03-05.md")
        let reconciler = NoteIndexReconciler(fileStore: fileStore, dbManager: dbManager)
        _ = try reconciler.reconcile()

        // A second claimant with a "better" path appears later.
        _ = try writeRaw("---\nid: aa-second\ntitle: Second\n" + header + "second", to: "A/2026-03-05.md")
        _ = try reconciler.reconcile()
        let owner = try dbManager.database.read {
            try String.fetchAll($0, sql: "SELECT id FROM notes WHERE dailyDate IS NOT NULL")
        }
        XCTAssertEqual(owner, ["zz-first"])
        let secondIsDaily = try dbManager.database.read {
            try Bool.fetchOne($0, sql: "SELECT isDailyNote FROM notes WHERE id = 'aa-second'")
        }
        XCTAssertEqual(secondIsDaily, false)
    }

    // MARK: - Templates

    func testUserTemplatesFolderIsIndexedButScribeTemplatesAreNot() throws {
        _ = try writeRaw("---\nid: u1\ntitle: Standup template\n---\n", to: "Templates/Standup.md")
        _ = try writeRaw("---\nname: Summary\n---\n", to: "Templates/Summaries/default.md")
        _ = try writeRaw("---\nname: Recipe\n---\n", to: "templates/recipes/r.md")
        let ids = try fileStore.listAll().map(\.id)
        XCTAssertEqual(ids, ["u1"])
    }

    // MARK: - Delete

    func testDeleteRemovesFileFromVault() throws {
        let url = try fileStore.write(note("t1", "Trash me"))
        XCTAssertEqual(try fileStore.delete(id: "t1"), url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(try fileStore.findURL(for: "t1"))
    }

    // MARK: - Vault move

    func testCopyTreeIncludesHiddenFoldersAndVerifies() throws {
        let source = tempRoot.appendingPathComponent("src", isDirectory: true)
        let destination = tempRoot.appendingPathComponent("dst", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: source.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent(".git/refs"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent(".obsidian/app.json"))
        try Data("ref: main".utf8).write(to: source.appendingPathComponent(".git/HEAD"))
        try Data("note".utf8).write(to: source.appendingPathComponent("Note.md"))

        XCTAssertNotNil(VaultCoordinator.firstMissingItem(from: source, in: destination),
                        "verification must notice missing items before anything is deleted")
        let copied = try VaultCoordinator.copyTree(from: source, to: destination)
        XCTAssertEqual(copied, 3)
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent(".obsidian/app.json").path))
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent(".git/HEAD").path))
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent(".git/refs").path))
        XCTAssertNil(VaultCoordinator.firstMissingItem(from: source, in: destination))
    }

    // MARK: - Reconcile scheduling

    func testSchedulerReconcileNowRunsAPass() throws {
        try fileStore.write(note("s1", "Scheduled"))
        let scheduler = NoteReconcileScheduler(
            reconciler: NoteIndexReconciler(fileStore: fileStore, dbManager: dbManager),
            onComplete: { _ in }
        )
        let result = try scheduler.reconcileNow()
        XCTAssertEqual(result.upserted, 1)
    }

    func testSchedulerCoalescesBurstIntoAtMostTwoPasses() throws {
        try fileStore.write(note("s2", "Burst"))
        let counter = PassCounter()
        let scheduler = NoteReconcileScheduler(
            reconciler: NoteIndexReconciler(fileStore: fileStore, dbManager: dbManager),
            onComplete: { _ in counter.increment() }
        )
        for _ in 0..<20 { scheduler.requestReconcile() }
        // Runs on the same serial queue, so it returns only after the drain
        // loop for the burst has finished.
        _ = try scheduler.reconcileNow()
        XCTAssertGreaterThanOrEqual(counter.value, 1)
        XCTAssertLessThanOrEqual(counter.value, 2)
    }
}

private final class PassCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// NoteStore-level contracts: notebook frontmatter rewrites, transactional
/// mirroring, daily-draft binding.
final class NoteStoreVaultSafetyTests: XCTestCase {

    private var tempRoot: URL!
    private var fileStore: NoteFileStore!
    private var dbManager: DatabaseManager!
    private var store: NoteStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        fileStore = NoteFileStore(directory: NotesDirectory(root: tempRoot), writeGuard: VaultWriteGuard())
        dbManager = try! DatabaseManager(path: ":memory:")
        store = NoteStore(databaseManager: dbManager, fileStore: fileStore)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func diskNotebookId(_ noteId: String) throws -> String? {
        let url = try XCTUnwrap(try fileStore.findURL(for: noteId))
        return try fileStore.read(at: url).frontmatter.notebookId
    }

    func testDeleteNotebookRewritesFrontmatterSoReconcileKeepsItCleared() throws {
        let notebook = try store.createNotebook(name: "Work")
        let note = try store.createNote(title: "In work", body: "keep me", notebookId: notebook.id)
        XCTAssertEqual(try diskNotebookId(note.id), notebook.id)

        try store.deleteNotebook(id: notebook.id)
        XCTAssertNil(try diskNotebookId(note.id))

        _ = try NoteIndexReconciler(fileStore: fileStore, dbManager: dbManager).reconcile()
        XCTAssertNil(try store.fetchNote(id: note.id)?.notebookId)
        XCTAssertEqual(try store.fetchNote(id: note.id)?.body, "keep me")
    }

    func testMoveNoteRewritesFrontmatter() throws {
        let a = try store.createNotebook(name: "A")
        let note = try store.createNote(title: "Mover", body: "b")
        try store.moveNote(id: note.id, toNotebookId: a.id)
        XCTAssertEqual(try diskNotebookId(note.id), a.id)

        _ = try NoteIndexReconciler(fileStore: fileStore, dbManager: dbManager).reconcile()
        XCTAssertEqual(try store.fetchNote(id: note.id)?.notebookId, a.id)
    }

    func testFetchExistingDailyNoteCarriesDiskBody() throws {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 4))!
        var daily = try store.dailyNote(for: date)
        daily.body = "written earlier"
        try store.updateNote(daily, tags: [])
        XCTAssertEqual(try store.fetchExistingDailyNote(for: date)?.body, "written earlier")
    }

    func testDailyNoteCreatingIfNeededReportsCreation() throws {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 5))!
        XCTAssertTrue(try store.dailyNoteCreatingIfNeeded(for: date).created)
        XCTAssertFalse(try store.dailyNoteCreatingIfNeeded(for: date).created)
    }

    func testDailyDraftNeverOverwritesExistingBody() {
        XCTAssertEqual(NoteStore.dailyDraftBodyToWrite(created: true, existingBody: "", draft: "h"), "h")
        XCTAssertNil(NoteStore.dailyDraftBodyToWrite(created: false, existingBody: "Real content", draft: "h"))
        XCTAssertEqual(NoteStore.dailyDraftBodyToWrite(created: false, existingBody: " \n", draft: "h"), "h")
    }
}

/// External-edit handling: decision table plus the editor's keep-both and
/// reload paths against a real vault.
@MainActor
final class NoteExternalEditTests: XCTestCase {

    private var tempRoot: URL!
    private var fileStore: NoteFileStore!
    private var dbManager: DatabaseManager!
    private var store: NoteStore!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        fileStore = NoteFileStore(directory: NotesDirectory(root: tempRoot), writeGuard: VaultWriteGuard())
        dbManager = try DatabaseManager(path: ":memory:")
        store = NoteStore(databaseManager: dbManager, fileStore: fileStore)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    private func makeVM(_ note: Note) -> NoteDetailViewModel {
        NoteDetailViewModel(
            note: note,
            store: store,
            transcriptStore: TranscriptStore(databaseManager: dbManager),
            taskStore: TaskStore(databaseManager: dbManager)
        )
    }

    private func editExternally(_ noteId: String, body: String) throws {
        let url = try XCTUnwrap(try fileStore.findURL(for: noteId))
        let contents = try String(contentsOf: url, encoding: .utf8)
        let header = contents.components(separatedBy: "\n---\n").first ?? ""
        try (header + "\n---\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func testPolicyDecisionTable() {
        let a = NoteFileFingerprint(modificationDate: nil, size: 1, contentHash: "a")
        let b = NoteFileFingerprint(modificationDate: nil, size: 1, contentHash: "b")
        XCTAssertEqual(NoteExternalEditPolicy.decide(loaded: a, current: a, hasUnsavedChanges: true), .write)
        XCTAssertEqual(NoteExternalEditPolicy.decide(loaded: a, current: b, hasUnsavedChanges: false), .reloadFromDisk)
        XCTAssertEqual(NoteExternalEditPolicy.decide(loaded: a, current: b, hasUnsavedChanges: true), .keepBoth)
        XCTAssertEqual(NoteExternalEditPolicy.decide(loaded: nil, current: b, hasUnsavedChanges: true), .write)
        XCTAssertEqual(NoteExternalEditPolicy.decide(loaded: a, current: nil, hasUnsavedChanges: true), .write)
        // Disk holds what Scribe itself last wrote (another in-app writer):
        // not an external edit.
        XCTAssertEqual(NoteExternalEditPolicy.decide(loaded: a, current: b, lastWrittenByScribe: b, hasUnsavedChanges: true), .write)
    }

    func testInAppWriteByAnotherComponentDoesNotCreateConflict() throws {
        let note = try store.createNote(title: "AI target", body: "notes")
        let vm = makeVM(try XCTUnwrap(store.fetchNote(id: note.id)))
        // Another component (e.g. an AI summary) writes through NoteStore.
        var other = try XCTUnwrap(store.fetchNote(id: note.id))
        other.body = "notes\n\nsummary"
        try store.updateNote(other, tags: [])

        vm.note.body = "notes\n\nsummary\n\nmore typing"
        vm.markDirty()
        vm.save()

        XCTAssertEqual(try store.fetchNote(id: note.id)?.body, "notes\n\nsummary\n\nmore typing")
        XCTAssertTrue(try NoteConflictDetector(fileStore: fileStore).listConflicts().isEmpty)
    }

    func testUnsavedEditRacingExternalEditKeepsBoth() throws {
        let note = try store.createNote(title: "Shared", body: "base")
        let vm = makeVM(try XCTUnwrap(store.fetchNote(id: note.id)))
        try editExternally(note.id, body: "external change")

        vm.note.body = "in-app change"
        vm.markDirty()
        vm.save()

        XCTAssertEqual(try store.fetchNote(id: note.id)?.body, "in-app change")
        let conflicts = try NoteConflictDetector(fileStore: fileStore).conflicts(forNoteId: note.id, originalName: "Shared")
        XCTAssertEqual(conflicts.count, 1)
        let copy = try fileStore.read(at: try XCTUnwrap(conflicts.first?.url))
        XCTAssertEqual(copy.body, "external change")
        XCTAssertNotEqual(copy.id, note.id)
        XCTAssertNotNil(vm.errorMessage, "the user is told about the conflict")
    }

    func testCleanEditorReloadsInsteadOfOverwriting() throws {
        let note = try store.createNote(title: "Clean", body: "base")
        let vm = makeVM(try XCTUnwrap(store.fetchNote(id: note.id)))
        try editExternally(note.id, body: "external change")

        vm.save()   // no unsaved changes

        XCTAssertEqual(vm.note.body, "external change")
        XCTAssertEqual(try store.fetchNote(id: note.id)?.body, "external change")
        XCTAssertTrue(try NoteConflictDetector(fileStore: fileStore).listConflicts().isEmpty)
    }

    func testInAppRewriteOnTopOfExternalEditStillKeepsBoth() throws {
        let note = try store.createNote(title: "Fonts", body: "base")
        let vm = makeVM(try XCTUnwrap(store.fetchNote(id: note.id)))
        try editExternally(note.id, body: "external change")
        // A Scribe read-modify-write of the externally edited file must not
        // make the external body look like Scribe's own version.
        store.setNoteFont(id: note.id, "serif")

        vm.note.body = "in-app change"
        vm.markDirty()
        vm.save()

        XCTAssertEqual(try store.fetchNote(id: note.id)?.body, "in-app change")
        let conflicts = try NoteConflictDetector(fileStore: fileStore).conflicts(forNoteId: note.id, originalName: "Fonts")
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(try fileStore.read(at: try XCTUnwrap(conflicts.first?.url)).body, "external change")
    }

    func testConflictCopyIsRecognisedAndEditsInPlace() throws {
        let note = try store.createNote(title: "Twice", body: "base")
        let entry = try XCTUnwrap(store.diskEntry(forNoteId: note.id))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try fileStore.writeConflictCopy(of: entry, now: now)
        let second = try fileStore.writeConflictCopy(of: entry, now: now)
        XCTAssertNotEqual(first, second)
        for url in [first, second] {
            XCTAssertEqual(
                NoteConflictDetector.stripConflictSuffix(url.deletingPathExtension().lastPathComponent),
                "Twice",
                "a same-second collision must still end in the conflict marker"
            )
        }

        // The copy's title matches its file name, so editing it in Scribe
        // saves in place rather than spawning yet another file.
        var copy = try fileStore.read(at: first)
        XCTAssertEqual(copy.frontmatter.title, first.deletingPathExtension().lastPathComponent)
        copy.body = "edited copy"
        let written = try fileStore.write(copy)
        XCTAssertEqual(VaultWriteGuard.normalize(written.path), VaultWriteGuard.normalize(first.path))
        XCTAssertEqual(try fileStore.read(at: first).body, "edited copy")
    }

    func testOrdinarySaveDoesNotCreateConflicts() throws {
        let note = try store.createNote(title: "Solo", body: "v1")
        let vm = makeVM(try XCTUnwrap(store.fetchNote(id: note.id)))
        for body in ["v2", "v3"] {
            vm.note.body = body
            vm.markDirty()
            vm.save()
        }
        XCTAssertEqual(try store.fetchNote(id: note.id)?.body, "v3")
        XCTAssertTrue(try NoteConflictDetector(fileStore: fileStore).listConflicts().isEmpty)
    }
}
