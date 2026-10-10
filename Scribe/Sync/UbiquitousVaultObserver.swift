// Scribe/Sync/UbiquitousVaultObserver.swift
//
// D-Sync-2 for the iCloud vault: an `NSMetadataQuery` over the app's ubiquity
// container (`NSMetadataQueryUbiquitousDocumentsScope`) that
//
//   • reports files iCloud added / changed / removed under the vault root as
//     `NoteVaultEvent`s (same callback contract as the FSEvents watcher), so a
//     note edited on the Mac appears on iPhone / iPad and vice versa, and
//   • downloads non-local files on demand (`startDownloadingUbiquitousItem`):
//     iCloud may keep a file as a cloud-only placeholder; it is requested, and
//     when the download lands the query reports it current → a reconcile.
//
// The decision logic (`UbiquitousVaultChangePlanner`) is pure and unit-tested;
// the query wiring is ⚠️DEVICE (needs a signed-in iCloud account and the
// provisioned `iCloud.com.varij.scribe` container).
//
// Portable Foundation: compiled into the macOS app (unused there today — the
// Mac keeps FSEvents) and the iOS target.

import Foundation

/// The parts of one `NSMetadataItem` the planner needs, as a value.
struct UbiquitousVaultItem: Equatable, Sendable {
    /// Absolute file path.
    var path: String
    /// The local copy is the current version (`…DownloadingStatusCurrent`).
    var isCurrent: Bool
    /// A download is already in flight.
    var isDownloading: Bool

    init(path: String, isCurrent: Bool, isDownloading: Bool = false) {
        self.path = path
        self.isCurrent = isCurrent
        self.isDownloading = isDownloading
    }
}

/// Pure decisions for `UbiquitousVaultObserver`.
enum UbiquitousVaultChangePlanner {

    struct Plan: Equatable, Sendable {
        /// Watcher events to feed `VaultWriteGuard.requiresReconcile`.
        var events: [NoteVaultEvent]
        /// Paths to request with `startDownloadingUbiquitousItem`.
        var downloads: [String]
        /// Paths that are now current (no longer need tracking as requested).
        var completed: [String]
    }

    /// Plans one query update.
    ///
    /// - Items outside `root` or inside hidden folders / hidden files
    ///   (`.obsidian`, `.git`, `.Trash`, iCloud's own `.x.icloud` stubs) are
    ///   ignored.
    /// - A current item yields an event (the reconciler re-reads it).
    /// - A non-current item that isn't downloading and wasn't already
    ///   requested is scheduled for download; it yields no event yet — its
    ///   content isn't readable until the download completes, which the query
    ///   reports as another (current) update.
    /// - Every removed path yields an event (the note may have been deleted
    ///   on another device).
    nonisolated static func plan(
        changed: [UbiquitousVaultItem],
        removedPaths: [String],
        root: URL,
        alreadyRequested: Set<String>
    ) -> Plan {
        var events: [NoteVaultEvent] = []
        var downloads: [String] = []
        var completed: [String] = []
        var seenDownloads = Set<String>()

        for item in changed where isVaultPath(item.path, root: root) {
            if item.isCurrent {
                events.append(NoteVaultEvent(path: item.path))
                if alreadyRequested.contains(item.path) { completed.append(item.path) }
            } else if !item.isDownloading,
                      !alreadyRequested.contains(item.path),
                      seenDownloads.insert(item.path).inserted {
                downloads.append(item.path)
            }
        }
        for path in removedPaths where isVaultPath(path, root: root) {
            events.append(NoteVaultEvent(path: path))
        }
        return Plan(events: events, downloads: downloads, completed: completed)
    }

    /// Downloads to request after the initial gather: every non-current,
    /// not-yet-downloading vault item.
    nonisolated static func initialDownloads(items: [UbiquitousVaultItem], root: URL) -> [String] {
        plan(changed: items, removedPaths: [], root: root, alreadyRequested: []).downloads
    }

    /// True when `path` lies under `root` and no component is hidden.
    nonisolated static func isVaultPath(_ path: String, root: URL) -> Bool {
        guard let relative = VaultWriteGuard.relativePath(of: path, under: root.path) else { return false }
        return !relative.split(separator: "/").contains { $0.hasPrefix(".") }
    }
}

/// Observes the iCloud vault through `NSMetadataQuery` (main run loop).
@MainActor
final class UbiquitousVaultObserver: VaultChangeObserving {

