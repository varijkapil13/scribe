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
        .frame(width: 272)
    }

    // MARK: - Shortcuts

    private var shortcutsRow: some View {
        HStack(spacing: 6) {
            shortcutChip(systemImage: "sun.max.fill",        help: "Today",     date: cal.startOfDay(for: Date()))
            shortcutChip(systemImage: "sunrise.fill",        help: "Tomorrow",  date: dayOffset(1))
            shortcutChip(systemImage: "forward.end.fill",    help: "This Weekend", date: thisWeekend)
            shortcutChip(systemImage: "calendar.badge.plus", help: "Next Week", date: nextMonday)
            Spacer()
            Button { selectedDate = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.quaternary)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Clear date")
        }
    }

    @ViewBuilder
    private func shortcutChip(systemImage: String, help: String, date: Date) -> some View {
        let isActive = selectedDate.map { cal.isDate($0, inSameDayAs: date) } ?? false
        Button { applyDate(date) } label: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.10))
                )
                .foregroundStyle(isActive ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .help(help)
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

    private let dayNames = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    private var dayNamesRow: some View {
        HStack(spacing: 0) {
            ForEach(dayNames, id: \.self) { name in
                Text(name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
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
            }
            .buttonStyle(.plain)
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

    // Returns Date? for each grid cell: nil = leading/trailing empty.
    private func buildDays() -> [Date?] {
        let firstDay     = displayMonth
        let leadingNulls = cal.component(.weekday, from: firstDay) - 1 // weekday is 1-based
        let range        = cal.range(of: .day, in: .month, for: firstDay)!

        var cells: [Date?] = Array(repeating: nil, count: leadingNulls)
        for dayNum in range {
            let date = cal.date(byAdding: .day, value: dayNum - 1, to: firstDay)!
            cells.append(date)
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }
}

// MARK: - Calendar helper

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        let comps = dateComponents([.year, .month], from: date)
        return self.date(from: comps) ?? date
    }
}
