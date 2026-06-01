import SwiftUI

/// Tick Tick-style compact calendar date picker. Shown as a popover from the
/// task editor's due-date row.
///
/// Layout:
///   ┌─────────────────────────────────┐
///   │  Today  Tomorrow  Next Week  ✕  │  ← quick shortcuts
///   ├─────────────────────────────────┤
///   │  < May 2026 >                   │
///   │  Su Mo Tu We Th Fr Sa           │
///   │   …  calendar grid  …           │
///   └─────────────────────────────────┘
struct InlineDatePickerView: View {

    @Binding var selectedDate: Date?
    @Environment(\.dismiss) private var dismiss

    @State private var displayMonth: Date

    private let cal = Calendar.current

    init(selectedDate: Binding<Date?>) {
        _selectedDate = selectedDate
        let anchor = selectedDate.wrappedValue ?? Date()
        _displayMonth = State(initialValue: Calendar.current.startOfMonth(for: anchor))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            shortcutsRow
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            VStack(spacing: 6) {
                monthHeader
                dayNamesRow
                calendarGrid
            }
            .padding(12)
        }
        .frame(width: 300)
    }

    // MARK: - Shortcuts

    private var shortcutsRow: some View {
        HStack(spacing: 6) {
            shortcutChip(systemImage: "sun.max.fill",        label: "Today",       date: cal.startOfDay(for: Date()))
            shortcutChip(systemImage: "sunrise.fill",        label: "Tomorrow",    date: dayOffset(1))
            shortcutChip(systemImage: "forward.end.fill",    label: "Weekend",     date: thisWeekend)
            shortcutChip(systemImage: "calendar.badge.plus", label: "Next week",   date: nextMonday)
            Spacer()
            Button { selectedDate = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.quaternary)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Clear date")
            .accessibilityLabel("Clear date")
        }
    }

    @ViewBuilder
    private func shortcutChip(systemImage: String, label: String, date: Date) -> some View {
        let isActive = selectedDate.map { cal.isDate($0, inSameDayAs: date) } ?? false
        Button { applyDate(date) } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.10))
            )
            .foregroundStyle(isActive ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Month header

    private var monthHeader: some View {
        HStack {
            Button { shiftMonth(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text(displayMonth, format: .dateTime.month(.wide).year())
                .font(.system(.callout, weight: .semibold))

            Spacer()

            Button { shiftMonth(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Day grid

    /// Localized two-letter weekday symbols, rotated so the column order honours
    /// `Calendar.firstWeekday` (Sunday in en_US, Monday in most of Europe).
    private var dayNames: [String] {
        let symbols = cal.veryShortWeekdaySymbols
        let shift = cal.firstWeekday - 1
        guard shift > 0, shift < symbols.count else { return symbols }
        return Array(symbols[shift...] + symbols[..<shift])
    }

    /// Full localized weekday names for VoiceOver column headers.
    private var dayNamesAccessible: [String] {
        let symbols = cal.weekdaySymbols
        let shift = cal.firstWeekday - 1
        guard shift > 0, shift < symbols.count else { return symbols }
        return Array(symbols[shift...] + symbols[..<shift])
    }

    private var dayNamesRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(dayNames.enumerated()), id: \.offset) { index, name in
                Text(name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(dayNamesAccessible[safe: index] ?? name)
            }
        }
    }

    private var calendarGrid: some View {
        let days = buildDays()
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(0..<days.count, id: \.self) { i in
                dayCell(days[i])
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ date: Date?) -> some View {
        if let date {
            let isSelected = selectedDate.map { cal.isDate($0, inSameDayAs: date) } ?? false
            let isToday    = cal.isDateInToday(date)
            let day        = cal.component(.day, from: date)

            Button { applyDate(date) } label: {
                Text("\(day)")
                    .font(.system(size: 12, weight: isSelected ? .semibold : isToday ? .medium : .regular))
                    .foregroundStyle(
                        isSelected ? Color.white :
                        isToday    ? Color.accentColor :
                                     Color.primary
                    )
                    .frame(width: 30, height: 28)
                    .background(
                        Circle()
                            .fill(
                                isSelected ? Color.accentColor :
                                isToday    ? Color.accentColor.opacity(0.15) :
                                             Color.clear
                            )
                    )
                    .overlay(
                        // Non-color cue for "today" — a small ring — so it's
                        // distinguishable from the selected day without hue.
                        Circle()
                            .strokeBorder(isToday && !isSelected ? Color.accentColor : .clear, lineWidth: 1)
                            .frame(width: 26, height: 26)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(date.formatted(date: .complete, time: .omitted) + (isToday ? ", today" : ""))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        } else {
            Color.clear
                .frame(width: 30, height: 28)
        }
    }

    // MARK: - Helpers

    private func applyDate(_ date: Date) {
        if let existing = selectedDate {
            let comps = cal.dateComponents([.hour, .minute], from: existing)
            let h = comps.hour ?? 0
            let m = comps.minute ?? 0
            if h != 0 || m != 0 {
                // User previously set an explicit time — preserve it on the new date.
                selectedDate = cal.date(bySettingHour: h, minute: m, second: 0, of: date)
            } else {
                selectedDate = cal.startOfDay(for: date)
            }
        } else {
            // No time specified — store date-only (midnight).
            selectedDate = cal.startOfDay(for: date)
        }
        displayMonth = cal.startOfMonth(for: date)
    }

    private func shiftMonth(_ value: Int) {
        guard let next = cal.date(byAdding: .month, value: value, to: displayMonth)
        else { return }
        displayMonth = next
    }

    private func dayOffset(_ n: Int) -> Date {
        cal.date(byAdding: .day, value: n, to: cal.startOfDay(for: Date())) ?? Date()
    }

    private var nextMonday: Date {
        let today    = cal.startOfDay(for: Date())
        let weekday  = cal.component(.weekday, from: today) // 1=Sun…7=Sat
        let daysToMon = (2 - weekday + 7) % 7
        return cal.date(byAdding: .day, value: daysToMon == 0 ? 7 : daysToMon, to: today) ?? today
    }

    private var thisWeekend: Date {
        let today   = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today) // 1=Sun, 7=Sat
        let daysToSat = (7 - weekday + 7) % 7
        return cal.date(byAdding: .day, value: daysToSat == 0 ? 7 : daysToSat, to: today) ?? today
    }

    // Returns Date? for each grid cell: nil = leading/trailing empty. Locale-
    // aware leading blanks via the shared `CalendarMonthGrid`.
    private func buildDays() -> [Date?] {
        CalendarMonthGrid.cells(forMonth: displayMonth, calendar: cal, padTrailing: true)
    }
}

// MARK: - Safe-index helper

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Calendar helper

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        let comps = dateComponents([.year, .month], from: date)
        return self.date(from: comps) ?? date
    }
}
