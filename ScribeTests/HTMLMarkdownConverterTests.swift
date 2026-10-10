// ScribeTests/HTMLMarkdownConverterTests.swift
import XCTest
@testable import Scribe

final class HTMLMarkdownConverterTests: XCTestCase {

    private func md(_ html: String, options: HTMLMarkdownOptions = HTMLMarkdownOptions()) -> String {
        HTMLMarkdownConverter.markdown(fromHTML: html, options: options)
    }

    // MARK: - Blocks

    func testParagraphsAndBold() {
        XCTAssertEqual(md("<p>Hello <b>world</b></p><p>Second</p>"), "Hello **world**\n\nSecond")
    }

    func testEvernoteDivLinesAndBlankLine() {
        let enml = """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd">\
        <en-note><div>First line</div><div><br/></div><div>Third &amp; last</div></en-note>
        """
        XCTAssertEqual(md(enml), "First line\n\nThird & last")
    }

    func testHeadingLinkAndImage() {
        let html = #"<h2>Title &lt;x&gt;</h2><p>See <a href="https://example.com">the site</a> and <img src="pic.png" alt="A pic"></p>"#
        XCTAssertEqual(md(html), "## Title <x>\n\nSee [the site](https://example.com) and ![A pic](pic.png)")
    }

    func testLineBreakInsideParagraph() {
        XCTAssertEqual(md("<p>Line one<br>Line two</p>"), "Line one\nLine two")
    }

    func testNestedAndOrderedLists() {
        let html = "<ul><li>One</li><li>Two<ul><li>Nested</li></ul></li></ul><ol><li>First</li><li>Second</li></ol>"
        XCTAssertEqual(md(html), "- One\n- Two\n  - Nested\n\n1. First\n2. Second")
    }

    func testUnclosedListItemsAreClosedImplicitly() {
        XCTAssertEqual(md("<ul><li>A<li>B</ul>"), "- A\n- B")
    }

    func testEvernoteTodos() {
        let enml = #"<en-note><div><en-todo checked="true"/>Done task</div><div><en-todo/>Open task</div></en-note>"#
        XCTAssertEqual(md(enml), "- [x] Done task\n- [ ] Open task")
    }

