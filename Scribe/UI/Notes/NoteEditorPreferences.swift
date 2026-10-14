// Scribe/UI/Notes/NoteEditorPreferences.swift
import AppKit
import SwiftUI

// MARK: - Page width

/// Reading-measure presets for the note body. The web editor centres its text
/// column at one of these widths instead of letting prose run full-bleed.
enum NotePageWidth: String, CaseIterable, Identifiable {
    case full
    case regular
    case wide

    var id: String { rawValue }

    /// Target column width in points. `.full` is unbounded (the editor fills the
    /// available width); for the finite presets the column tracks the view width
    /// below `measure` and the gutter grows symmetrically above it.
    var measure: CGFloat {
        switch self {
        case .full:    return .infinity   // no cap — fill the available width
        case .regular: return 620
        case .wide:    return 860
        }
    }

    /// Whether this preset caps the editor to a centered column. `.full` does not.
    var capsWidth: Bool { self != .full }

    var label: String {
        switch self {
        case .full:    return "Full Width"
        case .regular: return "Regular Width"
        case .wide:    return "Wide Width"
        }
    }

    var symbol: String {
        switch self {
        case .full:    return "arrow.left.and.right"
        case .regular: return "rectangle.portrait"
        case .wide:    return "rectangle"
        }
    }

    /// The next option — used by the toggle shortcut so a single keystroke
    /// cycles through the presets.
    var toggled: NotePageWidth {
        switch self {
        case .full:    return .regular
        case .regular: return .wide
        case .wide:    return .full
        }
    }

    /// AppStorage key shared by the editor and the spine's View-menu hook.
    static let storageKey = "noteEditor.pageWidth"
}

// MARK: - Per-note typeface

/// Body typeface for a note. `Serif` is the bundled Newsreader (the default);
/// `System` is SF Pro, `Mono` SF Mono.
enum NoteTypeface: String, CaseIterable, Identifiable {
    case system
    case serif
    case mono

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .serif:  return "Serif"
        case .mono:   return "Mono"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "textformat"
        case .serif:  return "textformat.alt"
        case .mono:   return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Body size in the web editor; Newsreader runs small next to SF.
    var editorFontSize: CGFloat {
        switch self {
        case .serif:          return 18
        case .system, .mono:  return 16
        }
    }

    static let defaultTypeface: NoteTypeface = .serif

    /// AppStorage key for the default typeface applied to notes that have no
    /// explicit per-note choice yet.
    static let defaultStorageKey = "noteEditor.defaultTypeface"

    /// Per-note AppStorage key. The per-note choice is persisted app-side keyed
    /// by note id. (Frontmatter persistence — `setExtra("font", …)` — is the
    /// preferred home once the Phase-0 frontmatter passthrough lands; see the
    /// integration hook notes.)
    static func storageKey(forNoteId id: String) -> String {
        "noteEditor.font.\(id)"
    }
}
