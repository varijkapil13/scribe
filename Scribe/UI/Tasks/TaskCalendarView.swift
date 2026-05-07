import SwiftUI

/// Full monthly calendar showing task load per day.
/// Left pane: calendar grid. Right pane (slides in): task list for selected day.
struct TaskCalendarView: View {

    @StateObject private var viewModel = TaskCalendarViewModel()
    @State private var editingTask: TodoTask?

    private let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        HStack(spacing: 0) {
            // ── Calendar grid ───────────────────────────────────────────────
            VStack(spacing: 0) {
                calendarHeader
                    .padding(.horizontal, DesignTokens.Spacing.lg)
                    .padding(.vertical, DesignTokens.Spacing.md)

                Divider()

                dayNamesRow
                    .padding(.horizontal, DesignTokens.Spacing.lg)
                    .padding(.vertical, DesignTokens.Spacing.sm)

                Divider()

                calendarGrid
            }

            // ── Day detail panel ────────────────────────────────────────────
            if let day = viewModel.selectedDay {
                Divider()
                dayPanel(for: day)
                    .frame(width: 290)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: DesignTokens.Motion.standard),
                   value: viewModel.selectedDay.map(TaskCalendarViewModel.dayKey))
        .background(DesignTokens.Palette.surface)
        .navigationTitle("Calendar")
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .sheet(item: $editingTask) { task in
            TaskEditorView(task: task)
        }
    }

    // MARK: - Calendar Header

    private var calendarHeader: some View {
        HStack {
            Button { viewModel.navigateMonth(by: -1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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

            Button { viewModel.navigateMonth(by: 1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Day names

    private var dayNamesRow: some View {
        HStack(spacing: 0) {
            ForEach(dayNames, id: \.self) { name in
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
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

                    // Task count badge (when > 0 and collapsed)
                    if tasks.count > 0 {
                        Text("\(tasks.count)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 16, minHeight: 14)
                            .background(Capsule().fill(countBadgeColor(for: tasks)))
                            .padding(.top, 4)
                            .padding(.trailing, 4)
                    }
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
        .background(isSelected ? Color.accentColor.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let date else { return }
            withAnimation(.easeOut(duration: DesignTokens.Motion.standard)) {
                if isSelected {
                    viewModel.selectedDay = nil
                } else {
                    viewModel.selectedDay = date
                }
            }
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
    }

    // MARK: - Day Panel

    private func dayPanel(for day: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
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

            let tasks = viewModel.tasks(for: day)
            if tasks.isEmpty {
                Spacer()
                VStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No tasks")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        ForEach(tasks) { task in
                            dayPanelRow(task)
                        }
                    }
                    .padding(DesignTokens.Spacing.md)
                }
            }
        }
        .background(DesignTokens.Palette.surface)
        .id(TaskCalendarViewModel.dayKey(for: day))
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
                .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
        )
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
