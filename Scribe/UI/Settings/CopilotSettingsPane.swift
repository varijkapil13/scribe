import KeyboardShortcuts
import SwiftUI

/// Settings → Meeting Copilot: live summary while recording, bookmarked
/// moments, and pre-meeting briefs.
struct CopilotSettingsPane: View {

    @AppStorage(CopilotSettings.liveSummaryEnabledKey) private var liveSummaryEnabled: Bool = true
    @AppStorage(CopilotSettings.liveSummaryIntervalKey) private var intervalMinutes: Int = CopilotSettings.defaultIntervalMinutes
    @AppStorage(CopilotSettings.highlightsInNoteKey) private var highlightsInNote: Bool = true
    @AppStorage(CopilotSettings.briefNotificationsKey) private var briefNotifications: Bool = true
    @AppStorage(CopilotSettings.briefLeadMinutesKey) private var briefLeadMinutes: Int = CopilotSettings.defaultBriefLeadMinutes

    var body: some View {
        Form {
            Section {
                Toggle("Keep a live summary while recording", isOn: $liveSummaryEnabled)
                Stepper(value: $intervalMinutes, in: CopilotSettings.intervalRange) {
                    Text("Update every \(intervalMinutes) min of conversation")
                }
                .disabled(!liveSummaryEnabled)
                Text("The Copilot panel in the live view shows a running summary, action items and open questions, and answers questions about the meeting so far. Everything runs on-device with Apple Intelligence; without it you still get detected action items and questions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Live summary")
            }

            Section {
                KeyboardShortcuts.Recorder("Mark moment:", name: .markMoment)
                Toggle("Add highlights to the meeting note when recording stops", isOn: $highlightsInNote)
                Text("Bookmarked moments appear on the playback timeline, in the Summary tab, and get extra weight in AI summaries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Highlights")
            }

            Section {
                Toggle("Send a brief before meetings", isOn: $briefNotifications)
                Stepper(value: $briefLeadMinutes, in: CopilotSettings.briefLeadRange) {
                    Text("\(briefLeadMinutes) min before the meeting")
                }
                .disabled(!briefNotifications)
                Text("Briefs collect earlier meetings and notes with the same people or a similar title, plus their open action items. They appear under Upcoming in the menu bar and need Calendar integration and meeting reminders (Settings → Calendar).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Pre-meeting brief")
            }
        }
        .formStyle(.grouped)
    }
}
