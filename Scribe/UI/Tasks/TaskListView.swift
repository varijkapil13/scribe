import SwiftUI

/// Detail-pane view for the Tasks layer (slice 2). Renders a quick-add field
/// at the top followed by a vertical list of tasks bucketed by due date.
struct TaskListView: View {

    let filter: TaskStore.Filter
    /// When set (command-bar / ⌘K deep-link), focus this task and open its
    /// inspector once the list loads.
    private let focusTaskId: String?

    @StateObject private var viewModel: TaskListViewModel
    @State private var selectedTask: TodoTask?
    @State private var pendingDelete: TodoTask?
    @State private var showQuickAddDatePicker = false
    @State private var showQuickAddSyntaxHelp = false
    @State private var quickAddFieldHeight: CGFloat = 28
    /// On the Today filter, upcoming buckets (tomorrow / this week / later) and
    /// completed are hidden behind a "Show N more" link by default — the
    /// Today screen is meant to focus on today + overdue.
    @State private var todayUpcomingExpanded: Bool = false
    /// Title of the bucket currently highlighted as a drop target (drag-to-
    /// schedule). Drives the highlight ring.
    @State private var dropTargetBucket: String?
    /// Task id the in-bucket reorder insertion line is drawn above.
    @State private var reorderInsertionId: String?
    /// Whether keyboard focus is currently on the list region (vs. the quick-add
    /// field). Tab toggles between them.
    @FocusState private var listFocused: Bool

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scribeAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Per-filter bucket-collapse state. Persisted to `UserDefaults` keyed by
    /// `(filter, bucket)` so collapsing "Completed" under one filter no longer
    /// leaks into every other filter (the old shared local-`Set` bug). Loaded
    /// on appear / filter switch; written on every toggle.
    @State private var collapsedBuckets: Set<String> = []

    init(filter: TaskStore.Filter, focusTaskId: String? = nil) {
        self.filter = filter
        self.focusTaskId = focusTaskId
        _viewModel = StateObject(wrappedValue: TaskListViewModel(filter: filter))
    }

    /// Stable string key for a filter, used to namespace the collapse store.
    private static func filterKey(_ filter: TaskStore.Filter) -> String {
        switch filter {
        case .inbox:           return "inbox"
        case .today:           return "today"
        case .dueOn:           return "dueOn"
        case .upcoming:        return "upcoming"
        case .all:             return "all"
        case .completed:       return "completed"
        case .project(let id): return "project.\(id)"
        case .tag(let tag):    return "tag.\(tag)"
        }
    }

    private var collapseStorageKey: String {
        "tasks.collapsed.\(Self.filterKey(filter))"
    }

    private func loadCollapsedBuckets() {
        let stored = UserDefaults.standard.stringArray(forKey: collapseStorageKey) ?? []
        collapsedBuckets = Set(stored)
    }

    private func persistCollapsedBuckets() {
        UserDefaults.standard.set(Array(collapsedBuckets), forKey: collapseStorageKey)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: quick-add + task list
            VStack(spacing: 0) {
                quickAddBar
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.top, DesignTokens.Spacing.sm)
                    .padding(.bottom, DesignTokens.Spacing.xs)
                    .background(DesignTokens.Palette.surface)

                Divider()

                content
                    .focusable(true)
                    .focused($listFocused)
                    .focusEffectDisabled()
                    .onKeyPress(action: handleListKeyPress)
            }
            .frame(minWidth: 280)

