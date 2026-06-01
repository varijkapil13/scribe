import Foundation
import SwiftUI

/// Hot-swap orchestrator for the markdown notes vault.
///
/// Owns the long-lived `NoteVaultWatcher` and the per-launch
/// `NoteIndexReconciler`, and exposes two user-facing actions:
///
/// - `moveVault(to:)` — physically relocates every file from the current
///   vault to a new (empty / non-existent) folder. The DB stays put.
/// - `openVault(at:)` — points Scribe at an existing folder without
///   moving anything. The reconciler will import whatever's at the new
///   location and remove DB rows for note ids not present there.
///
/// Both swap `NoteStore.shared`'s file store under its lock, stop and
/// restart the watcher, and run a single reconcile pass against the
/// new location. The user preference at `NotesDirectory.userPreferenceKey`
/// is updated so the swap survives a relaunch.
@MainActor
final class VaultCoordinator: ObservableObject {

    static let shared = VaultCoordinator()

    @Published private(set) var currentRoot: URL?
    /// True while a move / open is in flight so Settings can disable
    /// buttons and surface a spinner.
    @Published private(set) var isBusy: Bool = false
    /// Surfaces the last fatal error so Settings can show it inline
    /// without taking down the app. Cleared on the next successful swap.
    @Published var lastError: String?

    enum VaultError: LocalizedError {
        case destinationIsCurrentVault
        case destinationNotEmpty(URL)
        case destinationInsideCurrent
        case destinationDoesNotExist(URL)
        case noActiveFileStore

        var errorDescription: String? {
            switch self {
            case .destinationIsCurrentVault: return "That is already the current vault."
            case .destinationNotEmpty(let url): return "\(url.lastPathComponent) is not empty — pick an empty folder or one that doesn't exist yet."
            case .destinationInsideCurrent: return "The destination can't be inside the current vault."
            case .destinationDoesNotExist(let url): return "\(url.path) doesn't exist."
            case .noActiveFileStore: return "Scribe doesn't have an active vault — restart and try again."
            }
        }
    }

    private let noteStore: NoteStore
    private let dbManager: DatabaseManager
    private var watcher: NoteVaultWatcher?

    init(noteStore: NoteStore = .shared, dbManager: DatabaseManager = .shared) {
        self.noteStore = noteStore
        self.dbManager = dbManager
        self.currentRoot = noteStore.fileStore?.directory.root
    }

    // MARK: - Lifecycle

