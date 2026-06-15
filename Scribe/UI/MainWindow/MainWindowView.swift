import SwiftUI

// `MainSelection`, `NotesFilter`, and `Surface` live in MainSelection.swift so
// they stay in the SwiftPM test target while this view file is excluded from it
// (see the EDITOR EXCLUSION BOUNDARY note in Package.swift).

/// The main window — sidebar of past transcripts + settings panes, detail
/// pane shows whichever is selected. Primary UI for the app.
struct MainWindowView: View {

    @EnvironmentObject var appState: AppState
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
    @State private var tasksExpanded: Bool = true
    @State private var projectsExpanded: Bool = true
    @State private var notesExpanded: Bool = true
    @State private var notebooksExpanded: Bool = true
    @State private var notesTagsExpanded: Bool = false
    @State private var unifiedTags: [String] = []
    @State private var notebooks: [Notebook] = []
    @State private var allNotes: [Note] = []
    @State private var taskCounts = SidebarTaskCounts()
    @State private var showUniversalSearch: Bool = false
    @State private var isCreatingTopNotebook: Bool = false
    @State private var topNotebookDraftName: String = ""
    @State private var detailNote: Note? = nil
    @State private var detailSession: Session? = nil
    @State private var tagReloadTask: Task<Void, Never>? = nil
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showOnboarding = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    /// Bridges `List(selection:)` and child views (which traffic in
    /// `MainSelection?`) to the history-backed coordinator. A nil set
    /// (clicking empty space) is ignored so the detail pane never blanks.
    private var selectionBinding: Binding<MainSelection?> {
        Binding(get: { nav.current }, set: { nav.select($0) })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
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
                        appState: appState,
                        onPauseToggle: {
                            if appState.audioManager.isPaused {
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
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    nav.goBack()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .help("Back (⌘[)")
                .accessibilityLabel("Back")
                .disabled(!nav.canGoBack)
            }
            ToolbarItem(placement: .navigation) {
                RecordingStatusPill(audioManager: appState.audioManager, appState: appState)
                    .onTapGesture {
                        if appState.isTranscribing {
                            nav.navigate(to: .live)
                        }
                    }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                recordingToolbar
            }
        }
        .onAppear {
            projectsViewModel.start()
            reloadTags()
            // The coordinator defaults to .today; only the active-recording
            // case overrides the initial destination (no history entry).
            if appState.isTranscribing {
                nav.replaceCurrent(.live)
            }
            appState.currentSelection = nav.current
            // Never show onboarding in the screenshot/UI-test fixture mode,
            // regardless of when the fixture sets `hasCompletedOnboarding`
            // (avoids a set-vs-read race that left the Welcome sheet — and its
            // mic-permission step — covering every captured screen).
            if !hasCompletedOnboarding && !AppLaunchEnvironment.usesUITestFixtures {
                showOnboarding = true
            }
        }
        .onDisappear { projectsViewModel.stop() }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding, audioManager: appState.audioManager)
        }
        .onReceive(NoteStore.shared.observeNotes().replaceError(with: [])) { notes in
            allNotes = notes
            scheduleTagReload()
        }
        .onReceive(NoteStore.shared.observeNotebooks().replaceError(with: [])) { notebooks = $0 }
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .scribeGoBack)) { _ in nav.goBack() }
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
        .onChange(of: appState.isTranscribing) { _, isRecording in
            // Session started → flip to the inline live view via the tested
            // RecordingNavigationPolicy: it returns .live unless the user is
            // already on a Note (whose inline pane handles streaming) or the
            // auto-create path already navigated to a note.
            if let dest = RecordingNavigationPolicy.destination(
                currentSelection: nav.current, isRecording: isRecording
            ) {
                withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
                    nav.navigate(to: dest)
                }
            }
            // Session stopped → if the user was watching the live view (which
            // goes blank on stop), take them to the finished transcript.
            if !isRecording,
               let dest = RecordingNavigationPolicy.stopDestination(
                currentSelection: nav.current,
                finishedSessionId: appState.lastFinishedSessionId
               ) {
                withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
                    nav.navigate(to: dest)
                }
            }
        }
        .onChange(of: nav.current) { _, newValue in
            appState.currentSelection = newValue
        }
    }

    // MARK: - Recording Toolbar

    @ViewBuilder
    private var recordingToolbar: some View {
        let isRecording = appState.isTranscribing
        let isPaused = appState.audioManager.isPaused

        if isRecording {
            Button {
                if isPaused {
                    Task { await appDelegate.resumeRecording() }
                } else {
                    appDelegate.pauseRecording()
                }
            } label: {
                Label(isPaused ? "Resume" : "Pause",
                      systemImage: isPaused ? "play.fill" : "pause.fill")
            }
            .help(isPaused ? "Resume recording" : "Pause recording")
        }

        Button {
            Task { await appDelegate.toggleRecording() }
        } label: {
            Label(
                isRecording ? "Stop" : "Record",
                systemImage: isRecording ? "stop.circle.fill" : "record.circle"
            )
            .foregroundStyle(isRecording ? DesignTokens.Palette.recording : .primary)
        }
        .help(isRecording ? "Stop the current session" : "Start a new recording")
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: selectionBinding) {
            if searchText.isEmpty {
                let surface = nav.current.surface

                // MARK: Capture surface
                if surface == .capture {
                if appState.isTranscribing {
                    Section {
                        NavigationLink(value: MainSelection.live) {
                            LiveSidebarRow(
                                isPaused: appState.audioManager.isPaused,
                                duration: appState.audioManager.recordingDuration
                            )
                        }
                    } header: {
                        Text("Now")
                            .eyebrowStyle()
                    }
                }

                Section {
                    NavigationLink(value: MainSelection.today) {
                        Label("Today", systemImage: "sun.max")
                    }
                    .badge(taskCounts.today)
                    NavigationLink(value: MainSelection.recordings) {
                        Label("Recordings", systemImage: "waveform")
                    }
                }
                }  // end Capture surface

                // MARK: Tasks surface
                if surface == .tasks {
                Section {
                    if tasksExpanded {
                        ForEach(TaskSidebarItem.unifiedSidebarFilters) { item in
                            NavigationLink(value: MainSelection.tasks(item.filter)) {
                                Label(item.title, systemImage: item.systemImage)
                            }
                            .badge(taskBadge(for: item.filter))
                        }
                        NavigationLink(value: MainSelection.taskCalendar) {
                            Label("Calendar", systemImage: "calendar")
                        }
                    }
                } header: {
                    CollapsibleSectionHeader(title: "Tasks", isExpanded: $tasksExpanded)
                }

                Section {
                    if projectsExpanded {
                        ForEach(projectsViewModel.projects) { project in
                            NavigationLink(value: MainSelection.tasks(.project(project.id))) {
                                ProjectSidebarRow(project: project)
                            }
                            .contextMenu {
                                Button {
                                    projectEditorMode = .edit(project)
                                } label: {
                                    Label("Edit…", systemImage: "pencil")
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
                    }
                } header: {
                    HStack(alignment: .center) {
                        CollapsibleSectionHeader(title: "Projects", isExpanded: $projectsExpanded)
                        Spacer()
                        Button {
                            projectEditorMode = .create
                        } label: {
                            Image(systemName: "plus.circle")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("New project")
                    }
                }
                }  // end Tasks surface

                // MARK: Notes surface
                if surface == .notes {
                Section {
                    if notesExpanded {
                        NavigationLink(value: MainSelection.notes(.all)) {
                            Label("All Notes", systemImage: "doc.on.doc")
                        }
                        NavigationLink(value: MainSelection.notes(.graph)) {
                            Label("Graph", systemImage: "circle.hexagongrid")
                        }
                        NavigationLink(value: MainSelection.bases) {
                            Label("Bases", systemImage: "tablecells")
                        }
                    }
                } header: {
                    HStack(alignment: .center) {
                        CollapsibleSectionHeader(title: "Notes", isExpanded: $notesExpanded)
                        Spacer()
                        Button {
                            let note = try? NoteStore.shared.createNote(title: "", body: "")
                            if let note { nav.navigate(to: .note(note.id)) }
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("New note (⌘N)")
                    }
                }

                Section {
                    if notebooksExpanded {
                        NotebookTreeView(
                            parentId: nil,
                            notebooks: notebooks,
                            notes: allNotes,
                            selection: selectionBinding
                        )

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
                    }
                } header: {
                    HStack(alignment: .center) {
                        CollapsibleSectionHeader(title: "Notebooks", isExpanded: $notebooksExpanded)
                        Spacer()
                        Button {
                            notebooksExpanded = true
                            isCreatingTopNotebook = true
                            topNotebookDraftName = ""
                        } label: {
                            Image(systemName: "plus.circle")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("New notebook")
                    }
                }

                Section {
                    if notesTagsExpanded {
                        ForEach(unifiedTags, id: \.self) { tag in
                            NavigationLink(value: MainSelection.notes(.tag(tag))) {
                                Label(tag, systemImage: "tag")
                            }
                        }
                    }
                } header: {
                    CollapsibleSectionHeader(title: "Tags", isExpanded: $notesTagsExpanded)
                }
                }  // end Notes surface
            } else {
                Section {
                    let results = sidebarSearchResults
                    if results.isEmpty {
                        Label("No results", systemImage: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .font(DesignTokens.Typography.callout)
                    } else {
                        ForEach(results) { note in
                            NavigationLink(value: MainSelection.note(note.id)) {
                                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                                    Text(note.title.isEmpty ? "Untitled" : note.title)
                                        .font(DesignTokens.Typography.body)
                                        .fontWeight(.medium)
                                        .lineLimit(1)
                                    Text(note.updatedAt, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Notes")
                        .eyebrowStyle()
                }
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search…")
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
        .safeAreaInset(edge: .top, spacing: 0) {
            surfaceSwitcher
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarFooter
        }
    }

    /// Arc-style top-level surface switcher. Reflects the active selection's
    /// surface and jumps to that surface's default destination (⌘1/2/3 mirror
    /// this via the Go menu). Tapping the already-active surface is a no-op so
    /// it doesn't reset an open note/task back to the default.
    private var surfaceSwitcher: some View {
        Picker("Surface", selection: Binding(
            get: { nav.current.surface },
            set: { newSurface in
                if newSurface != nav.current.surface {
                    nav.navigate(to: newSurface.defaultSelection)
                }
            }
        )) {
            ForEach(Surface.allCases) { surface in
                Text(surface.title).tag(surface)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.top, DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.xs)
        .background(.bar)
        .accessibilityLabel("Surface")
        .accessibilityHint("Switch between Capture, Notes and Tasks")
    }

    /// Footer icon strip for rarely-used destinations. Avoids dedicating
    /// entire sidebar sections to views opened a few times per week.
    @ViewBuilder
    private var sidebarFooter: some View {
        HStack(spacing: 0) {
            footerIcon(systemImage: "checkmark.circle",
                       help: "Completed tasks",
                       isActive: nav.current == .tasks(.completed)) {
                nav.navigate(to: .tasks(.completed))
            }
            Spacer()
            footerIcon(systemImage: "gearshape",
                       help: "Settings (⌘,)",
                       isActive: false) {
                NotificationCenter.default.post(name: .openScribeSettings,
                                                object: SettingsPane.general)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    @ViewBuilder
    private func footerIcon(systemImage: String,
                            help: String,
                            isActive: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func reloadTags() {
        let noteTags = (try? NoteStore.shared.allNoteTags()) ?? []
        let taskTags = (try? TaskStore.shared.allTags()) ?? []
        unifiedTags = Array(Set(noteTags + taskTags)).sorted()
    }

    /// Sidebar count badge for a smart-filter row (0 is hidden by SwiftUI).
    private func taskBadge(for filter: TaskStore.Filter) -> Int {
        switch filter {
        case .inbox:    return taskCounts.inbox
        case .upcoming: return taskCounts.upcoming
        case .today:    return taskCounts.today
        default:        return 0
        }
    }

    private func scheduleTagReload() {
        tagReloadTask?.cancel()
        tagReloadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            reloadTags()
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
            LiveSessionView()
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
                if let note = detailNote, note.id == id {
                    NoteDetailView(note: note, onNavigate: { noteId in
                        nav.navigate(to: .note(noteId))
                    })
                    .id(id)
                } else {
                    ContentUnavailableView(
                        "Note not found",
                        systemImage: "note.text",
                        description: Text("This note may have been deleted.")
                    )
                }
            }
            .task(id: id) {
                detailNote = try? NoteStore.shared.fetchNote(id: id)
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
        case .session(let id):
            Group {
                if let session = detailSession, session.id == id {
                    TranscriptDetailView(session: session)
                        .id(id)
                } else {
                    ContentUnavailableView(
                        "Recording not found",
                        systemImage: "waveform",
                        description: Text("This recording may have been deleted.")
                    )
                }
            }
            .task(id: id) {
                detailSession = try? TranscriptStore.shared.fetchSession(id: id)
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
    let duration: TimeInterval

    @State private var pulse: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .scaleEffect(showHalo ? (0.9 + pulse * 0.5) : 0.6)
                    .opacity(showHalo ? (0.6 - pulse * 0.6) : 0)
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
            }
            .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 0) {
                Text(isPaused ? "Paused" : "Recording")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(formatted(duration))
                    .font(.system(.caption, design: .monospaced).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = 1
            }
        }
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

                Text("On-device speech recognition for meetings, interviews, and anything else worth remembering. Nothing leaves your Mac.")
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

// MARK: - Collapsible section header

private struct CollapsibleSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .eyebrowStyle()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeOut(duration: 0.18), value: isExpanded)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Task sidebar items

/// At-a-glance sidebar counts derived from the active (incomplete,
/// non-cancelled) task set — computed client-side from `observeTasks(.all)`.
struct SidebarTaskCounts: Equatable {
    var inbox = 0
    var today = 0      // due today or overdue
    var overdue = 0
    var upcoming = 0   // next 7 days, excluding today

    init() {}

    init(tasks: [TodoTask], now: Date = Date(), calendar: Calendar = .current) {
        let startToday = calendar.startOfDay(for: now)
        let startTomorrow = calendar.date(byAdding: .day, value: 1, to: startToday)!
        let endUpcoming = calendar.date(byAdding: .day, value: 7, to: startTomorrow)!
        for task in tasks {
            if task.projectId == nil { inbox += 1 }
            if let due = task.dueAt {
                if due < startTomorrow { today += 1 }
                if due < startToday { overdue += 1 }
                if due >= startTomorrow && due < endUpcoming { upcoming += 1 }
            }
        }
    }
}

/// Smart filters shown under the "Tasks" sidebar header: Inbox, Today, Upcoming, All, Completed.
struct TaskSidebarItem: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let filter: TaskStore.Filter

    static let smartFilters: [TaskSidebarItem] = [
        .init(id: "inbox",    title: "Inbox",    systemImage: "tray",            filter: .inbox),
        .init(id: "today",    title: "Today",    systemImage: "sun.max",         filter: .today),
        .init(id: "upcoming", title: "Upcoming", systemImage: "calendar",        filter: .upcoming),
        .init(id: "all",      title: "All",      systemImage: "list.bullet",     filter: .all),
        .init(id: "completed", title: "Completed", systemImage: "checkmark.circle", filter: .completed)
    ]

    /// Subset shown in the sidebar after Slice E — "Completed" moved to the
    /// footer icon strip, "All" stays in the body view as a filter chip.
    static let sidebarFilters: [TaskSidebarItem] = smartFilters.filter { item in
        switch item.filter {
        case .completed, .all: return false
        default: return true
        }
    }

    /// After Slice G the unified "Today" destination replaces the per-section
    /// Today filter; sidebar lists Inbox + Upcoming under Tasks.
    static let unifiedSidebarFilters: [TaskSidebarItem] = sidebarFilters.filter { item in
        if case .today = item.filter { return false }
        return true
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
