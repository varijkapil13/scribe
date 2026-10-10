// ScribeTests/SummaryTemplateTests.swift
import XCTest
import GRDB
@testable import Scribe

/// Pure logic behind summary templates, recipes, note summary blocks,
/// "Enhance notes" prompt helpers and transcript budgeting. Nothing here
/// needs Apple Intelligence.
final class SummaryTemplateParsingTests: XCTestCase {

    func testParsesFrontmatterAndBody() {
        let raw = """
        ---
        name: 1:1
        description: "Weekly one-on-one"
        match: 1:1, One on One ,1on1
        ---

        Be brief.

        ## Highlights
        ### Blockers
        """
        let t = SummaryTemplate.parse(raw, id: "one-on-one")
        XCTAssertEqual(t.id, "one-on-one")
        XCTAssertEqual(t.name, "1:1")
        XCTAssertEqual(t.description, "Weekly one-on-one")
        XCTAssertEqual(t.matchKeywords, ["1:1", "one on one", "1on1"])
        XCTAssertEqual(t.body, "Be brief.\n\n## Highlights\n### Blockers")
        XCTAssertEqual(t.sectionHeadings, ["Highlights", "Blockers"])
    }

    func testParsesInlineAndBlockLists() {
        let inline = TemplateFileParser.parse("---\nmatch: [standup, 'daily sync']\n---\nbody")
        XCTAssertEqual(inline.fields["match"], "standup, daily sync")

        let block = TemplateFileParser.parse("---\nmatch:\n  - sales\n  - demo\nname: Sales\n---\nbody")
        XCTAssertEqual(block.fields["match"], "sales, demo")
        XCTAssertEqual(block.fields["name"], "Sales")
        XCTAssertEqual(block.body, "body")
    }

    func testMissingFrontmatterFallsBackToIdAndWholeBody() {
        let t = SummaryTemplate.parse("## Notes\n- one", id: "plain")
        XCTAssertEqual(t.name, "plain")
        XCTAssertEqual(t.description, "")
        XCTAssertTrue(t.matchKeywords.isEmpty)
        XCTAssertEqual(t.body, "## Notes\n- one")
    }

    func testCRLFAndUnclosedFrontmatter() {
        let crlf = SummaryTemplate.parse("---\r\nname: Win\r\n---\r\nBody\r\n", id: "x")
        XCTAssertEqual(crlf.name, "Win")
        XCTAssertEqual(crlf.body, "Body")

        // No closing fence → treated as body, not frontmatter.
        let unclosed = TemplateFileParser.parse("---\nname: Oops\nbody")
        XCTAssertTrue(unclosed.fields.isEmpty)
        XCTAssertTrue(unclosed.body.contains("name: Oops"))
    }

    func testTemplateRoundTrip() {
        for template in BuiltInTemplates.summaries {
            let reparsed = SummaryTemplate.parse(template.serialized(), id: template.id)
            XCTAssertEqual(reparsed, template, "round-trip failed for \(template.id)")
        }
    }

    func testRecipeRoundTrip() {
        for recipe in BuiltInTemplates.recipes {
            XCTAssertEqual(NoteRecipe.parse(recipe.serialized(), id: recipe.id), recipe)
        }
        XCTAssertEqual(BuiltInTemplates.recipes.count, 3)
    }

    func testBuiltInsHaveUniqueIdsAndSections() {
        let ids = BuiltInTemplates.summaries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.contains(BuiltInTemplates.defaultTemplateId))
        for template in BuiltInTemplates.summaries {
            XCTAssertFalse(template.sectionHeadings.isEmpty, template.id)
            XCTAssertEqual(TemplateFileParser.slug(template.id), template.id)
        }
    }

    func testSlug() {
        XCTAssertEqual(TemplateFileParser.slug("Sales / Customer call"), "sales-customer-call")
        XCTAssertEqual(TemplateFileParser.slug("  1:1  "), "1-1")
        XCTAssertEqual(TemplateFileParser.slug("!!!"), "template")
    }
}

final class TemplateSelectorTests: XCTestCase {

    private let templates = BuiltInTemplates.summaries

