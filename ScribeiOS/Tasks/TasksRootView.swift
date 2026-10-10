import SwiftUI

/// Root of the Tasks area on iPhone and iPad.
///
/// - iPad (regular width): three columns — lists sidebar (smart lists,
///   areas → projects, tags, planner), the selected list, and the selected
///   task's editor.
/// - iPhone (compact width): one navigation stack — sidebar → list → task.
///
/// A floating + button (⌘N) opens quick add for the current list. Tasks
/// can be dragged onto sidebar lists and projects to move / plan them.
struct TasksRootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var library = TasksLibraryModel(store: TaskStore.shared)
    @ObservedObject private var openRequest = TasksOpenRequest.shared

    @State private var destination: TaskListDestination? = .today
    @State private var selectedTaskId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var phonePath = NavigationPath()
    /// The list currently on top of the iPhone stack (quick-add context).
    @State private var phoneDestination: TaskListDestination?
    @State private var quickAdd: TasksQuickAddRequest?
    /// iPhone: a task editor is on top (the + button hides there).
    @State private var phoneDetailVisible = false

    var body: some View {
        Group {
            if sizeClass == .regular {
                splitView
            } else {
                phoneStack
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if sizeClass == .regular || !phoneDetailVisible {
                TasksAddButton { openQuickAdd(headingId: nil) }
            }
        }
        .sheet(item: $quickAdd) { request in
            TaskQuickAddSheet(destination: request.destination, headingId: request.headingId, library: library)
        }
        .onAppear {
            TasksIOSBootstrap.start()
            library.start()
            consumeOpenRequest()
        }
        .onChange(of: openRequest.taskId) { consumeOpenRequest() }
    }

    // MARK: - iPad

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            TasksSidebarView(library: library, selection: $destination)
                .navigationTitle("Tasks")
        } content: {
            if let destination {
                listContent(for: destination, onOpenTask: { selectedTaskId = $0 })
                    .id(destination)
            } else {
                ContentUnavailableView("Choose a list", systemImage: "sidebar.left")
            }
        } detail: {
            NavigationStack {
                if let selectedTaskId {
                    TaskDetailScreen(taskId: selectedTaskId, onDeleted: { self.selectedTaskId = nil })
                        .id(selectedTaskId)
                } else {
                    ContentUnavailableView("No task selected", systemImage: "checklist",
                                           description: Text("Pick a task to see its details."))
                }
            }
        }
        .onChange(of: destination) { selectedTaskId = nil }
    }

    // MARK: - iPhone

    private var phoneStack: some View {
        NavigationStack(path: $phonePath) {
            TasksSidebarView(library: library, selection: nil)
                .navigationTitle("Tasks")
                .navigationDestination(for: TaskListDestination.self) { destination in
                    listContent(for: destination, onOpenTask: nil)
                        .onAppear { phoneDestination = destination }
                }
                .navigationDestination(for: TaskRouteID.self) { route in
                    TaskDetailScreen(taskId: route.id)
                        .onAppear { phoneDetailVisible = true }
                        .onDisappear { phoneDetailVisible = false }
                }
        }
        .onChange(of: phonePath.count) { _, count in
            if count == 0 { phoneDestination = nil }
        }
    }

    @ViewBuilder
    private func listContent(for destination: TaskListDestination, onOpenTask: ((String) -> Void)?) -> some View {
        if destination == .planner {
            TasksDayPlannerScreen(library: library, onOpenTask: onOpenTask)
        } else {
            TasksListScreen(destination: destination, library: library,
                            onOpenTask: onOpenTask, selectedTaskId: selectedTaskId,
                            onQuickAdd: { headingId in openQuickAdd(headingId: headingId, in: destination) })
        }
    }

    // MARK: - Actions

    private var currentDestination: TaskListDestination? {
        sizeClass == .regular ? destination : phoneDestination
    }

    private func openQuickAdd(headingId: String?, in list: TaskListDestination? = nil) {
        quickAdd = TasksQuickAddRequest(destination: list ?? currentDestination, headingId: headingId)
    }

    private func consumeOpenRequest() {
        guard let taskId = openRequest.taskId else { return }
        openRequest.taskId = nil
        if sizeClass == .regular {
            selectedTaskId = taskId
        } else {
            phonePath.append(TaskRouteID(id: taskId))
        }
    }
}

/// What the quick-add sheet was opened for.
struct TasksQuickAddRequest: Identifiable {
    let id = UUID()
    let destination: TaskListDestination?
    let headingId: String?
}

/// Compatibility name for the old iOS Tasks tab (the shell may still refer
/// to it); the area's root view is `TasksRootView`.
typealias TasksScreen = TasksRootView

// MARK: - Sidebar

/// Lists sidebar: smart lists (with counts), planner, areas → projects,
/// projects without an area, tags, and the iCloud sync status. Rows accept
/// dropped tasks.
struct TasksSidebarView: View {
    @ObservedObject var library: TasksLibraryModel
    /// iPad selection; nil on iPhone (rows push instead).
    var selection: Binding<TaskListDestination?>?

    @ObservedObject private var syncStatus = TasksCloudSyncStatus.shared
    @State private var prompt: TasksSidebarPrompt?
    @State private var promptText = ""
    @State private var pendingDelete: TasksSidebarPrompt?

    private var actions: TaskMobileActions { .live }

