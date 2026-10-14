// Scribe/UI/Today/TodayAgendaView.swift
import Combine
import SwiftUI

/// What the Today agenda shows for one day: tasks due that day, plus (on the
/// current day only) a count of older overdue work and its oldest due date.
struct TodayAgendaSummary: Equatable {
    var due: [TodoTask]
    var overdueCount: Int
    var oldestOverdue: Date?

    static let empty = TodayAgendaSummary(due: [], overdueCount: 0, oldestOverdue: nil)

    /// `tasks` is the day's `DayPlanningModel.taskFilter` result; for the
    /// current day that filter also carries the overdue tasks, split out here.
    static func make(tasks: [TodoTask], day: Date, now: Date, calendar: Calendar) -> TodayAgendaSummary {
        guard calendar.isDate(day, inSameDayAs: now) else {
            return TodayAgendaSummary(due: tasks, overdueCount: 0, oldestOverdue: nil)
        }
        let startOfToday = calendar.startOfDay(for: now)
        var due: [TodoTask] = []
        var overdueCount = 0
        var oldest: Date?
        for task in tasks {
            if let dueAt = task.dueAt, dueAt < startOfToday {
                overdueCount += 1
                oldest = min(oldest ?? dueAt, dueAt)
            } else {
                due.append(task)
            }
        }
        return TodayAgendaSummary(due: due, overdueCount: overdueCount, oldestOverdue: oldest)
    }
}

@MainActor
@Observable
final class TodayAgendaModel {
    private(set) var summary = TodayAgendaSummary.empty
    private(set) var hasLoaded = false
    private(set) var completing: Set<String> = []

    @ObservationIgnored private var cancellable: AnyCancellable?
    @ObservationIgnored private var observedDay: Date?