    func testPicksByKeyword() {
        let pick = TemplateSelector.select(from: templates, titles: ["Sam / Varij 1:1"],
                                           defaultId: "general", autoPick: true)
        XCTAssertEqual(pick?.id, "one-on-one")

        let standup = TemplateSelector.select(from: templates, titles: ["", "Daily Standup — Platform"],
                                              defaultId: "general", autoPick: true)
        XCTAssertEqual(standup?.id, "standup")

        let interview = TemplateSelector.select(from: templates, titles: ["Interview: iOS candidate"],
                                                defaultId: "general", autoPick: true)
        XCTAssertEqual(interview?.id, "interview")
    }

    func testWholeWordMatchOnly() {
        // "dailymotion" must not match "daily"; "democracy" must not match "demo".
        let pick = TemplateSelector.select(from: templates, titles: ["Dailymotion democracy talk"],
                                           defaultId: "general", autoPick: true)
        XCTAssertEqual(pick?.id, "general")
    }

    func testFallsBackToUserDefaultThenGeneral() {
        let custom = TemplateSelector.select(from: templates, titles: ["Quarterly review"],
                                             defaultId: "brainstorm", autoPick: true)
        XCTAssertEqual(custom?.id, "brainstorm")

        let missingDefault = TemplateSelector.select(from: templates, titles: ["Quarterly review"],
                                                     defaultId: "does-not-exist", autoPick: true)
        XCTAssertEqual(missingDefault?.id, "general")
    }

    func testAutoPickOffUsesDefault() {
        let pick = TemplateSelector.select(from: templates, titles: ["Team standup"],
                                           defaultId: "interview", autoPick: false)
        XCTAssertEqual(pick?.id, "interview")
    }

    func testMostHitsWins() {
        let a = SummaryTemplate(id: "a", name: "A", description: "", matchKeywords: ["sync"], body: "")
        let b = SummaryTemplate(id: "b", name: "B", description: "", matchKeywords: ["sync", "design"], body: "")
        let pick = TemplateSelector.select(from: [a, b], titles: ["Design sync"], defaultId: nil, autoPick: true)
        XCTAssertEqual(pick?.id, "b")
    }

    func testEmptyTemplatesReturnsNil() {
        XCTAssertNil(TemplateSelector.select(from: [], titles: ["x"], defaultId: nil, autoPick: true))
    }
}

final class NoteScribeBlocksTests: XCTestCase {

    func testUpsertAppendsThenReplacesInPlace() {
        let body = "# Meeting\n\nMy own notes\n"
        let once = NoteScribeBlocks.upsertSummary(body: body, sessionId: "s1", content: "## Summary\n- v1")
        XCTAssertEqual(once, """
        # Meeting

        My own notes

        <!-- scribe:summary:s1 -->
        ## Summary
        - v1
        <!-- /scribe:summary -->

        """)

        // User keeps typing after the block; replacing must keep that text.
        let edited = once + "\nMore user text\n"
        let twice = NoteScribeBlocks.upsertSummary(body: edited, sessionId: "s1", content: "## Summary\n- v2")
        XCTAssertTrue(twice.contains("- v2"))
        XCTAssertFalse(twice.contains("- v1"))
        XCTAssertTrue(twice.hasPrefix("# Meeting\n\nMy own notes\n\n"))
        XCTAssertTrue(twice.hasSuffix("\nMore user text\n"))
        XCTAssertEqual(NoteScribeBlocks.blocks(in: twice).count, 1)
    }

    func testUpsertIsIdempotent() {
        let a = NoteScribeBlocks.upsertSummary(body: "x", sessionId: "s", content: "c")
        let b = NoteScribeBlocks.upsertSummary(body: a, sessionId: "s", content: "c")
        XCTAssertEqual(a, b)
    }

    func testMultipleSessionsAreIndependent() {
        var body = "notes"
        body = NoteScribeBlocks.upsertSummary(body: body, sessionId: "a", content: "A1")
        body = NoteScribeBlocks.upsertSummary(body: body, sessionId: "b", content: "B1")
        body = NoteScribeBlocks.upsertSummary(body: body, sessionId: "a", content: "A2")
        XCTAssertEqual(NoteScribeBlocks.extractSummary(body: body, sessionId: "a"), "A2")
        XCTAssertEqual(NoteScribeBlocks.extractSummary(body: body, sessionId: "b"), "B1")
        XCTAssertNil(NoteScribeBlocks.extractSummary(body: body, sessionId: "c"))
        let ids = NoteScribeBlocks.blocks(in: body).map(\.id)
        XCTAssertEqual(ids, ["a", "b"])
    }

