// Scribe/UI/Notes/DailyNoteView.swift
import Combine
import SwiftUI

/// Daily-note destination. Renders a 7-day strip at the top for adjacent-day
/// navigation; a popover mini-calendar covers jumps farther afield. The full
/// note editor fills the rest of the pane — no permanent calendar sidebar.
struct DailyNoteView: View {
    enum DailyState {
        case existing(Note)
        case draft(Date)
    }

    /// Compact per-day load surfaced inside the expanded month grid. Encoded
    /// in a small struct (count + dominant priority) so the cell can render a
    /// priority-tinted count badge without holding full ``TodoTask`` objects.
    struct DaySummary: Equatable {
        let taskCount: Int
        let highestPriority: TodoTask.Priority?
    }

    @State private var state: DailyState
    @Binding private var selectedDate: Date
    @State private var datesWithNotes: Set<String> = []
    @State private var taskSummariesByDay: [String: DaySummary] = [:]
    @State private var noteChangeCancellable: AnyCancellable?
    @State private var taskChangeCancellable: AnyCancellable?

    var onNavigate: (String) -> Void

    init(selectedDate: Binding<Date>, onNavigate: @escaping (String) -> Void) {
        self.onNavigate = onNavigate
        self._selectedDate = selectedDate
        let day = Calendar.current.startOfDay(for: selectedDate.wrappedValue)
        if let note = try? NoteStore.shared.fetchExistingDailyNote(for: day) {
            _state = State(initialValue: .existing(note))
        } else {
            _state = State(initialValue: .draft(day))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DailyNoteHeader(
                selectedDate: $selectedDate,
                datesWithNotes: datesWithNotes,
                taskSummariesByDay: taskSummariesByDay,
                onShift: { delta in
                    let cal = Calendar.current
                    if let new = cal.date(byAdding: .day, value: delta, to: selectedDate) {
                        selectDate(new)
                    }
                }
            )

            Divider()

            Group {
                switch state {
                case .existing(let note):
                    NoteDetailView(note: note, onNavigate: onNavigate)
                        .id(note.id)

                case .draft(let date):
                    DraftDailyNoteView(date: date, onCreated: { note in
                        withAnimation(.easeInOut(duration: DesignTokens.Motion.fast)) {
                            state = .existing(note)
                        }
                    }, onNavigate: onNavigate)
                    .id(date)
                }
            }
        }
        .onChange(of: selectedDate) { _, newValue in
            selectDate(newValue)
        }
        .onAppear {
            datesWithNotes = Set((try? NoteStore.shared.fetchDailyDates()) ?? [])
            noteChangeCancellable = NoteStore.shared.observeNotes()
                .sink(receiveCompletion: { _ in },
                      receiveValue: { _ in
                          datesWithNotes = Set((try? NoteStore.shared.fetchDailyDates()) ?? [])
                      })
            taskChangeCancellable = TaskStore.shared.observeTasks(filter: .all)
                .sink(receiveCompletion: { _ in },
                      receiveValue: { tasks in
                          taskSummariesByDay = Self.buildSummaries(tasks: tasks)
                      })
        }
    }

    /// Buckets incomplete dated tasks by `yyyy-MM-dd` key and reduces each
    /// bucket to a `DaySummary`. Priority ranking: high > medium > low > none.
    /// The dominant priority drives the cell badge tint.
    private static func buildSummaries(tasks: [TodoTask]) -> [String: DaySummary] {
        var grouped: [String: [TodoTask]] = [:]
        for task in tasks where task.dueAt != nil {
            let key = dayKey(for: task.dueAt!)
            grouped[key, default: []].append(task)
        }
        return grouped.mapValues { tasksForDay in
            let priorityRank: (TodoTask.Priority?) -> Int = { p in
                switch p {
                case .high?:   return 3
                case .medium?: return 2
                case .low?:    return 1
                case nil:      return 0
                }
            }
            let highest = tasksForDay.map(\.priority).max { priorityRank($0) < priorityRank($1) } ?? nil
            return DaySummary(taskCount: tasksForDay.count, highestPriority: highest)
        }
    }

