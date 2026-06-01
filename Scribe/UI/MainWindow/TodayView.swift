// Scribe/UI/MainWindow/TodayView.swift
import Combine
import SwiftUI

/// Unified "Today" destination: the selected day's daily note on the left,
/// the same day's tasks on the right rail. Replaces the separate "Today's
/// Note" and Tasks-"Today" sidebar entries — both used to be one click away
/// from the same date but on different surfaces, requiring two visits when
/// the user just wanted to plan the day.
///
/// Layout direction: an *asymmetric* horizontal split (note ~60%, tasks rail
/// ~40%) rather than a 50/50 vertical split. The note is the primary canvas
/// you write into; the tasks rail is a glanceable companion. Both panes
/// remain user-resizable.
///
/// The selected date is owned here and shared with both panes — when the
/// user navigates days via the date strip in the note header, the rail
/// re-filters tasks to that day automatically.
struct TodayView: View {
    var onNavigate: (String) -> Void

    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())

    var body: some View {
        HSplitView {
            DailyNoteView(selectedDate: $selectedDate, onNavigate: onNavigate)
                .frame(minWidth: 380, idealWidth: 600)
                .layoutPriority(2)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(noteAccessibilityLabel)

            TodayTasksRail(selectedDate: selectedDate)
                .frame(minWidth: 280, idealWidth: 360, maxWidth: 520)
                .layoutPriority(1)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(tasksAccessibilityLabel)
        }
    }

    private var noteAccessibilityLabel: String {
        Calendar.current.isDateInToday(selectedDate)
            ? "Today's daily note"
            : "Daily note for \(Self.longFormatter.string(from: selectedDate))"
    }

    private var tasksAccessibilityLabel: String {
        Calendar.current.isDateInToday(selectedDate)
            ? "Today's tasks"
            : "Tasks for \(Self.longFormatter.string(from: selectedDate))"
    }

    private static let longFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        return f
    }()
}

// MARK: - Tasks rail

/// Right-hand rail that hosts the selected day's tasks. Wraps
/// ``TaskListView`` with an editorial header so the rail reads as a focused,
/// glanceable companion to the note pane — not a second 50/50 surface
/// competing for visual weight. Re-filters reactively as the parent's
/// selected date changes.
private struct TodayTasksRail: View {
    let selectedDate: Date

    @StateObject private var progress = TodayProgressViewModel()

    /// `.today` keeps overdue tasks visible alongside today's; non-today
    /// dates use the strict same-day `.dueOn` window.
    private var filter: TaskStore.Filter {
        Calendar.current.isDateInToday(selectedDate)
            ? .today
            : .dueOn(Calendar.current.startOfDay(for: selectedDate))
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            TaskListView(filter: filter)
                .id(filter)
        }
        .onAppear { progress.start(filter: filter) }
        .onDisappear { progress.stop() }
        .onChange(of: filter) { _, newFilter in
            progress.start(filter: newFilter)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text(eyebrow)
                .font(DesignTokens.Typography.eyebrow)
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            Text(progress.summary)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeOut(duration: DesignTokens.Motion.fast),
                           value: progress.incompleteCount)
                .accessibilityLabel(progress.accessibilitySummary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.top, DesignTokens.Spacing.md)
        .padding(.bottom, DesignTokens.Spacing.sm)
    }

    private var eyebrow: String {
        let cal = Calendar.current
        if cal.isDateInToday(selectedDate)     { return "TODAY'S TASKS" }
        if cal.isDateInYesterday(selectedDate) { return "YESTERDAY'S TASKS" }
        if cal.isDateInTomorrow(selectedDate)  { return "TOMORROW'S TASKS" }
        return Self.shortFormatter.string(from: selectedDate).uppercased() + " · TASKS"
    }

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f
    }()
}

// MARK: - Lightweight progress observer

/// Minimal observer that exposes the count of incomplete tasks for the
/// currently-shown filter, plus an overdue split. Kept independent from
/// ``TaskListViewModel`` so the rail header can update without touching the
/// embedded list's internal state. Resubscribes when the filter changes
/// (e.g. when the user navigates to a different day).
@MainActor
private final class TodayProgressViewModel: ObservableObject {
    @Published private(set) var incompleteCount: Int = 0
    @Published private(set) var overdueCount: Int = 0
    @Published private(set) var filterIsToday: Bool = true

    private let store = TaskStore()
    private var cancellable: AnyCancellable?

    func start(filter: TaskStore.Filter) {
        cancellable?.cancel()
        filterIsToday = (filter == .today)
        let isToday = filterIsToday
        cancellable = store.observeTasks(filter: filter)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] tasks in
                    guard let self else { return }
                    let startOfToday = Calendar.current.startOfDay(for: Date())
                    let overdue = isToday
                        ? tasks.filter { ($0.dueAt ?? .distantFuture) < startOfToday }.count
                        : 0
                    self.incompleteCount = tasks.count
                    self.overdueCount = overdue
                }
            )
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
    }

    /// Compact visual summary, e.g. "3 to do · 1 overdue" or "All clear".
    var summary: String {
        if incompleteCount == 0 {
            return filterIsToday ? "All clear" : "Nothing scheduled"
        }
        let base = "\(incompleteCount) to do"
        return overdueCount > 0 ? "\(base) · \(overdueCount) overdue" : base
    }

    /// Verbose form for screen readers — full words, no glyphs.
    var accessibilitySummary: String {
        if incompleteCount == 0 {
            return filterIsToday ? "No tasks for today" : "No tasks scheduled"
        }
        let tasks = incompleteCount == 1 ? "1 task" : "\(incompleteCount) tasks"
        if overdueCount == 0 { return "\(tasks) to do" }
        let overdue = overdueCount == 1 ? "1 overdue" : "\(overdueCount) overdue"
        return "\(tasks) to do, \(overdue)"
    }
}