            // Right: detail panel (slides in when a task is selected)
            if let task = selectedTask {
                Divider()
                TaskDetailPanel(task: task, onDismiss: { selectedTask = nil })
                    .frame(width: 320)
                    .id(task.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(DesignTokens.Palette.surface)
        .scribeAnimation(.snappy, value: selectedTask?.id)
        .navigationTitle(headerTitle)
        .searchable(text: $viewModel.searchQuery, prompt: "Search tasks")
        .onAppear {
            viewModel.start()
            loadCollapsedBuckets()
            if let focusTaskId {
                viewModel.focusedTaskId = focusTaskId
            } else {
                focusQuickAddIfNeeded()
            }
        }
        .onDisappear { viewModel.stop() }
        .onChange(of: filter) { _, newFilter in
            viewModel.switchFilter(to: newFilter)
            selectedTask = nil
            todayUpcomingExpanded = false
            loadCollapsedBuckets()
        }
        // Focus is handled directly by HighlightingQuickAddField observing .scribeFocusQuickAdd.
        .confirmationDialog(
            pendingDelete.map { "Delete \"\($0.title)\"?" } ?? "Delete task?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let task = pendingDelete {
                    viewModel.delete(task)
                    if task.id == selectedTask?.id { selectedTask = nil }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
        .toolbar { projectHeaderToolbar }
        .background(shortcutButtons)
    }

    /// For a `.project` filter, surfaces the project's color swatch + name in
    /// the toolbar (the navigation title is text-only). Empty for other filters.
    @ToolbarContentBuilder
    private var projectHeaderToolbar: some ToolbarContent {
        if case .project(let id) = filter, let project = viewModel.project(id: id) {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    if let icon = project.icon {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(project.color.flatMap { Color(hex: $0) } ?? accent)
                    } else {
                        Circle()
                            .fill(project.color.flatMap { Color(hex: $0) } ?? accent)
                            .frame(width: 9, height: 9)
                    }
                    Text(project.name)
                        .font(.system(size: 13, weight: .semibold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Project \(project.name)")
            }
        }
    }

    // MARK: - Shortcuts

    @ViewBuilder
    private var shortcutButtons: some View {
        VStack(spacing: 0) {
            Button("New task") {
                NotificationCenter.default.post(name: .scribeFocusQuickAdd, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command])
            Button("Toggle complete") {
                if let id = viewModel.focusedTaskId,
                   let task = focusedTask(id: id) {
                    viewModel.toggleCompleted(task)
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(viewModel.focusedTaskId == nil)
            Button("Delete") {
                if let id = viewModel.focusedTaskId,
                   let task = focusedTask(id: id) {
                    pendingDelete = task
                }
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(viewModel.focusedTaskId == nil)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func focusedTask(id: String) -> TodoTask? {
        viewModel.task(id: id)
    }

    // MARK: - Keyboard list navigation

    /// Handles arrow / j-k navigation, Enter (open inspector), Space (toggle),
    /// Cmd-Delete (delete) while the list region holds keyboard focus. Tab
    /// hands focus back to the quick-add field. Returns `.handled` for keys we
    /// consume so the system doesn't beep.
    private func handleListKeyPress(_ press: KeyPress) -> KeyPress.Result {
        let ids = viewModel.flatVisibleTaskIds(visibleGroups: visibleGroups)

        switch press.key {
        case .downArrow:
            withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
                viewModel.moveFocus(by: 1, in: ids)
            }
            return .handled
        case .upArrow:
            withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
                viewModel.moveFocus(by: -1, in: ids)
            }
            return .handled
        case .return:
            if let id = viewModel.focusedTaskId, let task = focusedTask(id: id) {
                openInspector(task)
                return .handled
            }
            return .ignored
        case .space:
            if let id = viewModel.focusedTaskId, let task = focusedTask(id: id) {
                viewModel.toggleCompleted(task)
                return .handled
            }
            return .ignored
        case .tab:
            // Hand focus to the quick-add field.
            listFocused = false
            NotificationCenter.default.post(name: .scribeFocusQuickAdd, object: nil)
            return .handled
        default:
            break
        }

        // j / k vim-style movement.
        if press.characters == "j" {
            withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
                viewModel.moveFocus(by: 1, in: ids)
            }
            return .handled
        }
        if press.characters == "k" {
            withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
                viewModel.moveFocus(by: -1, in: ids)
            }
            return .handled
        }
        // Cmd-Delete deletes the focused row.
        if press.modifiers.contains(.command),
           press.key == .delete || press.key == .deleteForward {
            if let id = viewModel.focusedTaskId, let task = focusedTask(id: id) {
                pendingDelete = task
                return .handled
            }
        }
        return .ignored
    }

    private func openInspector(_ task: TodoTask) {
        viewModel.focusedTaskId = task.id
        withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
            selectedTask = task
        }
    }

    // MARK: - Focus

    private func focusQuickAddIfNeeded() {
        switch filter {
        case .today, .inbox, .dueOn:
            break
        default:
            return
        }
        // Small async hop so NSTextField's notification observer is registered
        // before the post fires (makeNSView runs during the same layout pass as onAppear).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: .scribeFocusQuickAdd, object: nil)
        }
    }

    // MARK: - Header

    private var headerTitle: String {
        switch filter {
        case .inbox:        return "Inbox"
        case .today:        return "Today"
        case .dueOn(let date):
            return Self.dueOnFormatter.string(from: date)
        case .upcoming:     return "Upcoming"
        case .all:          return "All Tasks"
        case .completed:    return "Completed"
        case .project(let id):
            // Resolve the real project name instead of leaking the UUID prefix.
            // Falls back to "Project" until the project list has loaded.
            return viewModel.project(id: id)?.name ?? "Project"
        case .tag(let tag):    return "#\(tag)"
        }
    }

    private static let dueOnFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f
    }()

    // MARK: - Quick add

    @ViewBuilder
    private var quickAddBar: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)

