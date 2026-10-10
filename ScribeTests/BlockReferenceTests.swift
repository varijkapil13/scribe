// ScribeTests/BlockReferenceTests.swift
import XCTest
@testable import Scribe

final class WikiLinkTargetTests: XCTestCase {

    func testParsesPlainAliasHeadingAndBlock() {
        XCTAssertEqual(WikiLinkTarget.parse("Note"), WikiLinkTarget(title: "Note"))
        XCTAssertEqual(WikiLinkTarget.parse(" Note | shown "), WikiLinkTarget(title: "Note", alias: "shown"))
        XCTAssertEqual(WikiLinkTarget.parse("Note#Section A"), WikiLinkTarget(title: "Note", heading: "Section A"))
        XCTAssertEqual(WikiLinkTarget.parse("Note#^abc-1|see"),
                       WikiLinkTarget(title: "Note", blockId: "abc-1", alias: "see"))
        XCTAssertEqual(WikiLinkTarget.parse("#Heading"), WikiLinkTarget(title: "", heading: "Heading"))
        XCTAssertTrue(WikiLinkTarget.parse("#^id").refersToSameNote)
        XCTAssertFalse(WikiLinkTarget.parse("Note#").hasFragment)
    }

    func testAnchorTextRoundTrips() {
        for anchor in ["Note", "Note#Heading", "Note#^id", "Note#^id|alias", "#Heading"] {
            XCTAssertEqual(WikiLinkTarget.parse(anchor).anchorText, anchor)
        }
    }

    func testLookupCandidatesPreferWholeAnchor() {
        XCTAssertEqual(WikiLinkTarget.lookupCandidates(forAnchor: "C# Tips|c"), ["C# Tips", "C"])
        XCTAssertEqual(WikiLinkTarget.lookupCandidates(forAnchor: "Note#Heading"), ["Note#Heading", "Note"])
        XCTAssertEqual(WikiLinkTarget.lookupCandidates(forAnchor: "Note"), ["Note"])
        XCTAssertEqual(WikiLinkTarget.lookupCandidates(forAnchor: "#Heading"), ["#Heading"])
    }

    func testUnresolvedAnchorsUnderstandFragments() {
        let unresolved = WikiLinkResolver.unresolvedAnchors(
            existingTitles: ["Alpha"],
            body: "[[Alpha#Intro]] [[Alpha#^b1|x]] [[#Local]] [[Ghost#Intro]]"
        )
        XCTAssertEqual(unresolved, ["Ghost#Intro"])
    }

    func testNoteStoreResolvesHeadingAndBlockLinks() throws {
        let store = NoteStore(databaseManager: try DatabaseManager(path: ":memory:"))
        let target = try store.createNote(title: "Alpha", body: "")
        let source = try store.createNote(title: "Source", body: "")
        var updated = source
        updated.body = "See [[Alpha#Intro]] and [[alpha#^b1|that]]."
        try store.updateNote(updated, tags: [])
        let backlinks = try store.backlinks(for: target.id)
        XCTAssertEqual(backlinks.map(\.id), [source.id])
        XCTAssertEqual(try store.resolveLinkTarget(anchor: "Alpha#Intro")?.id, target.id)
        XCTAssertNil(try store.resolveLinkTarget(anchor: "#Intro"))
    }
}

final class NoteBlockReferenceTests: XCTestCase {

    private let body = """
    # Project

    Intro paragraph line one
    continues here ^intro

    ## Tasks
    - first item ^item1
      - child of first
    - second item

    ### Detail
    Deep text.

    ## Notes
    A table:

    | a | b |
    ^table1

    ```
    # not a heading
    fake ^nope
    ```
    """

    func testHeadingSectionRunsToNextSameOrHigherHeading() {
        XCTAssertEqual(NoteBlockReference.headingSection("tasks", in: body), """
        ## Tasks
        - first item ^item1
          - child of first
        - second item

        ### Detail
        Deep text.
        """)
        XCTAssertEqual(NoteBlockReference.headingSection("Detail", in: body), "### Detail\nDeep text.")
        XCTAssertNil(NoteBlockReference.headingSection("not a heading", in: body))
    }

    func testParagraphBlock() {
        XCTAssertEqual(NoteBlockReference.block("intro", in: body), "Intro paragraph line one\ncontinues here")
    }

    func testListItemBlockIncludesChildren() {
        XCTAssertEqual(NoteBlockReference.block("item1", in: body), "- first item\n  - child of first")
    }

    func testStandaloneAnchorTargetsPrecedingBlock() {
        XCTAssertEqual(NoteBlockReference.block("table1", in: body), "| a | b |")
    }

    func testAnchorsInsideCodeAreIgnored() {
        XCTAssertNil(NoteBlockReference.block("nope", in: body))
        XCTAssertEqual(NoteBlockReference.blockIds(in: body), ["intro", "item1", "table1"])
    }

    func testLineIndexForTargets() {
        XCTAssertEqual(NoteBlockReference.lineIndex(for: WikiLinkTarget(title: "", heading: "Notes"), in: body), 13)
        XCTAssertEqual(NoteBlockReference.lineIndex(for: WikiLinkTarget(title: "", blockId: "item1"), in: body), 6)
        XCTAssertNil(NoteBlockReference.lineIndex(for: WikiLinkTarget(title: "X"), in: body))
    }

    func testBlockIdParsing() {
        XCTAssertEqual(NoteBlockReference.blockId(in: "text ^abc-1  "), "abc-1")
        XCTAssertEqual(NoteBlockReference.blockId(in: "^solo"), "solo")
        XCTAssertNil(NoteBlockReference.blockId(in: "x^notanchor"))
        XCTAssertNil(NoteBlockReference.blockId(in: "2^10 is 1024"))
        XCTAssertEqual(NoteBlockReference.strippingBlockId("text ^abc"), "text")
        XCTAssertEqual(NoteBlockReference.strippingBlockId("no anchor"), "no anchor")
    }

