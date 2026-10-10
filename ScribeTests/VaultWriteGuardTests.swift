// ScribeTests/VaultWriteGuardTests.swift
import XCTest
@testable import Scribe

/// The watcher must skip only the events Scribe's own writes explain — per
/// path, and only while the file still holds what Scribe wrote — and never
/// swallow an external edit, even one landing right after an autosave.
final class VaultWriteGuardTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func fingerprint(_ hash: String, date: Date? = nil, size: Int? = nil) -> NoteFileFingerprint {
        NoteFileFingerprint(modificationDate: date, size: size, contentHash: hash)
    }

    // MARK: - Pure matching

    func testPresentExpectationMatchesSameContent() {
        let expected = fingerprint("abc", date: Date(timeIntervalSince1970: 1), size: 3)
        // A `touch` changes the date but not the content: still our write.
        let touched = fingerprint("abc", date: Date(timeIntervalSince1970: 2), size: 3)
        XCTAssertTrue(VaultWriteGuard.matches(.present(expected), current: touched))
    }

    func testPresentExpectationRejectsDifferentContentOrMissingFile() {
        let expected = fingerprint("abc")
        XCTAssertFalse(VaultWriteGuard.matches(.present(expected), current: fingerprint("xyz")))
        XCTAssertFalse(VaultWriteGuard.matches(.present(expected), current: nil))
    }

    func testAbsentExpectation() {
        XCTAssertTrue(VaultWriteGuard.matches(.absent, current: nil))
        XCTAssertFalse(VaultWriteGuard.matches(.absent, current: fingerprint("recreated")))
    }

    // MARK: - Event filtering

    func testOwnWritesAreSuppressedPerPath() {
        let root = URL(fileURLWithPath: "/vault")
        let own: Set<String> = ["/vault/Mine.md"]
        let isOwn: (String) -> Bool = { own.contains($0) }

        XCTAssertFalse(VaultWriteGuard.requiresReconcile(
            events: [NoteVaultEvent(path: "/vault/Mine.md")], root: root, isOwnWrite: isOwn))
        // Another file changing in the same batch is NOT hidden by our write.
        XCTAssertTrue(VaultWriteGuard.requiresReconcile(
            events: [NoteVaultEvent(path: "/vault/Mine.md"), NoteVaultEvent(path: "/vault/Theirs.md")],
            root: root, isOwnWrite: isOwn))
    }

    func testIrrelevantPathsNeverReconcile() {
        let root = URL(fileURLWithPath: "/vault")
        let events = [
            NoteVaultEvent(path: "/vault/.obsidian/workspace.json"),
            NoteVaultEvent(path: "/vault/.git/index"),
            NoteVaultEvent(path: "/vault/.dat.nosync1234.abcd"),
            NoteVaultEvent(path: "/vault/attachments/n1/photo.png"),
        ]
        XCTAssertFalse(VaultWriteGuard.requiresReconcile(events: events, root: root, isOwnWrite: { _ in false }))
    }

    func testDirectoriesAndCoalescedEventsAlwaysReconcile() {
        let root = URL(fileURLWithPath: "/vault")
        XCTAssertTrue(VaultWriteGuard.requiresReconcile(
            events: [NoteVaultEvent(path: "/vault/Projects", isDirectory: true)], root: root, isOwnWrite: { _ in true }))
        XCTAssertTrue(VaultWriteGuard.requiresReconcile(
            events: [NoteVaultEvent(path: "/vault/x.md", requiresFullScan: true)], root: root, isOwnWrite: { _ in true }))
        XCTAssertTrue(VaultWriteGuard.requiresReconcile(
            events: [NoteVaultEvent(path: "/private/vault/Theirs.md")], root: root, isOwnWrite: { _ in false }),
            "`/private` alias still resolves inside the vault")
    }

    // MARK: - Against the real file system

    func testRecordedWriteIsOwnUntilFileChangesExternally() throws {
        let guardian = VaultWriteGuard()
        let store = NoteFileStore(directory: NotesDirectory(root: root), writeGuard: guardian)
        let url = try store.write(NoteFile(
            id: "n1",
            frontmatter: NoteFrontmatter(title: "Mine", createdAt: Date(), updatedAt: Date()),
            body: "in-app"
        ))
        XCTAssertTrue(guardian.isOwnWrite(atPath: url.path))

        // External edit to the very same file right after the autosave.
        try "---\nid: n1\ntitle: Mine\n---\nexternal".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(guardian.isOwnWrite(atPath: url.path))
    }

    func testRecordedRemovalIsOwnUntilFileReappears() throws {
        let guardian = VaultWriteGuard()
        let store = NoteFileStore(directory: NotesDirectory(root: root), writeGuard: guardian)
        let url = try store.write(NoteFile(
            id: "gone",
            frontmatter: NoteFrontmatter(title: "Gone", createdAt: Date(), updatedAt: Date()),
            body: ""
        ))
        try store.delete(id: "gone")
        XCTAssertTrue(guardian.isOwnWrite(atPath: url.path))

        try "recreated elsewhere".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(guardian.isOwnWrite(atPath: url.path))
    }

    func testUnrecordedPathAndExpiredRecordAreNotOwn() throws {
        let guardian = VaultWriteGuard(ttl: 30)
        let url = root.appendingPathComponent("x.md")
        XCTAssertFalse(guardian.isOwnWrite(atPath: url.path))

        let t0 = Date(timeIntervalSince1970: 1_000)
        guardian.recordRemoval(at: url, now: t0)
        XCTAssertTrue(guardian.isOwnWrite(atPath: url.path, now: t0.addingTimeInterval(1)))
        XCTAssertFalse(guardian.isOwnWrite(atPath: url.path, now: t0.addingTimeInterval(31)))
    }
}
