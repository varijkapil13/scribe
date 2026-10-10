import Foundation

// Portable logic behind the iOS shell's universal Search tab and its
// "New Task" sheet. Lives in Scribe/App so `swift test` covers it
// (ScribeMobileRoutingTests); also compiled into the ScribeiOS target.
// Foundation + the shared stores only.

/// Notes + tasks matching one query.
struct ScribeMobileSearchResults: Equatable {
    var notes: [Note]
    var tasks: [TodoTask]

    var isEmpty: Bool { notes.isEmpty && tasks.isEmpty }

    nonisolated static var empty: ScribeMobileSearchResults {
        ScribeMobileSearchResults(notes: [], tasks: [])
    }
}

/// Universal search over the notes FTS index and the tasks FTS index.
enum ScribeMobileSearch {
    /// Maximum hits shown per kind.
    nonisolated static let defaultLimit = 50

    /// The trimmed query, or nil when it is blank (blank shows the
    /// suggestions state rather than every note).
    nonisolated static func normalizedQuery(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Runs `query` against both stores. A failing store contributes no hits
    /// instead of failing the whole search.
    nonisolated static func run(
        query raw: String,
        noteStore: NoteStore,
        taskStore: TaskStore,
        limit: Int
    ) -> ScribeMobileSearchResults {
        guard let query = normalizedQuery(raw) else { return .empty }
        let notes = (try? noteStore.searchNotes(query: query)) ?? []
        let tasks = (try? taskStore.searchTasks(query: query, includeCompleted: true, limit: limit)) ?? []
        return ScribeMobileSearchResults(
            notes: Array(notes.prefix(limit)),
            tasks: orderedTasks(tasks)
        )
    }

    /// Open tasks first, completed ones after; the store's relevance order
    /// is kept within each group.
    nonisolated static func orderedTasks(_ tasks: [TodoTask]) -> [TodoTask] {
        tasks.filter { !$0.isCompleted } + tasks.filter { $0.isCompleted }
    }
}

/// Creates tasks from free text the way the Tasks quick-add field does
/// (`#tag +project !priority` + natural dates via `QuickAddParser`).
enum ScribeMobileTaskCreation {
    /// Creates a task from quick-add text; nil (and nothing written) when
    /// `raw` is blank.
    @discardableResult
    nonisolated static func createTask(fromQuickAdd raw: String, store: TaskStore) throws -> TodoTask? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let parsed = QuickAddParser.parse(text)
        let title = parsed.title.isEmpty ? text : parsed.title
        return try store.createTask(
            title: title,
            priority: parsed.priority,
            dueAt: parsed.dueAt,
            recurrenceRule: parsed.recurrenceRule,
            tags: parsed.tags,
            startAt: parsed.startAt,
            scheduleBucket: parsed.scheduleBucket ?? .anytime,
            estimatedMinutes: parsed.estimatedMinutes
        )
    }

    /// A `scribe://new-task?due=` value → date: the strict deep-link formats
    /// first, then the quick-add natural-language parser — the same order as
    /// the Mac's `ScribeEntryRouter`.
    nonisolated static func dueDate(fromLinkValue raw: String?, now: Date, calendar: Calendar) -> Date? {
        guard let raw else { return nil }
        return ScribeDeepLink.dueDate(from: raw, now: now, calendar: calendar)
            ?? QuickAddParser.parse(raw, now: now, calendar: calendar).dueAt
    }
}
