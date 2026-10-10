// ScribeTests/MarkdownImportRewriterTests.swift
import XCTest
@testable import Scribe

final class MarkdownImportRewriterTests: XCTestCase {

    // MARK: - Links

    func testRewriteLinksSkipsFencedAndInlineCode() {
        let input = """
        See [doc](a.md) and ![pic](img/p.png "Title").
        `[not](code.md)` stays.
        ```
        [fenced](x.md)
        ```
        After [b](<My Page.md>)
        """
        var seen: [String] = []
        let output = MarkdownImportRewriter.rewriteLinks(in: input) { match in
            seen.append(match.destination)
            return match.isImage ? "![\(match.text)](NEW)" : "[[\(match.text)]]"
        }
        XCTAssertEqual(seen, ["a.md", "img/p.png", "My Page.md"])
        XCTAssertEqual(output, """
        See [[doc]] and ![pic](NEW).
        `[not](code.md)` stays.
        ```
        [fenced](x.md)
        ```
        After [[b]]
        """)
    }

    func testRewriteLinksKeepsMatchWhenTransformReturnsNil() {
        let input = "[a](https://example.com) and [b](b.md)"
        let output = MarkdownImportRewriter.rewriteLinks(in: input) { match in
            match.isExternal ? nil : "[[\(match.text)]]"
        }
        XCTAssertEqual(output, "[a](https://example.com) and [[b]]")
    }

    func testLinkMatchDecodingAndSchemes() {
        let match = MarkdownLinkMatch(isImage: false, text: "x", destination: "My%20Page%20abc.md")
        XCTAssertEqual(match.decodedDestination, "My Page abc.md")
        XCTAssertFalse(match.isExternal)
        XCTAssertTrue(MarkdownImportRewriter.hasURLScheme("https://x.dev"))
        XCTAssertTrue(MarkdownImportRewriter.hasURLScheme("mailto:a@b.c"))
        XCTAssertFalse(MarkdownImportRewriter.hasURLScheme("C:/x"))
        XCTAssertFalse(MarkdownImportRewriter.hasURLScheme("img/a.png"))
    }

