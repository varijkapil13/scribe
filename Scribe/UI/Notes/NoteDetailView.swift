// Scribe/UI/Notes/NoteDetailView.swift
import Combine
import SwiftUI

struct NoteDetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var appDelegate: AppDelegate
    @StateObject private var vm: NoteDetailViewModel
    var onNavigate: (String) -> Void
    @State private var backlinksExpanded: Bool = false
    @State private var selectedSessionId: String? = nil
    @State private var userExplicitlyCollapsed: Bool = false
    @State private var openedTaskFromAction: TodoTask?
    @State private var openedTranscriptSession: Session?
    @FocusState private var titleFocused: Bool
    /// Focus mode: hides the sessions strip, backlinks, and document metadata,
    /// dims non-active blocks in the body, leaving just title + body. Persisted
    /// so it survives note switches and relaunches.
    @AppStorage("noteEditor.focusMode") private var focusMode: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(note: Note, onNavigate: @escaping (String) -> Void) {
        _vm = StateObject(wrappedValue: NoteDetailViewModel(note: note, onNavigate: onNavigate))
        self.onNavigate = onNavigate
    }

    private var isRecordingForThisNote: Bool {
        guard appState.isTranscribing, let currentId = appState.currentSessionId else { return false }
        return vm.sessions.contains(where: { $0.id == currentId })
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Document header ────────────────────────────────────────────
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                if !focusMode {
                    // Muted breadcrumb so the user knows where they landed after a
                    // ⌘K / deep-link jump. Uses the static "Notes" root rather than
                    // the notebook name — the notebook label lives inside the
                    // NotebookPicker's own state and isn't available here without a
                    // new fetch.
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Text("Notes")
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                            .foregroundStyle(.tertiary)
                        Text(vm.note.title.isEmpty ? "Untitled" : vm.note.title)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Location: Notes, \(vm.note.title.isEmpty ? "Untitled" : vm.note.title)")
                }

                TextField("Untitled", text: Binding(
                    get: { vm.note.title },
                    set: { vm.note.title = $0; vm.markDirty() }
                ))
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .textFieldStyle(.plain)
                .foregroundStyle(.primary)
                .focused($titleFocused)
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous)
                        .fill(titleFocused ? Color.accentColor.opacity(0.07) : .clear)
                        .animation(.easeOut(duration: DesignTokens.Motion.fast), value: titleFocused)
                )

                if !focusMode {
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

                        Spacer()

                        let headings = Self.headings(in: vm.note.body)
                        if !headings.isEmpty {
                            Menu {
                                ForEach(headings) { heading in
                                    Button {
                                        NotificationCenter.default.post(
                                            name: .scribeScrollToOffset, object: nil,
                                            userInfo: ["offset": heading.offset])
                                    } label: {
                                        Text(String(repeating: "    ", count: max(0, heading.level - 1)) + heading.title)
                                    }
                                }
                            } label: {
                                Image(systemName: "list.bullet.indent")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Outline — jump to a heading")
                            .accessibilityLabel("Document outline")
                        }

                        if vm.unresolvedLinkCount > 0 {
                            HStack(spacing: DesignTokens.Spacing.xs) {
                                Image(systemName: "exclamationmark.triangle")
                                    .imageScale(.small)
                                Text("\(vm.unresolvedLinkCount) unresolved link\(vm.unresolvedLinkCount == 1 ? "" : "s")")
                            }
                            .font(DesignTokens.Typography.eyebrow)
                            .foregroundStyle(.tertiary)
                            .tracking(0.5)
                            .help("These [[wiki links]] don't match an existing note title")
                            .accessibilityLabel("\(vm.unresolvedLinkCount) unresolved wiki link\(vm.unresolvedLinkCount == 1 ? "" : "s")")
                        }
                    }

                    // Inline tags — same token field the Tasks inspector uses,
                    // so a note's tags are visible and editable where they live
                    // (they were previously stored + sidebar-navigable but had
                    // no UI in the editor).
                    TagTokenField(
                        tags: vm.tags,
                        suggestions: { vm.tagSuggestions($0) },
                        onAdd: { vm.addTag($0) },
                        onRemove: { vm.removeTag($0) }
                    )
                    .accessibilityLabel("Note tags")
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .padding(.top, DesignTokens.Spacing.sm)
            .padding(.bottom, DesignTokens.Spacing.xs)

            if !focusMode {
                Divider()

                NoteSessionsStrip(
                    sessions: vm.sessions,
                    selectedSessionId: $selectedSessionId,
                    onStartRecording: { vm.startRecording(appDelegate: appDelegate) }
                )
                if isRecordingForThisNote {
                    NoteLiveRecordingPane()
                }
                if let selectedId = selectedSessionId,
                   let session = vm.sessions.first(where: { $0.id == selectedId }) {
                    ScrollView {
                        NoteSessionAutoSection(
                            viewModel: vm.transcriptDetailViewModel(for: session),
                            onOpenSession: { sess in openedTranscriptSession = sess },
                            onConvertActionItem: { _, task in
                                openedTaskFromAction = task
                            }
                        )
                    }
                    .frame(maxHeight: 280)
                }
                Divider()
            }

            // ── Body editor (full width) ───────────────────────────────────
            NoteEditorView(
                text: Binding(
                    get: { vm.note.body },
                    set: { vm.note.body = $0; vm.markDirty() }
                ),
                noteStore: .shared,
                noteId: vm.note.id,
                onNavigate: { anchor in vm.handleWikiLinkNavigate(anchor: anchor) },
                focusModeEnabled: focusMode
            )
            .padding(.vertical, DesignTokens.Spacing.xs)

            // ── Backlinks (collapsible, only when non-empty) ───────────────
            if !vm.backlinks.isEmpty && !focusMode {
                Divider()
                BacklinksBar(
                    backlinks: vm.backlinks,
                    isExpanded: $backlinksExpanded,
                    onNavigate: onNavigate
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onDisappear {
            // Commit any edit still inside the autosave debounce window before
            // this view (and its view model) is torn down on a note switch.
            vm.flushPendingSave()
        }
        .onChange(of: selectedSessionId) { _, newValue in
            if let updated = SessionSelectionReducer.userCollapsedFromTransition(
                newSelection: newValue,
                hasSessions: !vm.sessions.isEmpty
            ) {
                userExplicitlyCollapsed = updated
            }
        }
        .onChange(of: vm.sessions) { _, newSessions in
            selectedSessionId = SessionSelectionReducer.selection(
                forNewSessions: newSessions,
                currentSelection: selectedSessionId,
                userExplicitlyCollapsed: userExplicitlyCollapsed
            )
        }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .sheet(item: $openedTaskFromAction) { task in
            TaskInspectorSheet(task: task) { openedTaskFromAction = nil }
        }
        .sheet(item: $openedTranscriptSession) { session in
            NavigationStack {
                TranscriptDetailView(session: session)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { openedTranscriptSession = nil }
                        }
                    }
            }
            .frame(minWidth: 720, minHeight: 540)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    toggleFocusMode()
                } label: {
                    Label(focusMode ? "Exit Focus Mode" : "Focus Mode",
                          systemImage: focusMode ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                }
                .help(focusMode ? "Exit focus mode (⌃⌘F)" : "Focus mode: hide chrome and dim other blocks (⌃⌘F)")
                .keyboardShortcut("f", modifiers: [.control, .command])
                .accessibilityLabel(focusMode ? "Exit focus mode" : "Enter focus mode")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    exportMarkdown()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export this note as Markdown")
            }
        }
    }

    private func toggleFocusMode() {
        if reduceMotion {
            focusMode.toggle()
        } else {
            withAnimation(.easeInOut(duration: DesignTokens.Motion.standard)) {
                focusMode.toggle()
            }
        }
    }

    private func exportMarkdown() {
        // Use the VM's injected TranscriptStore so the export path respects
        // DI — same store the auto-section observes, and tests can swap in
        // an in-memory instance.
        let markdown = NoteMarkdownExporter.export(note: vm.note,
                                                   transcriptStore: vm.transcriptStore)
        ExportManager.saveToFile(
            content: markdown,
            defaultName: ExportFileName.safe(vm.note.title),
            fileExtension: "md"
        )
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
                .foregroundStyle(.primary)
                .padding(.horizontal, DesignTokens.Spacing.xl)
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
                    .padding(.horizontal, DesignTokens.Spacing.xl)
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

// MARK: - Document outline

extension NoteDetailView {
    struct Heading: Identifiable {
        let id = UUID()
        let level: Int
        let title: String
        /// UTF-16 offset of the heading line in the body — drives the editor
        /// scroll (NSRange/NSTextView use UTF-16 indices).
        let offset: Int
    }

    private static let headingRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+(.+?)[ \t]*$"#)
    }()

    /// ATX headings (`# …`) parsed from the body with their UTF-16 offsets, for
    /// the outline menu. (Code-block fences aren't excluded — a rare edge.)
    static func headings(in body: String) -> [Heading] {
        let ns = body as NSString
        var out: [Heading] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byLines]) { sub, lineRange, _, _ in
            guard let line = sub else { return }
            let lineNS = line as NSString
            guard let m = headingRegex.firstMatch(in: line, range: NSRange(location: 0, length: lineNS.length)),
                  let hashes = Range(m.range(at: 1), in: line),
                  let titleR = Range(m.range(at: 2), in: line) else { return }
            out.append(Heading(level: line[hashes].count,
                               title: String(line[titleR]),
                               offset: lineRange.location))
        }
        return out
    }
}
