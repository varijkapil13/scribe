import SwiftUI

/// Where a search hit navigates.
enum ScribeSearchDestination: Hashable {
    case note(String)
    case task(String)
}

/// The Search tab (`Tab(role: .search)`): one field over the notes FTS index
/// and the tasks FTS index (`ScribeMobileSearch`). ⌘F / ⌘K and
/// `scribe://search?q=` land here through the navigator.
struct UniversalSearchScreen: View {
    @Environment(ScribeiOSNavigator.self) private var navigator: ScribeiOSNavigator?

    @State private var query = ""
    @State private var results = ScribeMobileSearchResults.empty
    @State private var path: [ScribeSearchDestination] = []
    @FocusState private var searchFocused: Bool
    /// The navigator focus request already handled (so re-showing the tab
    /// doesn't reset the stack).
    @State private var adoptedFocusToken = 0

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !results.notes.isEmpty {
                    Section("Notes") {
                        ForEach(results.notes) { note in
                            NavigationLink(value: ScribeSearchDestination.note(note.id)) {
                                SearchNoteRow(note: note)
                            }
                            .scribeNoteRowAffordances(noteId: note.id, title: note.title)
                        }
                    }
                }
                if !results.tasks.isEmpty {
                    Section("Tasks") {
                        ForEach(results.tasks) { task in
                            NavigationLink(value: ScribeSearchDestination.task(task.id)) {
                                SearchTaskRow(task: task)
                            }
                            .hoverEffect(.highlight)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay { emptyState }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Notes and tasks")
            .searchFocused($searchFocused)
            .autocorrectionDisabled()
            .navigationDestination(for: ScribeSearchDestination.self) { destination in
                switch destination {
                case .note(let id): NoteEditorScreen(noteId: id)
                case .task(let id): TaskDetailScreen(taskId: id)
                }
            }
            // Debounced: typing quickly runs one search, not one per key.
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                runSearch()
            }
            .onAppear { adoptNavigatorQuery() }
            .onChange(of: navigator?.searchFocusToken) { _, _ in adoptNavigatorQuery() }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if ScribeMobileSearch.normalizedQuery(query) == nil {
            ContentUnavailableView(
                "Search Scribe",
                systemImage: "magnifyingglass",
                description: Text("Find notes and tasks by any word in them.")
            )
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    private func runSearch() {
        results = ScribeMobileSearch.run(
            query: query,
            noteStore: .shared,
            taskStore: .shared,
            limit: ScribeMobileSearch.defaultLimit
        )
    }

    /// Takes over a query posted by a link / shortcut and focuses the field.
    private func adoptNavigatorQuery() {
        guard let navigator, navigator.searchFocusToken != adoptedFocusToken else { return }
        adoptedFocusToken = navigator.searchFocusToken
        if !navigator.searchQuery.isEmpty {
            query = navigator.searchQuery
        }
        path = []
        searchFocused = true
    }
}

private struct SearchNoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.title.isEmpty ? "Untitled" : note.title)
                .font(.headline)
                .lineLimit(1)
            if let excerpt = note.bodyExcerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the note")
    }
}

private struct SearchTaskRow: View {
    let task: TodoTask

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(task.isCompleted ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                if let due = task.dueAt {
                    Text(due, format: .dateTime.weekday().month().day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(task.isCompleted ? "Completed" : "Open"))
        .accessibilityHint("Opens the task")
    }
}
