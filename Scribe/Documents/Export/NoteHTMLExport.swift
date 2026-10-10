// Scribe/Documents/Export/NoteHTMLExport.swift
//
// Single-note HTML export: the same HTML the print / PDF path renders
// (`NotePrintHTML`), restyled for screens and made self-contained by
// inlining every local image as a `data:` URL.

import AppKit
import Foundation
import UniformTypeIdentifiers

enum NoteHTMLExport {

    /// Extra CSS so the printable page also reads well in a browser.
    static let screenStylesheet = """
    @media screen {
      body { max-width: 46rem; margin: 2.5rem auto; padding: 0 1.25rem; font-size: 16px; }
      img { border-radius: 4px; }
    }
    @media (prefers-color-scheme: dark) {
      body { background: #1e1e1e; color: #e6e6e6; }
      a { color: #6cb4ff; }
      code, pre { background: #2a2a2c; }
      blockquote { color: #b0b0b0; border-left-color: #555; }
      th, td { border-color: #555; }
    }
    details { margin: 0 0 0.7em; }
    summary { cursor: pointer; color: #666; }
    """

    /// The standalone HTML document for a note whose `body` is plaintext.
    /// `loadImage` returns the bytes + MIME type for a local image `src`.
    nonisolated static func document(
        for note: Note,
        transcriptStore: TranscriptStore,
        loadImage: (String) -> (data: Data, mimeType: String)?
    ) -> String {
        let printable = NotePrintHTML.document(for: note, transcriptStore: transcriptStore)
        return inliningImages(in: addingScreenStyles(to: printable), loadImage: loadImage)
    }

    nonisolated static func addingScreenStyles(to html: String) -> String {
        guard let range = html.range(of: "</style>") else { return html }
        return html.replacingCharacters(in: range, with: screenStylesheet + "\n</style>")
    }

    private static let imgSrcRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(<img\b[^>]*?\bsrc\s*=\s*)(["'])([^"']*)(\2)"#,
            options: [.caseInsensitive]
        )
    }()

    /// Replaces local `<img src>` values with `data:` URLs. Remote (`http:`,
    /// `https:`), `data:` and unresolvable sources are left untouched.
    nonisolated static func inliningImages(
        in html: String,
        loadImage: (String) -> (data: Data, mimeType: String)?
    ) -> String {
        let ns = html as NSString
        let matches = imgSrcRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }
        var out = ""
        var cursor = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let src = ns.substring(with: match.range(at: 3))
            let decodedSrc = decodeHTMLAttribute(src)
            if !MarkdownImportRewriter.hasURLScheme(decodedSrc) || decodedSrc.lowercased().hasPrefix("file:"),
               let image = loadImage(decodedSrc) {
                let quote = ns.substring(with: match.range(at: 2))
                out += ns.substring(with: match.range(at: 1))
                out += quote + "data:\(image.mimeType);base64,\(image.data.base64EncodedString())" + quote
            } else {
                out += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func decodeHTMLAttribute(_ value: String) -> String {
        HTMLEntities.decode(value)
    }

    /// Loads a vault image for inlining: vault-relative paths (percent
    /// escapes allowed) and `file:` URLs inside `root` only.
    nonisolated static func vaultImageLoader(root: URL) -> (String) -> (data: Data, mimeType: String)? {
        { src in
            var path = src
            if path.lowercased().hasPrefix("file://") {
                guard let url = URL(string: path) else { return nil }
                guard let relative = VaultWriteGuard.relativePath(of: url.path, under: root.path) else { return nil }
                path = relative
            }
            path = path.removingPercentEncoding ?? path
            guard let url = EditorAttachmentFiles.servedAttachmentURL(forRequestPath: path, root: root),
                  let data = try? Data(contentsOf: url) else { return nil }
            return (data, EditorAttachmentFiles.mimeType(forFilename: url.lastPathComponent))
        }
    }

    // MARK: - Interactive

    /// Asks where to save, then writes the note as a self-contained HTML
    /// file. `note.body` must hold the plaintext body.
    @MainActor
    static func exportInteractively(note: Note) {
        guard !LockedNoteEnvelope.isLocked(note.body) else {
            AppState.shared.report("This note is locked. Unlock it and use its Document menu to export it.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export as HTML"
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(ExportFileName.safe(note.title)).html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = AttachmentsDirectory.defaultRoot()
        let html = document(for: note, transcriptStore: .shared, loadImage: vaultImageLoader(root: root))
        do {
            try Data(html.utf8).write(to: url, options: .atomic)
            AppState.shared.notify("Exported \u{201C}\(url.lastPathComponent)\u{201D}")
        } catch {
            AppState.shared.report("Couldn't export the note: \(error.localizedDescription)")
        }
    }

    /// File-menu entry: exports the note with `noteId` from disk.
    @MainActor
    static func exportInteractively(noteId: String) {
        guard let note = try? NoteStore.shared.fetchNote(id: noteId) else {
            AppState.shared.report("This note couldn't be found — it may have been deleted.")
            return
        }
        exportInteractively(note: note)
    }
}