    private static func dayKey(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func selectDate(_ date: Date) {
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        selectedDate = day
        if let note = try? NoteStore.shared.fetchExistingDailyNote(for: day) {
            withAnimation(.easeInOut(duration: DesignTokens.Motion.fast)) {
                state = .existing(note)
            }
        } else {
            withAnimation(.easeInOut(duration: DesignTokens.Motion.fast)) {
                state = .draft(day)
            }
        }
    }
}

/// Self-contained host for callers that don't need to observe the selected
/// date externally (e.g. the legacy `NotesFilter.today` / `.daily` routes in
/// the sidebar). Owns its own state; defaults to today.
struct StandaloneDailyNoteView: View {
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    var onNavigate: (String) -> Void

    var body: some View {
        DailyNoteView(selectedDate: $selectedDate, onNavigate: onNavigate)
    }
}

// MARK: - Header

/// Title + adaptive calendar surface + calendar trigger. The bottom region
/// flips between two layouts driven by ``isCalendarExpanded`` (persisted via
/// `@AppStorage`):
///   • **Collapsed** — a horizontal 7-day strip showing the days adjacent to
///     `selectedDate`. Compact, glanceable.
///   • **Expanded** — a multi-row month grid centred on `displayedMonth`,
///     with prev/next month navigation. Full-visibility view without
///     leaving Today.
/// The calendar icon in the header toggles between modes; tinted accent
/// when expanded so the active state is unambiguous.
private struct DailyNoteHeader: View {
    @Binding var selectedDate: Date
    let datesWithNotes: Set<String>
    let taskSummariesByDay: [String: DailyNoteView.DaySummary]
    let onShift: (Int) -> Void

    @AppStorage("scribe.today.calendarExpanded") private var isCalendarExpanded: Bool = false
    @State private var displayedMonth: Date

    private let calendar = Calendar.current

    init(selectedDate: Binding<Date>,
         datesWithNotes: Set<String>,
         taskSummariesByDay: [String: DailyNoteView.DaySummary],
         onShift: @escaping (Int) -> Void) {
        self._selectedDate = selectedDate
        self.datesWithNotes = datesWithNotes
        self.taskSummariesByDay = taskSummariesByDay
        self.onShift = onShift
        _displayedMonth = State(initialValue: Calendar.current.startOfMonth(for: selectedDate.wrappedValue))
    }

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f
    }()

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(titleText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Button { onShift(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Previous day")

                Button { onShift(1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Next day")

                Button { selectedDate = calendar.startOfDay(for: Date()) } label: {
                    Text("Today")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .help("Jump to today")

                Button {
                    withAnimation(.easeInOut(duration: DesignTokens.Motion.standard)) {
                        isCalendarExpanded.toggle()
                        // Reset the month view to the selected date's month
                        // each time the user expands — otherwise scrolling
                        // months back, collapsing, then re-expanding leaves
                        // the user disoriented far from their selection.
                        if isCalendarExpanded {
                            displayedMonth = calendar.startOfMonth(for: selectedDate)
                        }
                    }
                } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isCalendarExpanded ? Color.accentColor : .secondary)
                .help(isCalendarExpanded ? "Hide calendar" : "Show calendar")
                .accessibilityLabel(isCalendarExpanded ? "Hide month calendar" : "Show month calendar")
                .accessibilityAddTraits(isCalendarExpanded ? .isSelected : [])
            }

            if isCalendarExpanded {
                monthGrid
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                weekStrip
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.top, DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.xs)
        .onChange(of: selectedDate) { _, newDate in
            // Keep the visible month aligned with the selection so navigating
            // via prev/next chevrons or the date strip doesn't strand the
            // expanded grid on a different month.
            let target = calendar.startOfMonth(for: newDate)
            if target != displayedMonth {
                withAnimation(.easeInOut(duration: DesignTokens.Motion.fast)) {
                    displayedMonth = target
                }
            }
        }
    }

    // MARK: - Collapsed week strip

    private var weekStrip: some View {
        HStack(spacing: 2) {
            ForEach(adjacentDays(), id: \.timeIntervalSince1970) { date in
                DayPill(
                    date: date,
                    isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
                    isToday: calendar.isDateInToday(date),
                    hasNote: datesWithNotes.contains(Self.keyFormatter.string(from: date)),
                    onTap: { selectedDate = calendar.startOfDay(for: date) }
                )
            }
        }
    }

    // MARK: - Expanded month grid

    private var monthGrid: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(displayedMonth, format: .dateTime.month(.wide).year())
                    .font(DesignTokens.Typography.eyebrow)
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Previous month")
                .accessibilityLabel("Previous month")

                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Next month")
                .accessibilityLabel("Next month")
            }
            .padding(.top, 2)

            HStack(spacing: 2) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7),
                spacing: 2
            ) {
                ForEach(monthCells.indices, id: \.self) { idx in
                    if let date = monthCells[idx] {
                        let key = Self.keyFormatter.string(from: date)
                        MonthDayCell(
                            date: date,
                            isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
                            isToday: calendar.isDateInToday(date),
                            hasNote: datesWithNotes.contains(key),
                            summary: taskSummariesByDay[key],
                            onTap: { selectedDate = calendar.startOfDay(for: date) }
                        )
                    } else {
                        Color.clear.frame(height: 42)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Month calendar")
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: displayedMonth) else { return }
        withAnimation(.easeInOut(duration: DesignTokens.Motion.fast)) {
            displayedMonth = calendar.startOfMonth(for: next)
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var monthCells: [Date?] {
        CalendarMonthGrid.cells(forMonth: displayedMonth, calendar: calendar, padTrailing: false)
    }

    private var titleText: String {
        if calendar.isDateInToday(selectedDate) {
            return "Today · \(Self.titleFormatter.string(from: selectedDate))"
        }
        if calendar.isDateInYesterday(selectedDate) {
            return "Yesterday · \(Self.titleFormatter.string(from: selectedDate))"
        }
        if calendar.isDateInTomorrow(selectedDate) {
            return "Tomorrow · \(Self.titleFormatter.string(from: selectedDate))"
        }
        return Self.titleFormatter.string(from: selectedDate)
    }

    private func adjacentDays() -> [Date] {
        let day = calendar.startOfDay(for: selectedDate)
        return (-3...3).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: day)
        }
    }
}

private struct DayPill: View {
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let hasNote: Bool
    let onTap: () -> Void

