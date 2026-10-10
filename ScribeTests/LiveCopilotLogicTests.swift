import XCTest
@testable import Scribe

/// Live meeting copilot: chunk scheduling, the incremental prompt and its
/// budget, parsing the model's reply, the heuristic fallback, and "Ask now"
/// context selection.
final class LiveCopilotLogicTests: XCTestCase {

    private func line(_ id: Int64, _ startMs: Int, _ speaker: String, _ text: String) -> LiveCopilotLine {
        LiveCopilotLine(id: id, startMs: startMs, endMs: startMs + 5_000, speaker: speaker, text: text)
    }

    // MARK: - Lines

    func testPromptLineFormat() {
        XCTAssertEqual(line(1, 65_000, "Priya", "We  ship\non the 14th.").promptLine,
                       "[00:01:05] Priya: We ship on the 14th.")
        XCTAssertEqual(line(1, 0, " ", "Hello").promptLine, "[00:00:00] Hello")
    }

    // MARK: - Scheduling

    func testPendingLinesAfterLastProcessedId() {
        let lines = [line(3, 0, "a", "three"), line(1, 0, "a", "one"), line(2, 0, "a", "  "), line(4, 0, "a", "four")]
        XCTAssertEqual(LiveCopilotScheduler.pendingLines(lines, afterId: 1).map(\.id), [3, 4])
        XCTAssertEqual(LiveCopilotScheduler.pendingCharacters([line(1, 0, "a", "abc"), line(2, 0, "a", "de")]), 5)
    }

    func testShouldUpdate() {
        func check(elapsed: Int, last: Int?, pending: Int, force: Bool = false) -> Bool {
            LiveCopilotScheduler.shouldUpdate(
                elapsedMs: elapsed, lastUpdateElapsedMs: last, pendingCharacters: pending,
                intervalMs: 120_000, force: force
            )
        }
        // Nothing new → never, even forced.
        XCTAssertFalse(check(elapsed: 500_000, last: nil, pending: 0, force: true))
        // Forced → any new text.
        XCTAssertTrue(check(elapsed: 1_000, last: nil, pending: 10, force: true))
        // Too little text.
        XCTAssertFalse(check(elapsed: 500_000, last: nil, pending: 100))
        // First update waits for the interval.
        XCTAssertFalse(check(elapsed: 60_000, last: nil, pending: 500))
        XCTAssertTrue(check(elapsed: 130_000, last: nil, pending: 500))
        // Then every interval after the last update.
        XCTAssertFalse(check(elapsed: 200_000, last: 100_000, pending: 500))
        XCTAssertTrue(check(elapsed: 221_000, last: 100_000, pending: 500))
        // A full chunk of backlog runs early.
        XCTAssertTrue(check(elapsed: 10_000, last: nil, pending: LiveCopilotPromptBuilder.chunkBudget))
    }

    func testBatchesRespectBudgetAndChunkLimit() {
        let text = String(repeating: "x", count: 100)
        let lines = (1...5).map { line(Int64($0), 0, "A", text) }
        // "[00:00:00] A: " + 100 chars = 114 → two lines per 250-char chunk.
        XCTAssertEqual(lines[0].promptLine.count, 114)
        let batches = LiveCopilotScheduler.batches(lines, chunkBudget: 250, maxChunks: 2)
        XCTAssertEqual(batches.map { $0.map(\.id) }, [[1, 2], [3, 4]])

        let all = LiveCopilotScheduler.batches(lines, chunkBudget: 250, maxChunks: 5)
        XCTAssertEqual(all.map { $0.map(\.id) }, [[1, 2], [3, 4], [5]])
        for batch in all {
            let size = batch.map(\.promptLine).joined(separator: "\n").count
            XCTAssertLessThanOrEqual(size, 250)
        }

        // An oversized single line still gets its own chunk.
        let huge = [line(9, 0, "A", String(repeating: "y", count: 1_000))]
        XCTAssertEqual(LiveCopilotScheduler.batches(huge, chunkBudget: 250).map { $0.map(\.id) }, [[9]])
        XCTAssertEqual(LiveCopilotScheduler.batches([], chunkBudget: 250).count, 0)
    }

    // MARK: - Prompt

