// ScribeTests/MarkdownRendererTests.swift
import XCTest
import AppKit
@testable import Scribe

/// Smoke tests for the AST-driven `MarkdownRenderer`. These don't exhaustively
/// cover every node type — they pin behaviour we care about not regressing:
/// the renderer preserves source text byte-for-byte, attaches the expected
/// custom attributes, and the cursor-proximity reveal flips marker visibility.
final class MarkdownRendererTests: XCTestCase {

    private let font = NSFont.systemFont(ofSize: 15)

    func testPreservesSourceVerbatim() {
        let source = "# Hello\n\nA *world* with `code` and **bold**.\n"
        let result = MarkdownRenderer.attributed(source, font: font)
        XCTAssertEqual(result.string, source)
    }

    func testHeadingGetsLargerFont() {
        let source = "# Title\n"
        let result = MarkdownRenderer.attributed(source, font: font)
        let f = result.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(f)
        XCTAssertGreaterThan(f!.pointSize, font.pointSize)
    }

    func testInlineCodeGetsContentMarker() {
        let source = "Hello `code` world\n"
        let result = MarkdownRenderer.attributed(source, font: font)
        let codeStart = (source as NSString).range(of: "code")
        let isCode = result.attribute(.scribeInlineCode, at: codeStart.location,
                                       effectiveRange: nil) as? Bool
        XCTAssertEqual(isCode, true)
    }

    func testInlineCodeBackticksAreSyntaxMarkers() {
        let source = "Hello `code` world\n"
        let result = MarkdownRenderer.attributed(source, font: font)
        let backtickLoc = (source as NSString).range(of: "`").location
        let isMarker = result.attribute(.scribeSyntaxMarker, at: backtickLoc,
                                         effectiveRange: nil) as? Bool
        XCTAssertEqual(isMarker, true)
    }

