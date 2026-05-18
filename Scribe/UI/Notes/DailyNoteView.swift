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

    @State private var state: DailyState
    @State private var selectedDate: Date
    @State private var datesWithNotes: Set<String> = []
    @State private var showCalendarPopover: Bool = false
    @State private var noteChangeCancellable: AnyCancellable?

    var onNavigate: (String) -> Void

    init(onNavigate: @escaping (String) -> Void) {
        self.onNavigate = onNavigate
        let today = Calendar.current.startOfDay(for: Date())
        _selectedDate = State(initialValue: today)
        if let note = try? NoteStore.shared.fetchExistingDailyNote(for: today) {
            _state = State(initialValue: .existing(note))
        } else {
            _state = State(initialValue: .draft(today))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DailyNoteHeader(
                selectedDate: $selectedDate,
                datesWithNotes: datesWithNotes,
                showCalendarPopover: $showCalendarPopover,
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
        }
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

// MARK: - Header

/// Title + horizontal day strip + calendar trigger. Replaces the previous
/// `HSplitView` calendar sidebar; the full month picker is one click away in
/// a popover.
private struct DailyNoteHeader: View {
    @Binding var selectedDate: Date
    let datesWithNotes: Set<String>
    @Binding var showCalendarPopover: Bool
    let onShift: (Int) -> Void

    private let calendar = Calendar.current

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

                Button { showCalendarPopover.toggle() } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .popover(isPresented: $showCalendarPopover, arrowEdge: .bottom) {
                    NoteCalendarView { date in
                        showCalendarPopover = false
                        selectedDate = calendar.startOfDay(for: date)
                    }
                    .frame(width: 280, height: 320)
                }
                .help("Pick a date")
            }

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
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.top, DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.xs)
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
