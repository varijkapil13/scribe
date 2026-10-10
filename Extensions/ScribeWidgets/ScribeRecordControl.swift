// Extensions/ScribeWidgets/ScribeRecordControl.swift
//
// Control Center / menu bar control (macOS 26+): one button that opens Scribe
// and starts recording via scribe://record/start.

import AppIntents
import SwiftUI
import WidgetKit

struct ScribeRecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ScribeAppGroup.recordControlKind) {
            ControlWidgetButton(action: OpenScribeRecordingIntent()) {
                Label("Start Recording", systemImage: "record.circle")
            }
        }
        .displayName("Start Recording")
        .description("Open Scribe and start recording.")
    }
}
