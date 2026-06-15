import SwiftUI

// MARK: - Root entry point

/// Renders the full notebook hierarchy starting from `parentId` (nil = roots).
/// Pass the flat notebooks + notes arrays from the sidebar observer so the tree
/// never makes extra DB calls — all filtering is done in-memory per node.
struct NotebookTreeView: View {
    let parentId: String?
    let notebooks: [Notebook]
    let notes: [Note]
    @Binding var selection: MainSelection?

    /// IDs of currently expanded notebooks, persisted across launches.
    @AppStorage("expandedNotebookIds") private var expandedRaw: String = ""

    private var expanded: Set<String> {
        get { Set(expandedRaw.split(separator: ",").map(String.init)) }
    }

    private func setExpanded(_ id: String, _ value: Bool) {
        var s = expanded
        if value { s.insert(id) } else { s.remove(id) }
        expandedRaw = s.joined(separator: ",")
    }

    private var children: [Notebook] {
        notebooks
            .filter { $0.parentId == parentId }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        ForEach(children) { nb in
            NotebookTreeRow(
                notebook: nb,
                notebooks: notebooks,
                notes: notes,
                selection: $selection,
                isExpanded: expanded.contains(nb.id),
                onToggle: { setExpanded(nb.id, $0) }
            )
        }
    }
}

// MARK: - Folder row

private struct NotebookTreeRow: View {
    let notebook: Notebook
    let notebooks: [Notebook]
    let notes: [Note]
    @Binding var selection: MainSelection?
    let isExpanded: Bool
    let onToggle: (Bool) -> Void

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isCreatingNote = false
    @State private var noteTitle = ""
    @State private var isCreatingChild = false
    @State private var childName = ""
    @State private var showDeleteFolderConfirm = false

    private var hasChildren: Bool {
        notebooks.contains { $0.parentId == notebook.id } ||
        notes.contains { $0.notebookId == notebook.id && !$0.isDailyNote }
    }

    private var childNotes: [Note] {
        notes
            .filter { $0.notebookId == notebook.id && !$0.isDailyNote }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        Group {
            if isRenaming {
                InlineNameField(
                    text: $renameText,
                    placeholder: notebook.name,
                    systemImage: "folder"
                ) {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        var copy = notebook; copy.name = name
                        try? NoteStore.shared.updateNotebook(copy)
                    }
                    isRenaming = false
                } onCancel: {
                    isRenaming = false
                }
            } else {
                folderRow
            }

            if isExpanded {
                // Sub-notebooks (recursive)
                NotebookTreeView(
                    parentId: notebook.id,
                    notebooks: notebooks,
                    notes: notes,
                    selection: $selection
                )
                .padding(.leading, DesignTokens.Spacing.lg)

                // Note leaves
                ForEach(childNotes) { note in
                    NoteLeafRow(note: note, selection: $selection)
                        .padding(.leading, DesignTokens.Spacing.lg)
                }

                // Inline new-note field
                if isCreatingNote {
                    InlineNameField(
                        text: $noteTitle,
                        placeholder: "New Note",
                        systemImage: "doc.text"
                    ) {
                        let t = noteTitle.trimmingCharacters(in: .whitespaces)
                        if let created = try? NoteStore.shared.createNote(
                            title: t.isEmpty ? "Untitled" : t,
                            notebookId: notebook.id
                        ) {
                            selection = .note(created.id)
                        }
                        isCreatingNote = false; noteTitle = ""
                    } onCancel: {
                        isCreatingNote = false; noteTitle = ""
                    }
                    .padding(.leading, DesignTokens.Spacing.lg)
                }

                // Inline new-subfolder field
                if isCreatingChild {
                    InlineNameField(
                        text: $childName,
                        placeholder: "New Folder",
                        systemImage: "folder"
                    ) {
                        let n = childName.trimmingCharacters(in: .whitespaces)
                        if !n.isEmpty {
                            _ = try? NoteStore.shared.createNotebook(name: n, parentId: notebook.id)
                        }
                        isCreatingChild = false; childName = ""
                    } onCancel: {
                        isCreatingChild = false; childName = ""
                    }
                    .padding(.leading, DesignTokens.Spacing.lg)
                }
            }
        }
    }

    // MARK: - Folder label row

    private var folderRow: some View {
        HStack(spacing: 2) {
            // Disclosure chevron
            Button {
                onToggle(!isExpanded)
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .opacity(hasChildren ? 1 : 0)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Folder icon + name — clicking also toggles expansion
            Button {
                onToggle(!isExpanded)
            } label: {
                Label(notebook.name, systemImage: isExpanded ? "folder.fill" : "folder")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .contextMenu { contextMenuItems }
        .confirmationDialog(
            "Delete “\(notebook.name)”?",
            isPresented: $showDeleteFolderConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if case .note(let id) = selection,
                   notes.first(where: { $0.id == id })?.notebookId == notebook.id {
                    selection = .notes(.all)
                }
                try? NoteStore.shared.deleteNotebook(id: notebook.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteFolderMessage)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            onToggle(true)
            isCreatingNote = true
            noteTitle = ""
        } label: {
            Label("New Note Here", systemImage: "square.and.pencil")
        }
        Button {
            onToggle(true)
            isCreatingChild = true
            childName = ""
        } label: {
            Label("New Subfolder", systemImage: "folder.badge.plus")
        }
        Divider()
        Button {
            isRenaming = true
            renameText = notebook.name
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Divider()
        Button(role: .destructive) {
            showDeleteFolderConfirm = true
        } label: {
            Label("Delete Folder", systemImage: "trash")
        }
    }

    private var deleteFolderMessage: String {
        let count = childNotes.count
        guard count > 0 else { return "This empty folder will be deleted." }
        let plural = count == 1 ? "note" : "notes"
        return "The folder will be deleted. Its \(count) \(plural) won’t be deleted — they’ll move to your Inbox."
    }
}

// MARK: - Note leaf row

struct NoteLeafRow: View {
    let note: Note
    @Binding var selection: MainSelection?

    @State private var showDeleteConfirm = false
    @State private var sessionCount = 0

    private var isSelected: Bool {
        if case .note(let id) = selection { return id == note.id }
        return false
    }

    var body: some View {
        Button {
            selection = .note(note.id)
        } label: {
            Label(note.title.isEmpty ? "Untitled" : note.title, systemImage: "doc.text")
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.vertical, DesignTokens.Spacing.xxs)
        .padding(.horizontal, 6)
        .background(Color.accentColor.opacity(isSelected ? 0.15 : 0))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                selection = .note(note.id)
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }
            Divider()
            Button(role: .destructive) {
                // Deleting a note cascades to its recordings; confirm first
                // and tell the user how many will go with it.
                sessionCount = (try? NoteStore.shared.sessionCount(forNoteId: note.id)) ?? 0
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Delete “\(note.title.isEmpty ? "Untitled" : note.title)”?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if isSelected { selection = .notes(.all) }
                try? NoteStore.shared.deleteNote(id: note.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteMessage: String {
        if sessionCount > 0 {
            let plural = sessionCount == 1 ? "recording" : "recordings"
            return "This note and its \(sessionCount) \(plural) — including transcripts, summaries, and action items — will be permanently deleted. Tasks you created from it are kept."
        }
        return "This note will be permanently deleted. This can’t be undone."
    }
}
