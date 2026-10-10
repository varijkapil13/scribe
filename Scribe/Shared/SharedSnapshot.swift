// Scribe/Shared/SharedSnapshot.swift
//
// The small, Codable picture of "right now" the app hands to its widgets via
// the App Group container. Shared with the ScribeWidgets extension (see
// project.yml); Foundation-only.

import Foundation

/// What the widgets show: today's top tasks, the next few calendar meetings
/// and whether a recording is running. Written by the app
/// (`WidgetSnapshotPublisher`), read by the widget timeline provider.
struct ScribeSharedSnapshot: Codable, Equatable, Sendable {

    static let currentVersion = 1
    static let maxTasks = 8
    static let maxMeetings = 3

    enum Priority: String, Codable, Sendable, Hashable {
        case high
        case medium
        case low
    }

    struct TaskItem: Codable, Equatable, Sendable, Hashable, Identifiable {
        var id: String
        var title: String
        var due: Date?
        var priority: Priority?
        var isCompleted: Bool

        init(id: String, title: String, due: Date?, priority: Priority?, isCompleted: Bool) {
            self.id = id
            self.title = title
            self.due = due
            self.priority = priority
            self.isCompleted = isCompleted
        }
    }

    struct Meeting: Codable, Equatable, Sendable, Hashable, Identifiable {
        var id: String
        var title: String
        var start: Date
        var end: Date

        init(id: String, title: String, start: Date, end: Date) {
            self.id = id
            self.title = title
            self.start = start
            self.end = end
        }

        func isInProgress(at now: Date) -> Bool {
            start <= now && now < end
        }
    }

    struct RecordingState: Codable, Equatable, Sendable {
        var isRecording: Bool
        var startedAt: Date?

        init(isRecording: Bool, startedAt: Date?) {
            self.isRecording = isRecording
            self.startedAt = startedAt
        }

        static var idle: RecordingState { RecordingState(isRecording: false, startedAt: nil) }
    }

    var version: Int
    var generatedAt: Date
    var tasks: [TaskItem]
    var meetings: [Meeting]
    var recording: RecordingState

    /// Memberwise; prefer `make(…)`, which applies the size limits.
    init(version: Int, generatedAt: Date, tasks: [TaskItem], meetings: [Meeting], recording: RecordingState) {
        self.version = version
        self.generatedAt = generatedAt
        self.tasks = tasks
        self.meetings = meetings
        self.recording = recording
    }

    /// Builds a snapshot from already-ordered tasks and any meetings: keeps
    /// the first `maxTasks` tasks, and the `maxMeetings` soonest meetings that
    /// haven't ended by `now` (in-progress ones included).
    static func make(
        now: Date,
        tasks: [TaskItem],
        meetings: [Meeting],
        recording: RecordingState
    ) -> ScribeSharedSnapshot {
        let upcoming = meetings
            .filter { $0.end > now }
            .sorted { lhs, rhs in
                lhs.start == rhs.start ? lhs.title < rhs.title : lhs.start < rhs.start
            }
        return ScribeSharedSnapshot(
            version: currentVersion,
            generatedAt: now,
            tasks: Array(tasks.prefix(maxTasks)),
            meetings: Array(upcoming.prefix(maxMeetings)),
            recording: recording
        )
    }

    /// An empty snapshot (widget placeholder / nothing written yet).
    static func empty(at now: Date) -> ScribeSharedSnapshot {
        ScribeSharedSnapshot(version: currentVersion, generatedAt: now, tasks: [], meetings: [], recording: .idle)
    }

    /// The first meeting that hasn't ended at `now`.
    func nextMeeting(at now: Date) -> Meeting? {
        meetings.first { $0.end > now }
    }

    /// Optimistic local update after a widget toggles a task, so the widget
    /// reflects the tap before the app has applied it.
    func applyingCompletion(taskId: String, isCompleted: Bool) -> ScribeSharedSnapshot {
        var copy = self
        copy.tasks = tasks.map { item in
            guard item.id == taskId else { return item }
            var updated = item
            updated.isCompleted = isCompleted
            return updated
        }
        return copy
    }

    /// Equal apart from `generatedAt` — the app skips rewriting (and
    /// reloading every widget timeline) when nothing visible changed.
    func hasSameContent(as other: ScribeSharedSnapshot) -> Bool {
        version == other.version
            && tasks == other.tasks
            && meetings == other.meetings
            && recording == other.recording
    }

    // MARK: - Coding

    func encoded() throws -> Data {
        try ScribeAppGroup.makeEncoder().encode(self)
    }

    static func decode(_ data: Data) throws -> ScribeSharedSnapshot {
        try ScribeAppGroup.makeDecoder().decode(ScribeSharedSnapshot.self, from: data)
    }
}

/// Reads / writes `widget-snapshot.json` in a directory (the App Group
/// container in production, a temp folder in tests).
struct ScribeSharedSnapshotStore: Sendable {

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The store in the App Group container, or nil when it's unavailable.
    static func appGroup() -> ScribeSharedSnapshotStore? {
        ScribeAppGroup.containerURL().map { ScribeSharedSnapshotStore(directory: $0) }
    }

    var fileURL: URL {
        directory.appendingPathComponent(ScribeAppGroup.snapshotFileName, isDirectory: false)
    }

    func write(_ snapshot: ScribeSharedSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try snapshot.encoded().write(to: fileURL, options: .atomic)
    }

    /// The stored snapshot; nil when missing or unreadable.
    func read() -> ScribeSharedSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? ScribeSharedSnapshot.decode(data)
    }
}
