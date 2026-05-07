// Scribe/UI/Notes/NoteListView.swift
import SwiftUI

struct NoteListView: View {
    @StateObject private var vm = NoteListViewModel()
    @Binding var selectedNoteId: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search notes…", text: $vm.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color(.windowBackgroundColor).opacity(0.5))

            Divider()

            if vm.filteredNotes.isEmpty {
                ContentUnavailableView(
                    "No notes",
                    systemImage: "note.text",
                    description: Text("Press ⌘N to create your first note.")
                )
            } else {
                List(vm.filteredNotes, selection: $selectedNoteId) { note in
                    NoteRowView(note: note)
                        .tag(note.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                vm.deleteNote(id: note.id)
                                if selectedNoteId == note.id { selectedNoteId = nil }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                .listStyle(.sidebar)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let note = vm.createNote()
                    selectedNoteId = note?.id
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New note (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

private struct NoteRowView: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title.isEmpty ? "(Untitled)" : note.title)
                .font(.body)
                .lineLimit(1)
            Text(note.body.isEmpty ? "No additional text" : note.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}
