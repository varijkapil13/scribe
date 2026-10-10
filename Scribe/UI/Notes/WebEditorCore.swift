// Scribe/UI/Notes/WebEditorCore.swift
//
// Platform-neutral half of the CodeMirror 6 note editor host. Compiled into
// BOTH the macOS app (WebMarkdownEditor, an NSViewRepresentable) and the
// iPhone/iPad app (IOSWebMarkdownEditor, a UIViewRepresentable):
//
// - `WebEditorAssets`: where the bundled `Editor/` folder lives and the
//   custom-scheme entry URL the page is loaded from.
// - `EditorAssetSchemeHandler`: serves `scribe-asset://editor/…` (the bundle)
//   and `scribe-asset://vault/attachments/…` (note images) to the WKWebView.
// - `WebEditorConfiguration`: the shared `WKWebViewConfiguration` (message
//   handler, PlantUML document-start config, scheme handler).
// - `WebEditorCoordinator`: the JS ⇄ native message protocol, pending-state
//   flush on `ready`, the native → JS pushes, the command runner and
//   attachment saving.
//
// The bridge contract (message types and `window.scribe*` entry points) is
// documented at the top of WebMarkdownEditor.swift and must match
// editor-web/src/editor.js.

import Foundation
import OSLog
import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private let log = Logger(subsystem: "com.varij.scribe", category: "web-markdown-editor")

// MARK: - Assets

/// Location of the bundled CodeMirror editor and the URLs it is served under.
enum WebEditorAssets {
    /// Custom URL scheme used to serve the bundled editor assets. See
    /// `EditorAssetSchemeHandler` for why file:// fails.
    static let scheme = "scribe-asset"
    /// Host serving the bundled `Editor/` directory.
    static let editorHost = "editor"
    /// Host under the same scheme that serves note attachments (images only)
    /// from the vault, so `![](attachments/<noteId>/x.png)` renders inline.
    /// See `EditorAttachmentFiles.servedAttachmentURL` for what may be served.
    static let vaultHost = "vault"

    /// The custom-scheme entry point loaded into the WebView. Resolves to
    /// `index.html` under the served `Editor/` directory.
    static let entryURL: URL? = URL(string: "scribe-asset://editor/index.html")

    /// Resolves the bundled `Editor/index.html`. The Editor folder is added as
    /// a folder reference in project.yml (both the macOS and the iOS target),
    /// so it lands inside the bundle's Editor subdirectory.
    static var indexURL: URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor")
            ?? Bundle.main.url(forResource: "index", withExtension: "html")
    }

    /// Root directory the scheme handler serves from — the folder containing
    /// `index.html`, `editor.bundle.js`, `editor.css`, and `chunks/`.
    static var resourceDir: URL? {
        indexURL?.deletingLastPathComponent()
    }

    /// Loads the editor page into `webView`. Returns false (and loads
    /// nothing) when the assets are missing from the bundle — e.g. under
    /// `swift test`, where the editor degrades to an empty view.
    @MainActor
    @discardableResult
    static func loadEditor(into webView: WKWebView) -> Bool {
        guard resourceDir != nil, let entryURL else { return false }
        webView.load(URLRequest(url: entryURL))
        return true
    }
}