    func testEmptyBody() {
        let out = NoteScribeBlocks.upsertSummary(body: "", sessionId: "s", content: "c")
        XCTAssertEqual(out, "<!-- scribe:summary:s -->\nc\n<!-- /scribe:summary -->\n")
    }

    func testUnclosedMarkerIsUserText() {
        let body = "<!-- scribe:summary:s -->\nhalf a block"
        XCTAssertTrue(NoteScribeBlocks.blocks(in: body).isEmpty)
        XCTAssertEqual(NoteScribeBlocks.userContent(body: body), body)
    }

    func testUserContentExcludesBlocks() {
        var body = "- point one\n- point two\n"
        body = NoteScribeBlocks.upsertSummary(body: body, sessionId: "s", content: "generated")
        body += "\n- typed after\n"
        XCTAssertEqual(NoteScribeBlocks.userContent(body: body), "- point one\n- point two\n\n- typed after")
    }

    func testReplaceUserContentKeepsBlocks() {
        var body = "- a\n"
        body = NoteScribeBlocks.upsertSummary(body: body, sessionId: "s", content: "generated")
        let replaced = NoteScribeBlocks.replaceUserContent(body: body, with: "- a\n  - › detail")
        XCTAssertEqual(NoteScribeBlocks.userContent(body: replaced), "- a\n  - › detail")
        XCTAssertEqual(NoteScribeBlocks.extractSummary(body: replaced, sessionId: "s"), "generated")
    }

    func testRemoveBlock() {
        let body = NoteScribeBlocks.upsertSummary(body: "keep", sessionId: "s", content: "drop")
        let removed = NoteScribeBlocks.remove(body: body, kind: "summary", id: "s")
        XCTAssertEqual(removed.trimmingCharacters(in: .whitespacesAndNewlines), "keep")
    }

    func testAppendSection() {
        XCTAssertEqual(NoteScribeBlocks.appendSection(body: "notes\n\n", heading: "Follow-up email", content: "Hi all\n"),
                       "notes\n\n## Follow-up email\n\nHi all\n")
    }

    func testNoteAIEditApplyMatchesPureHelpers() {
        let edit = NoteAIEdit.upsertSummary(sessionId: "s", markdown: "m")
        XCTAssertEqual(edit.apply(to: "x"), NoteScribeBlocks.upsertSummary(body: "x", sessionId: "s", content: "m"))
    }
}

final class TranscriptBudgetTests: XCTestCase {

    func testFormatLinesSkipsEmpty() {
        let lines = TranscriptBudget.formatLines([
            (speaker: "Ann", text: " hello ", timestamp: "[00:00:01]"),
            (speaker: "Bob", text: "   ", timestamp: "[00:00:02]"),
            (speaker: "", text: "marker", timestamp: "")
        ])
        XCTAssertEqual(lines, ["[00:00:01] Ann: hello", "marker"])
    }

    func testChunkRespectsLimitAndLineBoundaries() {
        let lines = (0..<50).map { "line \($0) " + String(repeating: "x", count: 20) }
        let chunks = TranscriptBudget.chunk(lines: lines, maxChars: 100)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 100 })
        XCTAssertEqual(chunks.joined(separator: "\n"), lines.joined(separator: "\n"))
    }

    func testChunkHardSplitsOverlongLine() {
        let long = String(repeating: "a", count: 250)
        let chunks = TranscriptBudget.chunk(lines: ["short", long, "tail"], maxChars: 100)
        XCTAssertEqual(chunks, ["short", String(repeating: "a", count: 100), String(repeating: "a", count: 100),
                                String(repeating: "a", count: 50), "tail"])
    }

    func testTruncateKeepsHeadAndTail() {
        let text = String(repeating: "h", count: 500) + String(repeating: "t", count: 500)
        let out = TranscriptBudget.truncate(text, maxChars: 200)
        XCTAssertLessThanOrEqual(out.count, 200)
        XCTAssertTrue(out.hasPrefix("hhh"))
        XCTAssertTrue(out.hasSuffix("ttt"))
        XCTAssertTrue(out.contains("[…]"))
        XCTAssertEqual(TranscriptBudget.truncate("short", maxChars: 200), "short")
    }

    func testCondenseReturnsInputWhenItFits() async throws {
        let out = try await TranscriptBudget.condense(lines: ["a", "b"], budget: 100) { _ in
            XCTFail("summarize must not be called")
            return ""
        }
        XCTAssertEqual(out, "a\nb")
    }

    func testCondenseSummarizesChunksThenMerges() async throws {
        let lines = (0..<40).map { "speaker: sentence number \($0) with some words" }
        // Fake model: condenses each chunk to a short fixed-size line.
        let out = try await TranscriptBudget.condense(lines: lines, budget: 300, chunkSize: 400) { chunk in
            "- " + String(chunk.prefix(20))
        }
        XCTAssertLessThanOrEqual(out.count, 300)
        XCTAssertTrue(out.hasPrefix("- speaker: sentence"))
    }

    func testCondenseFallsBackToTruncationWithoutProgress() async throws {
        let lines = (0..<20).map { "line \($0) " + String(repeating: "z", count: 40) }
        // A "model" that doesn't shrink anything must still end within budget.
        let out = try await TranscriptBudget.condense(lines: lines, budget: 200, chunkSize: 300, maxRounds: 3) { chunk in
            chunk
        }
        XCTAssertLessThanOrEqual(out.count, 200)
    }
}

