// ScribeTests/NoteDocumentsExportTests.swift
import XCTest
@testable import Scribe

/// Single-note HTML export (self-contained images) and the vault zip's file
/// selection.
final class NoteDocumentsExportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    private func write(_ relative: String, _ data: Data) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    // MARK: - HTML export

    func testInliningReplacesLocalImagesOnly() {
        let html = #"<p><img src="attachments/n/a.png" alt="a"><img src='https://x.dev/b.png'><img src="data:image/png;base64,AA=="><img src="attachments/n/missing.png"></p>"#
        let out = NoteHTMLExport.inliningImages(in: html) { src in
            src == "attachments/n/a.png" ? (Data([1, 2, 3]), "image/png") : nil
        }
        XCTAssertEqual(
            out,
            #"<p><img src="data:image/png;base64,AQID" alt="a"><img src='https://x.dev/b.png'><img src="data:image/png;base64,AA=="><img src="attachments/n/missing.png"></p>"#
        )
    }

    func testInliningDecodesEntitiesInSources() {
        var asked: [String] = []
        _ = NoteHTMLExport.inliningImages(in: #"<img src="attachments/n/a&amp;b.png">"#) { src in
            asked.append(src)
            return nil
        }
        XCTAssertEqual(asked, ["attachments/n/a&b.png"])
    }

    func testScreenStylesAreAddedToTheStyleBlock() {
        let html = "<html><head><style>body{}</style></head><body></body></html>"
        let styled = NoteHTMLExport.addingScreenStyles(to: html)
        XCTAssertTrue(styled.contains("@media screen"))
        XCTAssertTrue(styled.contains("prefers-color-scheme: dark"))
        XCTAssertEqual(styled.components(separatedBy: "</style>").count, 2)
        XCTAssertEqual(NoteHTMLExport.addingScreenStyles(to: "<p>no style</p>"), "<p>no style</p>")
    }

    func testVaultImageLoaderReadsVaultImagesAndRefusesEscapes() throws {
        try write("attachments/n1/photo one.png", Data([4, 5]))
        try write("secret.png", Data([6]))
        let load = NoteHTMLExport.vaultImageLoader(root: root)

        let loaded = try XCTUnwrap(load("attachments/n1/photo%20one.png"))
        XCTAssertEqual(loaded.data, Data([4, 5]))
        XCTAssertEqual(loaded.mimeType, "image/png")

        let fileURL = root.appendingPathComponent("attachments/n1/photo one.png").absoluteString
        XCTAssertEqual(load(fileURL)?.data, Data([4, 5]))

        XCTAssertNil(load("secret.png"))
        XCTAssertNil(load("attachments/../secret.png"))
        XCTAssertNil(load("attachments/n1/nothing.png"))
    }

    func testDocumentInlinesTheNotesImages() throws {
        try write("attachments/n1/pic.png", Data([7, 7]))
        let note = Note(title: "Pictures", body: "Before\n\n![pic](attachments/n1/pic.png)\n\nAfter")
        let dbm = try DatabaseManager(path: ":memory:")
        let html = NoteHTMLExport.document(
            for: note,
            transcriptStore: TranscriptStore(databaseManager: dbm),
            loadImage: NoteHTMLExport.vaultImageLoader(root: root)
        )
        XCTAssertTrue(html.contains("data:image/png;base64,\(Data([7, 7]).base64EncodedString())"), html)
        XCTAssertFalse(html.contains("src=\"attachments/n1/pic.png\""))
        XCTAssertTrue(html.contains("Pictures"))
        XCTAssertTrue(html.contains("@media screen"))
    }

    // MARK: - Vault zip

    func testExportablePathsSkipHiddenFiles() throws {
        try write("Note.md", Data("a".utf8))
        try write("Work/Plan.md", Data("b".utf8))
        try write("attachments/n1/a.png", Data([1]))
        try write(".hidden/x.md", Data("c".utf8))
        try write(".DS_Store", Data([0]))

        let paths = VaultZipExporter.exportablePaths(under: root)
        XCTAssertTrue(paths.contains("Note.md"))
        XCTAssertTrue(paths.contains("Work/Plan.md"))
        XCTAssertTrue(paths.contains("attachments/n1/a.png"))
        XCTAssertFalse(paths.contains { $0.hasPrefix(".") })
        XCTAssertEqual(paths, paths.sorted())
    }

    func testDefaultZipFileName() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12)) ?? Date()
        XCTAssertEqual(VaultZipExporter.defaultFileName(now: date), "Scribe Notes 2026-03-09.zip")
    }
}
