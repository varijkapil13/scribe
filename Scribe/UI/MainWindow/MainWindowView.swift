import SwiftUI
import TipKit

// `MainSelection` and `NotesFilter` live in MainSelection.swift so
// they stay in the SwiftPM test target while this view file is excluded from it
// (see the EDITOR EXCLUSION BOUNDARY note in Package.swift).

/// The main window — sidebar of past transcripts + settings panes, detail
/// pane shows whichever is selected. Primary UI for the app.
struct MainWindowView: View {

    // AppState is held without observing it, so error banners and session
    // bookkeeping don't re-render the whole window.
    let appState: AppState
    @ObservedObject private var recording: RecordingStatus
    @EnvironmentObject var appDelegate: AppDelegate
    @StateObject private var projectsViewModel = ProjectsViewModel()
    @State private var searchText: String = ""
    @State private var nav = NavigationCoordinator()
    /// Shared "one day model" — the date the Today home and Task Calendar both
    /// plan against. Injected into the detail pane so navigating a day in one
    /// surface is reflected in the other (Slice E1).
    @State private var dayPlanning = DayPlanningModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @State private var projectEditorMode: ProjectEditorMode?
    @State private var projectPendingDelete: Project?
    @State private var projectsExpanded: Bool = true
    @State private var notesExpanded: Bool = true
    @State private var meetingsExpanded: Bool = true
    @State private var notesTagsExpanded: Bool = false
    @State private var unifiedTags: [String] = []
    @State private var notebooks: [Notebook] = []
    /// Animatable, persisted expansion state for the notebook folder tree.
    @State private var notebookExpansion = NotebookExpansion()
    @State private var allNotes: [Note] = []
    @State private var notebookTreeIndex = NotebookTreeIndex(notebooks: [], notes: [])
    @State private var taskCounts = SidebarTaskCounts()
    @State private var showUniversalSearch: Bool = false
    @State private var isCreatingTopNotebook: Bool = false
    @State private var topNotebookDraftName: String = ""
    @State private var detailNote: Note? = nil
    /// The note id whose fetch has finished, so "not found" is shown only
    /// after the lookup rather than while it is in flight.
    @State private var detailNoteFetchedId: String? = nil
    @State private var detailSession: Session? = nil
    @State private var detailSessionFetchedId: String? = nil
    @State private var tagReloadTask: Task<Void, Never>? = nil
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showOnboarding = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    init(appState: AppState) {
        self.appState = appState
        _recording = ObservedObject(wrappedValue: appState.recordingStatus)
    }

