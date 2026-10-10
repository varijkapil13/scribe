// Scribe/Storage/VaultChangeObserving.swift
//
// D-Sync-2 (docs/ICLOUD-MULTIPLATFORM-DESIGN.md): vault change observation
// behind a protocol, so the reconcile wiring doesn't care HOW changes made
// outside Scribe are noticed:
//
// - macOS, local vault: `NoteVaultWatcher` (FSEvents) — conformance below.
// - iCloud vault (iPhone / iPad): `UbiquitousVaultObserver` (NSMetadataQuery
//   over the ubiquity container; also downloads non-local files on demand).
//
// Both keep the same contract: they are created with an
// `onChange: @Sendable ([NoteVaultEvent]) -> Void` callback, which the owner
// filters through `VaultWriteGuard.requiresReconcile` (skipping Scribe's own
// writes) before asking its `NoteReconcileScheduler` for a pass.

import Foundation

/// A long-lived observer of the notes vault that reports changes made
/// outside Scribe through the `onChange` callback it was created with.
@MainActor
protocol VaultChangeObserving: AnyObject {
    /// Begins observing. Idempotent.
    func start()
    /// Stops observing; no callbacks are delivered afterwards.
    func stop()
}

#if os(macOS)
// The FSEvents watcher (macOS only; excluded from the iOS target). Its
// nonisolated start/stop satisfy the main-actor requirements.
extension NoteVaultWatcher: VaultChangeObserving {}
#endif
