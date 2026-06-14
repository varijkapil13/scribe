import Combine
import Foundation
import SwiftUI

/// iOS Notes surface — a live list of notes over the shared `NoteStore`, with a
/// baseline editor (title + markdown body). The rich decoration editor is a
/// later milestone; this is the M1 "competent create/edit" path.
struct NotesScreen: View {
    @StateObject private var model = NotesViewModel()
    @State private var searchText: String = ""
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(filtered) { note in
                    NavigationLink(value: note.id) {
                        NoteRow(note: note)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { model.delete(note) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay { if model.notes.isEmpty { emptyState } }
            .navigationTitle("Notes")
            .searchable(text: $searchText, prompt: "Search notes")
            .navigationDestination(for: String.self) { NoteEditorScreen(noteId: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // Create on tap (not in body) and push into the editor.
                    Button {
                        let id = model.createNoteId()
                        if !id.isEmpty { path.append(id) }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New note")
                }
            }
        }
    }

    private var filtered: [Note] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.notes }
        return model.notes.filter {
            $0.title.lowercased().contains(q) || ($0.bodyExcerpt ?? "").lowercased().contains(q)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No notes",
            systemImage: "doc.text",
            description: Text("Tap the compose button to write your first note.")
        )
    }
}

private struct NoteRow: View {
    let note: Note
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.title.isEmpty ? "Untitled" : note.title)
                .font(.headline)
                .lineLimit(1)
            if let excerpt = note.bodyExcerpt, !excerpt.isEmpty {
                Text(excerpt).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(note.updatedAt, format: .relative(presentation: .named))
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

/// Baseline note editor: title + raw markdown body in a `TextEditor`. Loads the
/// full body from disk on appear (the list publisher only carries excerpts) and
/// autosaves on change (debounced) and on disappear.
struct NoteEditorScreen: View {
    let noteId: String

    @StateObject private var model: NoteEditorModel

    init(noteId: String) {
        self.noteId = noteId
        _model = StateObject(wrappedValue: NoteEditorModel(noteId: noteId))
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Title", text: $model.title)
                .font(.title2.weight(.semibold))
                .textFieldStyle(.plain)
                .padding(.horizontal)
                .padding(.top, 8)
            Divider().padding(.top, 8)
            TextEditor(text: $model.body)
                .font(.body)
                .padding(.horizontal, 12)
        }
        .navigationTitle(model.title.isEmpty ? "Untitled" : model.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.title) { model.markDirty() }
        .onChange(of: model.body) { model.markDirty() }
        .onDisappear { model.flush() }
    }
}

// MARK: - View models

@MainActor
final class NotesViewModel: ObservableObject {
    @Published private(set) var notes: [Note] = []

    private let store: NoteStore
    private var cancellable: AnyCancellable?

    init(store: NoteStore = .shared) {
        self.store = store
        cancellable = store.observeNotes()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] in self?.notes = $0 })
    }

    /// Creates an empty note and returns its id so the toolbar `NavigationLink`
    /// can push straight into the editor.
    func createNoteId() -> String {
        (try? store.createNote(title: "", body: ""))?.id ?? ""
    }

    func delete(_ note: Note) {
        try? store.deleteNote(id: note.id)
    }
}

@MainActor
final class NoteEditorModel: ObservableObject {
    @Published var title: String = ""
    @Published var body: String = ""

    private let noteId: String
    private let store: NoteStore
    private var note: Note?
    private var dirty = false
    private var saveTask: Task<Void, Never>?

    init(noteId: String, store: NoteStore = .shared) {
        self.noteId = noteId
        self.store = store
        load()
    }

    private func load() {
        guard let note = try? store.fetchNote(id: noteId) else { return }
        self.note = note
        self.title = note.title
        self.body = note.body
    }

    func markDirty() {
        dirty = true
        // Debounced autosave; flush() also covers teardown.
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        guard dirty, var note else { return }
        note.title = title
        note.body = body
        let tags = (try? store.tags(for: noteId)) ?? []
        try? store.updateNote(note, tags: tags)
        self.note = note
        dirty = false
    }
}
