// ScribeTests/AttachmentsDirectoryTests.swift
import XCTest
@testable import Scribe

final class AttachmentsDirectoryTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testDirectoryCreatesParent() throws {
        let dir = try AttachmentsDirectory.directory(forNoteId: "note-42", root: tempRoot)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testDirectoryReturnsSameForSameNoteId() throws {
        let a = try AttachmentsDirectory.directory(forNoteId: "n", root: tempRoot)
        let b = try AttachmentsDirectory.directory(forNoteId: "n", root: tempRoot)
        XCTAssertEqual(a.path, b.path)
    }

    func testStoreCopiesIntoDirectoryAndReturnsRelativePath() throws {
        // Create a source file to copy.
        let sourceFile = tempRoot.appendingPathComponent("source.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: sourceFile)

        let result = try AttachmentsDirectory.store(
            sourceURL: sourceFile,
            forNoteId: "note-1",
            root: tempRoot
        )

        // Returned relative path should be "attachments/note-1/<uuid>.png".
        XCTAssertTrue(result.relativePath.hasPrefix("attachments/note-1/"))
        XCTAssertTrue(result.relativePath.hasSuffix(".png"))
        // The destination file exists.
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.absoluteURL.path))
        // The original source is untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))
    }

    func testCleanupRemovesNoteDirectory() throws {
        let dir = try AttachmentsDirectory.directory(forNoteId: "n", root: tempRoot)
        try Data().write(to: dir.appendingPathComponent("a.png"))
        try AttachmentsDirectory.cleanup(forNoteId: "n", root: tempRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testCleanupOnMissingDirectoryIsNoOp() throws {
        XCTAssertNoThrow(try AttachmentsDirectory.cleanup(forNoteId: "ghost", root: tempRoot))
    }
}
