// Scribe/UI/Notes/ScribeEditorWebView.swift
//
// The WKWebView subclass hosting the CodeMirror note editor. It exists to hook
// AppKit responder features WKWebView doesn't expose to page JS:
//
// - The standard Edit › Find menu (`performTextFinderAction:`) → the editor's
//   find / replace panel via `WebEditorCommand`.
// - Continuity Camera ("Import from iPhone or iPad" → Take Photo / Scan
//   Documents) — see EditorContinuityCamera.swift.
// - Writing Tools: full (inline rewrite) behavior is opted into on the
//   configuration before the view is created (`EditorWebViewConfigurator`).

import AppKit
import WebKit

@MainActor
final class ScribeEditorWebView: WKWebView {

    /// Receives an image / scan imported from a nearby iPhone or iPad:
    /// (bytes, suggested file name, MIME type). Set by the editor coordinator.
    var onDeviceImport: ((Data, String, String) -> Void)?

    private lazy var continuityRequestor = EditorContinuityImportRequestor { [weak self] data, name, mime in
        self?.onDeviceImport?(data, name, mime)
    }

    /// Runs an editor command (wired to the coordinator); returns whether the
    /// editor took it.
    var onEditorCommand: ((WebEditorCommand) -> Bool)?

    /// The standard Edit › Find menu items (⌘F, ⌘G, ⇧⌘G, ⌥⌘F …) arrive here
    /// as menu key equivalents before the page sees the key, so route them to
    /// the CodeMirror search panel instead of WebKit's own find UI.
    override func performTextFinderAction(_ sender: Any?) {
        if let item = sender as? any NSValidatedUserInterfaceItem,
           let command = WebEditorCommand.forTextFinderAction(tag: item.tag),
           onEditorCommand?(command) == true {
            return
        }
        // Only forward to super when WKWebView (or an ancestor) actually
        // implements the action: the selector is declared in an NSResponder
        // category, and messaging super for an unimplemented selector would
        // raise "unrecognized selector" instead of falling through.
        let action = #selector(NSResponder.performTextFinderAction(_:))
        if WKWebView.instancesRespond(to: action) {
            super.performTextFinderAction(sender)
        } else {
            _ = nextResponder?.tryToPerform(action, with: sender)
        }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        EditorContinuityCamera.addImportItem(to: menu)
    }

    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if onDeviceImport != nil,
           EditorContinuityCamera.canImport(sendType: sendType, returnType: returnType) {
            return continuityRequestor
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
}

/// Configuration tweaks for the editor's WKWebView.
@MainActor
enum EditorWebViewConfigurator {
    /// Opts the editor into the full Writing Tools experience (inline
    /// proofread / rewrite of the selected prose, not just the panel).
    ///
    /// Isolated on purpose: `WKWebViewConfiguration.writingToolsBehavior`
    /// (an `NSWritingToolsBehavior`) is the only SDK-specific line here; if a
    /// newer SDK renames it, fix it in this one place.
    static func enableFullWritingTools(on configuration: WKWebViewConfiguration) {
        configuration.writingToolsBehavior = .complete
    }
}
