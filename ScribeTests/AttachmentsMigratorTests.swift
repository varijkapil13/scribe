// ScribeTests/AttachmentsMigratorTests.swift
import XCTest
@testable import Scribe

/// Slice 7 contract: one-time move of per-note attachment folders from
/// the legacy Application Support location into the vault root, leaving
/// the relative-path format unchanged.
final class AttachmentsMigratorTests: XCTestCase {

    private var legacyRoot: URL!
    private var newRoot: URL!

    override func setUp() {
        super.setUp()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        legacyRoot = parent.appendingPathComponent("legacy", isDirectory: true)
        newRoot = parent.appendingPathComponent("vault", isDirectory: true)
        try? FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        let parent = legacyRoot.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: parent)
        super.tearDown()
    }

    func testMovesPerNoteFolders() throws {
        // Seed two note folders with one file each under the legacy root.
        let legacyAttachments = legacyRoot.appendingPathComponent("attachments", isDirectory: true)
        for noteId in ["note-a", "note-b"] {
            let dir = legacyAttachments.appendingPathComponent(noteId, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([0x01, 0x02]).write(to: dir.appendingPathComponent("img.png"))
        }

        let moved = try AttachmentsMigrator.migrateIfNeeded(legacyRoot: legacyRoot, newRoot: newRoot)
        XCTAssertEqual(moved, 2)

        let newAttachments = newRoot.appendingPathComponent("attachments", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newAttachments.appendingPathComponent("note-a/img.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newAttachments.appendingPathComponent("note-b/img.png").path))
    }

    func testIdempotentSecondRun() throws {
        let legacyAttachments = legacyRoot.appendingPathComponent("attachments", isDirectory: true)
        let dir = legacyAttachments.appendingPathComponent("note", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("a.png"))

        XCTAssertEqual(try AttachmentsMigrator.migrateIfNeeded(legacyRoot: legacyRoot, newRoot: newRoot), 1)
        // Second invocation should find the legacy root empty (or absent)
        // and move nothing.
        XCTAssertEqual(try AttachmentsMigrator.migrateIfNeeded(legacyRoot: legacyRoot, newRoot: newRoot), 0)
    }

    func testPreservesUserStateOnCollision() throws {
        // Pre-existing destination — user manually copied before launch.
        let newAttachments = newRoot.appendingPathComponent("attachments", isDirectory: true)
        let dst = newAttachments.appendingPathComponent("note", isDirectory: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        try Data([0xAA]).write(to: dst.appendingPathComponent("a.png"))

        // Same note id in the legacy root, *different* content.
        let legacySrc = legacyRoot
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent("note", isDirectory: true)
        try FileManager.default.createDirectory(at: legacySrc, withIntermediateDirectories: true)
        try Data([0xBB]).write(to: legacySrc.appendingPathComponent("a.png"))

        _ = try AttachmentsMigrator.migrateIfNeeded(legacyRoot: legacyRoot, newRoot: newRoot)
        // The destination must keep the user's existing bytes.
        let kept = try Data(contentsOf: dst.appendingPathComponent("a.png"))
        XCTAssertEqual(kept, Data([0xAA]))
    }

    func testNoOpWhenLegacyMissing() throws {
        // Don't create the legacy attachments dir at all.
        XCTAssertEqual(try AttachmentsMigrator.migrateIfNeeded(legacyRoot: legacyRoot, newRoot: newRoot), 0)
    }
}
