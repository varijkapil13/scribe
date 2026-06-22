import SwiftUI

// MARK: - Expansion model

/// Shared, animatable expansion state for the notebook tree. Kept as an
/// `@Observable` rather than `@AppStorage`: `@AppStorage` writes propagate
/// out-of-transaction (via UserDefaults), so a toggle inside `withAnimation`
/// never animates the row insert/remove. A synchronous `@Observable` mutation
/// does. Still persisted to UserDefaults (same key) for launch-to-launch.
@MainActor
@Observable
final class NotebookExpansion {
    private static let storageKey = "expandedNotebookIds"
    private(set) var expanded: Set<String>

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? ""
        expanded = Set(raw.split(separator: ",").map(String.init))
    }

    func isExpanded(_ id: String) -> Bool { expanded.contains(id) }

    func setExpanded(_ id: String, _ value: Bool) {
        if value { expanded.insert(id) } else { expanded.remove(id) }
        UserDefaults.standard.set(expanded.sorted().joined(separator: ","), forKey: Self.storageKey)
    }
}

// MARK: - Root entry point

/// Renders the notebook hierarchy from `parentId` (nil = roots) using a
/// precomputed `NotebookTreeIndex`. Rows use the shared `SidebarRow` so folders
/// and notes look and behave exactly like the rest of the sidebar (full-width
/// selection + hover, whole-row click). Expansion is persisted and animates.
struct NotebookTreeView: View {
    let parentId: String?
    let index: NotebookTreeIndex
    @Binding var selection: MainSelection?
    /// Nesting depth, used to indent rows while keeping highlights full-width.
    var depth: Int = 0
    /// Shared, animatable expansion state (see `NotebookExpansion`).
    let expansion: NotebookExpansion

    var body: some View {
        // A VStack (not bare List rows): macOS `List` doesn't animate row
        // insertion, so the whole tree lives in one List cell where
        // `withAnimation` + `.transition` animate expansion reliably.
        VStack(alignment: .leading, spacing: 2) {
            ForEach(index.children(of: parentId)) { notebook in
                NotebookTreeRow(
                    notebook: notebook,
                    index: index,
                    selection: $selection,
                    depth: depth,
                    expansion: expansion
                )
            }
        }
    }
}

// MARK: - Folder row

private struct NotebookTreeRow: View {
    let notebook: Notebook
    let index: NotebookTreeIndex
    @Binding var selection: MainSelection?
    let depth: Int
    let expansion: NotebookExpansion

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isCreatingNote = false
    @State private var noteTitle = ""
    @State private var isCreatingChild = false
    @State private var childName = ""
    @State private var showDeleteFolderConfirm = false

    private var isExpanded: Bool { expansion.isExpanded(notebook.id) }
    private var hasChildren: Bool { index.hasChildren(notebook.id) }
    private var childNotes: [Note] { index.notes(in: notebook.id) }
    private var indent: CGFloat { CGFloat(depth) * DesignTokens.Spacing.lg }
    private var childIndent: CGFloat { CGFloat(depth + 1) * DesignTokens.Spacing.lg + DesignTokens.Spacing.sm }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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
                .padding(.leading, indent)
            } else {
                folderRow
            }

            if isExpanded {
                // Sub-notebooks (recursive) + note leaves, one level deeper.
                // Wrapped + transitioned so the whole subtree fades/slides open
                // under `withAnimation`.
                VStack(alignment: .leading, spacing: 2) {
                    NotebookTreeView(
                        parentId: notebook.id,
                        index: index,
                        selection: $selection,
                        depth: depth + 1,
                        expansion: expansion
                    )

                    ForEach(childNotes) { note in
                        NoteLeafRow(note: note, selection: $selection, depth: depth + 1)
                    }

                    if isCreatingNote {
                        InlineNameField(
                            text: $noteTitle,
                            placeholder: "New Note",
                            systemImage: "doc.text"
                        ) {
                            let title = noteTitle.trimmingCharacters(in: .whitespaces)
                            if let created = try? NoteStore.shared.createNote(
                                title: title.isEmpty ? "Untitled" : title,
                                notebookId: notebook.id
                            ) {
                                selection = .note(created.id)
                            }
                            isCreatingNote = false; noteTitle = ""
                        } onCancel: {
                            isCreatingNote = false; noteTitle = ""
                        }
                        .padding(.leading, childIndent)
                    }

                    if isCreatingChild {
                        InlineNameField(
                            text: $childName,
                            placeholder: "New Folder",
                            systemImage: "folder"
                        ) {
                            let name = childName.trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty {
                                _ = try? NoteStore.shared.createNotebook(name: name, parentId: notebook.id)
                            }
                            isCreatingChild = false; childName = ""
                        } onCancel: {
                            isCreatingChild = false; childName = ""
                        }
                        .padding(.leading, childIndent)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Folder label row

    private var folderRow: some View {
        SidebarRow(isSelected: false, indent: indent, action: { toggleExpansion() }) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(hasChildren ? 1 : 0)
                    .frame(width: 12)
                Label(notebook.name, systemImage: isExpanded ? "folder.fill" : "folder")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .contextMenu { contextMenuItems }
        .confirmationDialog(
            "Delete “\(notebook.name)”?",
            isPresented: $showDeleteFolderConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if case .note(let id) = selection,
                   childNotes.contains(where: { $0.id == id }) {
                    selection = .notes(.all)
                }
                try? NoteStore.shared.deleteNotebook(id: notebook.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteFolderMessage)
        }
    }

    /// Toggles expansion inside an animation so the sub-tree slides open and the
    /// chevron rotates (instant under Reduce Motion).
    private func toggleExpansion() {
        if reduceMotion {
            expansion.setExpanded(notebook.id, !isExpanded)
        } else {
            withAnimation(DesignTokens.Motion.gentle) {
                expansion.setExpanded(notebook.id, !isExpanded)
            }
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            expansion.setExpanded(notebook.id, true)
            isCreatingNote = true
            noteTitle = ""
        } label: {
            Label("New Note Here", systemImage: "square.and.pencil")
        }
        Button {
            expansion.setExpanded(notebook.id, true)
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
    var depth: Int = 0

    @State private var showDeleteConfirm = false
    @State private var sessionCount = 0

    private var isSelected: Bool {
        if case .note(let id) = selection { return id == note.id }
        return false
    }

    /// Indent so a note's icon aligns just past its folder's disclosure chevron.
    private var indent: CGFloat { CGFloat(depth) * DesignTokens.Spacing.lg + DesignTokens.Spacing.sm }

    var body: some View {
        SidebarRow(isSelected: isSelected, indent: indent, action: { selection = .note(note.id) }) {
            Label(note.title.isEmpty ? "Untitled" : note.title, systemImage: "doc.text")
                .lineLimit(1)
                .truncationMode(.tail)
        }
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
