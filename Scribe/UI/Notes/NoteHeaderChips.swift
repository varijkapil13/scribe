// Scribe/UI/Notes/NoteHeaderChips.swift
import Combine
import SwiftUI

/// Chips under a note's title: its notebook (quiet) and its tags (accent),
/// with an inline field to add tags.
struct NoteHeaderChips: View {
    let tags: [String]
    /// nil hides the notebook chip (daily notes have no notebook).
    var notebookId: Binding<String?>?
    let suggestions: (String) -> [String]
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void

    @State private var draft = ""
    @State private var isAdding = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            WrapHStack(spacing: 6, lineSpacing: 6) {
                if let notebookId {
                    NotebookChip(selectedNotebookId: notebookId)
                }
                ForEach(tags, id: \.self) { tag in
                    NoteTagChip(tag: tag) { onRemove(tag) }
                }
                addControl
            }
            if fieldFocused, !liveSuggestions.isEmpty {
                suggestionRow
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note tags")
    }

    @ViewBuilder
    private var addControl: some View {
        if isAdding || !draft.isEmpty {
            TextField("Tag", text: $draft)
                .textFieldStyle(.plain)
                .font(DesignTokens.Notes.chip)
                .frame(width: 90)
                .focused($fieldFocused)
                .onSubmit { commitDraft() }
                .onChange(of: draft) { _, newValue in
                    if newValue.contains(",") || newValue.contains(" ") {
                        for part in newValue.split(whereSeparator: { $0 == "," || $0 == " " }) {
                            onAdd(String(part))
                        }
                        draft = ""
                    }
                }
                .onChange(of: fieldFocused) { _, focused in
                    if !focused {
                        commitDraft()
                        isAdding = false
                    }
                }
                .onKeyPress(.delete) {
                    if draft.isEmpty, let last = tags.last {
                        onRemove(last)
                        return .handled
                    }
                    return .ignored
                }
                .onExitCommand {
                    draft = ""
                    fieldFocused = false
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(DesignTokens.Palette.quietFill))
                .accessibilityLabel("Add tag")
                .accessibilityHint("Type a tag and press Return to add it")
        } else {
            Button {
                isAdding = true
                fieldFocused = true
            } label: {
                Label(tags.isEmpty ? "Add tag" : "Tag", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
                    .font(DesignTokens.Notes.chip)
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Add a tag")
            .accessibilityLabel("Add tag")
        }
    }

    private var liveSuggestions: [String] {
        Array(suggestions(draft).prefix(6))
    }

    private var suggestionRow: some View {
        HStack(spacing: 6) {
            ForEach(liveSuggestions, id: \.self) { suggestion in
                Button {
                    onAdd(suggestion)
                    draft = ""
                } label: {
                    Text("#\(suggestion)")
                        .noteChip(tinted: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add tag \(suggestion)")
            }
        }
    }

    private func commitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed)
        draft = ""
    }
}

private struct NoteTagChip: View {
    let tag: String
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 3) {
            Text("#\(tag)")
            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove tag \(tag)")
            }
        }
        .noteChip(tinted: true)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Remove Tag", role: .destructive, action: onRemove)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tag \(tag)")
        .accessibilityAction(named: "Remove", onRemove)
    }
}

/// The note's notebook as a quiet chip; its menu moves the note.
private struct NotebookChip: View {
    @Binding var selectedNotebookId: String?
    @State private var notebooks: [Notebook] = []
    @State private var notebookCancellable: AnyCancellable?

    var body: some View {
        Menu {
            Button {
                selectedNotebookId = nil
            } label: {
                HStack {
                    Text("Inbox")
                    if selectedNotebookId == nil { Image(systemName: "checkmark") }
                }
            }
            if !notebooks.isEmpty {
                Divider()
                ForEach(notebooks) { nb in
                    Button {
                        selectedNotebookId = nb.id
                    } label: {
                        HStack {
                            Text(nb.name)
                            if selectedNotebookId == nb.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 9.5, weight: .medium))
                Text(currentName)
            }
            .noteChip(tinted: false)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Move to notebook")
        .accessibilityLabel("Notebook: \(currentName)")
        .onAppear {
            notebooks = (try? NoteStore.shared.fetchAllNotebooks()) ?? []
            notebookCancellable = NoteStore.shared.observeNotebooks()
                .sink(receiveCompletion: { _ in },
                      receiveValue: { notebooks = $0 })
        }
    }

    private var currentName: String {
        guard let id = selectedNotebookId else { return "Inbox" }
        return notebooks.first(where: { $0.id == id })?.name ?? "Notebook"
    }
}
