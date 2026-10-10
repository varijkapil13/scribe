// Scribe/UI/Notes/WebMarkdownEditor.swift
//
// CodeMirror 6 markdown editor hosted in a WKWebView. This is step 1 of the
// editor rebuild that replaces the CodeEditSourceEditor engine (which read as a
// code editor: monospace, no full-width wrap, not live-preview). The web editor
// gives us Obsidian-style prose with markdown highlighting, line wrapping, and
// light/dark theming, all driven from native.
//
// This is the LIVE note editor surface, hosted by NoteEditorView (which
// NoteDetailView / DailyNoteView embed). Edits round-trip through a Binding, the
// theme follows the native color scheme, and the JS side renders Obsidian-style
// live preview (decorations are display-only; the bound text stays raw markdown).
//
// Assets live in Scribe/Resources/Editor/ (index.html + editor.bundle.js +
// editor.css + chunks/), bundled as app resources. The bundle is built offline
// from editor-web/ via esbuild; the app never needs node. See
// editor-web/README.md.
//
// The page is served over a custom URL scheme (scribe-asset://editor/, via
// EditorAssetSchemeHandler) rather than loadFileURL. editor.bundle.js is an ES
// module that statically/dynamically imports chunks/*.js; a file:// document
// has a null origin and WebKit blocks CORS-fetched module + import() requests,
// which left the editor a blank white box. A custom scheme gives the document a
// real same-origin tuple so the module and its lazy chunks load.
//
// Bridge contract (must match editor-web/src/editor.js):
//   JS -> native:  window.webkit.messageHandlers.scribe.postMessage(...)
//                    {type:"ready"}             editor mounted
//                    {type:"change", text}      debounced doc edit
//                    {type:"wikilink", target}  user clicked a [[wiki link]]
//                    {type:"outline", headings:[{level,text,line}]}  heading list
//                    {type:"attachment", id, filename, mime, data}   pasted/dropped file
//                    {type:"attachmentRejected", filename, reason}   over the size cap
//                    {type:"requestCompletionData"}  `[[` / `#` completion wants data
//   native -> JS:  window.scribeSetDoc(text)
//                  window.scribeSetTheme("light"|"dark")
//                  window.scribeSetFontSize(px)
//                  window.scribeSetKnownTitles([title, …])  resolved-link styling
//                  window.scribeSetPlantUMLRemote(bool)  opt-in plantuml.com rendering
//                  window.scribeFocus()
//                  window.scribeCommand(name, arg)  WebEditorCommand (find, replace,
//                                   findNext, findPrevious, fold…, scrollToLine)
//                  window.scribeSetCompletionData({titles, tags})
//                  window.scribeAttachmentSaved(id, {path, name, isImage})
//                  window.scribeAttachmentFailed(id, message)
//                  window.scribeInsertAttachment({path, name, isImage})
//   config:        window.scribeConfig = {plantUMLRemote}  document-start user script

import AppKit
import SwiftUI
import WebKit
import OSLog

private let log = Logger(subsystem: "com.varij.scribe", category: "web-markdown-editor")

/// Custom URL scheme + host used to serve the bundled CodeMirror editor assets.
/// See `EditorAssetSchemeHandler` and the file header for why file:// fails.
private let editorAssetScheme = "scribe-asset"
private let editorAssetHost = "editor"
/// Host under the same scheme that serves note attachments (images only) from
/// the vault, so `![](attachments/<noteId>/x.png)` renders inline. See
/// `EditorAttachmentFiles.servedAttachmentURL` for what may be served.
private let vaultAssetHost = "vault"

