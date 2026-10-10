// ScribeiOS/System/Shared/ScribeiOSCaptureIntents.swift
//
// Capture intents shared by the iOS app AND the ScribeiOSWidgets extension
// (project.yml lists this folder in both). The Control Center controls and
// the Next Meeting widget's Record button need the types in the extension;
// because the app target contains them too and they open the app
// (`openAppWhenRun`), iOS runs `perform()` in the app process, where the
// capture sheet and the recorder live. The extension build defines
// SCRIBE_IOS_WIDGET_EXTENSION and leaves out the app-only calls.
//
// Also the Action button's "Quick Capture" (Settings → Action Button →
// Shortcut → Scribe → Quick Capture) and a Siri / Shortcuts action.

import AppIntents
import Foundation

/// Widget / control kinds of the iOS extension.
enum ScribeiOSWidgetKinds {
    static let today = ScribeAppGroup.todayWidgetKind
    static let nextMeeting = ScribeAppGroup.nextMeetingWidgetKind
    static let recordControl = ScribeAppGroup.recordControlKind
    static let newNoteControl = "com.varij.scribe.control.new-note"
    static let newTaskControl = "com.varij.scribe.control.new-task"
}

/// Note or task, for "Quick Capture".
enum ScribeCaptureKindAppEnum: String, AppEnum, CaseIterable, Sendable {
    case note
    case task

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Capture Type")
    }

    static var caseDisplayRepresentations: [ScribeCaptureKindAppEnum: DisplayRepresentation] {
        [
            .note: DisplayRepresentation(title: "Note", image: DisplayRepresentation.Image(systemName: "square.and.pencil")),
            .task: DisplayRepresentation(title: "Task", image: DisplayRepresentation.Image(systemName: "checklist")),
        ]
    }
}

/// Opens Scribe's capture sheet for a note or a task.
struct ScribeQuickCaptureIntent: AppIntent {

    static var title: LocalizedStringResource { "Quick Capture" }

    static var description: IntentDescription {
        IntentDescription("Opens Scribe's capture sheet to jot down a note or a task.")
    }

    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Capture", default: .note)
    var kind: ScribeCaptureKindAppEnum

    init() {}

    init(kind: ScribeCaptureKindAppEnum) {
        self.kind = kind
    }

    func perform() async throws -> some IntentResult {
        #if !SCRIBE_IOS_WIDGET_EXTENSION
        let requested = kind
        await ScribeiOSCaptureRouting.presentCapture(requested)
        #endif
        return .result()
    }
}

/// The Control Center "Start Recording" control and the Next Meeting
/// widget's Record button: opens Scribe and starts recording.
struct ScribeStartRecordingControlIntent: AppIntent {

    static var title: LocalizedStringResource { "Start Scribe Recording" }

    static var isDiscoverable: Bool { false }

    static var openAppWhenRun: Bool { true }

    init() {}

    func perform() async throws -> some IntentResult {
        #if !SCRIBE_IOS_WIDGET_EXTENSION
        await ScribeiOSCaptureRouting.startRecordingFromControl()
        #endif
        return .result()
    }
}
