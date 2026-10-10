// ScribeTests/WikiLinkNavigationPlanTests.swift
import XCTest
@testable import Scribe

final class WikiLinkNavigationPlanTests: XCTestCase {

    private let otherBody = "# Other\n\nIntro\n\n## Details\n\nA paragraph ^blk1\n"
    private let currentBody = "# Current\n\n## Section\n\ntext ^here\n"

    private func plan(_ anchor: String) -> WikiLinkNavigationPlan {
        WikiLinkNavigationPlan.plan(
            anchor: anchor,
            currentNoteId: "cur",
            currentBody: currentBody,
            resolve: { anchor in
                let title = WikiLinkTarget.parse(anchor).title.lowercased()
                switch title {
                case "other": return (id: "other", title: "Other")
                case "current": return (id: "cur", title: "Current")
                default: return nil
                }
            },
            bodyOf: { $0 == "other" ? self.otherBody : nil }
        )
    }

    func testOpensAnotherNote() {
        XCTAssertEqual(plan("Other"), .open(noteId: "other", line: nil))
        XCTAssertEqual(plan("Other|alias"), .open(noteId: "other", line: nil))
    }

    func testOpensAnotherNoteAtHeadingOrBlock() {
        XCTAssertEqual(plan("Other#Details"), .open(noteId: "other", line: 5))
        XCTAssertEqual(plan("Other#^blk1"), .open(noteId: "other", line: 7))
        // A missing heading still opens the note.
        XCTAssertEqual(plan("Other#Nope"), .open(noteId: "other", line: nil))
    }

    func testSameNoteLinksScroll() {
        XCTAssertEqual(plan("#Section"), .scrollCurrent(line: 3))
        XCTAssertEqual(plan("#^here"), .scrollCurrent(line: 5))
        XCTAssertEqual(plan("Current#Section"), .scrollCurrent(line: 3))
        XCTAssertEqual(plan("#Missing"), .none)
        XCTAssertEqual(plan("Current"), .none)
    }

    func testUnknownNoteIsMissing() {
        XCTAssertEqual(plan("Brand New|shown"), .missing(title: "Brand New"))
    }
}
