// Scribe/UI/Notes/NoteDetailView.swift
import Combine
import SwiftUI

struct NoteDetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var appDelegate: AppDelegate
    @StateObject private var vm: NoteDetailViewModel
    var onNavigate: (String) -> Void
    @State private var backlinksExpanded: Bool = false
    /// Whether the frontmatter "Properties" panel is expanded. Collapsed by
    /// default — the meta-bar chip shows a count; opening reveals a
    /// content-sized card.
    @State private var propertiesExpanded: Bool = false
    /// Whether the recording summary panel is expanded. Collapsed by default:
    /// the old layout auto-reserved ~280px even with no summary, leaving a tall
    /// void above the editor. Now the panel opens on demand, sized to content.
    @State private var recordingExpanded: Bool = false
    /// Which session the expanded recording panel shows (defaults to the latest).
    @State private var selectedSessionId: String? = nil
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
                .padding(.vertical, DesignTokens.Spacing.xxs)
                .padding(.horizontal, DesignTokens.Spacing.xs)
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

                    // Compact meta bar — Properties + Recording disclosure
                    // chips on a single row, plus "New recording". Replaces the
                    // old tall stack (a full-width properties section + the
                    // sessions strip + a 280px auto-reserved summary block).
                    // The matching panels open below, sized to content.
                    metaBar
                        .padding(.top, DesignTokens.Spacing.xxs)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Note properties and recordings")
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .padding(.top, DesignTokens.Spacing.sm)
            .padding(.bottom, DesignTokens.Spacing.xs)

            if !focusMode {
                // Expandable panels — opened from the meta bar, sized to their
                // content. No fixed height is reserved, so an empty or short
                // summary no longer leaves a tall void above the editor.
                if propertiesExpanded || recordingExpanded || isRecordingForThisNote {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        if propertiesExpanded { propertiesPanel }
                        if isRecordingForThisNote { NoteLiveRecordingPane() }
                        if recordingExpanded, let session = displayedSession {
                            recordingPanel(session)
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.xl)
                    .padding(.bottom, DesignTokens.Spacing.sm)
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
        // Note save / reload failures are recoverable, background-ish problems
        // (autosave debounce, a backlinks refresh) — they should never block the
        // editor with a modal. Route them to the unified banner instead of a
        // blocking `.alert` (one feedback language — see FeedbackPolicy). A
        // genuine hard failure that the user *must* act on would still warrant a
        // `.alert`; none of these qualify.
        .onChange(of: vm.errorMessage) { _, newValue in
            if let message = newValue {
                appState.report(message)
                // The banner now owns the message; clear the VM flag so it
                // doesn't re-fire on the next dependency change.
                vm.errorMessage = nil
            }
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

    // MARK: - Meta bar + expandable panels

    /// Most recent recording session for this note, if any.
    private var latestSession: Session? {
        vm.sessions.max(by: { $0.createdAt < $1.createdAt })
    }

    /// The session the expanded recording panel shows — the user's pick, else
    /// the latest.
    private var displayedSession: Session? {
        if let id = selectedSessionId, let s = vm.sessions.first(where: { $0.id == id }) { return s }
        return latestSession
    }

    /// One compact row carrying the Properties and Recording disclosure chips
    /// plus a quiet "New recording" action — the chrome that used to occupy
    /// several stacked full-width sections.
    private var metaBar: some View {
        HStack(spacing: 0) {
            metaChip(
                isOpen: propertiesExpanded,
                systemImage: "list.bullet.rectangle",
                label: "Properties",
                trailing: vm.properties.isEmpty ? nil : "\(vm.properties.count)",
                action: { toggle($propertiesExpanded) }
            )
            .accessibilityLabel("Properties, \(vm.properties.count) set")

            if let session = latestSession {
                barSeparator
                Button { toggle($recordingExpanded) } label: {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        chevron(recordingExpanded)
                        sessionDot(session)
                        Text("Recording").fontWeight(.semibold)
                        Text(Self.sessionSubtitle(session))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, DesignTokens.Spacing.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Recording from \(Self.sessionSubtitle(session))")
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            barSeparator
            Button { vm.startRecording(appDelegate: appDelegate) } label: {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "record.circle")
                        .imageScale(.small)
                        .foregroundStyle(Color.accentColor)
                    Text("New recording")
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Start a new recording for this note")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.Palette.surfaceSunken,
                    in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
        )
    }

    private func metaChip(isOpen: Bool, systemImage: String, label: String,
                          trailing: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                chevron(isOpen)
                Image(systemName: systemImage).imageScale(.small)
                Text(label).fontWeight(.semibold)
                if let trailing {
                    Text(trailing).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chevron(_ isOpen: Bool) -> some View {
        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
            .imageScale(.small)
            .foregroundStyle(.tertiary)
            .frame(width: 9)
    }

    private var barSeparator: some View {
        Rectangle()
            .fill(DesignTokens.Palette.divider)
            .frame(width: 1, height: 18)
    }

    @ViewBuilder
    private func sessionDot(_ session: Session) -> some View {
        if session.endedAt == nil {
            Circle().fill(DesignTokens.Palette.recording).frame(width: 7, height: 7)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .imageScale(.small)
                .foregroundStyle(.green)
        }
    }

    /// Properties editor rendered as a content-sized card (its own header is
    /// hidden — the meta-bar chip is the label).
    private var propertiesPanel: some View {
        NotePropertiesView(
            properties: $vm.properties,
            onCommit: { vm.updateProperties($0) },
            optionSuggestions: vm.propertyOptionSuggestions,
            showsHeader: false
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Palette.surfaceSunken,
                    in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
        )
        .accessibilityLabel("Note properties")
    }

    /// Recording summary as a content-sized card (no fixed height). When the
    /// note has more than one session, a slim switcher chooses which to show.
    private func recordingPanel(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if vm.sessions.count > 1 { sessionSwitcher }
            NoteSessionAutoSection(
                viewModel: vm.transcriptDetailViewModel(for: session),
                onOpenSession: { sess in openedTranscriptSession = sess },
                onConvertActionItem: { _, task in openedTaskFromAction = task }
            )
        }
    }

    /// Horizontal chips to pick which recording the panel shows.
    private var sessionSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(vm.sessions) { session in
                    let isSelected = displayedSession?.id == session.id
                    Button { selectedSessionId = session.id } label: {
                        HStack(spacing: DesignTokens.Spacing.xs) {
                            sessionDot(session)
                            Text(Self.sessionSubtitle(session)).font(.caption).lineLimit(1)
                        }
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                        .padding(.vertical, DesignTokens.Spacing.xxs)
                        .background(isSelected ? DesignTokens.Palette.surfaceElevated : .clear,
                                    in: Capsule())
                        .overlay(
                            Capsule().strokeBorder(
                                isSelected ? Color.accentColor : DesignTokens.Palette.cardBorder,
                                lineWidth: 1)
                        )
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Toggles a disclosure with the standard reduce-motion-aware animation.
    private func toggle(_ flag: Binding<Bool>) {
        withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
            flag.wrappedValue.toggle()
        }
    }

    /// "Mon D at H:MM · <duration>" subtitle for a session chip.
    static func sessionSubtitle(_ session: Session) -> String {
        let date = session.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        if let secs = session.durationSeconds {
            let label = secs < 60 ? "<1m" : "\(secs / 60)m"
            return "\(date) · \(label)"
        }
        return date
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
