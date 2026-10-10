import Combine
import SwiftUI
import UIKit

/// Day planner: a 24-hour time grid with the day's calendar events and
/// scheduled tasks laid out side by side (the Mac's `PlannerGrid` /
/// `TimeGridLayout`), an all-day strip, and a tray of unscheduled tasks.
/// Long-press a task block and drag to move it; drag its handle to resize;
/// drag a tray task onto the grid (or tap it) to give it a time.
struct TasksDayPlannerScreen: View {
    @ObservedObject var library: TasksLibraryModel
    /// iPad: open in the detail column. Nil (iPhone): push.
    var onOpenTask: ((String) -> Void)?

    @ObservedObject private var calendarEvents = TasksCalendarEventsModel.shared
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var events: [CalendarEventInfo] = []
    @State private var moving: (id: String, deltaY: CGFloat)?
    @State private var resizing: (id: String, deltaY: CGFloat)?
    @State private var scheduling: TodoTask?
    @State private var now = Date()

    private let geometry = TimeGridGeometry(hourHeight: 60, snapMinutes: 15)
    private let gutter: CGFloat = 52
    private var actions: TaskMobileActions { .live }
    private var calendar: Calendar { .current }

    private var tasks: [TodoTask] { library.openTasks }

    private var gridItems: [PlannerGridItem] {
        let hidden = PlannerMirroredEventFilter.hiddenEventIds(events: events, tasks: tasks, calendar: calendar)
        return PlannerGrid.items(events: events, hiddenEventIds: hidden, tasks: tasks, day: day, calendar: calendar)
    }

    private var sideList: PlannerSideList {
        PlannerScheduling.sideList(tasks, for: day, calendar: calendar, now: now)
    }

    var body: some View {
        VStack(spacing: 0) {
            dayHeader
            Divider()
            if !calendarEvents.isActive {
                TasksCalendarPromptRow(calendar: calendarEvents)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
            allDayStrip
            tray
            Divider()
            grid
        }
        .navigationTitle("Planner")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            library.start()
            calendarEvents.refreshAccess()
            reloadEvents()
        }
        .onChange(of: day) { reloadEvents() }
        .onChange(of: calendarEvents.revision) { reloadEvents() }
        .onChange(of: calendarEvents.isGranted) { reloadEvents() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
        .sheet(item: $scheduling) { task in
            TasksScheduleSheet(task: task, day: day) { start in
                actions.update(PlannerScheduling.scheduling(task, at: start, calendar: calendar))
            }
        }
    }

    // MARK: - Header

    private var dayHeader: some View {
        HStack {
            Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous day")
            Spacer()
            VStack(spacing: 0) {
                Text(day.formatted(.dateTime.weekday(.wide)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(day.formatted(.dateTime.month(.wide).day()))
                    .font(.headline)
            }
            Spacer()
            if !calendar.isDateInToday(day) {
                Button("Today") { day = calendar.startOfDay(for: Date()) }
            }
            Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next day")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func shiftDay(_ delta: Int) {
        day = calendar.date(byAdding: .day, value: delta, to: day) ?? day
    }

    @ViewBuilder
    private var allDayStrip: some View {
        let allDay = PlannerGrid.allDayEvents(events, day: day, calendar: calendar)
        if !allDay.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(allDay, id: \.self) { event in
                        Text(event.displayTitle)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private var tray: some View {
        let side = sideList
        let items = side.forDay + side.undated.prefix(20)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(side.forDay.isEmpty ? "Unscheduled" : "To schedule")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(items) { task in
                            Button { scheduling = task } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: side.forDay.contains(task) ? "star" : "circle")
                                        .font(.caption2)
                                    Text(task.title.isEmpty ? "Untitled" : task.title).lineLimit(1)
                                    Text(TaskQuickAddPlanner.durationLabel(PlannerScheduling.durationMinutes(of: task)))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
                            }
                            .buttonStyle(.plain)
                            .draggable(TaskDragToken.encode(task.id))
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: - Grid

    private var grid: some View {
        GeometryReader { proxy in
            let columnWidth = max(40, proxy.size.width - gutter - 8)
            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    ZStack(alignment: .topLeading) {
                        hourLines(width: proxy.size.width)
                        if calendar.isDate(now, inSameDayAs: day) {
                            nowLine(width: proxy.size.width)
                        }
                        ForEach(gridItems) { item in
                            block(item, columnWidth: columnWidth)
                        }
                    }
                    .frame(width: proxy.size.width, height: CGFloat(geometry.totalHeight), alignment: .topLeading)
                    .contentShape(Rectangle())
                    .dropDestination(for: String.self) { tokens, location in
                        dropOnGrid(tokens, at: location)
                    }
                }
                .onAppear {
                    let hour = calendar.component(.hour, from: Date())
                    reader.scrollTo("hour-\(max(0, hour - 1))", anchor: .top)
                }
            }
        }
    }

    private func hourLines(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 4) {
                    Text(hourLabel(hour))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: gutter - 8, alignment: .trailing)
                        .offset(y: -6)
                    VStack { Divider() }
                }
                .frame(width: width, height: CGFloat(geometry.hourHeight), alignment: .topLeading)
                .id("hour-\(hour)")
            }
        }
    }