    func testPromptCarriesPreviousStateAndNewChunk() {
        let previous = LiveCopilotState(
            summary: "Earlier we agreed on the budget.",
            actionItems: ["Ben: book the venue"],
            openQuestions: []
        )
        let prompt = LiveCopilotPromptBuilder.prompt(
            title: "Launch sync",
            previous: previous,
            chunk: [line(1, 0, "Priya", "We ship on the 14th."), line(2, 6_000, "Ben", "Agreed.")],
            highlightedMs: [3_000, 900_000]
        )
        XCTAssertTrue(prompt.contains("MEETING: Launch sync"))
        XCTAssertTrue(prompt.contains("NOTES SO FAR:\nEarlier we agreed on the budget."))
        XCTAssertTrue(prompt.contains("ACTION ITEMS SO FAR:\n- Ben: book the venue"))
        XCTAssertTrue(prompt.contains("OPEN QUESTIONS SO FAR:\n- None"))
        XCTAssertTrue(prompt.contains("NEW TRANSCRIPT:\n[00:00:00] Priya: We ship on the 14th.\n[00:00:06] Ben: Agreed."))
        XCTAssertTrue(prompt.contains("marked these moments as important: [00:00:03]."))
        XCTAssertFalse(prompt.contains("[00:15:00]"), "Bookmarks outside the chunk are left out")
        XCTAssertTrue(prompt.contains("SUMMARY:"))
    }

    func testPromptStaysWithinBudget() {
        let previous = LiveCopilotState(
            summary: String(repeating: "Long summary. ", count: 2_000),
            actionItems: (0..<30).map { "Item \($0) " + String(repeating: "z", count: 400) },
            openQuestions: (0..<30).map { "Question \($0)?" }
        )
        let chunk = (0..<200).map { line(Int64($0), $0 * 1_000, "Speaker", String(repeating: "word ", count: 40)) }
        let prompt = LiveCopilotPromptBuilder.prompt(title: "T", previous: previous, chunk: chunk)
        let lists = 2 * LiveCopilotPromptBuilder.listLimit * (LiveCopilotPromptBuilder.listItemBudget + 4)
        let ceiling = LiveCopilotPromptBuilder.chunkBudget + LiveCopilotPromptBuilder.previousSummaryBudget + lists + 1_000
        XCTAssertLessThanOrEqual(prompt.count, ceiling)
        XCTAssertTrue(prompt.contains("Item 29"), "The most recent items are carried")
        XCTAssertFalse(prompt.contains("Item 0 "), "Old items beyond the limit are dropped")
    }

    func testFirstPromptSaysNothingYet() {
        let prompt = LiveCopilotPromptBuilder.prompt(title: "", previous: .empty, chunk: [line(1, 0, "A", "Hi")])
        XCTAssertTrue(prompt.contains("MEETING: Untitled meeting"))
        XCTAssertTrue(prompt.contains("(nothing yet"))
    }

    // MARK: - Parsing

    func testParseStandardReply() throws {
        let reply = """
        SUMMARY:
        The team reviewed the launch plan.
        Dates are tight.
        ACTION ITEMS:
        - Priya: send the deck
        - None
        OPEN QUESTIONS:
        1. Who owns QA?
        2) When is code freeze?
        """
        let state = try XCTUnwrap(LiveCopilotPromptBuilder.parse(reply, previous: .empty))
        XCTAssertEqual(state.summary, "The team reviewed the launch plan. Dates are tight.")
        XCTAssertEqual(state.actionItems, ["Priya: send the deck"])
        XCTAssertEqual(state.openQuestions, ["Who owns QA?", "When is code freeze?"])
    }

    func testParseMarkdownHeadings() throws {
        let previous = LiveCopilotState(summary: "Old", actionItems: ["old item"], openQuestions: ["old question?"])
        let reply = """
        **Summary:** Budget approved.
        ## Action items
        * Ben to book the venue
        * **Ana** to draft the agenda
        **Open questions:**
        - None
        """
        let state = try XCTUnwrap(LiveCopilotPromptBuilder.parse(reply, previous: previous))
        XCTAssertEqual(state.summary, "Budget approved.")
        XCTAssertEqual(state.actionItems, ["Ben to book the venue", "Ana to draft the agenda"])
        XCTAssertEqual(state.openQuestions, [], "An explicit empty section clears the list")
    }

    func testParseFallbacks() throws {
        let previous = LiveCopilotState(summary: "Old", actionItems: ["a"], openQuestions: ["q?"])
        XCTAssertNil(LiveCopilotPromptBuilder.parse("  \n ", previous: previous))

        let prose = try XCTUnwrap(LiveCopilotPromptBuilder.parse("Just prose.", previous: previous))
        XCTAssertEqual(prose, LiveCopilotState(summary: "Just prose.", actionItems: ["a"], openQuestions: ["q?"]))

        let onlyActions = try XCTUnwrap(LiveCopilotPromptBuilder.parse("ACTION ITEMS:\n- new\n- NEW", previous: previous))
        XCTAssertEqual(onlyActions.summary, "Old", "Missing sections keep the previous value")
        XCTAssertEqual(onlyActions.actionItems, ["new"], "Duplicates are dropped case-insensitively")
        XCTAssertEqual(onlyActions.openQuestions, ["q?"])
    }

