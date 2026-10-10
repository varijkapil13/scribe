import AppKit
import SwiftUI

/// Day planner (TaskCalendarView's "Day" mode): a 24-hour time grid with the
/// day's calendar events and scheduled task blocks, plus a side list of tasks
/// still waiting for a time.
///
/// - Drag a task from the side list onto the grid to schedule it (snaps to
///   15 minutes; a task without an estimate gets a 30-minute block).
/// - Drag a block to move it; drag its bottom edge to resize it.
/// - Every gesture also has a context-menu / VoiceOver action, and every
///   change is undoable (Edit › Undo).
struct TaskPlannerView: View {

    let day: Date
    let onOpen: (TodoTask) -> Void

    @StateObject private var viewModel: TaskPlannerViewModel
    @State private var interaction: PlannerBlockInteraction?
    @State private var gridTargeted = false

    @Environment(\.undoManager) private var undoManager
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scribeAccent) private var accent

    private let geometry = TimeGridGeometry(hourHeight: 56, snapMinutes: 15)
    private static let gridSpace = "scribe.planner.grid"
    private static let hourLabelWidth: CGFloat = 52
    private static let sideListWidth: CGFloat = 250

    init(day: Date, onOpen: @escaping (TodoTask) -> Void) {
        self.day = day
        self.onOpen = onOpen
        _viewModel = StateObject(wrappedValue: TaskPlannerViewModel(
            store: TaskStore.shared,
            reminderScheduler: TaskReminderScheduler.shared
        ))
    }

    var body: some View {
        HStack(spacing: 0) {
            sideListPane
                .frame(width: Self.sideListWidth)
            Divider()
            VStack(spacing: 0) {
                if !viewModel.allDayEvents.isEmpty {
                    allDayStrip
                    Divider()
                }
                if !viewModel.showsCalendarEvents {
                    calendarHint
                    Divider()
                }
                grid
            }
        }
        .onAppear {
            viewModel.undoManager = undoManager
            viewModel.show(day: day)
            viewModel.start()
        }
        .onDisappear { viewModel.stop() }
        .onChange(of: day) { _, newDay in viewModel.show(day: newDay) }
    }

    // MARK: - Side list

    private var sideListPane: some View {
        let list = viewModel.sideList
        return ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                Text("Drag a task onto the grid to give it a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                sideSection(title: viewModel.calendar.isDateInToday(viewModel.day) ? "Today" : "This Day",
                            tasks: list.forDay,
                            empty: "Nothing else due")
                sideSection(title: "Anytime", tasks: list.undated, empty: "No undated tasks")
            }
            .padding(DesignTokens.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignTokens.Palette.surface)
    }

    @ViewBuilder
    private func sideSection(title: String, tasks: [TodoTask], empty: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(tasks.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if tasks.isEmpty {
                Text(empty)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(tasks) { task in sideRow(task) }
            }
        }
    }

    private func sideRow(_ task: TodoTask) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(task.title)
                .font(.system(size: 12))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(TaskDurationFormat.short(PlannerScheduling.durationMinutes(of: task)))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .fill(DesignTokens.Palette.fill(.hover, contrast: contrast))
        )
        .contentShape(Rectangle())
        .onTapGesture { onOpen(task) }
        .draggable(TaskDragPayload(id: task.id))
        .contextMenu {
            Button { onOpen(task) } label: { Label("Edit…", systemImage: "pencil") }
            Menu {
                ForEach(Self.menuHours, id: \.self) { hour in
                    Button(hourTitle(hour)) {
                        viewModel.schedule(taskId: task.id, startMinute: hour * 60,
                                           snapMinutes: geometry.snapMinutes)
                    }
                }
            } label: {
                Label("Schedule at", systemImage: "clock")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Drag onto the time grid, or use the actions to schedule.")
        .accessibilityAction(named: "Schedule at 9 AM") {
            viewModel.schedule(taskId: task.id, startMinute: 9 * 60, snapMinutes: geometry.snapMinutes)
        }
    }

    /// Hours offered by the "Schedule at" menu.
    private static let menuHours: [Int] = Array(7...20)

    // MARK: - All-day strip + hint

    private var allDayStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text("All day")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.hourLabelWidth - 6, alignment: .trailing)
                ForEach(viewModel.allDayEvents, id: \.self) { event in
                    Text(event.title.isEmpty ? "Event" : event.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                        .padding(.vertical, DesignTokens.Spacing.xxs)
                        .background(Capsule().fill(DesignTokens.Palette.fill(.selected, contrast: contrast)))
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
        }
    }

    private var calendarHint: some View {
        Text("Turn on Settings → Calendar to see your events beside your tasks.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    hourLabels
                    GeometryReader { geo in
                        dayColumn(width: geo.size.width)
                    }
                    .frame(height: CGFloat(geometry.totalHeight))
                    .padding(.trailing, DesignTokens.Spacing.md)
                }
                .padding(.vertical, DesignTokens.Spacing.sm)
            }
            .onAppear { proxy.scrollTo(Self.hourAnchor(initialHour), anchor: .top) }
            .onChange(of: viewModel.day) { _, _ in
                proxy.scrollTo(Self.hourAnchor(initialHour), anchor: .top)
            }
        }
    }

    /// The hour scrolled to on open: just before now (today) or before the
    /// first block, else 8 AM.
    private var initialHour: Int {
        if viewModel.calendar.isDateInToday(viewModel.day) {
            return max(0, viewModel.calendar.component(.hour, from: Date()) - 1)
        }
        if let first = viewModel.gridItems.first {
            return max(0, first.startMinute / 60 - 1)
        }
        return 8
    }

    private static func hourAnchor(_ hour: Int) -> String { "planner.hour.\(hour)" }

    private var hourLabels: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hour == 0 ? "" : hourTitle(hour))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: Self.hourLabelWidth - 8, alignment: .trailing)
                    .offset(y: -6)
                    .frame(width: Self.hourLabelWidth, height: CGFloat(geometry.hourHeight), alignment: .topLeading)
                    .id(Self.hourAnchor(hour))
                    .accessibilityHidden(true)
            }
        }
    }

    private func hourTitle(_ hour: Int) -> String {
        TimeGridGeometry.date(atMinute: hour * 60, on: viewModel.day, calendar: viewModel.calendar)
            .formatted(date: .omitted, time: .shortened)
    }

    @ViewBuilder
    private func dayColumn(width: CGFloat) -> some View {
        let total = CGFloat(geometry.totalHeight)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(gridTargeted
                      ? DesignTokens.Palette.accentFill(.hover, accent: accent, contrast: contrast)
                      : Color.clear)
                .frame(width: width, height: total)

            ForEach(0..<24, id: \.self) { hour in
                Rectangle()
                    .fill(DesignTokens.Palette.cardBorder(contrast))
                    .frame(width: width, height: 0.5)
                    .offset(y: CGFloat(geometry.y(forMinute: Double(hour * 60))))
                Rectangle()
                    .fill(DesignTokens.Palette.cardBorder(contrast).opacity(0.5))
                    .frame(width: width, height: 0.5)
                    .offset(y: CGFloat(geometry.y(forMinute: Double(hour * 60 + 30))))
            }

            ForEach(viewModel.gridItems) { item in
                block(item, width: width)
            }

            if viewModel.calendar.isDateInToday(viewModel.day) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    nowLine(at: context.date, width: width)
                }
                .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: total, alignment: .topLeading)
        .coordinateSpace(name: Self.gridSpace)
        .contentShape(Rectangle())
        .dropDestination(for: TaskDragPayload.self) { payloads, location in
            guard let first = payloads.first, let task = viewModel.task(id: first.id) else { return false }
            let minute = geometry.startMinute(forY: Double(location.y),
                                              durationMinutes: PlannerScheduling.durationMinutes(of: task))
            viewModel.schedule(taskId: first.id, startMinute: minute, snapMinutes: geometry.snapMinutes)
            return true
        } isTargeted: { targeted in
            gridTargeted = targeted
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Time grid")
    }

    private func nowLine(at date: Date, width: CGFloat) -> some View {
        let minute = TimeGridGeometry.minuteOfDay(for: date, on: viewModel.day, calendar: viewModel.calendar)
        return HStack(spacing: 0) {
            Circle().fill(DesignTokens.Palette.recording).frame(width: 7, height: 7)
            Rectangle().fill(DesignTokens.Palette.recording).frame(height: 1)
        }
        .frame(width: width + 3, height: 7)
        .offset(x: -3, y: CGFloat(geometry.y(forMinute: Double(minute))) - 3.5)
        .accessibilityHidden(true)
    }

    // MARK: - Blocks

    /// Start and duration a block is drawn with (the live preview while it's
    /// being dragged or resized).
    private func displayed(_ item: PlannerGridItem) -> (start: Int, duration: Int) {
        guard case .task(let task) = item.kind, let interaction, interaction.taskId == task.id else {
            return (item.startMinute, item.durationMinutes)
        }
        let duration = PlannerScheduling.durationMinutes(of: task)
        switch interaction.kind {
        case .move:
            let moved = geometry.movedStart(startMinute: item.startMinute, durationMinutes: duration,
                                            deltaY: interaction.translation)
            let start = PlannerScheduling.representableStartMinute(moved, snapMinutes: geometry.snapMinutes)
            return (start, min(duration, TimeGridGeometry.minutesPerDay - start))
        case .resize:
            return (item.startMinute,
                    geometry.resizedDuration(startMinute: item.startMinute, durationMinutes: duration,
                                             deltaY: interaction.translation))
        }
    }

    @ViewBuilder
    private func block(_ item: PlannerGridItem, width: CGFloat) -> some View {
        let shown = displayed(item)
        let minHeight = CGFloat(geometry.y(forMinute: 15)) - 2
        let x = width * CGFloat(item.placement.leadingFraction)
        let blockWidth = max(24, width * CGFloat(item.placement.widthFraction) - 3)
        let y = CGFloat(geometry.y(forMinute: Double(shown.start)))
        let height = max(minHeight, CGFloat(geometry.y(forMinute: Double(shown.duration))) - 2)
        Group {
            switch item.kind {
            case .event(let event):
                eventBlock(event)
            case .task(let task):
                taskBlock(task, item: item, start: shown.start, duration: shown.duration, height: height)
            }
        }
        .frame(width: blockWidth, height: height, alignment: .topLeading)
        .offset(x: x + 1, y: y + 1)
        .zIndex(blockZIndex(for: item))
    }

    /// Events under tasks; the block being dragged above everything.
    private func blockZIndex(for item: PlannerGridItem) -> Double {
        guard let taskId = item.taskId else { return 0 }
        return interaction?.taskId == taskId ? 2 : 1
    }

    private func eventBlock(_ event: CalendarEventInfo) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(event.title.isEmpty ? "Event" : event.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
            Text(timeRange(event.start, event.end))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous)
                .fill(DesignTokens.Palette.fill(.strong, contrast: contrast))
        )
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.secondary).frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Event \(event.title), \(timeRange(event.start, event.end))")
    }

    private func taskBlock(_ task: TodoTask, item: PlannerGridItem, start: Int, duration: Int, height: CGFloat) -> some View {
        let startDate = TimeGridGeometry.date(atMinute: start, on: viewModel.day, calendar: viewModel.calendar)
        let endDate = startDate.addingTimeInterval(TimeInterval(duration * 60))
        let isActive = interaction?.taskId == task.id
        return VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 4) {
                Button { viewModel.toggleCompleted(task) } label: {
                    Image(systemName: "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Complete")
                Text(task.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(height > 40 ? 2 : 1)
            }
            if height > 30 {
                Text(timeRange(startDate, endDate))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous)
                .fill(DesignTokens.Palette.accentFill(isActive ? .strong : .selected, accent: accent, contrast: contrast))
        )
        .overlay(alignment: .leading) {
            Rectangle().fill(accent).frame(width: 3)
        }
        .overlay(alignment: .bottom) { resizeHandle(task: task, item: item) }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onOpen(task) }
        .gesture(moveGesture(task: task, item: item))
        .contextMenu { blockMenu(task: task, item: item) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title), \(timeRange(startDate, endDate))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Move 15 minutes later") { nudge(task: task, item: item, by: geometry.snapMinutes) }
        .accessibilityAction(named: "Move 15 minutes earlier") { nudge(task: task, item: item, by: -geometry.snapMinutes) }
        .accessibilityAction(named: "Make longer") { stretch(task: task, by: geometry.snapMinutes, item: item) }
        .accessibilityAction(named: "Make shorter") { stretch(task: task, by: -geometry.snapMinutes, item: item) }
        .accessibilityAction(named: "Remove time") { viewModel.unschedule(taskId: task.id) }
    }

    private func resizeHandle(task: TodoTask, item: PlannerGridItem) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 7)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in PlannerCursor.setResizing(inside) }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: CoordinateSpace.named(Self.gridSpace))
                    .onChanged { value in
                        interaction = PlannerBlockInteraction(taskId: task.id, kind: .resize,
                                                              translation: Double(value.translation.height))
                    }
                    .onEnded { value in
                        let minutes = geometry.resizedDuration(
                            startMinute: item.startMinute,
                            durationMinutes: PlannerScheduling.durationMinutes(of: task),
                            deltaY: Double(value.translation.height))
                        interaction = nil
                        viewModel.resize(taskId: task.id, toMinutes: minutes)
                    }
            )
            .accessibilityHidden(true)
    }

    private func moveGesture(task: TodoTask, item: PlannerGridItem) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: CoordinateSpace.named(Self.gridSpace))
            .onChanged { value in
                interaction = PlannerBlockInteraction(taskId: task.id, kind: .move,
                                                      translation: Double(value.translation.height))
            }
            .onEnded { value in
                let start = geometry.movedStart(startMinute: item.startMinute,
                                                durationMinutes: PlannerScheduling.durationMinutes(of: task),
                                                deltaY: Double(value.translation.height))
                interaction = nil
                viewModel.move(taskId: task.id, toStartMinute: start, snapMinutes: geometry.snapMinutes)
            }
    }

    @ViewBuilder
    private func blockMenu(task: TodoTask, item: PlannerGridItem) -> some View {
        Button { onOpen(task) } label: { Label("Edit…", systemImage: "pencil") }
        Button { viewModel.toggleCompleted(task) } label: { Label("Complete", systemImage: "checkmark.circle") }
        Divider()
        Button("Move 15 Minutes Earlier") { nudge(task: task, item: item, by: -geometry.snapMinutes) }
        Button("Move 15 Minutes Later") { nudge(task: task, item: item, by: geometry.snapMinutes) }
        Button("Make Longer") { stretch(task: task, by: geometry.snapMinutes, item: item) }
        Button("Make Shorter") { stretch(task: task, by: -geometry.snapMinutes, item: item) }
        Divider()
        Button { viewModel.unschedule(taskId: task.id) } label: { Label("Remove Time", systemImage: "clock.badge.xmark") }
    }

    private func nudge(task: TodoTask, item: PlannerGridItem, by minutes: Int) {
        let start = geometry.clampStart(item.startMinute + minutes,
                                        durationMinutes: PlannerScheduling.durationMinutes(of: task))
        viewModel.move(taskId: task.id, toStartMinute: start, snapMinutes: geometry.snapMinutes)
    }

    private func stretch(task: TodoTask, by minutes: Int, item: PlannerGridItem) {
        let deltaY = geometry.y(forMinute: Double(minutes))
        let duration = geometry.resizedDuration(startMinute: item.startMinute,
                                                durationMinutes: PlannerScheduling.durationMinutes(of: task),
                                                deltaY: deltaY)
        viewModel.resize(taskId: task.id, toMinutes: duration)
    }

    private func timeRange(_ start: Date, _ end: Date) -> String {
        "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}

// MARK: - Support

/// A block being dragged (moved) or resized, with the live vertical
/// translation in points.
struct PlannerBlockInteraction: Equatable {
    enum Kind: Equatable {
        case move
        case resize
    }

    let taskId: String
    let kind: Kind
    var translation: Double
}

extension PlannerGridItem {
    /// The task id for a task block, nil for an event.
    var taskId: String? {
        if case .task(let task) = kind { return task.id }
        return nil
    }
}

/// The resize-edge cursor. Push/pop are balanced through `isPushed` so a
/// hover that ends mid-drag can't leave the cursor stuck.
@MainActor
enum PlannerCursor {
    private static var isPushed = false

    static func setResizing(_ resizing: Bool) {
        if resizing, !isPushed {
            NSCursor.resizeUpDown.push()
            isPushed = true
        } else if !resizing, isPushed {
            NSCursor.pop()
            isPushed = false
        }
    }
}