    func testRewriteEmbedsAndImageTags() {
        let embeds = MarkdownImportRewriter.rewriteEmbeds(in: "Look ![[photo.png|300]] and ![[Other Note]]") { target in
            target == "photo.png" ? "![photo](P1)" : nil
        }
        XCTAssertEqual(embeds, "Look ![photo](P1) and ![[Other Note]]")

        let tags = MarkdownImportRewriter.rewriteImageTags(in: #"<img src="a/b.png" width="20"> <IMG SRC='c.png'>"#) { src in
            src == "a/b.png" ? "NEW" : nil
        }
        XCTAssertEqual(tags, #"<img src="NEW" width="20"> <IMG SRC='c.png'>"#)
    }

    // MARK: - Paths

    func testResolveRelative() {
        XCTAssertEqual(MarkdownImportRewriter.resolveRelative("img/a.png", fromFolder: "Notes/Work"), "Notes/Work/img/a.png")
        XCTAssertEqual(MarkdownImportRewriter.resolveRelative("../img/a.png", fromFolder: "Notes/Work"), "Notes/img/a.png")
        XCTAssertEqual(MarkdownImportRewriter.resolveRelative("./a.png#frag", fromFolder: ""), "a.png")
        XCTAssertEqual(MarkdownImportRewriter.resolveRelative("/assets/a.png?x=1", fromFolder: "Deep/Er"), "assets/a.png")
        XCTAssertNil(MarkdownImportRewriter.resolveRelative("../../a.png", fromFolder: "One"))
        XCTAssertNil(MarkdownImportRewriter.resolveRelative("#heading", fromFolder: "One"))
    }

    // MARK: - Notion names

    func testStripNotionId() {
        XCTAssertEqual(MarkdownImportRewriter.stripNotionId("Meeting Notes 0123456789abcdef0123456789ABCDEF"), "Meeting Notes")
        XCTAssertEqual(MarkdownImportRewriter.stripNotionId("Roadmap_0123456789abcdef0123456789abcdef"), "Roadmap")
        XCTAssertEqual(MarkdownImportRewriter.stripNotionId("Plain name"), "Plain name")
        // Too short to be an id.
        XCTAssertEqual(MarkdownImportRewriter.stripNotionId("Hex abc123"), "Hex abc123")
        // A name that is only an id is kept.
        XCTAssertEqual(MarkdownImportRewriter.stripNotionId("0123456789abcdef0123456789abcdef"), "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(MarkdownImportRewriter.notionTitle(forFileName: "Q3 Plan 0123456789abcdef0123456789abcdef.md"), "Q3 Plan")
    }

    // MARK: - Titles

    func testUniqueTitleAddsSuffixCaseInsensitively() {
        var taken: Set<String> = ["ideas", "ideas 2"]
        XCTAssertEqual(MarkdownImportRewriter.uniqueTitle("Ideas", taken: &taken), "Ideas 3")
        XCTAssertEqual(MarkdownImportRewriter.uniqueTitle("Fresh", taken: &taken), "Fresh")
        XCTAssertEqual(MarkdownImportRewriter.uniqueTitle("fresh", taken: &taken), "fresh 2")
        XCTAssertEqual(MarkdownImportRewriter.uniqueTitle("   ", taken: &taken), "Untitled")
        XCTAssertTrue(taken.contains("ideas 3"))
    }

    func testRemovingLeadingTitleHeading() {
        XCTAssertEqual(MarkdownImportRewriter.removingLeadingTitleHeading("\n# My Page\n\nBody", title: "my page"), "Body")
        XCTAssertEqual(MarkdownImportRewriter.removingLeadingTitleHeading("# Other\nBody", title: "My Page"), "# Other\nBody")
        XCTAssertEqual(MarkdownImportRewriter.removingLeadingTitleHeading("## My Page\nBody", title: "My Page"), "## My Page\nBody")
    }

    // MARK: - Frontmatter

    func testSplitFrontmatter() throws {
        let file = """
        ---
        title: "Trip Plan"
        tags: [travel, "#summer"]
        aliases:
          - Holiday
          - Vacation
        created: 2024-01-05
        updated: 2024-02-01T10:30:00Z
        id: should-be-dropped
        rating: 5
        ---

        # Trip Plan
        Body text
        """
        let (meta, body) = MarkdownImportRewriter.splitFrontmatter(file)
        XCTAssertEqual(meta.title, "Trip Plan")
        XCTAssertEqual(meta.tags, ["travel", "summer"])
        XCTAssertEqual(meta.extra, [
            FrontmatterEntry(key: "aliases", value: "[Holiday, Vacation]"),
            FrontmatterEntry(key: "rating", value: "5"),
        ])
        let created = try XCTUnwrap(meta.created)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        XCTAssertEqual(calendar.component(.year, from: created), 2024)
        XCTAssertEqual(meta.updated, Date(timeIntervalSince1970: 1_706_783_400))
        XCTAssertEqual(body, "# Trip Plan\nBody text")
    }

    func testSplitFrontmatterWithoutBlockAndSpaceSeparatedTags() {
        let (none, body) = MarkdownImportRewriter.splitFrontmatter("Just text\n---\nmore")
        XCTAssertNil(none.title)
        XCTAssertEqual(body, "Just text\n---\nmore")

        let (meta, _) = MarkdownImportRewriter.splitFrontmatter("---\ntags: work #home\n---\nx")
        XCTAssertEqual(meta.tags, ["work", "home"])
    }

    func testParseDateFormats() {
        XCTAssertEqual(MarkdownImportRewriter.parseDate("2024-02-01T10:30:00Z"), Date(timeIntervalSince1970: 1_706_783_400))
        XCTAssertEqual(MarkdownImportRewriter.parseDate("2024-02-01T10:30:00.000Z"), Date(timeIntervalSince1970: 1_706_783_400))
        XCTAssertNotNil(MarkdownImportRewriter.parseDate("2024-02-01"))
        XCTAssertNotNil(MarkdownImportRewriter.parseDate("2024-02-01 09:15"))
        XCTAssertNotNil(MarkdownImportRewriter.parseDate("January 5, 2024 3:04 PM"))
        XCTAssertNil(MarkdownImportRewriter.parseDate("someday"))
        XCTAssertNil(MarkdownImportRewriter.parseDate(""))
    }

    // MARK: - CSV

    func testParseCSV() {
        let csv = "\u{FEFF}Name,Notes\r\n\"Smith, Jo\",\"said \"\"hi\"\"\nthen left\"\r\nPlain,\r\n\r\n"
        XCTAssertEqual(MarkdownImportRewriter.parseCSV(csv), [
            ["Name", "Notes"],
            ["Smith, Jo", "said \"hi\"\nthen left"],
            ["Plain", ""],
        ])
        XCTAssertEqual(MarkdownImportRewriter.parseCSV("a,b"), [["a", "b"]])
    }

    func testMarkdownTableFromCSVLinksKnownPages() {
        let rows = [["Name", "Status", "Extra"], ["Launch", "Done"], ["Other | thing", "Open", "x\ny"]]
        let table = MarkdownImportRewriter.markdownTable(fromCSV: rows) { $0 == "Launch" }
        XCTAssertEqual(table, """
        | Name | Status | Extra |
        | --- | --- | --- |
        | [[Launch]] | Done |  |
        | Other \\| thing | Open | x y |
        """)
        XCTAssertEqual(MarkdownImportRewriter.markdownTable(fromCSV: []), "")
    }

    // MARK: - Recognized text

    func testEscapedPlainText() {
        let text = "# Heading-like\n\n\n- bullet-like\n```\n<b>tag</b>\n  plain  "
        XCTAssertEqual(
            MarkdownImportRewriter.escapedPlainText(text),
            "\\# Heading-like\n\n\\- bullet-like\n\\```\n\\<b>tag</b>\nplain"
        )
        XCTAssertEqual(MarkdownImportRewriter.escapedPlainText("  \n\n "), "")
    }
}
