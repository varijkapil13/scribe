// Extensions/ScribeWidgets/ScribeWidgetsBundle.swift
//
// WidgetKit extension for Scribe (macOS desktop / Notification Center
// widgets + a Control Center control). Lives outside Scribe/ because SwiftPM
// compiles every file under Scribe/ into the app's executable target; this
// target is built only by Xcode (project.yml → ScribeWidgets) and embedded in
// the app. Data comes from the App Group (Scribe/Shared/, compiled in here).

import SwiftUI
import WidgetKit

@main
struct ScribeWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ScribeTodayWidget()
        ScribeNextMeetingWidget()
        ScribeRecordControl()
    }
}