            MultilineQuickAddField(
                text: $viewModel.quickAddText,
                intrinsicHeight: $quickAddFieldHeight,
                placeholder: "Add a task…",
                minHeight: 24,
                maxHeight: 24,
                onSubmit: {
                    viewModel.commitQuickAdd()
                    quickAddFieldHeight = 24
                }
            )
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)

            Button { showQuickAddSyntaxHelp.toggle() } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quick-add syntax help")
            .popover(isPresented: $showQuickAddSyntaxHelp, arrowEdge: .bottom) {
                quickAddSyntaxHelp
                    .scribeGlass(.hud, in: Rectangle())
            }
            .help("Quick-add syntax")

            Button { showQuickAddDatePicker.toggle() } label: {
                Image(systemName: viewModel.quickAddDueDate != nil
                      ? "calendar.badge.clock"
                      : "calendar")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(viewModel.quickAddDueDate != nil
                                     ? Color.orange
                                     : Color.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.quickAddDueDate.map {
                "Due date: \($0.formatted(date: .abbreviated, time: .omitted))"
            } ?? "Pick due date")
            .popover(isPresented: $showQuickAddDatePicker, arrowEdge: .bottom) {
                InlineDatePickerView(selectedDate: $viewModel.quickAddDueDate)
                    .padding(4)
                    .scribeGlass(.hud, in: Rectangle())
            }
            .help(viewModel.quickAddDueDate.map {
                "Due: \($0.formatted(date: .abbreviated, time: .omitted))"
            } ?? "Pick due date")
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 4)
        .background(DesignTokens.Palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var quickAddSyntaxHelp: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Quick-add syntax")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Group {
                row(token: "tmr · next fri", meaning: "due date phrases")
                row(token: "#tag", meaning: "add a tag")
                row(token: "+Project", meaning: "file under project")
                row(token: "!high · !med · !low", meaning: "priority")
                row(token: "Return", meaning: "newline (in notes)")
                row(token: "⌘ Return", meaning: "save task")
            }
        }
        .padding(DesignTokens.Spacing.md)
        .frame(width: 260)
    }

    @ViewBuilder
    private func row(token: String, meaning: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Text(token)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
            Text(meaning)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isSearching {
            searchContent
        } else if viewModel.groups.isEmpty {
            EmptyStateView(
                systemImage: "checkmark.circle",
                title: "Nothing here yet",
                message: emptyMessage
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    ForEach(visibleGroups, id: \.bucket) { group in
                        section(for: group.bucket, tasks: group.tasks)
                    }
                    if filter == .today, let hidden = hiddenUpcomingCount, hidden > 0, !todayUpcomingExpanded {
                        showMoreButton(count: hidden)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
            }
        }
    }

    /// On `.today`, hide tomorrow / this week / later / completed by default
    /// behind a "Show N more upcoming" link. Other filters render every
    /// bucket as before.
    private var visibleGroups: [(bucket: TaskListViewModel.Bucket, tasks: [TodoTask])] {
        guard filter == .today, !todayUpcomingExpanded else { return viewModel.groups }
        return viewModel.groups.filter { group in
            switch group.bucket {
            case .overdue, .today, .noDate: return true
            case .tomorrow, .thisWeek, .later, .completed: return false
            }
        }
    }

    private var hiddenUpcomingCount: Int? {
        guard filter == .today else { return nil }
        return viewModel.groups.reduce(0) { acc, group in
            switch group.bucket {
            case .tomorrow, .thisWeek, .later: return acc + group.tasks.count
            default: return acc
            }
        }
    }

    @ViewBuilder
    private func showMoreButton(count: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: DesignTokens.Motion.fast)) {
                todayUpcomingExpanded = true
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                Text("Show \(count) more upcoming")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var searchContent: some View {
        if viewModel.searchResults.isEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "No matches",
                message: "Try a different word or part of a word."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("\(viewModel.searchResults.count) result\(viewModel.searchResults.count == 1 ? "" : "s")")
                        .eyebrowStyle()
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                        .padding(.bottom, DesignTokens.Spacing.xs)
                    ForEach(Array(viewModel.searchResults.enumerated()), id: \.element.id) { index, task in
                        if index > 0 {
                            Divider().padding(.leading, 32)
                        }
                        taskRow(for: task)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
            }
        }
    }

    @ViewBuilder
    private func taskRow(for task: TodoTask, bucket: TaskListViewModel.Bucket? = nil) -> some View {
        TaskRowView(
            task: task,
            isSettling: viewModel.settlingTasks.contains(task.id)
                || viewModel.recentlyCompletedRecurring.contains(task.id),
            tags: viewModel.tags(for: task.id),
            isSelected: selectedTask?.id == task.id,
            isKeyboardFocused: viewModel.focusedTaskId == task.id,
            projects: viewModel.availableProjects,
            currentProject: viewModel.project(id: task.projectId),
            onToggle: { viewModel.toggleCompleted(task) },
            onOpen: { openInspector(task) },
            onSetDue: { viewModel.setDueDate($0, for: task) },
            onCyclePriority: { viewModel.cyclePriority(for: task) },
            onSetPriority: { viewModel.setPriority($0, for: task) },
            onMoveProject: { viewModel.moveToProject($0, for: task) },
            onRename: { viewModel.setTitle($0, for: task) },
            subtaskProgress: viewModel.subtaskProgress[task.id]
        )
        .onTapGesture {
            viewModel.focusedTaskId = task.id
            withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
                selectedTask = (selectedTask?.id == task.id) ? nil : task
            }
        }
        .draggable(TaskDragPayload(id: task.id))
        .contextMenu { rowContextMenu(for: task, bucket: bucket) }
    }

    @ViewBuilder
    private func rowContextMenu(for task: TodoTask, bucket: TaskListViewModel.Bucket?) -> some View {
        Button {
            openInspector(task)
        } label: {
            Label("Edit…", systemImage: "pencil")
        }

        Button {
            viewModel.toggleCompleted(task)
        } label: {
            Label(task.isCompleted ? "Mark incomplete" : "Mark complete",
                  systemImage: task.isCompleted ? "circle" : "checkmark.circle")
        }

        Menu {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            Button("Today") { viewModel.setDueDate(today, for: task) }
            Button("Tomorrow") { viewModel.setDueDate(cal.date(byAdding: .day, value: 1, to: today), for: task) }
            Button("Next week") { viewModel.setDueDate(cal.date(byAdding: .day, value: 7, to: today), for: task) }
            Divider()
            Button("No date") { viewModel.setDueDate(nil, for: task) }
        } label: {
            Label("Reschedule to", systemImage: "calendar")
        }

        Menu {
            Button { viewModel.setPriority(.high, for: task) } label: {
                Label("High", systemImage: DesignTokens.Palette.prioritySymbolHigh)
            }
            Button { viewModel.setPriority(.medium, for: task) } label: {
                Label("Medium", systemImage: DesignTokens.Palette.prioritySymbolMedium)
            }
            Button { viewModel.setPriority(.low, for: task) } label: {
                Label("Low", systemImage: DesignTokens.Palette.prioritySymbolLow)
            }
            Divider()
            Button("None") { viewModel.setPriority(nil, for: task) }
        } label: {
            Label("Priority", systemImage: "flag")
        }

        Menu {
            Button("Inbox") { viewModel.moveToProject(nil, for: task) }
            Divider()
            ForEach(viewModel.availableProjects) { project in
                Button(project.name) { viewModel.moveToProject(project.id, for: task) }
            }
        } label: {
            Label("Move to Project", systemImage: "folder")
        }

        Divider()

        Button(role: .destructive) {
            pendingDelete = task
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .inbox:    return "Tasks without a project show up here."
        case .today:    return "Nothing due today."
        case .dueOn:    return "Nothing scheduled for this day."
        case .upcoming: return "No tasks due in the next 7 days."
        case .completed: return "Completed tasks will appear here."
        default:        return "Add a task with the field above to get started."
        }
    }

    @ViewBuilder
    private func section(for bucket: TaskListViewModel.Bucket, tasks: [TodoTask]) -> some View {
        let isCollapsed = collapsedBuckets.contains(bucket.title)
        let isDropTarget = dropTargetBucket == bucket.title
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
                    if isCollapsed {
                        collapsedBuckets.remove(bucket.title)
                    } else {
                        collapsedBuckets.insert(bucket.title)
                    }
                }
                persistCollapsedBuckets()
            } label: {
                HStack(spacing: 4) {
                    Text(bucket.title)
                        .eyebrowStyle()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .scribeAnimation(.snappy, value: isCollapsed)
                    Spacer()
                    Text("\(tasks.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, DesignTokens.Spacing.xs)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(bucket.title), \(tasks.count) tasks")
            .accessibilityHint(isCollapsed ? "Collapsed. Activate to expand." : "Expanded. Activate to collapse.")

            if !isCollapsed {
                VStack(spacing: 0) {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                        if index > 0 {
                            Divider()
                                .padding(.leading, 32)
                        }
                        taskRow(for: task, bucket: bucket)
                            .overlay(alignment: .top) {
                                // Insertion indicator for in-bucket reorder.
                                if reorderInsertionId == task.id {
                                    Rectangle()
                                        .fill(accent)
                                        .frame(height: 2)
                                }
                            }
                            .modifier(RowReorderDropModifier(
                                enabled: reorderEnabled,
                                onTargeted: { reorderInsertionId = $0 ? task.id : (reorderInsertionId == task.id ? nil : reorderInsertionId) },
                                onDrop: { payload in handleReorderDrop(payload, before: task, in: tasks) }
                            ))
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .strokeBorder(accent, lineWidth: isDropTarget ? 2 : 0)
        )
        .modifier(BucketDropModifier(
            bucket: bucket,
            isEnabled: dropDate(for: bucket) != nil || bucket == .noDate,
            onDrop: { payload in handleBucketDrop(payload, into: bucket) },
            isTargeted: { targeted in
                dropTargetBucket = targeted ? bucket.title : (dropTargetBucket == bucket.title ? nil : dropTargetBucket)
            }
        ))
    }

    // MARK: - In-bucket reorder

    /// In-bucket manual reorder is only meaningful when every visible task
    /// shares one project scope (`store.reorderTasks` is per-project). That's
    /// the `.project(id)` filter; elsewhere reorder is disabled and rows fall
    /// through to the bucket-level reschedule drop.
    private var reorderEnabled: Bool {
        if case .project = filter { return true }
        return false
    }

    private var reorderProjectScope: String? {
        if case .project(let id) = filter { return id }
        return nil
    }

    /// Persists a reorder that drops `payload`'s task immediately before
    /// `target` within the bucket. No-op when dropping a task on itself.
    private func handleReorderDrop(_ payload: TaskDragPayload, before target: TodoTask, in tasks: [TodoTask]) {
        reorderInsertionId = nil
        guard reorderEnabled, payload.id != target.id else { return }
        var ids = tasks.map(\.id)
        ids.removeAll { $0 == payload.id }
        guard let insertAt = ids.firstIndex(of: target.id) else { return }
        ids.insert(payload.id, at: insertAt)
        withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
            viewModel.reorder(ids, inProject: reorderProjectScope)
        }
    }

    // MARK: - Drag-to-schedule

    /// Representative date a bucket drop reschedules to. `nil` means the bucket
    /// has no single date (this week / later / completed) — drops are disabled
    /// there. The `.noDate` bucket is handled specially (clears the date).
    private func dropDate(for bucket: TaskListViewModel.Bucket) -> Date? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        switch bucket {
        case .overdue, .today: return today
        case .tomorrow:        return cal.date(byAdding: .day, value: 1, to: today)
        case .noDate:          return nil
        case .thisWeek, .later, .completed: return nil
        }
    }

    private func handleBucketDrop(_ payload: TaskDragPayload, into bucket: TaskListViewModel.Bucket) {
        dropTargetBucket = nil
        guard let task = viewModel.task(id: payload.id) else { return }
        withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
            if bucket == .noDate {
                viewModel.setDueDate(nil, for: task)
            } else if let date = dropDate(for: bucket) {
                // Preserve any existing time-of-day on a reschedule.
                let cal = Calendar.current
                let merged: Date
                if let existing = task.dueAt {
                    let comps = cal.dateComponents([.hour, .minute], from: existing)
                    merged = cal.date(bySettingHour: comps.hour ?? 0,
                                      minute: comps.minute ?? 0,
                                      second: 0, of: date) ?? date
                } else {
                    merged = date
                }
                viewModel.setDueDate(merged, for: task)
            }
        }
    }
}

