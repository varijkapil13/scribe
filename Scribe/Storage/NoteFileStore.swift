import Foundation

/// File-IO primitives for Scribe's markdown note vault.
///
/// One `.md` file per note, plus optional `Daily/<YYYY-MM-DD>.md` for the
/// daily-note convention. The store knows nothing about SQLite, the live
/// `NoteStore`, or the running app — it just reads/writes/lists files
/// under a configurable root, so it's trivially unit-testable.
///
/// Writes are atomic (`Data.write(options: .atomic)`), so a crash mid-flush
/// can never leave a partially-written file on disk. Reads tolerate
/// missing or malformed frontmatter by falling back to defaults, so an
/// externally-added `.md` file still parses as a note.
struct NoteFileStore {
    let directory: NotesDirectory

    init(directory: NotesDirectory) {
        self.directory = directory
    }

    // MARK: - Read

    /// Reads and parses a single `.md` file. The `id` and `frontmatter`
    /// come from the file's YAML block; if absent, fall back to a fresh
    /// UUID and a title derived from the filename so the read still
    /// succeeds.
    func read(at url: URL) throws -> NoteFile {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let fallbackId = UUID().uuidString
        let parsed = NoteFrontmatterCodec.decodeFile(
            contents: contents,
            fallbackTitle: fallbackTitle,
            fallbackId: fallbackId
        )
        return NoteFile(
            id: parsed.id,
            frontmatter: parsed.frontmatter,
            body: parsed.body
        )
    }

    /// Walks the vault root and returns one `NoteFile` per `.md` file
    /// found. Errors on individual files (malformed UTF-8, IO failures)
    /// are silently skipped so a single corrupt file can't take down the
    /// whole index rebuild.
    func listAll() throws -> [NoteFile] {
        try directory.ensureExists()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory.root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var out: [NoteFile] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile,
                  isRegular else { continue }
            do {
                out.append(try read(at: url))
            } catch {
                Log.storage.error("NoteFileStore.listAll skipped \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return out
    }

    // MARK: - Write

    /// Writes a note to disk under the appropriate path. Returns the URL
    /// the file landed at. If a different file with the same target name
    /// already exists, appends a numeric suffix (`Meeting 2.md`) — the
    /// caller never has to worry about silent overwrites of unrelated
    /// notes.
    @discardableResult
    func write(_ file: NoteFile) throws -> URL {
        let url = try resolveTargetURL(for: file)
        let contents = NoteFrontmatterCodec.encodeFile(
            id: file.id,
            frontmatter: file.frontmatter,
            body: file.body
        )
        guard let data = contents.data(using: .utf8) else {
            throw NoteFileStoreError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Deletes the file backing `id`, if it exists. Returns the URL that
    /// was removed (or `nil` if nothing matched). Walks the vault rather
    /// than guessing a path, since the filename may have drifted from the
    /// current title.
    @discardableResult
    func delete(id: String) throws -> URL? {
        if let url = try findURL(for: id) {
            try FileManager.default.removeItem(at: url)
            return url
        }
        return nil
    }

    // MARK: - URL resolution

    /// Returns the URL currently backing `id`, by scanning all `.md` files
    /// and matching on frontmatter `id`. `nil` if no match. Used both by
    /// `delete` and by callers who need to rename or relocate a note.
    func findURL(for id: String) throws -> URL? {
        try directory.ensureExists()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory.root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            if let parsed = try? read(at: url), parsed.id == id {
                return url
            }
        }
        return nil
    }

    /// Picks the target URL for a new write. Daily notes land in
    /// `Daily/<YYYY-MM-DD>.md`; everything else lands in the root with a
    /// sanitized title. Collisions are resolved by appending ` 2`, ` 3`,
    /// etc. — but only when the existing file belongs to a *different*
    /// note id, so renaming a note to its current name is a no-op.
    private func resolveTargetURL(for file: NoteFile) throws -> URL {
        try directory.ensureExists()

        if file.frontmatter.isDailyNote, let date = file.frontmatter.dailyDate {
            let folder = try directory.dailyFolder()
            let url = folder.appendingPathComponent("\(Self.dailyDateFormatter.string(from: date)).md")
            return url
        }

        // Reuse the existing URL if we already have a file for this id and
        // its sanitized name still matches the desired title.
        let desiredName = sanitize(filename: file.frontmatter.title.isEmpty
                                   ? "Untitled"
                                   : file.frontmatter.title)
        if let existing = try findURL(for: file.id) {
            let existingName = existing.deletingPathExtension().lastPathComponent
            if existingName == desiredName { return existing }
            // Title changed — drop the orphan at the old filename and fall
            // through to picking a fresh target. The new write is what
            // becomes authoritative.
            try? FileManager.default.removeItem(at: existing)
        }

        let base = directory.root.appendingPathComponent("\(desiredName).md")
        let fm = FileManager.default
        if !fm.fileExists(atPath: base.path) {
            return base
        }
        // Disambiguate: try " 2", " 3", … until a free slot opens up. If a
        // slot is occupied by a file that already belongs to this id, use
        // it (we're effectively idempotent for a renamed file).
        for i in 2...256 {
            let candidate = directory.root.appendingPathComponent("\(desiredName) \(i).md")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            if let parsed = try? read(at: candidate), parsed.id == file.id { return candidate }
        }
        throw NoteFileStoreError.tooManyCollisions(desiredName)
    }

    /// Replaces filesystem-hostile characters in a title with hyphens and
    /// trims edge whitespace. POSIX paths only forbid `/` and `\0`, but
    /// HFS+/APFS and other apps choke on more — we strip the union here
    /// so files survive moves to other filesystems / OSes.
    private func sanitize(filename: String) -> String {
        let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\u{0000}"]
        let mapped = filename.map { forbidden.contains($0) ? "-" : $0 }
        var out = String(mapped).trimmingCharacters(in: .whitespaces)
        // Avoid hidden files on macOS and reserved Windows-style filenames.
        if out.hasPrefix(".") { out = "_" + out.dropFirst() }
        if out.isEmpty { out = "Untitled" }
        return out
    }

    // Local time, matching NoteStore.dailyDateFormatter so a round-trip
    // through (String → Date → String) preserves the day. Using UTC here
    // would shift the day by ±1 for users west of UTC.
    nonisolated(unsafe) private static let dailyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

enum NoteFileStoreError: Error, Equatable {
    case encodingFailed
    case tooManyCollisions(String)
}
