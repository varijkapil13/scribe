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
        case copyIncomplete(String)

        var errorDescription: String? {
            switch self {
            case .destinationIsCurrentVault: return "That is already the current vault."
            case .destinationNotEmpty(let url): return "\(url.lastPathComponent) is not empty — pick an empty folder or one that doesn't exist yet."
            case .destinationInsideCurrent: return "The destination can't be inside the current vault."
            case .destinationDoesNotExist(let url): return "\(url.path) doesn't exist."
            case .noActiveFileStore: return "Scribe doesn't have an active vault — restart and try again."
            case .copyIncomplete(let path): return "\(path) didn't copy to the new location, so the old vault was left untouched."
            }
        }
    }

    private let noteStore: NoteStore
    private let dbManager: DatabaseManager
    private var watcher: NoteVaultWatcher?
    /// Serial, coalescing reconciler for the current vault. Replaced on
    /// every vault swap.
    private var scheduler: NoteReconcileScheduler?

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
        let scheduler = makeScheduler(for: fileStore)
        startWatcher(for: fileStore, scheduler: scheduler)
        // Off the main actor; the notes list updates through DB observation.
        scheduler.requestReconcile()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        scheduler?.invalidate()
        scheduler = nil
    }

    // MARK: - Move

    /// Copies every item from the current vault — hidden folders such as
    /// `.obsidian` and `.git` included — into `destination` and re-points
    /// Scribe there. `destination` must be empty or non-existent. The old
    /// vault is removed (moved to the Trash) only after every item is
    /// verified at the destination; any copy error or verification miss
    /// throws and leaves the old vault untouched and active. Returns the
    /// number of files copied.
    @discardableResult
    func moveVault(to destination: URL) async throws -> Int {
        guard let oldStore = noteStore.fileStore else { throw VaultError.noActiveFileStore }
        let oldRoot = oldStore.directory.root
        try validate(destination: destination, against: oldRoot, isOpen: false)

        isBusy = true
        defer { isBusy = false }

        let (moved, missing): (Int, String?) = try await Task.detached(priority: .userInitiated) {
            let copied = try Self.copyTree(from: oldRoot, to: destination)
            return (copied, Self.firstMissingItem(from: oldRoot, in: destination))
        }.value
        if let missing {
            throw VaultError.copyIncomplete(missing)
        }

        let newStore = swapFileStore(to: destination)
        await reconcileAndWatch(newStore, label: "move")
        UserDefaults.standard.set(destination.path, forKey: NotesDirectory.userPreferenceKey)
        currentRoot = destination

        // Every item was verified at the destination, so the source can go.
        // Trash rather than unlink, so even this step is recoverable.
        await Task.detached(priority: .background) {
            do {
                try NoteFileStore.trashOrRemove(oldRoot)
            } catch {
                Log.storage.error("VaultCoordinator: couldn't remove old vault: \(error.localizedDescription, privacy: .public)")
            }
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

        let newStore = swapFileStore(to: destination)
        await reconcileAndWatch(newStore, label: "open")
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

    @discardableResult
    private func swapFileStore(to root: URL) -> NoteFileStore {
        let directory = NotesDirectory(root: root)
        let newStore = NoteFileStore(directory: directory)
        noteStore.setFileStore(newStore)
        return newStore
    }

    /// Runs a full reconcile of `fileStore` off the main actor (waiting for
    /// it), then (re)starts the watcher on it.
    private func reconcileAndWatch(_ fileStore: NoteFileStore, label: String) async {
        let scheduler = makeScheduler(for: fileStore)
        let outcome: Result<NoteReconcileResult, Error> = await Task.detached(priority: .userInitiated) {
            Result { try scheduler.reconcileNow() }
        }.value
        handle(outcome, label: label)
        startWatcher(for: fileStore, scheduler: scheduler)
    }

    private func makeScheduler(for fileStore: NoteFileStore) -> NoteReconcileScheduler {
        self.scheduler?.invalidate()
        let reconciler = NoteIndexReconciler(fileStore: fileStore, dbManager: dbManager)
        let scheduler = NoteReconcileScheduler(reconciler: reconciler) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.handle(result, label: "watcher")
            }
        }
        self.scheduler = scheduler
        return scheduler
    }

    private func handle(_ result: Result<NoteReconcileResult, Error>, label: String) {
        switch result {
        case .success(let r):
            if r.upserted > 0 || r.removed > 0 || r.pinned > 0 {
                Log.storage.info("VaultCoordinator(\(label, privacy: .public)): upserted=\(r.upserted) removed=\(r.removed) pinned=\(r.pinned)")
            }
            lastError = nil
            if !r.changedNoteIds.isEmpty {
                NotificationCenter.default.post(
                    name: .noteVaultFilesChanged,
                    object: nil,
                    userInfo: [NoteVaultChange.noteIdsKey: r.changedNoteIds]
                )
            }
        case .failure(let error):
            Log.storage.error("VaultCoordinator(\(label, privacy: .public)) reconcile failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    private func startWatcher(for fileStore: NoteFileStore, scheduler: NoteReconcileScheduler) {
        watcher?.stop()
        let root = fileStore.directory.root
        let writeGuard = fileStore.writeGuard
        watcher = NoteVaultWatcher(root: root) { events in
            // Skip batches fully explained by Scribe's own writes (autosave,
            // renames, id pinning): each event's path must still hold
            // exactly what Scribe wrote there. Anything else — including an
            // external edit to the very file Scribe just saved — reconciles.
            let needed = VaultWriteGuard.requiresReconcile(
                events: events,
                root: root,
                isOwnWrite: { writeGuard.isOwnWrite(atPath: $0) }
            )
            if needed {
                scheduler.requestReconcile()
            }
        }
        watcher?.start()
    }

    /// Strip macOS's `/private` symlink alias for path comparisons.
    /// `/private/var/folders/X` and `/var/folders/X` are the same place
    /// on disk; either form can appear depending on how a URL was
    /// constructed (NSOpenPanel vs realpath). Tests and production both
    /// hit this drift.
    private static func stripPrivatePrefix(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    /// Recursive copy used by `moveVault`. Copies *everything* under
    /// `source` — hidden files and folders (`.obsidian`, `.git`,
    /// `.DS_Store`) included — keeping the tree intact. Returns the number
    /// of non-directory items copied. Throws on the first failure.
    nonisolated static func copyTree(from source: URL, to destination: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: source.path) else { return 0 }

        var copied = 0
        for (relative, isDirectory) in try treeItems(under: source) {
            let item = source.appendingPathComponent(relative)
            let target = destination.appendingPathComponent(relative)
            if isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }
                try fm.copyItem(at: item, to: target)
                copied += 1
            }
        }
        return copied
    }

    /// Verification for `moveVault`: the relative path of the first item
    /// under `source` that is missing at `destination` (or, for regular
    /// files, differs in size), or nil when everything arrived.
    nonisolated static func firstMissingItem(from source: URL, in destination: URL) -> String? {
        let fm = FileManager.default
        guard let items = try? treeItems(under: source) else { return source.lastPathComponent }
        for (relative, isDirectory) in items {
            let item = source.appendingPathComponent(relative)
            let target = destination.appendingPathComponent(relative)
            var targetIsDir: ObjCBool = false
            // Symlinks: compare the link itself, not what it points at.
            let targetLinkExists = (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil
            guard targetLinkExists || fm.fileExists(atPath: target.path, isDirectory: &targetIsDir) else {
                return relative
            }
            if isDirectory {
                if !targetIsDir.boolValue { return relative }
                continue
            }
            let sourceAttrs = try? fm.attributesOfItem(atPath: item.path)
            let targetAttrs = try? fm.attributesOfItem(atPath: target.path)
            if (sourceAttrs?[.type] as? FileAttributeType) == .typeRegular {
                let a = (sourceAttrs?[.size] as? NSNumber)?.int64Value
                let b = (targetAttrs?[.size] as? NSNumber)?.int64Value
                if a != b { return relative }
            }
        }
        return nil
    }

    /// Every item under `root` as `(relative path, is real directory)`,
    /// hidden ones included. Symlinked directories are reported as
    /// non-directories so they are copied as links, not followed.
    nonisolated static func treeItems(under root: URL) throws -> [(String, Bool)] {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = fm.enumerator(atPath: rootPath) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var out: [(String, Bool)] = []
        while let relative = enumerator.nextObject() as? String {
            let isDirectory = (enumerator.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory
            out.append((relative, isDirectory))
        }
        return out
    }
}
