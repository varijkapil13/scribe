// ScribeTests/WikiLinkResolverTests.swift
import XCTest
@testable import Scribe

final class WikiLinkResolverTests: XCTestCase {

    func testAllResolvedReturnsEmpty() {
        let unresolved = WikiLinkResolver.unresolvedAnchors(
            existingTitles: ["Alpha", "Beta"],
            body: "See [[Alpha]] and [[Beta]] for details."
        )
        XCTAssertTrue(unresolved.isEmpty)
    }

    func testUnknownAnchorIsReturned() {
        let unresolved = WikiLinkResolver.unresolvedAnchors(
            existingTitles: ["Alpha"],
            body: "Links to [[Alpha]] and [[Ghost]]."
        )
        XCTAssertEqual(unresolved, ["Ghost"])
    }

    func testMatchIsCaseInsensitive() {
        let unresolved = WikiLinkResolver.unresolvedAnchors(
            existingTitles: ["Swift Tips"],
            body: "Check [[swift tips]] please."
        )
        XCTAssertTrue(unresolved.isEmpty)
    }

    func testAliasFormResolvesOnTitleBeforePipe() {
        // [[Title|alias]] resolves when the title (before `|`) exists.
        let resolved = WikiLinkResolver.unresolvedAnchors(
            existingTitles: ["Project Plan"],
            body: "See [[Project Plan|the plan]]."
        )
        XCTAssertTrue(resolved.isEmpty)

        // ...and is reported broken (full anchor preserved) when it does not.
        let broken = WikiLinkResolver.unresolvedAnchors(
            existingTitles: ["Project Plan"],
            body: "See [[Missing Note|nickname]]."
        )
        XCTAssertEqual(broken, ["Missing Note|nickname"])
    }

    func testNoLinksReturnsEmpty() {
        let unresolved = WikiLinkResolver.unresolvedAnchors(
            existingTitles: ["Alpha"],
            body: "Just plain prose with no links at all."
        )
        XCTAssertTrue(unresolved.isEmpty)
    }

    func testDuplicateUnresolvedAnchorReportedOnce() {
        let unresolved = WikiLinkResolver.unresolvedAnchors(
            existingTitles: [],
            body: "[[Ghost]] then again [[ghost]]."
        )
        XCTAssertEqual(unresolved, ["Ghost"])
    }

    func testEmptyBodyReturnsEmpty() {
        XCTAssertTrue(
            WikiLinkResolver.unresolvedAnchors(existingTitles: ["Alpha"], body: "").isEmpty
        )
    }
}
