// Scribe/UI/Notes/NoteDetailView.swift
import SwiftUI

struct NoteDetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var appDelegate: AppDelegate
    @StateObject private var vm: NoteDetailViewModel
    var onNavigate: (String) -> Void
    /// Whether the recording summary panel is expanded. Opens on demand,
    /// sized to content.
    @State private var recordingExpanded: Bool = false
    /// Which session the expanded recording panel shows (defaults to the latest).
    @State private var selectedSessionId: String? = nil
    @State private var openedTaskFromAction: TodoTask?
    @State private var openedTranscriptSession: Session?
    @State private var editorModel = WebEditorModel()
    @FocusState private var titleFocused: Bool
    /// Focus mode: hides the header metadata, recordings and footer, leaving
    /// just title + body. Persisted so it survives note switches and relaunches.
    @AppStorage("noteEditor.focusMode") private var focusMode: Bool = false
    @AppStorage(NotePageWidth.storageKey) private var pageWidthRaw: String = NotePageWidth.regular.rawValue
    @SceneStorage("scribe.noteInspector.isPresented") private var inspectorPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.noteDetailShowsDocumentHeader) private var showsDocumentHeader

    init(note: Note, onNavigate: @escaping (String) -> Void) {
        _vm = StateObject(wrappedValue: NoteDetailViewModel(note: note, onNavigate: onNavigate))
        self.onNavigate = onNavigate
    }

    private var isRecordingForThisNote: Bool {
        guard appState.isTranscribing, let currentId = appState.currentSessionId else { return false }
        return vm.sessions.contains(where: { $0.id == currentId })
    }

    /// Matches the web editor's centred text column so the title and body
    /// share one left edge.
    private var columnMaxWidth: CGFloat {
        let width = NotePageWidth(rawValue: pageWidthRaw) ?? .regular
        return width.capsWidth ? width.measure + DesignTokens.Notes.editorGutter * 2 : .infinity
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(maxWidth: columnMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)

            if !focusMode, recordingExpanded || isRecordingForThisNote {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    if isRecordingForThisNote { NoteLiveRecordingPane() }
                    if recordingExpanded, let session = displayedSession {
                        recordingPanel(session)
                    }
                }
                .padding(.horizontal, DesignTokens.Notes.editorGutter)
                .padding(.bottom, DesignTokens.Spacing.sm)
                .frame(maxWidth: columnMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // A locked note shows its unlock view until Touch ID releases it.
            if vm.lockPhase == .locked {
                LockedNoteUnlockView(title: vm.note.title) {
                    Task { await vm.unlockNote() }
                }
            } else {
                NoteEditorView(
                    text: Binding(
                        get: { vm.note.body },
                        set: {
                            // A late edit from the editor (its debounced
                            // change) after the note re-locked must not put
                            // plaintext back into the locked body.
                            guard vm.lockPhase != .locked else { return }
                            vm.note.body = $0
                            vm.markDirty()
                        }
                    ),
                    noteStore: .shared,
                    noteId: vm.note.id,
                    onNavigate: { anchor in vm.handleWikiLinkNavigate(anchor: anchor) },
                    focusModeEnabled: focusMode,
                    editorModel: editorModel
                )
            }

            if !focusMode {
                footer
                    .transition(.opacity)
            }
        }
        .background(DesignTokens.Palette.ground)
        // Note info inspector (⌥⌘I) + the focused-note value the menu bar's
        // Print / Export as PDF / Open in New Window commands act on.
        .modifier(NoteInspectorModifier(vm: vm, editorModel: editorModel,
                                        isPresented: $inspectorPresented, onNavigate: onNavigate))
        .onDisappear {
            // Commit any edit still inside the autosave debounce window before
            // this view (and its view model) is torn down on a note switch.
            vm.flushPendingSave()
        }
        // Save / reload failures are recoverable and go to the unified banner,
        // never a blocking alert (see FeedbackPolicy).
        .onChange(of: vm.errorMessage) { _, newValue in
            if let message = newValue {
                appState.report(message)
                vm.errorMessage = nil
            }
        }
        // Notes AI toolbar menu (Enhance notes, recipes) + replay of
        // template-summary edits written to this note elsewhere.
        .modifier(NoteAIFeaturesModifier(vm: vm))
        // Handoff / search activity + Reveal in Finder / Copy Link menu.
        .modifier(NoteEntryPointsModifier(noteId: vm.note.id, title: vm.note.title))
        // Lock / unlock, attachments with Live Text, HTML export.
        .modifier(NoteDocumentsModifier(vm: vm))
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
                .help(focusMode ? "Exit focus mode (⌃⌘F)" : "Focus mode: hide note chrome (⌃⌘F)")
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

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if !focusMode {
                metaLine
            }

            if showsDocumentHeader {
                titleField
            }

            if !focusMode {
                NoteHeaderChips(
                    tags: vm.tags,
                    notebookId: vm.note.isDailyNote ? nil : Binding(
                        get: { vm.note.notebookId },
                        set: { newId in
                            vm.note.notebookId = newId
                            vm.markDirty()
                        }
                    ),
                    suggestions: { vm.tagSuggestions($0) },
                    onAdd: { vm.addTag($0) },
                    onRemove: { vm.removeTag($0) }
                )
            }
        }
        .padding(.horizontal, DesignTokens.Notes.editorGutter)
        .padding(.top, DesignTokens.Spacing.lg)
        .padding(.bottom, DesignTokens.Spacing.xs)
    }

    private var titleField: some View {
        TextField("Untitled", text: Binding(
            get: { vm.note.title },
            set: { vm.note.title = $0; vm.markDirty() }
        ), axis: .vertical)
        .font(DesignTokens.Typography.display(size: DesignTokens.Notes.titleSize, weight: .medium))
        .textFieldStyle(.plain)
        .foregroundStyle(DesignTokens.Palette.textPrimary)
        .lineLimit(1...3)
        .focused($titleFocused)
        .onSubmit { titleFocused = false }
    }

    /// Quiet top line: when the note was edited, link health, and recordings.
    private var metaLine: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text("Edited \(vm.note.updatedAt.formatted(.relative(presentation: .named)))")
                .lineLimit(1)

            if vm.unresolvedLinkCount > 0 {
                Text("·")
                Text("\(vm.unresolvedLinkCount) unresolved link\(vm.unresolvedLinkCount == 1 ? "" : "s")")
                    .help("These [[wiki links]] don't match an existing note title")
                    .accessibilityLabel("\(vm.unresolvedLinkCount) unresolved wiki link\(vm.unresolvedLinkCount == 1 ? "" : "s")")
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            if let session = latestSession {
                Button { toggle($recordingExpanded) } label: {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        sessionDot(session)
                        Text(Self.sessionSubtitle(session)).lineLimit(1)
                        Image(systemName: recordingExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(recordingExpanded ? "Hide the recording summary" : "Show the recording summary")
                .accessibilityLabel("Recording from \(Self.sessionSubtitle(session))")
            }

            Button { vm.startRecording(appDelegate: appDelegate) } label: {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "record.circle")
                        .foregroundStyle(DesignTokens.Palette.recording)
                    Text("Record")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Start a new recording for this note")
        }
        .font(DesignTokens.Notes.meta)
        .foregroundStyle(DesignTokens.Palette.textTertiary)
    }

    // MARK: - Footer

    private var footer: some View {
        let words = NoteStatistics.compute(body: vm.note.body).words
        return HStack(spacing: DesignTokens.Spacing.sm) {
            if !vm.backlinks.isEmpty {
                Button {
                    inspectorPresented = true
                } label: {
                    Text("\(vm.backlinks.count) backlink\(vm.backlinks.count == 1 ? "" : "s")")
                }
                .buttonStyle(.plain)
                .help("Show backlinks in the inspector")
                Text("·")
            }
            Text("\(words) word\(words == 1 ? "" : "s")")
                .monospacedDigit()
            Spacer()
        }
        .font(DesignTokens.Notes.meta)
        .foregroundStyle(DesignTokens.Palette.textTertiary)
        .padding(.horizontal, DesignTokens.Notes.editorGutter)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(maxWidth: columnMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
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
        // The VM's injected TranscriptStore keeps export on the same store the
        // auto-section observes (tests swap in an in-memory one).
        let markdown = NoteMarkdownExporter.export(note: vm.note,
                                                   transcriptStore: vm.transcriptStore)
        ExportManager.saveToFile(
            content: markdown,
            defaultName: ExportFileName.safe(vm.note.title),
            fileExtension: "md"
        )
    }

    // MARK: - Recording panel

    private var latestSession: Session? {
        vm.sessions.max(by: { $0.createdAt < $1.createdAt })
    }

    /// The session the expanded recording panel shows — the user's pick, else
    /// the latest.
    private var displayedSession: Session? {
        if let id = selectedSessionId, let s = vm.sessions.first(where: { $0.id == id }) { return s }
        return latestSession
    }

    @ViewBuilder
    private func sessionDot(_ session: Session) -> some View {
        if session.endedAt == nil {
            Circle().fill(DesignTokens.Palette.recording).frame(width: 6, height: 6)
        } else {
            Image(systemName: "waveform")
                .font(.system(size: 10, weight: .medium))
        }
    }

    /// Recording summary as a content-sized card. When the note has more than
    /// one session, a slim switcher chooses which to show.
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

    private var sessionSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(vm.sessions) { session in
                    let isSelected = displayedSession?.id == session.id
                    Button { selectedSessionId = session.id } label: {
                        HStack(spacing: DesignTokens.Spacing.xs) {
                            sessionDot(session)
                            Text(Self.sessionSubtitle(session)).lineLimit(1)
                        }
                        .noteChip(tinted: isSelected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

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
