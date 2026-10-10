// ScribeiOS/Notes/IOSVaultSyncController.swift
//
// iCloud vault sync on iPhone / iPad (D-Sync-2 in
// docs/ICLOUD-MULTIPLATFORM-DESIGN.md). The iOS counterpart of the Mac's
// `VaultCoordinator.start()`:
//
// 1. Picks the vault: the iCloud Drive vault
//    (`<container>/Documents/Scribe/Notes`, `ICloudVaultLocator`) when the user
//    turned on "Store notes in iCloud Drive" (Settings, which migrates the
//    local vault with `ICloudVaultMigrator` and stores the path) and iCloud is
//    available; otherwise the local vault in the app's Documents — no iCloud
//    account / container is handled gracefully by staying local.
// 2. Observes it: `UbiquitousVaultObserver` (NSMetadataQuery) for the iCloud
//    vault — notes edited on the Mac show up here and vice versa, cloud-only
//    files are downloaded on demand. A local vault has no outside writers, so
//    it is reconciled on launch and whenever the app comes to the front.
// 3. Reconciles through the shared serial `NoteReconcileScheduler` /
//    `NoteIndexReconciler`, skipping Scribe's own writes (`VaultWriteGuard`),
//    and posts `.noteVaultFilesChanged` so open editors reload.
//
// ⚠️DEVICE: live iCloud behaviour needs a signed-in account and the
// provisioned `iCloud.com.varij.scribe` container.

import Foundation
import Observation

@MainActor
@Observable
final class IOSVaultSyncController {

    static let shared = IOSVaultSyncController()

    /// Where the open vault lives.
    enum Location: Equatable {
        /// Not started yet.
        case unknown
        /// The app's local Documents vault.
        case local
        /// The iCloud Drive vault.
        case iCloud
        /// iCloud was chosen but isn't available (signed out, container not
        /// provisioned): the local vault is used until it comes back.
        case iCloudUnavailable
    }

    /// Settings' "Store notes in iCloud Drive" toggle (ScribeiOS/SettingsScreen).
    static let iCloudNotesEnabledKey = "iCloudNotesEnabled"

    private(set) var location: Location = .unknown
    private(set) var lastError: String?
    private(set) var lastSync: Date?

    private let noteStore: NoteStore
    private let dbManager: DatabaseManager
    @ObservationIgnored private var scheduler: NoteReconcileScheduler?
    @ObservationIgnored private var observer: (any VaultChangeObserving)?
    @ObservationIgnored private var observedRoot: URL?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isConfiguring = false
    @ObservationIgnored private var lastSeenPreference: String?
    @ObservationIgnored private var defaultsToken: NSObjectProtocol?

    private init() {
        self.noteStore = NoteStore.shared
        self.dbManager = DatabaseManager.shared
    }

    // MARK: - Lifecycle