// MARK: - Scheme handler

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
/// `@MainActor` in this SDK — mirrors `WebEditorCoordinator`'s
/// `WKScriptMessageHandler` conformance), so the class is `@MainActor`. All
/// work happens synchronously inside `start` (reads are small, local bundle
/// files): no thread hop, no `Sendable` capture across boundaries, and no
/// window for `stop` to race the response.
@MainActor
final class EditorAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    /// Absolute URL of the bundled `Editor/` directory. Requests are resolved
    /// underneath it; paths escaping it are refused.
    private let rootDir: URL?

    init(rootDir: URL?) {
        self.rootDir = rootDir
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        if let url = urlSchemeTask.request.url, url.host == WebEditorAssets.vaultHost {
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

// MARK: - Configuration

/// Builds the `WKWebViewConfiguration` both platform editors start from.
@MainActor
enum WebEditorConfiguration {
    /// A configuration with the `scribe` message handler, the PlantUML
    /// privacy setting injected at document start (so a remote fetch is never
    /// attempted when the toggle is off), and the asset scheme handler (which
    /// must be set before the WKWebView is created).
    static func make(
        messageHandler: any WKScriptMessageHandler,
        plantUMLRemoteEnabled: Bool
    ) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(messageHandler, name: "scribe")
        controller.addUserScript(WKUserScript(
            source: PlantUMLRenderingPreference.configScript(remoteEnabled: plantUMLRemoteEnabled),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.userContentController = controller
        config.setURLSchemeHandler(
            EditorAssetSchemeHandler(rootDir: WebEditorAssets.resourceDir),
            forURLScheme: WebEditorAssets.scheme
        )
        return config
    }
}

// MARK: - Feedback

/// Platform feedback for an editor action that failed (an attachment that
/// couldn't be saved): the system beep on the Mac, an error haptic on iOS.
@MainActor
enum WebEditorFeedback {
    static func signalFailure() {
        #if os(macOS)
        NSSound.beep()
        #else
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }
}

// MARK: - Imported files

/// A file handed to the editor by a device source (photo library, camera,
/// document scanner) to be saved as an attachment and inserted at the caret.
struct EditorImportedFile: Sendable {
    var data: Data
    var filename: String
    var mimeType: String

    init(data: Data, filename: String, mimeType: String) {
        self.data = data
        self.filename = filename
        self.mimeType = mimeType
    }
}

// MARK: - Coordinator

/// The native peer of one CodeMirror editor page: receives its messages,
/// pushes document / theme / font / titles / completion data into it, runs
/// commands and saves pasted / dropped / imported attachments.
///
/// Used as `WebMarkdownEditor.Coordinator` on the Mac and as the coordinator
/// of `IOSWebMarkdownEditor` on iPhone / iPad.
@MainActor
final class WebEditorCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var parentText: Binding<String>
    var onWikiLink: ((String) -> Void)?
    weak var webView: WKWebView?

    /// iOS only: receives the message types the core doesn't handle itself
    /// (`copyText`, `insertTemplateRequest`, …). Returns whether it handled
    /// the message. On the Mac these go to `NotePowerEditorBridge`.
    var onPlatformMessage: ((String, [String: Any]) -> Bool)?

    private(set) var isReady = false
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
            WebEditorFeedback.signalFailure()
        default:
            #if os(macOS)
            // Embeds, block links, templates (editor-web/src/notepower.js).
            NotePowerEditorBridge.handle(type: type, body: body, coordinator: self)
            #else
            if !NoteEmbedEditorRequest.handle(type: type, body: body, coordinator: self) {
                _ = onPlatformMessage?(type, body)
            }
            #endif
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
            let outcome = await WebEditorCoordinator.saveDetached(
                base64: base64, data: nil, filename: filename, mimeType: mimeType, noteId: noteId, root: root
            )
            self?.finishAttachment(outcome, replyID: replyID)
        }
    }

    /// Saves an image / file imported from a device source (Continuity
    /// Camera on the Mac; the photo library, camera or document scanner on
    /// iOS) and inserts it at the caret.
    func importDeviceFile(data: Data, filename: String, mimeType: String) {
        let noteId = attachmentNoteId
        let root = AttachmentsDirectory.defaultRoot()
        Task { [weak self] in
            let outcome = await WebEditorCoordinator.saveDetached(
                base64: nil, data: data, filename: filename, mimeType: mimeType, noteId: noteId, root: root
            )
            self?.finishAttachment(outcome, replyID: nil)
        }
    }

    /// Saves several imported files (e.g. the pages of a document scan) one
    /// after another and inserts them at the caret in the given order.
    func importDeviceFiles(_ files: [EditorImportedFile]) {
        guard !files.isEmpty else { return }
        let noteId = attachmentNoteId
        let root = AttachmentsDirectory.defaultRoot()
        Task { [weak self] in
            for file in files {
                let outcome = await WebEditorCoordinator.saveDetached(
                    base64: nil, data: file.data, filename: file.filename, mimeType: file.mimeType,
                    noteId: noteId, root: root
                )
                guard let self else { return }
                self.finishAttachment(outcome, replyID: nil)
            }
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
            WebEditorFeedback.signalFailure()
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
    /// first view update doesn't redundantly re-push it.
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
