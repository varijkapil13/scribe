// Scribe/UI/Notes/NoteDetailView.swift
import Combine
import SwiftUI

struct NoteDetailView: View {
    @StateObject private var vm: NoteDetailViewModel
    var onNavigate: (String) -> Void
    @State private var backlinksExpanded: Bool = false

    init(note: Note, onNavigate: @escaping (String) -> Void) {
        _vm = StateObject(wrappedValue: NoteDetailViewModel(note: note, onNavigate: onNavigate))
        self.onNavigate = onNavigate
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Document header ────────────────────────────────────────────
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                TextField("Untitled", text: Binding(
                    get: { vm.note.title },
                    set: { vm.note.title = $0; vm.markDirty() }
                ))
                .font(DesignTokens.Typography.title2)
                .textFieldStyle(.plain)
                .foregroundStyle(.primary)

                HStack(spacing: DesignTokens.Spacing.md) {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Image(systemName: "clock")
                            .imageScale(.small)
                        Text("Edited \(vm.note.updatedAt.formatted(.relative(presentation: .named)))")
                    }
                    .font(DesignTokens.Typography.eyebrow)
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)

                    if !vm.note.isDailyNote {
                        NotebookPicker(selectedNotebookId: Binding(
                            get: { vm.note.notebookId },
                            set: { newId in
                                vm.note.notebookId = newId
                                vm.markDirty()
                            }
                        ))
                    }
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.xxxl)
            .padding(.top, DesignTokens.Spacing.xl)
            .padding(.bottom, DesignTokens.Spacing.lg)

            Divider()

            // ── Body editor (reading-width constrained) ────────────────────
            NoteEditorView(
                text: Binding(
                    get: { vm.note.body },
                    set: { vm.note.body = $0; vm.markDirty() }
                ),
                noteStore: .shared,
                onNavigate: { anchor in vm.handleWikiLinkNavigate(anchor: anchor) }
            )
            .padding(.horizontal, DesignTokens.Spacing.xxxl)
            .padding(.vertical, DesignTokens.Spacing.lg)

            // ── Backlinks (collapsible, only when non-empty) ───────────────
            if !vm.backlinks.isEmpty {
                Divider()
                BacklinksBar(
                    backlinks: vm.backlinks,
                    isExpanded: $backlinksExpanded,
                    onNavigate: onNavigate
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    if vm.isDirty {
                        Text("Unsaved changes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Save") { vm.save() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!vm.isDirty)
                }
            }
        }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }
}

// MARK: - Backlinks bar

private struct BacklinksBar: View {
    let backlinks: [Note]
    @Binding var isExpanded: Bool
    let onNavigate: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Disclosure toggle
            Button {
                withAnimation(.easeInOut(duration: DesignTokens.Motion.fast)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "link")
                        .imageScale(.small)
                    Text("\(backlinks.count) linked note\(backlinks.count == 1 ? "" : "s")")
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                .font(DesignTokens.Typography.eyebrow)
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.horizontal, DesignTokens.Spacing.xxxl)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        ForEach(backlinks) { note in
                            Button {
                                onNavigate(note.id)
                            } label: {
                                HStack(spacing: DesignTokens.Spacing.xs) {
                                    Image(systemName: "note.text")
                                        .imageScale(.small)
                                    Text(note.title.isEmpty ? "(Untitled)" : note.title)
                                        .lineLimit(1)
                                }
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, DesignTokens.Spacing.sm)
                                .padding(.vertical, DesignTokens.Spacing.xs)
                                .background(DesignTokens.Palette.surfaceElevated,
                                            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                                        .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.xxxl)
                    .padding(.vertical, DesignTokens.Spacing.sm)
                }
            }
        }
        .background(DesignTokens.Palette.surfaceSunken)
    }
}

// MARK: - Notebook picker chip

private struct NotebookPicker: View {
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
            HStack(spacing: 3) {
                Image(systemName: "folder")
                    .imageScale(.small)
                Text(currentName)
            }
            .font(DesignTokens.Typography.eyebrow)
            .foregroundStyle(.secondary)
            .tracking(0.5)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
