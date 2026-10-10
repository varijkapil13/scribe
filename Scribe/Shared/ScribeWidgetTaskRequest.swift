// Scribe/Shared/ScribeWidgetTaskRequest.swift
//
// Widget → app: "mark this task done / not done". The widget extension can't
// open the app's database, so its toggle intent queues a request file in the
// App Group container and the app applies it (on activation, at launch, and
// immediately when it's running via a Darwin notification). Shared with the
// ScribeWidgets extension; Foundation-only.

import Foundation

struct ScribeWidgetTaskRequest: Codable, Equatable, Sendable {
    var id: String
    var taskId: String
    var isCompleted: Bool
    var requestedAt: Date

    init(id: String = UUID().uuidString, taskId: String, isCompleted: Bool, requestedAt: Date) {
        self.id = id
        self.taskId = taskId
        self.isCompleted = isCompleted
        self.requestedAt = requestedAt
    }

    /// Collapses a batch to one desired state per task: the latest request
    /// (by `requestedAt`, then queue order) wins, so a quick done → undone
    /// double tap ends up undone. Result is ordered by task id.
    static func latestPerTask(_ requests: [ScribeWidgetTaskRequest]) -> [ScribeWidgetTaskRequest] {
        var latest: [String: ScribeWidgetTaskRequest] = [:]
        for request in requests {
            if let existing = latest[request.taskId], existing.requestedAt > request.requestedAt {
                continue
            }
            latest[request.taskId] = request
        }
        return latest.values.sorted { $0.taskId < $1.taskId }
    }
}

/// The `WidgetRequests/` folder: one JSON file per request.
struct ScribeWidgetRequestQueue: Sendable {

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The queue inside `container` (the App Group container in production).
    init(container: URL) {
        self.directory = container.appendingPathComponent(ScribeAppGroup.widgetRequestsFolderName, isDirectory: true)
    }

    static func appGroup() -> ScribeWidgetRequestQueue? {
        ScribeAppGroup.containerURL().map { ScribeWidgetRequestQueue(container: $0) }
    }

    func enqueue(_ request: ScribeWidgetTaskRequest) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(request.id).json", isDirectory: false)
        try ScribeAppGroup.makeEncoder().encode(request).write(to: file, options: .atomic)
    }

    /// Reads and removes every queued request, oldest first. Unreadable
    /// files are removed too (they can never be applied).
    func drain() -> [ScribeWidgetTaskRequest] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let decoder = ScribeAppGroup.makeDecoder()
        var requests: [(ScribeWidgetTaskRequest, String)] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let request = try? decoder.decode(ScribeWidgetTaskRequest.self, from: data) {
                requests.append((request, file.lastPathComponent))
            }
            try? fm.removeItem(at: file)
        }
        return requests
            .sorted { lhs, rhs in
                lhs.0.requestedAt == rhs.0.requestedAt ? lhs.1 < rhs.1 : lhs.0.requestedAt < rhs.0.requestedAt
            }
            .map { $0.0 }
    }
}
