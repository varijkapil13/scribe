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
// editor.css), bundled as app resources. The bundle is built offline from
// editor-web/ via esbuild; the app never needs node. See editor-web/README.md.
//
// Bridge contract (must match editor-web/src/editor.js):
//   JS -> native:  window.webkit.messageHandlers.scribe.postMessage(...)
//                    {type:"ready"}             editor mounted
//                    {type:"change", text}      debounced doc edit
//                    {type:"wikilink", target}  user clicked a [[wiki link]]
//   native -> JS:  window.scribeSetDoc(text)
//                  window.scribeSetTheme("light"|"dark")
//                  window.scribeSetFontSize(px)
//                  window.scribeSetKnownTitles([title, …])  resolved-link styling
//                  window.scribeFocus()

import SwiftUI
import WebKit
import OSLog

private let log = Logger(subsystem: "com.varij.scribe", category: "web-markdown-editor")

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

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onWikiLink: onWikiLink)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "scribe")
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
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

        if let htmlURL = Self.indexURL, let resourceDir = Self.resourceDir {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: resourceDir)
        } else {
            log.error("WebMarkdownEditor: editor index.html missing from bundle — editor will not load")
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
    }

    // MARK: - Bundle lookup

    /// Resolves the bundled `Editor/index.html`. The Editor folder is added as a
    /// folder reference in project.yml, so it lands inside the bundle's Editor
    /// subdirectory.
    private static var indexURL: URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor")
            ?? Bundle.main.url(forResource: "index", withExtension: "html")
    }

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

        /// Held until the editor reports `ready`, then flushed.
        var pendingText: String?
        var pendingTheme: ColorScheme?
        var pendingFontSize: CGFloat?
        var pendingTitles: [String]?

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
            default:
                break
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
