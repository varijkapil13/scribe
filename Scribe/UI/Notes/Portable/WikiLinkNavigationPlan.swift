// Scribe/UI/Notes/Portable/WikiLinkNavigationPlan.swift
//
// What tapping a `[[wiki link]]` should do — the same rules as the Mac's
// `NoteDetailViewModel.handleWikiLinkNavigate` (same-note heading / block
// links scroll; other notes open, scrolled to the heading / block), plus a
// `.missing` outcome so the iPhone / iPad editor can offer to create the note.
// Pure (resolution is injected); unit-tested in WikiLinkNavigationPlanTests.

import Foundation

enum WikiLinkNavigationPlan: Equatable, Sendable {
    /// Scroll the open note to this 1-based line.
    case scrollCurrent(line: Int)
    /// Open another note, then scroll to this 1-based line when non-nil.
    case open(noteId: String, line: Int?)
    /// No note has this title; offer to create one.
    case missing(title: String)
    /// Nothing to do (a same-note link to a heading / block that isn't there).
    case stay

    /// - Parameters:
    ///   - anchor: the link text between the brackets (as the editor posts it).
    ///   - currentNoteId / currentBody: the note the link was tapped in.
    ///   - resolve: anchor → the linked note's id and title, or nil.
    ///   - bodyOf: note id → its markdown body (to find heading / block lines).
    nonisolated static func plan(
        anchor: String,
        currentNoteId: String?,
        currentBody: String,
        resolve: (String) -> (id: String, title: String)?,
        bodyOf: (String) -> String?
    ) -> WikiLinkNavigationPlan {
        let parsed = WikiLinkTarget.parse(anchor)
        if parsed.refersToSameNote {
            guard let index = NoteBlockReference.lineIndex(for: parsed, in: currentBody) else { return .stay }
            return .scrollCurrent(line: index + 1)
        }
        guard let resolved = resolve(anchor) else {
            return parsed.title.isEmpty ? .stay : .missing(title: parsed.title)
        }
        let target = NoteEmbedExpander.effectiveTarget(parsed, anchor: anchor, resolvedTitle: resolved.title)
        if resolved.id == currentNoteId {
            guard let index = NoteBlockReference.lineIndex(for: target, in: currentBody) else { return .stay }
            return .scrollCurrent(line: index + 1)
        }
        guard target.hasFragment, let body = bodyOf(resolved.id),
              let index = NoteBlockReference.lineIndex(for: target, in: body) else {
            return .open(noteId: resolved.id, line: nil)
        }
        return .open(noteId: resolved.id, line: index + 1)
    }
}
