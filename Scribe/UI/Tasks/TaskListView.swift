import SwiftUI
import TipKit

/// Detail-pane view for the Tasks layer (slice 2). Renders a quick-add field
/// at the top followed by a vertical list of tasks bucketed by due date.
struct TaskListView: View {

    let filter: TaskStore.Filter
    /// When set (command-bar / ⌘K deep-link), focus this task and open its
    /// inspector once the list loads.
    private let focusTaskId: String?
    /// Navigation hook for opening the source recording of a task that was
    /// converted from a meeting. Forwarded to the detail panel's "From:
    /// <recording>" affordance. Nil hides the navigation behaviour.
    private let onOpenRecording: ((String) -> Void)?

    @StateObject private var viewModel: TaskListViewModel
    /// Task actions register Edit › Undo with the window's undo manager.
    @Environment(\.undoManager) private var undoManager
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
    /// Active sort, persisted per filter (TickTick parity).
    @State private var sortMode: TaskListViewModel.TaskSort = .smart
    /// Add / rename heading prompt (project lists).
    @State private var headingPrompt: HeadingPrompt?
    /// List or Kanban board, and the board's grouping — both per filter.
    @State private var layoutMode: TaskListLayoutMode = .list
    @State private var boardGrouping: TaskBoardGrouping = .status

