// ScribeTests/MarkdownOpenClassifierTests.swift
import XCTest
@testable import Scribe

final class MarkdownOpenClassifierTests: XCTestCase {

    private let vault = URL(fileURLWithPath: "/Users/me/Documents/Scribe", isDirectory: true)

    private func classify(_ path: String, root: URL? = nil) -> MarkdownOpenClassifier.Disposition {
        MarkdownOpenClassifier.classify(fileURL: URL(fileURLWithPath: path), vaultRoot: root ?? vault)
    }

    func testNoteAtVaultRoot() {
        XCTAssertEqual(classify("/Users/me/Documents/Scribe/Plans.md"), .vaultNote(relativePath: "Plans.md"))
    }

    func testNoteInSubfolder() {
        XCTAssertEqual(
            classify("/Users/me/Documents/Scribe/Work/Q4/Roadmap.md"),
            .vaultNote(relativePath: "Work/Q4/Roadmap.md")
        )
    }

    func testDailyNote() {
        XCTAssertEqual(
            classify("/Users/me/Documents/Scribe/Daily/2026-10-10.md"),
            .vaultNote(relativePath: "Daily/2026-10-10.md")
        )
    }

    func testUppercaseExtensionInVault() {
        XCTAssertEqual(classify("/Users/me/Documents/Scribe/README.MD"), .vaultNote(relativePath: "README.MD"))
    }

    func testFileOutsideVaultIsImported() {
        XCTAssertEqual(classify("/Users/me/Downloads/notes.md"), .importCopy)
    }

    func testSiblingFolderWithSharedPrefixIsOutside() {
        // "/…/Scribe Archive" starts with "/…/Scribe" but is not inside it.
        XCTAssertEqual(classify("/Users/me/Documents/Scribe Archive/old.md"), .importCopy)
    }

    func testDotDotEscapingTheVaultIsOutside() {
        XCTAssertEqual(classify("/Users/me/Documents/Scribe/../elsewhere.md"), .importCopy)
    }

    func testDotDotStayingInsideTheVault() {
        XCTAssertEqual(
            classify("/Users/me/Documents/Scribe/Work/../Plans.md"),
            .vaultNote(relativePath: "Plans.md")
        )
    }

    func testPrivateAliasOnEitherSide() {
        let root = URL(fileURLWithPath: "/private/var/folders/x/Scribe", isDirectory: true)
        XCTAssertEqual(
            classify("/var/folders/x/Scribe/a.md", root: root),
            .vaultNote(relativePath: "a.md")
        )
        let plainRoot = URL(fileURLWithPath: "/var/folders/x/Scribe", isDirectory: true)
        XCTAssertEqual(
            classify("/private/var/folders/x/Scribe/b.md", root: plainRoot),
            .vaultNote(relativePath: "b.md")
        )
    }

    func testHiddenFolderInVaultIsImported() {
        XCTAssertEqual(classify("/Users/me/Documents/Scribe/.trash/old.md"), .importCopy)
        XCTAssertEqual(classify("/Users/me/Documents/Scribe/.hidden.md"), .importCopy)
    }

    func testExcludedTemplateFolderIsImported() {
        XCTAssertEqual(classify("/Users/me/Documents/Scribe/templates/summaries/Standup.md"), .importCopy)
    }

    func testMarkdownVariantExtensionInVaultIsImported() {
        // The vault only indexes `.md`; a `.markdown` file there isn't a note.
        XCTAssertEqual(classify("/Users/me/Documents/Scribe/Plans.markdown"), .importCopy)
    }

    func testMarkdownVariantExtensionOutsideVaultIsImported() {
        XCTAssertEqual(classify("/Users/me/Desktop/Plans.markdown"), .importCopy)
        XCTAssertEqual(classify("/Users/me/Desktop/Plans.mdown"), .importCopy)
    }

    func testNonMarkdownIsUnsupported() {
        XCTAssertEqual(classify("/Users/me/Documents/Scribe/photo.png"), .unsupported)
        XCTAssertEqual(classify("/Users/me/Desktop/notes.txt"), .unsupported)
        XCTAssertEqual(classify("/Users/me/Desktop/md"), .unsupported)
    }

    func testRemoteURLIsUnsupported() {
        let url = URL(string: "https://example.com/readme.md")
        XCTAssertNotNil(url)
        if let url {
            XCTAssertEqual(MarkdownOpenClassifier.classify(fileURL: url, vaultRoot: vault), .unsupported)
        }
    }

    func testNoVaultImportsEverything() {
        XCTAssertEqual(
            MarkdownOpenClassifier.classify(fileURL: URL(fileURLWithPath: "/Users/me/Documents/Scribe/a.md"), vaultRoot: nil),
            .importCopy
        )
    }

    func testVaultRootWithTrailingSlash() {
        let root = URL(fileURLWithPath: "/Users/me/Documents/Scribe/")
        XCTAssertEqual(classify("/Users/me/Documents/Scribe/a.md", root: root), .vaultNote(relativePath: "a.md"))
    }

    func testFallbackTitle() {
        XCTAssertEqual(MarkdownOpenClassifier.fallbackTitle(for: URL(fileURLWithPath: "/tmp/Meeting Notes.md")), "Meeting Notes")
    }
}
