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
        VStack(spacing: 8) {
            HStack {
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
                Text(displayedMonth, format: .dateTime.month(.wide).year())
                    .font(.headline)
                Spacer()
                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)

            HStack(spacing: 0) {
                ForEach(["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"], id: \.self) { d in
                    Text(d)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            let days = monthDays()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7),
                      spacing: 0) {
                ForEach(days.indices, id: \.self) { idx in
                    if let date = days[idx] {
                        let key = Self.keyFormatter.string(from: date)
                        let hasNote = datesWithNotes.contains(key)
                        let isToday = calendar.isDateInToday(date)
                        Button { onSelectDate(date) } label: {
                            ZStack {
                                if isToday {
                                    Circle().fill(Color.accentColor).frame(width: 26, height: 26)
                                }
                                VStack(spacing: 1) {
                                    Text("\(calendar.component(.day, from: date))")
                                        .font(.callout)
                                        .foregroundStyle(isToday ? .white : .primary)
                                    if hasNote {
                                        Circle()
                                            .fill(isToday ? Color.white : Color.accentColor)
                                            .frame(width: 4, height: 4)
                                    }
                                }
                            }
                            .frame(height: 36)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(height: 36)
                    }
                }
            }
        }
        .padding(8)
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
        let notes = (try? NoteStore.shared.fetchAllNotes()) ?? []
        datesWithNotes = Set(notes.compactMap(\.dailyDate))
    }
}

