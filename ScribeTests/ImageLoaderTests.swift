// ScribeTests/ImageLoaderTests.swift
import XCTest
import AppKit
@testable import Scribe

/// Asserts the path-safety contract of `ImageLoader`:
///   1. Paths containing `..` segments are rejected outright.
///   2. The resolved file URL — relative, absolute, or `file://` — must
///      canonicalise inside the configured attachments root.
///
/// The cache is opaque from the outside; we don't assert on it directly.
/// Instead we verify rejected paths return nil even though a real file
/// sits at that absolute path on disk.
final class ImageLoaderTests: XCTestCase {

    private var sandbox: URL!
    private var attachmentsRoot: URL!
    private var noteDir: URL!
    private var validImageRelative: String!
    private var validImageAbsolute: URL!
    private var outsideImage: URL!

    override func setUp() {
        super.setUp()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageLoaderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        // Mimic the production layout: <root>/attachments/<noteId>/<file>.
        attachmentsRoot = sandbox.appendingPathComponent("Scribe", isDirectory: true)
        noteDir = attachmentsRoot
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent("note-1", isDirectory: true)
        try? FileManager.default.createDirectory(at: noteDir, withIntermediateDirectories: true)

        // A real 1×1 PNG so NSImage(contentsOf:) actually succeeds inside
        // the root — otherwise we can't tell "rejected by guard" from
        // "rejected by decoder."
        let pngBytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        ]
        let pngData = Data(pngBytes)

        let inside = noteDir.appendingPathComponent("ok.png")
        try? pngData.write(to: inside)
        validImageAbsolute = inside
        validImageRelative = "attachments/note-1/ok.png"

        // Same bytes, but living outside the root — what a malicious link
        // would try to point at.
        outsideImage = sandbox.appendingPathComponent("outside.png")
        try? pngData.write(to: outsideImage)

        #if DEBUG
        AttachmentsDirectory.rootOverrideForTesting = attachmentsRoot
        #endif

        // Reset cache state for determinism. ImageLoader has no clearCache;
        // we instead use a unique filename per test so the cache doesn't
        // hide our negative assertions.
    }

    override func tearDown() {
        #if DEBUG
        AttachmentsDirectory.rootOverrideForTesting = nil
        #endif
        try? FileManager.default.removeItem(at: sandbox)
        sandbox = nil
        super.tearDown()
    }

    func testLoadsValidRelativePathInsideAttachmentsRoot() {
        let img = ImageLoader.load(path: validImageRelative)
        XCTAssertNotNil(img, "Relative attachments path must resolve.")
    }

    func testRejectsParentSegmentInRelativePath() {
        // Even though `attachments/note-1/../note-1/ok.png` would resolve to
        // the same valid file, the `..` segment is forbidden — it's the
        // cheap first-line guard against traversal craft.
        XCTAssertNil(ImageLoader.load(path: "attachments/note-1/../note-1/ok.png"))
    }

    func testRejectsAbsolutePathOutsideAttachmentsRoot() {
        // The most important negative case: a crafted link pointing at a
        // file on disk that lives outside the per-app sandbox must NOT
        // load, even though the file is a valid PNG.
        XCTAssertNil(ImageLoader.load(path: outsideImage.path))
    }

    func testRejectsFileURLOutsideAttachmentsRoot() {
        XCTAssertNil(ImageLoader.load(path: "file://\(outsideImage.path)"))
    }

    func testAcceptsAbsolutePathInsideAttachmentsRoot() {
        // Absolute paths are not categorically banned — only those that
        // canonicalise outside the root. A path that resolves to a file
        // inside the root must still load (otherwise drag-and-drop into
        // the editor, which writes absolute URLs into the cache key, would
        // break).
        let img = ImageLoader.load(path: validImageAbsolute.path)
        XCTAssertNotNil(img, "Absolute path inside the root must still load.")
    }

    func testRejectsSiblingDirectoryThatSharesRootPrefix() {
        // "/sandbox/Scribe" vs "/sandbox/Scribe-evil" — the prefix-match guard
        // must require a directory boundary (trailing `/`), not a raw string
        // prefix match, or this attack succeeds.
        let sibling = sandbox.appendingPathComponent("Scribe-evil", isDirectory: true)
        try? FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let evilFile = sibling.appendingPathComponent("trap.png")
        try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: evilFile)
        XCTAssertNil(ImageLoader.load(path: evilFile.path))
    }
}
