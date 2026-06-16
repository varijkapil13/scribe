//
//  EditorCalloutStyle.swift
//  Scribe
//
//  Shared callout type → tint + SF Symbol mapping for the native note editor
//  (``CodeEditNoteTextView`` / ``EditorCalloutDecorations``). Mirrors the old
//  editor's `MarkdownCallout` (see MarkdownEditorView.swift) so `> [!type]`
//  Obsidian callouts render with the same colour family + iconography.
//
//  ── SwiftPM build boundary ───────────────────────────────────────────────
//  This file imports ONLY AppKit (no CodeEditSourceEditor / CodeEditTextView),
//  so it stays in the SwiftPM `Scribe` target and is NOT in Package.swift's
//  exclude list. Keep it dependency-free so `swift test` can compile it.
//

import AppKit

/// Visual identity for an Obsidian-style callout (`> [!type] Title`). Maps a
/// type keyword to a tint colour (drawn as the left bar + soft panel fill) and
/// an SF Symbol shown beside the title.
///
/// The tint families intentionally match the old `MarkdownCallout` so notes
/// look identical across the legacy and native editors.
enum EditorCalloutStyle {

    /// The accent colour for a callout `kind` (case-insensitive). Falls back to
    /// the `note`/`info` blue for unknown types — matching Obsidian, which
    /// renders any unrecognised callout as a default note.
    static func tint(for kind: String) -> NSColor {
        switch kind.lowercased() {
        case "tip", "success", "hint", "check", "done":
            return .systemGreen
        case "warning", "caution", "attention":
            return .systemOrange
        case "danger", "error", "bug", "failure", "fail", "missing":
            return .systemRed
        case "important", "question", "help", "faq":
            return .systemPurple
        case "quote", "cite":
            return .tertiaryLabelColor
        case "example":
            return .systemIndigo
        case "todo":
            return .systemTeal
        default:
            // note / info / abstract / summary / tldr / …
            return .systemBlue
        }
    }

    /// The SF Symbol name for a callout `kind`. Returned names are all available
    /// on the deployment target (macOS 26) so the editor can always render one.
    static func symbolName(for kind: String) -> String {
        switch kind.lowercased() {
        case "tip", "hint":                       return "flame"
        case "success", "check", "done":          return "checkmark.circle"
        case "warning", "caution", "attention":   return "exclamationmark.triangle"
        case "danger", "error", "failure", "fail":return "exclamationmark.octagon"
        case "bug":                               return "ant"
        case "missing":                           return "questionmark.circle"
        case "important":                         return "exclamationmark.circle"
        case "question", "help", "faq":           return "questionmark.circle"
        case "quote", "cite":                     return "quote.opening"
        case "example":                           return "list.bullet"
        case "todo":                              return "checklist"
        case "abstract", "summary", "tldr":       return "doc.text"
        default:                                  return "info.circle"  // note / info
        }
    }
}