final class NoteAIPromptBuilderTests: XCTestCase {

    func testAILineDetection() {
        XCTAssertTrue(NoteAIPromptBuilder.isAIAddedLine("  - › Budget approved"))
        XCTAssertTrue(NoteAIPromptBuilder.isAIAddedLine("› standalone"))
        XCTAssertTrue(NoteAIPromptBuilder.isAIAddedLine("1. › numbered"))
        XCTAssertTrue(NoteAIPromptBuilder.isAIAddedLine("- [ ] › task"))
        XCTAssertFalse(NoteAIPromptBuilder.isAIAddedLine("- my own bullet"))
        XCTAssertFalse(NoteAIPromptBuilder.isAIAddedLine("## Heading"))
        XCTAssertFalse(NoteAIPromptBuilder.isAIAddedLine(""))
    }

    func testTemplateInstructionsEmbedTemplateBody() {
        let template = BuiltInTemplates.summaries[0]
        let instructions = NoteAIPromptBuilder.templateInstructions(template)
        for heading in template.sectionHeadings {
            XCTAssertTrue(instructions.contains("## \(heading)"))
        }
    }

    func testEnhancePromptTruncatesNotes() {
        let notes = String(repeating: "n", count: TranscriptBudget.enhanceNotesBudget * 2)
        let prompt = NoteAIPromptBuilder.enhancePrompt(userNotes: notes, title: "", transcript: "t")
        XCTAssertTrue(prompt.contains("MEETING: Untitled"))
        XCTAssertLessThan(prompt.count, TranscriptBudget.enhanceNotesBudget + 200)
    }

    func testRecipePromptOmitsEmptyNotes() {
        let recipe = BuiltInTemplates.recipes[0]
        let withoutNotes = NoteAIPromptBuilder.recipePrompt(recipe: recipe, title: "T", transcript: "x", noteBody: "  ")
        XCTAssertFalse(withoutNotes.contains("MY NOTES"))
        let withNotes = NoteAIPromptBuilder.recipePrompt(recipe: recipe, title: "T", transcript: "x", noteBody: "mine")
        XCTAssertTrue(withNotes.contains("MY NOTES:\nmine"))
        XCTAssertTrue(withNotes.contains(recipe.prompt))
    }

    func testCleanMarkdownOutputStripsFences() {
        XCTAssertEqual(NoteAIPromptBuilder.cleanMarkdownOutput("```markdown\n## A\n- b\n```"), "## A\n- b")
        XCTAssertEqual(NoteAIPromptBuilder.cleanMarkdownOutput("  ## A  \n"), "## A")
    }
}

