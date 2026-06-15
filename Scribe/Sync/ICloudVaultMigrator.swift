import Foundation

/// Migrates Scribe's note vault into iCloud Drive and re-points the app at it
/// (or back to local) by writing `NotesDirectory`'s `notesVaultPath` override.
///
/// Why a copy and not a move: the local `~/Documents/Scribe/Notes` tree may
/// already be covered by Finder's "Documents in iCloud" or be the user's only
/// copy. We COPY into the app's own ubiquity container, leave the local tree
/// intact, then flip the stored override so the *next* resolution uses the
/// iCloud path. Disabling just clears the override — the local tree is still
/// there, so it's a safe, reversible toggle.
///
/// ⚠️ Launch-hang hazard: `url(forUbiquityContainerIdentifier:)` blocks the
/// first time it runs. We only ever reach it through
/// `ICloudVaultLocator.resolveNotesURL()`, which hops onto a detached
/// background task. After migration the app reads a plain stored path via
/// `NotesDirectory.defaultLocation()` with NO ubiquity call on launch.
///
/// The pure helpers (`relativeFilePath`, `destinationURL`, `entriesToCopy`)
/// are unit-tested without touching the filesystem or iCloud. The live
/// `enableICloudVault()` / `disableICloudVault()` paths are
/// DEVICE-VALIDATION-REQUIRED: they need a real iCloud account plus a
/// provisioned `iCloud.com.varij.scribe` container, so they can only be
/// exercised on a signed-in device, not in CI.
enum ICloudVaultMigrator {

    enum MigrationError: Error, Equatable {
        /// iCloud unavailable: not signed in, or the container isn't
        /// provisioned. The caller should stay on the local vault.
        case iCloudUnavailable
    }

    // MARK: - Pure helpers (unit-tested, no I/O)

    /// The path of `entry` relative to `root`, as a `/`-joined string. Returns
    /// `nil` when `entry` is not actually under `root` (defensive — the
    /// enumerator should only ever yield descendants). Pure.
    static func relativeFilePath(of entry: URL, under root: URL) -> String? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let entryComponents = entry.standardizedFileURL.pathComponents
        guard entryComponents.count > rootComponents.count else { return nil }
        guard Array(entryComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        return entryComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// Maps a vault-relative path to its destination URL under
    /// `destinationRoot`, preserving the directory structure. Pure.
    static func destinationURL(forRelativePath relativePath: String, destinationRoot: URL) -> URL {
        var url = destinationRoot
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
            url = url.appendingPathComponent(String(component))
        }
        return url
    }

    /// Given the relative paths present in the source vault and those already
    /// present at the destination, returns the relative paths that still need
    /// copying — i.e. the set difference, sorted for deterministic ordering.
    ///
    /// Merge policy: a relative path already at the destination is left
    /// untouched (the iCloud copy wins, never clobbered), so re-running after
    /// a partial copy resumes rather than overwrites. Pure.
    static func entriesToCopy(sourceRelativePaths: [String],
                              existingDestinationRelativePaths: [String]) -> [String] {
        let existing = Set(existingDestinationRelativePaths)
        let source = Set(sourceRelativePaths)
        return source.subtracting(existing).sorted()
    }

    // MARK: - Live paths (DEVICE-VALIDATION-REQUIRED)

    /// Enables the iCloud vault:
    /// 1. Resolves the iCloud notes URL off-main (`resolveNotesURL`); throws
    ///    `.iCloudUnavailable` when iCloud isn't usable.
    /// 2. Copies the current local vault tree into the iCloud destination,
    ///    skipping entries already present (merge, never clobber).
    /// 3. Writes the iCloud path into `NotesDirectory.userPreferenceKey` so
    ///    every subsequent launch reads it with no blocking ubiquity call.
    ///
    /// Returns the resolved iCloud notes URL now in effect.
    ///
    /// ⚠️ DEVICE-VALIDATION-REQUIRED: needs a signed-in iCloud account and a
    /// provisioned `iCloud.com.varij.scribe` container. Cannot run in CI.
    @discardableResult
    static func enableICloudVault() async throws -> URL {
        guard let iCloudNotesURL = await ICloudVaultLocator.resolveNotesURL() else {
            throw MigrationError.iCloudUnavailable
        }

        // The current local source is whatever NotesDirectory would resolve
        // *before* we flip the override. If an override is already pointing at
        // iCloud, defaultLocation() returns that — copying a tree onto itself
        // is a no-op via the skip-if-present policy below, so this stays safe.
        let sourceRoot = try NotesDirectory.defaultLocation().root

        try copyVaultTree(from: sourceRoot, to: iCloudNotesURL)

        UserDefaults.standard.set(iCloudNotesURL.path, forKey: NotesDirectory.userPreferenceKey)
        Log.storage.notice("ICloudVaultMigrator: enabled iCloud vault at \(iCloudNotesURL.path, privacy: .public)")
        return iCloudNotesURL
    }

    /// Disables the iCloud vault by clearing the override, so the next
    /// resolution falls back to the built-in local default. The iCloud copy is
    /// left in place (reversible). Does not touch iCloud, so it's safe to call
    /// anywhere, including when offline.
    static func disableICloudVault() {
        UserDefaults.standard.removeObject(forKey: NotesDirectory.userPreferenceKey)
        Log.storage.notice("ICloudVaultMigrator: disabled iCloud vault, re-pointed to local default")
    }

    // MARK: - Copy (filesystem; driven by the pure helpers above)

    /// Recursively copies every file under `sourceRoot` into `destinationRoot`,
    /// recreating the directory structure and skipping any relative path that
    /// already exists at the destination (merge, never clobber). Idempotent.
    ///
    /// ⚠️ DEVICE-VALIDATION-REQUIRED in the iCloud case — the destination is a
    /// ubiquity container. The logic itself is plain `FileManager` and is
    /// validated indirectly through the pure helpers' tests.
    static func copyVaultTree(from sourceRoot: URL, to destinationRoot: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        guard fm.fileExists(atPath: sourceRoot.path) else { return }

        // List source regular files as vault-relative paths.
        var sourceRelativePaths: [String] = []
        if let enumerator = fm.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                guard isRegular else { continue }
                if let rel = relativeFilePath(of: url, under: sourceRoot) {
                    sourceRelativePaths.append(rel)
                }
            }
        }

        // List what already exists at the destination so we can skip it.
        var existingRelativePaths: [String] = []
        if let enumerator = fm.enumerator(
            at: destinationRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                guard isRegular else { continue }
                if let rel = relativeFilePath(of: url, under: destinationRoot) {
                    existingRelativePaths.append(rel)
                }
            }
        }

        let toCopy = entriesToCopy(
            sourceRelativePaths: sourceRelativePaths,
            existingDestinationRelativePaths: existingRelativePaths
        )

        for rel in toCopy {
            let src = destinationURL(forRelativePath: rel, destinationRoot: sourceRoot)
            let dst = destinationURL(forRelativePath: rel, destinationRoot: destinationRoot)
            try fm.createDirectory(
                at: dst.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Skip-if-present is enforced by entriesToCopy, but guard again in
            // case of a race so copyItem never throws on an existing file.
            if fm.fileExists(atPath: dst.path) { continue }
            try fm.copyItem(at: src, to: dst)
        }
    }
}
