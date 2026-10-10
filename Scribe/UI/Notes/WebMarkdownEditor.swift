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
//                  window.scribeCommand(name, arg)  menu-bar Format/Find commands
//                                   (EditorCommandBridge) and WebEditorCommand
//                                   (find, replace, fold…, scrollToLine)
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

// The platform-neutral parts — asset lookup, `EditorAssetSchemeHandler`, the
// shared `WKWebViewConfiguration`, and the message protocol / push logic in
// `WebEditorCoordinator` — live in WebEditorCore.swift, shared with the
// iPhone/iPad editor (ScribeiOS/Notes/IOSWebMarkdownEditor.swift).

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
    /// Receives the web view so menu-bar Format/Find commands can reach this
    /// editor (see `EditorCommandBridge`). Optional; nil means no menu access.
    var commandBridge: EditorCommandBridge? = nil
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
        // Message handler + PlantUML document-start config + the asset scheme
        // handler (serves the bundle over a real origin so the ES module and
        // its lazy chunks load). See WebEditorConfiguration.
        let config = WebEditorConfiguration.make(
            messageHandler: context.coordinator,
            plantUMLRemoteEnabled: plantUMLRemoteEnabled
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
        commandBridge?.attach(webView)
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

        if !WebEditorAssets.loadEditor(into: webView) {
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
        commandBridge?.attach(webView)
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

    // MARK: - Coordinator

    /// The shared, platform-neutral coordinator (WebEditorCore.swift).
    typealias Coordinator = WebEditorCoordinator
}

extension WebEditorCoordinator {
    /// Whether this editor's web view holds keyboard focus in `window`.
    func isFirstResponder(in window: NSWindow) -> Bool {
        guard let webView, let responder = window.firstResponder as? NSView else { return false }
        return responder === webView || responder.isDescendant(of: webView)
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