    /// Chooses the vault, starts observing it and runs a first reconcile.
    /// Idempotent; later calls just reconcile (e.g. on foregrounding).
    func start() {
        guard !started else {
            refresh()
            return
        }
        started = true
        lastSeenPreference = UserDefaults.standard.string(forKey: NotesDirectory.userPreferenceKey)
        // Settings flips the vault by writing the stored path; follow it.
        defaultsToken = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { IOSVaultSyncController.shared.preferenceMayHaveChanged() }
        }
        Task { await configureVault() }
    }

    /// Foreground / pull-to-refresh: re-check iCloud and reconcile.
    func refresh() {
        guard started else { return start() }
        if location == .iCloudUnavailable || location == .iCloud {
            Task { await configureVault() }
        } else {
            scheduler?.requestReconcile()
        }
    }

    // MARK: - Vault selection

    private var wantsICloud: Bool {
        UserDefaults.standard.bool(forKey: Self.iCloudNotesEnabledKey)
    }

    private func preferenceMayHaveChanged() {
        let current = UserDefaults.standard.string(forKey: NotesDirectory.userPreferenceKey)
        guard current != lastSeenPreference else { return }
        lastSeenPreference = current
        Task { await configureVault() }
    }

    private func configureVault() async {
        guard !isConfiguring else { return }
        isConfiguring = true
        defer { isConfiguring = false }

        let target: URL
        let newLocation: Location
        if wantsICloud {
            // Fast, non-blocking: nil when no iCloud account is signed in.
            if FileManager.default.ubiquityIdentityToken != nil,
               let iCloudURL = await ICloudVaultLocator.resolveNotesURL() {
                target = iCloudURL
                newLocation = .iCloud
            } else {
                target = NotesDirectory.builtInDefault()
                newLocation = .iCloudUnavailable
            }
        } else {
            // The stored path (cleared when iCloud is turned off) or the
            // built-in local default.
            target = (try? NotesDirectory.defaultLocation())?.root ?? NotesDirectory.builtInDefault()
            newLocation = .local
        }

        let fileStore = activateFileStore(at: target)
        location = newLocation
        startObserving(fileStore, iCloud: newLocation == .iCloud)
        scheduler?.requestReconcile()
    }

    /// Points `NoteStore.shared` at `root` (when it isn't already) and
    /// returns the active file store.
    private func activateFileStore(at root: URL) -> NoteFileStore {
        if let current = noteStore.fileStore,
           VaultWriteGuard.normalize(current.directory.root.path) == VaultWriteGuard.normalize(NotesDirectory(root: root).root.path) {
            return current
        }
        let fileStore = NoteFileStore(directory: NotesDirectory(root: root))
        noteStore.setFileStore(fileStore)
        Log.storage.notice("IOSVaultSyncController: vault is now \(fileStore.directory.root.path, privacy: .public)")
        return fileStore
    }

    // MARK: - Observation + reconcile

    private func startObserving(_ fileStore: NoteFileStore, iCloud: Bool) {
        let root = fileStore.directory.root
        if let observedRoot, observedRoot == root, scheduler != nil,
           (observer != nil) == iCloud {
            return
        }
        observer?.stop()
        observer = nil
        scheduler?.invalidate()

        let reconciler = NoteIndexReconciler(fileStore: fileStore, dbManager: dbManager)
        let scheduler = NoteReconcileScheduler(reconciler: reconciler) { result in
            Task { @MainActor in
                IOSVaultSyncController.shared.handle(result)
            }
        }
        self.scheduler = scheduler
        observedRoot = root

        guard iCloud else { return }
        let writeGuard = fileStore.writeGuard
        let observer = UbiquitousVaultObserver(root: root) { events in
            let needed = VaultWriteGuard.requiresReconcile(
                events: events,
                root: root,
                isOwnWrite: { writeGuard.isOwnWrite(atPath: $0) }
            )
            if needed { scheduler.requestReconcile() }
        }
        self.observer = observer
        observer.start()
    }

    private func handle(_ result: Result<NoteReconcileResult, Error>) {
        switch result {
        case .success(let r):
            lastError = nil
            lastSync = Date()
            if r.upserted > 0 || r.removed > 0 {
                Log.storage.info("IOSVaultSyncController: upserted=\(r.upserted) removed=\(r.removed)")
            }
            if !r.changedNoteIds.isEmpty {
                NotificationCenter.default.post(
                    name: .noteVaultFilesChanged,
                    object: nil,
                    userInfo: [NoteVaultChange.noteIdsKey: r.changedNoteIds]
                )
            }
        case .failure(let error):
            lastError = error.localizedDescription
            Log.storage.error("IOSVaultSyncController: reconcile failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Status

    /// A one-line status for the notes sidebar.
    var statusText: String {
        switch location {
        case .unknown: return "Opening notes…"
        case .local: return "On this device"
        case .iCloud: return "iCloud Drive"
        case .iCloudUnavailable: return "iCloud unavailable — using notes on this device"
        }
    }
}
