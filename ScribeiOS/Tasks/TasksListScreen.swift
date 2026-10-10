import SwiftUI

/// One task list (Inbox, Today, Upcoming, Anytime, Someday, Logbook, an area,
/// a project, a tag) as a sectioned list or a board. Rows support swipe
/// actions, context menus, drag-to-reorder (Edit), dragging onto sections,
/// sidebar lists and board columns, and multi-select batch edits.
struct TasksListScreen: View {
    let destination: TaskListDestination
    @ObservedObject var library: TasksLibraryModel
    /// iPad: open in the detail column. Nil (iPhone): push.
    var onOpenTask: ((String) -> Void)?
    var selectedTaskId: String?
    /// Opens the quick-add sheet (optionally under a heading).
    var onQuickAdd: ((String?) -> Void)?

    @StateObject private var model: TasksListModel
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<String> = []
    @State private var layout: TaskListLayoutMode
    @State private var grouping: TaskBoardGrouping = .status
    @State private var headingPrompt: HeadingPromptState?
    @State private var headingText = ""
    @State private var confirmBatchDelete = false

    private var actions: TaskMobileActions { .live }

    init(destination: TaskListDestination,
         library: TasksLibraryModel,
         onOpenTask: ((String) -> Void)? = nil,
         selectedTaskId: String? = nil,
         onQuickAdd: ((String?) -> Void)? = nil) {
        self.destination = destination
        self.library = library
        self.onOpenTask = onOpenTask
        self.selectedTaskId = selectedTaskId
        self.onQuickAdd = onQuickAdd
        _model = StateObject(wrappedValue: TasksListModel(destination: destination, store: TaskStore.shared))
        _layout = State(initialValue: TasksListLayoutMemory.layout(for: destination))
    }

