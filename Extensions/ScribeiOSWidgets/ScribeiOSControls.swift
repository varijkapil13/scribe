// Extensions/ScribeiOSWidgets/ScribeiOSControls.swift
//
// Control Center / Lock Screen / Action button controls. Each runs a capture
// intent from ScribeiOS/System/Shared that opens Scribe (the intent then
// runs in the app: the Quick Capture sheet, or the recorder).

import AppIntents
import SwiftUI
import WidgetKit

struct ScribeiOSNewNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ScribeiOSWidgetKinds.newNoteControl) {
            ControlWidgetButton(action: ScribeQuickCaptureIntent(kind: .note)) {
                Label("New Note", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Note")
        .description("Open Scribe to capture a note.")
    }
}

struct ScribeiOSNewTaskControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ScribeiOSWidgetKinds.newTaskControl) {
            ControlWidgetButton(action: ScribeQuickCaptureIntent(kind: .task)) {
                Label("New Task", systemImage: "checklist")
            }
        }
        .displayName("New Task")
        .description("Open Scribe to add a task.")
    }
}

struct ScribeiOSRecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ScribeiOSWidgetKinds.recordControl) {
            ControlWidgetButton(action: ScribeStartRecordingControlIntent()) {
                Label("Start Recording", systemImage: "record.circle")
            }
        }
        .displayName("Start Recording")
        .description("Open Scribe and start recording a meeting.")
    }
}
