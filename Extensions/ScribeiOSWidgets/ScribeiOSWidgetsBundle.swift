// Extensions/ScribeiOSWidgets/ScribeiOSWidgetsBundle.swift
//
// iPhone / iPad WidgetKit extension: Home Screen, Lock Screen and StandBy
// widgets (Today's tasks with tappable completion, Next Meeting) and Control
// Center controls (New Note, New Task, Start Recording). Lives outside
// Scribe/ because SwiftPM compiles every file under Scribe/ into the Mac app's
// executable target; built only by Xcode (project.yml → ScribeiOSWidgets) and
// embedded in the iOS app. Data comes from the App Group snapshot the app
// writes (Scribe/Shared, compiled in here); the timeline provider and the
// task-toggle intent are the Mac widgets' portable files, listed in
// project.yml. The recording Live Activity is a separate extension.

import SwiftUI
import WidgetKit

@main
struct ScribeiOSWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ScribeiOSTodayWidget()
        ScribeiOSNextMeetingWidget()
        ScribeiOSNewNoteControl()
        ScribeiOSNewTaskControl()
        ScribeiOSRecordControl()
    }
}