    init(
        filter: TaskStore.Filter,
        focusTaskId: String? = nil,
        onOpenRecording: ((String) -> Void)? = nil
    ) {
        self.filter = filter
        self.focusTaskId = focusTaskId
        self.onOpenRecording = onOpenRecording
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
        case .someday:         return "someday"
        case .area(let id):    return "area.\(id)"
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

    private var sortStorageKey: String { "tasks.sort.\(Self.filterKey(filter))" }

    private func loadSortMode() {
        let raw = UserDefaults.standard.string(forKey: sortStorageKey)
            ?? TaskListViewModel.TaskSort.smart.rawValue
        sortMode = TaskListViewModel.TaskSort(rawValue: raw) ?? .smart
        viewModel.sortMode = sortMode
    }

    private func loadBoardPreferences() {
        layoutMode = TaskBoardPreferences.layoutMode(forFilterKey: Self.filterKey(filter))
        boardGrouping = TaskBoardPreferences.grouping(forFilterKey: Self.filterKey(filter))
    }

    private func setLayoutMode(_ mode: TaskListLayoutMode) {
        if mode == .board { viewModel.exitSelectMode() }
        layoutMode = mode
        TaskBoardPreferences.setLayoutMode(mode, forFilterKey: Self.filterKey(filter))
    }

    private func setBoardGrouping(_ grouping: TaskBoardGrouping) {
        boardGrouping = grouping
        TaskBoardPreferences.setGrouping(grouping, forFilterKey: Self.filterKey(filter))
    }

    private func setSort(_ sort: TaskListViewModel.TaskSort) {
        sortMode = sort
        viewModel.sortMode = sort
        UserDefaults.standard.set(sort.rawValue, forKey: sortStorageKey)
    }

    private var listHeader: some View {
        QuietListHeader(title: headerTitle, count: headerCount) {
            if viewModel.isSelecting {
                batchControls
            } else if layoutMode == .list || viewModel.isSearching {
                if sortMode != .smart {
                    Text(sortMode.rawValue)
                        .font(DesignTokens.QuietList.countFont)
                        .foregroundStyle(DesignTokens.Palette.textTertiary)
                }
                listOptionsMenu
            }
        }
        .padding(.horizontal, DesignTokens.QuietList.gutter)
        .padding(.top, DesignTokens.Spacing.lg)
        .padding(.bottom, DesignTokens.Spacing.xs)
        .animation(DesignTokens.Motion.resolve(DesignTokens.Motion.snappy, reduceMotion: reduceMotion),
                   value: viewModel.isSelecting)
    }

    private var headerCount: String? {
        guard !viewModel.isSearching else { return nil }
        let tasks = viewModel.groups.lazy.flatMap { $0.tasks }
        if filter == .completed {
            return "\(tasks.count) done"
        }
        return "\(tasks.filter { !$0.isCompleted && !$0.isCancelled }.count) open"
    }

    private var listOptionsMenu: some View {
        Menu {
            Button { viewModel.enterSelectMode() } label: {
                Label("Select Tasks", systemImage: "checkmark.circle")
            }
            if case .project = filter {
                Button { headingPrompt = .add } label: {
                    Label("Add Heading", systemImage: "plus.rectangle.on.rectangle")
                }
            }
            Divider()
            Picker(selection: Binding(get: { sortMode }, set: { setSort($0) })) {
                ForEach(TaskListViewModel.TaskSort.allCases) { sort in
                    Label(sort.rawValue, systemImage: sort.systemImage).tag(sort)
                }
            } label: {
                Label("Sort By", systemImage: "arrow.up.arrow.down")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Select, sort and list options")
        .accessibilityLabel("List options, sort: \(sortMode.rawValue)")
    }

    /// Batch action bar shown in multi-select mode.
    private var batchControls: some View {
        let empty = viewModel.selection.isEmpty
        return HStack(spacing: DesignTokens.Spacing.md) {
            Text("\(viewModel.selection.count) selected")
                .font(DesignTokens.QuietList.countFont)
                .foregroundStyle(DesignTokens.Palette.textTertiary)
            Button { viewModel.batchComplete() } label: { Image(systemName: "checkmark.circle") }
                .help("Complete selected").disabled(empty)
            Menu {
                let cal = Calendar.current
                let today = cal.startOfDay(for: Date())
                Button("Today") { viewModel.batchReschedule(to: today) }
                Button("Tomorrow") { viewModel.batchReschedule(to: cal.date(byAdding: .day, value: 1, to: today)) }
                Button("Next week") { viewModel.batchReschedule(to: cal.date(byAdding: .day, value: 7, to: today)) }
                Divider()
                Button("No date") { viewModel.batchReschedule(to: nil) }
            } label: { Image(systemName: "calendar") }
                .help("Reschedule selected").disabled(empty)
            Menu {
                Button { viewModel.batchPriority(.high) } label: { Label("High", systemImage: DesignTokens.Palette.prioritySymbolHigh) }
                Button { viewModel.batchPriority(.medium) } label: { Label("Medium", systemImage: DesignTokens.Palette.prioritySymbolMedium) }
                Button { viewModel.batchPriority(.low) } label: { Label("Low", systemImage: DesignTokens.Palette.prioritySymbolLow) }
                Divider()
                Button("None") { viewModel.batchPriority(nil) }
            } label: { Image(systemName: "flag") }
                .help("Set priority").disabled(empty)
            Menu {
                Button("Inbox") { viewModel.batchMove(toProject: nil) }
                Divider()
                ForEach(viewModel.availableProjects) { project in
                    Button(project.name) { viewModel.batchMove(toProject: project.id) }
                }
            } label: { Image(systemName: "folder") }
                .help("Move to project").disabled(empty)
            Button(role: .destructive) { viewModel.batchDelete() } label: { Image(systemName: "trash") }
                .help("Delete selected").disabled(empty)
            Button("Done") { viewModel.exitSelectMode() }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(DesignTokens.Palette.textSecondary)
        .fixedSize()
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: quick-add + task list
            VStack(spacing: 0) {
                listHeader

                quickAddBar
                    .padding(.horizontal, DesignTokens.QuietList.gutter - DesignTokens.Spacing.sm)
                    .padding(.bottom, DesignTokens.Spacing.xs)

                Rectangle()
                    .fill(DesignTokens.Palette.cardBorder(contrast))
                    .frame(height: 1)
                    .padding(.horizontal, DesignTokens.QuietList.gutter)

                if layoutMode == .board && !viewModel.isSearching {
                    TaskBoardView(
                        viewModel: viewModel,
                        filter: filter,
                        grouping: Binding(get: { boardGrouping }, set: { setBoardGrouping($0) }),
                        selectedTaskId: selectedTask?.id,
                        onOpen: { openInspector($0) }
                    )
                } else {
                    content
                        .focusable(true)
                        .focused($listFocused)
                        .focusEffectDisabled()
                        .onKeyPress(action: handleListKeyPress)
                }
            }
            .frame(minWidth: 280)

            // Right: detail panel (slides in when a task is selected)
            if let task = selectedTask {
                Rectangle()
                    .fill(DesignTokens.Palette.cardBorder(contrast))
                    .frame(width: 1)
                TaskDetailPanel(
                    task: task,
                    onDismiss: { selectedTask = nil },
                    onOpenRecording: onOpenRecording
                )
                    .frame(width: 320)
                    .id(task.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(DesignTokens.Palette.ground)
        .scribeAnimation(.snappy, value: selectedTask?.id)
        .navigationTitle(headerTitle)
        .searchable(text: $viewModel.searchQuery, prompt: "Search tasks")
        .onAppear {
            viewModel.undoManager = undoManager
            viewModel.start()
            loadCollapsedBuckets()
            loadSortMode()
            loadBoardPreferences()
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
            loadSortMode()
            loadBoardPreferences()
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                TaskLayoutModePicker(mode: Binding(get: { layoutMode }, set: { setLayoutMode($0) }))
            }
        }
        .background(shortcutButtons)
        .modifier(HeadingPromptModifier(prompt: $headingPrompt) { prompt, text in
            switch prompt {
            case .add:                 viewModel.addHeading(title: text)
            case .rename(let heading): viewModel.renameHeading(heading, to: text)
            }
        })
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
        case .someday:         return "Someday"
        case .area(let id):    return viewModel.area(id: id)?.name ?? "Area"
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
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(DesignTokens.Palette.textTertiary)
                .frame(width: 16)

            MultilineQuickAddField(
                text: $viewModel.quickAddText,
                intrinsicHeight: $quickAddFieldHeight,
                placeholder: "New task",
                minHeight: 24,
                maxHeight: 24,
                onSubmit: {
                    viewModel.commitQuickAdd()
                    quickAddFieldHeight = 24
                    ScribeTips.taskQuickAddUsed()
                }
            )
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
            .help(Self.quickAddSyntaxSummary)

            Button { showQuickAddSyntaxHelp.toggle() } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quick-add syntax help")
            .popoverTip(ScribeTips.taskQuickAdd)
            .popover(isPresented: $showQuickAddSyntaxHelp, arrowEdge: .bottom) {
                // No custom backing: the system popover is already glass.
                quickAddSyntaxHelp
            }
            .help(Self.quickAddSyntaxSummary)

            Button { showQuickAddDatePicker.toggle() } label: {
                Image(systemName: viewModel.quickAddDueDate != nil
                      ? "calendar.badge.clock"
                      : "calendar")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(viewModel.quickAddDueDate != nil
                                     ? accent
                                     : DesignTokens.Palette.textTertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.quickAddDueDate.map {
                "Due date: \($0.formatted(date: .abbreviated, time: .omitted))"
            } ?? "Pick due date")
            .popover(isPresented: $showQuickAddDatePicker, arrowEdge: .bottom) {
                InlineDatePickerView(selectedDate: $viewModel.quickAddDueDate)
                    .padding(DesignTokens.Spacing.xs)
            }
            .help(viewModel.quickAddDueDate.map {
                "Due: \($0.formatted(date: .abbreviated, time: .omitted))"
            } ?? "Pick due date")
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(minHeight: DesignTokens.QuietList.rowHeight)
    }

    private static let quickAddSyntaxSummary =
        "Type as you go: #tag, +project, !high, and dates like “tmr” or “next fri”."

    @ViewBuilder
    private var quickAddSyntaxHelp: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Quick-add shorthand")
                .quietListSectionHeader()
            Group {
                row(token: "tmr · next fri", meaning: "due date phrases")
                row(token: "#tag", meaning: "add a tag")
                row(token: "+Project", meaning: "file under project")
                row(token: "!high · !med · !low", meaning: "priority")
                row(token: "every 2 weeks · after completion", meaning: "repeat")
                row(token: "starting fri · someday · tonight", meaning: "plan")
                row(token: "~30m · for 1h", meaning: "duration")
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.Palette.textPrimary)
            Text(meaning)
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Palette.textTertiary)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isSearching {
            searchContent
        } else if viewModel.groups.isEmpty {
            let empty = emptyState
            EmptyStateView(
                systemImage: empty.systemImage,
                title: empty.title,
                message: empty.message,
                actionTitle: empty.showsAddAction ? "Add a task" : nil,
                action: empty.showsAddAction ? {
                    NotificationCenter.default.post(name: .scribeFocusQuickAdd, object: nil)
                } : nil
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.QuietList.sectionSpacing) {
                    ForEach(visibleGroups, id: \.bucket) { group in
                        section(for: group.bucket, tasks: group.tasks)
                    }
                    if filter == .today, let hidden = hiddenUpcomingCount, hidden > 0, !todayUpcomingExpanded {
                        showMoreButton(count: hidden)
                    }
                }
                .padding(.horizontal, DesignTokens.QuietList.gutter - DesignTokens.Spacing.sm)
                .padding(.vertical, DesignTokens.Spacing.md)
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
            case .overdue, .today, .evening, .noDate, .someday, .heading: return true
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
            .foregroundStyle(DesignTokens.Palette.textSecondary)
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
                        .quietListSectionHeader()
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                        .padding(.bottom, DesignTokens.Spacing.xs)
                    ForEach(Array(viewModel.searchResults.enumerated()), id: \.element.id) { index, task in
                        if index > 0 {
                            rowSeparator
                        }
                        taskRow(for: task)
                    }
                }
                .padding(.horizontal, DesignTokens.QuietList.gutter - DesignTokens.Spacing.sm)
                .padding(.vertical, DesignTokens.Spacing.md)
            }
        }
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(DesignTokens.Palette.cardBorder(contrast))
            .frame(height: 1)
            .padding(.leading, DesignTokens.Spacing.xxl)
            .padding(.trailing, DesignTokens.Spacing.sm)
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
            subtaskProgress: viewModel.subtaskProgress[task.id],
            isSelecting: viewModel.isSelecting,
            isMultiSelected: viewModel.selection.contains(task.id),
            onToggleSelect: { viewModel.toggleSelected(task.id) }
        )
        .onTapGesture {
            if viewModel.isSelecting {
                viewModel.toggleSelected(task.id)
                return
            }
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

        TaskWhenMenu(task: task) { viewModel.setScheduleBucket($0, for: task) }

        if case .project = filter, !viewModel.headings.isEmpty {
            TaskHeadingMenu(task: task, headings: viewModel.headings) {
                viewModel.setHeading($0, for: task)
            }
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

        Button {
            viewModel.togglePin(task)
        } label: {
            Label(task.isPinned ? "Unpin" : "Pin to top",
                  systemImage: task.isPinned ? "pin.slash" : "pin")
        }

        Button {
            if task.isCancelled { viewModel.uncancelTask(task) } else { viewModel.cancelTask(task) }
        } label: {
            Label(task.isCancelled ? "Mark active" : "Won't do",
                  systemImage: task.isCancelled ? "arrow.uturn.backward" : "xmark.circle")
        }

        Divider()

        Button(role: .destructive) {
            pendingDelete = task
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// Filter-aware empty state: each list explains *why* it's empty and what
    /// belongs there, so a blank pane never reads as "something's broken".
    /// `showsAddAction` hides the "Add a task" button where adding from the
    /// current list wouldn't land a task in it (e.g. Completed).
    private var emptyState: (systemImage: String, title: String, message: String, showsAddAction: Bool) {
        switch filter {
        case .inbox:
            return ("tray", "Inbox is empty",
                    "Tasks with no project land here.", true)
        case .today:
            return ("checkmark.circle", "Nothing due today",
                    "Tasks due today and anything overdue show up here.", true)
        case .dueOn:
            return ("calendar", "Nothing scheduled",
                    "No tasks are scheduled for this day.", true)
        case .upcoming:
            return ("calendar.badge.clock", "Nothing coming up",
                    "Overdue and upcoming tasks appear here.", true)
        case .project:
            return ("folder", "No tasks yet",
                    "No tasks in this project yet.", true)
        case .completed:
            return ("checkmark.circle", "Nothing completed yet",
                    "Completed tasks will appear here.", false)
        case .all:
            return ("checkmark.circle", "Nothing here yet",
                    "Add a task with the field above to get started.", true)
        case .tag(let tag):
            return ("number", "No tasks tagged #\(tag)",
                    "Tasks tagged #\(tag) will appear here.", true)
        case .someday:
            return ("archivebox", "Nothing parked for someday",
                    "Tasks you set to Someday wait here, out of Inbox and Today.", true)
        case .area:
            return ("square.stack.3d.up", "No tasks in this area",
                    "Tasks in this area's projects, or filed directly under it, appear here.", true)
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
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(bucket.title)
                        .quietListSectionHeader()
                    Text("\(tasks.count)")
                        .font(DesignTokens.QuietList.countFont)
                        .foregroundStyle(DesignTokens.Palette.textTertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DesignTokens.Palette.textTertiary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .scribeAnimation(.snappy, value: isCollapsed)
                    Spacer()
                }
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.bottom, DesignTokens.Spacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let heading = bucket.heading {
                    HeadingSectionMenu(
                        heading: heading,
                        isFirst: viewModel.headings.first?.id == heading.id,
                        isLast: viewModel.headings.last?.id == heading.id,
                        onRename: { headingPrompt = .rename(heading) },
                        onMove: { viewModel.moveHeading(heading, by: $0) },
                        onDelete: { viewModel.deleteHeading(heading) }
                    )
                }
            }
            .accessibilityLabel("\(bucket.title), \(tasks.count) tasks")
            .accessibilityHint(isCollapsed ? "Collapsed. Activate to expand." : "Expanded. Activate to collapse.")

            if !isCollapsed {
                LazyVStack(spacing: 0) {
                    ForEach(tasks) { task in
                        if task.id != tasks.first?.id {
                            rowSeparator
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
                                onDrop: { payload in handleReorderDrop(payload, before: task, in: tasks, bucket: bucket) }
                            ))
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                .strokeBorder(accent, lineWidth: isDropTarget ? 2 : 0)
        )
        .modifier(BucketDropModifier(
            bucket: bucket,
            isEnabled: dropDate(for: bucket) != nil || bucket == .noDate
                || bucket == .someday || bucket.heading != nil,
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
    private func handleReorderDrop(_ payload: TaskDragPayload,
                                   before target: TodoTask,
                                   in tasks: [TodoTask],
                                   bucket: TaskListViewModel.Bucket? = nil) {
        reorderInsertionId = nil
        guard reorderEnabled, payload.id != target.id else { return }
        // Dropping across heading sections re-files the task under the
        // target section's heading (or none for the un-headed sections).
        if !viewModel.headings.isEmpty, let dragged = viewModel.task(id: payload.id) {
            let targetHeading = bucket?.heading?.id
            if dragged.headingId != targetHeading {
                viewModel.setHeading(targetHeading, for: dragged)
            }
        }
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
        case .overdue, .today, .evening: return today
        case .tomorrow:        return cal.date(byAdding: .day, value: 1, to: today)
        case .noDate:          return nil
        case .thisWeek, .later, .completed, .someday, .heading: return nil
        }
    }

    private func handleBucketDrop(_ payload: TaskDragPayload, into bucket: TaskListViewModel.Bucket) {
        dropTargetBucket = nil
        guard let task = viewModel.task(id: payload.id) else { return }
        withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
            if let heading = bucket.heading {
                viewModel.setHeading(heading.id, for: task)
            } else if bucket == .someday {
                viewModel.setScheduleBucket(.someday, for: task)
            } else if bucket == .evening {
                viewModel.planForEvening(task)
            } else if bucket == .noDate {
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
                if task.scheduleBucket == .anytime {
                    viewModel.setDueDate(merged, for: task)
                } else {
                    viewModel.setDueDate(merged, bucket: .anytime, for: task)
                }
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

/// Single-line row: checkbox · title · quiet trailing metadata (tags,
/// project, due). Hairline dividers between rows live in the parent list.
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
    /// Multi-select mode: the checkbox becomes a selection toggle and the row
    /// tap selects rather than opens the inspector.
    var isSelecting: Bool = false
    var isMultiSelected: Bool = false
    var onToggleSelect: () -> Void = {}

    @State private var isHovered: Bool = false
    @State private var showDuePopover = false
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var bounceTrigger = 0
    @FocusState private var titleFieldFocused: Bool

    @Environment(\.scribeAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var struck: Bool { task.isCompleted || task.isCancelled || isSettling }
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
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(minHeight: DesignTokens.QuietList.rowHeight)
        .quietListRowBackground(selected: isSelected || isMultiSelected,
                                hovered: affordancesVisible)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                .strokeBorder(accent.opacity(0.7), lineWidth: isKeyboardFocused ? 1.5 : 0)
        )
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous))
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
            if isSelecting {
                onToggleSelect()
            } else {
                if !reduceMotion { bounceTrigger += 1 }
                onToggle()
            }
        } label: {
            if isSelecting {
                Image(systemName: isMultiSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isMultiSelected ? accent : DesignTokens.Palette.textTertiary)
                    .font(.system(size: 16))
            } else {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isCompleted ? accent : DesignTokens.Palette.textTertiary)
                    .font(.system(size: 16, weight: .light))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: bounceTrigger)
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: task.isCompleted)
        .accessibilityLabel(isSelecting
                            ? (isMultiSelected ? "Deselect" : "Select")
                            : (task.isCompleted ? "Mark incomplete" : "Mark complete"))
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            if task.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                    .accessibilityLabel("Pinned")
            }

            priorityControl

            if isEditingTitle {
                titleEditor
            } else {
                titleText
            }

            if !task.notes.isEmpty {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.Palette.textTertiary.opacity(0.7))
                    .accessibilityHidden(true)
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            HStack(spacing: DesignTokens.Spacing.md) {
                subtaskChip

                planningChips

                if !tags.isEmpty {
                    Text(tags.map { "#\($0)" }.joined(separator: " "))
                        .font(DesignTokens.QuietList.rowMetaFont)
                        .foregroundStyle(DesignTokens.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }

                if let project = currentProject {
                    projectMenu(label: project.name)
                } else if affordancesVisible {
                    projectMenu(label: "Inbox")
                }

                dueControl
            }
        }
    }

    /// Duration estimate, recurrence glyph, and a "starts <day>" hint for
    /// deferred tasks (v20 planning fields).
    @ViewBuilder
    private var planningChips: some View {
        if task.recurrenceRule != nil {
            Image(systemName: "repeat")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.Palette.textTertiary)
                .accessibilityLabel("Repeats")
        }
        if let minutes = task.estimatedMinutes, minutes > 0 {
            Text(TaskDurationFormat.short(minutes))
                .font(DesignTokens.QuietList.rowMetaFont)
                .foregroundStyle(DesignTokens.Palette.textTertiary)
                .accessibilityLabel("Estimated \(TaskDurationFormat.short(minutes))")
        }
        if let start = task.startAt, start > Date() {
            Text("Starts \(start.formatted(.dateTime.month(.abbreviated).day()))")
                .font(DesignTokens.QuietList.rowMetaFont)
                .foregroundStyle(DesignTokens.Palette.textTertiary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var subtaskChip: some View {
        if let progress = subtaskProgress, progress.total > 0 {
            HStack(spacing: 3) {
                Image(systemName: progress.isComplete ? "checklist.checked" : "checklist")
                    .font(.system(size: 10))
                Text("\(progress.completed)/\(progress.total)")
                    .font(DesignTokens.QuietList.rowMetaFont)
            }
            .foregroundStyle(DesignTokens.Palette.textTertiary)
            .accessibilityLabel("\(progress.completed) of \(progress.total) subtasks completed")
        }
    }

    // MARK: - Title (double-click to edit)

    private var titleText: some View {
        Text(task.title)
            .font(DesignTokens.QuietList.rowTitleFont)
            .strikethrough(struck, color: DesignTokens.Palette.textTertiary)
            .foregroundStyle(struck ? DesignTokens.Palette.textTertiary : DesignTokens.Palette.textPrimary)
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
            .font(DesignTokens.QuietList.rowTitleFont)
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

    // MARK: - Project (move menu)

    private func projectMenu(label: String) -> some View {
        Menu {
            Button("Inbox") { onMoveProject(nil) }
            Divider()
            ForEach(projects) { project in
                Button(project.name) { onMoveProject(project.id) }
            }
        } label: {
            Text(label)
                .font(DesignTokens.QuietList.rowMetaFont)
                .foregroundStyle(DesignTokens.Palette.textTertiary)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
                .padding(DesignTokens.Spacing.xs)
            }
        } else if affordancesVisible {
            Button { showDuePopover = true } label: {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Set due date")
            .popover(isPresented: $showDuePopover, arrowEdge: .bottom) {
                InlineDatePickerView(selectedDate: Binding(
                    get: { task.dueAt },
                    set: { onSetDue($0) }
                ))
                .padding(DesignTokens.Spacing.xs)
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
/// "Mon", "Mar 12") with tabular figures; overdue dates use the overdue tone.
private struct DueDateLabel: View {
    let date: Date
    let isOverdue: Bool

    var body: some View {
        Text(formatted)
            .font(DesignTokens.QuietList.rowMetaFont)
            .foregroundStyle(isOverdue ? DesignTokens.Palette.overdue : DesignTokens.Palette.textTertiary)
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
