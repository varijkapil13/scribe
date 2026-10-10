import Foundation

/// Turns text handed to Scribe from another app (the Services menu, a
/// `scribe://new-note` body) into note / task fields. Pure, unit-tested.
enum SelectionCaptureParser {

    /// Longest title derived from a selection; longer first lines are cut at
    /// a word boundary and get an ellipsis.
    nonisolated static let maxTitleLength = 120

    struct NoteFields: Equatable, Sendable {
        var title: String
        var body: String
    }

    struct TaskFields: Equatable, Sendable {
        var title: String
        var notes: String
    }

    /// A note from a selection: the title is the first non-blank line (with
    /// any Markdown heading / list marker stripped, truncated), the body the
    /// whole selection trimmed of surrounding blank lines. Nil for a blank
    /// selection.
    nonisolated static func noteFields(from selection: String) -> NoteFields? {
        let body = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let title = firstLine(of: body).map(cleanTitle) ?? ""
        return NoteFields(title: title, body: body)
    }

    /// A task from a selection: the title is the first non-blank line
    /// (cleaned, truncated); any further lines become the task's notes. When
    /// the first line was truncated, the full selection goes to the notes so
    /// nothing is lost. Nil for a blank selection.
    nonisolated static func taskFields(from selection: String) -> TaskFields? {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let first = firstLine(of: trimmed) else { return nil }
        let title = cleanTitle(first)
        guard !title.isEmpty else { return nil }

        let lines = trimmed.components(separatedBy: .newlines)
        let firstIndex = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? 0
        var notes = lines.dropFirst(firstIndex + 1)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripMarkers(first).count > maxTitleLength {
            notes = trimmed
        }
        return TaskFields(title: title, notes: notes)
    }

    // MARK: - Helpers

    nonisolated private static func firstLine(of text: String) -> String? {
        text.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Strips leading Markdown markers (`#`, `-`, `*`, `>`, `- [ ]`, `1.`)
    /// and surrounding whitespace.
    nonisolated static func stripMarkers(_ line: String) -> String {
        var s = Substring(line.trimmingCharacters(in: .whitespaces))
        var changed = true
        while changed {
            changed = false
            for marker in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "#", ">", "- ", "* ", "+ "] where s.hasPrefix(marker) {
                s = s.dropFirst(marker.count)
                s = Substring(s.trimmingCharacters(in: .whitespaces))
                changed = true
            }
        }
        // Ordered-list marker: digits followed by "." or ")" and a space.
        let digits = s.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty {
            let afterDigits = s.dropFirst(digits.count)
            if afterDigits.hasPrefix(". ") || afterDigits.hasPrefix(") ") {
                s = Substring(afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces))
            }
        }
        return String(s)
    }

    nonisolated private static func cleanTitle(_ line: String) -> String {
        truncate(stripMarkers(line))
    }

    /// Cuts `text` to at most `maxTitleLength` characters (ellipsis
    /// included), preferring the last word boundary.
    nonisolated static func truncate(_ text: String) -> String {
        guard text.count > maxTitleLength else { return text }
        let limit = maxTitleLength - 1
        let hard = String(text.prefix(limit))
        if let space = hard.lastIndex(of: " "), hard.distance(from: hard.startIndex, to: space) > limit / 2 {
            return String(hard[..<space]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return hard + "…"
    }
}