    func observe(day: Date) {
        guard day != observedDay || cancellable == nil else { return }
        observedDay = day
        hasLoaded = false
        cancellable = TaskStore.shared.observeTasks(filter: DayPlanningModel.taskFilter(for: day))
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] tasks in
                    guard let self else { return }
                    summary = Perf.measure("TodayAgenda.summary") {
                        TodayAgendaSummary.make(tasks: tasks, day: day, now: Date(), calendar: .current)
                    }
                    hasLoaded = true
                }
            )
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
    }

    func complete(_ task: TodoTask) {
        guard !completing.contains(task.id) else { return }
        completing.insert(task.id)
        Task { @MainActor in
            // Let the checkmark register before the row leaves the list.
            try? await Task.sleep(for: .milliseconds(350))
            let store = TaskStore.shared
            do {
                try store.completeTask(id: task.id)
                if let refreshed = try store.fetchTask(id: task.id) {
                    if refreshed.isCompleted {
                        await TaskReminderScheduler.shared.cancel(taskId: task.id)
                    } else {
                        await TaskReminderScheduler.shared.schedule(refreshed)
                    }
                }
            } catch {
                Log.ui.error("TodayAgendaModel.complete failed: \(error.localizedDescription, privacy: .public)")
            }
            completing.remove(task.id)
        }
    }

    /// Quick-add with the same parsing and defaults as the Today task list;
    /// an undated task added while viewing another day is due that day.
    func add(_ raw: String, day: Date) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let calendar = Calendar.current
        let now = Date()
        let store = TaskStore.shared
        let parsed = QuickAddParser.parse(text, now: now, calendar: calendar)
        let projects = parsed.projectName == nil ? [] : ((try? store.fetchProjects()) ?? [])
        guard var plan = TaskQuickAddPlanner.plan(
            parsed: parsed,
            destination: .today,
            projects: projects,
            calendar: calendar,
            now: now
        ) else { return }
        if parsed.dueAt == nil, plan.dueAt != nil, !calendar.isDate(day, inSameDayAs: now) {
            plan.dueAt = calendar.startOfDay(for: day)
        }
        do {
            try store.createTask(
                title: plan.title,
                notes: plan.notes,
                projectId: plan.projectId,
                priority: plan.priority,
                dueAt: plan.dueAt,
                recurrenceRule: plan.recurrenceRule,
                tags: plan.tags,
                startAt: plan.startAt,
                scheduleBucket: plan.scheduleBucket,
                estimatedMinutes: plan.estimatedMinutes,
                areaId: plan.areaId,
                headingId: plan.headingId
            )
        } catch {
            Log.ui.error("TodayAgendaModel.add failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Right-hand column of the Today page: next meeting, the day's tasks, and a
/// one-line overdue summary that hands off to the full task list.
struct TodayAgendaView: View {
    let selectedDate: Date

    @State private var model = TodayAgendaModel()
    @ObservedObject private var calendarService = CalendarService.shared
    @State private var isAdding = false
    @State private var draft = ""
    @FocusState private var addFieldFocused: Bool

    private var isToday: Bool { Calendar.current.isDateInToday(selectedDate) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Today.sectionSpacing) {
                if isToday, calendarService.isActive {
                    nextMeetingSection
                }
                dueSection
                if isToday, model.summary.overdueCount > 0 {
                    overdueSummary
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .padding(.top, DesignTokens.Today.topPadding + 12)
            .padding(.bottom, DesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onAppear { model.observe(day: selectedDate) }
        .onDisappear { model.stop() }
        .onChange(of: selectedDate) { _, day in
            isAdding = false
            draft = ""
            model.observe(day: day)
        }
    }

    // MARK: - Next meeting

    @ViewBuilder
    private var nextMeetingSection: some View {
        TimelineView(.everyMinute) { context in
            if let event = nextEvent(at: context.date) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    sectionHeader("Next meeting")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title.isEmpty ? String(localized: "Untitled event") : event.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DesignTokens.Palette.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(meetingSubtitle(event, now: context.date))
                            .font(.system(size: 12))
                            .foregroundStyle(DesignTokens.Palette.textSecondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func nextEvent(at now: Date) -> CalendarEventInfo? {
        calendarService.upcomingEvents.first { !$0.isAllDay && $0.end > now }
    }

    private func meetingSubtitle(_ event: CalendarEventInfo, now: Date) -> String {
        let time = Date.FormatStyle.dateTime.hour().minute()
        let range = "\(event.start.formatted(time)) – \(event.end.formatted(time))"
        if event.start <= now { return String(localized: "Now · \(range)") }
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        if minutes < 60 {
            return String(localized: "In \(max(1, minutes)) min · \(range)")
        }
        return range
    }

    // MARK: - Due

    private var dueSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                sectionHeader(dueTitle)
                Spacer(minLength: 0)
                Button {
                    isAdding = true
                    addFieldFocused = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.Palette.textTertiary)
                .help("Add a task")
                .accessibilityLabel("Add a task")
            }

            if isAdding {
                TextField("New task", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($addFieldFocused)
                    .padding(.vertical, 5)
                    .onSubmit {
                        model.add(draft, day: selectedDate)
                        draft = ""
                        addFieldFocused = true
                    }
                    .onExitCommand { endAdding() }
                    .onChange(of: addFieldFocused) { _, focused in
                        if !focused, draft.isEmpty { isAdding = false }
                    }
            }

            if model.summary.due.isEmpty {
                if model.hasLoaded && !isAdding {
                    Text("Nothing due \(dayPhrase)")
                        .font(.system(size: 13))
                        .foregroundStyle(DesignTokens.Palette.textTertiary)
                        .padding(.vertical, 5)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.summary.due) { task in
                        TodayAgendaTaskRow(
                            task: task,
                            isCompleting: model.completing.contains(task.id),
                            onComplete: { model.complete(task) }
                        )
                    }
                }
            }
        }
    }

    private func endAdding() {
        draft = ""
        isAdding = false
        addFieldFocused = false
    }

    private var dueTitle: String {
        isToday ? String(localized: "Due today") : String(localized: "Due \(dayPhrase)")
    }

    private var dayPhrase: String {
        let cal = Calendar.current
        if cal.isDateInToday(selectedDate) { return String(localized: "today") }
        if cal.isDateInTomorrow(selectedDate) { return String(localized: "tomorrow") }
        if cal.isDateInYesterday(selectedDate) { return String(localized: "yesterday") }
        return selectedDate.formatted(.dateTime.day().month(.abbreviated))
    }

    // MARK: - Overdue

    private var overdueSummary: some View {
        Button {
            NotificationCenter.default.post(name: .scribeNavigate, object: MainSelection.tasks(.upcoming))
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(overdueText)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: DesignTokens.Spacing.sm)
                Text("Review \u{2192}")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignTokens.Palette.accent)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Today.summaryRadius, style: .continuous)
                    .fill(DesignTokens.Palette.quietFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Review overdue tasks")
        .accessibilityLabel(Text(overdueText))
        .accessibilityHint("Opens the overdue tasks")
    }

    private var overdueText: String {
        let count = model.summary.overdueCount
        guard let oldest = model.summary.oldestOverdue else {
            return String(localized: "\(count) overdue")
        }
        let sameYear = Calendar.current.isDate(oldest, equalTo: Date(), toGranularity: .year)
        let style: Date.FormatStyle = sameYear
            ? .dateTime.day().month(.abbreviated)
            : .dateTime.day().month(.abbreviated).year()
        return String(localized: "\(count) overdue · since \(oldest.formatted(style))")
    }

    // MARK: - Pieces

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(DesignTokens.Today.sectionHeader)
            .foregroundStyle(DesignTokens.Palette.textTertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct TodayAgendaTaskRow: View {
    let task: TodoTask
    let isCompleting: Bool
    let onComplete: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button(action: onComplete) {
                Image(systemName: isCompleting ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(isCompleting ? DesignTokens.Palette.accent : DesignTokens.Palette.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCompleting ? "Completed" : "Mark complete")

            Text(task.title)
                .font(.system(size: 13))
                .foregroundStyle(isCompleting ? DesignTokens.Palette.textTertiary : DesignTokens.Palette.textPrimary)
                .strikethrough(isCompleting, color: DesignTokens.Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .animation(.easeOut(duration: DesignTokens.Motion.fast), value: isCompleting)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCompleting ? .isSelected : [])
    }
}