    private let root: URL
    private let onChange: @Sendable ([NoteVaultEvent]) -> Void
    private var query: NSMetadataQuery?
    private var tokens: [NSObjectProtocol] = []
    /// Paths whose download was requested and hasn't completed yet.
    private var requested: Set<String> = []

    /// - Parameters:
    ///   - root: the vault root inside the ubiquity container
    ///     (`ICloudVaultLocator.notesURL(forContainer:)`).
    ///   - onChange: receives the events of every query update; the first
    ///     callback after the initial gather is a single full-scan event.
    init(root: URL, onChange: @escaping @Sendable ([NoteVaultEvent]) -> Void) {
        self.root = root
        self.onChange = onChange
    }

    func start() {
        guard query == nil else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        // Every item in the container's Documents scope; narrowed to the
        // vault root by the planner (path prefixes in a predicate trip over
        // the /private alias).
        query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*")
        query.notificationBatchingInterval = 0.5

        let center = NotificationCenter.default
        tokens.append(center.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleGatherFinished() }
        })
        tokens.append(center.addObserver(
            forName: .NSMetadataQueryDidUpdate, object: query, queue: .main
        ) { [weak self] notification in
            let changed = Self.items(in: notification.userInfo?[NSMetadataQueryUpdateChangedItemsKey])
                + Self.items(in: notification.userInfo?[NSMetadataQueryUpdateAddedItemsKey])
            let removed = Self.items(in: notification.userInfo?[NSMetadataQueryUpdateRemovedItemsKey]).map(\.path)
            MainActor.assumeIsolated { self?.handleUpdate(changed: changed, removed: removed) }
        })
        self.query = query
        if !query.start() {
            Log.storage.error("UbiquitousVaultObserver: NSMetadataQuery failed to start")
        } else {
            Log.storage.info("UbiquitousVaultObserver: watching \(self.root.path, privacy: .public)")
        }
    }

    func stop() {
        query?.stop()
        query = nil
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
        requested.removeAll()
    }

    // MARK: - Updates

    private func handleGatherFinished() {
        guard let query else { return }
        query.disableUpdates()
        let all = Self.items(in: query.results)
        query.enableUpdates()
        requestDownloads(UbiquitousVaultChangePlanner.initialDownloads(items: all, root: root))
        // Whatever arrived while the app wasn't running: one full pass.
        onChange([NoteVaultEvent(path: "", requiresFullScan: true)])
    }

    private func handleUpdate(changed: [UbiquitousVaultItem], removed: [String]) {
        guard query != nil else { return }
        let plan = UbiquitousVaultChangePlanner.plan(
            changed: changed, removedPaths: removed, root: root, alreadyRequested: requested
        )
        for path in plan.completed { requested.remove(path) }
        requestDownloads(plan.downloads)
        if !plan.events.isEmpty { onChange(plan.events) }
    }

    private func requestDownloads(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        requested.formUnion(paths)
        let urls = paths.map { URL(fileURLWithPath: $0) }
        // File-coordination work inside FileManager; keep it off the main thread.
        Task.detached(priority: .utility) {
            for url in urls {
                do {
                    try FileManager.default.startDownloadingUbiquitousItem(at: url)
                } catch {
                    Log.storage.error("UbiquitousVaultObserver: download request failed for \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Metadata items

    /// Snapshots `NSMetadataItem`s (an array from the query's results or an
    /// update's userInfo) into values. Runs on the main thread, where the
    /// query delivers.
    nonisolated private static func items(in raw: Any?) -> [UbiquitousVaultItem] {
        guard let array = raw as? [Any] else { return [] }
        var out: [UbiquitousVaultItem] = []
        out.reserveCapacity(array.count)
        for case let item as NSMetadataItem in array {
            if let snapshot = snapshot(item) { out.append(snapshot) }
        }
        return out
    }

    nonisolated private static func snapshot(_ item: NSMetadataItem) -> UbiquitousVaultItem? {
        let path: String
        if let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
            path = url.path
        } else if let raw = item.value(forAttribute: NSMetadataItemPathKey) as? String {
            path = raw
        } else {
            return nil
        }
        let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
        let isDownloading = (item.value(forAttribute: NSMetadataUbiquitousItemIsDownloadingKey) as? NSNumber)?.boolValue ?? false
        // No status (e.g. a folder, or a local-only item): treat as current.
        let isCurrent = status == nil || status == NSMetadataUbiquitousItemDownloadingStatusCurrent
        return UbiquitousVaultItem(path: path, isCurrent: isCurrent, isDownloading: isDownloading)
    }
}
