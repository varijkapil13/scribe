// Scribe/Storage/AttachmentsDirectory.swift
import Foundation

/// Resolves per-note attachment paths under
/// `~/Library/Application Support/Scribe/attachments/<noteId>/`.
///
/// The `root` parameter exists for testability — production callers omit it
/// and get the default Application Support root.
enum AttachmentsDirectory {

    #if DEBUG
    /// Test-only override of the storage root. DEBUG builds only so a
    /// release path can never accidentally read it. Setting this lets
    /// `NoteStore.deleteNote` (which doesn't take a `root` parameter) be
    /// exercised against a temp dir.
    nonisolated(unsafe) static var rootOverrideForTesting: URL?
    #endif

    struct StoredAttachment {
        /// Path relative to `root` (e.g. `attachments/note-1/abc.png`). Suitable
        /// for embedding in a markdown body so other installations / exports can
        /// resolve it from the same root.
        let relativePath: String
        /// Absolute file URL.
        let absoluteURL: URL
    }

    static func defaultRoot() -> URL {
        #if DEBUG
        if let override = rootOverrideForTesting { return override }
        #endif
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return appSupport.appendingPathComponent("Scribe", isDirectory: true)
    }

    /// Returns the directory for a note's attachments, creating it (and any
    /// intermediate directories) if missing.
    @discardableResult
    static func directory(forNoteId noteId: String, root: URL = defaultRoot()) throws -> URL {
        let dir = root
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(noteId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies `sourceURL` into the note's attachments directory under a new
    /// UUID-based filename, preserving the original extension. Returns both
    /// the relative path (for markdown embedding) and the absolute URL.
    static func store(
        sourceURL: URL,
        forNoteId noteId: String,
        root: URL = defaultRoot()
    ) throws -> StoredAttachment {
        let ext = sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension
        let filename = "\(UUID().uuidString).\(ext)"
        let dir = try directory(forNoteId: noteId, root: root)
        let dest = dir.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        let relative = "attachments/\(noteId)/\(filename)"
        return StoredAttachment(relativePath: relative, absoluteURL: dest)
    }

    /// Removes the note's attachments directory if present. No-op when missing.
    /// Throws on permission errors / filesystem failure so callers can decide
    /// whether to swallow or surface; `NoteStore.deleteNote` swallows + logs.
    static func cleanup(forNoteId noteId: String, root: URL = defaultRoot()) throws {
        let dir = root
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(noteId, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}