    var body: some View {
        Group {
            if layout == .board {
                TasksBoardScreen(destination: destination, model: model, library: library,
                                 grouping: grouping, onOpenTask: onOpenTask)
            } else {
                list
            }
        }
        .navigationTitle(library.title(for: destination))
        .toolbar { toolbar }
        .environment(\.editMode, $editMode)
        .onAppear {
            model.start()
            model.setObservesFinished(layout == .board)
        }
        .onChange(of: layout) { _, newValue in
            TasksListLayoutMemory.setLayout(newValue, for: destination)
            model.setObservesFinished(newValue == .board)
            if newValue == .board { editMode = .inactive }
        }
        .onChange(of: editMode) { _, newValue in
            if !newValue.isEditing { selection.removeAll() }
        }
        .alert(headingPrompt?.title ?? "Heading", isPresented: Binding(
            get: { headingPrompt != nil },
            set: { if !$0 { headingPrompt = nil } }
        )) {
            TextField("Heading name", text: $headingText)
            Button("Save") { commitHeadingPrompt() }
            Button("Cancel", role: .cancel) { headingPrompt = nil }
        }
        .confirmationDialog("Delete \(selection.count) tasks?", isPresented: $confirmBatchDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                actions.delete(ids: selection)
                editMode = .inactive
            }
        }
    }

    // MARK: - List

    private var list: some View {
        List(selection: $selection) {
            if !library.tags.isEmpty, !model.requiredTags.isEmpty {
                Section { activeTagFilters }
            }
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.tasks) { task in
                        row(task)
                    }
                    .onMove(perform: moveHandler(for: section))
                } header: {
                    sectionHeader(section)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { if model.isEmpty { emptyState } }
        .safeAreaInset(edge: .bottom) {
            if editMode.isEditing { batchBar }
        }
    }

    private var canReorder: Bool {
        destination.supportsManualOrder && model.requiredTags.isEmpty && editMode.isEditing
    }

    /// Drag-to-reorder within a section while editing (nil disables it).
    private func moveHandler(for section: TaskListSection) -> ((IndexSet, Int) -> Void)? {
        guard canReorder else { return nil }
        let handler: (IndexSet, Int) -> Void = { source, target in
            move(in: section, source, target)
        }
        return handler
    }

    @ViewBuilder
    private func row(_ task: TodoTask) -> some View {
        let content = MobileTaskRow(
            task: task,
            projectName: library.project(task.projectId)?.name,
            tags: model.tagsByTask[task.id] ?? [],
            subtaskProgress: model.progress[task.id],
            showsProject: !isProjectList,
            onToggle: { actions.toggleCompleted(task) }
        )
        Group {
            if editMode.isEditing {
                content
            } else if let onOpenTask {
                Button { onOpenTask(task.id) } label: { content }
                    .buttonStyle(.plain)
                    .listRowBackground(selectedTaskId == task.id ? Color.accentColor.opacity(0.15) : nil)
            } else {
                NavigationLink(value: TaskRouteID(id: task.id)) { content }
            }
        }
        .tag(task.id)
        .taskSwipeActions(task, actions: actions)
        .contextMenu {
            TaskRowContextMenu(task: task, projects: library.projects, headings: model.headings,
                               onOpen: onOpenTask == nil ? nil : { open(task.id) }, actions: actions)
        }
        .draggable(TaskDragToken.encode(task.id)) {
            Label(task.title.isEmpty ? "Task" : task.title, systemImage: "checkmark.circle")
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var isProjectList: Bool {
        if case .project = destination { return true }
        return false
    }

    @ViewBuilder
    private func sectionHeader(_ section: TaskListSection) -> some View {
        let header = HStack {
            if !section.title.isEmpty {
                Text(section.title)
                    .foregroundStyle(section.kind == .overdue ? Color.red : Color.secondary)
            }
            Spacer()
            if case .heading(let heading) = section.kind {
                Menu {
                    Button { onQuickAdd?(heading.id) } label: { Label("Add Task Here", systemImage: "plus") }
                    Button { startHeadingPrompt(.rename(heading)) } label: { Label("Rename", systemImage: "pencil") }
                    Button { model.moveHeading(heading, by: -1) } label: { Label("Move Up", systemImage: "arrow.up") }
                    Button { model.moveHeading(heading, by: 1) } label: { Label("Move Down", systemImage: "arrow.down") }
                    Divider()
                    Button(role: .destructive) { model.deleteHeading(heading) } label: { Label("Delete Heading", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Heading options")
            }
        }
        .contentShape(Rectangle())
        header
            .dropDestination(for: String.self) { items, _ in
                actions.drop(tokens: items, ontoSection: section.kind)
            }
    }

    private var activeTagFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(model.requiredTags.sorted(), id: \.self) { tag in
                    Button { model.requiredTags.remove(tag) } label: {
                        Label("#\(tag)", systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: library.systemImage(for: destination))
        } description: {
            Text(emptyMessage)
        }
    }

    private var emptyTitle: String {
        switch destination {
        case .today:   return "All clear for today"
        case .logbook: return "Nothing completed yet"
        default:       return "No tasks"
        }
    }

    private var emptyMessage: String {
        if !model.requiredTags.isEmpty { return "No tasks carry every selected tag." }
        switch destination {
        case .upcoming: return "Tasks with a future due or start date show up here, by day."
        case .someday:  return "Park tasks here for later with “someday” or the When menu."
        case .logbook:  return "Completed and won’t-do tasks are kept here."
        default:        return "Tap + to add one — try “draft deck tomorrow 5pm #work !high ~30m”."
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if layout == .list {
                Button(editMode.isEditing ? "Done" : "Select") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
            }
            Menu {
                if destination != .logbook {
                    Picker("Layout", selection: $layout) {
                        ForEach(TaskListLayoutMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                }
                if layout == .board {
                    Picker("Columns", selection: $grouping) {
                        ForEach(TaskBoardGrouping.allCases) { option in
                            Label(option.title, systemImage: option.systemImage).tag(option)
                        }
                    }
                }
                if !library.tags.isEmpty {
                    Menu {
                        ForEach(library.tags, id: \.self) { tag in
                            Button {
                                if model.requiredTags.contains(tag) { model.requiredTags.remove(tag) }
                                else { model.requiredTags.insert(tag) }
                            } label: {
                                Label("#\(tag)", systemImage: model.requiredTags.contains(tag) ? "checkmark" : "number")
                            }
                        }
                        if !model.requiredTags.isEmpty {
                            Divider()
                            Button("Clear Tag Filter") { model.requiredTags.removeAll() }
                        }
                    } label: {
                        Label("Filter by Tag", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
                if isProjectList {
                    Divider()
                    Button { startHeadingPrompt(.add) } label: { Label("Add Heading", systemImage: "text.badge.plus") }
                }
            } label: {
                Image(systemName: model.requiredTags.isEmpty ? "ellipsis.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .accessibilityLabel("List options")
        }
    }

    // MARK: - Batch

    private var batchBar: some View {
        HStack(spacing: 18) {
            Button { actions.complete(ids: selection); editMode = .inactive } label: {
                Image(systemName: "checkmark.circle")
            }
            .accessibilityLabel("Complete selected")
            Menu {
                Button { actions.plan(ids: selection, bucket: .today) } label: { Label("Today", systemImage: "star") }
                Button { actions.plan(ids: selection, bucket: .evening) } label: { Label("This Evening", systemImage: "moon") }
                Button { actions.plan(ids: selection, bucket: .anytime) } label: { Label("Anytime", systemImage: "circle.dashed") }
                Button { actions.plan(ids: selection, bucket: .someday) } label: { Label("Someday", systemImage: "archivebox") }
            } label: { Image(systemName: "moon.stars") }
            .accessibilityLabel("When")
            Menu {
                Button("Today") { actions.setDue(TaskQuickDates.today(), ids: selection) }
                Button("Tomorrow") { actions.setDue(TaskQuickDates.tomorrow(), ids: selection) }
                Button("Next Week") { actions.setDue(TaskQuickDates.nextWeek(), ids: selection) }
                Button("No Due Date", role: .destructive) { actions.setDue(nil, ids: selection) }
            } label: { Image(systemName: "calendar") }
            .accessibilityLabel("Due date")
            Menu {
                Button("Inbox") { actions.move(ids: selection, toProject: nil) }
                ForEach(library.projects) { project in
                    Button(project.name) { actions.move(ids: selection, toProject: project.id) }
                }
            } label: { Image(systemName: "folder") }
            .accessibilityLabel("Move to project")
            Menu {
                ForEach(TodoTask.Priority.allCases, id: \.self) { priority in
                    Button(priority.rawValue) { actions.setPriority(priority, ids: selection) }
                }
                Button("None") { actions.setPriority(nil, ids: selection) }
            } label: { Image(systemName: "flag") }
            .accessibilityLabel("Priority")
            Spacer()
            Button(role: .destructive) { confirmBatchDelete = true } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Delete selected")
        }
        .font(.title3)
        .disabled(selection.isEmpty)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Actions

    private func open(_ id: String) {
        if let onOpenTask { onOpenTask(id) }
    }

    private func move(in section: TaskListSection, _ source: IndexSet, _ target: Int) {
        let sectionIds = section.tasks.map(\.id)
        let reordered = TaskListSectioning.reordered(sectionIds, moving: source, to: target)
        actions.reorder(reordered, tasks: section.tasks)
    }

    private func startHeadingPrompt(_ prompt: HeadingPromptState) {
        headingText = prompt.initialText
        headingPrompt = prompt
    }

    private func commitHeadingPrompt() {
        guard let prompt = headingPrompt else { return }
        switch prompt {
        case .add:                 model.addHeading(headingText)
        case .rename(let heading): model.renameHeading(heading, to: headingText)
        }
        headingPrompt = nil
    }
}

/// Add / rename heading alert state.
enum HeadingPromptState: Equatable {
    case add
    case rename(ProjectHeading)

    var title: String {
        switch self {
        case .add:    return "New Heading"
        case .rename: return "Rename Heading"
        }
    }

    var initialText: String {
        if case .rename(let heading) = self { return heading.title }
        return ""
    }
}

/// Remembers list vs board per list (a per-device convenience).
enum TasksListLayoutMemory {
    private static func key(_ destination: TaskListDestination) -> String {
        "iosTaskListLayout.\(destination.id)"
    }

    static func layout(for destination: TaskListDestination) -> TaskListLayoutMode {
        let raw = UserDefaults.standard.string(forKey: key(destination)) ?? ""
        return TaskListLayoutMode(rawValue: raw) ?? .list
    }

    static func setLayout(_ layout: TaskListLayoutMode, for destination: TaskListDestination) {
        UserDefaults.standard.set(layout.rawValue, forKey: key(destination))
    }
}
