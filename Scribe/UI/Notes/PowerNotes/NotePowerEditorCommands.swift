// Scribe/UI/Notes/PowerNotes/NotePowerEditorCommands.swift
//
// Portable (Foundation only): shared by the Mac template picker / block-link
// menu and the iOS note editor.
import Foundation

/// Commands this feature sends into the web editor (see editor-web/src/notepower.js).
enum NotePowerEditorCommands {
    static func insertTemplate(_ rendered: RenderedNoteTemplate) -> WebEditorCommand {
        var arg: [String: Any] = ["text": rendered.text]
        if let cursor = rendered.cursorOffset { arg["cursor"] = cursor }
        return WebEditorCommand(name: "insertTemplate", argumentJSON: WebEditorJS.jsonLiteral(arg, fallback: "null"))
    }

    static func setCursor(offset: Int, docLength: Int) -> WebEditorCommand {
        WebEditorCommand(name: "setCursorOffset",
                         argumentJSON: WebEditorJS.jsonLiteral(["offset": offset, "docLength": docLength], fallback: "null"))
    }

    static func copyBlockLink(noteTitle: String) -> WebEditorCommand {
        WebEditorCommand(name: "copyBlockLink",
                         argumentJSON: WebEditorJS.jsonLiteral(["title": noteTitle], fallback: "null"))
    }

    static func embedContent(target: String, found: Bool, title: String, markdown: String) -> WebEditorCommand {
        let arg: [String: Any] = ["target": target, "found": found, "title": title, "markdown": markdown]
        return WebEditorCommand(name: "embedContent", argumentJSON: WebEditorJS.jsonLiteral(arg, fallback: "null"))
    }
}
