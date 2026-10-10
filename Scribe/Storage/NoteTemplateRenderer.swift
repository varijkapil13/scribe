// Scribe/Storage/NoteTemplateRenderer.swift
import Foundation

/// Values a note template's `{{variables}}` are filled from.
struct NoteTemplateContext: Sendable {
    var date: Date
    var title: String
    var meetingTitle: String?
    var meetingAttendees: [String]
    var clipboard: String?
    var locale: Locale
    var timeZone: TimeZone

    init(
        date: Date,
        title: String,
        meetingTitle: String? = nil,
        meetingAttendees: [String] = [],
        clipboard: String? = nil,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) {
        self.date = date
        self.title = title
        self.meetingTitle = meetingTitle
        self.meetingAttendees = meetingAttendees
        self.clipboard = clipboard
        self.locale = locale
        self.timeZone = timeZone
    }
}

/// A rendered template: the text plus where `{{cursor}}` was (UTF-16 offset,
/// which is also a CodeMirror document position).
struct RenderedNoteTemplate: Equatable, Sendable {
    var text: String
    var cursorOffset: Int?
}

/// Fills a note template's variables. Pure.
///
/// Supported (names case-insensitive, whitespace inside the braces allowed):
///
///     {{date}}                 2026-10-10
///     {{date:EEEE d MMMM}}     any DateFormatter pattern
///     {{time}}                 14:05          ({{time:h:mm a}} also works)
///     {{weekday}}              Saturday
///     {{title}}                the note's title
///     {{meeting.title}}        the calendar event / meeting title
///     {{meeting.attendees}}    "Ana, Ben" (comma-separated)
///     {{clipboard}}            the clipboard's text
///     {{cursor}}               removed; marks where the caret goes
///
/// Unknown variables are left in place verbatim.
enum NoteTemplateRenderer {

    nonisolated private static let variableRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-z][A-Za-z0-9_.]*)\s*(?::([^}]*))?\}\}"#)
    }()

    nonisolated static func render(_ template: String, context: NoteTemplateContext) -> RenderedNoteTemplate {
        let ns = template as NSString
        let matches = variableRegex.matches(in: template, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return RenderedNoteTemplate(text: template, cursorOffset: nil) }

        var out = ""
        var outLength = 0   // UTF-16 length of `out`
        var cursor: Int?
        var last = 0
        for m in matches {
            let before = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += before
            outLength += (before as NSString).length
            last = NSMaxRange(m.range)

            let name = ns.substring(with: m.range(at: 1)).lowercased()
            let argument: String? = m.range(at: 2).location == NSNotFound
                ? nil
                : ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)

            if name == "cursor" {
                if cursor == nil { cursor = outLength }
                continue
            }
            let replacement = value(for: name, argument: argument, context: context)
                ?? ns.substring(with: m.range)
            out += replacement
            outLength += (replacement as NSString).length
        }
        out += ns.substring(from: last)
        return RenderedNoteTemplate(text: out, cursorOffset: cursor)
    }

    /// The value of one variable, or nil when it isn't a known variable.
    nonisolated static func value(for name: String, argument: String?, context: NoteTemplateContext) -> String? {
        switch name {
        case "date":
            return format(context.date, pattern: nonEmpty(argument) ?? "yyyy-MM-dd", context: context)
        case "time":
            return format(context.date, pattern: nonEmpty(argument) ?? "HH:mm", context: context)
        case "weekday":
            return format(context.date, pattern: "EEEE", context: context)
        case "title":
            return context.title
        case "meeting.title":
            return context.meetingTitle ?? ""
        case "meeting.attendees":
            return context.meetingAttendees
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        case "clipboard":
            return context.clipboard ?? ""
        default:
            return nil
        }
    }

    /// `rendered` as a note body is stored: leading / trailing newlines
    /// trimmed (the vault codec trims them on read), with the cursor offset
    /// shifted and clamped to match.
    nonisolated static func trimmedForNoteBody(_ rendered: RenderedNoteTemplate) -> RenderedNoteTemplate {
        let ns = rendered.text as NSString
        var start = 0
        while start < ns.length, isNewlineUnit(ns.character(at: start)) { start += 1 }
        var end = ns.length
        while end > start, isNewlineUnit(ns.character(at: end - 1)) { end -= 1 }
        let text = ns.substring(with: NSRange(location: start, length: end - start))
        let cursor = rendered.cursorOffset.map { min(max(0, $0 - start), end - start) }
        return RenderedNoteTemplate(text: text, cursorOffset: cursor)
    }

    /// A daily note seeded from a template while the user had already
    /// started typing in the draft editor: the draft follows the template.
    nonisolated static func appendingDraft(_ draft: String, toSeed seed: String) -> String {
        let trimmedSeed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSeed.isEmpty else { return draft }
        guard !draft.isEmpty else { return seed }
        let base = seed.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        return base + "\n\n" + draft
    }

    nonisolated private static func isNewlineUnit(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D
    }

    nonisolated private static func format(_ date: Date, pattern: String, context: NoteTemplateContext) -> String {
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.timeZone = context.timeZone
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    nonisolated private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
