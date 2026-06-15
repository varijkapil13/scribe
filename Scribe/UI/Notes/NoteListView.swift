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
                // Shared EmptyStateView (one component, one tone across the app)
                // rather than a bespoke stack.
                EmptyStateView(
                    systemImage: vm.searchText.isEmpty ? "note.text" : "magnifyingglass",
                    title: vm.searchText.isEmpty ? "No notes yet" : "No results",
                    message: vm.searchText.isEmpty
                        ? "Create a note with ⌘N, or record a meeting to start one automatically."
                        : "No notes match “\(vm.searchText)”.",
                    actionTitle: vm.searchText.isEmpty ? "Create your first note" : nil,
                    action: vm.searchText.isEmpty ? {
                        let note = vm.createNote()
                        selectedNoteId = note?.id
                    } : nil
                )
            } else {
                List(vm.filteredNotes, selection: $selectedNoteId) { note in
                    NoteRowView(note: note)
                        .tag(note.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                vm.requestDelete(id: note.id)
                            } label: {
                                Label("Delete Note", systemImage: "trash")
                            }
                        }
                }
                .listStyle(.sidebar)
            }
        }
        .confirmationDialog(
            deletionTitle(for: vm.pendingDelete),
            isPresented: Binding(
                get: { vm.pendingDelete != nil },
                set: { newValue in if !newValue { vm.pendingDelete = nil } }
            ),
            presenting: vm.pendingDelete
        ) { request in
            Button("Delete", role: .destructive) {
                let deletedId = vm.confirmDelete(request)
                if let id = deletedId, selectedNoteId == id { selectedNoteId = nil }
            }
            Button("Cancel", role: .cancel) { vm.pendingDelete = nil }
        } message: { request in
            Text(deletionMessage(for: request))
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let note = vm.createNote()
                    selectedNoteId = note?.id
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New note")
            }
        }
    }

    private func deletionTitle(for request: DeleteNoteRequest?) -> String {
        DeletionPrompt.title(for: request)
    }

    private func deletionMessage(for request: DeleteNoteRequest) -> String {
        DeletionPrompt.message(for: request)
    }
}

/// Pure, testable copy-builder for the delete-note confirmation dialog.
/// Lives at file scope so the dialog text — particularly the "X linked
/// recording(s) … will also be deleted" warning — can be asserted without
/// instantiating a SwiftUI hierarchy.
enum DeletionPrompt {
    static func title(for request: DeleteNoteRequest?) -> String {
        let displayName = (request?.noteTitle.isEmpty ?? true)
            ? "this note"
            : "\u{201C}\(request!.noteTitle)\u{201D}"
        return "Delete \(displayName)?"
    }

    static func message(for request: DeleteNoteRequest) -> String {
        if request.sessionCount == 0 {
            return "This note will be permanently deleted."
        }
        let recordingLabel = request.sessionCount == 1 ? "recording" : "recordings"
        return "This note has \(request.sessionCount) linked \(recordingLabel) — the recording\(request.sessionCount == 1 ? "" : "s"), transcript segments, summary, action items, and entities will also be permanently deleted. Tasks you converted from this recording will keep their text but lose the source link."
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

                if let excerpt = note.bodyExcerpt, !excerpt.isEmpty {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)

                    Text(excerpt)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }
}
