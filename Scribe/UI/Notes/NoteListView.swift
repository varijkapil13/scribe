// Scribe/UI/Notes/NoteListView.swift
import SwiftUI

struct NoteListView: View {
    @StateObject private var vm: NoteListViewModel
    @Binding var selectedNoteId: String?

    init(scope: NoteListScope = .all, selectedNoteId: Binding<String?>) {
        _vm = StateObject(wrappedValue: NoteListViewModel(scope: scope))
        _selectedNoteId = selectedNoteId
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Search ────────────────────────────────────────────────────
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                TextField("Search notes…", text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !vm.searchText.isEmpty {
                    Button {
                        vm.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.small)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs + 2)
            .background(DesignTokens.Palette.surfaceElevated)

            Divider()

            if vm.filteredNotes.isEmpty {
                VStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: vm.searchText.isEmpty ? "note.text" : "magnifyingglass")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.quaternary)
                    Text(vm.searchText.isEmpty ? "No notes yet" : "No results")
                        .font(DesignTokens.Typography.section)
                        .foregroundStyle(.secondary)
                    if vm.searchText.isEmpty {
                        Text("Press ⌘N to create your first note.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(vm.filteredNotes, selection: $selectedNoteId) { note in
                    NoteRowView(note: note)
                        .tag(note.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                vm.deleteNote(id: note.id)
                                if selectedNoteId == note.id { selectedNoteId = nil }
                            } label: {
                                Label("Delete Note", systemImage: "trash")
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

// MARK: - Note row

private struct NoteRowView: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs + 1) {
            Text(note.title.isEmpty ? "Untitled" : note.title)
                .font(.body)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(1)

            HStack(spacing: DesignTokens.Spacing.xs) {
                Text(note.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()

                if !note.body.isEmpty {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)

                    Text(note.body.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }
}