/// Serves the bundled `Editor/` directory to the WKWebView for
/// `scribe-asset://editor/...` requests, mapping each URL path to a file under
/// the resolved resource directory.
///
/// Why this exists: the editor is an ES module (`editor.bundle.js`) whose first
/// statement is `import "./chunks/chunk-….js"`, and it dynamically `import()`s
/// mermaid/KaTeX chunks on first use. Module scripts and their imports are
/// CORS-fetched; a `file://` document is a null origin, so WebKit denies them
/// and the editor never mounts (blank white view). Serving the identical bytes
/// over a custom scheme gives the page a real, same-origin tuple, so the module
/// and all chunks load normally while staying fully offline.
///
/// WebKit delivers these callbacks on the main thread (the protocol is
/// `@MainActor` in this SDK — mirrors `Coordinator`'s `WKScriptMessageHandler`
/// conformance), so the class is `@MainActor`. All work happens synchronously
/// inside `start` (reads are small, local bundle files): no thread hop, no
/// `Sendable` capture across boundaries, and no window for `stop` to race the
/// response.
@MainActor
private final class EditorAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    /// Absolute URL of the bundled `Editor/` directory. Requests are resolved
    /// underneath it; paths escaping it are refused.
    private let rootDir: URL?

    init(rootDir: URL?) {
        self.rootDir = rootDir
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        if let url = urlSchemeTask.request.url, url.host == vaultAssetHost {
            serveVaultAttachment(url, task: urlSchemeTask)
            return
        }
        guard let rootDir,
              let url = urlSchemeTask.request.url,
              let fileURL = Self.resolve(url, under: rootDir),
              let data = try? Data(contentsOf: fileURL) else {
            if let requested = urlSchemeTask.request.url?.absoluteString {
                log.error("EditorAssetSchemeHandler: no asset for \(requested, privacy: .public)")
            }
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let headers = [
            "Content-Type": Self.mimeType(forExtension: fileURL.pathExtension),
            "Content-Length": String(data.count),
            // Same-origin already, but explicit and harmless — keeps module
            // fetches unambiguous for WebKit.
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
        ]
        guard let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers
        ) else {
            urlSchemeTask.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Responses complete synchronously in `start`; nothing to cancel.
    }

    /// Serves an attachment image from the notes vault for
    /// `scribe-asset://vault/attachments/<noteId>/<file>`.
    private func serveVaultAttachment(_ url: URL, task urlSchemeTask: any WKURLSchemeTask) {
        let root = AttachmentsDirectory.defaultRoot()
        guard let fileURL = EditorAttachmentFiles.servedAttachmentURL(forRequestPath: url.path, root: root),
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let headers = [
            "Content-Type": EditorAttachmentFiles.mimeType(forFilename: fileURL.lastPathComponent),
            "Content-Length": String(data.count),
            "Cache-Control": "no-cache",
        ]
        guard let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers
        ) else {
            urlSchemeTask.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    /// Maps a request URL to a file under `root`, defaulting to `index.html`
    /// for the bare host. Refuses any path that escapes `root` (traversal).
    private static func resolve(_ url: URL, under root: URL) -> URL? {
        var path = url.path
        if path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty { path = "index.html" }

        let candidate = root.appendingPathComponent(path).standardizedFileURL
        let rootStd = root.standardizedFileURL
        guard candidate.path == rootStd.path
                || candidate.path.hasPrefix(rootStd.path + "/") else { return nil }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    private static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }
}

/// A SwiftUI wrapper around a `WKWebView` running the bundled CodeMirror 6
/// markdown editor. Binds to a `String` document and tracks the environment
/// color scheme. Fills its container full width and height.
struct WebMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var colorScheme: ColorScheme
    /// Optional body font size (points) pushed to the JS editor. When nil the
    /// editor keeps its built-in default (17px).
    var fontSize: CGFloat? = nil
    /// Titles of all known notes (lowercased match) so the JS editor can style
    /// `[[wiki links]]` as resolved vs broken. Pushed to JS on change.
    var knownTitles: [String] = []
    /// Called when the user clicks a rendered `[[wiki link]]`. The argument is
    /// the lookup target (the text before any `|alias`), to be resolved via the
    /// note-title resolution and navigated through the app's coordinator.
    var onWikiLink: ((String) -> Void)? = nil
    /// Whether ```plantuml``` fences may be rendered via plantuml.com (sends
    /// the diagram source over the internet). Off by default — see
    /// `PlantUMLRenderingPreference`.
    var plantUMLRemoteEnabled: Bool = PlantUMLRenderingPreference.defaultValue
    /// Note whose attachments folder receives pasted / dropped / imported
    /// files. nil (e.g. an unsaved daily-note draft) saves to
    /// `attachments/unfiled/`.
    var attachmentNoteId: String? = nil
    /// Supplies note titles + tags for `[[` / `#` autocomplete. Called on load
    /// and whenever the editor asks for fresh data.
    var completionDataProvider: (() -> EditorCompletionData)? = nil
    /// Optional observable model receiving the heading outline and offering a
    /// handle to send commands to this editor.
    var model: WebEditorModel? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onWikiLink: onWikiLink)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "scribe")
        // Tell the bundle the PlantUML privacy setting before any of its code
        // runs, so a remote fetch is never attempted when the toggle is off.
        controller.addUserScript(WKUserScript(
            source: PlantUMLRenderingPreference.configScript(remoteEnabled: plantUMLRemoteEnabled),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.userContentController = controller
        // Serve the bundled editor assets over a real origin so the ES module
        // bundle + its lazy chunks load (file:// is a null origin and WebKit
        // blocks module/import() fetches there). Must be set before the
        // WKWebView is created. See EditorAssetSchemeHandler.
        config.setURLSchemeHandler(
            EditorAssetSchemeHandler(rootDir: Self.resourceDir),
            forURLScheme: editorAssetScheme
        )
        EditorWebViewConfigurator.enableFullWritingTools(on: config)

        let webView = ScribeEditorWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // Transparent so the page background (set from CSS/theme) shows through
        // and there's no white flash on dark mode before the bundle loads.
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]

        context.coordinator.webView = webView
        context.coordinator.pendingText = text
        context.coordinator.pendingTheme = colorScheme
        context.coordinator.pendingFontSize = fontSize
        context.coordinator.pendingTitles = knownTitles
        context.coordinator.initialPlantUMLRemote(plantUMLRemoteEnabled)
        context.coordinator.attachmentNoteId = attachmentNoteId
        context.coordinator.completionDataProvider = completionDataProvider
        context.coordinator.attach(model: model)
        webView.onDeviceImport = { [weak coordinator = context.coordinator] data, name, mime in
            coordinator?.importDeviceFile(data: data, filename: name, mimeType: mime)
        }
        webView.onEditorCommand = { [weak coordinator = context.coordinator] command in
            coordinator?.run(command) ?? false
        }
        WebEditorCommandCenter.shared.register(context.coordinator)

        if Self.resourceDir != nil, let entryURL = Self.editorEntryURL {
            webView.load(URLRequest(url: entryURL))
        } else {
            log.error("WebMarkdownEditor: editor assets missing from bundle — editor will not load")
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Push external document changes (e.g. a different note selected) and
        // theme changes down to JS. The coordinator no-ops if the editor isn't
        // ready yet; it flushes pending state on `ready`.
        context.coordinator.parentText = $text
        context.coordinator.onWikiLink = onWikiLink
        context.coordinator.setDoc(text)
        context.coordinator.setTheme(colorScheme)
        if let fontSize { context.coordinator.setFontSize(fontSize) }
        context.coordinator.setKnownTitles(knownTitles)
        context.coordinator.setPlantUMLRemote(plantUMLRemoteEnabled)
        context.coordinator.attachmentNoteId = attachmentNoteId
        context.coordinator.completionDataProvider = completionDataProvider
        context.coordinator.attach(model: model)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        WebEditorCommandCenter.shared.unregister(coordinator)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "scribe")
        if let editorWebView = webView as? ScribeEditorWebView {
            editorWebView.onDeviceImport = nil
            editorWebView.onEditorCommand = nil
        }
    }

    // MARK: - Bundle lookup

    /// The custom-scheme entry point loaded into the WebView. Resolves to
    /// `index.html` under the served `Editor/` directory (see
    /// `EditorAssetSchemeHandler`).
    private static let editorEntryURL = URL(string: "\(editorAssetScheme)://\(editorAssetHost)/index.html")

    /// Resolves the bundled `Editor/index.html`. The Editor folder is added as a
    /// folder reference in project.yml, so it lands inside the bundle's Editor
    /// subdirectory. Used only to derive `resourceDir` (the scheme handler's
    /// root); the page itself is loaded via `editorEntryURL`.
    private static var indexURL: URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor")
            ?? Bundle.main.url(forResource: "index", withExtension: "html")
    }

    /// Root directory the scheme handler serves from — the folder containing
    /// `index.html`, `editor.bundle.js`, `editor.css`, and `chunks/`.
    private static var resourceDir: URL? {
        indexURL?.deletingLastPathComponent()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parentText: Binding<String>
        var onWikiLink: ((String) -> Void)?
        weak var webView: WKWebView?

        private var isReady = false
        /// Last document we pushed to JS — guards the echo loop where a native
        /// push triggers no change, but a user edit comes back as a `change`.
        private var lastSentText: String?
        private var lastSentTheme: ColorScheme?
        private var lastSentFontSize: CGFloat?
        private var lastSentTitles: [String]?
        /// PlantUML remote-render flag the page currently knows (the injected
        /// document-start value, then any live pushes).
        private var lastSentPlantUMLRemote: Bool?

        /// Held until the editor reports `ready`, then flushed.
        var pendingText: String?
        var pendingTheme: ColorScheme?
        var pendingFontSize: CGFloat?
        var pendingTitles: [String]?
        var pendingPlantUMLRemote: Bool?

        /// Folder (note id) for pasted / dropped / imported attachments.
        var attachmentNoteId: String?
        /// Supplies `[[` / `#` completion data (see WebMarkdownEditor).
        var completionDataProvider: (() -> EditorCompletionData)?
        /// Latest heading outline reported by the editor.
        private(set) var outline: [EditorOutlineHeading] = []
        private weak var model: WebEditorModel?

        init(text: Binding<String>, onWikiLink: ((String) -> Void)? = nil) {
            self.parentText = text
            self.onWikiLink = onWikiLink
        }

        // MARK: JS -> native

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "scribe",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            switch type {
            case "ready":
                isReady = true
                if let text = pendingText {
                    pushDoc(text)
                    pendingText = nil
                }
                if let theme = pendingTheme {
                    pushTheme(theme)
                    pendingTheme = nil
                }
                if let size = pendingFontSize {
                    pushFontSize(size)
                    pendingFontSize = nil
                }
                if let titles = pendingTitles {
                    pushKnownTitles(titles)
                    pendingTitles = nil
                }
                if let remote = pendingPlantUMLRemote {
                    pendingPlantUMLRemote = nil
                    if remote != lastSentPlantUMLRemote { pushPlantUMLRemote(remote) }
                }
                pushCompletionData()
            case "change":
                guard let text = body["text"] as? String else { return }
                lastSentText = text
                if parentText.wrappedValue != text {
                    parentText.wrappedValue = text
                }
            case "wikilink":
                guard let target = body["target"] as? String else { return }
                let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                onWikiLink?(trimmed)
            case "outline":
                let headings = EditorOutlineHeading.parseList(body["headings"])
                outline = headings
                if let model, model.outline != headings { model.outline = headings }
            case "requestCompletionData":
                pushCompletionData()
            case "attachment":
                guard let id = body["id"] as? String,
                      let base64 = body["data"] as? String else { return }
                importAttachment(
                    base64: base64,
                    filename: body["filename"] as? String ?? "",
                    mimeType: body["mime"] as? String ?? "",
                    replyID: id
                )
            case "attachmentRejected":
                let name = body["filename"] as? String ?? "file"
                log.error("WebMarkdownEditor: attachment \(name, privacy: .private) rejected (over the size limit)")
                NSSound.beep()
            default:
                break
            }
        }

        // MARK: Model / commands

        /// Connects (or swaps) the observable model that mirrors this editor.
        func attach(model newModel: WebEditorModel?) {
            guard newModel !== model else { return }
            if let old = model, old.coordinator === self { old.coordinator = nil }
            model = newModel
            if let newModel {
                newModel.coordinator = self
                if newModel.outline != outline { newModel.outline = outline }
            }
        }

        /// Runs a native → JS editor command. Returns false until the editor
        /// has loaded.
        @discardableResult
        func run(_ command: WebEditorCommand) -> Bool {
            guard isReady, let webView else { return false }
            webView.evaluateJavaScript(command.javaScript, completionHandler: nil)
            return true
        }

        /// Whether this editor's web view holds keyboard focus in `window`.
        func isFirstResponder(in window: NSWindow) -> Bool {
            guard let webView, let responder = window.firstResponder as? NSView else { return false }
            return responder === webView || responder.isDescendant(of: webView)
        }

        // MARK: Completion data

        private func pushCompletionData() {
            guard isReady, let provider = completionDataProvider else { return }
            let data = provider()
            webView?.evaluateJavaScript(
                "window.scribeSetCompletionData && window.scribeSetCompletionData(\(data.javaScriptLiteral));",
                completionHandler: nil
            )
        }

        // MARK: Attachments

        /// Saves a pasted / dropped file (base64 from JS) off the main actor,
        /// then tells JS where it landed so it can insert the markdown link.
        private func importAttachment(base64: String, filename: String, mimeType: String, replyID: String) {
            let noteId = attachmentNoteId
            let root = AttachmentsDirectory.defaultRoot()
            Task { [weak self] in
                let outcome = await Coordinator.saveDetached(
                    base64: base64, data: nil, filename: filename, mimeType: mimeType, noteId: noteId, root: root
                )
                self?.finishAttachment(outcome, replyID: replyID)
            }
        }

        /// Saves an image imported from a nearby device (Continuity Camera) and
        /// inserts it at the caret.
        func importDeviceFile(data: Data, filename: String, mimeType: String) {
            let noteId = attachmentNoteId
            let root = AttachmentsDirectory.defaultRoot()
            Task { [weak self] in
                let outcome = await Coordinator.saveDetached(
                    base64: nil, data: data, filename: filename, mimeType: mimeType, noteId: noteId, root: root
                )
                self?.finishAttachment(outcome, replyID: nil)
            }
        }

        private nonisolated static func saveDetached(
            base64: String?,
            data: Data?,
            filename: String,
            mimeType: String,
            noteId: String?,
            root: URL
        ) async -> Result<SavedEditorAttachment, EditorAttachmentFilesError> {
            await Task.detached(priority: .userInitiated) { () -> Result<SavedEditorAttachment, EditorAttachmentFilesError> in
                do {
                    let saved: SavedEditorAttachment
                    if let data {
                        saved = try EditorAttachmentFiles.save(
                            data: data, suggestedName: filename, mimeType: mimeType, noteId: noteId, root: root
                        )
                    } else {
                        saved = try EditorAttachmentFiles.saveBase64(
                            base64 ?? "", suggestedName: filename, mimeType: mimeType, noteId: noteId, root: root
                        )
                    }
                    return .success(saved)
                } catch let error as EditorAttachmentFilesError {
                    return .failure(error)
                } catch {
                    log.error("WebMarkdownEditor: saving attachment failed — \(error.localizedDescription, privacy: .public)")
                    return .failure(.invalidData)
                }
            }.value
        }

        private func finishAttachment(
            _ outcome: Result<SavedEditorAttachment, EditorAttachmentFilesError>,
            replyID: String?
        ) {
            switch outcome {
            case .success(let saved):
                let info = WebEditorJS.jsonLiteral(
                    ["path": saved.relativePath, "name": saved.filename, "isImage": saved.isImage] as [String: Any],
                    fallback: "null"
                )
                if let replyID {
                    webView?.evaluateJavaScript(
                        "window.scribeAttachmentSaved && window.scribeAttachmentSaved(\(WebEditorJS.stringLiteral(replyID)), \(info));",
                        completionHandler: nil
                    )
                } else {
                    webView?.evaluateJavaScript(
                        "window.scribeInsertAttachment && window.scribeInsertAttachment(\(info));",
                        completionHandler: nil
                    )
                }
            case .failure(let error):
                log.error("WebMarkdownEditor: attachment not saved — \(error.localizedDescription, privacy: .public)")
                NSSound.beep()
                if let replyID {
                    let message = WebEditorJS.stringLiteral(error.localizedDescription)
                    webView?.evaluateJavaScript(
                        "window.scribeAttachmentFailed && window.scribeAttachmentFailed(\(WebEditorJS.stringLiteral(replyID)), \(message));",
                        completionHandler: nil
                    )
                }
            }
        }

        // MARK: native -> JS

        func setDoc(_ text: String) {
            guard isReady else { pendingText = text; return }
            guard text != lastSentText else { return }
            pushDoc(text)
        }

        func setTheme(_ scheme: ColorScheme) {
            guard isReady else { pendingTheme = scheme; return }
            guard scheme != lastSentTheme else { return }
            pushTheme(scheme)
        }

        private func pushDoc(_ text: String) {
            lastSentText = text
            let json = Self.jsonStringLiteral(text)
            webView?.evaluateJavaScript("window.scribeSetDoc(\(json));", completionHandler: nil)
        }

        func setFontSize(_ size: CGFloat) {
            guard isReady else { pendingFontSize = size; return }
            guard size != lastSentFontSize else { return }
            pushFontSize(size)
        }

        func setKnownTitles(_ titles: [String]) {
            guard isReady else { pendingTitles = titles; return }
            guard titles != lastSentTitles else { return }
            pushKnownTitles(titles)
        }

        /// Records the value baked into the document-start user script so the
        /// first `updateNSView` doesn't redundantly re-push it.
        func initialPlantUMLRemote(_ enabled: Bool) {
            lastSentPlantUMLRemote = enabled
        }

        func setPlantUMLRemote(_ enabled: Bool) {
            guard isReady else { pendingPlantUMLRemote = enabled; return }
            guard enabled != lastSentPlantUMLRemote else { return }
            pushPlantUMLRemote(enabled)
        }

        private func pushPlantUMLRemote(_ enabled: Bool) {
            lastSentPlantUMLRemote = enabled
            webView?.evaluateJavaScript(
                PlantUMLRenderingPreference.setRemoteScript(remoteEnabled: enabled),
                completionHandler: nil
            )
        }

        private func pushKnownTitles(_ titles: [String]) {
            lastSentTitles = titles
            let json: String
            if let data = try? JSONSerialization.data(withJSONObject: titles, options: []),
               let str = String(data: data, encoding: .utf8) {
                json = str
            } else {
                json = "[]"
            }
            webView?.evaluateJavaScript("window.scribeSetKnownTitles(\(json));", completionHandler: nil)
        }

        private func pushTheme(_ scheme: ColorScheme) {
            lastSentTheme = scheme
            let mode = scheme == .dark ? "dark" : "light"
            webView?.evaluateJavaScript("window.scribeSetTheme(\"\(mode)\");", completionHandler: nil)
        }

        private func pushFontSize(_ size: CGFloat) {
            lastSentFontSize = size
            webView?.evaluateJavaScript("window.scribeSetFontSize(\(Int(size.rounded())));", completionHandler: nil)
        }

        // MARK: Navigation

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            let desc = error.localizedDescription
            Task { @MainActor in log.error("WebMarkdownEditor: navigation failed — \(desc, privacy: .public)") }
        }

        nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            let desc = error.localizedDescription
            Task { @MainActor in log.error("WebMarkdownEditor: provisional navigation failed — \(desc, privacy: .public)") }
        }

        /// Escapes an arbitrary string into a JS string literal (including quotes)
        /// safe to embed in evaluateJavaScript. Uses JSONSerialization so all
        /// control characters and unicode line separators are handled.
        nonisolated static func jsonStringLiteral(_ value: String) -> String {
            if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
               let array = String(data: data, encoding: .utf8) {
                // array is `["...escaped..."]`; strip the surrounding brackets.
                let start = array.index(after: array.startIndex)
                let end = array.index(before: array.endIndex)
                return String(array[start..<end])
            }
            return "\"\""
        }
    }
}

// MARK: - Preview

#Preview("Web Markdown Editor") {
    WebMarkdownEditorPreviewHost()
        .frame(width: 700, height: 520)
}

private struct WebMarkdownEditorPreviewHost: View {
    @State private var text = """
    # Welcome to Scribe

    This is the **CodeMirror 6** editor running in a WKWebView.

    - Line wrapping is on, so long paragraphs flow to the full available width \
    instead of scrolling sideways like a code editor.
    - The column is centered with comfortable padding for a prose feel.

    > Edits round-trip back to native through the message bridge.
    """
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WebMarkdownEditor(text: $text, colorScheme: colorScheme)
    }
}
