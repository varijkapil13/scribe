// ScribeiOS/Recording/RecordingSettingsSection.swift
//
// Settings › Recording on iPhone / iPad. Wired into the settings root
// (SettingsScreen) with one line at the recording slot.

import SwiftUI

/// UserDefaults keys and readers for iPhone / iPad recording.
enum MobileRecordingSettings {

    /// Shared with the Mac (`selectedLanguage`): the recognition language
    /// code (`LanguageOptions`), "auto" for the system language.
    nonisolated static let languageKey = "selectedLanguage"
    nonisolated static let keepAudioKey = "ios.recording.keepAudio"
    nonisolated static let summarizeKey = "ios.recording.summarize"
    nonisolated static let actionItemsToTasksKey = "ios.recording.actionItemsToTasks"
    nonisolated static let transcriptInNoteKey = "ios.recording.transcriptInNote"
    nonisolated static let liveActivityKey = "ios.recording.liveActivity"
    nonisolated static let useCalendarKey = "ios.recording.useCalendar"

    nonisolated static func bool(_ key: String, default fallback: Bool, defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    static var keepAudio: Bool { bool(keepAudioKey, default: true, defaults: .standard) }
    static var summarize: Bool { bool(summarizeKey, default: true, defaults: .standard) }
    static var actionItemsToTasks: Bool { bool(actionItemsToTasksKey, default: true, defaults: .standard) }
    static var transcriptInNote: Bool { bool(transcriptInNoteKey, default: true, defaults: .standard) }
    static var liveActivity: Bool { bool(liveActivityKey, default: true, defaults: .standard) }
    static var useCalendar: Bool { bool(useCalendarKey, default: false, defaults: .standard) }
    static var language: String? { UserDefaults.standard.string(forKey: languageKey) }
}

/// The Recording section of the iOS settings screen.
struct RecordingSettingsSection: View {
    @AppStorage(MobileRecordingSettings.languageKey) private var language = "auto"
    @AppStorage(MobileRecordingSettings.keepAudioKey) private var keepAudio = true
    @AppStorage(MobileRecordingSettings.summarizeKey) private var summarize = true
    @AppStorage(MobileRecordingSettings.actionItemsToTasksKey) private var actionItemsToTasks = true
    @AppStorage(MobileRecordingSettings.transcriptInNoteKey) private var transcriptInNote = true
    @AppStorage(MobileRecordingSettings.liveActivityKey) private var liveActivity = true
    @AppStorage(MobileRecordingSettings.useCalendarKey) private var useCalendar = false

    @State private var calendarDenied = false

    var body: some View {
        Section {
            Picker("Language", selection: $language) {
                ForEach(LanguageOptions.supported, id: \.code) { option in
                    Text(option.name).tag(option.code)
                }
            }
            Toggle("Keep audio for playback", isOn: $keepAudio)
            Toggle("Summarize after recording", isOn: $summarize)
            Toggle("Turn action items into tasks", isOn: $actionItemsToTasks)
                .disabled(!summarize)
            Toggle("Add transcript to the meeting note", isOn: $transcriptInNote)
            Toggle("Live Activity while recording", isOn: $liveActivity)
            Toggle("Name recordings after calendar events", isOn: Binding(
                get: { useCalendar },
                set: { setUseCalendar($0) }
            ))
            if calendarDenied {
                Text("Calendar access is off for Scribe. Turn it on in Settings › Privacy & Security › Calendars.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Recording")
        } footer: {
            Text("iPhone and iPad record the microphone only (\(MobileRecordingDefaults.captureModeLabel)). Transcription and summaries run on this device; the summary, action items and transcript are written into the meeting note so they sync to your Mac.")
        }
    }

    private func setUseCalendar(_ enabled: Bool) {
        guard enabled else {
            useCalendar = false
            calendarDenied = false
            return
        }
        Task { @MainActor in
            let granted = await MobileCalendarLookup.requestAccess()
            useCalendar = granted
            calendarDenied = !granted
        }
    }
}
