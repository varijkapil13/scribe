import XCTest
@testable import Scribe

final class TranslationPlanningTests: XCTestCase {

    func testPlanKeepsStructureAndTranslatesProse() {
        let markdown = """
        ---
        tags: [work]
        ---
        # Weekly sync

        - [ ] Send the deck
        1. First point
        > A quote

        ```swift
        let x = 1
        ```
        ---
        | a | b |
        |---|---|
        12345
        """
        let plan = MarkdownTranslationPlan(markdown: markdown)
        XCTAssertEqual(plan.texts, ["Weekly sync", "Send the deck", "First point", "A quote", "| a | b |"])

        let rendered = plan.render(translations: ["Wöchentlich", "Deck senden", "Erster Punkt", "Ein Zitat", "| a | b |"])
        XCTAssertEqual(rendered, """
        ---
        tags: [work]
        ---
        # Wöchentlich

        - [ ] Deck senden
        1. Erster Punkt
        > Ein Zitat

        ```swift
        let x = 1
        ```
        ---
        | a | b |
        |---|---|
        12345
        """)
    }

    func testRenderFallsBackToOriginalAndFlattensNewlines() {
        let plan = MarkdownTranslationPlan(markdown: "One\nTwo")
        XCTAssertEqual(plan.render(translations: ["Eins\nzwei"]), "Eins zwei\nTwo")
    }

    func testSplitPrefix() {
        XCTAssertEqual(MarkdownTranslationPlan.splitPrefix("  - item").prefix, "  - ")
        XCTAssertEqual(MarkdownTranslationPlan.splitPrefix("  - item").text, "item")
        XCTAssertEqual(MarkdownTranslationPlan.splitPrefix("### Title").prefix, "### ")
        XCTAssertEqual(MarkdownTranslationPlan.splitPrefix("#hashtag start").prefix, "")
        XCTAssertEqual(MarkdownTranslationPlan.splitPrefix("> - [x] done").prefix, "> - [x] ")
        XCTAssertEqual(MarkdownTranslationPlan.splitPrefix("10) tenth").prefix, "10) ")
        XCTAssertEqual(MarkdownTranslationPlan.splitPrefix("2024 was good").prefix, "")
    }

    func testRulesAndTableSeparators() {
        XCTAssertTrue(MarkdownTranslationPlan.isRule("---"))
        XCTAssertTrue(MarkdownTranslationPlan.isRule("* * *"))
        XCTAssertFalse(MarkdownTranslationPlan.isRule("--"))
        XCTAssertFalse(MarkdownTranslationPlan.isRule("-*-"))
        XCTAssertTrue(MarkdownTranslationPlan.isTableSeparator("|---|:---:|"))
        XCTAssertFalse(MarkdownTranslationPlan.isTableSeparator("| a |"))
    }

    func testOutputBuilders() {
        XCTAssertEqual(ScribeTranslationOutput.noteTitle(original: "Sync", languageName: "German"), "Sync (German)")
        XCTAssertEqual(ScribeTranslationOutput.noteTitle(original: "  ", languageName: "German"), "Untitled (German)")

        let body = ScribeTranslationOutput.noteBody(originalTitle: "Sync", languageName: "German", translatedMarkdown: "Hallo\n")
        XCTAssertTrue(body.hasPrefix("> Translated note of [[Sync]] into German"))
        XCTAssertTrue(body.hasSuffix("\n\nHallo\n"))

        let lines = [
            TranscriptTranslationLine(speaker: "Ana", timestamp: "[00:00:01]", text: "Hello"),
            TranscriptTranslationLine(speaker: "", timestamp: "[00:00:05]", text: "Bye")
        ]
        let transcript = ScribeTranslationOutput.transcriptBody(originalTitle: "Sync", sessionTitle: "Call",
                                                          languageName: "French", lines: lines,
                                                          translations: ["Bonjour"])
        XCTAssertTrue(transcript.contains("## Call (French)"))
        XCTAssertTrue(transcript.contains("**Ana** [00:00:01]: Bonjour"))
        XCTAssertTrue(transcript.contains("\n\n[00:00:05]: Bye"))
        XCTAssertTrue(transcript.contains("transcript of [[Sync]]"))
    }

    func testBatches() {
        XCTAssertEqual(ScribeTranslationOutput.batches([1, 2, 3, 4, 5], size: 2), [[1, 2], [3, 4], [5]])
        XCTAssertEqual(ScribeTranslationOutput.batches([Int](), size: 2), [])
        XCTAssertEqual(ScribeTranslationOutput.batches([1, 2], size: 0), [[1, 2]])
    }
}
