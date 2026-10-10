import Foundation

// Pure planning behind the iOS Quick Capture sheet (Action button, Control
// Center, Siri "Quick Capture"): turns what was typed into a note or a task.
// Portable and Foundation-only so the macOS `swift test` job covers it
// (ScribeQuickCapturePlanTests); the iOS sheet executes the plan.

/// What a Quick Capture creates.
enum ScribeQuickCaptureKind: String, CaseIterable, Sendable, Hashable {
    case note
    case task

    var title: String {
        switch self {
        case .note: return "Note"
        case .task: return "Task"
        }
    }
}

/// The note or task a capture should create.
enum ScribeQuickCapturePlan: Equatable {
    case note(title: String, body: String)
    /// `parsed` is the quick-add parse of the title line (`#tag`, `!high`,
    /// "tomorrow 5pm", "every monday", …); `notes` the extra text.
    case task(parsed: QuickAddParser.ParsedQuickAdd, notes: String)

    /// The plan for the typed `title` / `body`, or nil when nothing was
    /// typed.
    ///
    /// - Note: a blank title takes the body's first non-blank line, the rest
    ///   stays the body.
    /// - Task: the title line is parsed with `QuickAddParser`; when the parse
    ///   leaves no title (only tokens were typed) the raw line is the title.
    nonisolated static func make(
        kind: ScribeQuickCaptureKind,
        title rawTitle: String,
        body rawBody: String,
        now: Date,
        calendar: Calendar
    ) -> ScribeQuickCapturePlan? {
        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            let split = splitFirstLine(body)
            title = split.first
            body = split.rest
        }
        guard !title.isEmpty || !body.isEmpty else { return nil }

        switch kind {
        case .note:
            return .note(title: title, body: body)
        case .task:
            var parsed = QuickAddParser.parse(title, now: now, calendar: calendar)
            let parsedTitle = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
            parsed.title = parsedTitle.isEmpty ? title : parsedTitle
            return .task(parsed: parsed, notes: body)
        }
    }

    /// The first non-blank line (trimmed) and everything after it (trimmed).
    nonisolated static func splitFirstLine(_ text: String) -> (first: String, rest: String) {
        var lines = text.components(separatedBy: .newlines)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        guard let first = lines.first else { return ("", "") }
        lines.removeFirst()
        return (
            first.trimmingCharacters(in: .whitespaces),
            lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
