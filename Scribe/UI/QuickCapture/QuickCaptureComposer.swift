import CoreGraphics
import Foundation

// Pure logic behind the Quick Capture panel: what each mode does with the
// typed text, the preview chips for a task, the line appended to today's
// daily note, and where the panel sits on screen. No AppKit, no stores, so
// it is covered by plain XCTest (QuickCaptureComposerTests).

// MARK: - Mode

/// What the Quick Capture panel does with the text on save.
enum QuickCaptureMode: String, CaseIterable, Identifiable, Sendable {
    /// A new note in the Inbox. First line is the title.
    case note
    /// A new task. The first line is parsed by `QuickAddParser`
    /// (`tmr 5pm #tag +Project !high`); further lines become its notes.
    case task
    /// A timestamped bullet at the end of today's daily note.
    case appendToDaily

    /// Remembers the last-used mode between invocations.
    static let defaultsKey = "quickCaptureLastMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .note:          return String(localized: "Note")
        case .task:          return String(localized: "Task")
        case .appendToDaily: return String(localized: "Today")
        }
    }

    /// Longer name for VoiceOver and the help tag.
    var accessibilityTitle: String {
        switch self {
        case .note:          return String(localized: "New note")
        case .task:          return String(localized: "New task")
        case .appendToDaily: return String(localized: "Append to today's daily note")
        }
    }

    var systemImage: String {
        switch self {
        case .note:          return "doc.text"
        case .task:          return "checklist"
        case .appendToDaily: return "calendar.badge.plus"
        }
    }

    var placeholder: String {
        switch self {
        case .note:          return String(localized: "Title, then more lines for the body")
        case .task:          return "Buy milk tmr 5pm #errands +Home !high"
        case .appendToDaily: return String(localized: "Add a line to today's daily note")
        }
    }

    /// The digit used with ⌘ to switch to this mode (⌘1 / ⌘2 / ⌘3).
    var shortcutDigit: Int {
        switch self {
        case .note:          return 1
        case .task:          return 2
        case .appendToDaily: return 3
        }
    }

    nonisolated static func mode(forShortcutDigit digit: Int) -> QuickCaptureMode? {
        allCases.first { $0.shortcutDigit == digit }
    }

    /// The mode to open with: the last one used, or `.note`.
    nonisolated static func restored(from rawValue: String?) -> QuickCaptureMode {
        rawValue.flatMap(QuickCaptureMode.init(rawValue:)) ?? .note
    }
}

// MARK: - Save request

/// Everything needed to persist one capture, decided before any store is
/// touched. `QuickCaptureSaver` turns it into a note, task or daily entry.
enum QuickCaptureRequest: Equatable, Sendable {
    case note(title: String, body: String)
    case task(QuickCaptureTaskDraft)
    case appendToDaily(text: String)
}

/// A task ready to insert. `projectName` is resolved to an id by the saver;
/// an unknown name falls back to the Inbox, like the task list's quick add.
struct QuickCaptureTaskDraft: Equatable, Sendable {
    var title: String
    var notes: String
    var projectName: String?
    var priority: TodoTask.Priority?
    var dueAt: Date?
    var tags: [String]
}

// MARK: - Preview chips

/// One piece of metadata recognised in a task, shown under the text field.
struct QuickCaptureChip: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case due
        case priority
        case tag
        case project
        /// A `+Project` that doesn't match an existing project.
        case unknownProject
    }

    let kind: Kind
    let text: String

    var id: String { "\(kind)-\(text)" }

    var systemImage: String {
        switch kind {
        case .due:            return "calendar"
        case .priority:       return "flag.fill"
        case .tag:            return "number"
        case .project:        return "folder"
        case .unknownProject: return "tray"
        }
    }
}

// MARK: - Composer

enum QuickCaptureComposer {

    /// Longest first line used verbatim as a note title. Longer first lines
    /// are shortened for the title and the full text goes into the body, so
    /// nothing typed is lost and file names stay sensible.
    static let maxTitleLength = 80

    // MARK: Request

