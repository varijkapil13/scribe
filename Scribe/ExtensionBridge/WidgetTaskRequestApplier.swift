// Scribe/ExtensionBridge/WidgetTaskRequestApplier.swift
//
// Applies the task completion toggles the Today widget queued in the App
// Group (`ScribeWidgetTaskRequest`). Runs at launch, on app activation, and
// as soon as a widget posts the Darwin notification while the app runs.
//
// Portable: also compiled into the iOS app (project.yml → ScribeiOS), where
// ScribeiOS/System/IOSSystemIntegration owns it and installs
// `darwinRequestHandler`.

import Foundation

@MainActor
final class WidgetTaskRequestApplier {

    private let queue: ScribeWidgetRequestQueue
    private let taskStore: TaskStore
    /// Called with the refreshed task after each change (production:
    /// reminder bookkeeping; tests: a no-op, so no notification center).
    private let onTaskChanged: @MainActor (TodoTask) -> Void
    private var isObserving = false

    #if !os(macOS)
    /// iOS: what the Darwin notification runs (the Mac routes it through
    /// `ScribeExtensionsBridge`). Installed by IOSSystemIntegration.
    static var darwinRequestHandler: (@MainActor () -> Void)?
    #endif

    init(
        queue: ScribeWidgetRequestQueue,
        taskStore: TaskStore,
        onTaskChanged: @escaping @MainActor (TodoTask) -> Void
    ) {
        self.queue = queue
        self.taskStore = taskStore
        self.onTaskChanged = onTaskChanged
    }

    /// Same reminder bookkeeping as the Complete Task intent: cancel when
    /// done, (re)schedule when still open (recurring advance / undo).
    static func rescheduleReminder(for task: TodoTask) {
        Task {
            if task.isCompleted {
                await TaskReminderScheduler.shared.cancel(taskId: task.id)
            } else {
                await TaskReminderScheduler.shared.schedule(task)
            }
        }
    }

    /// What applying one request should do to the task.
    enum Action: Equatable {
        case complete
        case uncomplete
        case noChange
    }

    /// Pure decision: only change a task whose state differs from the
    /// request (so a stale double-tap never logs a second completion).
    nonisolated static func action(for request: ScribeWidgetTaskRequest, task: TodoTask?) -> Action {
        guard let task, !task.isCancelled else { return .noChange }
        if request.isCompleted && !task.isCompleted { return .complete }
        if !request.isCompleted && task.isCompleted { return .uncomplete }
        return .noChange
    }

    /// Drains the queue and applies each task's latest request. Returns the
    /// number of tasks changed.
    @discardableResult
    func drain() -> Int {
        let requests = ScribeWidgetTaskRequest.latestPerTask(queue.drain())
        var changed = 0
        for request in requests {
            do {
                let task = try taskStore.fetchTask(id: request.taskId)
                switch Self.action(for: request, task: task) {
                case .complete:
                    try taskStore.completeTask(id: request.taskId)
                    changed += 1
                    notifyChanged(taskId: request.taskId)
                case .uncomplete:
                    try taskStore.uncompleteTask(id: request.taskId)
                    changed += 1
                    notifyChanged(taskId: request.taskId)
                case .noChange:
                    break
                }
            } catch {
                Log.app.error("Widget task request failed: \(error.localizedDescription, privacy: .private)")
            }
        }
        return changed
    }

    private func notifyChanged(taskId: String) {
        guard let refreshed = try? taskStore.fetchTask(id: taskId) else { return }
        onTaskChanged(refreshed)
    }

    // MARK: - Darwin notification

    /// Drains whenever a widget posts `ScribeAppGroup.widgetRequestNotificationName`.
    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        Self.addDarwinObserver(observer: Unmanaged.passUnretained(self).toOpaque())
    }

    /// Routes the Darwin notification to the platform's extensions bridge.
    static func darwinNotificationArrived() {
        #if os(macOS)
        ScribeExtensionsBridge.shared.widgetRequestsArrived()
        #else
        darwinRequestHandler?()
        #endif
    }

    /// Isolated CoreFoundation call (the one C-API touch point here). The
    /// callback is a capture-free C function pointer: it hops to the main
    /// actor and drains the shared bridge's applier. `observer` only
    /// identifies the registration; the object lives for the app's lifetime.
    nonisolated private static func addDarwinObserver(observer: UnsafeMutableRawPointer) {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            UnsafeRawPointer(observer),
            { _, _, _, _, _ in
                let hop = Task { @MainActor in
                    WidgetTaskRequestApplier.darwinNotificationArrived()
                }
                _ = hop
            },
            ScribeAppGroup.widgetRequestNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }
}
