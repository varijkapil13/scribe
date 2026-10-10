// Scribe/Documents/Import/DocumentNoteImport.swift
//
// File › Import › PDF or Image as Note…: each chosen file becomes a note
// with the file embedded as an attachment and its recognized text (PDF text
// layer + OCR, or image OCR) in a collapsed "Recognized text" section.

import Foundation

enum ImportedDocumentNoteBuilder {

    /// Summary line of the collapsed section.
    static let recognizedTextSummary = "Recognized text"

    /// The note body for an imported document. `destination` is where the
    /// attachment lives (a placeholder during import).
    nonisolated static func body(
        destination: String,
        filename: String,
        isImage: Bool,
        recognizedText: String
    ) -> String {
        let label = HTMLMarkdownRenderer.escapeBrackets(filename)
        let target = HTMLMarkdownRenderer.markdownDestination(destination)
        var lines = [isImage ? "![\(label)](\(target))" : "[\(label)](\(target))"]
        let text = MarkdownImportRewriter.escapedPlainText(recognizedText)
        if !text.isEmpty {
            lines.append("")
            lines.append("<details>")
            lines.append("<summary>\(recognizedTextSummary)</summary>")
            lines.append("")
            lines.append(text)
            lines.append("")
            lines.append("</details>")
        }
        return lines.joined(separator: "\n")
    }

    /// Note title for an imported file: its name without the extension.
    nonisolated static func title(forFilename filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? "Imported Document" : base
    }
}

extension NoteImportSources {

    static let documentExtensions: Set<String> = AttachmentTextRecognizer.imageExtensions.union(["pdf"])

    /// Reads PDFs / images into drafts, recognizing their text (slow: OCR).
    static func readDocuments(
        _ urls: [URL],
        isCancelled: @Sendable () -> Bool = { false },
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) -> NoteImportReadResult {
        var result = NoteImportReadResult()
        for (index, url) in urls.enumerated() {
            if isCancelled() { break }
            let ext = url.pathExtension.lowercased()
            guard documentExtensions.contains(ext) else {
                result.warnings.append("\(url.lastPathComponent) isn't a PDF or an image.")
                continue
            }
            let recognized = (try? AttachmentTextRecognizer.recognizeText(at: url)) ?? ""
            var collector = ImportAttachmentCollector()
            let placeholder = collector.register(ImportedAttachmentSource(
                content: .file(url),
                filename: url.lastPathComponent,
                mimeType: ext == "pdf" ? "application/pdf" : nil
            ))
            let dates = fileDates(url)
            result.drafts.append(ImportedNoteDraft(
                title: ImportedDocumentNoteBuilder.title(forFilename: url.lastPathComponent),
                body: ImportedDocumentNoteBuilder.body(
                    destination: placeholder,
                    filename: url.lastPathComponent,
                    isImage: ext != "pdf",
                    recognizedText: recognized
                ),
                createdAt: dates.created,
                updatedAt: dates.modified,
                attachments: collector.attachments,
                sourceName: url.lastPathComponent
            ))
            progress(index + 1, urls.count)
        }
        return result
    }
}
