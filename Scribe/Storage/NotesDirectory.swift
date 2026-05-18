import Darwin
import Foundation

/// Resolves the on-disk root for Scribe's note vault.
///
/// Default location is `~/Documents/Scribe/Notes/` — visible in Finder and
/// covered automatically when the user enables iCloud Drive for the
/// Documents folder. The root is created on first access; tests inject
/// their own root via `NotesDirectory(root:)`.
struct NotesDirectory {
    let root: URL

    init(root: URL) {
        // Materialize the folder, then canonicalize via realpath(3). Both
        // URL.resolvingSymlinksInPath() and NSString.resolvingSymlinksInPath
        // leave macOS's `/var → /private/var` alias intact; only realpath
        // collapses intermediate symlinks. We canonicalize once at the
        // root so every downstream URL — directly-constructed or returned
        // by the file enumerator — agrees on the same path.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = Self.canonicalize(root)
    }

    private static func canonicalize(_ url: URL) -> URL {
        url.path.withCString { cString in
            guard let resolved = realpath(cString, nil) else { return url }
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        }
    }

    /// Default production location.
    ///
    /// Priority order:
    /// 1. User preference at `Self.userPreferenceKey` (`notesVaultPath`),
    ///    if non-empty and the path is reachable.
    /// 2. Fall back to `~/Documents/Scribe/Notes/`.
    ///
    /// Folder is created lazily and the call is safe to repeat.
    static func defaultLocation() throws -> NotesDirectory {
        if let override = userOverridePath() {
            try FileManager.default.createDirectory(
                at: override,
                withIntermediateDirectories: true
            )
            return NotesDirectory(root: override)
        }
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = documents.appendingPathComponent("Scribe", isDirectory: true)
            .appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return NotesDirectory(root: root)
    }

    /// Built-in fallback. Used by Settings to surface what the path would
    /// reset to.
    static func builtInDefault() -> URL {
        let documents = (try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return documents
            .appendingPathComponent("Scribe", isDirectory: true)
            .appendingPathComponent("Notes", isDirectory: true)
    }

    /// UserDefaults key the Settings pane and `defaultLocation()` share.
    /// Mirrored via `@AppStorage` in SwiftUI; reading raw here keeps the
    /// storage layer free of SwiftUI imports.
    static let userPreferenceKey = "notesVaultPath"

    /// Resolves the user preference into a URL if it's set, non-empty, and
    /// addressable. Returns nil otherwise so the caller falls back to the
    /// built-in default — never propagate a malformed preference up the
    /// stack because the user would lose access to all their notes.
    private static func userOverridePath() -> URL? {
        guard let raw = UserDefaults.standard.string(forKey: userPreferenceKey),
              !raw.isEmpty
        else { return nil }
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        // A non-existent path is fine — we'll create it. But guard against
        // paths the FileManager refuses to even canonicalize (e.g. on a
        // detached volume).
        return url
    }

    /// Sub-folder for the daily note files (`Daily/2026-05-18.md`). Created
    /// on demand.
    func dailyFolder() throws -> URL {
        let url = root.appendingPathComponent("Daily", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func ensureExists() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }
}
