// ScribeiOS/System/ScribeiOSSystemSettingsSection.swift
//
// Settings → Siri, Spotlight & Widgets on iPhone / iPad: the Spotlight
// indexing toggle (same key as the Mac's Settings → Shortcuts), the Scribe
// Focus filter status, and pointers to the widgets, controls, Action button
// and Share sheet. Wired into SettingsScreen with one line.

import SwiftUI

struct ScribeiOSSystemSettingsSection: View {

    @AppStorage(SpotlightIndexer.enabledKey) private var spotlightEnabled = true
    @AppStorage(ScribeFocusPreferences.muteMeetingPromptsKey) private var focusMutesMeetingPrompts = false
    @AppStorage(ScribeFocusPreferences.hideRemindersKey) private var focusHidesReminders = false

    private var appGroupAvailable: Bool { ScribeAppGroup.containerURL() != nil }

    var body: some View {
        Section {
            Toggle("Show notes and tasks in Spotlight", isOn: Binding(
                get: { spotlightEnabled },
                set: { newValue in
                    spotlightEnabled = newValue
                    SpotlightIndexer.shared.setEnabled(newValue)
                }
            ))
            LabeledContent("Scribe Focus filter", value: focusStatus)
        } header: {
            Text("Siri & Spotlight")
        } footer: {
            Text("Ask Siri to \u{201C}Quick capture in Scribe\u{201D} or \u{201C}Start recording in Scribe\u{201D}; every action is also in the Shortcuts app. Add the Scribe filter to a Focus in Settings → Focus to mute meeting prompts or hide reminders while it's on.")
        }

        Section {
            LabeledContent("Widgets & Share sheet", value: appGroupAvailable ? "Connected" : "Unavailable")
        } header: {
            Text("Widgets & Controls")
        } footer: {
            Text("Add Scribe widgets to the Home Screen, Lock Screen or StandBy, and the New Note, New Task and Start Recording controls to Control Center. Set the Action button to Shortcut → Scribe → Quick Capture. Items shared to Scribe from other apps are imported the next time you open Scribe.")
        }
    }

    private var focusStatus: String {
        switch (focusMutesMeetingPrompts, focusHidesReminders) {
        case (true, true):   return "Muting prompts and reminders"
        case (true, false):  return "Muting meeting prompts"
        case (false, true):  return "Hiding reminders"
        case (false, false): return "Inactive"
        }
    }
}