    /// Selection binding handed to the notebook-tree rows, which set it on tap.
    /// Drives the history coordinator; reads back `nav.current` so a tree note
    /// reads as selected. (Top-level rows call `nav.navigate` directly.)
    private var treeSelection: Binding<MainSelection?> {
        Binding(get: { nav.current }, set: { if let value = $0 { nav.navigate(to: value) } })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: DesignTokens.Metrics.sidebarWidth, max: 360)
        } detail: {
            detail
                .environment(dayPlanning)
                .errorBanner(appState)
                .overlay {
                    // IINA-style floating controller; self-gates on
                    // isTranscribing and positions itself by its placement
                    // setting, so it's inert when not recording.
                    LiveControllerOverlay(
                        audioManager: appState.audioManager,
                        status: recording,
                        clock: appState.recordingClock,
                        onPauseToggle: {
                            if recording.isPaused {
                                Task { await appDelegate.resumeRecording() }
                            } else {
                                appDelegate.pauseRecording()
                            }
                        },
                        onStop: { Task { await appDelegate.stopRecording() } },
                        onExpand: { nav.navigate(to: .live) }
                    )
                }
        }
        .frame(minWidth: columnVisibility == .detailOnly ? 720 : 920, minHeight: 620)
        // Customizable (View › Customize Toolbar…); see MainWindowToolbar.
        .toolbar(id: MainWindowToolbar.id) {
            MainWindowToolbar(
                appState: appState,
                canGoBack: nav.canGoBack,
                canGoForward: nav.canGoForward,
                isRecording: recording.isRecording,
                isPaused: recording.isPaused,
                onBack: { nav.goBack() },
                onForward: { nav.goForward() },
                onShowLive: { nav.navigate(to: .live) },
                onTogglePause: {
                    if recording.isPaused {
                        Task { await appDelegate.resumeRecording() }
                    } else {
                        appDelegate.pauseRecording()
                    }
                },
                onToggleRecording: { Task { await appDelegate.toggleRecording() } },
                onNewNote: {
                    NotificationCenter.default.post(name: .scribeNewNote, object: nil)
                },
                onCommandBar: { showUniversalSearch.toggle() }
            )
        }
        // Restores the selected destination + sidebar visibility per window.
        .modifier(MainWindowRestorationModifier(
            nav: nav,
            columnVisibility: $columnVisibility,
            isRecording: recording.isRecording
        ))
        .onAppear {
            projectsViewModel.start()
            reloadTags()
            // The coordinator defaults to .today; only the active-recording
            // case overrides the initial destination (no history entry).
            if recording.isRecording {
                nav.replaceCurrent(.live)
            }
            appState.currentSelection = nav.current
            // Never show onboarding in the screenshot/UI-test fixture mode,
            // regardless of when the fixture sets `hasCompletedOnboarding`
            // (avoids a set-vs-read race that left the Welcome sheet — and its
            // mic-permission step — covering every captured screen).
            if OnboardingGate.shouldShow() && !AppLaunchEnvironment.usesUITestFixtures {
                showOnboarding = true
            }
        }
        .onDisappear { projectsViewModel.stop() }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding, audioManager: appState.audioManager)
        }
        .onReceive(NoteStore.shared.observeNotes().replaceError(with: [])) { notes in
            allNotes = notes
            rebuildNotebookTreeIndex()
            scheduleTagReload()
        }
        .onReceive(NoteStore.shared.observeNotebooks().replaceError(with: [])) {
            notebooks = $0
            rebuildNotebookTreeIndex()
        }
        .onReceive(TaskStore.shared.observeTasks(filter: .all).replaceError(with: [])) { tasks in
            taskCounts = SidebarTaskCounts(tasks: tasks)
        }
        .sheet(item: $projectEditorMode) { mode in
            switch mode {
            case .create:
                ProjectEditorView(mode: .create) { name, color, icon in
                    _ = projectsViewModel.create(name: name, color: color, icon: icon)
                }
            case .edit(let project):
                ProjectEditorView(mode: .edit(project)) { name, color, icon in
                    var copy = project
                    copy.name = name
                    copy.color = color
                    copy.icon = icon
                    projectsViewModel.update(copy)
                }
            }
        }
        .overlay(alignment: .top) {
            if showUniversalSearch {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture { showUniversalSearch = false }
                    UniversalSearchView(isPresented: $showUniversalSearch) { dest in
                        nav.navigate(to: dest)
                    }
                    .padding(.top, 60)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        // Menu-bar commands (the shortcut owners) route here.
        .onReceive(NotificationCenter.default.publisher(for: .scribeToggleCommandBar)) { _ in
            showUniversalSearch.toggle()
            ScribeTips.quickSearchUsed()
        }
        .onReceive(NotificationCenter.default.publisher(for: .scribeGoBack)) { _ in nav.goBack() }
        // scribe:// links, opened files and Handoff (ScribeEntryRouter).
        .modifier(ScribeEntryPointsModifier(nav: nav, showCommandBar: $showUniversalSearch))
        // Drop audio/video to import it as a recording; import progress card.
        .modifier(MediaImportWindowSupport())
        .onReceive(NotificationCenter.default.publisher(for: .scribeGoForward)) { _ in nav.goForward() }
        .onReceive(NotificationCenter.default.publisher(for: .scribeToggleSidebar)) { _ in
            withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scribeNewNote)) { _ in
            if let note = try? NoteStore.shared.createNote(title: "", body: "") {
                nav.navigate(to: .note(note.id))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scribeNewDailyNote)) { _ in
            if let note = try? NoteStore.shared.dailyNote(for: Date()) {
                nav.navigate(to: .note(note.id))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scribeNavigate)) { note in
            if let dest = note.object as? MainSelection { nav.navigate(to: dest) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openScribeSettings)) { _ in
            // Settings is a native scene now — open the standard preferences
            // window instead of clobbering the working note/task in-pane.
            openSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .scribeRequestNavigateToNote)) { note in
            // Auto-create path (B1.1): bind the freshly created meeting note as
            // the current pane in one atomic routed transition. `replaceCurrent`
            // (not `navigate`) because the user never explicitly navigated here,
            // so it shouldn't create a spurious Back entry — and because it
            // makes `.note(id)` the only value `nav.current` takes on this path,
            // the `isTranscribing` policy below can never resolve to `.live`
            // first. No intermediate `.live` frame regardless of callback order.
            if let id = note.userInfo?["noteId"] as? String {
                nav.replaceCurrent(RecordingNavigationPolicy.autoCreateDestination(noteId: id))
            }
        }
        .onChange(of: recording.isRecording) { _, isRecording in
            // Session started → flip to the inline live view via the tested
            // RecordingNavigationPolicy: it returns .live unless the user is
            // already on a Note (whose inline pane handles streaming) or the
            // auto-create path already navigated to a note.
            if let dest = RecordingNavigationPolicy.destination(
                currentSelection: nav.current, isRecording: isRecording
            ) {
                nav.navigate(to: dest)
            }
            // Session stopped → if the user was watching the live view (which
            // goes blank on stop), take them to the finished transcript.
            if !isRecording,
               let dest = RecordingNavigationPolicy.stopDestination(
                currentSelection: nav.current,
                finishedSessionId: appState.lastFinishedSessionId
               ) {
                nav.navigate(to: dest)
            }
        }
        .onChange(of: nav.current) { _, newValue in
            Perf.event("navigation")
            appState.currentSelection = newValue
            // A cached detail is only reused for a note-to-note (or
            // recording-to-recording) switch; otherwise it would be stale.
            if case .note(let id) = newValue {
                loadDetailNote(id: id)
            } else {
                detailNote = nil; detailNoteFetchedId = nil
            }
            if case .session = newValue {} else { detailSession = nil; detailSessionFetchedId = nil }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List {
            if searchText.isEmpty {
                Section {
                    sidebarLink(.today, "Today", systemImage: "sun.max", badge: taskCounts.today)
                    sidebarLink(.tasks(.inbox), "Inbox", systemImage: "tray", badge: taskCounts.inbox)
                    sidebarLink(.tasks(.upcoming), "Upcoming", systemImage: "calendar", badge: taskCounts.upcoming)
                }

                notesSection
                meetingsSection
                projectsSection

                TaskAreasSidebarSection(
                    viewModel: projectsViewModel,
                    isSelected: { nav.current == .tasks(.area($0)) },
                    onSelect: { nav.navigate(to: .tasks(.area($0))) },
                    onDeleted: { if nav.current == .tasks(.area($0)) { nav.navigate(to: .tasks(.inbox)) } }
                )
            } else {
                Section {
                    let results = sidebarSearchResults
                    if results.isEmpty {
                        Label("No results", systemImage: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .font(DesignTokens.Typography.callout)
                    } else {
                        ForEach(results) { note in
                            SidebarRow(isSelected: nav.current == .note(note.id),
                                       action: { nav.navigate(to: .note(note.id)) }) {
                                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                                    Text(note.title.isEmpty ? "Untitled" : note.title)
                                        .lineLimit(1)
                                    Text(note.updatedAt, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(DesignTokens.Palette.textTertiary)
                                }
                                .padding(.vertical, DesignTokens.Spacing.xs)
                            }
                        }
                    }
                } header: {
                    SidebarSectionHeader(title: "Notes")
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, DesignTokens.Metrics.sidebarRowHeight)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Filter notes")
        .navigationTitle("Scribe")
        .confirmationDialog(
            projectPendingDelete.map { "Delete “\($0.name)”?" } ?? "Delete project?",
            isPresented: Binding(
                get: { projectPendingDelete != nil },
                set: { if !$0 { projectPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) {
                guard let project = projectPendingDelete else { return }
                projectsViewModel.delete(id: project.id)
                if case .tasks(.project(let id)) = nav.current, id == project.id {
                    nav.navigate(to: .tasks(.inbox))
                }
                projectPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { projectPendingDelete = nil }
        } message: {
            Text("The project will be deleted. Its tasks won’t be deleted — they’ll move to your Inbox.")
        }
        // An edge bar (not a painted inset) joins the system scroll-edge
        // effect, so the sidebar's own material shows through.
        .scribeEdgeBar(.bottom) {
            sidebarFooter
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        Section {
            if notesExpanded {
                sidebarLink(.notes(.all), "All Notes", systemImage: "doc.on.doc")
                sidebarLink(.notes(.daily), "Daily Notes", systemImage: "calendar.day.timeline.left")

                NotebookTreeView(
                    parentId: nil,
                    index: notebookTreeIndex,
                    selection: treeSelection,
                    expansion: notebookExpansion
                )
                // The tree is one List cell (a VStack); inset it to the same
                // margin the other sidebar rows use.
                .listRowInsets(EdgeInsets(top: 0, leading: DesignTokens.Spacing.sm,
                                          bottom: 0, trailing: DesignTokens.Spacing.sm))
                .listRowSeparator(.hidden)

                if isCreatingTopNotebook {
                    InlineNameField(
                        text: $topNotebookDraftName,
                        placeholder: "New Notebook",
                        systemImage: "folder"
                    ) {
                        let name = topNotebookDraftName.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty {
                            _ = try? NoteStore.shared.createNotebook(name: name)
                        }
                        isCreatingTopNotebook = false
                        topNotebookDraftName = ""
                    } onCancel: {
                        isCreatingTopNotebook = false
                        topNotebookDraftName = ""
                    }
                }

                if !unifiedTags.isEmpty {
                    SidebarRow(isSelected: false, action: {
                        withAnimation(.easeOut(duration: 0.18)) { notesTagsExpanded.toggle() }
                    }) {
                        HStack(spacing: DesignTokens.Spacing.xs) {
                            Label("Tags", systemImage: "tag")
                            Spacer(minLength: DesignTokens.Spacing.xs)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(DesignTokens.Palette.textTertiary)
                                .rotationEffect(.degrees(notesTagsExpanded ? 90 : 0))
                        }
                    }
                    .accessibilityValue(notesTagsExpanded ? "Expanded" : "Collapsed")
                    if notesTagsExpanded {
                        ForEach(unifiedTags, id: \.self) { tag in
                            sidebarLink(.notes(.tag(tag)), verbatim: tag, systemImage: "number", indent: DesignTokens.Spacing.lg)
                        }
                    }
                }

                sidebarLink(.bases, "Bases", systemImage: "tablecells")
                sidebarLink(.notes(.graph), "Graph", systemImage: "circle.hexagongrid")
            }
        } header: {
            SidebarSectionHeader(title: "Notes", isExpanded: $notesExpanded) {
                Menu {
                    Button("New Note") {
                        NotificationCenter.default.post(name: .scribeNewNote, object: nil)
                    }
                    Button("New Notebook") {
                        notesExpanded = true
                        isCreatingTopNotebook = true
                        topNotebookDraftName = ""
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New note or notebook")
                .accessibilityLabel("New note or notebook")
            }
        }
    }

    @ViewBuilder
    private var meetingsSection: some View {
        Section {
            if meetingsExpanded {
                if recording.isRecording {
                    SidebarRow(isSelected: nav.current == .live,
                               action: { nav.navigate(to: .live) }) {
                        LiveSidebarRow(
                            isPaused: recording.isPaused,
                            clock: appState.recordingClock
                        )
                    }
                }
                sidebarLink(.recordings, "Recordings", systemImage: "waveform")
                sidebarLink(.people, "People", systemImage: "person.2")
                sidebarLink(.ask, "Ask Scribe", systemImage: "bubble.left.and.text.bubble.right")
            }
        } header: {
            SidebarSectionHeader(title: "Meetings", isExpanded: $meetingsExpanded)
        }
    }

    @ViewBuilder
    private var projectsSection: some View {
        Section {
            if projectsExpanded {
                ForEach(projectsViewModel.projects) { project in
                    SidebarRow(isSelected: nav.current == .tasks(.project(project.id)),
                               action: { nav.navigate(to: .tasks(.project(project.id))) }) {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            ProjectSidebarRow(project: project)
                            Spacer(minLength: DesignTokens.Spacing.xs)
                            SidebarCount(value: taskCounts.openByProject[project.id] ?? 0)
                        }
                    }
                    .contextMenu {
                        Button {
                            projectEditorMode = .edit(project)
                        } label: {
                            Label("Edit…", systemImage: "pencil")
                        }
                        ProjectAreaMenu(project: project, areas: projectsViewModel.areas) {
                            projectsViewModel.assignArea($0, toProject: project.id)
                        }
                        Button(role: .destructive) {
                            projectPendingDelete = project
                        } label: {
                            Label("Delete project", systemImage: "trash")
                        }
                    }
                    .dropDestination(for: TaskDragPayload.self) { items, _ in
                        for item in items {
                            projectsViewModel.moveTask(taskId: item.id, toProject: project.id)
                        }
                        return !items.isEmpty
                    }
                }
                .onMove { source, destination in
                    projectsViewModel.reorder(from: source, to: destination)
                }

                sidebarLink(.taskCalendar, "Calendar", systemImage: "calendar.badge.clock")
                sidebarLink(.tasks(.someday), "Someday", systemImage: "archivebox")
            }
        } header: {
            SidebarSectionHeader(title: "Projects", isExpanded: $projectsExpanded) {
                SidebarHeaderButton(systemImage: "plus", help: "New project") {
                    projectEditorMode = .create
                }
            }
        }
    }

    @ViewBuilder
    private var sidebarFooter: some View {
        HStack(spacing: 0) {
            Button {
                NotificationCenter.default.post(name: .openScribeSettings,
                                                object: SettingsPane.general)
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(SidebarLabelStyle(isSelected: false))
                    .font(DesignTokens.Typography.sidebarRow)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .frame(height: DesignTokens.Metrics.sidebarRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            Spacer()
            footerIcon(systemImage: "checkmark.circle",
                       help: "Completed tasks",
                       isActive: nav.current == .tasks(.completed)) {
                nav.navigate(to: .tasks(.completed))
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    @ViewBuilder
    private func footerIcon(systemImage: String,
                            help: LocalizedStringKey,
                            isActive: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(isActive ? DesignTokens.Palette.accent : DesignTokens.Palette.textSecondary)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    // Synchronous, during the navigation update: an async fetch renders an
    // empty pane for a frame first.
    private func loadDetailNote(id: String) {
        detailNote = Perf.measure("detail note fetch") {
            try? NoteStore.shared.fetchNote(id: id)
        }
        detailNoteFetchedId = id
    }

    private func reloadTags() {
        let noteTags = (try? NoteStore.shared.allNoteTags()) ?? []
        let taskTags = (try? TaskStore.shared.allTags()) ?? []
        unifiedTags = Array(Set(noteTags + taskTags)).sorted()
    }

    private func scheduleTagReload() {
        tagReloadTask?.cancel()
        tagReloadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            reloadTags()
        }
    }

    /// Rebuilds the notebook-tree lookups; called only when the notebooks or
    /// notes arrays change.
    private func rebuildNotebookTreeIndex() {
        notebookTreeIndex = Perf.measure("notebook tree index") {
            NotebookTreeIndex(notebooks: notebooks, notes: allNotes)
        }
    }

    private func sidebarLink(_ destination: MainSelection,
                             _ title: LocalizedStringKey,
                             systemImage: String,
                             badge: Int = 0) -> some View {
        sidebarLink(destination, label: Label(title, systemImage: systemImage), badge: badge, indent: 0)
    }

    /// Sidebar row whose title is user data (a tag) — shown verbatim.
    private func sidebarLink(_ destination: MainSelection,
                             verbatim title: String,
                             systemImage: String,
                             indent: CGFloat = 0) -> some View {
        sidebarLink(destination, label: Label(title, systemImage: systemImage), badge: 0, indent: indent)
    }

    private func sidebarLink<RowLabel: View>(_ destination: MainSelection,
                                             label: RowLabel,
                                             badge: Int,
                                             indent: CGFloat) -> some View {
        SidebarRow(isSelected: nav.current == destination,
                   indent: indent,
                   action: { nav.navigate(to: destination) }) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                label
                Spacer(minLength: DesignTokens.Spacing.xs)
                SidebarCount(value: badge)
            }
        }
    }

    private var sidebarSearchResults: [Note] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        return allNotes
            .filter {
                $0.title.lowercased().contains(query) ||
                ($0.bodyExcerpt ?? "").lowercased().contains(query)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    @ViewBuilder
    private func notesDetailView(filter: NotesFilter) -> some View {
        switch filter {
        case .daily:
            StandaloneDailyNoteView(onNavigate: { nav.navigate(to: .note($0)) })
        case .graph:
            GraphView(onNavigate: { nav.navigate(to: .note($0)) })
        case .tag(let tag):
            TaggedContentView(
                tag: tag,
                onNavigate: { nav.navigate(to: .note($0)) },
                onNavigateToTask: { nav.navigate(to: .task($0)) }
            )
        case .inbox:
            NotesBrowserView(scope: .inbox)
                .id(NotesFilter.inbox)
        case .notebook(let notebookId):
            NotesBrowserView(scope: .notebook(notebookId))
                .id(NotesFilter.notebook(notebookId))
        case .all:
            NotesBrowserView(scope: .all)
                .id(NotesFilter.all)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch nav.current {
        case .live:
            LiveSessionView(status: recording)
        case .today:
            TodayView(onNavigate: { nav.navigate(to: .note($0)) })
        case .recordings:
            TranscriptArchiveView(onNavigate: { nav.navigate(to: .session($0)) })
        case .tasks(let filter):
            TaskListView(
                filter: filter,
                onOpenRecording: { nav.navigate(to: .session($0)) }
            )
                .id(filter)
        case .taskCalendar:
            TaskCalendarView(onNavigateToNote: { noteId in
                nav.navigate(to: .note(noteId))
            })
        case .note(let id):
            Group {
                // While the new note loads, keep the previous one on screen
                // (same view identity) instead of flashing "not found".
                if let note = detailNote, note.id == id || detailNoteFetchedId != id {
                    NoteDetailView(note: note, onNavigate: { noteId in
                        nav.navigate(to: .note(noteId))
                    })
                    .id(note.id)
                } else if detailNoteFetchedId == id {
                    ContentUnavailableView(
                        "Note not found",
                        systemImage: "note.text",
                        description: Text("This note may have been deleted.")
                    )
                } else {
                    DesignTokens.Palette.surface
                }
            }
            .onAppear {
                if detailNoteFetchedId != id { loadDetailNote(id: id) }
            }
        case .task(let id):
            // Command-bar deep-link to a single task: open the All list and
            // focus it (its inspector opens automatically).
            TaskListView(
                filter: .all,
                focusTaskId: id,
                onOpenRecording: { nav.navigate(to: .session($0)) }
            )
                .id("task-\(id)")
        case .notes(let filter):
            notesDetailView(filter: filter)
        case .bases:
            BasesScreen(onNavigate: { nav.navigate(to: .note($0)) })
        case .ask:
            AskView(onNavigate: { nav.navigate(to: $0) })
        case .people:
            PeopleView(onNavigate: { nav.navigate(to: $0) })
        case .session(let id):
            Group {
                if let session = detailSession, session.id == id || detailSessionFetchedId != id {
                    TranscriptDetailView(session: session)
                        .id(session.id)
                } else if detailSessionFetchedId == id {
                    ContentUnavailableView(
                        "Recording not found",
                        systemImage: "waveform",
                        description: Text("This recording may have been deleted.")
                    )
                } else {
                    DesignTokens.Palette.surface
                }
            }
            .task(id: id) {
                detailSession = Perf.measure("detail session fetch") {
                    try? TranscriptStore.shared.fetchSession(id: id)
                }
                detailSessionFetchedId = id
            }
        }
    }
}

// MARK: - Live sidebar row

/// Compact "Now Recording" entry shown at the top of the sidebar while a
/// session is active. Pulses a recording dot and shows tabular elapsed time
/// so the user can always jump back to the live view, no matter where they
/// browsed off to.
private struct LiveSidebarRow: View {
    let isPaused: Bool
    let clock: RecordingClock

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ZStack {
                if showHalo {
                    RecordingPulseHalo(tint: tint)
                }
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
            }
            .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 0) {
                Text(isPaused ? "Paused" : "Recording")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(.primary)
                RecordingElapsed(clock: clock) { duration in
                    Text(formatted(duration))
                        .font(.system(.caption, design: .monospaced).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    private var tint: Color {
        isPaused ? DesignTokens.Palette.paused : DesignTokens.Palette.recording
    }

    private var showHalo: Bool { !isPaused && !reduceMotion }

    private func formatted(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Welcome state

/// First-run / empty-selection hero. Big serif headline, short supporting
/// copy, one oversized capsule Record CTA, and a calm keyboard-shortcut
/// hint — nothing else. No cards, no badges, no marketing chrome.
private struct WelcomeView: View {

    let isRecording: Bool
    let onRecord: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xxl) {
            Spacer()

            VStack(spacing: DesignTokens.Spacing.lg) {
                Text("SCRIBE")
                    .eyebrowStyle()

                Text(isRecording ? "Listening." : "Ready when you are.")
                    .font(DesignTokens.Typography.display)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("On-device speech recognition for meetings, interviews, and anything else worth remembering. Audio never leaves your Mac.")
                    .font(.system(.body))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HeroRecordButton(isRecording: isRecording, action: onRecord)

            HStack(spacing: DesignTokens.Spacing.xs) {
                Text("or press")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                KeyCapGroup(keys: ["⇧", "⌘", "R"])
                Text("from anywhere")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignTokens.Spacing.xxxl)
        .background(DesignTokens.Palette.surface)
    }
}

// `KeyCapGroup` moved to UI/DesignSystem/KeyCapGroup.swift (kept in the SwiftPM
// target; see Package.swift exclusion note).

// MARK: - Task sidebar items

/// At-a-glance sidebar counts derived from the active (incomplete,
/// non-cancelled) task set — computed client-side from `observeTasks(.all)`.
struct SidebarTaskCounts: Equatable {
    var inbox = 0
    var today = 0      // due today or overdue
    var overdue = 0
    var upcoming = 0   // next 7 days, excluding today
    var openByProject: [String: Int] = [:]

    init() {}

    init(tasks: [TodoTask], now: Date = Date(), calendar: Calendar = .current) {
        let startToday = calendar.startOfDay(for: now)
        let startTomorrow = calendar.date(byAdding: .day, value: 1, to: startToday)!
        let endUpcoming = calendar.date(byAdding: .day, value: 7, to: startTomorrow)!
        for task in tasks {
            if let projectId = task.projectId, !task.isCompleted, !task.isCancelled {
                openByProject[projectId, default: 0] += 1
            }
            if TaskPlanningRules.isInInbox(task) { inbox += 1 }
            if TaskPlanningRules.isInToday(task, now: now, calendar: calendar) { today += 1 }
            if let due = task.dueAt {
                if due < startToday { overdue += 1 }
                if due >= startTomorrow && due < endUpcoming { upcoming += 1 }
            }
        }
    }
}

// MARK: - Project sidebar

/// Drives the create/edit sheet for projects from the sidebar.
// `ProjectEditorMode` moved to ProjectEditorMode.swift (kept in the SwiftPM
// target; see Package.swift exclusion note).

/// Sidebar row for a single project. Renders the project's icon (if set) in
/// its custom color, otherwise falls back to a generic folder.
struct ProjectSidebarRow: View {
    let project: Project

    var body: some View {
        Label {
            Text(project.name)
        } icon: {
            Image(systemName: project.icon ?? "folder")
                .foregroundStyle(tint)
        }
    }

    private var tint: Color {
        if let hex = project.color, let color = Color(hex: hex) { return color }
        return .secondary
    }
}

// `InlineNameField` moved to UI/DesignSystem/InlineNameField.swift (kept in the
// SwiftPM target; see Package.swift exclusion note).
