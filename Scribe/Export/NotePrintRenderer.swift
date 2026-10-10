// Scribe/Export/NotePrintRenderer.swift
import AppKit
import Markdown
import UniformTypeIdentifiers
import WebKit

// File › Print… (⌘P) and File › Export as PDF… for a note.
//
// The note goes through the existing Markdown exporter (`NoteMarkdownExporter`,
// so the printout carries the same title / linked-recordings tail as a Markdown
// export), is rendered to HTML with swift-markdown, loaded into an offscreen
// WKWebView, and printed with WebKit's print operation. Export as PDF is the
// same operation with a "save to file" job disposition, so the PDF is
// paginated exactly like the printout.

// MARK: - HTML (pure)

/// Builds the printable HTML document for a note. Pure and testable.
enum NotePrintHTML {

    /// Markdown → HTML fragment.
    ///
    /// Uses swift-markdown's `HTMLFormatter`. If a swift-markdown update ever
    /// changes this API, this one function is the only place to fix.
    nonisolated static func bodyHTML(fromMarkdown markdown: String) -> String {
        HTMLFormatter.format(markdown)
    }

    /// Escapes text for an HTML text node / attribute.
    nonisolated static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            case "'":  out += "&#39;"
            default:   out.append(character)
            }
        }
        return out
    }

    /// A complete, self-contained HTML page. Scripts and remote loads are
    /// blocked by the CSP (raw HTML inside a note must not run or phone home
    /// while printing); local images (vault attachments) and data URLs load.
    nonisolated static func document(title: String, bodyHTML: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file: data:; style-src 'unsafe-inline'">
        <title>\(escape(title))</title>
        <style>\(stylesheet)</style>
        </head>
        <body>
        \(bodyHTML)
        </body>
        </html>
        """
    }

    /// The full printable page for a note (title, body, linked recordings).
    nonisolated static func document(for note: Note, transcriptStore: TranscriptStore) -> String {
        let markdown = NoteMarkdownExporter.export(note: note, transcriptStore: transcriptStore)
        let title = note.title.isEmpty ? "Untitled note" : note.title
        return document(title: title, bodyHTML: bodyHTML(fromMarkdown: markdown))
    }

    static let stylesheet = """
    body { font: 11pt -apple-system, "Helvetica Neue", sans-serif; line-height: 1.5; color: #111; margin: 0; }
    h1 { font-size: 20pt; margin: 0 0 0.4em; }
    h2 { font-size: 15pt; margin: 1.2em 0 0.4em; }
    h3 { font-size: 12.5pt; margin: 1em 0 0.3em; }
    p, ul, ol, blockquote, pre, table { margin: 0 0 0.7em; }
    code { font: 9.5pt ui-monospace, Menlo, monospace; background: #f2f2f4; padding: 0 0.2em; border-radius: 3px; }
    pre { background: #f6f6f8; padding: 0.6em 0.8em; border-radius: 4px; white-space: pre-wrap; }
    pre code { background: none; padding: 0; }
    blockquote { border-left: 3px solid #ccc; margin-left: 0; padding-left: 0.8em; color: #444; }
    table { border-collapse: collapse; }
    th, td { border: 1px solid #ccc; padding: 0.2em 0.5em; }
    hr { border: none; border-top: 1px solid #ddd; margin: 1.2em 0; }
    img { max-width: 100%; }
    a { color: #0a58ca; text-decoration: none; }
    h1, h2, h3 { page-break-after: avoid; }
    pre, blockquote, table, img { page-break-inside: avoid; }
    """
}

// MARK: - Renderer

/// Prints a note, or saves it as a PDF, via an offscreen WKWebView.
@MainActor
final class NotePrintRenderer: NSObject, WKNavigationDelegate {

    enum Output {
        case printer
        case pdf(URL)
    }

    /// Renderers stay alive here until their print operation finishes (the
    /// web view must outlive the asynchronous load + print sheet).
    private static var inFlight: [NotePrintRenderer] = []

    private let webView: WKWebView
    private let output: Output
    private let jobTitle: String

    // MARK: Entry points

    /// File › Print… for the note with `noteId`.
    static func printNote(id noteId: String) {
        guard let document = loadDocument(noteId: noteId) else { return }
        start(html: document.html, title: displayTitle(document.note), output: .printer)
    }

    /// File › Export as PDF… for the note with `noteId`: asks where to save,
    /// then writes a paginated PDF.
    static func exportPDF(noteId: String) {
        guard let document = loadDocument(noteId: noteId) else { return }
        let note = document.note
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(ExportFileName.safe(note.title)).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start(html: document.html, title: displayTitle(note), output: .pdf(url))
    }

    // MARK: Internals

    private struct LoadedDocument {
        let note: Note
        let html: String
    }

    private static func loadDocument(noteId: String) -> LoadedDocument? {
        guard let note = try? NoteStore.shared.fetchNote(id: noteId) else {
            AppState.shared.report("This note couldn't be found — it may have been deleted.")
            return nil
        }
        return LoadedDocument(note: note,
                              html: NotePrintHTML.document(for: note, transcriptStore: .shared))
    }

    private static func displayTitle(_ note: Note) -> String {
        note.title.isEmpty ? "Untitled note" : note.title
    }

    private static func start(html: String, title: String, output: Output) {
        let renderer = NotePrintRenderer(title: title, output: output)
        inFlight.append(renderer)
        renderer.load(html: html)
    }

    private init(title: String, output: Output) {
        let config = WKWebViewConfiguration()
        // Raw HTML in a note must never run script while printing.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        // US Letter-ish width at 72 dpi; the print operation re-flows to the
        // chosen paper size.
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 612, height: 792), configuration: config)
        self.output = output
        self.jobTitle = title
        super.init()
        webView.navigationDelegate = self
    }

    private func load(html: String) {
        // The vault root as base URL so relative attachment paths
        // (`attachments/<note>/<file>`) resolve for images.
        // Directory URL (trailing slash), or relative paths would resolve
        // against the vault's parent.
        let root = URL(fileURLWithPath: AttachmentsDirectory.defaultRoot().path, isDirectory: true)
        webView.loadHTMLString(html, baseURL: root)
    }

    private func finish() {
        Self.inFlight.removeAll { $0 === self }
    }

    private func runPrintOperation() {
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 40
        printInfo.rightMargin = 40

        let showsPanel: Bool
        switch output {
        case .printer:
            showsPanel = true
        case .pdf(let url):
            showsPanel = false
            printInfo.jobDisposition = .save
            printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = url
        }

        let operation = webView.printOperation(with: printInfo)
        operation.jobTitle = jobTitle
        operation.showsPrintPanel = showsPanel
        operation.showsProgressPanel = showsPanel
        // WebKit's print view needs a real frame or it paginates to blank pages.
        operation.view?.frame = webView.bounds

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            operation.runModal(
                for: window,
                delegate: self,
                didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                contextInfo: nil
            )
        } else {
            let success = operation.run()
            completed(success: success)
        }
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation,
                                            success: Bool,
                                            contextInfo: UnsafeMutableRawPointer?) {
        completed(success: success)
    }

    private func completed(success: Bool) {
        if success, case .pdf(let url) = output {
            AppState.shared.notify("Exported “\(url.deletingPathExtension().lastPathComponent).pdf”")
        }
        finish()
    }

    private func loadFailed(_ message: String) {
        AppState.shared.report("Couldn't prepare the note for printing: \(message)")
        finish()
    }

    // MARK: WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.runPrintOperation() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.loadFailed(message) }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.loadFailed(message) }
    }
}