    func testHeadingParsing() {
        XCTAssertEqual(NoteBlockReference.heading(in: "## Title ##")?.text, "Title")
        XCTAssertEqual(NoteBlockReference.heading(in: "# C#")?.text, "C#")
        XCTAssertEqual(NoteBlockReference.heading(in: "### Three")?.level, 3)
        XCTAssertNil(NoteBlockReference.heading(in: "#tag"))
    }
}

/// Fixture notes for the embed tests. A file-scope enum (not statics on the
/// test case) so the `@Sendable` lookup closure never touches the test
/// class's isolation.
private enum EmbedFixtures {
    static let notes: [String: NoteEmbedResolution] = [
        "alpha": NoteEmbedResolution(noteId: "A", title: "Alpha",
                                     body: "# Alpha\n\n## Intro\nHello ^p1\n\n## Nested\n![[Beta]]"),
        "beta": NoteEmbedResolution(noteId: "B", title: "Beta", body: "Beta body ![[Alpha]]"),
    ]

    static func resolve(_ anchor: String) -> NoteEmbedResolution? {
        let candidates = WikiLinkTarget.lookupCandidates(forAnchor: anchor)
        for candidate in candidates {
            if let hit = notes[candidate.lowercased()] { return hit }
        }
        return nil
    }
}

final class NoteEmbedExpanderTests: XCTestCase {

    func testAttachmentEmbedsAreNotNotes() {
        XCTAssertTrue(NoteEmbedExpander.isAttachmentAnchor("photo.PNG"))
        XCTAssertTrue(NoteEmbedExpander.isAttachmentAnchor("scan.pdf#page=2"))
        XCTAssertTrue(NoteEmbedExpander.isAttachmentAnchor("img.jpg|300"))
        XCTAssertFalse(NoteEmbedExpander.isAttachmentAnchor("Release v1.2"))
        XCTAssertFalse(NoteEmbedExpander.isAttachmentAnchor("#Figure.png"))
        XCTAssertFalse(NoteEmbedExpander.isAttachmentAnchor("Alpha"))
        let body = "![[photo.png]] ![[Beta]]"
        XCTAssertEqual(NoteEmbedExpander.embeds(in: body).map(\.anchor), ["Beta"])
        XCTAssertEqual(NoteEmbedExpander.expand(body: body, currentNoteId: "X", resolve: EmbedFixtures.resolve),
                       "![[photo.png]] Beta body [[Alpha]]")
    }

    func testFindsEmbedsOutsideCode() {
        let body = "![[Alpha]] `![[Beta]]`\n```\n![[Gamma]]\n```\n![[Delta#Intro]]"
        XCTAssertEqual(NoteEmbedExpander.embeds(in: body).map(\.anchor), ["Alpha", "Delta#Intro"])
    }

    func testExpandsHeadingAndBlockOneLevel() {
        let expanded = NoteEmbedExpander.expand(body: "Start\n![[Alpha#Intro]]\n![[Alpha#^p1]]\nEnd",
                                                currentNoteId: "X", resolve: EmbedFixtures.resolve)
        XCTAssertEqual(expanded, "Start\n## Intro\nHello\nHello\nEnd")
    }

    func testNestedEmbedsDegradeToLinks() {
        let expanded = NoteEmbedExpander.expand(body: "![[Beta]]", currentNoteId: "X", resolve: EmbedFixtures.resolve)
        XCTAssertEqual(expanded, "Beta body [[Alpha]]")
    }

    func testSelfEmbedAndMissingTargetsStayLinks() {
        let expanded = NoteEmbedExpander.expand(body: "![[Alpha]] ![[Ghost]] ![[Alpha#Missing]]",
                                                currentNoteId: "A", resolve: EmbedFixtures.resolve)
        XCTAssertEqual(expanded, "[[Alpha]] [[Ghost]] [[Alpha#Missing]]")
    }

    func testSameNoteSectionEmbed() {
        let body = "## Part\nText\n\n![[#Part]]"
        let expanded = NoteEmbedExpander.expand(body: body, currentNoteId: "S", resolve: { _ in nil })
        XCTAssertEqual(expanded, "## Part\nText\n\n## Part\nText\n\n[[#Part]]")
    }

    func testAncestryBlocksCycles() {
        let expanded = NoteEmbedExpander.expand(body: "![[Beta]]", currentNoteId: "A", ancestry: ["B"], resolve: EmbedFixtures.resolve)
        XCTAssertEqual(expanded, "[[Beta]]")
    }

    func testTitleWithHashResolvesWhole() {
        let target = NoteEmbedExpander.effectiveTarget(WikiLinkTarget.parse("C# Tips"), anchor: "C# Tips",
                                                       resolvedTitle: "C# Tips")
        XCTAssertFalse(target.hasFragment)
    }

    func testMarkdownExporterExpandsEmbeds() throws {
        let db = try DatabaseManager(path: ":memory:")
        let transcripts = TranscriptStore(databaseManager: db)
        let note = Note(id: "X", title: "Host", body: "Before\n![[Beta]]\nAfter")
        let lookup = NoteEmbedLookup { anchor in EmbedFixtures.resolve(anchor) }
        let markdown = NoteMarkdownExporter.export(note: note, transcriptStore: transcripts, embeds: lookup)
        XCTAssertTrue(markdown.contains("Before\nBeta body [[Alpha]]\nAfter"), markdown)
        let raw = NoteMarkdownExporter.export(note: note, transcriptStore: transcripts, embeds: nil)
        XCTAssertTrue(raw.contains("![[Beta]]"))
    }
}
