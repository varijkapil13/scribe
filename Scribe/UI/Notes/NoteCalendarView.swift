// Scribe/UI/Notes/NoteCalendarView.swift
import SwiftUI

struct NoteCalendarView: View {
    @State private var displayedMonth: Date = Calendar.current.startOfMonth(for: Date())
    @State private var datesWithNotes: Set<String> = []
    var onSelectDate: (Date) -> Void

    private let calendar = Calendar.current

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Month header ──────────────────────────────────────────────
            HStack(alignment: .center) {
                Text(displayedMonth, format: .dateTime.month(.wide).year())
                    .font(DesignTokens.Typography.section)
                    .foregroundStyle(.primary)

                Spacer()

                HStack(spacing: DesignTokens.Spacing.xxs) {
                    Button { shiftMonth(-1) } label: {
                        Image(systemName: "chevron.left")
                            .imageScale(.small)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Button { shiftMonth(1) } label: {
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.top, DesignTokens.Spacing.lg)
            .padding(.bottom, DesignTokens.Spacing.sm)

            // ── Day-of-week headers ───────────────────────────────────────
            HStack(spacing: 0) {
                ForEach(["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"], id: \.self) { d in
                    Text(d)
                        .font(DesignTokens.Typography.eyebrow)
                        .tracking(0.3)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.bottom, DesignTokens.Spacing.xs)

            Divider()
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.bottom, DesignTokens.Spacing.xs)

            // ── Day grid ──────────────────────────────────────────────────
            let days = monthDays()
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7),
                spacing: 2
            ) {
                ForEach(days.indices, id: \.self) { idx in
                    if let date = days[idx] {
                        DayCell(
                            date: date,
                            hasNote: datesWithNotes.contains(Self.keyFormatter.string(from: date)),
                            isToday: calendar.isDateInToday(date),
                            onTap: { onSelectDate(date) }
                        )
                    } else {
                        Color.clear.frame(height: 40)
                    }
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)

            Spacer()
        }
        .onAppear { loadDailyNoteDates() }
        .onChange(of: displayedMonth) { _, _ in loadDailyNoteDates() }
    }

    private func shiftMonth(_ delta: Int) {
        displayedMonth = calendar.date(byAdding: .month, value: delta, to: displayedMonth)
            ?? displayedMonth
    }

    private func monthDays() -> [Date?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth) else { return [] }
        let firstDay = monthInterval.start
        let weekday = calendar.component(.weekday, from: firstDay) - 1
        var days: [Date?] = Array(repeating: nil, count: weekday)
        var current = firstDay
        while current < monthInterval.end {
            days.append(current)
            current = calendar.date(byAdding: .day, value: 1, to: current)!
        }
        return days
    }

    private func loadDailyNoteDates() {
        datesWithNotes = Set((try? NoteStore.shared.fetchDailyDates()) ?? [])
    }
}

// MARK: - Day cell

private struct DayCell: View {
    let date: Date
    let hasNote: Bool
    let isToday: Bool
    let onTap: () -> Void

    @State private var isHovered = false
    private let calendar = Calendar.current

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if isToday {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 30, height: 30)
                } else if isHovered {
                    Circle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 30, height: 30)
                }

                VStack(spacing: 1) {
                    Text("\(calendar.component(.day, from: date))")
                        .font(.callout)
                        .fontWeight(isToday ? .semibold : .regular)
                        .foregroundStyle(isToday ? .white : .primary)
                        .monospacedDigit()

                    if hasNote {
                        Circle()
                            .fill(isToday ? Color.white.opacity(0.8) : Color.accentColor)
                            .frame(width: 4, height: 4)
                    } else {
                        Color.clear.frame(width: 4, height: 4)
                    }
                }
            }
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}