// MARK: - Bucket drop modifier

/// Wraps a section in a `dropDestination` for `TaskDragPayload`, enabled only
/// for buckets that map to a concrete reschedule date (or the No-date bucket).
private struct BucketDropModifier: ViewModifier {
    let bucket: TaskListViewModel.Bucket
    let isEnabled: Bool
    let onDrop: (TaskDragPayload) -> Void
    let isTargeted: (Bool) -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.dropDestination(for: TaskDragPayload.self) { payloads, _ in
                guard let first = payloads.first else { return false }
                onDrop(first)
                return true
            } isTargeted: { targeted in
                isTargeted(targeted)
            }
        } else {
            content
        }
    }
}

/// Per-row `dropDestination` for in-bucket reorder. The innermost drop target
/// wins, so this intercepts the drop before the bucket-level reschedule when
/// reorder is enabled (the `.project(id)` filter).
private struct RowReorderDropModifier: ViewModifier {
    let enabled: Bool
    let onTargeted: (Bool) -> Void
    let onDrop: (TaskDragPayload) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: TaskDragPayload.self) { payloads, _ in
                guard let first = payloads.first else { return false }
                onDrop(first)
                return true
            } isTargeted: { onTargeted($0) }
        } else {
            content
        }
    }
}

// MARK: - Row

