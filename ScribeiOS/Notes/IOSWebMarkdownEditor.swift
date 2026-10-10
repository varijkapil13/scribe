// ScribeiOS/Notes/IOSWebMarkdownEditor.swift
//
// The iPhone / iPad note editor: the SAME CodeMirror 6 bundle the Mac uses
// (Scribe/Resources/Editor, bundled as a folder reference), hosted in a
// WKWebView through UIViewRepresentable. Everything but the view setup — the
// asset scheme handler, the JS ⇄ native message protocol, pending-state flush,
// attachment saving — is the shared `WebEditorCoordinator`
// (Scribe/UI/Notes/WebEditorCore.swift), so behaviour matches the Mac.
//
// Touch: widget taps (checkboxes, [[links]]) and the fold gutter are made
// touch-friendly in the bundle itself (editor-web/src/touch.js, editor.css).
// Scribble / Apple Pencil handwriting works in the page's contenteditable
// natively; nothing here disables it.

import SwiftUI
import UIKit
import WebKit

struct IOSWebMarkdownEditor: UIViewRepresentable {
    @Binding var text: String
    var colorScheme: ColorScheme
    /// Body font size (points) pushed to the JS editor; nil keeps its 17px.
    var fontSize: CGFloat? = nil
    /// Titles of all notes, so `[[links]]` render resolved vs broken.
    var knownTitles: [String] = []
    /// A rendered `[[wiki link]]` was tapped (argument: the link anchor).
    var onWikiLink: ((String) -> Void)? = nil
    /// Whether ```plantuml``` fences may be rendered via plantuml.com.
    var plantUMLRemoteEnabled: Bool = PlantUMLRenderingPreference.defaultValue
    /// Receives the web view so the keyboard format bar can reach it.
    var commandBridge: EditorCommandBridge? = nil
    /// Note whose attachments folder receives pasted / imported files.
    var attachmentNoteId: String? = nil
    /// Note titles + tags for `[[` / `#` completion.
    var completionDataProvider: (() -> EditorCompletionData)? = nil
    /// Outline + command handle for native UI (inspector, attachments).
    var model: WebEditorModel? = nil
    /// Editor messages the shared core leaves to the platform
    /// (`copyText`, `insertTemplateRequest`).
    var onPlatformMessage: ((String, [String: Any]) -> Bool)? = nil

    func makeCoordinator() -> WebEditorCoordinator {
        WebEditorCoordinator(text: $text, onWikiLink: onWikiLink)
    }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let config = WebEditorConfiguration.make(
            messageHandler: coordinator,
            plantUMLRemoteEnabled: plantUMLRemoteEnabled
        )
        // No phone-number / address links inside the prose.
        config.dataDetectorTypes = []
        IOSEditorWebViewConfigurator.enableFullWritingTools(on: config)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        // Transparent so the page background shows and dark mode never
        // flashes white before the bundle loads.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.keyboardDismissMode = .interactive
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false

        coordinator.webView = webView
        commandBridge?.attach(webView)
        coordinator.pendingText = text
        coordinator.pendingTheme = colorScheme
        coordinator.pendingFontSize = fontSize
        coordinator.pendingTitles = knownTitles
        coordinator.initialPlantUMLRemote(plantUMLRemoteEnabled)
        coordinator.attachmentNoteId = attachmentNoteId
        coordinator.completionDataProvider = completionDataProvider
        coordinator.onPlatformMessage = onPlatformMessage
        coordinator.attach(model: model)

        WebEditorAssets.loadEditor(into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parentText = $text
        coordinator.onWikiLink = onWikiLink
        coordinator.onPlatformMessage = onPlatformMessage
        commandBridge?.attach(webView)
        coordinator.setDoc(text)
        coordinator.setTheme(colorScheme)
        if let fontSize { coordinator.setFontSize(fontSize) }
        coordinator.setKnownTitles(knownTitles)
        coordinator.setPlantUMLRemote(plantUMLRemoteEnabled)
        coordinator.attachmentNoteId = attachmentNoteId
        coordinator.completionDataProvider = completionDataProvider
        coordinator.attach(model: model)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: WebEditorCoordinator) {
        // The user content controller retains its handler; drop it so the
        // coordinator (and its bindings) can go.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "scribe")
        coordinator.onPlatformMessage = nil
        coordinator.attach(model: nil)
    }
}

/// iOS counterpart of the Mac's `EditorWebViewConfigurator`.
@MainActor
enum IOSEditorWebViewConfigurator {
    /// Opts the editor into the full Writing Tools experience (inline
    /// rewrite of the selected prose).
    ///
    /// Isolated on purpose: `WKWebViewConfiguration.writingToolsBehavior`
    /// (a `UIWritingToolsBehavior`) is the only SDK-specific line here; if a
    /// newer SDK renames it, fix it in this one place.
    static func enableFullWritingTools(on configuration: WKWebViewConfiguration) {
        if #available(iOS 18.0, *) {
            configuration.writingToolsBehavior = .complete
        }
    }
}