    /// Builds the save request for `text` in `mode`, or nil when there is
    /// nothing to save (blank text, or a task whose title is only metadata).
    ///
    /// - Parameter parse: Task-line parser. The app passes
    ///   `QuickAddParser.parse(_:)`; tests pass a detector-free variant.
    nonisolated static func request(
        mode: QuickCaptureMode,
        text: String,
        parse: (String) -> QuickAddParser.ParsedQuickAdd
    ) -> QuickCaptureRequest? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch mode {
        case .note:
            let parts = noteParts(from: trimmed)
            return .note(title: parts.title, body: parts.body)

        case .task:
            let lines = splitFirstLine(trimmed)
            let parsed = parse(lines.first)
            guard !parsed.title.isEmpty else { return nil }
            return .task(QuickCaptureTaskDraft(
                title: parsed.title,
                notes: lines.rest,
                projectName: parsed.projectName,
                priority: parsed.priority,
                dueAt: parsed.dueAt,
                tags: parsed.tags
            ))

        case .appendToDaily:
            return .appendToDaily(text: trimmed)
        }
    }

    /// Whether Save should be enabled for `text` in `mode`.
    nonisolated static func canSave(
        mode: QuickCaptureMode,
        text: String,
        parse: (String) -> QuickAddParser.ParsedQuickAdd
    ) -> Bool {
        request(mode: mode, text: text, parse: parse) != nil
    }

    // MARK: Note

    /// Title and body for a note. The first line is the title (a leading
    /// markdown `#` heading marker is dropped); the remaining lines are the
    /// body. A first line longer than ``maxTitleLength`` is shortened at a
    /// word boundary for the title and the whole text becomes the body.
    nonisolated static func noteParts(from text: String) -> (title: String, body: String) {
        let lines = splitFirstLine(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var title = lines.first
        // "## Plan" is a heading; "#idea" is a tag and stays.
        let hashes = title.prefix(while: { $0 == "#" }).count
        if hashes > 0, title.dropFirst(hashes).first == " " {
            title = String(title.dropFirst(hashes))
        }
        title = title.trimmingCharacters(in: .whitespaces)

        if title.count <= maxTitleLength {
            return (title, lines.rest)
        }
        let full = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (shortenedTitle(title), full)
    }

    /// `title` cut to at most ``maxTitleLength`` characters at the last word
    /// boundary, with an ellipsis.
    nonisolated static func shortenedTitle(_ title: String) -> String {
        guard title.count > maxTitleLength else { return title }
        let prefix = String(title.prefix(maxTitleLength - 1))
        let cut: String
        if let space = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: space) > maxTitleLength / 2 {
            cut = String(prefix[prefix.startIndex..<space])
        } else {
            cut = prefix
        }
        return cut.trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// Splits `text` into its first line and the (trimmed) rest.
    nonisolated static func splitFirstLine(_ text: String) -> (first: String, rest: String) {
        guard let newline = text.firstIndex(where: { $0.isNewline }) else {
            return (text.trimmingCharacters(in: .whitespaces), "")
        }
        let first = String(text[text.startIndex..<newline]).trimmingCharacters(in: .whitespaces)
        let rest = String(text[text.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (first, rest)
    }

    // MARK: Daily note

    /// The markdown appended to the daily note for `text` captured at `date`:
    /// a bullet starting with the 24-hour time, continuation lines indented
    /// so they stay part of the same list item.
    ///
    ///     - 14:05 Call Anna about the offsite
    ///       bring the budget sheet
    nonisolated static func dailyEntry(text: String, at date: Date, timeZone: TimeZone) -> String {
        let lines = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let first = lines.first ?? ""
        var out = "- \(timeString(date, timeZone: timeZone)) \(first)"
        for line in lines.dropFirst() {
            out += line.isEmpty ? "\n" : "\n  \(line)"
        }
        return out
    }

    /// `HH:mm` in `timeZone`, independent of the user's locale settings.
    nonisolated static func timeString(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// `body` with `entry` appended. Trailing whitespace is normalised; when
    /// the body already ends in a list item the entry joins that list,
    /// otherwise it starts a new paragraph. Always ends with one newline.
    nonisolated static func appendingDailyEntry(_ entry: String, to body: String) -> String {
        var trimmed = body
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        if trimmed.isEmpty { return entry + "\n" }

        let lastLine = trimmed.components(separatedBy: "\n").last ?? ""
        let separator = isListLine(lastLine) ? "\n" : "\n\n"
        return trimmed + separator + entry + "\n"
    }

    /// Bullet / task-list / indented-continuation lines.
    nonisolated static func isListLine(_ line: String) -> Bool {
        if line.hasPrefix("  ") && !line.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        return line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    // MARK: Dictation

    /// The field text while dictating: what was typed before dictation
    /// started, followed by the dictated text.
    nonisolated static func merging(typed: String, dictated: String) -> String {
        let spoken = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return typed }
        if typed.isEmpty { return spoken }
        if let last = typed.last, last.isWhitespace { return typed + spoken }
        return typed + " " + spoken
    }

    // MARK: Chips

    /// Preview chips for a parsed task line, in display order: due date,
    /// priority, project, tags.
    ///
    /// - Parameters:
    ///   - knownProjects: Existing project names. A `+Project` not in the
    ///     list is shown as "Inbox" (where the task will actually land).
    ///     Pass nil when the list is unknown to show the name as typed.
    nonisolated static func chips(
        for parsed: QuickAddParser.ParsedQuickAdd,
        knownProjects: [String]?,
        now: Date,
        calendar: Calendar
    ) -> [QuickCaptureChip] {
        var chips: [QuickCaptureChip] = []
        if let due = parsed.dueAt {
            chips.append(QuickCaptureChip(kind: .due, text: dueText(due, now: now, calendar: calendar)))
        }
        if let priority = parsed.priority {
            chips.append(QuickCaptureChip(kind: .priority, text: priority.rawValue))
        }
        if let project = parsed.projectName {
            if let known = knownProjects,
               !known.contains(where: { $0.caseInsensitiveCompare(project) == .orderedSame }) {
                chips.append(QuickCaptureChip(kind: .unknownProject, text: "Inbox (no project \u{201C}\(project)\u{201D})"))
            } else {
                let display = knownProjects?.first { $0.caseInsensitiveCompare(project) == .orderedSame } ?? project
                chips.append(QuickCaptureChip(kind: .project, text: display))
            }
        }
        for tag in parsed.tags {
            chips.append(QuickCaptureChip(kind: .tag, text: tag))
        }
        return chips
    }

    /// "Today", "Tomorrow", "Yesterday" or a short date, plus the time when
    /// it isn't midnight (a date-only phrase like "friday").
    nonisolated static func dueText(_ date: Date, now: Date, calendar: Calendar) -> String {
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
                  calendar.isDate(date, inSameDayAs: tomorrow) {
            day = "Tomorrow"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(date, inSameDayAs: yesterday) {
            day = "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = calendar.locale ?? Locale.current
            formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
            day = formatter.string(from: date)
        }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard (parts.hour ?? 0) != 0 || (parts.minute ?? 0) != 0 else { return day }
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.locale = calendar.locale ?? Locale.current
        time.timeStyle = .short
        time.dateStyle = .none
        return "\(day) \(time.string(from: date))"
    }

    // MARK: Confirmation

    /// Toast text after a successful save. `resolvedProject` is the name
    /// of the project a task actually landed in (nil = Inbox).
    nonisolated static func confirmation(for request: QuickCaptureRequest, resolvedProject: String?) -> String {
        switch request {
        case .note:
            return "Note saved to Inbox"
        case .task:
            if let resolvedProject { return "Task added to \(resolvedProject)" }
            return "Task added to Inbox"
        case .appendToDaily:
            return "Added to today's daily note"
        }
    }
}

// MARK: - Panel geometry

enum QuickCapturePanelGeometry {

    /// Panel origin centred horizontally on `visibleFrame`, with the panel's
    /// top edge a third of the way down (where Spotlight sits), clamped so
    /// the panel stays fully on screen.
    nonisolated static func origin(panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        let x = visibleFrame.midX - panelSize.width / 2
        let top = visibleFrame.maxY - visibleFrame.height / 3
        var y = top - panelSize.height
        y = max(visibleFrame.minY, min(y, visibleFrame.maxY - panelSize.height))
        let clampedX = max(visibleFrame.minX, min(x, visibleFrame.maxX - panelSize.width))
        return CGPoint(x: clampedX.rounded(), y: y.rounded())
    }
}