    func testListItem() {
        XCTAssertEqual(LiveCopilotPromptBuilder.listItem("- Do it"), "Do it")
        XCTAssertEqual(LiveCopilotPromptBuilder.listItem("• Do it"), "Do it")
        XCTAssertEqual(LiveCopilotPromptBuilder.listItem("12. Do it"), "Do it")
        XCTAssertEqual(LiveCopilotPromptBuilder.listItem("Q3. budget"), "Q3. budget")
        XCTAssertNil(LiveCopilotPromptBuilder.listItem("- None."))
        XCTAssertNil(LiveCopilotPromptBuilder.listItem("- n/a"))
        XCTAssertNil(LiveCopilotPromptBuilder.listItem("-"))
    }

    // MARK: - Heuristic fallback

    func testHeuristicsFindCommitmentsAndQuestions() {
        let lines = [
            line(1, 0, "Priya", "I'll send the deck by Friday. What is the budget for the launch? Okay."),
            line(2, 5_000, "Ben", "Right? Sounds good."),
            line(3, 9_000, "Ben", "Could you share the QA plan with everyone?"),
        ]
        let state = LiveCopilotHeuristics.update(previous: .empty, lines: lines)
        XCTAssertEqual(state.summary, "")
        XCTAssertEqual(state.actionItems, [
            "Priya: I'll send the deck by Friday.",
            "Ben: Could you share the QA plan with everyone?",
        ])
        XCTAssertEqual(state.openQuestions, ["Priya: What is the budget for the launch?"])

        // Re-running on the same lines doesn't duplicate.
        let again = LiveCopilotHeuristics.update(previous: state, lines: [lines[0]])
        XCTAssertEqual(again.actionItems.count, 2)
    }

    func testHeuristicListsAreCapped() {
        let lines = (0..<20).map { line(Int64($0), $0 * 1_000, "A", "We will ship feature number \($0) soon.") }
        let state = LiveCopilotHeuristics.update(previous: .empty, lines: lines)
        XCTAssertEqual(state.actionItems.count, LiveCopilotPromptBuilder.listLimit)
        XCTAssertEqual(state.actionItems.last, "A: We will ship feature number 19 soon.")
    }

    // MARK: - Ask now

    private var meetingLines: [LiveCopilotLine] {
        [
            line(1, 0, "You", "Let's talk about the roadmap."),
            line(2, 10_000, "Priya", "The deadline is March 3rd for the beta."),
            line(3, 20_000, "Ben", "Sounds good."),
            line(4, 30_000, "Priya", "Deadline might slip if QA is late."),
        ]
    }

    func testAskSelectsMatchingLinesInOrder() {
        let context = LiveCopilotAskBuilder.selectContext(
            question: "What did Priya say about the deadline?", lines: meetingLines
        )
        XCTAssertEqual(context.map(\.id), [2, 4])
    }

    func testAskRespectsBudgetPreferringLatest() {
        let latest = meetingLines[3].promptLine.count
        let context = LiveCopilotAskBuilder.selectContext(
            question: "What did Priya say about the deadline?", lines: meetingLines, budget: latest + 2
        )
        XCTAssertEqual(context.map(\.id), [4])
    }

    func testAskFallsBackToRecentTranscript() {
        let context = LiveCopilotAskBuilder.selectContext(question: "Any zebras?", lines: meetingLines)
        XCTAssertEqual(context.map(\.id), [1, 2, 3, 4])
        let tight = LiveCopilotAskBuilder.selectContext(
            question: "Any zebras?", lines: meetingLines, budget: meetingLines[3].promptLine.count
        )
        XCTAssertEqual(tight.map(\.id), [4])
        XCTAssertEqual(LiveCopilotAskBuilder.selectContext(question: "x", lines: []).count, 0)
    }

    func testAskPromptAndFallbackAnswer() {
        let prompt = LiveCopilotAskBuilder.prompt(
            question: " When is the beta? ", context: [meetingLines[1]], liveSummary: "Roadmap review."
        )
        XCTAssertTrue(prompt.contains("LIVE NOTES SO FAR:\nRoadmap review."))
        XCTAssertTrue(prompt.contains("TRANSCRIPT EXCERPTS:\n[00:00:10] Priya: The deadline is March 3rd for the beta."))
        XCTAssertTrue(prompt.hasSuffix("QUESTION: When is the beta?"))
        XCTAssertFalse(LiveCopilotAskBuilder.prompt(question: "q", context: [], liveSummary: "").contains("LIVE NOTES"))

        let answer = LiveCopilotAskBuilder.fallbackAnswer(question: "deadline?", lines: meetingLines)
        XCTAssertTrue(answer.hasPrefix("Most relevant moments so far:"))
        XCTAssertTrue(answer.contains("- 0:10 Priya: The deadline is March 3rd for the beta."))
        XCTAssertTrue(answer.contains("- 0:30 Priya: Deadline might slip if QA is late."))
        XCTAssertEqual(
            LiveCopilotAskBuilder.fallbackAnswer(question: "zebras?", lines: meetingLines),
            "Nothing in the transcript so far matches that question."
        )
    }
}
