import SwiftUI

/// Full monthly calendar showing task load and daily notes per day.
/// Left pane: calendar grid. Right pane (slides in): tasks + daily note for selected day.
struct TaskCalendarView: View {

    @StateObject private var viewModel = TaskCalendarViewModel()
    @State private var editingTask: TodoTask?
    @State private var mode: Mode = .month
    @State private var dropTargetKey: String?
    var onNavigateToNote: ((String) -> Void)?

    /// Shared "one day model" (Slice E1). The calendar's selected day mirrors
    /// the date the Today home plans against, so jumping between the two
    /// surfaces keeps the focused day consistent.
    @Environment(DayPlanningModel.self) private var dayPlanning

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scribeAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Display mode toggle: a full month grid, or a scrollable agenda (week-
    /// at-a-glance) list anchored at the selected day.
    private enum Mode: String, CaseIterable, Identifiable {
        case month, agenda
        var id: String { rawValue }
        var label: String { self == .month ? "Month" : "Week" }
        var symbol: String { self == .month ? "calendar" : "list.bullet" }
    }

    /// Short localized weekday symbols rotated to honour `Calendar.firstWeekday`.
    private var dayNames: [String] {
        let symbols = viewModel.cal.shortWeekdaySymbols
        let shift = viewModel.cal.firstWeekday - 1
        guard shift > 0, shift < symbols.count else { return symbols }
        return Array(symbols[shift...] + symbols[..<shift])
    }

    private var dayNamesAccessible: [String] {
        let symbols = viewModel.cal.weekdaySymbols
        let shift = viewModel.cal.firstWeekday - 1
        guard shift > 0, shift < symbols.count else { return symbols }
        return Array(symbols[shift...] + symbols[..<shift])
    }

    var body: some View {
        HStack(spacing: 0) {
            // ── Calendar grid / agenda ──────────────────────────────────────
            VStack(spacing: 0) {
                calendarHeader
                    .padding(.horizontal, DesignTokens.Spacing.lg)
                    .padding(.vertical, DesignTokens.Spacing.md)

                Divider()

                if mode == .month {
                    dayNamesRow
                        .padding(.horizontal, DesignTokens.Spacing.lg)
                        .padding(.vertical, DesignTokens.Spacing.sm)

                    Divider()

                    calendarGrid
                } else {
                    agendaList
                }
            }

            // ── Day detail panel ────────────────────────────────────────────
            if let day = viewModel.selectedDay {
                Divider()
                dayPanel(for: day)
                    .frame(width: 290)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .scribeAnimation(.snappy, value: viewModel.selectedDay.map(TaskCalendarViewModel.dayKey))
        .background(DesignTokens.Palette.surface)
        .navigationTitle("Calendar")
        .onAppear {
            viewModel.start()
            // Adopt the shared day so we open on whatever the user last planned
            // (e.g. a non-today date chosen in the Today home).
            viewModel.focus(on: dayPlanning.selectedDate)
        }
        .onDisappear { viewModel.stop() }
        .onChange(of: viewModel.selectedDay) { _, newDay in
            // Calendar selection → shared model. A nil selection (day panel
            // dismissed) leaves the shared day untouched.
            if let newDay { dayPlanning.select(newDay) }
        }
        .onChange(of: dayPlanning.selectedDate) { _, newDate in
            // Shared model → calendar (e.g. changed elsewhere while mounted).
            viewModel.focus(on: newDate)
        }
        .sheet(item: $editingTask) { task in
            TaskInspectorSheet(task: task) { editingTask = nil }
        }
    }

    // MARK: - Calendar Header

    private var calendarHeader: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button { viewModel.navigateMonth(by: -1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous month")

            Button(action: jumpToToday) {
                Text("Today")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                            .fill(DesignTokens.Palette.fill(.hover, contrast: contrast))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Jump to today")

            Spacer()

            VStack(spacing: 2) {
                Text(viewModel.displayMonth, format: .dateTime.month(.wide).year())
                    .font(.system(.title3, weight: .semibold))
                let total = viewModel.tasksByDay.values.reduce(0) { $0 + $1.count }
                if total > 0 {
                    Text("\(total) task\(total == 1 ? "" : "s") this month")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { m in
                    Label(m.label, systemImage: m.symbol).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Calendar view mode")

            Button { viewModel.navigateMonth(by: 1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next month")
        }
    }

    private func jumpToToday() {
        let today = viewModel.cal.startOfDay(for: Date())
        withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
            viewModel.displayMonth = viewModel.cal.startOfMonth(for: today)
            viewModel.selectedDay = today
        }
    }

    // MARK: - Day names

    private var dayNamesRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(dayNames.enumerated()), id: \.offset) { index, name in
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(dayNamesAccessible[safe: index] ?? name)
            }
        }
    }

    // MARK: - Agenda (week) list

    /// Week-at-a-glance list anchored on the selected day's week. Each day shows
    /// its tasks; empty days collapse to a single line. Same reschedule menu as
    /// the month grid.
    private var agendaList: some View {
        let anchor = viewModel.selectedDay ?? viewModel.cal.startOfDay(for: Date())
        let days = weekDays(containing: anchor)
        return ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                ForEach(days, id: \.self) { day in
                    agendaDaySection(day)
                }
            }
            .padding(DesignTokens.Spacing.lg)
        }
    }

    private func weekDays(containing date: Date) -> [Date] {
        let cal = viewModel.cal
        let start = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: start)
        let offset = (weekday - cal.firstWeekday + 7) % 7
        guard let weekStart = cal.date(byAdding: .day, value: -offset, to: start) else { return [start] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
    }

    @ViewBuilder
    private func agendaDaySection(_ day: Date) -> some View {
        let tasks = viewModel.tasks(for: day)
        let isToday = viewModel.cal.isDateInToday(day)
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(day, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.system(size: 12, weight: isToday ? .bold : .semibold))
                    .foregroundStyle(isToday ? accent : .primary)
                if isToday {
                    Text("Today").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(tasks.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if tasks.isEmpty {
                Text("No tasks")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(tasks) { task in dayPanelRow(task) }
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .fill(viewModel.cal.isDate(day, inSameDayAs: viewModel.selectedDay ?? .distantPast)
                      ? DesignTokens.Palette.accentFill(.hover, accent: accent, contrast: contrast)
                      : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .strokeBorder(dropTargetKey == TaskCalendarViewModel.dayKey(for: day) ? accent : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
                viewModel.selectedDay = day
            }
        }
        .dropDestination(for: TaskDragPayload.self) { payloads, _ in
            guard let first = payloads.first else { return false }
            reschedule(taskId: first.id, to: day)
            return true
        } isTargeted: { targeted in
            dropTargetKey = targeted ? TaskCalendarViewModel.dayKey(for: day) : (dropTargetKey == TaskCalendarViewModel.dayKey(for: day) ? nil : dropTargetKey)
        }
    }

    // MARK: - Calendar Grid

    private var calendarGrid: some View {
        let cells  = viewModel.buildCells()
        let rows   = cells.count / 7
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

        return GeometryReader { geo in
            let cellH = max(80, (geo.size.height - 1) / CGFloat(rows))
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(0 ..< cells.count, id: \.self) { i in
                    calendarCell(cells[i], height: cellH)
                    // Horizontal dividers between rows (not after last row)
                }
            }
            .overlay(gridLines(rows: rows, cols: 7, size: geo.size, cellH: cellH))
        }
    }

    // Hairline grid lines drawn as overlay so they don't affect cell layout.
    private func gridLines(rows: Int, cols: Int, size: CGSize, cellH: CGFloat) -> some View {
        let colW = size.width / CGFloat(cols)
        return ZStack(alignment: .topLeading) {
            // Horizontal lines (between rows)
            ForEach(1 ..< rows, id: \.self) { row in
                Rectangle()
                    .fill(DesignTokens.Palette.cardBorder)
                    .frame(width: size.width, height: 0.5)
                    .offset(y: cellH * CGFloat(row))
            }
            // Vertical lines (between columns)
            ForEach(1 ..< cols, id: \.self) { col in
                Rectangle()
                    .fill(DesignTokens.Palette.cardBorder)
                    .frame(width: 0.5, height: size.height)
                    .offset(x: colW * CGFloat(col))
            }
        }
    }

    // MARK: - Calendar Cell

    private func calendarCell(_ cell: TaskCalendarViewModel.CalendarCell, height: CGFloat) -> some View {
        let date      = cell.date
        let tasks     = date.map { viewModel.tasks(for: $0) } ?? []
        let noteExists = date.map { viewModel.hasNote(for: $0) } ?? false
        let isToday   = date.map { viewModel.cal.isDateInToday($0) } ?? false
        let isSelected = date.map { d in
            viewModel.selectedDay.map { viewModel.cal.isDate(d, inSameDayAs: $0) } ?? false
        } ?? false

        return VStack(alignment: .leading, spacing: 3) {
            if let date {
                HStack(alignment: .top) {
                    // Day number badge
                    Text("\(viewModel.cal.component(.day, from: date))")
                        .font(.system(size: 12, weight: isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? Color.white : cell.isCurrentMonth ? Color.primary : Color.secondary.opacity(0.4))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(isToday ? Color.accentColor : .clear))

                    Spacer(minLength: 0)

                    HStack(spacing: 3) {
                        // Note dot
                        if noteExists {
                            Image(systemName: "note.text")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(isToday ? Color.white.opacity(0.85) : Color.accentColor.opacity(0.7))
                        }

                        // Task count badge (when > 0)
                        if tasks.count > 0 {
                            Text("\(tasks.count)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(minWidth: 16, minHeight: 14)
                                .background(Capsule().fill(countBadgeColor(for: tasks)))
                        }
                    }
                    .padding(.top, 4)
                    .padding(.trailing, 4)
                }
                .padding(.horizontal, 6)
                .padding(.top, 6)

                // Task chips (up to visible count)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(tasks.prefix(visibleTaskCount(height: height)), id: \.id) { task in
                        taskChip(task)
                    }
                    let overflow = tasks.count - visibleTaskCount(height: height)
                    if overflow > 0 {
                        Text("+\(overflow) more")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                    }
                }
                .padding(.horizontal, 4)

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(isSelected ? DesignTokens.Palette.accentFill(.hover, accent: accent, contrast: contrast) : .clear)
        .overlay(dropHighlight(for: date))
        .contentShape(Rectangle())
        .onTapGesture {
            guard let date else { return }
            withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
                if isSelected {
                    viewModel.selectedDay = nil
                } else {
                    viewModel.selectedDay = date
                }
            }
        }
        .modifier(CalendarCellDropModifier(
            date: date,
            isTargeted: { targeted in
                guard let date else { return }
                let key = TaskCalendarViewModel.dayKey(for: date)
                dropTargetKey = targeted ? key : (dropTargetKey == key ? nil : dropTargetKey)
            },
            onDrop: { payload in
                guard let date else { return }
                reschedule(taskId: payload.id, to: date)
            }
        ))
        .contextMenu {
            if let date { calendarDayMenu(for: date) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dayCellAccessibilityLabel(date: date, isToday: isToday))
        .accessibilityValue(dayCellAccessibilityValue(tasks: tasks, noteExists: noteExists))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func dropHighlight(for date: Date?) -> some View {
        if let date, dropTargetKey == TaskCalendarViewModel.dayKey(for: date) {
            Rectangle().strokeBorder(accent, lineWidth: 2)
        }
    }

    private func dayCellAccessibilityLabel(date: Date?, isToday: Bool) -> String {
        guard let date else { return "" }
        return date.formatted(date: .complete, time: .omitted) + (isToday ? ", today" : "")
    }

    private func dayCellAccessibilityValue(tasks: [TodoTask], noteExists: Bool) -> String {
        var parts: [String] = []
        if tasks.isEmpty { parts.append("no tasks") }
        else { parts.append("\(tasks.count) task\(tasks.count == 1 ? "" : "s")") }
        if noteExists { parts.append("has daily note") }
        return parts.joined(separator: ", ")
    }

    /// Keyboard-equivalent reschedule menu for a calendar day. Lists the day's
    /// tasks; choosing one reschedules it to that day. (Drag is the pointer
    /// path; this is the menu path required for keyboard/VoiceOver users.)
    @ViewBuilder
    private func calendarDayMenu(for date: Date) -> some View {
        Button {
            withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
                viewModel.selectedDay = date
            }
        } label: {
            Label("Open day", systemImage: "calendar")
        }
        let movable = viewModel.tasksByDay.values.flatMap { $0 }
            .filter { !viewModel.cal.isDate($0.dueAt ?? .distantPast, inSameDayAs: date) }
        if !movable.isEmpty {
            Menu {
                ForEach(movable.prefix(20)) { task in
                    Button(task.title) { reschedule(taskId: task.id, to: date) }
                }
            } label: {
                Label("Reschedule task here", systemImage: "arrow.uturn.right")
            }
        }
    }

    private func reschedule(taskId: String, to day: Date) {
        dropTargetKey = nil
        withAnimation(DesignTokens.Motion.resolve(.snappy, reduceMotion: reduceMotion)) {
            viewModel.reschedule(taskId: taskId, to: day)
        }
    }

    private func visibleTaskCount(height: CGFloat) -> Int {
        // Header row ~34px, each chip ~18px, overflow label ~16px
        let available = height - 34 - 16
        return max(0, Int(available / 18))
    }

    // MARK: - Task Chip

    private func taskChip(_ task: TodoTask) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(priorityColor(task.priority))
                .frame(width: 3)
                .frame(height: 12)

            Text(task.title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(task.isCompleted ? Color.secondary : .primary)
                .strikethrough(task.isCompleted)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(priorityColor(task.priority).opacity(0.10))
        )
        .draggable(TaskDragPayload(id: task.id))
    }

    // MARK: - Day Panel

    private func dayPanel(for day: Date) -> some View {
        let tasks = viewModel.tasks(for: day)
        let dailyNote = viewModel.existingDailyNote(for: day)

        return VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 2) {
                Text(day, format: .dateTime.weekday(.wide))
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(day, format: .dateTime.month(.wide).day())
                    .font(.system(.title3, weight: .semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.lg)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // ── Tasks section ────────────────────────────────────
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        Text("Tasks")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.bottom, 2)

                        if tasks.isEmpty {
                            HStack(spacing: DesignTokens.Spacing.sm) {
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(.tertiary)
                                Text("No tasks")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, DesignTokens.Spacing.sm)
                        } else {
                            ForEach(tasks) { task in
                                dayPanelRow(task)
                            }
                        }
                    }
                    .padding(DesignTokens.Spacing.md)

                    Divider()
                        .padding(.horizontal, DesignTokens.Spacing.md)

                    // ── Daily Note section ───────────────────────────────
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        Text("Daily Note")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.bottom, 2)

                        if let note = dailyNote {
                            dailyNoteCard(note)
                        } else {
                            Button {
                                if let note = try? NoteStore.shared.dailyNote(for: day) {
                                    onNavigateToNote?(note.id)
                                }
                            } label: {
                                Label("New Daily Note", systemImage: "square.and.pencil")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, DesignTokens.Spacing.sm)
                        }
                    }
                    .padding(DesignTokens.Spacing.md)
                }
            }
        }
        .background(DesignTokens.Palette.surface)
        .id(TaskCalendarViewModel.dayKey(for: day))
    }

    private func dailyNoteCard(_ note: Note) -> some View {
        Button {
            onNavigateToNote?(note.id)
        } label: {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                if !note.body.isEmpty {
                    Text(note.body)
                        .font(.system(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Empty note")
                        .font(.system(.caption))
                        .foregroundStyle(.tertiary)
                        .italic()
                }

                Label("Open note", systemImage: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.Palette.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func dayPanelRow(_ task: TodoTask) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Button { viewModel.toggleCompleted(task) } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(task.isCompleted ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(.callout))
                    .strikethrough(task.isCompleted, color: .secondary)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    .lineLimit(2)

                HStack(spacing: DesignTokens.Spacing.sm) {
                    if let dueAt = task.dueAt {
                        Label(dueAt.formatted(date: .omitted, time: .shortened),
                              systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let priority = task.priority {
                        Text(priority.rawValue.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(priorityColor(priority))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(priorityColor(priority).opacity(0.12)))
                    }
                }
            }

            Spacer(minLength: 0)

            Button { editingTask = task } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.secondary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Edit task")
        }
        .padding(DesignTokens.Spacing.sm)
        .background(DesignTokens.Palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .strokeBorder(DesignTokens.Palette.cardBorder(contrast), lineWidth: 1)
        )
        .draggable(TaskDragPayload(id: task.id))
    }

    // MARK: - Helpers

    private func priorityColor(_ priority: TodoTask.Priority?) -> Color {
        switch priority {
        case .high:   return DesignTokens.Palette.priorityHigh
        case .medium: return DesignTokens.Palette.priorityMedium
        case .low:    return DesignTokens.Palette.priorityLow
        case .none:   return .accentColor
        }
    }

    private func countBadgeColor(for tasks: [TodoTask]) -> Color {
        if tasks.contains(where: { $0.priority == .high })   { return DesignTokens.Palette.priorityHigh }
        if tasks.contains(where: { $0.priority == .medium }) { return DesignTokens.Palette.priorityMedium }
        return Color.accentColor
    }
}

// MARK: - Calendar-cell drop modifier

/// Adds a `dropDestination` for `TaskDragPayload` on a calendar day cell,
/// gated on the cell having a real date (padding cells are inert).
private struct CalendarCellDropModifier: ViewModifier {
    let date: Date?
    let isTargeted: (Bool) -> Void
    let onDrop: (TaskDragPayload) -> Void

    func body(content: Content) -> some View {
        if date != nil {
            content.dropDestination(for: TaskDragPayload.self) { payloads, _ in
                guard let first = payloads.first else { return false }
                onDrop(first)
                return true
            } isTargeted: { isTargeted($0) }
        } else {
            content
        }
    }
}

// MARK: - Safe-index helper

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
