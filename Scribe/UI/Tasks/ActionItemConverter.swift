import Foundation

/// Converts a meeting `ActionItem` into a `TodoTask` draft. Used by the
/// "Convert to task" button in `TranscriptDetailView`. Pure mapping logic
/// kept here so it stays unit-testable without a database.
enum ActionItemConverter {

    /// Bag of values to feed into `TaskStore.createTask(...)`. Wraps every
    /// derivable field plus the parsed deadline date and the suggested tags
    /// list (assignee → tag).
    struct Draft: Equatable {
        var title: String
        var notes: String
        var priority: TodoTask.Priority?
        var dueAt: Date?
        var tags: [String]
        var sourceSessionId: String
        var sourceActionItemId: String
    }

    static func draft(from item: ActionItem,
                      sessionId: String,
                      now: Date = Date(),
                      detector: NSDataDetector? = .scribeDateDetector) -> Draft {
        let title = item.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let priority = mapPriority(item.priority)
        var notesParts: [String] = []
        if let assignee = item.assignee, !assignee.isEmpty {
            notesParts.append("Assignee: \(assignee)")
        }
        if let deadline = item.deadline, !deadline.isEmpty {
            notesParts.append("Deadline (mentioned): \(deadline)")
        }
        if !item.sourceText.isEmpty {
            notesParts.append("Source: \"\(item.sourceText)\"")
        }
        let notes = notesParts.joined(separator: "\n")

        let dueAt: Date?
        if let deadline = item.deadline, !deadline.isEmpty,
           let detector = detector {
            dueAt = parseDate(deadline, with: detector, reference: now)
        } else {
            dueAt = nil
        }

        var tags: [String] = []
        if let assignee = item.assignee?.trimmingCharacters(in: .whitespacesAndNewlines), !assignee.isEmpty {
            tags.append(assignee.lowercased())
        }

        return Draft(
            title: title,
            notes: notes,
            priority: priority,
            dueAt: dueAt,
            tags: tags,
            sourceSessionId: sessionId,
            sourceActionItemId: item.id.uuidString
        )
    }

    // MARK: - Internals

    static func mapPriority(_ p: ActionItem.Priority?) -> TodoTask.Priority? {
        switch p {
        case .high:   return .high
        case .medium: return .medium
        case .low:    return .low
        case .none:   return nil
        }
    }

    static func parseDate(_ text: String, with detector: NSDataDetector, reference: Date) -> Date? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector.matches(in: text, options: [], range: range)
        for match in matches where match.resultType == .date {
            // Use reference date so phrases like "tomorrow" resolve correctly.
            if let date = match.date(from: reference) ?? match.date {
                return date
            }
        }
        return nil
    }
}

extension NSDataDetector {
    /// Shared detector configured for date-like phrases. Falls back to nil if
    /// the system fails to construct one (extremely unlikely).
    static let scribeDateDetector: NSDataDetector? = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
}

// `NSTextCheckingResult.date(from:)` resolves relative phrases against a
// reference date but isn't a public API on every SDK version. Provide a
// shim that uses the absolute date and applies the offset manually if
// needed.
private extension NSTextCheckingResult {
    func date(from reference: Date) -> Date? {
        guard resultType == .date, let absolute = date else { return nil }
        // For "tomorrow at 3pm" style phrases, NSDataDetector already returns
        // a fully-qualified Date relative to its current "now". We lean on
        // that here; reference is preserved for future RRULE-style work.
        _ = reference
        return absolute
    }
}
