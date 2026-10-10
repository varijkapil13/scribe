// Scribe/UI/Notes/PowerNotes/NoteEmbedContentProvider.swift
//
// `![[…]]` embeds for the CodeMirror editor (editor-web/src/notepower.js).
// Portable: compiled into the macOS app and the iOS target.
import Foundation

/// Answers the editor's `{type:"embedRequest", target}` message with the
/// `embedContent` command once the embedded note is resolved.
@MainActor
enum NoteEmbedEditorRequest {

    /// Returns true when `type` was an embed request (handled, even when
    /// malformed), false for every other message type.
    @discardableResult
    static func handle(type: String, body: [String: Any], coordinator: WebEditorCoordinator) -> Bool {
        guard type == "embedRequest" else { return false }
        guard let target = body["target"] as? String else { return true }
        let currentNoteId = coordinator.attachmentNoteId
        Task { [weak coordinator] in
            let payload = await NoteEmbedContentProvider.load(target: target, currentNoteId: currentNoteId)
            coordinator?.run(NotePowerEditorCommands.embedContent(
                target: target,
                found: payload.found,
                title: payload.title,
                markdown: payload.markdown
            ))
        }
        return true
    }
}

/// What an `![[…]]` embed shows in the editor.
struct NoteEmbedPayload: Equatable, Sendable {
    let found: Bool
    let title: String
    let markdown: String
}

/// Resolves embed targets against the note store (off the main actor).
enum NoteEmbedContentProvider {

    nonisolated static func load(target: String, currentNoteId: String?) async -> NoteEmbedPayload {
        await Task.detached(priority: .userInitiated) {
            payload(target: target, currentNoteId: currentNoteId, store: .shared)
        }.value
    }

    /// Pure-ish: the payload for `target` written in note `currentNoteId`.
    nonisolated static func payload(target: String, currentNoteId: String?, store: NoteStore) -> NoteEmbedPayload {
        let parsed = WikiLinkTarget.parse(target)
        let resolution: NoteEmbedResolution?
        if parsed.refersToSameNote {
            resolution = currentNoteId
                .flatMap { try? store.fetchNote(id: $0) }
                .map { NoteEmbedResolution(noteId: $0.id, title: $0.title, body: $0.body) }
        } else {
            resolution = NoteEmbedLookup.noteStore(store).resolve(target)
        }
        guard let resolution else {
            return NoteEmbedPayload(found: false, title: parsed.title, markdown: "")
        }
        let effective = NoteEmbedExpander.effectiveTarget(parsed, anchor: target, resolvedTitle: resolution.title)
        let displayTitle = title(for: effective, noteTitle: resolution.title)
        if !effective.hasFragment && resolution.noteId == currentNoteId {
            return NoteEmbedPayload(found: true, title: displayTitle, markdown: "*A note can't embed itself.*")
        }
        guard let markdown = NoteEmbedExpander.embeddedMarkdown(for: effective, resolution: resolution) else {
            return NoteEmbedPayload(found: false, title: displayTitle, markdown: "")
        }
        return NoteEmbedPayload(found: true, title: displayTitle, markdown: markdown)
    }

    nonisolated static func title(for target: WikiLinkTarget, noteTitle: String) -> String {
        let base = noteTitle.isEmpty ? "Untitled" : noteTitle
        if let heading = target.heading { return "\(base) \u{203A} \(heading)" }
        if let block = target.blockId { return "\(base) \u{203A} ^\(block)" }
        return base
    }
}
