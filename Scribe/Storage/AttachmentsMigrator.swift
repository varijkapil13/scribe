import Foundation

/// One-time move of the attachments tree from
/// `~/Library/Application Support/Scribe/attachments/` into the markdown
/// vault root (`~/Documents/Scribe/Notes/attachments/`) so an exported
/// vault carries its images. Idempotent.
///
/// Existing `attachments/<noteId>/<filename>` relative paths embedded in
/// note bodies remain valid — only the resolution root changes.
enum AttachmentsMigrator {

    /// Moves every per-note subdirectory under the legacy attachments
    /// root into the new location. If a destination already exists, the
    /// source is left alone (the user already migrated or made a manual
    /// copy). Returns the number of `<noteId>` folders moved.
    @discardableResult
    static func migrateIfNeeded(legacyRoot: URL, newRoot: URL) throws -> Int {
        let fm = FileManager.default
        let legacyAttachments = legacyRoot.appendingPathComponent("attachments", isDirectory: true)
        let newAttachments = newRoot.appendingPathComponent("attachments", isDirectory: true)

        guard fm.fileExists(atPath: legacyAttachments.path) else { return 0 }
        try fm.createDirectory(at: newAttachments, withIntermediateDirectories: true)

        let entries = try fm.contentsOfDirectory(
            at: legacyAttachments,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var moved = 0
        for src in entries {
            let isDir = (try? src.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let dst = newAttachments.appendingPathComponent(src.lastPathComponent, isDirectory: true)
            if fm.fileExists(atPath: dst.path) {
                // Already present — preserve user state, skip silently.
                continue
            }
            try fm.moveItem(at: src, to: dst)
            moved += 1
        }
        // If we emptied the legacy folder, remove it so the next launch
        // skips the scan entirely. Tolerate the folder being non-empty
        // (e.g. partial migration retried) — leave it for inspection.
        if let remaining = try? fm.contentsOfDirectory(atPath: legacyAttachments.path),
           remaining.isEmpty {
            try? fm.removeItem(at: legacyAttachments)
        }
        return moved
    }

    /// Convenience for production callers — wires up the canonical
    /// legacy and new roots.
    @discardableResult
    static func migrateProductionIfNeeded() throws -> Int {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let legacyRoot = appSupport.appendingPathComponent("Scribe", isDirectory: true)
        let newRoot = try NotesDirectory.defaultLocation().root
        return try migrateIfNeeded(legacyRoot: legacyRoot, newRoot: newRoot)
    }
}
