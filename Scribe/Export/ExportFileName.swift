// Scribe/Export/ExportFileName.swift
import Foundation

/// Sanitises a note title into a default filename for `NSSavePanel`.
///
/// Lives outside `NoteDetailView` so the sanitisation rules — illegal
/// characters, fallback when the title is empty, whitespace handling —
/// can be asserted directly without running through the AppKit panel.
enum ExportFileName {

    /// Characters macOS / Finder won't accept in a filename, plus a few
    /// (`*`, `%`, `?`, `|`, `<`, `>`, `"`) that are technically legal on
    /// HFS+ / APFS but trip every other operating system the user might
    /// sync the file to. Splitting on this set and rejoining with `-`
    /// preserves word boundaries the user can still read.
    private static let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")

    /// - Parameters:
    ///   - title: the user-visible title; may be empty or whitespace-only.
    ///   - fallback: filename to use when `title` has no usable characters
    ///     left after sanitisation. Default `"Untitled-note"`.
    /// - Returns: a filename without an extension. Callers add `.md` etc.
    static func safe(_ title: String, fallback: String = "Untitled-note") -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback }

        let withoutIllegal = trimmed
            .components(separatedBy: illegal)
            .joined(separator: "-")
        let collapsed = withoutIllegal.replacingOccurrences(of: " ", with: "_")
        // Collapse runs of dashes/underscores left behind when adjacent
        // characters were illegal — "a/?b" → "a--b" → "a-b" reads better.
        let collapsedDashes = collapsed.replacingOccurrences(
            of: "-+", with: "-", options: .regularExpression
        )

        let finalCandidate = collapsedDashes.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return finalCandidate.isEmpty ? fallback : finalCandidate
    }
}
