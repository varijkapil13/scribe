import SwiftUI

/// Settings → Shortcuts: Spotlight indexing toggle and pointers to the
/// Shortcuts / Siri actions and the "Scribe Focus" filter.
struct SiriSpotlightSettingsSection: View {

    @AppStorage(SpotlightIndexer.enabledKey) private var spotlightEnabled = true
    @AppStorage(ScribeFocusPreferences.muteMeetingPromptsKey) private var focusMutesMeetingPrompts = false
    @AppStorage(ScribeFocusPreferences.hideRemindersKey) private var focusHidesReminders = false

    var body: some View {
        Section {
            Toggle("Show notes and tasks in Spotlight", isOn: Binding(
                get: { spotlightEnabled },
                set: { newValue in
                    spotlightEnabled = newValue
                    SpotlightIndexer.shared.setEnabled(newValue)
                }
            ))
            Text("Note titles and previews and open task titles are added to the on-device Spotlight index. Turning this off removes them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Spotlight")
        }

        Section {
            Text("Scribe's actions — create and search notes, add and complete tasks, start or stop recording, toggle dictation, and get meeting summaries or transcripts — are available in the Shortcuts app and to Siri (for example, \u{201C}Start recording in Scribe\u{201D}).")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Scribe Focus filter", value: focusStatus)
            Text("Add the Scribe filter to a Focus in System Settings → Focus to mute meeting-detection prompts or hide reminders while that Focus is on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Shortcuts & Siri")
        }
    }

    private var focusStatus: String {
        switch (focusMutesMeetingPrompts, focusHidesReminders) {
        case (true, true):   return "Muting meeting prompts and reminders"
        case (true, false):  return "Muting meeting prompts"
        case (false, true):  return "Hiding reminders"
        case (false, false): return "Inactive"
        }
    }
}
