import SwiftUI

/// Settings → Calendar → Time Blocking: "Write scheduled tasks to calendar"
/// plus the calendar the blocks go to. Lives inside `CalendarSettingsPane`'s
/// Form and is disabled until the calendar integration has full access.
struct TaskTimeBlockingSettingsSection: View {
    @ObservedObject private var calendar = CalendarService.shared
    @ObservedObject private var mirror = TaskCalendarMirrorService.shared

    @AppStorage(CalendarService.enabledKey) private var calendarEnabled: Bool = false
    @AppStorage(TaskCalendarMirrorService.enabledKey) private var writeBlocks: Bool = false
    @AppStorage(TaskCalendarMirrorService.calendarIdKey) private var calendarId: String = ""

    private var isAvailable: Bool { calendarEnabled && calendar.accessState == .granted }

    var body: some View {
        Section("Time Blocking") {
            Toggle("Write scheduled tasks to calendar", isOn: Binding(
                get: { writeBlocks },
                set: { newValue in
                    writeBlocks = newValue
                    if newValue && calendarId.isEmpty, let first = mirror.availableCalendars.first {
                        calendarId = first.id
                    }
                }
            ))
            .disabled(!isAvailable)

            Picker("Calendar", selection: $calendarId) {
                if calendarId.isEmpty {
                    Text("Choose…").tag("")
                }
                ForEach(mirror.availableCalendars) { choice in
                    Text(choice.sourceTitle.isEmpty ? choice.title : "\(choice.title) (\(choice.sourceTitle))")
                        .tag(choice.id)
                }
                if !calendarId.isEmpty && !mirror.availableCalendars.contains(where: { $0.id == calendarId }) {
                    Text("Unavailable calendar").tag(calendarId)
                }
            }
            .disabled(!isAvailable || !writeBlocks)

            if let error = mirror.lastError, writeBlocks {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("Tasks you give a time in the planner appear as events in this calendar, and move or disappear when the task changes or is completed. Scribe only ever edits or removes events it created itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { mirror.reloadCalendars() }
        .onChange(of: calendar.accessState) { _, _ in mirror.reloadCalendars() }
        .onChange(of: calendarEnabled) { _, _ in mirror.reloadCalendars() }
    }
}
