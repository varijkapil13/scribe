// Scribe/UI/Notes/PowerNotes/NotePowerEditorBridge.swift
import AppKit
import Foundation

/// Native side of editor-web/src/notepower.js. `WebMarkdownEditor.Coordinator`
/// forwards the message types it doesn't handle itself here:
///
///   {type:"embedRequest", target}       → answers with the "embedContent" command
///   {type:"copyText", text, label?}     → puts `text` on the pasteboard
///   {type:"insertTemplateRequest"}      → template picker, then "insertTemplate"
@MainActor
enum NotePowerEditorBridge {

    /// Returns true when `type` was one of this feature's messages.
    @discardableResult
    static func handle(type: String, body: [String: Any], coordinator: WebMarkdownEditor.Coordinator) -> Bool {
        switch type {
        case "embedRequest":
            return NoteEmbedEditorRequest.handle(type: type, body: body, coordinator: coordinator)
        case "copyText":
            guard let text = body["text"] as? String, !text.isEmpty else { return true }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            AppState.shared.notify((body["label"] as? String) ?? "Copied")
            return true
        case "insertTemplateRequest":
            NoteTemplatePanelController.shared.presentInsert(into: coordinator)
            return true
        default:
            return false
        }
    }
}

// `NoteEmbedPayload` / `NoteEmbedContentProvider` live in
// NoteEmbedContentProvider.swift (portable, shared with the iOS editor).
