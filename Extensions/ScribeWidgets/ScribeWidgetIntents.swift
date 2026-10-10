// Extensions/ScribeWidgets/ScribeWidgetIntents.swift
//
// App Intents that run inside the widget extension process. The extension
// can't touch Scribe's database, so the task toggle queues a request in the
// App Group (applied by the app's WidgetTaskRequestApplier) and updates the
// shared snapshot optimistically so the widget reflects the tap at once.

import AppIntents
import Foundation
import WidgetKit

struct ToggleScribeWidgetTaskIntent: AppIntent {

    static var title: LocalizedStringResource { "Toggle Scribe Task" }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Task ID")
    var taskId: String

    @Parameter(title: "Completed")
    var isCompleted: Bool

    init() {}

    init(taskId: String, isCompleted: Bool) {
        self.taskId = taskId
        self.isCompleted = isCompleted
    }

    func perform() async throws -> some IntentResult {
        let id = taskId
        let completed = isCompleted
        guard let container = ScribeAppGroup.containerURL() else { return .result() }

        let request = ScribeWidgetTaskRequest(taskId: id, isCompleted: completed, requestedAt: Date())
        try ScribeWidgetRequestQueue(container: container).enqueue(request)

        let store = ScribeSharedSnapshotStore(directory: container)
        if let snapshot = store.read() {
            try? store.write(snapshot.applyingCompletion(taskId: id, isCompleted: completed))
        }

        ScribeAppGroup.postWidgetRequestNotification()
        return .result()
    }
}

/// The Control Center "Start Recording" button: opens
/// scribe://record/start, which the app routes like any other deep link.
struct OpenScribeRecordingIntent: AppIntent {

    static var title: LocalizedStringResource { "Start Scribe Recording" }
    static var isDiscoverable: Bool { false }

    init() {}

    func perform() async throws -> some IntentResult & OpensIntent {
        Self.openRecordStart()
    }

    /// Isolated so a signature change in the AppIntents URL-opening API is a
    /// one-line fix.
    private static func openRecordStart() -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(ScribeAppGroup.recordStartURL))
    }
}
