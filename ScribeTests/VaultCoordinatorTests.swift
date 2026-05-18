// ScribeTests/VaultCoordinatorTests.swift
import XCTest
@testable import Scribe

/// Slice 9: hot-swap between vaults.
///
/// `moveVault(to:)` copies the current tree to the new location, swaps
/// `NoteStore.fileStore`, reconciles, and removes the source. `openVault`
/// just swaps + reconciles, leaving both folders intact on disk. Both
/// honour the file-store lock — readers in flight see one consistent
/// vault or the other, never a partial swap.
@MainActor
final class VaultCoordinatorTests: XCTestCase {

    private var tempParent: URL!
    private var vaultA: URL!
    private var vaultB: URL!
    private var dbManager: DatabaseManager!
    private var noteStore: NoteStore!
    private var coordinator: VaultCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        tempParent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        vaultA = tempParent.appendingPathComponent("vault-a", isDirectory: true)
        vaultB = tempParent.appendingPathComponent("vault-b", isDirectory: true)

        dbManager = try DatabaseManager(path: ":memory:")
        let fileStore = NoteFileStore(directory: NotesDirectory(root: vaultA))
        noteStore = NoteStore(databaseManager: dbManager, fileStore: fileStore)
        coordinator = VaultCoordinator(noteStore: noteStore, dbManager: dbManager)
    }

    override func tearDown() async throws {
        coordinator.stop()
        try? FileManager.default.removeItem(at: tempParent)
        try await super.tearDown()
    }

    // MARK: - File store lock

    func testFileStoreSwapVisibleToReaders() {
        let original = noteStore.fileStore
        XCTAssertNotNil(original)
        let other = NoteFileStore(directory: NotesDirectory(root: vaultB))
        noteStore.setFileStore(other)
        // Snapshot semantics: a fresh getter call sees the new store.
        XCTAssertEqual(noteStore.fileStore?.directory.root, other.directory.root)
    }

    // MARK: - Move

    func testMoveCopiesFilesAndUpdatesNoteStore() async throws {
        let note = try noteStore.createNote(title: "Original", body: "hello")
        XCTAssertNotNil(try noteStore.fileStore?.findURL(for: note.id))

        let moved = try await coordinator.moveVault(to: vaultB)
        XCTAssertGreaterThan(moved, 0)

        // NoteStore now points at vault-b.
        XCTAssertEqual(noteStore.fileStore?.directory.root.path,
                       NotesDirectoryTestHelper.canonicalize(vaultB))

        // The note is reachable at the new location with its body intact.
        let fetched = try noteStore.fetchNote(id: note.id)
        XCTAssertEqual(fetched?.body, "hello")

        // Source vault is gone after a successful move.
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultA.path))
    }

    func testMoveRefusesNonEmptyDestination() async throws {
        _ = try noteStore.createNote(title: "Existing", body: "")
        try FileManager.default.createDirectory(at: vaultB, withIntermediateDirectories: true)
        try Data().write(to: vaultB.appendingPathComponent("squatter.md"))

        do {
            _ = try await coordinator.moveVault(to: vaultB)
            XCTFail("Expected destinationNotEmpty")
        } catch VaultCoordinator.VaultError.destinationNotEmpty {
            // expected
        }
    }

    func testMoveRefusesCurrentVault() async throws {
        do {
            _ = try await coordinator.moveVault(to: vaultA)
            XCTFail("Expected destinationIsCurrentVault")
        } catch VaultCoordinator.VaultError.destinationIsCurrentVault {
            // expected
        }
    }

    func testMoveRefusesDestinationInsideCurrent() async throws {
        let inside = vaultA.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultA, withIntermediateDirectories: true)
        do {
            _ = try await coordinator.moveVault(to: inside)
            XCTFail("Expected destinationInsideCurrent")
        } catch VaultCoordinator.VaultError.destinationInsideCurrent {
            // expected
        }
    }

    // MARK: - Open

    func testOpenSwitchesToExistingVault() async throws {
        // Seed both vaults with distinct notes.
        let originalNote = try noteStore.createNote(title: "Stays in A", body: "A body")

        // Build vault B directly via NoteFileStore.
        try FileManager.default.createDirectory(at: vaultB, withIntermediateDirectories: true)
        let storeB = NoteFileStore(directory: NotesDirectory(root: vaultB))
        let imported = NoteFile(
            id: "import-1",
            frontmatter: NoteFrontmatter(title: "Lives in B", createdAt: Date(), updatedAt: Date()),
            body: "imported body"
        )
        try storeB.write(imported)

        try await coordinator.openVault(at: vaultB)

        // Vault A still has its files on disk — Open is non-destructive.
        let storeA = NoteFileStore(directory: NotesDirectory(root: vaultA))
        XCTAssertNotNil(try storeA.findURL(for: originalNote.id))

        // The DB now reflects vault B's contents. originalNote is gone
        // from the index (file isn't at the new location); imported is
        // present.
        XCTAssertNil(try noteStore.fetchNote(id: originalNote.id))
        XCTAssertEqual(try noteStore.fetchNote(id: "import-1")?.title, "Lives in B")
    }

    func testOpenRefusesNonexistent() async throws {
        let missing = tempParent.appendingPathComponent("never-existed")
        do {
            try await coordinator.openVault(at: missing)
            XCTFail("Expected destinationDoesNotExist")
        } catch VaultCoordinator.VaultError.destinationDoesNotExist {
            // expected
        }
    }

    func testPreviewOpenComputesDiff() throws {
        // DB has one note from setUp's noteStore.
        let original = try noteStore.createNote(title: "InDb", body: "")

        // Vault B has a different note.
        try FileManager.default.createDirectory(at: vaultB, withIntermediateDirectories: true)
        let storeB = NoteFileStore(directory: NotesDirectory(root: vaultB))
        try storeB.write(NoteFile(
            id: "only-on-disk",
            frontmatter: NoteFrontmatter(title: "OnDisk", createdAt: Date(), updatedAt: Date()),
            body: ""
        ))

        let preview = try coordinator.previewOpen(at: vaultB)
        XCTAssertEqual(preview.toImport, 1)   // only-on-disk would import
        XCTAssertEqual(preview.toRemove, 1)   // original would be removed
        _ = original
    }
}

/// Mirrors the canonicalization that `NotesDirectory.init(root:)` does so
/// path equality assertions don't fight the macOS `/var → /private/var`
/// alias.
private enum NotesDirectoryTestHelper {
    static func canonicalize(_ url: URL) -> String {
        let raw = url.path
        return raw.withCString { c in
            guard let p = realpath(c, nil) else { return raw }
            defer { free(p) }
            return String(cString: p)
        }
    }
}