    var body: some View {
        Group {
            if let selection {
                List(selection: selection) { rows }
            } else {
                List { rows }
            }
        }
        .listStyle(.sidebar)
        .refreshable { await syncStatus.syncNow() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { startPrompt(.newProject(areaId: nil)) } label: { Label("New Project", systemImage: "folder.badge.plus") }
                    Button { startPrompt(.newArea) } label: { Label("New Area", systemImage: "square.grid.2x2") }
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityLabel("New project or area")
            }
        }
        .alert(prompt?.title ?? "", isPresented: Binding(
            get: { prompt != nil },
            set: { if !$0 { prompt = nil } }
        )) {
            TextField("Name", text: $promptText)
            Button("Save") { commitPrompt() }
            Button("Cancel", role: .cancel) { prompt = nil }
        }
        .confirmationDialog(pendingDelete?.deleteTitle ?? "", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { commitDelete() }
        } message: {
            Text(pendingDelete?.deleteMessage ?? "")
        }
    }

    @ViewBuilder
    private var rows: some View {
        Section {
            ForEach(TaskListDestination.smartLists) { destination in
                row(destination)
            }
            row(.planner)
        }

        let loose = library.looseProjects
        if !loose.isEmpty {
            Section("Projects") {
                ForEach(loose) { project in projectRow(project) }
            }
        }

        ForEach(library.areas) { area in
            Section {
                row(.area(area.id))
                    .contextMenu { areaMenu(area) }
                ForEach(library.projects(inArea: area.id)) { project in projectRow(project) }
            } header: {
                Text(area.name)
            }
        }

        if !library.tags.isEmpty {
            Section("Tags") {
                ForEach(library.tags, id: \.self) { tag in row(.tag(tag)) }
            }
        }

        Section {
            syncFooter
        }
    }

    private func row(_ destination: TaskListDestination) -> some View {
        NavigationLink(value: destination) {
            HStack {
                Label(library.title(for: destination), systemImage: library.systemImage(for: destination))
                Spacer()
                if destination == .today, library.overdueCount > 0 {
                    Text("\(library.overdueCount)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.red))
                        .accessibilityLabel("\(library.overdueCount) overdue")
                }
                if let count = library.count(for: destination) {
                    Text("\(count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tag(destination)
        .dropDestination(for: String.self) { items, _ in
            guard destination.acceptsDrops else { return false }
            return actions.drop(tokens: items, onto: destination)
        }
    }

    private func projectRow(_ project: Project) -> some View {
        row(.project(project.id))
            .contextMenu {
                Button { startPrompt(.renameProject(project)) } label: { Label("Rename…", systemImage: "pencil") }
                Menu {
                    Button("No Area") { library.moveProject(project, toArea: nil) }
                    ForEach(library.areas) { area in
                        Button(area.name) { library.moveProject(project, toArea: area.id) }
                    }
                } label: { Label("Move to Area", systemImage: "square.grid.2x2") }
                Divider()
                Button(role: .destructive) { pendingDelete = .renameProject(project) } label: {
                    Label("Delete Project…", systemImage: "trash")
                }
            }
    }

    @ViewBuilder
    private func areaMenu(_ area: TaskArea) -> some View {
        Button { startPrompt(.newProject(areaId: area.id)) } label: { Label("New Project in Area…", systemImage: "folder.badge.plus") }
        Button { startPrompt(.renameArea(area)) } label: { Label("Rename…", systemImage: "pencil") }
        Divider()
        Button(role: .destructive) { pendingDelete = .renameArea(area) } label: { Label("Delete Area…", systemImage: "trash") }
    }

    private var syncFooter: some View {
        HStack(spacing: 8) {
            if syncStatus.isSyncing {
                ProgressView()
            } else {
                Image(systemName: syncStatus.symbol)
                    .foregroundStyle(syncStatus.lastError == nil ? Color.secondary : Color.orange)
            }
            Text(syncStatus.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onAppear { syncStatus.refresh() }
    }

    // MARK: Prompts

    private func startPrompt(_ next: TasksSidebarPrompt) {
        promptText = next.initialText
        prompt = next
    }

    private func commitPrompt() {
        guard let current = prompt else { return }
        switch current {
        case .newProject(let areaId):     library.createProject(named: promptText, inArea: areaId)
        case .newArea:                    library.createArea(named: promptText)
        case .renameProject(let project): library.renameProject(project, to: promptText)
        case .renameArea(let area):       library.renameArea(area, to: promptText)
        }
        prompt = nil
    }

    private func commitDelete() {
        guard let target = pendingDelete else { return }
        switch target {
        case .renameProject(let project): library.deleteProject(project)
        case .renameArea(let area):       library.deleteArea(area)
        case .newProject, .newArea:       break
        }
        pendingDelete = nil
    }
}

/// Name prompts (and delete confirmations) in the sidebar.
enum TasksSidebarPrompt: Equatable {
    case newProject(areaId: String?)
    case newArea
    case renameProject(Project)
    case renameArea(TaskArea)

    var title: String {
        switch self {
        case .newProject:    return "New Project"
        case .newArea:       return "New Area"
        case .renameProject: return "Rename Project"
        case .renameArea:    return "Rename Area"
        }
    }

    var initialText: String {
        switch self {
        case .renameProject(let project): return project.name
        case .renameArea(let area):       return area.name
        case .newProject, .newArea:       return ""
        }
    }

    var deleteTitle: String {
        switch self {
        case .renameProject(let project): return "Delete “\(project.name)”?"
        case .renameArea(let area):       return "Delete “\(area.name)”?"
        case .newProject, .newArea:       return ""
        }
    }

    var deleteMessage: String {
        switch self {
        case .renameProject: return "Its tasks move to the Inbox."
        case .renameArea:    return "Its projects and tasks stay, without an area."
        case .newProject, .newArea: return ""
        }
    }
}