/// Compact single-line row: checkbox · title (with inline tag spans) ·
/// trailing meta (priority dot, due text, notes glyph). No per-row card
/// chrome — hairline dividers between rows live in the parent list.
///
/// Inline editing affordances (priority dot click-to-cycle, due-date popover,
/// project chip menu, double-click title) appear on hover OR keyboard focus,
/// each with a context-menu equivalent supplied by the parent.
struct TaskRowView: View {
    let task: TodoTask
    /// Lingering completed state during the settle-hold (struck-through in place).
    let isSettling: Bool
    let tags: [String]
    /// Inspector currently open on this row.
    var isSelected: Bool = false
    /// Keyboard focus ring on this row (distinct from hover + selection).
    var isKeyboardFocused: Bool = false
    let projects: [Project]
    let currentProject: Project?
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onSetDue: (Date?) -> Void
    let onCyclePriority: () -> Void
    let onSetPriority: (TodoTask.Priority?) -> Void
    let onMoveProject: (String?) -> Void
    let onRename: (String) -> Void
    /// Checklist progress for the row "n/m" chip (nil when the task has none).
    var subtaskProgress: SubtaskProgress? = nil

    @State private var isHovered: Bool = false
    @State private var showDuePopover = false
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var bounceTrigger = 0
    @FocusState private var titleFieldFocused: Bool

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scribeAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var struck: Bool { task.isCompleted || isSettling }
    private var affordancesVisible: Bool { isHovered || isKeyboardFocused }

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            checkbox

