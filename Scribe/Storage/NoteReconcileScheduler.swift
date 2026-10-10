import Foundation

/// Serialises and coalesces vault reconciles.
///
/// Every request lands on one private serial queue (never the main actor).
/// While a pass is running, further requests only set a dirty flag; when the
/// pass finishes, exactly one follow-up pass runs if anything was requested
/// in the meantime. A burst of watcher events therefore costs at most two
/// passes, and two passes never run concurrently against the same database.
final class NoteReconcileScheduler: @unchecked Sendable {

    typealias Completion = @Sendable (Result<NoteReconcileResult, Error>) -> Void

    private let reconciler: NoteIndexReconciler
    private let onComplete: Completion
    /// One queue for every scheduler, so a pass still running against a
    /// previous vault always finishes before the first pass of the next one.
    private static let queue = DispatchQueue(label: "com.varij.scribe.note-reconcile", qos: .utility)
    private var queue: DispatchQueue { Self.queue }

    private let lock = NSLock()
    private var isRunning = false
    private var isDirty = false
    private var isInvalidated = false

    init(reconciler: NoteIndexReconciler, onComplete: @escaping Completion) {
        self.reconciler = reconciler
        self.onComplete = onComplete
    }

    var fileStore: NoteFileStore { reconciler.fileStore }

    /// Asks for a pass. Returns immediately; the pass runs on the
    /// scheduler's queue and reports through `onComplete`.
    func requestReconcile() {
        lock.lock()
        if isInvalidated {
            lock.unlock()
            return
        }
        if isRunning {
            isDirty = true
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()
        queue.async { [self] in
            self.drain()
        }
    }

    /// Runs one pass synchronously on the scheduler's queue (after any pass
    /// already in flight) and returns its result. Call off the main actor.
    func reconcileNow() throws -> NoteReconcileResult {
        try queue.sync {
            try reconciler.reconcileDetailed()
        }
    }

    /// Stops this scheduler for good (the vault it serves was swapped out):
    /// pending and future requests are dropped.
    func invalidate() {
        lock.lock()
        isInvalidated = true
        lock.unlock()
    }

    private func drain() {
        while true {
            lock.lock()
            if isInvalidated {
                isRunning = false
                lock.unlock()
                return
            }
            isDirty = false
            lock.unlock()

            let result: Result<NoteReconcileResult, Error> = Result {
                try reconciler.reconcileDetailed()
            }
            onComplete(result)

            lock.lock()
            if isDirty {
                lock.unlock()
                continue
            }
            isRunning = false
            lock.unlock()
            return
        }
    }
}

/// Posted on the main thread after a watcher-driven reconcile found note
/// files whose content changed outside Scribe. `userInfo[noteIdsKey]` is a
/// `Set<String>` of the affected note ids.
enum NoteVaultChange {
    static let noteIdsKey = "noteIds"

    nonisolated static func noteIds(from notification: Notification) -> Set<String>? {
        notification.userInfo?[noteIdsKey] as? Set<String>
    }
}

extension Notification.Name {
    static let noteVaultFilesChanged = Notification.Name("ScribeNoteVaultFilesChanged")
}