    private func nowLine(width: CGFloat) -> some View {
        let minute = TimeGridGeometry.minuteOfDay(for: now, on: day, calendar: calendar)
        return HStack(spacing: 0) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Rectangle().fill(Color.red).frame(height: 1.5)
        }
        .frame(width: width - gutter + 4)
        .offset(x: gutter - 4, y: CGFloat(geometry.y(forMinute: Double(minute))) - 4)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func block(_ item: PlannerGridItem, columnWidth: CGFloat) -> some View {
        let x = gutter + CGFloat(item.placement.leadingFraction) * columnWidth
        let width = max(24, CGFloat(item.placement.widthFraction) * columnWidth - 3)
        let baseY = CGFloat(geometry.y(forMinute: Double(item.startMinute)))
        let baseHeight = max(22, CGFloat(geometry.y(forMinute: Double(item.durationMinutes))) - 2)
        switch item.kind {
        case .event(let event):
            eventBlock(event)
                .frame(width: width, height: baseHeight, alignment: .topLeading)
                .offset(x: x, y: baseY)
        case .task(let task):
            let dy = moving?.id == task.id ? (moving?.deltaY ?? 0) : 0
            let dh = resizing?.id == task.id ? (resizing?.deltaY ?? 0) : 0
            taskBlock(task, item: item)
                .frame(width: width, height: max(22, baseHeight + dh), alignment: .topLeading)
                .offset(x: x, y: baseY + dy)
                .zIndex(moving?.id == task.id || resizing?.id == task.id ? 1 : 0)
        }
    }

