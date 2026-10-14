// Scribe/UI/Notes/NoteListView.swift
import SwiftUI

struct NoteListView: View {
    @StateObject private var vm: NoteListViewModel
    @Binding var selectedNoteId: String?
    /// When set, the header offers All / Unfiled tabs bound to it.
    var scopeChoice: Binding<NoteListScope>?
    @Environment(\.undoManager) private var undoManager
    @FocusState private var listFocused: Bool

    init(scope: NoteListScope = .all,
         selectedNoteId: Binding<String?>,
         scopeChoice: Binding<NoteListScope>? = nil) {
        _vm = StateObject(wrappedValue: NoteListViewModel(scope: scope))
        _selectedNoteId = selectedNoteId
        self.scopeChoice = scopeChoice
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let scopeChoice {
                NoteScopeTabs(activeScope: scopeChoice)
                    .padding(.horizontal, DesignTokens.Notes.listInset + 4)
                    .padding(.bottom, DesignTokens.Spacing.sm)
            }
            searchField
                .padding(.horizontal, DesignTokens.Notes.listInset)
                .padding(.bottom, DesignTokens.Spacing.sm)

            if !vm.hasLoaded {
                Spacer()
            } else if vm.filteredNotes.isEmpty {
                EmptyStateView(
                    systemImage: vm.searchText.isEmpty ? "note.text" : "magnifyingglass",
                    title: vm.searchText.isEmpty ? "No notes yet" : "No results",
                    message: vm.searchText.isEmpty
                        ? "Create a note with ⌘N, or record a meeting to start one automatically."
                        : "No notes match “\(vm.searchText)”.",
                    actionTitle: vm.searchText.isEmpty ? "Create your first note" : nil,
                    action: vm.searchText.isEmpty ? { createNote() } : nil
                )
            } else {
                noteRows
            }
        }
        .background(DesignTokens.Palette.ground)
        .confirmationDialog(
            deletionTitle(for: vm.pendingDelete),
            isPresented: Binding(
                get: { vm.pendingDelete != nil },
                set: { newValue in if !newValue { vm.pendingDelete = nil } }
            ),
            presenting: vm.pendingDelete
        ) { request in
            Button("Delete", role: .destructive) {
                let deletedId = vm.confirmDelete(request, undoManager: undoManager)
                if let id = deletedId, selectedNoteId == id { selectedNoteId = nil }
            }
            Button("Cancel", role: .cancel) { vm.pendingDelete = nil }
        } message: { request in
            Text(deletionMessage(for: request))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Text(vm.title)
                .font(DesignTokens.Notes.listTitle)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .lineLimit(1)
            Text(Self.countLabel(vm.filteredNotes.count))
                .font(DesignTokens.Notes.listCount)
                .foregroundStyle(DesignTokens.Palette.textTertiary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: DesignTokens.Spacing.xs)
            Button(action: createNote) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .frame(width: 30, height: 24)
                    .background(Capsule(style: .continuous).fill(DesignTokens.Palette.quietFill))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("New note")
            .accessibilityLabel("New note")
        }
        .padding(.leading, DesignTokens.Notes.listInset + 4)
        .padding(.trailing, DesignTokens.Notes.listInset)
        .padding(.top, DesignTokens.Spacing.md)
        .padding(.bottom, DesignTokens.Spacing.sm)
        .accessibilityElement(children: .contain)
    }

    private var searchField: some View {
        HStack(spacing: DesignTokens.Spacing.xs + 2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.Palette.textTertiary)
            TextField("Search notes…", text: $vm.searchText)
                .textFieldStyle(.plain)
                .font(DesignTokens.Notes.rowSnippet)
            if !vm.searchText.isEmpty {
                Button {
                    vm.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(DesignTokens.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm + 2)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(DesignTokens.Palette.quietFill))
    }

    // MARK: Rows

    private var noteRows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(vm.filteredNotes) { note in
                        Button {
                            selectedNoteId = note.id
                            listFocused = true
                        } label: {
                            NoteRowView(note: note, isSelected: selectedNoteId == note.id)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedNoteId == note.id ? .isSelected : [])
                        .id(note.id)
                        .contextMenu {
                            OpenNoteInNewWindowButton(noteId: note.id)
                            NoteLinkMenuItems(noteId: note.id)
                            Divider()
                            Button(role: .destructive) {
                                vm.requestDelete(id: note.id)
                            } label: {
                                Label("Delete Note", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, DesignTokens.Notes.listInset)
                .padding(.bottom, DesignTokens.Spacing.lg)
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                moveSelection(direction)
                if let id = selectedNoteId {
                    proxy.scrollTo(id)
                }
            }
            .onKeyPress(keys: [.home, .end, .pageUp, .pageDown]) { press in
                guard jumpSelection(press.key) else { return .ignored }
                if let id = selectedNoteId {
                    proxy.scrollTo(id)
                }
                return .handled
            }
            .onDeleteCommand {
                if let id = selectedNoteId { vm.requestDelete(id: id) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Notes")
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let notes = vm.filteredNotes
        guard !notes.isEmpty else { return }
        let current = selectedNoteId.flatMap { id in notes.firstIndex { $0.id == id } }
        let next: Int
        switch direction {
        case .up:   next = max(0, (current ?? notes.count) - 1)
        case .down: next = min(notes.count - 1, (current ?? -1) + 1)
        default:    return
        }
        selectedNoteId = notes[next].id
    }

    private static let pageStep = 10

    private func jumpSelection(_ key: KeyEquivalent) -> Bool {
        let notes = vm.filteredNotes
        guard !notes.isEmpty else { return false }
        let current = selectedNoteId.flatMap { id in notes.firstIndex { $0.id == id } }
        let next: Int
        switch key {
        case .home:     next = 0
        case .end:      next = notes.count - 1
        case .pageUp:   next = max(0, (current ?? 0) - Self.pageStep)
        case .pageDown: next = min(notes.count - 1, (current ?? -1) + Self.pageStep)
        default:        return false
        }
        selectedNoteId = notes[next].id
        return true
    }

    private func createNote() {
        let note = vm.createNote()
        selectedNoteId = note?.id
    }

    nonisolated static func countLabel(_ count: Int) -> String {
        count == 1 ? "1 note" : "\(count) notes"
    }

    private func deletionTitle(for request: DeleteNoteRequest?) -> String {
        DeletionPrompt.title(for: request)
    }

    private func deletionMessage(for request: DeleteNoteRequest) -> String {
        DeletionPrompt.message(for: request)
    }
}

/// "All / Unfiled" text tabs for the list header.
private struct NoteScopeTabs: View {
    @Binding var activeScope: NoteListScope

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            tab("All", isActive: isAll) { activeScope = .all }
            tab("Unfiled", isActive: !isAll) { activeScope = .inbox }
            Spacer()
        }
    }

    private var isAll: Bool {
        if case .all = activeScope { return true } else { return false }
    }

    private func tab(_ title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? DesignTokens.Palette.textPrimary : DesignTokens.Palette.textTertiary)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous)
                    .fill(isActive ? DesignTokens.Palette.quietFill : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
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
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.title.isEmpty ? "Untitled" : note.title)
                .font(DesignTokens.Notes.rowTitle)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .lineLimit(1)

            if let excerpt = note.bodyExcerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(DesignTokens.Notes.rowSnippet)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .lineLimit(1)
            }

            Text(NoteRowDate.label(for: note.updatedAt))
                .font(DesignTokens.Notes.rowDate)
                .foregroundStyle(DesignTokens.Palette.textTertiary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignTokens.Notes.rowHorizontalPadding)
        .padding(.vertical, DesignTokens.Notes.rowVerticalPadding)
        .noteRowSelectedCard(isSelected, isHovered: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
    }
}

/// Row date: time for today, "Yesterday", "Oct 12", or "Oct 12, 2025".
enum NoteRowDate {
    nonisolated static func label(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