    func testTodoInsideListItem() {
        XCTAssertEqual(md(#"<ul><li><en-todo checked="false"/>Call Bob</li></ul>"#), "- [ ] Call Bob")
    }

    func testAppleNotesChecklist() {
        let html = #"<ul class="checklist"><li class="checked">Milk</li><li>Eggs</li></ul>"#
        XCTAssertEqual(md(html), "- [x] Milk\n- [ ] Eggs")
    }

    func testBlockquoteCodeBlockInlineCodeAndRule() {
        let html = """
        <blockquote><p>Quoted line</p><p>Second</p></blockquote><pre><code>let x = 1
        let y = 2</code></pre><p>Use <code>git status</code></p><hr>
        """
        XCTAssertEqual(
            md(html),
            "> Quoted line\n>\n> Second\n\n```\nlet x = 1\nlet y = 2\n```\n\nUse `git status`\n\n---"
        )
    }

    func testEvernoteCodeBlockDiv() {
        let enml = #"<en-note><div style="-en-codeblock: true;"><div>a = 1</div><div>b = 2</div></div></en-note>"#
        XCTAssertEqual(md(enml), "```\na = 1\nb = 2\n```")
    }

    func testTable() {
        let html = "<table><tr><th>Name</th><th>Qty</th></tr><tr><td>Apples</td><td>3</td></tr><tr><td>Pipe | char</td></tr></table>"
        XCTAssertEqual(md(html), "| Name | Qty |\n| --- | --- |\n| Apples | 3 |\n| Pipe \\| char |  |")
    }

    func testTableWithTheadAndTbody() {
        let html = "<table><thead><tr><th>A</th></tr></thead><tbody><tr><td>1</td></tr></tbody></table>"
        XCTAssertEqual(md(html), "| A |\n| --- |\n| 1 |")
    }

    // MARK: - Inline

    func testItalicStrikeAndStyledSpans() {
        XCTAssertEqual(md("<p><i>it</i> <s>gone</s> <em>em</em></p>"), "*it* ~~gone~~ *em*")
        XCTAssertEqual(md(#"<div><span style="font-weight: bold;">Bold</span> text</div>"#), "**Bold** text")
        XCTAssertEqual(md(#"<div><span style="font-style:italic">Lean</span></div>"#), "*Lean*")
    }

    func testWhitespaceAroundInlineElementsIsKept() {
        XCTAssertEqual(md("<p>Hello<b> world</b>!</p>"), "Hello **world**!")
        XCTAssertEqual(md("<p>a <b></b> b</p>"), "a b")
    }

    func testLinkVariants() {
        XCTAssertEqual(md(#"<p><a href="https://x.dev">https://x.dev</a></p>"#), "<https://x.dev>")
        XCTAssertEqual(md(#"<p><a href="x.html"><b>Bold link</b></a></p>"#), "[**Bold link**](x.html)")
        XCTAssertEqual(md(##"<p><a href="#top">Top</a></p>"##), "Top")
        XCTAssertEqual(md(#"<p><a href="my page.html">Spaced</a></p>"#), "[Spaced](<my page.html>)")
        var options = HTMLMarkdownOptions()
        options.resolveLink = { href in href == "page.html" ? "[[Other Page]]" : href }
        XCTAssertEqual(md(#"<p>See <a href="page.html">it</a></p>"#, options: options), "See [[Other Page]]")
    }

    func testImagesAreResolvedOrDropped() {
        XCTAssertEqual(md(#"<p><img src="data:image/png;base64,AAAA"></p>"#), "")
        var options = HTMLMarkdownOptions()
        options.resolveImage = { src, _ in src == "a.png" ? "attachments/n/a.png" : nil }
        XCTAssertEqual(md(#"<p><img src="a.png" alt="x"><img src="b.png"></p>"#, options: options), "![x](attachments/n/a.png)")
    }

    func testEntitiesAndWhitespaceCollapse() {
        XCTAssertEqual(
            md("<div>  Lots   of\n   space&nbsp;here &#x263A; &#9731; &unknown; &amp;</div>"),
            "Lots of space here \u{263A} \u{2603} &unknown; &"
        )
    }

    func testLineStartEscapes() {
        XCTAssertEqual(
            md("<p># not a heading</p><p>#hashtag stays</p><p>1. not a list</p><p>- not a bullet</p>"),
            "\\# not a heading\n\n#hashtag stays\n\n1\\. not a list\n\n\\- not a bullet"
        )
    }

    func testScriptsStylesAndCommentsAreSkipped() {
        let html = "<style>p{color:red}</style><!-- hidden --><p>Visible</p><script>if (a < b) alert(1)</script>"
        XCTAssertEqual(md(html), "Visible")
    }

    func testDocumentTitleAndBody() {
        let html = "<html><head><title>My Note</title><meta charset=\"utf-8\"></head><body><h1>My Note</h1><p>Body</p></body></html>"
        XCTAssertEqual(HTMLMarkdownConverter.documentTitle(inHTML: html), "My Note")
        XCTAssertEqual(md(html), "# My Note\n\nBody")
        XCTAssertNil(HTMLMarkdownConverter.documentTitle(inHTML: "<p>No title</p>"))
    }

    func testEncryptedEvernoteContentIsReplacedByANotice() {
        let out = md("<en-note><div>Before</div><en-crypt hint=\"x\">ABCDEF</en-crypt></en-note>")
        XCTAssertTrue(out.hasPrefix("Before\n"))
        XCTAssertTrue(out.contains("Encrypted Evernote content was not imported"))
        XCTAssertFalse(out.contains("ABCDEF"))
    }

    func testMalformedMarkupDoesNotCrash() {
        XCTAssertEqual(md("<p>Unclosed <b>bold"), "Unclosed **bold**")
        XCTAssertEqual(md("</div>stray end</span>"), "stray end")
        XCTAssertEqual(md("a < b and c > d"), "a < b and c > d")
        XCTAssertEqual(md("<"), "<")
    }

    // MARK: - Helpers

    func testEntityDecoding() {
        XCTAssertEqual(HTMLEntities.decode("&lt;tag&gt; &quot;q&quot; &#39;s&#39; &mdash; &#x41;"), "<tag> \"q\" 's' \u{2014} A")
        XCTAssertEqual(HTMLEntities.decode("no entities"), "no entities")
        XCTAssertEqual(HTMLEntities.decode("AT&T"), "AT&T")
    }

    func testEscapeLineStart() {
        XCTAssertEqual(HTMLMarkdownRenderer.escapeLineStart("> quote"), "\\> quote")
        XCTAssertEqual(HTMLMarkdownRenderer.escapeLineStart("## two"), "\\## two")
        XCTAssertEqual(HTMLMarkdownRenderer.escapeLineStart("#tag"), "#tag")
        XCTAssertEqual(HTMLMarkdownRenderer.escapeLineStart("+ plus"), "\\+ plus")
        XCTAssertEqual(HTMLMarkdownRenderer.escapeLineStart("12) item"), "12\\) item")
        XCTAssertEqual(HTMLMarkdownRenderer.escapeLineStart("2026 was"), "2026 was")
    }
}
