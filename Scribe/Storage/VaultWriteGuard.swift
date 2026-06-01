import Foundation

/// Coordinates Scribe's own vault writes with the FSEvents watcher so that
/// autosave (every keystroke in the notes editor, every field change in the
/// task inspector) can't trip the app's own `NoteIndexReconciler`.
///
/// `NoteVaultWatcher`'s callback is path-less — it only signals "something
/// under the vault changed" — so suppression is by a short *time window*
/// rather than by path: every self-write stamps `lastSelfWrite`, and the
/// watcher skips its reconcile while it is within `window` of that stamp.
/// Because Scribe's own writes already updated the DB/index in-process, the
/// reconcile they would trigger is pure waste (and, mid-edit, a hazard).
///
/// External edits (Obsidian, iCloud sync) that land *inside* the window are
/// not lost — they are picked up by the next watcher tick once the window
/// lapses, and by the defensive launch / app-resume reconcile.
final class VaultWriteGuard: @unchecked Sendable {

    static let shared = VaultWriteGuard()

    private let lock = NSLock()
    private var lastSelfWrite: Date = .distantPast

    /// Suppression window. Must comfortably exceed `NoteVaultWatcher`'s
    /// FSEvents latency (~0.5s) so the event a self-write produces falls
    /// inside it, but stay tight enough that genuine external edits aren't
    /// ignored for long.
    private let window: TimeInterval

    init(window: TimeInterval = 1.0) {
        self.window = window
    }

    /// Stamp that Scribe itself just wrote to (or deleted from) the vault.
    /// Call immediately before every app-initiated `NoteFileStore` mutation.
    func recordSelfWrite(at time: Date = Date()) {
        lock.lock()
        lastSelfWrite = time
        lock.unlock()
    }

    /// True when a self-write happened within the suppression window — the
    /// watcher should skip its reconcile because the in-process write already
    /// kept the index in sync.
    func isWithinSelfWriteWindow(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return now.timeIntervalSince(lastSelfWrite) < window
    }
}
