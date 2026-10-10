// ScribeTests/UnlinkedMentionMatcherTests.swift
import XCTest
@testable import Scribe

final class UnlinkedMentionMatcherTests: XCTestCase {

    private func texts(_ terms: [String], _ body: String) -> [String] {
        UnlinkedMentionMatcher.mentions(of: terms, in: body).map(\.matchedText)
    }

    func testFindsCaseInsensitiveWholeWordMentions() {
        let body = "Talked about project plan today. The Project Plan is late."
        XCTAssertEqual(texts(["Project Plan"], body), ["project plan", "Project Plan"])
    }

    func testRespectsWordBoundaries() {
        let body = "Planning, planner, plan_b, replan, Plan."
        XCTAssertEqual(texts(["Plan"], body), ["Plan"])
    }

    func testSkipsExistingLinksAndEmbeds() {
        let body = "See [[Alpha]] and [[Alpha|the alpha]] and ![[Alpha]] but also Alpha."
        let mentions = UnlinkedMentionMatcher.mentions(of: ["Alpha"], in: body)
        XCTAssertEqual(mentions.count, 1)
        XCTAssertEqual(mentions.first?.location, (body as NSString).range(of: "also Alpha").location + 5)
    }

    func testSkipsCodeBlocksAndInlineCode() {
        let body = """
        Alpha in prose.
        ```
        Alpha in a fence
        ```
        and `Alpha` inline, ~~~ not a fence ~~~ Alpha
        """
        XCTAssertEqual(texts(["Alpha"], body).count, 2)
        let lines = UnlinkedMentionMatcher.mentions(of: ["Alpha"], in: body).map(\.line)
        XCTAssertEqual(lines, [1, 5])
    }

    func testSkipsMarkdownLinksUrlsTagsAndComments() {
        let body = "[Alpha](https://x.y) https://alpha.example/Alpha #alpha @alpha <!-- Alpha --> Alpha!"
        let mentions = UnlinkedMentionMatcher.mentions(of: ["Alpha"], in: body)
        XCTAssertEqual(mentions.map(\.matchedText), ["Alpha"])
        XCTAssertEqual(mentions.first?.location, (body as NSString).length - 6)
    }

    func testLongerTermWinsOverlap() {
        let body = "The Project Plan v2 replaces the Project Plan."
        let mentions = UnlinkedMentionMatcher.mentions(of: ["Project Plan", "Project Plan v2"], in: body)
        XCTAssertEqual(mentions.map(\.term), ["Project Plan v2", "Project Plan"])
    }

    func testTermsDedupeAndDropShortOnes() {
        XCTAssertEqual(UnlinkedMentionMatcher.terms(title: "Alpha", aliases: ["alpha", "A", "Alpha Team", " "]),
                       ["Alpha Team", "Alpha"])
    }

    func testParseAliases() {
        XCTAssertEqual(UnlinkedMentionMatcher.parseAliases("[Alpha, Beta]"), ["Alpha", "Beta"])
        XCTAssertEqual(UnlinkedMentionMatcher.parseAliases(#"["Acme, Inc", 'Bee']"#), ["Acme, Inc", "Bee"])
        XCTAssertEqual(UnlinkedMentionMatcher.parseAliases("Solo"), ["Solo"])
        XCTAssertEqual(UnlinkedMentionMatcher.parseAliases("[]"), [])
        XCTAssertEqual(UnlinkedMentionMatcher.parseAliases(nil), [])
    }

    func testContextAndLine() {
        let body = "first line\n  second mentions Alpha here  \nthird"
        let mention = UnlinkedMentionMatcher.mentions(of: ["Alpha"], in: body).first
        XCTAssertEqual(mention?.line, 2)
        XCTAssertEqual(mention?.context, "second mentions Alpha here")
    }

    // MARK: - Linking

    func testLinkingExactTitle() throws {
        let body = "Met about Alpha today."
        let mention = try XCTUnwrap(UnlinkedMentionMatcher.mentions(of: ["Alpha"], in: body).first)
        XCTAssertEqual(UnlinkedMentionMatcher.linking(mention, in: body, title: "Alpha"),
                       "Met about [[Alpha]] today.")
    }

    func testLinkingDifferentCaseOrAliasKeepsProse() throws {
        let body = "the alpha team met"
        let mention = try XCTUnwrap(UnlinkedMentionMatcher.mentions(of: ["Alpha"], in: body).first)
        XCTAssertEqual(UnlinkedMentionMatcher.linking(mention, in: body, title: "Alpha"),
                       "the [[Alpha|alpha]] team met")
    }

    func testLinkingRefusesStaleMention() throws {
        let body = "Alpha here"
        let mention = try XCTUnwrap(UnlinkedMentionMatcher.mentions(of: ["Alpha"], in: body).first)
        XCTAssertNil(UnlinkedMentionMatcher.linking(mention, in: "Beta here", title: "Alpha"))
        XCTAssertNil(UnlinkedMentionMatcher.linking(mention, in: "[[Alpha]] here", title: "Alpha"))
        XCTAssertNil(UnlinkedMentionMatcher.linking(mention, in: "", title: "Alpha"))
    }

    func testRelocateFindsMentionAfterEdit() throws {
        let body = "Alpha one"
        let mention = try XCTUnwrap(UnlinkedMentionMatcher.mentions(of: ["Alpha"], in: body).first)
        let moved = UnlinkedMentionsModel.relocate(mention, in: "Prefix. Alpha one")
        XCTAssertEqual(moved?.location, 8)
    }

    func testMentionMatchExpression() {
        XCTAssertEqual(NoteStore.mentionMatchExpression(terms: ["Project Plan", "Q3-review", "!!"]),
                       #""Project Plan" OR "Q3 review""#)
        XCTAssertEqual(NoteStore.mentionMatchExpression(terms: []), "")
    }
}