    private let calendar = Calendar.current

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                Text(Self.weekdayFormatter.string(from: date).uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(weekdayTint)
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(numberTint)
                if hasNote && !isSelected {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 3)
                        .padding(.top, 1)
                } else if isSelected {
                    Circle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 3, height: 3)
                        .padding(.top, 1)
                } else {
                    Color.clear.frame(width: 3, height: 4)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous)
                    .strokeBorder(borderTint, lineWidth: isToday && !isSelected ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var background: some View {
        if isSelected {
            Color.accentColor
        } else {
            Color.clear
        }
    }

    private var weekdayTint: Color {
        isSelected ? .white.opacity(0.85) : Color.secondary.opacity(0.6)
    }

    private var numberTint: Color {
        if isSelected { return .white }
        if isToday { return Color.accentColor }
        return .primary
    }

    private var borderTint: Color {
        Color.accentColor.opacity(0.4)
    }
}

/// Compact day cell used inside the expanded month grid. Echoes the load
/// signals from ``TaskCalendarView`` — priority-tinted task count badge plus
/// a note indicator — at inline scale. Selection follows ``DayPill``'s accent
/// fill so the two surfaces feel like one design language.
///
/// Layout: day number on top, a single info row underneath holding the note
/// dot (if any) and the task-count capsule (if any). When neither exists the
/// info row collapses to a fixed spacer height so cell heights stay aligned
/// across the grid.
private struct MonthDayCell: View {
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let hasNote: Bool
    let summary: DailyNoteView.DaySummary?
    let onTap: () -> Void

    @State private var isHovered = false
    private let calendar = Calendar.current

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 12, weight: isSelected || isToday ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(numberTint)

                infoRow
                    .frame(height: 12)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous)
                    .strokeBorder(borderTint, lineWidth: isToday && !isSelected ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovered)
        .help(tooltip)
        .accessibilityLabel(Self.a11yFormatter.string(from: date))
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Info row

