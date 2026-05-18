import SwiftUI

/// Destination a user can navigate to from the main window's sidebar. Combines
/// transcript sessions with settings panes and, while a session is running,
/// the live-recording view so there's only ever one window to look at.
enum MainSelection: Hashable {
    case live
    case tasks(TaskStore.Filter)
    case taskCalendar
    case note(String)           // noteId
    case notes(NotesFilter)
    case settings(SettingsPane)
}

enum NotesFilter: Hashable {
    case all
    case inbox
    case today
    case daily
    case notebook(String)   // notebookId
    case tag(String)
    case graph
}

/// The main window — sidebar of past transcripts + settings panes, detail
/// pane shows whichever is selected. Primary UI for the app.
struct MainWindowView: View {

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var appDelegate: AppDelegate
    @StateObject private var projectsViewModel = ProjectsViewModel()
    @State private var searchText: String = ""
    @State private var selection: MainSelection?
    @State private var projectEditorMode: ProjectEditorMode?
    @State private var tasksExpanded: Bool = true
    @State private var projectsExpanded: Bool = true
    @State private var notesExpanded: Bool = true
    @State private var notebooksExpanded: Bool = true
    @State private var notesTagsExpanded: Bool = false
    @State private var settingsExpanded: Bool = false
    @State private var unifiedTags: [String] = []
    @State private var notebooks: [Notebook] = []
    @State private var allNotes: [Note] = []
    @State private var showUniversalSearch: Bool = false
    @State private var isCreatingNotebook: Bool = false
    @State private var notebookDraftName: String = ""
    @State private var renamingNotebookId: String? = nil
    @State private var inlineRenameName: String = ""
    @State private var detailNote: Note? = nil
    @State private var todayNote: Note? = nil
    @State private var tagReloadTask: Task<Void, Never>? = nil

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            detail
                .errorBanner(appState)
        }
        .frame(minWidth: 920, minHeight: 620)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                RecordingStatusPill(audioManager: appState.audioManager, appState: appState)
                    .onTapGesture {
                        if appState.isTranscribing {
                            selection = .live
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
            if selection == nil {
                if appState.isTranscribing {
                    selection = .live
                } else {
                    selection = .tasks(.today)
                }
            }
            appState.currentSelection = selection
        }
        .onDisappear { projectsViewModel.stop() }
        .onReceive(NoteStore.shared.observeNotes().replaceError(with: [])) { _ in scheduleTagReload() }
        .onReceive(NoteStore.shared.observeNotebooks().replaceError(with: [])) { notebooks = $0 }
        .onReceive(NoteStore.shared.observeAllNotes().replaceError(with: [])) { allNotes = $0 }
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
                        selection = dest
                    }
                    .padding(.top, 60)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .background(
            Button("") { showUniversalSearch.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .hidden()
        )
        .onReceive(NotificationCenter.default.publisher(for: .openScribeSettings)) { note in
            let pane = (note.object as? SettingsPane) ?? .general
            selection = .settings(pane)
        }
        .onReceive(NotificationCenter.default.publisher(for: .scribeRequestNavigateToNote)) { note in
            if let id = note.userInfo?["noteId"] as? String {
                selection = .note(id)
            }
        }
        .onChange(of: appState.isTranscribing) { _, isRecording in
            // Session started → flip to the inline live view so the user
            // immediately sees the streaming transcript. Skip the flip when
            // the user is already viewing a Note — the note's own live pane
            // handles in-place streaming, and AppDelegate may also be about
            // to post .scribeRequestNavigateToNote (auto-create path). Both
            // cases produce a brief flash to .live without this guard.
            if isRecording {
                if case .note = selection { return }
                withAnimation(.easeOut(duration: DesignTokens.Motion.standard)) {
                    selection = .live
                }
            }
        }
        .onChange(of: selection) { _, newValue in
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
        List(selection: $selection) {
            if searchText.isEmpty {
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
                    if tasksExpanded {
                        ForEach(TaskSidebarItem.smartFilters) { item in
                            NavigationLink(value: MainSelection.tasks(item.filter)) {
                                Label(item.title, systemImage: item.systemImage)
                            }
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
                                    projectsViewModel.delete(id: project.id)
                                    if case .tasks(.project(let id)) = selection, id == project.id {
                                        selection = .tasks(.inbox)
                                    }
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

                Section {
                    if notesExpanded {
                        NavigationLink(value: MainSelection.notes(.today)) {
                            Label("Today's Note", systemImage: "note.text")
                        }
                        NavigationLink(value: MainSelection.notes(.inbox)) {
                            Label("Unfiled", systemImage: "tray")
                        }
                        NavigationLink(value: MainSelection.notes(.all)) {
                            Label("All Notes", systemImage: "doc.on.doc")
                        }
                        NavigationLink(value: MainSelection.notes(.daily)) {
                            Label("All Daily Notes", systemImage: "calendar.badge.clock")
                        }
                        NavigationLink(value: MainSelection.notes(.graph)) {
                            Label("Graph", systemImage: "circle.hexagongrid")
                        }
                    }
                } header: {
                    HStack(alignment: .center) {
                        CollapsibleSectionHeader(title: "Notes", isExpanded: $notesExpanded)
                        Spacer()
                        Button {
                            let note = try? NoteStore.shared.createNote(title: "", body: "")
                            if let note { selection = .note(note.id) }
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("New note (⌘N)")
                        .keyboardShortcut("n", modifiers: .command)
                    }
                }

                Section {
                    if notebooksExpanded {
                        ForEach(notebooks) { nb in
                            if renamingNotebookId == nb.id {
                                InlineNameField(
                                    text: $inlineRenameName,
                                    placeholder: nb.name,
                                    systemImage: "folder"
                                ) {
                                    let name = inlineRenameName.trimmingCharacters(in: .whitespaces)
                                    if !name.isEmpty {
                                        var copy = nb
                                        copy.name = name
                                        try? NoteStore.shared.updateNotebook(copy)
                                    }
                                    renamingNotebookId = nil
                                } onCancel: {
                                    renamingNotebookId = nil
                                }
                            } else {
                                NavigationLink(value: MainSelection.notes(.notebook(nb.id))) {
                                    Label(nb.name, systemImage: "folder")
                                }
                                .contextMenu {
                                    Button {
                                        renamingNotebookId = nb.id
                                        inlineRenameName = nb.name
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        try? NoteStore.shared.deleteNotebook(id: nb.id)
                                        if case .notes(.notebook(let id)) = selection, id == nb.id {
                                            selection = .notes(.all)
                                        }
                                    } label: {
                                        Label("Delete Notebook", systemImage: "trash")
                                    }
                                }
                            }
                        }

                        if isCreatingNotebook {
                            InlineNameField(
                                text: $notebookDraftName,
                                placeholder: "New Notebook",
                                systemImage: "folder"
                            ) {
                                let name = notebookDraftName.trimmingCharacters(in: .whitespaces)
                                if !name.isEmpty {
                                    try? NoteStore.shared.createNotebook(name: name)
                                }
                                isCreatingNotebook = false
                                notebookDraftName = ""
                            } onCancel: {
                                isCreatingNotebook = false
                                notebookDraftName = ""
                            }
                        }
                    }
                } header: {
                    HStack(alignment: .center) {
                        CollapsibleSectionHeader(title: "Notebooks", isExpanded: $notebooksExpanded)
                        Spacer()
                        Button {
                            notebooksExpanded = true
                            isCreatingNotebook = true
                            notebookDraftName = ""
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

                Section {
                    if settingsExpanded {
                        ForEach(SettingsPane.allCases) { pane in
                            NavigationLink(value: MainSelection.settings(pane)) {
                                Label(pane.title, systemImage: pane.systemImage)
                            }
                        }
                    }
                } header: {
                    CollapsibleSectionHeader(title: "Settings", isExpanded: $settingsExpanded)
                }
            } else {
                Section {
                    let results = sidebarSearchResults
                    if results.isEmpty {
                        Label("No results", systemImage: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        ForEach(results) { note in
                            NavigationLink(value: MainSelection.note(note.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.title.isEmpty ? "Untitled" : note.title)
                                        .font(.body)
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

    private var sidebarSearchResults: [Note] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        return allNotes
            .filter {
                $0.title.lowercased().contains(query) ||
                $0.body.lowercased().contains(query)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    @ViewBuilder
    private func notesDetailView(filter: NotesFilter) -> some View {
        switch filter {
        case .today:
            Group {
                if let note = todayNote {
                    NoteDetailView(note: note, onNavigate: { selection = .note($0) })
                        .id(note.id)
                } else {
                    DailyNoteView(onNavigate: { selection = .note($0) })
                }
            }
            .task {
                todayNote = try? NoteStore.shared.fetchExistingDailyNote(for: Date())
            }
        case .daily:
            DailyNoteView(onNavigate: { selection = .note($0) })
        case .graph:
            GraphView(onNavigate: { selection = .note($0) })
        case .tag(let tag):
            TaggedContentView(tag: tag, onNavigate: { selection = .note($0) })
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
        switch selection {
        case .live:
            LiveSessionView()
        case .tasks(let filter):
            TaskListView(filter: filter)
                .id(filter)
        case .taskCalendar:
            TaskCalendarView(onNavigateToNote: { noteId in
                selection = .note(noteId)
            })
        case .note(let id):
            Group {
                if let note = detailNote, note.id == id {
                    NoteDetailView(note: note, onNavigate: { noteId in
                        selection = .note(noteId)
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
        case .notes(let filter):
            notesDetailView(filter: filter)
        case .settings(let pane):
            SettingsPaneView(pane: pane, audioManager: appState.audioManager)
        case .none:
            WelcomeView(
                isRecording: appState.isTranscribing,
                onRecord: { Task { await appDelegate.toggleRecording() } }
            )
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

/// Tiny inline "keyboard key caps" renderer for shortcut hints.
private struct KeyCapGroup: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(DesignTokens.Palette.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
                    )
            }
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let openScribeSettings = Notification.Name("scribe.openSettings")
    static let scribeSessionUpdated = Notification.Name("scribe.sessionUpdated")
    static let scribeRequestNavigateToNote = Notification.Name("scribe.requestNavigateToNote")
}

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
}

// MARK: - Project sidebar

/// Drives the create/edit sheet for projects from the sidebar.
enum ProjectEditorMode: Identifiable, Hashable {
    case create
    case edit(Project)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let project): return "edit-\(project.id)"
        }
    }
}

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

// MARK: - Inline name field

/// Inline editable text field for sidebar rows (notebook create / rename).
/// Commits on Return, cancels on Escape.
struct InlineNameField: View {
    @Binding var text: String
    let placeholder: String
    let systemImage: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: systemImage)
                .imageScale(.small)
                .foregroundStyle(Color.accentColor)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isFocused)
                .onSubmit { onCommit() }
                .onExitCommand { onCancel() }
        }
        .padding(.vertical, 2)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
                .padding(.horizontal, -4)
        )
        .onAppear { isFocused = true }
    }
}
