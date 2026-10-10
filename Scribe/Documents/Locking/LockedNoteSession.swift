// Scribe/Documents/Locking/LockedNoteSession.swift
import AppKit
import Combine
import CryptoKit
import Foundation

extension Notification.Name {
    /// Posted (synchronously, on the main thread) right before locked notes
    /// lock again. Open editors save and drop their plaintext.
    static let scribeLockedNotesWillLock = Notification.Name("scribe.lockedNotesWillLock")
}

/// Pure re-lock timing.
enum LockedNoteRelockPolicy {
    static let idleMinutesKey = "lockedNotes.idleMinutes"
    static let defaultIdleMinutes = 5
    static let idleMinuteChoices = [1, 5, 15, 60]

    /// True when the key has been idle for at least `idleMinutes`.
    nonisolated static func shouldLock(lastActivity: Date, now: Date, idleMinutes: Int) -> Bool {
        let minutes = max(1, idleMinutes)
        return now.timeIntervalSince(lastActivity) >= TimeInterval(minutes * 60)
    }
}

/// Holds the locked-notes key in memory while notes are unlocked, and
/// throws it away again — after `idleMinutes` without activity, when the
/// Mac sleeps, the screen locks or the user switches away, and when a window
/// closes. Plaintext of locked notes never leaves memory; editors drop it on
/// `scribeLockedNotesWillLock`.
@MainActor
final class LockedNoteSession: ObservableObject {

    static let shared = LockedNoteSession()

    @Published private(set) var isUnlocked = false

    private var key: SymmetricKey?
    private var lastActivity = Date()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var windowCloseCancellable: AnyCancellable?

    private init() {}

    /// Installs the re-lock triggers. Idempotent.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 20, repeats: true) { _ in
            Task { @MainActor in LockedNoteSession.shared.lockIfIdle() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { LockedNoteSession.shared.lock() }
            })
        }
        // The screen saver / screen lock.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { LockedNoteSession.shared.lock() }
        })
        // Closing a document window (a titled, non-panel, non-sheet window:
        // the main window or a note window) locks again. Same Combine pattern
        // as `AppDelegate.observeMainWindowClose`.
        windowCloseCancellable = NotificationCenter.default
            .publisher(for: NSWindow.willCloseNotification)
            .receive(on: RunLoop.main)
            .sink { notification in
                guard let window = notification.object as? NSWindow,
                      Self.isDocumentWindow(window) else { return }
                LockedNoteSession.shared.lock()
            }
    }

    /// True for the windows whose closing re-locks notes: titled windows
    /// that aren't panels (open/save panels, inspectors, popovers) or sheets.
    private static func isDocumentWindow(_ window: NSWindow) -> Bool {
        guard !(window is NSPanel), window.sheetParent == nil else { return false }
        return window.styleMask.contains(.titled)
    }

    var idleMinutes: Int {
        let stored = UserDefaults.standard.integer(forKey: LockedNoteRelockPolicy.idleMinutesKey)
        return stored > 0 ? stored : LockedNoteRelockPolicy.defaultIdleMinutes
    }

    /// The in-memory key while unlocked (counts as activity).
    func currentKey() -> SymmetricKey? {
        guard let key else { return nil }
        lastActivity = Date()
        return key
    }

    /// Any editing of an unlocked note postpones the idle re-lock.
    func noteActivity() {
        if key != nil { lastActivity = Date() }
    }

    /// Returns the key, asking for Touch ID / the password when it isn't in
    /// memory. `creatingKeyIfNeeded` creates the per-Mac key on first use
    /// (locking the first note).
    func unlock(reason: String, creatingKeyIfNeeded: Bool) async throws -> SymmetricKey {
        if let key = currentKey() { return key }
        try await LockedNoteKeychain.authenticate(reason: reason)
        // A single small Keychain read (or write); fine on the main actor.
        guard let loaded = try LockedNoteKeychain.key(creatingIfNeeded: creatingKeyIfNeeded) else {
            throw LockedNoteEnvelopeError.wrongKey
        }
        key = loaded
        lastActivity = Date()
        isUnlocked = true
        return loaded
    }

    /// Locks every unlocked note now.
    func lock() {
        guard key != nil else { return }
        NotificationCenter.default.post(name: .scribeLockedNotesWillLock, object: nil)
        key = nil
        isUnlocked = false
    }

    private func lockIfIdle() {
        guard key != nil,
              LockedNoteRelockPolicy.shouldLock(lastActivity: lastActivity, now: Date(), idleMinutes: idleMinutes)
        else { return }
        lock()
    }
}