            Button(action: onOpen) {
                rowContent
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .padding(.vertical, 5)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            // Leading accent bar marks the open inspector selection.
            if isSelected {
                Rectangle().fill(accent).frame(width: 2)
            }
        }
        .overlay(
            // Keyboard-focus ring — visually distinct from hover/selection.
            RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous)
                .strokeBorder(accent, lineWidth: isKeyboardFocused ? 2 : 0)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(task.isCompleted ? "Completed" : "Not completed")
        .accessibilityAddTraits(isKeyboardFocused ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Return to open. Space to toggle complete.")
    }

    // MARK: - Checkbox (completion delight)

    private var checkbox: some View {
        Button {
            if !reduceMotion { bounceTrigger += 1 }
            onToggle()
        } label: {
            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(task.isCompleted ? accent : .secondary)
                .font(.system(size: 15, weight: .regular))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: bounceTrigger)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: task.isCompleted)
        .accessibilityLabel(task.isCompleted ? "Mark incomplete" : "Mark complete")
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            DesignTokens.Palette.accentFill(.selected, accent: accent, contrast: contrast)
        } else if affordancesVisible {
            DesignTokens.Palette.fill(.hover, contrast: contrast)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            priorityControl

            if isEditingTitle {
                titleEditor
            } else {
                titleText
            }

            Spacer(minLength: DesignTokens.Spacing.xs)

            if let project = currentProject {
                projectChip(project)
            } else if affordancesVisible {
                projectChipMenu(label: "Inbox", tint: .secondary)
            }

            if !task.notes.isEmpty {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }

            subtaskChip

            dueControl
        }
    }

    @ViewBuilder
    private var subtaskChip: some View {
        if let progress = subtaskProgress, progress.total > 0 {
            HStack(spacing: 2) {
                Image(systemName: progress.isComplete ? "checklist.checked" : "checklist")
                    .font(.system(size: 9))
                Text("\(progress.completed)/\(progress.total)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(progress.isComplete ? Color.accentColor : .secondary)
            .accessibilityLabel("\(progress.completed) of \(progress.total) subtasks completed")
        }
    }

    // MARK: - Title (double-click to edit)

    private var titleText: some View {
        Text(titleWithTags)
            .font(.system(size: 13))
            .strikethrough(struck, color: .secondary)
            .foregroundStyle(struck ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                titleDraft = task.title
                isEditingTitle = true
                titleFieldFocused = true
            }
    }

    private var titleEditor: some View {
        TextField("Title", text: $titleDraft)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($titleFieldFocused)
            .onSubmit { commitTitle() }
            .onExitCommand { isEditingTitle = false }
            .onChange(of: titleFieldFocused) { _, focused in
                if !focused { commitTitle() }
            }
            .accessibilityLabel("Edit title")
    }

    private func commitTitle() {
        defer { isEditingTitle = false }
        onRename(titleDraft)
    }

    /// Title with `#tag` spans appended in tinted attributed text. Keeps the
    /// row to a single line while preserving tag visibility.
    private var titleWithTags: AttributedString {
        var out = AttributedString(task.title)
        for tag in tags {
            var chip = AttributedString("  #\(tag)")
            chip.foregroundColor = .secondary
            chip.font = .system(size: 12)
            out.append(chip)
        }
        return out
    }

    // MARK: - Priority (click-to-cycle)

    private var priorityControl: some View {
        Button(action: onCyclePriority) {
            PriorityIndicator(
                priority: task.priority,
                showPlaceholder: affordancesVisible,
                differentiateWithoutColor: differentiateWithoutColor
            )
        }
        .buttonStyle(.plain)
        .help("Cycle priority")
        .accessibilityLabel(priorityAccessibilityLabel)
        .accessibilityHint("Activate to cycle priority")
    }

    private var priorityAccessibilityLabel: String {
        switch task.priority {
        case .high:   return "Priority: high"
        case .medium: return "Priority: medium"
        case .low:    return "Priority: low"
        case .none:   return "Priority: none"
        }
    }

    // MARK: - Project chip (move menu)

    private func projectChip(_ project: Project) -> some View {
        projectChipMenu(label: project.name, tint: project.color.flatMap { Color(hex: $0) } ?? accent)
    }

    private func projectChipMenu(label: String, tint: Color) -> some View {
        Menu {
            Button("Inbox") { onMoveProject(nil) }
            Divider()
            ForEach(projects) { project in
                Button(project.name) { onMoveProject(project.id) }
            }
        } label: {
            HStack(spacing: 3) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(DesignTokens.Palette.fill(.hover, contrast: contrast))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(currentProject != nil || affordancesVisible ? 1 : 0)
        .accessibilityLabel("Project: \(label)")
        .accessibilityHint("Activate to move to another project")
    }

    // MARK: - Due date (inline popover)

    @ViewBuilder
    private var dueControl: some View {
        if let due = task.dueAt {
            Button { showDuePopover = true } label: {
                DueDateLabel(
                    date: due,
                    isOverdue: !task.isCompleted && due < Calendar.current.startOfDay(for: Date())
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Due \(DueDateLabel.accessibleString(for: due))")
            .accessibilityHint("Activate to reschedule")
            .popover(isPresented: $showDuePopover, arrowEdge: .bottom) {
                InlineDatePickerView(selectedDate: Binding(
                    get: { task.dueAt },
                    set: { onSetDue($0) }
                ))
                .padding(4)
                .scribeGlass(.hud, in: Rectangle())
            }
        } else if affordancesVisible {
            Button { showDuePopover = true } label: {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Set due date")
            .popover(isPresented: $showDuePopover, arrowEdge: .bottom) {
                InlineDatePickerView(selectedDate: Binding(
                    get: { task.dueAt },
                    set: { onSetDue($0) }
                ))
                .padding(4)
                .scribeGlass(.hud, in: Rectangle())
            }
        }
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        var parts: [String] = [task.title]
        if let due = task.dueAt {
            parts.append("due \(DueDateLabel.accessibleString(for: due))")
        }
        switch task.priority {
        case .high:   parts.append("high priority")
        case .medium: parts.append("medium priority")
        case .low:    parts.append("low priority")
        case .none:   break
        }
        if let project = currentProject { parts.append("in \(project.name)") }
        for tag in tags { parts.append("tag \(tag)") }
        return parts.joined(separator: ", ")
    }
}

/// Priority indicator. Default is a 6pt filled dot (high = red, medium = orange,
/// low = blue). Under Differentiate Without Color it renders an SF Symbol glyph
/// instead so priority survives without relying on hue. When `showPlaceholder`
/// is set (hover/focus) an empty-priority task shows a faint outline so the
/// click-to-cycle target is discoverable.
private struct PriorityIndicator: View {
    let priority: TodoTask.Priority?
    var showPlaceholder: Bool = false
    var differentiateWithoutColor: Bool = false

    var body: some View {
        if differentiateWithoutColor, let symbol = symbol {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 10)
        } else if priority != nil {
            Circle().fill(tint).frame(width: 6, height: 6)
        } else if showPlaceholder {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                .frame(width: 6, height: 6)
        } else {
            Circle().fill(.clear).frame(width: 6, height: 6)
        }
    }

    private var tint: Color {
        switch priority {
        case .high:   return DesignTokens.Palette.priorityHigh
        case .medium: return DesignTokens.Palette.priorityMedium
        case .low:    return DesignTokens.Palette.priorityLow
        case .none:   return .clear
        }
    }

    private var symbol: String? {
        switch priority {
        case .high:   return DesignTokens.Palette.prioritySymbolHigh
        case .medium: return DesignTokens.Palette.prioritySymbolMedium
        case .low:    return DesignTokens.Palette.prioritySymbolLow
        case .none:   return nil
        }
    }
}

/// Trailing due-date label using relative phrasing ("Today", "Tomorrow",
/// "Mon", "Mar 12") with tabular figures. Overdue dates render in the
/// recording-red accent; no capsule background.
private struct DueDateLabel: View {
    let date: Date
    let isOverdue: Bool

    var body: some View {
        Text(formatted)
            .font(.system(size: 11, design: .monospaced).monospacedDigit())
            .foregroundStyle(isOverdue ? DesignTokens.Palette.recording : .secondary)
            .lineLimit(1)
    }

    /// Spoken form for VoiceOver — full localized date instead of the terse
    /// "Mon" / "Mar 12" visual abbreviation.
    static func accessibleString(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInTomorrow(date) { return "tomorrow" }
        if cal.isDateInYesterday(date) { return "yesterday" }
        return date.formatted(date: .complete, time: .omitted)
    }

    private var formatted: String {
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        if cal.isDateInYesterday(date) { return "Yesterday" }

        let comps = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date))
        let days = comps.day ?? 0
        // Within the upcoming week, show weekday name; otherwise short date.
        if days > 1, days < 7 {
            let f = DateFormatter()
            f.dateFormat = "EEE"
            return f.string(from: date)
        }
        if days < 0, days > -7 {
            let f = DateFormatter()
            f.dateFormat = "EEE"
            return f.string(from: date)
        }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}

// MARK: - Notification names

extension Notification.Name {
    /// Received by TaskListView to focus the quick-add field.
    /// Slice 8: post this from the main window key handler when a task filter is
    /// selected and the user presses Cmd-N.
    static let scribeFocusQuickAdd = Notification.Name("scribe.focusQuickAdd")
}