    @ViewBuilder
    private var infoRow: some View {
        HStack(spacing: 3) {
            if hasNote {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(noteTint)
                    .accessibilityHidden(true)
            }
            if let summary, summary.taskCount > 0 {
                Text("\(summary.taskCount)")
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(badgeTextTint(for: summary))
                    .padding(.horizontal, 4)
                    .frame(minWidth: 14, minHeight: 12)
                    .background(
                        Capsule().fill(badgeFill(for: summary))
                    )
            }
        }
    }

    private static let a11yFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        return f
    }()

    private var tooltip: String {
        var parts: [String] = [Self.a11yFormatter.string(from: date)]
        if let summary, summary.taskCount > 0 {
            parts.append("\(summary.taskCount) task\(summary.taskCount == 1 ? "" : "s")")
        }
        if hasNote { parts.append("daily note") }
        return parts.joined(separator: " · ")
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if isToday { parts.append("Today") }
        if let summary, summary.taskCount > 0 {
            parts.append("\(summary.taskCount) task\(summary.taskCount == 1 ? "" : "s")")
        }
        if hasNote { parts.append("has note") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Tints

    @ViewBuilder
    private var background: some View {
        if isSelected {
            Color.accentColor
        } else if isHovered {
            Color.primary.opacity(0.07)
        } else {
            Color.clear
        }
    }

    private var numberTint: Color {
        if isSelected { return .white }
        if isToday { return Color.accentColor }
        return .primary
    }

    private var noteTint: Color {
        isSelected ? Color.white.opacity(0.9) : Color.accentColor.opacity(0.75)
    }

    private var borderTint: Color {
        Color.accentColor.opacity(0.4)
    }

    private func priorityColor(_ priority: TodoTask.Priority?) -> Color {
        switch priority {
        case .high:   return DesignTokens.Palette.priorityHigh
        case .medium: return DesignTokens.Palette.priorityMedium
        case .low:    return DesignTokens.Palette.priorityLow
        case .none:   return Color.accentColor
        }
    }

    private func badgeFill(for summary: DailyNoteView.DaySummary) -> Color {
        if isSelected {
            return Color.white.opacity(0.9)
        }
        return priorityColor(summary.highestPriority)
    }

    private func badgeTextTint(for summary: DailyNoteView.DaySummary) -> Color {
        if isSelected {
            return priorityColor(summary.highestPriority)
        }
        return .white
    }
}

// MARK: - Draft daily note editor

/// Shown when a date has no note yet. Displays the auto-generated title and
/// an empty body editor. On first non-empty keystroke the note is persisted
/// and the parent transitions to the full NoteDetailView.
private struct DraftDailyNoteView: View {
    let date: Date
    let onCreated: (Note) -> Void
    let onNavigate: (String) -> Void

    @State private var bodyText: String = ""
    @State private var hasCreated: Bool = false

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    private var noteTitle: String {
        "Daily Note \u{2013} \(Self.titleFormatter.string(from: date))"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(noteTitle)
                    .font(DesignTokens.Typography.title2)
                    .foregroundStyle(.primary)

                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "pencil")
                        .imageScale(.small)
                    Text("Start writing to save this note")
                }
                .font(DesignTokens.Typography.eyebrow)
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            }
            .padding(.horizontal, DesignTokens.Spacing.xxxl)
            .padding(.top, DesignTokens.Spacing.lg)
            .padding(.bottom, DesignTokens.Spacing.md)

            Divider()

            NoteEditorView(
                text: $bodyText,
                noteStore: .shared,
                onNavigate: onNavigate
            )
            .padding(.vertical, DesignTokens.Spacing.md)
        }
        .onChange(of: bodyText) { _, newValue in
            guard !hasCreated else { return }
            guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do {
                var note = try NoteStore.shared.dailyNote(for: date)
                note.body = newValue
                try NoteStore.shared.updateNote(note, tags: [])
                hasCreated = true
                onCreated(note)
            } catch {
                Log.app.error("DraftDailyNoteView: failed to persist note: \(error)")
            }
        }
    }
}