    func testBoldNesting() {
        let source = "**bold _italic_ end**\n"
        let result = MarkdownRenderer.attributed(source, font: font)
        // The inner italic content gets both bold+italic traits — regex engine couldn't.
        let italicLoc = (source as NSString).range(of: "italic").location
        let f = result.attribute(.font, at: italicLoc, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(f)
        let traits = f!.fontDescriptor.symbolicTraits
        XCTAssertTrue(traits.contains(.bold), "italic-inside-bold should keep bold trait")
        XCTAssertTrue(traits.contains(.italic), "italic-inside-bold should also be italic")
    }

    func testCodeBlockAttributesAndLanguage() {
        let source = "```swift\nlet x = 1\n```\n"
        let result = MarkdownRenderer.attributed(source, font: font)
        let blockLoc = (source as NSString).range(of: "let").location
        let isCodeLine = result.attribute(.codeBlockLine, at: blockLoc,
                                           effectiveRange: nil) as? Bool
        XCTAssertEqual(isCodeLine, true)
        let lang = result.attribute(.codeBlockLanguage, at: blockLoc,
                                     effectiveRange: nil) as? String
        XCTAssertEqual(lang, "swift")
    }

    func testBlockquoteFlagAndDepth() {
        let source = "> quoted line\n"
        let result = MarkdownRenderer.attributed(source, font: font)
        let isQuote = result.attribute(.blockquoteLine, at: 2, effectiveRange: nil) as? Bool
        XCTAssertEqual(isQuote, true)
        let depth = result.attribute(.blockquoteDepth, at: 2, effectiveRange: nil) as? Int
        XCTAssertEqual(depth, 1)
    }

    func testHorizontalRule() {
        let source = "---\n"
        let result = MarkdownRenderer.attributed(source, font: font)
        let isHR = result.attribute(.horizontalRule, at: 0, effectiveRange: nil) as? Bool
        XCTAssertEqual(isHR, true)
    }

    func testAutolinkBareURL() {
        let source = "see https://example.com here\n"
        let result = MarkdownRenderer.attributed(source, font: font)
        let urlLoc = (source as NSString).range(of: "https")
        let link = result.attribute(.link, at: urlLoc.location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "https://example.com")
        let autolink = result.attribute(.scribeAutoLinkURL, at: urlLoc.location,
                                         effectiveRange: nil) as? URL
        XCTAssertNotNil(autolink)
    }

    func testAutolinkSkipsURLsInsideInlineCode() {
        let source = "see `https://example.com` here\n"
        let result = MarkdownRenderer.attributed(source, font: font)
        let urlLoc = (source as NSString).range(of: "https")
        // The URL inside backticks must NOT be turned into a clickable link.
        let link = result.attribute(.link, at: urlLoc.location, effectiveRange: nil) as? URL
        XCTAssertNil(link)
    }

    func testAutolinkSkipsURLsInsideMarkdownLinkDestinations() {
        // Regression: applyLink dims the destination URL with .scribeSyntaxMarker
        // but doesn't set .link on it. autolinkBareURLs previously only checked
        // .link / .scribeInlineCode / .codeBlockLine and would re-stamp .link
        // on top, breaking the visual styling and producing two underlined
        // ranges in [label](url).
        let source = "see [the docs](https://example.com) for details\n"
        let result = MarkdownRenderer.attributed(source, font: font)
        let urlInsideParens = (source as NSString).range(of: "https://example.com")
        let link = result.attribute(.link, at: urlInsideParens.location,
                                     effectiveRange: nil) as? URL
        XCTAssertNil(link, "URL inside a markdown link destination must NOT be re-autolinked")
        // And the LABEL `the docs` still IS a link.
        let labelLoc = (source as NSString).range(of: "the docs").location
        let labelLink = result.attribute(.link, at: labelLoc, effectiveRange: nil) as? URL
        XCTAssertEqual(labelLink?.absoluteString, "https://example.com")
    }

    func testCursorAtBlockEndKeepsMarkersVisible() {
        // Regression: NSRange.contains is half-open, so a cursor at NSMaxRange
        // of a block was not matching any block and the marker-reveal pass
        // hid every marker — including for the block the user was editing.
        let source = "**hi**\n"
        let cursorAtEnd = (source as NSString).length - 1  // just before final \n
        let result = MarkdownRenderer.attributed(source, font: font, cursorOffset: cursorAtEnd)
        let markerLoc = (source as NSString).range(of: "**").location
        let color = result.attribute(.foregroundColor, at: markerLoc,
                                      effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(color, .clear,
                          "markers in the block containing the cursor must stay visible, even when cursor is at block end")
    }

    func testCursorProximityRevealHidesMarkersInOtherBlocks() {
        // Two paragraphs. Place cursor in the second — markers in the first
        // should be hidden (foreground=clear); markers in the second should
        // remain dim-but-visible (foreground=marker color, not clear).
        let source = "**first paragraph**\n\n**second paragraph**\n"
        let secondPara = (source as NSString).range(of: "second")
        let cursor = secondPara.location
        let result = MarkdownRenderer.attributed(source, font: font, cursorOffset: cursor)

        // First paragraph's `**` is hidden.
        let firstMarkerLoc = (source as NSString).range(of: "**").location
        let firstColor = result.attribute(.foregroundColor, at: firstMarkerLoc,
                                           effectiveRange: nil) as? NSColor
        XCTAssertEqual(firstColor, .clear, "markers outside cursor block must be hidden")

        // Second paragraph's `**` is dimmed but visible.
        let secondMarkerLoc = (source as NSString).range(of: "**second")
        let secondColor = result.attribute(.foregroundColor, at: secondMarkerLoc.location,
                                            effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(secondColor, .clear,
                          "markers inside cursor block must remain visible")
    }

    func testEmptySource() {
        let result = MarkdownRenderer.attributed("", font: font)
        XCTAssertEqual(result.length, 0)
    }
}