final class SummaryTemplateStoreTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testSeedsBuiltInsOnFirstUse() throws {
        let store = SummaryTemplateStore(vaultRoot: root)
        let templates = store.listTemplates()
        XCTAssertEqual(templates.count, BuiltInTemplates.summaries.count)
        XCTAssertEqual(templates.first?.id, "general")
        XCTAssertEqual(store.listRecipes().count, 3)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.summariesFolder.appendingPathComponent("standup.md").path))
    }

    func testDeletedBuiltInIsNotResurrectedButRestoreBringsItBack() throws {
        let store = SummaryTemplateStore(vaultRoot: root)
        _ = store.listTemplates()
        try FileManager.default.removeItem(at: store.summariesFolder.appendingPathComponent("brainstorm.md"))
        XCTAssertFalse(store.listTemplates().contains { $0.id == "brainstorm" })
        try store.restoreBuiltIns()
        XCTAssertTrue(store.listTemplates().contains { $0.id == "brainstorm" })
    }

    func testUserTemplateIsListedAndSurvivesRestore() throws {
        let store = SummaryTemplateStore(vaultRoot: root)
        _ = store.listTemplates()
        let custom = SummaryTemplate(id: "retro", name: "Retro", description: "Sprint retro",
                                     matchKeywords: ["retro"], body: "## Went well\n## To improve")
        try custom.serialized().write(to: store.summariesFolder.appendingPathComponent("retro.md"),
                                      atomically: true, encoding: .utf8)
        try store.restoreBuiltIns()
        XCTAssertEqual(store.template(id: "retro"), custom)
    }
}

/// Scribe's own `Templates/Summaries` and `Templates/Recipes` must never be
/// imported as notes — but a user's other notes under `Templates/` must be.
final class TemplatesFolderExclusionTests: XCTestCase {

    private var root: URL!
    private var fileStore: NoteFileStore!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        fileStore = NoteFileStore(directory: NotesDirectory(root: root))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testIsInExcludedFolder() {
        let r = URL(fileURLWithPath: "/vault", isDirectory: true)
        XCTAssertTrue(NoteFileStore.isInExcludedFolder(URL(fileURLWithPath: "/vault/Templates/Summaries"), root: r))
        XCTAssertTrue(NoteFileStore.isInExcludedFolder(URL(fileURLWithPath: "/vault/Templates/Summaries/a.md"), root: r))
        XCTAssertTrue(NoteFileStore.isInExcludedFolder(URL(fileURLWithPath: "/vault/Templates/Recipes/r.md"), root: r))
        XCTAssertTrue(NoteFileStore.isInExcludedFolder(URL(fileURLWithPath: "/vault/templates/recipes/r.md"), root: r),
                      "match is case-insensitive")
        XCTAssertTrue(NoteFileStore.isInExcludedFolder(URL(fileURLWithPath: "/private/vault/Templates/Summaries/x.md"), root: r))
        // The Templates folder itself and the user's own notes in it are not excluded.
        XCTAssertFalse(NoteFileStore.isInExcludedFolder(URL(fileURLWithPath: "/vault/Templates"), root: r))
        XCTAssertFalse(NoteFileStore.isInExcludedFolder(URL(fileURLWithPath: "/vault/Templates/x.md"), root: r))
        XCTAssertFalse(NoteFileStore.isInExcludedFolder(URL(fileURLWithPath: "/vault/Templates/Meetings/standup.md"), root: r))
        XCTAssertFalse(NoteFileStore.isInExcludedFolder(URL(fileURLWithPath: "/vault/Templates.md"), root: r))
        XCTAssertFalse(NoteFileStore.isInExcludedFolder(URL(fileURLWithPath: "/vault/Projects/Templates/a.md"), root: r))
        XCTAssertFalse(NoteFileStore.isInExcludedFolder(URL(fileURLWithPath: "/vault/Daily/2026-01-01.md"), root: r))
        XCTAssertFalse(NoteFileStore.isInExcludedFolder(URL(fileURLWithPath: "/other/Templates/a.md"), root: r))
    }

    func testListAllAndReconcilerSkipTemplates() throws {
        try fileStore.write(NoteFile(
            id: "note-1",
            frontmatter: NoteFrontmatter(title: "Real note", createdAt: Date(), updatedAt: Date()),
            body: "hello"
        ))
        let templateStore = SummaryTemplateStore(vaultRoot: fileStore.directory.root)
        try templateStore.seedIfNeeded()
        XCTAssertFalse(templateStore.listTemplates().isEmpty)

        let listed = try fileStore.listAll()
        XCTAssertEqual(listed.map(\.id), ["note-1"])

        let dbManager = try DatabaseManager(path: ":memory:")
        let reconciler = NoteIndexReconciler(fileStore: fileStore, dbManager: dbManager)
        let result = try reconciler.reconcile()
        XCTAssertEqual(result.upserted, 1)
        let titles = try dbManager.database.read { db in
            try String.fetchAll(db, sql: "SELECT title FROM notes")
        }
        XCTAssertEqual(titles, ["Real note"])
    }
}
