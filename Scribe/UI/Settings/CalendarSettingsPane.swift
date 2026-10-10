import AppKit
import Combine
import SwiftUI

/// Settings → Calendar. Calendar access is requested only when the user turns
/// the integration on here — never at launch.
struct CalendarSettingsPane: View {
    @ObservedObject private var calendar = CalendarService.shared

    @AppStorage(CalendarService.enabledKey) private var enabled: Bool = false
    @AppStorage(CalendarService.remindersKey) private var remindBeforeMeetings: Bool = true
    @AppStorage(CalendarService.nameNotesKey) private var nameNotesAfterEvents: Bool = true

    @State private var isRequesting = false

    var body: some View {
        Form {
            Section("Calendar") {
                Toggle("Use my calendar", isOn: Binding(
                    get: { enabled },
                    set: { newValue in setEnabled(newValue) }
                ))
                .disabled(isRequesting)

                HStack {
                    Text("Access")
                    Spacer()
                    if isRequesting {
                        ProgressView().controlSize(.small)
                    }
                    Text(calendar.accessState.label)
                        .foregroundStyle(calendar.accessState == .granted ? Color.secondary : Color.orange)
                }
                if enabled && calendar.accessState != .granted && calendar.accessState != .notDetermined {
                    Button("Open Calendar Privacy Settings…") {
                        Permissions.openSystemPreferences(for: "Privacy_Calendars")
                    }
                    Text("Scribe needs full calendar access. Turn Scribe on under Privacy & Security → Calendars, then come back here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Scribe reads events on your Mac to name meeting notes, list attendees and the agenda, and remind you to record. Scribe never uploads your calendar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Meetings") {
                Toggle("Remind me before meetings", isOn: $remindBeforeMeetings)
                Text("A notification one minute before events with two or more attendees, with Start Recording and — when the invite has a Zoom, Meet, Teams or Webex link — Join & Record.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Name notes after calendar events", isOn: $nameNotesAfterEvents)
                Text("When you start recording during an event, the new note is titled after it and starts with the attendees, agenda and meeting link.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!enabled)

            TaskTimeBlockingSettingsSection()
        }
        .formStyle(.grouped)
        .onAppear { calendar.refreshAccessState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            calendar.refreshAccessState()
        }
    }

    private func setEnabled(_ newValue: Bool) {
        guard newValue else {
            enabled = false
            return
        }
        isRequesting = true
        Task {
            await calendar.enable()
            isRequesting = false
        }
    }
}
