// Scribe/UI/Notes/DailyNoteView.swift
import Combine
import SwiftUI

/// Daily-note destination: a date header with a day switcher (and a month
/// calendar popover) above the day's note, in a centred reading column.
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
    @State private var datesWithNotes = Self.lastDatesWithNotes
    @State private var taskSummariesByDay = Self.lastTaskSummaries
    @State private var noteChangeCancellable: AnyCancellable?
    @State private var taskChangeCancellable: AnyCancellable?

    var onNavigate: (String) -> Void

    init(selectedDate: Binding<Date>, onNavigate: @escaping (String) -> Void) {
        self.onNavigate = onNavigate
        self._selectedDate = selectedDate
        _state = State(initialValue: Self.lookUpState(for: selectedDate.wrappedValue))
    }

    // Seed the header on re-entry so its dots don't pop in after the first
    // observation delivers.
    @MainActor private static var lastDatesWithNotes: Set<String> = []
    @MainActor private static var lastTaskSummaries: [String: DaySummary] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            .padding(.horizontal, DesignTokens.Today.noteColumnGutter)
            .padding(.top, DesignTokens.Today.topPadding)
            .padding(.bottom, DesignTokens.Spacing.sm)

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
            .environment(\.noteDetailShowsDocumentHeader, false)
        }
        .frame(maxWidth: DesignTokens.Today.noteColumnMaxWidth + 2 * DesignTokens.Today.noteColumnGutter)
        .frame(maxWidth: .infinity)
        .onChange(of: selectedDate) { _, newValue in
            showDay(newValue)
        }
        .onAppear {
            noteChangeCancellable = NoteStore.shared.observeNotes()
                .map { notes in Set(notes.compactMap { $0.isDailyNote ? $0.dailyDate : nil }) }
                .sink(receiveCompletion: { _ in },
                      receiveValue: { dates in
                          datesWithNotes = dates
                          Self.lastDatesWithNotes = dates
                      })
            taskChangeCancellable = TaskStore.shared.observeTasks(filter: .all)
                .sink(receiveCompletion: { _ in },
                      receiveValue: { tasks in
                          let summaries = Self.buildSummaries(tasks: tasks)
                          taskSummariesByDay = summaries
                          Self.lastTaskSummaries = summaries
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
        let day = Calendar.current.startOfDay(for: date)
        if selectedDate != day { selectedDate = day }
    }

    private func showDay(_ date: Date) {
        let loaded = Self.lookUpState(for: date)
        withAnimation(.easeInOut(duration: DesignTokens.Motion.fast)) { state = loaded }
    }

    // Synchronous: an async lookup renders a blank frame before the note.
    private static func lookUpState(for date: Date) -> DailyState {
        let day = Calendar.current.startOfDay(for: date)
        let note = Perf.measure("daily note lookup") {
            try? NoteStore.shared.fetchExistingDailyNote(for: day)
        }
        return note.map { .existing($0) } ?? .draft(day)
    }
}

extension EnvironmentValues {
    /// Whether a note detail draws its own breadcrumb and title. Hosts that
    /// show the note under their own header (the Today date) turn it off.
    @Entry var noteDetailShowsDocumentHeader: Bool = true
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

/// Weekday above a large serif date, with a compact ‹ Today › switcher and a
/// month-calendar popover on the right.
private struct DailyNoteHeader: View {
    @Binding var selectedDate: Date
    let datesWithNotes: Set<String>
    let taskSummariesByDay: [String: DailyNoteView.DaySummary]
    let onShift: (Int) -> Void

    @State private var isCalendarShown = false
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

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private var isToday: Bool { calendar.isDateInToday(selectedDate) }

    var body: some View {
        HStack(alignment: .bottom, spacing: DesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(selectedDate.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                Text(dateText)
                    .font(DesignTokens.Typography.display(size: DesignTokens.Today.dateSize, weight: .medium))
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            daySwitcher
                .padding(.bottom, 6)
        }
        .onChange(of: selectedDate) { _, newDate in
            displayedMonth = calendar.startOfMonth(for: newDate)
        }
    }

    private var dateText: String {
        let sameYear = calendar.isDate(selectedDate, equalTo: Date(), toGranularity: .year)
        return sameYear
            ? selectedDate.formatted(.dateTime.day().month(.wide))
            : selectedDate.formatted(.dateTime.day().month(.wide).year())
    }

    // MARK: - Day switcher

    private var daySwitcher: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: 0) {
                switcherIcon("chevron.left", help: "Previous day") { onShift(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])

                Button { selectedDate = calendar.startOfDay(for: Date()) } label: {
                    Text("Today")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isToday ? DesignTokens.Palette.textTertiary : DesignTokens.Palette.textPrimary)
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Jump to today")

                switcherIcon("chevron.right", help: "Next day") { onShift(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .padding(.horizontal, 2)
            .background(Capsule().fill(DesignTokens.Palette.quietFill))

            switcherIcon("calendar", help: "Show calendar") {
                displayedMonth = calendar.startOfMonth(for: selectedDate)
                isCalendarShown.toggle()
            }
            .background(Capsule().fill(DesignTokens.Palette.quietFill))
            .accessibilityLabel("Show month calendar")
            .popover(isPresented: $isCalendarShown, arrowEdge: .bottom) {
                monthGrid
                    .padding(DesignTokens.Spacing.md)
                    .frame(width: 300)
            }
        }
    }

    private func switcherIcon(_ systemName: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    // MARK: - Month grid

    private var monthGrid: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(displayedMonth, format: .dateTime.month(.wide).year())
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                switcherIcon("chevron.left", help: "Previous month") { shiftMonth(-1) }
                switcherIcon("chevron.right", help: "Next month") { shiftMonth(1) }
            }
            .padding(.bottom, DesignTokens.Spacing.xxs)

            HStack(spacing: 2) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(DesignTokens.Palette.textTertiary)
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
                            onTap: {
                                selectedDate = calendar.startOfDay(for: date)
                                isCalendarShown = false
                            }
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
}

/// Compact day cell used inside the month-calendar popover. Echoes the load
/// signals from ``TaskCalendarView`` — priority-tinted task count badge plus
/// a note indicator — at inline scale.
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
            .padding(.horizontal, DesignTokens.Spacing.xxs)
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
            DesignTokens.Palette.fill(.hover)
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

/// Shown when a date has no note yet: an empty body editor under the date
/// header. On first non-empty keystroke the note is persisted and the parent
/// transitions to the full NoteDetailView.
private struct DraftDailyNoteView: View {
    let date: Date
    let onCreated: (Note) -> Void
    let onNavigate: (String) -> Void

    @State private var bodyText: String = ""
    @State private var hasCreated: Bool = false

    private var placeholder: String {
        Calendar.current.isDateInToday(date)
            ? String(localized: "Start writing — today's note is created when you type.")
            : String(localized: "Start writing — this day's note is created when you type.")
    }

    var body: some View {
        NoteEditorView(
            text: $bodyText,
            noteStore: .shared,
            onNavigate: onNavigate
        )
        .overlay(alignment: .topLeading) {
            if bodyText.isEmpty {
                // Offsets match the web editor's `.cm-content` padding (2.5rem 1.75rem).
                Text(placeholder)
                    .font(.system(size: 17))
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                    .padding(.top, 40)
                    .padding(.leading, 28)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
        .onChange(of: bodyText) { _, newValue in
            guard !hasCreated else { return }
            guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do {
                let store = NoteStore.shared
                let note = try NoteWriteQueue.run { () throws -> Note in
                    let (fetched, didCreate) = try store.dailyNoteCreatingIfNeeded(for: date)
                    // If the day's note already exists (another window, iCloud,
                    // an external editor created it since this draft appeared),
                    // bind to it as-is — never overwrite its body with the
                    // draft's first keystroke.
                    var note = fetched
                    if !didCreate, let full = try store.fetchNote(id: fetched.id) {
                        note = full   // real body from disk, not the DB placeholder
                    }
                    // A daily template seeded the new note: keep it, with the
                    // draft typed so far after it.
                    let draft = didCreate
                        ? NoteTemplateRenderer.appendingDraft(newValue, toSeed: note.body)
                        : newValue
                    if let body = NoteStore.dailyDraftBodyToWrite(
                        created: didCreate,
                        existingBody: note.body,
                        draft: draft
                    ) {
                        note.body = body
                        try store.updateNote(note, tags: (try? store.tags(for: note.id)) ?? [])
                    }
                    return note
                }
                hasCreated = true
                onCreated(note)
            } catch {
                Log.app.error("DraftDailyNoteView: failed to persist note: \(error)")
            }
        }
    }
}