    private func eventBlock(_ event: CalendarEventInfo) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(event.displayTitle).font(.caption.weight(.semibold)).lineLimit(2)
            Text(event.start.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.16)))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.purple).frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            if let url = event.meetingURL {
                Link(destination: url) { Label("Join Meeting", systemImage: "video") }
            }
        }
    }

    private func taskBlock(_ task: TodoTask, item: PlannerGridItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Button { actions.toggleCompleted(task) } label: {
                    Image(systemName: "circle").font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Complete")
                Text(task.title.isEmpty ? "Untitled task" : task.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 0)
                Menu {
                    Button { openTask(task.id) } label: { Label("Open", systemImage: "arrow.up.forward.square") }
                    Button { actions.toggleCompleted(task) } label: { Label("Complete", systemImage: "checkmark.circle") }
                    Button { scheduling = task } label: { Label("Change Time…", systemImage: "clock") }
                    Button { actions.update(PlannerScheduling.unscheduling(task, calendar: calendar)) } label: {
                        Label("Remove Time", systemImage: "calendar.badge.minus")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption)
                        .frame(width: 22, height: 18)
                }
                .accessibilityLabel("Task options")
            }
            Text(timeRange(item))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.22)))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.accentColor).frame(width: 3)
        }
        .overlay(alignment: .bottom) { resizeHandle(task, item: item) }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { openTask(task.id) }
        // Long-press then drag moves the block (no context menu here: it
        // would compete for the same long press; the ⋯ menu has the actions).
        .gesture(moveGesture(task, item: item))
    }

    private func resizeHandle(_ task: TodoTask, item: PlannerGridItem) -> some View {
        Capsule()
            .fill(Color.accentColor.opacity(0.6))
            .frame(width: 28, height: 5)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, minHeight: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in resizing = (task.id, value.translation.height) }
                    .onEnded { value in
                        let minutes = geometry.resizedDuration(startMinute: item.startMinute,
                                                               durationMinutes: item.durationMinutes,
                                                               deltaY: Double(value.translation.height))
                        resizing = nil
                        actions.update(PlannerScheduling.resizing(task, toMinutes: minutes))
                    }
            )
            .accessibilityLabel("Resize")
    }

    private func moveGesture(_ task: TodoTask, item: PlannerGridItem) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case .second(true, let drag?) = value {
                    moving = (task.id, drag.translation.height)
                }
            }
            .onEnded { value in
                defer { moving = nil }
                guard case .second(true, let drag?) = value else { return }
                let start = geometry.movedStart(startMinute: item.startMinute,
                                                durationMinutes: item.durationMinutes,
                                                deltaY: Double(drag.translation.height))
                commitStart(task, minute: start)
            }
    }

    // MARK: - Writes

    private func dropOnGrid(_ tokens: [String], at location: CGPoint) -> Bool {
        guard let id = tokens.compactMap(TaskDragToken.decode).first,
              let task = try? TaskStore.shared.fetchTask(id: id) else { return false }
        let duration = PlannerScheduling.durationMinutes(of: task)
        let minute = geometry.startMinute(forY: Double(location.y), durationMinutes: duration)
        commitStart(task, minute: minute)
        return true
    }

    private func commitStart(_ task: TodoTask, minute: Int) {
        let representable = PlannerScheduling.representableStartMinute(minute, snapMinutes: geometry.snapMinutes)
        let start = TimeGridGeometry.date(atMinute: representable, on: day, calendar: calendar)
        actions.update(PlannerScheduling.scheduling(task, at: start, calendar: calendar))
    }

    private func reloadEvents() {
        events = calendarEvents.events(on: day)
    }

    private func openTask(_ id: String) {
        if let onOpenTask {
            onOpenTask(id)
        } else {
            TasksOpenRequest.shared.open(id)
        }
    }

    // MARK: - Formatting

    private func hourLabel(_ hour: Int) -> String {
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        return date.formatted(.dateTime.hour())
    }

    private func timeRange(_ item: PlannerGridItem) -> String {
        let start = TimeGridGeometry.date(atMinute: item.startMinute, on: day, calendar: calendar)
        let end = TimeGridGeometry.date(atMinute: item.endMinute, on: day, calendar: calendar)
        return "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}

/// Picks a start time (and length) for a task on the planner's day.
struct TasksScheduleSheet: View {
    let task: TodoTask
    let day: Date
    let onSchedule: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var start: Date

    init(task: TodoTask, day: Date, onSchedule: @escaping (Date) -> Void) {
        self.task = task
        self.day = day
        self.onSchedule = onSchedule
        let cal = Calendar.current
        let base: Date
        if let due = task.dueAt, PlannerTimeOfDay.hasTime(due, calendar: cal) {
            base = cal.date(bySettingHour: cal.component(.hour, from: due), minute: cal.component(.minute, from: due),
                            second: 0, of: day) ?? due
        } else {
            let nextHour = (cal.component(.hour, from: Date()) + 1) % 24
            base = cal.date(bySettingHour: max(nextHour, 1), minute: 0, second: 0, of: day) ?? day
        }
        _start = State(initialValue: base)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(task.title.isEmpty ? "Untitled task" : task.title).font(.headline)
                    DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
                    LabeledContent("Length", value: TaskQuickAddPlanner.durationLabel(PlannerScheduling.durationMinutes(of: task)))
                }
            }
            .navigationTitle("Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") {
                        onSchedule(start)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
