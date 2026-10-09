// ScribeTests/MeetingRetrievalTests.swift
import XCTest
@testable import Scribe

/// Pure retrieval logic behind "Ask Scribe": term extraction, ranking,
/// the context budget, scope filtering and citation parsing.
final class MeetingRetrievalTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snippet(_ id: String,
                         _ text: String,
                         kind: RetrievedSnippet.Kind = .transcript,
                         session: String? = nil,
                         noteId: String? = nil,
                         title: String = "Meeting",
                         notebookId: String? = nil,
                         daysAgo: Double = 0) -> RetrievedSnippet {
        RetrievedSnippet(
            id: id,
            kind: kind,
            sessionId: session ?? id,
            noteId: noteId,
            noteTitle: title,
            sessionTitle: title,
            notebookId: notebookId,
            date: now.addingTimeInterval(-daysAgo * 86_400),
            speaker: kind == .transcript ? "Alice" : nil,
            text: text
        )
    }

    // MARK: - Terms

    func testExtractTermsDropsStopWordsAndDuplicates() {
        let terms = MeetingRetrieval.extractTerms(from: "What did we decide about the launch date? The LAUNCH!")
        XCTAssertEqual(terms, ["decide", "launch", "date"])
    }

    func testExtractTermsKeepsShortAlphanumerics() {
        XCTAssertEqual(MeetingRetrieval.extractTerms(from: "Q3 budget for EU"), ["q3", "budget"])
    }

    func testExtractTermsCapsCount() {
        let terms = MeetingRetrieval.extractTerms(
            from: "alpha bravo charlie delta echo foxtrot golf hotel india juliet", maxTerms: 4)
        XCTAssertEqual(terms, ["alpha", "bravo", "charlie", "delta"])
    }

    func testFtsOrQueryQuotesAndPrefixesTerms() {
        XCTAssertEqual(MeetingRetrieval.ftsOrQuery(terms: ["launch", "q3"]), "\"launch\"* OR \"q3\"*")
        XCTAssertEqual(MeetingRetrieval.ftsOrQuery(terms: []), "")
    }

    // MARK: - Ranking

    func testRankPrefersSnippetsCoveringMoreTerms() {
        let candidates = [
            snippet("a", "We talked about the launch."),
            snippet("b", "The launch date moved to March."),
            snippet("c", "Lunch options were discussed.")
        ]
        let ranked = MeetingRetrieval.rank(candidates, terms: ["launch", "date"], now: now)
        XCTAssertEqual(ranked.map(\.id), ["b", "a", "c"])
        XCTAssertGreaterThan(ranked[0].score, ranked[1].score)
    }

    func testRankBreaksEqualRelevanceByRecency() {
        let candidates = [
            snippet("old", "Budget review", daysAgo: 90),
            snippet("new", "Budget review", daysAgo: 1)
        ]
        let ranked = MeetingRetrieval.rank(candidates, terms: ["budget"], now: now)
        XCTAssertEqual(ranked.map(\.id), ["new", "old"])
    }

    func testRankBoostsSummariesOverTranscriptLines() {
        let candidates = [
            snippet("t", "Hiring plan agreed", kind: .transcript),
            snippet("s", "Hiring plan agreed", kind: .summary)
        ]
        let ranked = MeetingRetrieval.rank(candidates, terms: ["hiring"], now: now)
        XCTAssertEqual(ranked.first?.id, "s")
    }

    func testRankMatchesTermsAsPrefixes() {
        let candidates = [
            snippet("a", "Nothing relevant here"),
            snippet("b", "Deployments are blocked")
        ]
        let ranked = MeetingRetrieval.rank(candidates, terms: ["deploy"], now: now)
        XCTAssertEqual(ranked.first?.id, "b")
    }

    // MARK: - Budget

    func testBudgetIsNeverExceeded() {
        let long = String(repeating: "launch plan details ", count: 60)
        let candidates = (0..<40).map { snippet("s\($0)", long, session: "session-\($0)") }
        let ranked = MeetingRetrieval.rank(candidates, terms: ["launch"], now: now)
        for budget in [600, 900, 2_500, 6_000] {
            let result = MeetingRetrieval.applyBudget(ranked, terms: ["launch"], budget: budget)
            let context = MeetingRetrieval.formatContext(result.snippets)
            XCTAssertLessThanOrEqual(context.count, budget, "budget \(budget)")
            XCTAssertTrue(result.truncated)
            XCTAssertFalse(result.snippets.isEmpty, "budget \(budget) should fit at least one snippet")
        }
    }

    func testBudgetTrimsEachSnippet() {
        let long = String(repeating: "x", count: 2_000) + " launch " + String(repeating: "y", count: 2_000)
        let result = MeetingRetrieval.applyBudget([snippet("a", long)], terms: ["launch"],
                                                  budget: 10_000, maxSnippetChars: 300)
        XCTAssertEqual(result.snippets.count, 1)
        let text = result.snippets[0].text
        XCTAssertLessThanOrEqual(text.count, 302)  // + two ellipses
        XCTAssertTrue(text.contains("launch"), "excerpt should be centred on the match")
        XCTAssertFalse(result.truncated)
    }

    func testBudgetCapsSnippetsPerSource() {
        let candidates = (0..<6).map { snippet("seg\($0)", "launch item \($0)", session: "same") }
            + [snippet("other", "launch elsewhere", session: "different")]
        let result = MeetingRetrieval.applyBudget(candidates, terms: ["launch"], maxPerSource: 2)
        XCTAssertEqual(result.snippets.filter { $0.sessionId == "same" }.count, 2)
        XCTAssertTrue(result.snippets.contains { $0.id == "other" })
        XCTAssertTrue(result.truncated)
    }

    func testContextUsesWikiLinkCitations() {
        let s = snippet("a", "Launch moved", title: "Weekly Sync")
        let context = MeetingRetrieval.formatContext([s])
        XCTAssertTrue(context.hasPrefix("[1] [[Weekly Sync]] ("), context)
        XCTAssertTrue(context.contains("Alice"))
        XCTAssertTrue(context.hasSuffix(": Launch moved"))
    }

    // MARK: - Scope

    func testScopeFilterBySinceNotebookAndNotes() {
        let candidates = [
            snippet("recent-in", "launch", noteId: "n1", notebookId: "nb1", daysAgo: 2),
            snippet("old-in", "launch", noteId: "n1", notebookId: "nb1", daysAgo: 40),
            snippet("recent-out", "launch", noteId: "n2", notebookId: "nb2", daysAgo: 2)
        ]
        let since = now.addingTimeInterval(-7 * 86_400)
        let byDate = MeetingRetrieval.assemble(candidates: candidates, terms: ["launch"],
                                               filter: AskScopeFilter(since: since), now: now)
        XCTAssertEqual(Set(byDate.snippets.map(\.id)), ["recent-in", "recent-out"])

        let byNotebook = MeetingRetrieval.assemble(candidates: candidates, terms: ["launch"],
                                                   filter: AskScopeFilter(notebookIds: ["nb1"]), now: now)
        XCTAssertEqual(Set(byNotebook.snippets.map(\.id)), ["recent-in", "old-in"])

        let byNote = MeetingRetrieval.assemble(candidates: candidates, terms: ["launch"],
                                               filter: AskScopeFilter(noteIds: ["n2"]), now: now)
        XCTAssertEqual(byNote.snippets.map(\.id), ["recent-out"])
    }

    func testDescendantNotebooks() {
        let pairs: [(String, String?)] = [("root", nil), ("child", "root"), ("grand", "child"), ("other", nil)]
        XCTAssertEqual(MeetingRetriever.descendants(of: "root", pairs: pairs), ["root", "child", "grand"])
    }

    // MARK: - Citations & prompt

    func testCitationPartsSplitTextAndLinks() {
        let parts = MeetingRetrieval.citationParts(in: "Launch moved [[Weekly Sync]] and [[Plan|the plan]].")
        XCTAssertEqual(parts, [
            .text("Launch moved "),
            .citation("Weekly Sync", "Weekly Sync"),
            .text(" and "),
            .citation("Plan", "the plan"),
            .text(".")
        ])
        XCTAssertEqual(MeetingRetrieval.citations(in: "[[A]] x [[a]] [[B]]"), ["A", "B"])
    }

    func testCitationPartsToleratesUnclosedBrackets() {
        let parts = MeetingRetrieval.citationParts(in: "Oops [[unclosed")
        XCTAssertEqual(parts, [.text("Oops [[unclosed")])
    }

    func testPromptContainsContextQuestionAndScope() {
        let prompt = MeetingRetrieval.buildPrompt(question: "When is launch?",
                                                  context: "[1] [[Sync]] (2026-10-01, summary): Launch is in March",
                                                  scopeLabel: AskScope.lastDays(7).label)
        XCTAssertTrue(prompt.contains("QUESTION: When is launch?"))
        XCTAssertTrue(prompt.contains("[[Sync]]"))
        XCTAssertTrue(prompt.contains("Last 7 days"))
    }

    func testFallbackAnswerCitesSources() {
        let answer = MeetingRetrieval.fallbackAnswer(snippets: [snippet("a", "Launch moved", title: "Sync")])
        XCTAssertTrue(answer.contains("[[Sync]]"))
        XCTAssertTrue(MeetingRetrieval.fallbackAnswer(snippets: []).contains("couldn't find"))
    }

    func testCitationDestinationPrefersSnippetNoteThenSession() {
        let withNote = snippet("a", "x", session: "s1", noteId: "n1", title: "Sync")
        XCTAssertEqual(AskViewModel.destination(forCitation: "sync", snippets: [withNote]), .note("n1"))
        let sessionOnly = snippet("b", "x", session: "s2", noteId: nil, title: "Standup")
        XCTAssertEqual(AskViewModel.destination(forCitation: "Standup", snippets: [sessionOnly]), .session("s2"))
        XCTAssertNil(AskViewModel.destination(forCitation: "Missing", snippets: [withNote]))
    }

    func testCitationLinkRoundTrip() throws {
        let id = UUID()
        let url = try XCTUnwrap(AskCitationLink.url(forTitle: "Q3 Plan & Budget", messageId: id))
        XCTAssertEqual(AskCitationLink.title(from: url), "Q3 Plan & Budget")
        XCTAssertEqual(AskCitationLink.messageId(from: url), id)
        XCTAssertNil(AskCitationLink.title(from: URL(string: "https://example.com")!))
    }
}
