// ScribeTests/NoteImportSourcesTests.swift
import XCTest
@testable import Scribe

/// File-system readers of the importers (Notion, Markdown folder, Apple
/// Notes, documents), against small fixture folders in a temp directory.
final class NoteImportSourcesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func write(_ relative: String, _ contents: String) throws -> URL {
        try write(relative, data: Data(contents.utf8))
    }

    @discardableResult
    private func write(_ relative: String, data: Data) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func draft(_ result: NoteImportReadResult, titled title: String) throws -> ImportedNoteDraft {
        try XCTUnwrap(result.drafts.first { $0.title == title }, "no draft titled \(title)")
    }

    /// The attachment a placeholder in `body` stands for, by file name.
    private func attachment(named name: String, in draft: ImportedNoteDraft) -> (placeholder: String, source: ImportedAttachmentSource)? {
        draft.attachments.first { $0.value.filename == name }.map { ($0.key, $0.value) }
    }

    // MARK: - Notion

    func testNotionStripsIdsFixesLinksAndConvertsDatabases() throws {
        let id1 = "0123456789abcdef0123456789abcdef"
        let id2 = "fedcba9876543210fedcba9876543210"
        let db = "aaaaaaaaaaaaaaaabbbbbbbbbbbbbbbb"
        let export = "Workspace \(id1)"
        try write("\(export)/Project Plan \(id1).md", """
        # Project Plan

        See [Meeting Notes](Project%20Plan%20\(id1)/Meeting%20Notes%20\(id2).md) and the [Tasks](Tasks%20\(db).csv).
        ![diagram](Project%20Plan%20\(id1)/diagram.png)
        [Site](https://notion.so)
        """)
        try write("\(export)/Project Plan \(id1)/Meeting Notes \(id2).md", "# Meeting Notes\n\nBack to [Plan](../Project%20Plan%20\(id1).md)")
        try write("\(export)/Project Plan \(id1)/diagram.png", data: Data([1, 2, 3]))
        try write("\(export)/Tasks \(db).csv", "Name,Status\nMeeting Notes,Done\nShip,Open\n")
        try write("\(export)/Tasks \(db)_all.csv", "Name,Status\nMeeting Notes,Done\nShip,Open\nArchived,Done\n")

        let result = NoteImportSources.readNotion(root: root.appendingPathComponent(export))
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(Set(result.drafts.map(\.title)), ["Project Plan", "Meeting Notes", "Tasks"])

        let plan = try draft(result, titled: "Project Plan")
        XCTAssertEqual(plan.notebookPath, ["Workspace"])
        XCTAssertFalse(plan.body.hasPrefix("# Project Plan"))
        XCTAssertTrue(plan.body.contains("See [[Meeting Notes]] and the [[Tasks]]."), plan.body)
        XCTAssertTrue(plan.body.contains("[Site](https://notion.so)"))
        let diagram = try XCTUnwrap(attachment(named: "diagram.png", in: plan))
        XCTAssertTrue(plan.body.contains("![diagram](\(diagram.placeholder))"))

        let meeting = try draft(result, titled: "Meeting Notes")
        XCTAssertEqual(meeting.body, "Back to [[Project Plan]]")

        // Only the `_all` CSV is used, its first column linked to known pages.
        XCTAssertEqual(result.drafts.filter { $0.title == "Tasks" }.count, 1)
        let tasks = try draft(result, titled: "Tasks")
        XCTAssertEqual(tasks.body, """
        | Name | Status |
        | --- | --- |
        | [[Meeting Notes]] | Done |
        | Ship | Open |
        | Archived | Done |
        """)
    }

    // MARK: - Markdown folder

    func testMarkdownFolderKeepsFoldersAsNotebooksAndRewritesImages() throws {
        let vault = "My Vault"
        try write("\(vault)/Work/Clients/Acme.md", """
        ---
        title: Acme Corp
        tags: [client, "#b2b"]
        aliases: [ACME]
        ---
        # Acme Corp

        Logo: ![logo](../../assets/logo%201.png)
        Embed: ![[chart.png|200]]
        Link to [Other](../Other.md) and [[Wiki Link]].
        <img src="../../assets/logo 1.png" width="40">
        `![code](../../assets/logo 1.png)`
        """)
        try write("\(vault)/Work/Other.md", "Plain note")
        try write("\(vault)/assets/logo 1.png", data: Data([9]))
        try write("\(vault)/Attachments/chart.png", data: Data([8]))
        try write("\(vault)/.obsidian/workspace.md", "hidden")

        let result = NoteImportSources.readMarkdownFolder(root: root.appendingPathComponent(vault))
        XCTAssertEqual(Set(result.drafts.map(\.title)), ["Acme Corp", "Other"])

        let acme = try draft(result, titled: "Acme Corp")
        XCTAssertEqual(acme.notebookPath, ["My Vault", "Work", "Clients"])
        XCTAssertEqual(acme.tags, ["client", "b2b"])
        XCTAssertEqual(acme.extra, [FrontmatterEntry(key: "aliases", value: "[ACME]")])
        XCTAssertEqual(acme.attachments.count, 2)
        let logo = try XCTUnwrap(attachment(named: "logo 1.png", in: acme))
        let chart = try XCTUnwrap(attachment(named: "chart.png", in: acme))
        let expected = """
        Logo: ![logo](\(logo.placeholder))
        Embed: ![chart.png](\(chart.placeholder))
        Link to [[Other]] and [[Wiki Link]].
        <img src="\(logo.placeholder)" width="40">
        `![code](../../assets/logo 1.png)`
        """
        XCTAssertEqual(acme.body, expected)

        let other = try draft(result, titled: "Other")
        XCTAssertEqual(other.notebookPath, ["My Vault", "Work"])
        XCTAssertEqual(other.body, "Plain note")
    }

    func testMarkdownFolderReadsBearTextBundles() throws {
        try write("Bear/Recipe.textbundle/text.md", "# Recipe\n\n![](assets/cake.jpg)")
        try write("Bear/Recipe.textbundle/assets/cake.jpg", data: Data([7]))
        try write("Bear/Recipe.textbundle/info.json", "{}")

        let result = NoteImportSources.readMarkdownFolder(root: root.appendingPathComponent("Bear"))
        XCTAssertEqual(result.drafts.map(\.title), ["Recipe"])
        let recipe = try draft(result, titled: "Recipe")
        XCTAssertEqual(recipe.notebookPath, ["Bear"])
        let cake = try XCTUnwrap(attachment(named: "cake.jpg", in: recipe))
        XCTAssertEqual(recipe.body, "![](\(cake.placeholder))")
    }

    func testMissingImagesAreLeftAsWritten() throws {
        try write("Notes/A.md", "![gone](missing.png) and ![up](../../../etc/passwd.png)")
        let result = NoteImportSources.readMarkdownFolder(root: root.appendingPathComponent("Notes"))
        let note = try draft(result, titled: "A")
        XCTAssertTrue(note.attachments.isEmpty)
        XCTAssertEqual(note.body, "![gone](missing.png) and ![up](../../../etc/passwd.png)")
    }

    // MARK: - Apple Notes

    func testAppleNotesHTMLExport() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        try write("Apple Notes/Recipes/Pancakes.html", """
        <html><head><title>Pancakes</title></head><body>
        <div><b>Pancakes</b></div>
        <ul class="checklist"><li class="checked">Flour</li><li>Milk</li></ul>
        <div><img src="data:image/png;base64,\(png.base64EncodedString())"></div>
        <div><img src="Pancakes_files/photo.jpg"></div>
        </body></html>
        """)
        try write("Apple Notes/Recipes/Pancakes_files/photo.jpg", data: Data([5]))
        try write("Apple Notes/Ideas.md", "Markdown export")

        let result = NoteImportSources.readAppleNotes(root: root.appendingPathComponent("Apple Notes"))
        XCTAssertEqual(Set(result.drafts.map(\.title)), ["Pancakes", "Ideas"])

        let pancakes = try draft(result, titled: "Pancakes")
        XCTAssertEqual(pancakes.notebookPath, ["Apple Notes", "Recipes"])
        XCTAssertEqual(pancakes.attachments.count, 2)
        let inline = try XCTUnwrap(attachment(named: "image.png", in: pancakes))
        XCTAssertEqual(inline.source.content, .data(png))
        let photo = try XCTUnwrap(attachment(named: "photo.jpg", in: pancakes))
        XCTAssertEqual(pancakes.body, """
        - [x] Flour
        - [ ] Milk

        ![](\(inline.placeholder))
        ![](\(photo.placeholder))
        """)

        let ideas = try draft(result, titled: "Ideas")
        XCTAssertEqual(ideas.notebookPath, ["Apple Notes"])
    }

    func testDecodeDataURI() throws {
        let decoded = try XCTUnwrap(NoteImportSources.decodeDataURI("data:image/jpeg;base64,AQID"))
        XCTAssertEqual(decoded.mimeType, "image/jpeg")
        XCTAssertEqual(decoded.data, Data([1, 2, 3]))
        XCTAssertNil(NoteImportSources.decodeDataURI("data:text/plain,hello"))
        XCTAssertNil(NoteImportSources.decodeDataURI("https://x.dev/a.png"))
    }

    func testRemovingLeadingLineEqualToTitle() {
        XCTAssertEqual(NoteImportSources.removingLeadingLine("**Pancakes**\nBody", equalTo: "Pancakes"), "Body")
        XCTAssertEqual(NoteImportSources.removingLeadingLine("Intro\nBody", equalTo: "Pancakes"), "Intro\nBody")
    }

    // MARK: - PDF / image as note

    func testDocumentNoteBodyEmbedsFileAndCollapsesRecognizedText() {
        let body = ImportedDocumentNoteBuilder.body(
            destination: "attachments/n/scan 1.pdf",
            filename: "scan 1.pdf",
            isImage: false,
            recognizedText: "INVOICE\n# 42\n\n\n\nTotal: 10"
        )
        XCTAssertEqual(body, """
        [scan 1.pdf](<attachments/n/scan 1.pdf>)

        <details>
        <summary>Recognized text</summary>

        INVOICE
        \\# 42

        Total: 10

        </details>
        """)
        XCTAssertEqual(
            ImportedDocumentNoteBuilder.body(destination: "p", filename: "photo.png", isImage: true, recognizedText: "  "),
            "![photo.png](p)"
        )
        XCTAssertEqual(ImportedDocumentNoteBuilder.title(forFilename: "Receipt March.pdf"), "Receipt March")
    }

    func testReadDocumentsRejectsUnsupportedFiles() throws {
        let text = try write("notes.txt", "hello")
        let result = NoteImportSources.readDocuments([text])
        XCTAssertTrue(result.drafts.isEmpty)
        XCTAssertEqual(result.warnings.count, 1)
    }
}
