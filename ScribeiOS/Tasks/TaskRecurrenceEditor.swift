import SwiftUI
import UIKit

/// Repeat editor: presets, frequency + interval, weekdays, the monthly /
/// yearly day pattern, the end (never / on a date / after N times) and
/// "repeat after completion". Writes the RRULE back through `rrule`.
struct TaskRecurrenceEditor: View {
    @Binding var rrule: String?
    /// The task's due date (anchor for weekday / day defaults).
    let anchor: Date

    @State private var isOn: Bool
    @State private var draft: TaskRecurrenceDraft
    private let startedLossy: Bool

    init(rrule: Binding<String?>, anchor: Date) {
        _rrule = rrule
        self.anchor = anchor
        let existing = TaskRecurrenceDraft(rrule: rrule.wrappedValue, anchor: anchor, calendar: .current)
        _isOn = State(initialValue: existing != nil)
        _draft = State(initialValue: existing ?? TaskRecurrenceDraft(anchor: anchor, calendar: .current))
        startedLossy = existing?.isLossy ?? false
    }

    var body: some View {
        Form {
            Section {
                Toggle("Repeat", isOn: $isOn)
            } footer: {
                if isOn { Text(draft.summary) }
            }

            if isOn {
                if startedLossy {
                    Section {
                        Label("This repeat uses options the editor can’t show. Changing it replaces them.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Presets") {
                    ForEach(TaskRecurrenceDraft.Preset.allCases) { preset in
                        Button(preset.title) {
                            var next = TaskRecurrenceDraft.preset(preset, anchor: anchor, calendar: .current)
                            next.endMode = draft.endMode
                            next.untilDate = draft.untilDate
                            next.count = draft.count
                            next.fromCompletion = draft.fromCompletion
                            draft = next
                        }
                    }
                }

                Section("Frequency") {
                    Picker("Frequency", selection: $draft.frequency) {
                        ForEach(TaskRecurrenceDraft.frequencies, id: \.self) { frequency in
                            Text(TaskRecurrenceDraft.frequencyTitle(frequency)).tag(frequency)
                        }
                    }
                    .pickerStyle(.segmented)
                    Stepper(value: $draft.interval, in: 1...99) {
                        Text(intervalText)
                    }
                    if draft.frequency == .weekly { weekdayPicker }
                    if draft.frequency == .monthly || draft.frequency == .yearly { monthPatternRows }
                }

                Section {
                    Picker("Ends", selection: $draft.endMode) {
                        ForEach(TaskRecurrenceDraft.EndMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    switch draft.endMode {
                    case .never:
                        EmptyView()
                    case .until:
                        DatePicker("Last Date", selection: untilBinding, displayedComponents: .date)
                    case .count:
                        Stepper(value: $draft.count, in: 1...999) {
                            Text("\(draft.count) more time\(draft.count == 1 ? "" : "s")")
                        }
                    }
                } header: {
                    Text("End")
                }

                Section {
                    Toggle("Repeat after completion", isOn: $draft.fromCompletion)
                } footer: {
                    Text("The next date counts from when you complete the task instead of its due date — handy for chores like “water plants every 2 weeks”.")
                }
            }
        }
        .navigationTitle("Repeat")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: isOn) { write() }
        .onChange(of: draft) { write() }
    }

    private var weekdayPicker: some View {
        HStack(spacing: 6) {
            ForEach(RecurrenceRule.Weekday.allCases, id: \.self) { day in
                let selected = draft.weekdays.contains(day)
                Button {
                    if selected { draft.weekdays.remove(day) } else { draft.weekdays.insert(day) }
                } label: {
                    Text(TaskRecurrenceDraft.weekdayInitial(day))
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .background(Circle().fill(selected ? Color.accentColor : Color(uiColor: .tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(TaskRecurrenceDraft.weekdayTitle(day))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var monthPatternRows: some View {
        Picker("On", selection: $draft.monthPattern) {
            ForEach(TaskRecurrenceDraft.MonthPattern.allCases) { pattern in
                Text(pattern.title).tag(pattern)
            }
        }
        switch draft.monthPattern {
        case .sameDay, .lastDay:
            EmptyView()
        case .dayOfMonth:
            Picker("Day", selection: $draft.monthDay) {
                ForEach(1...31, id: \.self) { day in Text("\(day)").tag(day) }
            }
        case .ordinalWeekday:
            Picker("Which", selection: $draft.ordinal) {
                ForEach(TaskRecurrenceDraft.ordinals, id: \.self) { value in
                    Text(TaskRecurrenceDraft.ordinalTitle(value)).tag(value)
                }
            }
            Picker("Weekday", selection: $draft.ordinalWeekday) {
                ForEach(RecurrenceRule.Weekday.allCases, id: \.self) { day in
                    Text(TaskRecurrenceDraft.weekdayTitle(day)).tag(day)
                }
            }
        }
    }

    private var intervalText: String {
        let unit = TaskRecurrenceDraft.unitName(draft.frequency, plural: draft.interval != 1)
        return draft.interval == 1 ? "Every \(unit)" : "Every \(draft.interval) \(unit)"
    }

    private var untilBinding: Binding<Date> {
        Binding(
            get: { draft.untilDate },
            set: { draft.untilDate = TaskRecurrenceDraft.endOfDay($0, calendar: .current) }
        )
    }

    private func write() {
        rrule = isOn ? draft.rruleString : nil
    }
}
