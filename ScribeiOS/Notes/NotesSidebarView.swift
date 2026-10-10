// ScribeiOS/Notes/NotesSidebarView.swift
//
// Notes destinations: Inbox / All Notes / Daily Notes, notebooks (nested,
// with create / rename / delete) and tags. On iPad this is the first column of
// the split view (`selection` binding); on iPhone it is the root of the stack
// (`onSelect` pushes the list).

import SwiftUI

struct NotesSidebarView: View {
    let library: NotesLibraryModel
    /// iPad: the selected destination. nil on iPhone.
    let selection: Binding<NotesSidebarItem?>?
    /// iPhone: push `item`'s list. nil on iPad.
    let onSelect: ((NotesSidebarItem) -> Void)?

    @State private var notebookPrompt: NotebookPrompt?
    @State private var promptText = ""
    @State private var notebookToDelete: Notebook?

    init(library: NotesLibraryModel, selection: Binding<NotesSidebarItem?>?,
         onSelect: ((NotesSidebarItem) -> Void)?) {
        self.library = library
        self.selection = selection
        self.onSelect = onSelect
    }

    /// Create / rename prompt state.
    enum NotebookPrompt: Identifiable, Equatable {
        case create(parentId: String?)
        case rename(Notebook)

        var id: String {
            switch self {
            case .create(let parent): return "create:\(parent ?? "")"
            case .rename(let notebook): return "rename:\(notebook.id)"
            }
        }
    }

    var body: some View {
        list
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        promptText = ""
                        notebookPrompt = .create(parentId: nil)
                    } label: {
                        Label("New Notebook", systemImage: "folder.badge.plus")
                    }
                }
            }
            .alert(promptTitle, isPresented: promptBinding) {
                TextField("Name", text: $promptText)
                Button("Cancel", role: .cancel) {}
                Button(promptConfirmTitle) { commitPrompt() }
            }
            .confirmationDialog(
                "Delete \u{201C}\(notebookToDelete?.name ?? "")\u{201D}?",
                isPresented: deleteBinding,
                titleVisibility: .visible
            ) {
                Button("Delete Notebook", role: .destructive) {
                    if let notebook = notebookToDelete {
                        if selection?.wrappedValue == .notebook(notebook.id) { selection?.wrappedValue = .all }
                        library.deleteNotebook(notebook)
                    }
                    notebookToDelete = nil
                }
                Button("Cancel", role: .cancel) { notebookToDelete = nil }
            } message: {
                Text("Its notes move to the Inbox.")
            }
    }

    @ViewBuilder
    private var list: some View {
        if let selection {
            List(selection: selection) { sections }
                .listStyle(.sidebar)
        } else {
            List { sections }
                .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private var sections: some View {
        Section {
            row(.inbox, title: "Inbox", systemImage: "tray")
            row(.all, title: "All Notes", systemImage: "doc.text")
            row(.daily, title: "Daily Notes", systemImage: "calendar")
        } footer: {
            Text(IOSVaultSyncController.shared.statusText)
        }

        Section("Notebooks") {
            if library.notebooks.isEmpty {
                Text("No notebooks yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(library.notebookTree) { entry in
                row(.notebook(entry.notebook.id), title: entry.notebook.name, systemImage: "folder")
                    .padding(.leading, CGFloat(entry.depth) * 14)
                    .contextMenu { notebookMenu(entry.notebook) }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            notebookToDelete = entry.notebook
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            promptText = entry.notebook.name
                            notebookPrompt = .rename(entry.notebook)
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
            }
        }

        if !library.tags.isEmpty {
            Section("Tags") {
                ForEach(library.tags, id: \.self) { tag in
                    row(.tag(tag), title: "#\(tag)", systemImage: "number")
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: NotesSidebarItem, title: String, systemImage: String) -> some View {
        let label = HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text("\(library.count(for: item))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        if let onSelect {
            Button {
                onSelect(item)
            } label: {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            label.tag(item)
        }
    }

    @ViewBuilder
    private func notebookMenu(_ notebook: Notebook) -> some View {
        Button {
            promptText = ""
            notebookPrompt = .create(parentId: notebook.id)
        } label: {
            Label("New Notebook Inside", systemImage: "folder.badge.plus")
        }
        Button {
            promptText = notebook.name
            notebookPrompt = .rename(notebook)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button(role: .destructive) {
            notebookToDelete = notebook
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Prompts

    private var promptTitle: String {
        switch notebookPrompt {
        case .rename?: return "Rename Notebook"
        default: return "New Notebook"
        }
    }

    private var promptConfirmTitle: String {
        switch notebookPrompt {
        case .rename?: return "Rename"
        default: return "Create"
        }
    }

    private var promptBinding: Binding<Bool> {
        Binding(get: { notebookPrompt != nil }, set: { if !$0 { notebookPrompt = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { notebookToDelete != nil }, set: { if !$0 { notebookToDelete = nil } })
    }

    private func commitPrompt() {
        guard let prompt = notebookPrompt else { return }
        notebookPrompt = nil
        switch prompt {
        case .create(let parentId):
            library.createNotebook(named: promptText, parentId: parentId)
        case .rename(let notebook):
            library.renameNotebook(notebook, to: promptText)
        }
    }
}
