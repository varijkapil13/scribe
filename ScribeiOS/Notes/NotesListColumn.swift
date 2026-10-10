// ScribeiOS/Notes/NotesListColumn.swift
//
// The note list for one destination: search, sort, new note / new from
// template / today's daily note, and per-note swipe actions and context menus
// (rename, move to a notebook, delete). The iPad split view drives selection;
// on iPhone rows push the editor.

import SwiftUI

struct NotesListColumn: View {
    let library: NotesLibraryModel
    let navigation: NotesNavigationModel
    let item: NotesSidebarItem
    /// iPhone stack (rows push) vs iPad split view (rows select).
    let compact: Bool

    @AppStorage("ios.notes.sortOrder") private var sortRaw = NoteSortOrder.updated.rawValue
    @State private var searchText = ""
    @State private var renaming: Note?
    @State private var renameText = ""
    @State private var moving: Note?
    @State private var deleting: Note?
    @State private var showTemplates = false

    private var sort: NoteSortOrder { NoteSortOrder(rawValue: sortRaw) ?? .updated }

    var body: some View {
        let notes = library.notes(for: item, search: searchText, sort: sort)
        return list(notes)
            .overlay {
                if notes.isEmpty { emptyState }
            }
            .navigationTitle(title)
            .searchable(text: $searchText, prompt: "Search notes")
            .toolbar { toolbarContent }
            .sheet(item: $moving) { note in
                NoteMoveSheet(library: library, note: note)
            }
            .sheet(isPresented: $showTemplates) {
                NoteTemplateSheet(mode: .newNote, library: NoteTemplateLibrary.iosCurrentVault(store: library.store)) { file, title in
                    createFromTemplate(file, title: title)
                }
            }
            .alert("Rename Note", isPresented: renameBinding) {
                TextField("Title", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    if let note = renaming { library.rename(noteId: note.id, to: renameText) }
                    renaming = nil
                }
            }
            .confirmationDialog(deleteTitle, isPresented: deleteBinding, titleVisibility: .visible) {
                Button("Delete Note", role: .destructive) {
                    if let note = deleting { delete(note) }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text(deleteMessage)
            }
    }

    @ViewBuilder
    private func list(_ notes: [Note]) -> some View {
        if compact {
            List {
                ForEach(notes) { note in
                    NavigationLink(value: NotesCompactRoute.note(note.id)) {
                        NoteListRow(note: note, notebookName: notebookLabel(for: note))
                    }
                    .modifier(rowActions(note))
                }
            }
            .listStyle(.plain)
        } else {
            List(selection: Binding(
                get: { navigation.selectedNoteId },
                set: { navigation.selectedNoteId = $0 }
            )) {
                ForEach(notes) { note in
                    NoteListRow(note: note, notebookName: notebookLabel(for: note))
                        .tag(note.id)
                        .modifier(rowActions(note))
                }
            }
            .listStyle(.plain)
        }
    }

    private func rowActions(_ note: Note) -> NoteRowActions {
        NoteRowActions(
            onRename: {
                renameText = note.title
                renaming = note
            },
            onMove: { moving = note },
            onDelete: { deleting = note }
        )
    }

    /// The notebook name shown on a row in cross-notebook lists.
    private func notebookLabel(for note: Note) -> String? {
        switch item {
        case .notebook, .inbox, .daily: return nil
        case .all, .tag: return note.notebookId.map { library.notebookName($0) }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Sort By", selection: $sortRaw) {
                    ForEach(NoteSortOrder.allCases) { order in
                        Text(order.label).tag(order.rawValue)
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    newNote()
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                Button {
                    showTemplates = true
                } label: {
                    Label("New from Template…", systemImage: "doc.badge.plus")
                }
                Button {
                    openToday()
                } label: {
                    Label("Today's Daily Note", systemImage: "calendar")
                }
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
            } primaryAction: {
                if item == .daily { openToday() } else { newNote() }
            }
        }
    }

    private var title: String {
        switch item {
        case .inbox: return "Inbox"
        case .all: return "All Notes"
        case .daily: return "Daily Notes"
        case .notebook(let id): return library.notebookName(id)
        case .tag(let tag): return "#\(tag)"
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if item == .daily {
            ContentUnavailableView {
                Label("No Daily Notes", systemImage: "calendar")
            } description: {
                Text("Start today's note to keep a running journal.")
            } actions: {
                Button("Open Today's Note") { openToday() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView {
                Label("No Notes", systemImage: "doc.text")
            } description: {
                Text("Tap the compose button to write a note.")
            } actions: {
                Button("New Note") { newNote() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Actions

    private func newNote() {
        guard let id = library.createNote(in: item) else { return }
        navigation.open(id, compact: compact)
    }

    private func openToday() {
        guard let id = library.todaysDailyNoteId() else { return }
        navigation.open(id, compact: compact)
    }

    private func createFromTemplate(_ file: NoteTemplateFile, title: String) {
        guard let library = NoteTemplateLibrary.iosCurrentVault(store: self.library.store) else { return }
        do {
            guard let id = try NoteTemplateActions.createNote(
                from: file, library: library, title: title,
                notebookId: item.notebookIdForNewNotes, store: self.library.store
            ) else {
                self.library.errorMessage = "The template \u{201C}\(file.name)\u{201D} couldn't be read."
                return
            }
            navigation.open(id, compact: compact)
        } catch {
            self.library.errorMessage = error.localizedDescription
        }
    }

    private func delete(_ note: Note) {
        if navigation.selectedNoteId == note.id { navigation.selectedNoteId = nil }
        navigation.compactPath.removeAll { $0 == .note(note.id) }
        library.delete(noteId: note.id)
    }

    // MARK: - Prompts

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var deleteTitle: String {
        "Delete \u{201C}\(deleting.map(NoteBrowserQuery.displayTitle) ?? "")\u{201D}?"
    }

    private var deleteMessage: String {
        guard let deleting else { return "" }
        let sessions = library.sessionCount(noteId: deleting.id)
        if sessions > 0 {
            return "Its file is removed from your notes folder, along with \(sessions) linked recording\(sessions == 1 ? "" : "s")."
        }
        return "Its file is removed from your notes folder."
    }
}

/// Swipe actions + context menu shared by both list styles.
struct NoteRowActions: ViewModifier {
    var onRename: () -> Void
    var onMove: () -> Void
    var onDelete: () -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                Button(action: onMove) {
                    Label("Move", systemImage: "folder")
                }
                .tint(.indigo)
            }
            .swipeActions(edge: .leading) {
                Button(action: onRename) {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.orange)
            }
            .contextMenu {
                Button(action: onRename) {
                    Label("Rename", systemImage: "pencil")
                }
                Button(action: onMove) {
                    Label("Move to Notebook…", systemImage: "folder")
                }
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
    }
}

struct NoteListRow: View {
    let note: Note
    var notebookName: String?

    private var isLocked: Bool { note.bodyExcerpt == LockedNoteEnvelope.excerptPlaceholder }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Locked")
                }
                Text(NoteBrowserQuery.displayTitle(note))
                    .font(.headline)
                    .lineLimit(1)
            }
            if !isLocked, let excerpt = note.bodyExcerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(note.updatedAt, format: .relative(presentation: .named))
                if let notebookName {
                    Text("·")
                    Label(notebookName, systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

/// Moves a note to a notebook (or the Inbox).
struct NoteMoveSheet: View {
    let library: NotesLibraryModel
    let note: Note
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    library.move(noteId: note.id, toNotebookId: nil)
                    dismiss()
                } label: {
                    HStack {
                        Label("Inbox", systemImage: "tray")
                        Spacer()
                        if note.notebookId == nil { Image(systemName: "checkmark") }
                    }
                }
                ForEach(library.notebookTree) { entry in
                    Button {
                        library.move(noteId: note.id, toNotebookId: entry.notebook.id)
                        dismiss()
                    } label: {
                        HStack {
                            Label(entry.notebook.name, systemImage: "folder")
                                .padding(.leading, CGFloat(entry.depth) * 14)
                            Spacer()
                            if note.notebookId == entry.notebook.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            .foregroundStyle(.primary)
            .navigationTitle("Move \u{201C}\(NoteBrowserQuery.displayTitle(note))\u{201D}")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
