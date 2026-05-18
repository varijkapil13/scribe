import SwiftUI

/// Detail-pane view for the Tasks layer (slice 2). Renders a quick-add field
/// at the top followed by a vertical list of tasks bucketed by due date.
struct TaskListView: View {

    let filter: TaskStore.Filter

    @StateObject private var viewModel: TaskListViewModel
    @State private var selectedTask: TodoTask?
    @State private var pendingDelete: TodoTask?
    @State private var collapsedBuckets: Set<String> = []
    @State private var showQuickAddDatePicker = false
    @State private var showQuickAddSyntaxHelp = false
    @State private var quickAddFieldHeight: CGFloat = 28
    /// On the Today filter, upcoming buckets (tomorrow / this week / later) and
    /// completed are hidden behind a "Show N more" link by default — the
    /// Today screen is meant to focus on today + overdue.
    @State private var todayUpcomingExpanded: Bool = false

    init(filter: TaskStore.Filter) {
        self.filter = filter
        _viewModel = StateObject(wrappedValue: TaskListViewModel(filter: filter))
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
        .animation(.easeOut(duration: DesignTokens.Motion.standard), value: selectedTask?.id)
        .navigationTitle(headerTitle)
        .searchable(text: $viewModel.searchQuery, prompt: "Search tasks")
        .onAppear {
            viewModel.start()
            focusQuickAddIfNeeded()
        }
        .onDisappear { viewModel.stop() }
        .onChange(of: filter) { _, newFilter in
            viewModel.switchFilter(to: newFilter)
            selectedTask = nil
            todayUpcomingExpanded = false
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
        .background(shortcutButtons)
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
        for group in viewModel.groups {
            if let task = group.tasks.first(where: { $0.id == id }) { return task }
        }
        return viewModel.searchResults.first(where: { $0.id == id })
    }

    // MARK: - Focus

    private func focusQuickAddIfNeeded() {
        guard filter == .today || filter == .inbox else { return }
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
        case .upcoming:     return "Upcoming"
        case .all:          return "All Tasks"
        case .completed:    return "Completed"
        case .project(let id): return "Project · \(id.prefix(6))"
        case .tag(let tag):    return "#\(tag)"
        }
    }

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
            .popover(isPresented: $showQuickAddSyntaxHelp, arrowEdge: .bottom) {
                quickAddSyntaxHelp
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
            .popover(isPresented: $showQuickAddDatePicker, arrowEdge: .bottom) {
                InlineDatePickerView(selectedDate: $viewModel.quickAddDueDate)
                    .padding(4)
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
    private func taskRow(for task: TodoTask) -> some View {
        TaskRowView(
            task: task,
            isRecentlyCompleted: viewModel.recentlyCompletedRecurring.contains(task.id),
            tags: viewModel.tags(for: task.id),
            isFocused: selectedTask?.id == task.id,
            onToggle: { viewModel.toggleCompleted(task) },
            onOpen: {
                viewModel.focusedTaskId = task.id
                withAnimation(.easeOut(duration: DesignTokens.Motion.standard)) {
                    selectedTask = task
                }
            }
        )
        .onTapGesture {
            viewModel.focusedTaskId = task.id
            withAnimation(.easeOut(duration: DesignTokens.Motion.standard)) {
                selectedTask = (selectedTask?.id == task.id) ? nil : task
            }
        }
        .draggable(TaskDragPayload(id: task.id))
        .contextMenu {
            Button {
                withAnimation { selectedTask = task }
            } label: {
                Label("Edit…", systemImage: "pencil")
            }
            Button(role: .destructive) {
                pendingDelete = task
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .inbox:    return "Tasks without a project show up here."
        case .today:    return "Nothing due today."
        case .upcoming: return "No tasks due in the next 7 days."
        case .completed: return "Completed tasks will appear here."
        default:        return "Add a task with the field above to get started."
        }
    }

    @ViewBuilder
    private func section(for bucket: TaskListViewModel.Bucket, tasks: [TodoTask]) -> some View {
        let isCollapsed = collapsedBuckets.contains(bucket.title)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    if isCollapsed {
                        collapsedBuckets.remove(bucket.title)
                    } else {
                        collapsedBuckets.insert(bucket.title)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(bucket.title)
                        .eyebrowStyle()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .animation(.easeOut(duration: 0.18), value: isCollapsed)
                    Spacer()
                    Text("\(tasks.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, DesignTokens.Spacing.xs)
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                VStack(spacing: 0) {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                        if index > 0 {
                            Divider()
                                .padding(.leading, 32)
                        }
                        taskRow(for: task)
                    }
                }
            }
        }
    }
}

// MARK: - Row

/// Compact single-line row: checkbox · title (with inline tag spans) ·
/// trailing meta (priority dot, due text, notes glyph). No per-row card
/// chrome — hairline dividers between rows live in the parent list.
struct TaskRowView: View {
    let task: TodoTask
    let isRecentlyCompleted: Bool
    let tags: [String]
    var isFocused: Bool = false
    let onToggle: () -> Void
    let onOpen: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            Button(action: onToggle) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isCompleted ? Color.accentColor : .secondary)
                    .font(.system(size: 15, weight: .regular))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isCompleted ? "Mark incomplete" : "Mark complete")

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
            if isFocused {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous))
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isFocused {
            Color.accentColor.opacity(0.10)
        } else if isHovered {
            Color.primary.opacity(0.04)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            PriorityDot(priority: task.priority)

            Text(titleWithTags)
                .font(.system(size: 13))
                .strikethrough(task.isCompleted || isRecentlyCompleted, color: .secondary)
                .foregroundStyle(task.isCompleted || isRecentlyCompleted ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: DesignTokens.Spacing.xs)

            if !task.notes.isEmpty {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .help("Has notes")
            }

            if let due = task.dueAt {
                DueDateLabel(
                    date: due,
                    isOverdue: !task.isCompleted && due < Calendar.current.startOfDay(for: Date())
                )
            }
        }
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
}

/// Priority indicator: 6pt filled dot (high = red, medium = orange,
/// low = blue, none = no dot). Replaces the previous full-text capsule chip.
private struct PriorityDot: View {
    let priority: TodoTask.Priority?

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 6, height: 6)
            .accessibilityLabel(label)
    }

    private var tint: Color {
        switch priority {
        case .high:   return DesignTokens.Palette.priorityHigh
        case .medium: return DesignTokens.Palette.priorityMedium
        case .low:    return DesignTokens.Palette.priorityLow
        case .none:   return .clear
        }
    }

    private var label: String {
        switch priority {
        case .high:   return "High priority"
        case .medium: return "Medium priority"
        case .low:    return "Low priority"
        case .none:   return ""
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
