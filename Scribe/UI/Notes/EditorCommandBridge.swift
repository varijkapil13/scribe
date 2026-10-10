// Scribe/UI/Notes/EditorCommandBridge.swift
import AppKit
import SwiftUI
import WebKit

/// A command the menu bar (Format / Find) sends to the focused note editor.
///
/// Every command crosses into the CodeMirror page as a string name through a
/// single JS entry point, `window.scribeCommand(name, arg)` (see
/// editor-web/src/commands.js). Format names are implemented there; the find
/// names (`find`, `replace`, `findNext`, `findPrevious`) are registered by the
/// editor's search module. A name the page doesn't know is a silent no-op.
enum EditorCommand: Equatable, Hashable, Sendable {
    case bold
    case italic
    case strikethrough
    case inlineCode
    case link
    /// 0 = paragraph, 1–3 = Heading 1–3.
    case heading(Int)
    case bulletedList
    case numberedList
    case checklist
    case quote
    case find
    case findAndReplace
    case findNext
    case findPrevious

    /// The command name the JS dispatcher understands.
    var jsName: String {
        switch self {
        case .bold:           return "bold"
        case .italic:         return "italic"
        case .strikethrough:  return "strikethrough"
        case .inlineCode:     return "code"
        case .link:           return "link"
        case .heading:        return "heading"
        case .bulletedList:   return "bulletList"
        case .numberedList:   return "orderedList"
        case .checklist:      return "checklist"
        case .quote:          return "blockquote"
        case .find:           return "find"
        case .findAndReplace: return "replace"
        case .findNext:       return "findNext"
        case .findPrevious:   return "findPrevious"
        }
    }

    /// The numeric argument passed alongside the name, if any.
    var argument: Int? {
        if case .heading(let level) = self { return max(0, min(6, level)) }
        return nil
    }

    /// The JavaScript evaluated in the editor page. Guarded so a page that
    /// predates the dispatcher (or hasn't mounted yet) ignores it instead of
    /// throwing. Names are fixed ASCII identifiers, so no escaping is needed.
    var javaScript: String {
        let arg = argument.map { String($0) } ?? "null"
        return "(function(){if(typeof window.scribeCommand==='function'){return window.scribeCommand('\(jsName)',\(arg))===true;}return false;})();"
    }
}

/// Connects menu commands to one `WebMarkdownEditor`'s web view.
///
/// `NoteEditorView` owns one, hands it to `WebMarkdownEditor` (which attaches
/// its `WKWebView`), and publishes it as the scene's focused value
/// (`FocusedValues.scribeEditorCommands`) so the Format and Find menus act on
/// the editor in the key window and disable themselves when there is none.
@MainActor
final class EditorCommandBridge {
    private weak var webView: WKWebView?

    init() {}

    /// Whether a live editor web view is attached.
    var isAttached: Bool { webView != nil }

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    /// Sends `command` to the editor. The web view is made first responder
    /// first so the edit lands where the user expects and the caret shows.
    func perform(_ command: EditorCommand) {
        guard let webView else { return }
        if let window = webView.window, window.firstResponder !== webView {
            window.makeFirstResponder(webView)
        }
        webView.evaluateJavaScript(command.javaScript, completionHandler: nil)
    }
}