    /// Bootstrap the watcher + run an initial reconcile against the
    /// current vault. Called once at app launch by `AppDelegate`.
    func start() {
        guard let fileStore = noteStore.fileStore else { return }
        runReconcile(with: fileStore, label: "launch")
        startWatcher(for: fileStore)
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    // MARK: - Move

    /// Copies every file from the current vault into `destination` and
    /// re-points Scribe there. `destination` must be empty or
    /// non-existent. Returns the number of files moved (for caller-side
    /// logging / UI) — does not throw on per-file failure mid-flight;
    /// failures are logged and the caller can rerun.
    @discardableResult
    func moveVault(to destination: URL) async throws -> Int {
        guard let oldStore = noteStore.fileStore else { throw VaultError.noActiveFileStore }
        let oldRoot = oldStore.directory.root
        try validate(destination: destination, against: oldRoot, isOpen: false)

        isBusy = true
        defer { isBusy = false }

        let moved = try await Task.detached(priority: .userInitiated) {
            try Self.copyTree(from: oldRoot, to: destination)
        }.value

        swapFileStore(to: destination)
        runReconcile(with: noteStore.fileStore!, label: "move")
        restartWatcher(for: noteStore.fileStore!)
        UserDefaults.standard.set(destination.path, forKey: NotesDirectory.userPreferenceKey)
        currentRoot = destination

        // Best-effort: tear down the source tree once everything is
        // healthy at the destination. If this fails the user is left
        // with two copies — recoverable, just confusing.
        await Task.detached(priority: .background) {
            try? FileManager.default.removeItem(at: oldRoot)
        }.value

        return moved
    }

    // MARK: - Open

    /// Points Scribe at an existing folder. The current vault is left
    /// untouched on disk. The reconciler imports whatever's at the new
    /// location and removes DB rows for note ids not present there —
    /// callers should warn the user before invoking.
    func openVault(at destination: URL) async throws {
        guard let oldStore = noteStore.fileStore else { throw VaultError.noActiveFileStore }
        try validate(destination: destination, against: oldStore.directory.root, isOpen: true)

        isBusy = true
        defer { isBusy = false }

        swapFileStore(to: destination)
        runReconcile(with: noteStore.fileStore!, label: "open")
        restartWatcher(for: noteStore.fileStore!)
        UserDefaults.standard.set(destination.path, forKey: NotesDirectory.userPreferenceKey)
        currentRoot = destination
    }

    /// Returns the diff a hypothetical reconcile would produce against
    /// `destination` so the UI can show "X imported, Y removed" before
    /// the user commits to opening. Read-only; does not touch the DB.
    func previewOpen(at destination: URL) throws -> (toImport: Int, toRemove: Int) {
        let preview = NoteFileStore(directory: NotesDirectory(root: destination))
        let onDiskIds = Set((try preview.listAll()).map(\.id))
        let inDbIds: Set<String> = try Set(
            dbManager.database.read { db in
                try String.fetchAll(db, sql: "SELECT id FROM notes")
            }
        )
        let toImport = onDiskIds.subtracting(inDbIds).count
        let toRemove = inDbIds.subtracting(onDiskIds).count
        return (toImport, toRemove)
    }

    // MARK: - Validation

    private func validate(destination: URL, against currentRoot: URL, isOpen: Bool) throws {
        // Normalize both sides — currentRoot is realpath-canonicalized at
        // NotesDirectory.init, but the destination URL handed in by the
        // NSOpenPanel / test may still carry macOS's `/var → /private/var`
        // alias. Strip the `/private` prefix from both sides so the
        // hasPrefix check compares apples to apples.
        let current = Self.stripPrivatePrefix(currentRoot.standardizedFileURL.path)
        let dest = Self.stripPrivatePrefix(destination.standardizedFileURL.path)
        if dest == current {
            throw VaultError.destinationIsCurrentVault
        }
        if dest.hasPrefix(current + "/") {
            throw VaultError.destinationInsideCurrent
        }
        let fm = FileManager.default
        if isOpen {
            guard fm.fileExists(atPath: destination.path) else {
                throw VaultError.destinationDoesNotExist(destination)
            }
        } else {
            // Move: destination must be empty or absent.
            if fm.fileExists(atPath: destination.path) {
                let contents = (try? fm.contentsOfDirectory(atPath: destination.path)) ?? []
                let visible = contents.filter { !$0.hasPrefix(".") }
                if !visible.isEmpty {
                    throw VaultError.destinationNotEmpty(destination)
                }
            }
        }
    }

    // MARK: - Internals

    private func swapFileStore(to root: URL) {
        let directory = NotesDirectory(root: root)
        let newStore = NoteFileStore(directory: directory)
        noteStore.setFileStore(newStore)
    }

    private func runReconcile(with fileStore: NoteFileStore, label: String) {
        let reconciler = NoteIndexReconciler(fileStore: fileStore, dbManager: dbManager)
        do {
            let (upserted, removed) = try reconciler.reconcile()
            if upserted > 0 || removed > 0 {
                Log.storage.info("VaultCoordinator(\(label, privacy: .public)): upserted=\(upserted) removed=\(removed)")
            }
            lastError = nil
        } catch {
            Log.storage.error("VaultCoordinator(\(label, privacy: .public)) reconcile failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    private func startWatcher(for fileStore: NoteFileStore) {
        watcher?.stop()
        let root = fileStore.directory.root
        let reconciler = NoteIndexReconciler(fileStore: fileStore, dbManager: dbManager)
        watcher = NoteVaultWatcher(root: root) {
            // Skip reconciles caused by Scribe's own writes (autosave). The
            // in-process write already updated the DB/index; reconciling here
            // is wasted work and, mid-edit, a write-amplification hazard.
            // External edits inside the window are caught by the next tick.
            if VaultWriteGuard.shared.isWithinSelfWriteWindow() {
                return
            }
            // Watcher callback can fire on any queue — hop to MainActor
            // for state updates, but keep the reconcile (which is purely
            // DB + disk) off main.
            Task.detached(priority: .utility) {
                do {
                    let (u, r) = try reconciler.reconcile()
                    if u > 0 || r > 0 {
                        Log.storage.info("Vault watcher: upserted=\(u) removed=\(r)")
                    }
                } catch {
                    Log.storage.error("Vault watcher reconcile failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        watcher?.start()
    }

    private func restartWatcher(for fileStore: NoteFileStore) {
        startWatcher(for: fileStore)
    }

    /// Strip macOS's `/private` symlink alias for path comparisons.
    /// `/private/var/folders/X` and `/var/folders/X` are the same place
    /// on disk; either form can appear depending on how a URL was
    /// constructed (NSOpenPanel vs realpath). Tests and production both
    /// hit this drift.
    private static func stripPrivatePrefix(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    /// Recursive copy used by `moveVault`. Keeps the directory tree
    /// (Daily/, attachments/, anything else) intact. Returns the
    /// number of regular files copied — folders aren't counted.
    nonisolated static func copyTree(from source: URL, to destination: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: source.path) else { return 0 }

        var copied = 0
        let enumerator = fm.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            let relative = url.path.replacingOccurrences(of: source.path + "/", with: "")
            guard !relative.isEmpty else { continue }
            let target = destination.appendingPathComponent(relative)
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
            if resourceValues.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }
                try fm.copyItem(at: url, to: target)
                copied += 1
            }
        }
        return copied
    }
}
