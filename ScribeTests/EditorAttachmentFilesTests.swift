// ScribeTests/EditorAttachmentFilesTests.swift
import XCTest
@testable import Scribe

final class EditorAttachmentFilesTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorAttachmentFilesTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - sanitizedFilename

    func testSanitizeKeepsSimpleName() {
        XCTAssertEqual(EditorAttachmentFiles.sanitizedFilename("photo.png", mimeType: "image/png"), "photo.png")
    }

    func testSanitizeReplacesSpacesAndPunctuation() {
        XCTAssertEqual(
            EditorAttachmentFiles.sanitizedFilename("Screen Shot (2) [final]!.PNG", mimeType: nil),
            "Screen-Shot-2-final.png"
        )
    }

    func testSanitizeDropsDirectoryComponents() {
        XCTAssertEqual(EditorAttachmentFiles.sanitizedFilename("../../etc/passwd", mimeType: nil), "passwd.bin")
        XCTAssertEqual(EditorAttachmentFiles.sanitizedFilename("C:\\Users\\me\\doc.pdf", mimeType: nil), "doc.pdf")
        XCTAssertEqual(EditorAttachmentFiles.sanitizedFilename("/tmp/a.txt", mimeType: nil), "a.txt")
    }

    func testSanitizeNeverReturnsHiddenOrEmptyName() {
        XCTAssertEqual(EditorAttachmentFiles.sanitizedFilename(".hidden", mimeType: nil), "hidden.bin")
        XCTAssertEqual(EditorAttachmentFiles.sanitizedFilename("", mimeType: "image/png"), "image.png")
        XCTAssertEqual(EditorAttachmentFiles.sanitizedFilename("   ", mimeType: nil), "attachment.bin")
        XCTAssertEqual(EditorAttachmentFiles.sanitizedFilename("..", mimeType: nil), "attachment.bin")
        XCTAssertEqual(EditorAttachmentFiles.sanitizedFilename("!!!.jpg", mimeType: nil), "image.jpg")
    }

    func testSanitizeDerivesExtensionFromMIME() {
        XCTAssertEqual(EditorAttachmentFiles.sanitizedFilename("Pasted", mimeType: "image/jpeg"), "Pasted.jpg")
        XCTAssertEqual(EditorAttachmentFiles.sanitizedFilename("Scan", mimeType: "application/pdf"), "Scan.pdf")
        XCTAssertEqual(EditorAttachmentFiles.sanitizedFilename("blob", mimeType: nil), "blob.bin")
    }

    func testSanitizeDotsInBaseBecomeDashes() {
        XCTAssertEqual(EditorAttachmentFiles.sanitizedFilename("my.file.v2.tar.gz", mimeType: nil), "my-file-v2-tar.gz")
    }

    func testSanitizeKeepsUnicodeLetters() {
        XCTAssertEqual(EditorAttachmentFiles.sanitizedFilename("Café menü.png", mimeType: nil), "Café-menü.png")
    }

    func testSanitizeCapsLength() {
        let long = String(repeating: "a", count: 300) + ".png"
        let result = EditorAttachmentFiles.sanitizedFilename(long, mimeType: nil)
        XCTAssertEqual(result, String(repeating: "a", count: EditorAttachmentFiles.maxBaseNameLength) + ".png")
    }

    func testSanitizeDropsWeirdExtension() {
        XCTAssertEqual(EditorAttachmentFiles.sanitizedFilename("x.p/n g", mimeType: "image/png"), "n-g.png")
        XCTAssertEqual(EditorAttachmentFiles.sanitizedFilename("a.verylongextension", mimeType: nil), "a.bin")
    }

    // MARK: - uniqueFilename

    func testUniqueFilenameReturnsNameWhenFree() {
        XCTAssertEqual(EditorAttachmentFiles.uniqueFilename("a.png") { _ in false }, "a.png")
    }

    func testUniqueFilenameAppendsCounter() {
        let taken: Set<String> = ["a.png", "a-2.png"]
        XCTAssertEqual(EditorAttachmentFiles.uniqueFilename("a.png") { taken.contains($0) }, "a-3.png")
    }

    func testUniqueFilenameWithoutExtension() {
        XCTAssertEqual(EditorAttachmentFiles.uniqueFilename("README") { $0 == "README" }, "README-2")
    }

    // MARK: - isImage / folder / MIME

    func testIsImage() {
        XCTAssertTrue(EditorAttachmentFiles.isImage(filename: "a.PNG", mimeType: nil))
        XCTAssertTrue(EditorAttachmentFiles.isImage(filename: "a.bin", mimeType: "image/webp"))
        XCTAssertFalse(EditorAttachmentFiles.isImage(filename: "a.pdf", mimeType: "application/pdf"))
    }

    func testFolderNameRejectsTraversal() {
        XCTAssertEqual(try EditorAttachmentFiles.folderName(forNoteId: nil), "unfiled")
        XCTAssertEqual(try EditorAttachmentFiles.folderName(forNoteId: "  "), "unfiled")
        XCTAssertEqual(try EditorAttachmentFiles.folderName(forNoteId: "note-1"), "note-1")
        XCTAssertThrowsError(try EditorAttachmentFiles.folderName(forNoteId: ".."))
        XCTAssertThrowsError(try EditorAttachmentFiles.folderName(forNoteId: "a/b"))
    }

    func testPreferredExtension() {
        XCTAssertEqual(EditorAttachmentFiles.preferredExtension(forMIMEType: "image/png; charset=binary"), "png")
        XCTAssertNil(EditorAttachmentFiles.preferredExtension(forMIMEType: ""))
        XCTAssertNil(EditorAttachmentFiles.preferredExtension(forMIMEType: nil))
    }

    // MARK: - save

    func testSaveWritesIntoNoteFolderWithUniqueNames() throws {
        let data = Data([0x89, 0x50, 0x4E, 0x47])
        let first = try EditorAttachmentFiles.save(
            data: data, suggestedName: "Shot 1.png", mimeType: "image/png", noteId: "note-7", root: tempRoot
        )
        XCTAssertEqual(first.relativePath, "attachments/note-7/Shot-1.png")
        XCTAssertEqual(first.filename, "Shot-1.png")
        XCTAssertTrue(first.isImage)
        XCTAssertEqual(try Data(contentsOf: first.absoluteURL), data)

        let second = try EditorAttachmentFiles.save(
            data: data, suggestedName: "Shot 1.png", mimeType: "image/png", noteId: "note-7", root: tempRoot
        )
        XCTAssertEqual(second.relativePath, "attachments/note-7/Shot-1-2.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.absoluteURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.absoluteURL.path))
    }

    func testSaveWithoutNoteIdUsesUnfiledFolder() throws {
        let saved = try EditorAttachmentFiles.save(
            data: Data("hi".utf8), suggestedName: "notes.txt", mimeType: "text/plain", noteId: nil, root: tempRoot
        )
        XCTAssertEqual(saved.relativePath, "attachments/unfiled/notes.txt")
        XCTAssertFalse(saved.isImage)
    }

    func testSaveRejectsEmptyAndOversized() {
        XCTAssertThrowsError(
            try EditorAttachmentFiles.save(data: Data(), suggestedName: "a.png", mimeType: nil, noteId: "n", root: tempRoot)
        ) { error in
            XCTAssertEqual(error as? EditorAttachmentFilesError, .empty)
        }
        let big = Data(count: EditorAttachmentFiles.maxBytes + 1)
        XCTAssertThrowsError(
            try EditorAttachmentFiles.save(data: big, suggestedName: "a.png", mimeType: nil, noteId: "n", root: tempRoot)
        ) { error in
            XCTAssertEqual(error as? EditorAttachmentFilesError, .tooLarge(bytes: EditorAttachmentFiles.maxBytes + 1))
        }
    }

    func testSaveBase64DecodesAndRejectsGarbage() throws {
        let saved = try EditorAttachmentFiles.saveBase64(
            Data([1, 2, 3, 4]).base64EncodedString(),
            suggestedName: "x.png", mimeType: "image/png", noteId: "n", root: tempRoot
        )
        XCTAssertEqual(try Data(contentsOf: saved.absoluteURL), Data([1, 2, 3, 4]))

        XCTAssertThrowsError(
            try EditorAttachmentFiles.saveBase64("", suggestedName: "x.png", mimeType: nil, noteId: "n", root: tempRoot)
        )
    }

    // MARK: - servedAttachmentURL

    func testServedAttachmentResolvesImagesInsideAttachments() throws {
        let saved = try EditorAttachmentFiles.save(
            data: Data([1]), suggestedName: "pic.png", mimeType: "image/png", noteId: "n1", root: tempRoot
        )
        let resolved = EditorAttachmentFiles.servedAttachmentURL(forRequestPath: "/" + saved.relativePath, root: tempRoot)
        XCTAssertEqual(resolved?.standardizedFileURL.path, saved.absoluteURL.standardizedFileURL.path)
    }

    func testServedAttachmentRefusesTraversalNonImagesAndOutsidePaths() throws {
        // A non-image inside attachments/.
        _ = try EditorAttachmentFiles.save(
            data: Data("x".utf8), suggestedName: "notes.txt", mimeType: "text/plain", noteId: "n1", root: tempRoot
        )
        XCTAssertNil(EditorAttachmentFiles.servedAttachmentURL(forRequestPath: "attachments/n1/notes.txt", root: tempRoot))

        // An image outside attachments/.
        try Data([1]).write(to: tempRoot.appendingPathComponent("secret.png"))
        XCTAssertNil(EditorAttachmentFiles.servedAttachmentURL(forRequestPath: "secret.png", root: tempRoot))
        XCTAssertNil(EditorAttachmentFiles.servedAttachmentURL(forRequestPath: "attachments/../secret.png", root: tempRoot))
        XCTAssertNil(EditorAttachmentFiles.servedAttachmentURL(forRequestPath: "attachments/./n1/../../secret.png", root: tempRoot))

        // Missing file.
        XCTAssertNil(EditorAttachmentFiles.servedAttachmentURL(forRequestPath: "attachments/n1/missing.png", root: tempRoot))
    }

    func testServedAttachmentRefusesSymlinkEscape() throws {
        let outside = tempRoot.appendingPathComponent("outside.png")
        try Data([1]).write(to: outside)
        let dir = try AttachmentsDirectory.directory(forNoteId: "n2", root: tempRoot)
        let link = dir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNil(EditorAttachmentFiles.servedAttachmentURL(forRequestPath: "attachments/n2/link.png", root: tempRoot))
    }

    func testMimeTypeForServedFiles() {
        XCTAssertEqual(EditorAttachmentFiles.mimeType(forFilename: "a.JPG"), "image/jpeg")
        XCTAssertEqual(EditorAttachmentFiles.mimeType(forFilename: "a.svg"), "image/svg+xml")
        XCTAssertEqual(EditorAttachmentFiles.mimeType(forFilename: "a"), "application/octet-stream")
    }
}
