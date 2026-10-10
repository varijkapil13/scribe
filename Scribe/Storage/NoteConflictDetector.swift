import Foundation

/// Detects iCloud-Drive-style conflict files in the notes vault.
///
/// iCloud syncs name conflicts by suffixing the loser with strings like
/// `(Mac's conflicted copy 2026-05-18)`. Obsidian / Dropbox / Google
/// Drive use variants ("conflicted copy", "Conflict"). The detector
/// returns every candidate so the UI can offer a resolve flow.
///
/// Detection only — Scribe never deletes a conflict file. Picking a
/// winner is left to the user. `NoteDetailViewModel` uses this to surface
/// conflicts for the open note, including the copies Scribe writes itself
/// when an external edit races an unsaved in-app edit.
struct NoteConflictDetector {
    let fileStore: NoteFileStore

    /// One conflict file with the title it would have if the suffix were
    /// stripped. `noteId` is whatever the file's frontmatter advertises,
    /// nil if the file isn't a Scribe-shaped note.
    struct Match: Equatable {
        let url: URL
        let displayName: String   // e.g. "Meeting (Mac's conflicted copy 2026-05-18)"
        let originalName: String  // e.g. "Meeting"
        let noteId: String?
    }

    init(fileStore: NoteFileStore) {
        self.fileStore = fileStore
    }

    /// Walks the vault and returns every file whose filename matches a
    /// known conflict-suffix pattern. Cheap — pure filename inspection,
    /// no file IO unless the caller asks for `match.noteId` and there's
    /// a hit, in which case we parse the frontmatter to surface the id.
    func listConflicts() throws -> [Match] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: fileStore.directory.root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var out: [Match] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            let display = url.deletingPathExtension().lastPathComponent
            guard let original = Self.stripConflictSuffix(display), original != display else {
                continue
            }
            let id = (try? fileStore.read(at: url))?.id
            out.append(Match(url: url, displayName: display, originalName: original, noteId: id))
        }
        return out
    }

    /// Conflicts that belong to one note: files whose frontmatter id is
    /// `noteId` (iCloud copies the bytes, id included) or whose name minus
    /// the conflict suffix equals `originalName` (copies Scribe writes when
    /// an external edit races an unsaved in-app edit get a fresh id).
    func conflicts(forNoteId noteId: String, originalName: String?) throws -> [Match] {
        try listConflicts().filter { match in
            match.noteId == noteId
                || (originalName.map { match.originalName.caseInsensitiveCompare($0) == .orderedSame } ?? false)
        }
    }

    /// Base filename (no extension) for a conflict copy Scribe writes itself.
    /// Recognised by `stripConflictSuffix`, so the copy surfaces through the
    /// same detection path as iCloud / Dropbox conflicts.
    nonisolated static func conflictCopyName(for originalName: String, at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return "\(originalName) (Scribe conflicted copy \(f.string(from: date)))"
    }

    /// If `name` ends with a recognised conflict suffix, returns the
    /// original (suffix-free) name. Otherwise nil. Tolerates:
    /// - " (Mac's conflicted copy 2026-05-18)"           — iCloud Drive
    /// - " (conflicted copy)"                            — Dropbox short form
    /// - " (Anna's conflicted copy 2026-05-18 12-30-45)" — iCloud with time
    ///
    /// Anything wrapped in parentheses that contains "conflicted copy"
    /// counts. Apostrophes are matched as straight or curly.
    static func stripConflictSuffix(_ name: String) -> String? {
        // Find the last "(" — conflict markers always wrap the trailing tag.
        guard let openIdx = name.lastIndex(of: "(") else { return nil }
        guard name.hasSuffix(")") else { return nil }
        let inside = String(name[name.index(after: openIdx)..<name.index(before: name.endIndex)])
        let lower = inside.lowercased()
        guard lower.contains("conflicted copy") else { return nil }
        // Drop the trailing space before "(", if any.
        var prefix = String(name[..<openIdx])
        if prefix.hasSuffix(" ") { prefix = String(prefix.dropLast()) }
        return prefix.isEmpty ? nil : prefix
    }
}
