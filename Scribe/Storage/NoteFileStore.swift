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
///
/// Lookups by note id go through a shared `NoteVaultIndex` (id → relative
/// path), verified against the file's own frontmatter and falling back to a
/// vault scan only on a miss. Every mutation is recorded with
/// `VaultWriteGuard` per path so the vault watcher can tell Scribe's own
/// writes from external edits.
struct NoteFileStore: Sendable {
    let directory: NotesDirectory
    let index: NoteVaultIndex
    let writeGuard: VaultWriteGuard

    init(
        directory: NotesDirectory,
        index: NoteVaultIndex = NoteVaultIndex(),
        writeGuard: VaultWriteGuard = .shared
    ) {
        self.directory = directory
        self.index = index
        self.writeGuard = writeGuard
    }

    // MARK: - Read

    /// Reads and parses a single `.md` file. The `id` and `frontmatter`
    /// come from the file's YAML block; if absent, the id is derived from
    /// the vault-relative path (stable across reads) and the title from the
    /// filename, so the read still succeeds.
    func read(at url: URL) throws -> NoteFile {
        try readEntry(at: url).file
    }

    /// `read(at:)` plus the facts the index needs: relative path, whether
    /// the id is pinned in the file, and the content fingerprint.
    func readEntry(at url: URL) throws -> NoteFileEntry {
        // Stat *before* reading: if the file changes in between, the stored
        // date is older than the new one, so a later fast-path comparison
        // re-hashes instead of trusting a stale hash.
        let stat = NoteFileFingerprint.statFile(at: url)
        let data = try Data(contentsOf: url)
        guard let contents = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let relative = relativePath(of: url) ?? VaultWriteGuard.normalize(url.path)
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let fallbackId = NoteStableId.derivedId(forRelativePath: relative)
        let parsed = NoteFrontmatterCodec.decodeFile(
            contents: contents,
            fallbackTitle: fallbackTitle,
            fallbackId: fallbackId
        )
        return NoteFileEntry(
            url: url,
            relativePath: relative,
            file: NoteFile(id: parsed.id, frontmatter: parsed.frontmatter, body: parsed.body),
            hasExplicitId: NoteFrontmatterCodec.explicitId(in: contents) != nil,
            fingerprint: NoteFileFingerprint(
                modificationDate: stat?.modificationDate,
                size: stat?.size ?? data.count,
                contentHash: NoteFileFingerprint.hash(data)
            )
        )
    }

    /// Walks the vault root and returns one `NoteFile` per `.md` file
    /// found. Errors on individual files (malformed UTF-8, IO failures)
    /// are silently skipped so a single corrupt file can't take down the
    /// whole index rebuild. Read-only: never pins ids or touches files.
    func listAll() throws -> [NoteFile] {
        try listEntries().entries.map(\.file)
    }

    /// Full listing with per-file metadata. Unchanged files (same
    /// modification date + size as the cached parse) are not re-read.
    /// Rebuilds the id → path index from the result. `changedIds` holds the
    /// ids whose file content differs from the previous listing / Scribe's
    /// own last write (every id on the first pass).
    func listEntries() throws -> (entries: [NoteFileEntry], changedIds: Set<String>) {
        try directory.ensureExists()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: directory.root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return ([], [])
        }
        var out: [NoteFileEntry] = []
        var changed: Set<String> = []
        var seenPaths: Set<String> = []
        for case let url as URL in enumerator {
            if Self.isInExcludedFolder(url, root: directory.root) {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            guard let relative = relativePath(of: url) else { continue }
            seenPaths.insert(relative)
            if let cached = index.cachedEntry(forPath: relative),
               let modified = values?.contentModificationDate,
               cached.fingerprint.modificationDate == modified,
               cached.fingerprint.size == values?.fileSize {
                out.append(cached)
                continue
            }
            do {
                let entry = try readEntry(at: url)
                let previous = index.cachedEntry(forPath: relative)
                if previous?.fingerprint.contentHash != entry.fingerprint.contentHash {
                    changed.insert(entry.file.id)
                }
                index.cache(entry)
                out.append(entry)
            } catch {
                Log.storage.error("NoteFileStore.listEntries skipped \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        index.pruneCache(keeping: seenPaths)
        index.replaceAll(with: out)
        return (out, changed)
    }

    // MARK: - Stable ids

    /// Pins `entry`'s (path-derived) id into the file's frontmatter so it
    /// survives renames and moves. Everything outside the frontmatter block
    /// is preserved byte-for-byte. Refuses (throws) if the file changed
    /// since `entry` was read, so a concurrent external edit isn't lost.
    @discardableResult
    func pinStableId(for entry: NoteFileEntry) throws -> NoteFileEntry {
        guard !entry.hasExplicitId else { return entry }
        let data = try Data(contentsOf: entry.url)
        guard NoteFileFingerprint.hash(data) == entry.fingerprint.contentHash else {
            throw NoteFileStoreError.changedSinceRead
        }
        guard let contents = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let pinned = NoteFrontmatterCodec.settingRawKeys(
            [(key: "id", value: entry.file.id)],
            in: contents
        )
        guard let newData = pinned.data(using: .utf8) else {
            throw NoteFileStoreError.encodingFailed
        }
        try newData.write(to: entry.url, options: .atomic)
        let fingerprint = NoteFileFingerprint.of(data: newData, at: entry.url)
        writeGuard.recordWrite(at: entry.url, fingerprint: fingerprint)
        var updated = entry
        updated.hasExplicitId = true
        updated.fingerprint = fingerprint
        index.cache(updated)
        index.setRelativePath(updated.relativePath, for: updated.file.id)
        return updated
    }

    // MARK: - Write

    /// Writes a note to disk. Returns the URL the file landed at.
    ///
    /// - An existing file for the id is updated in place, in whatever
    ///   folder it lives in; a title change renames it *within that folder*.
    /// - Renames write the new file first and only then remove the old one,
    ///   and only if the old path still holds this note (never a
    ///   `(conflicted copy)`, never another note, never the new file itself
    ///   on a case-insensitive volume).
    /// - If a different note already owns the target name, a numeric suffix
    ///   is appended (`Meeting 2.md`) — unrelated notes are never overwritten.
    @discardableResult
    func write(_ file: NoteFile) throws -> URL {
        try directory.ensureExists()
        let existing = try locate(id: file.id)?.url
        let url = try resolveTargetURL(for: file, existing: existing)
        let contents = NoteFrontmatterCodec.encodeFile(
            id: file.id,
            frontmatter: file.frontmatter,
            body: file.body
        )
        guard let data = contents.data(using: .utf8) else {
            throw NoteFileStoreError.encodingFailed
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        recordWrite(of: data, file: file, at: url)
        if let existing, !Self.isSameFile(existing, url) {
            removeSupersededFile(at: existing, expectedId: file.id)
        }
        return url
    }

    /// Deletes the file backing `id`, if it exists, by moving it to the
    /// Trash (falling back to a plain remove where there is no Trash, e.g.
    /// iOS, or when trashing fails). Returns the URL that was removed (or
    /// `nil` if nothing matched).
    @discardableResult
    func delete(id: String) throws -> URL? {
        guard let entry = try locate(id: id) else { return nil }
        try Self.trashOrRemove(entry.url)
        writeGuard.recordRemoval(at: entry.url)
        index.removeId(id)
        index.removePath(entry.relativePath)
        return entry.url
    }

    /// Writes a copy of the current on-disk version of `id` next to it as
    /// `<name> (Scribe conflicted copy <timestamp>).md`, with a fresh id and
    /// a matching title so it indexes as its own note. Everything except
    /// those two frontmatter keys is preserved byte-for-byte. Not recorded
    /// as a self-write, so the vault watcher indexes it.
    func writeConflictCopy(of entry: NoteFileEntry, now: Date = Date()) throws -> URL {
        let data = try Data(contentsOf: entry.url)
        guard let contents = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let folder = entry.url.deletingLastPathComponent()
        let baseName = NoteConflictDetector.conflictCopyName(
            for: entry.url.deletingPathExtension().lastPathComponent,
            at: now
        )
        let fm = FileManager.default
        var target = folder.appendingPathComponent("\(baseName).md")
        var n = 2
        while fm.fileExists(atPath: target.path) {
            guard n <= 256 else { throw NoteFileStoreError.tooManyCollisions(baseName) }
            target = folder.appendingPathComponent("\(baseName) \(n).md")
            n += 1
        }
        let copy = NoteFrontmatterCodec.settingRawKeys(
            [
                (key: "id", value: UUID().uuidString),
                (key: "title", value: NoteFrontmatterCodec.encodedScalar(
                    "\(entry.file.frontmatter.title) (conflicted copy)"
                )),
            ],
            in: contents
        )
        guard let copyData = copy.data(using: .utf8) else { throw NoteFileStoreError.encodingFailed }
        try copyData.write(to: target, options: .atomic)
        return target
    }

    // MARK: - Excluded folders

    /// Vault folders that hold Scribe's own non-note markdown (summary
    /// templates and recipes). Matched case-insensitively as a path prefix
    /// relative to the vault root; a user's own `Templates/` notes are
    /// still indexed.
    static let excludedFolders: [[String]] = [
        ["templates", "summaries"],
        ["templates", "recipes"],
    ]

    /// True when `url` is (inside) one of `excludedFolders` under `root`.
    /// Tolerates the macOS `/private` path alias on either side.
    static func isInExcludedFolder(_ url: URL, root: URL) -> Bool {
        guard let relative = VaultWriteGuard.relativePath(of: url.path, under: root.path) else {
            return false
        }
        let components = relative.split(separator: "/").map { $0.lowercased() }
        return excludedFolders.contains { prefix in
            components.count >= prefix.count && Array(components.prefix(prefix.count)) == prefix
        }
    }

    // MARK: - URL resolution

    /// Returns the URL currently backing `id`, or nil if no file carries it.
    func findURL(for id: String) throws -> URL? {
        try locate(id: id)?.url
    }

    /// Resolves `id` to its file: the index first (verified against the
    /// file's frontmatter id), then a full scan when the entry is stale or
    /// the index hasn't seen a complete listing yet. A regular file is
    /// preferred over a `(conflicted copy)` carrying the same id.
    func locate(id: String) throws -> NoteFileEntry? {
        try directory.ensureExists()
        if let relative = index.relativePath(for: id) {
            let url = directory.root.appendingPathComponent(relative)
            if let entry = try? readEntry(at: url), entry.file.id == id {
                return entry
            }
            index.removeId(id)
        } else if index.isComplete {
            // Not on disk at the last full listing and not written by
            // Scribe since (e.g. a note being created right now).
            return nil
        }
        return try scan(for: id)
    }

    /// Current fingerprint of the file backing `id` (nil if none). Cheap
    /// when `known` still matches the file's stat.
    func fingerprint(forId id: String, reusing known: NoteFileFingerprint? = nil) -> NoteFileFingerprint? {
        if let relative = index.relativePath(for: id) {
            let url = directory.root.appendingPathComponent(relative)
            if let fp = NoteFileFingerprint.current(at: url, reusing: known) { return fp }
        }
        guard let entry = try? locate(id: id) else { return nil }
        return entry.fingerprint
    }

    /// Fingerprint of the last version Scribe itself wrote for `id`.
    func lastWrittenFingerprint(forId id: String) -> NoteFileFingerprint? {
        index.lastWrittenFingerprint(for: id)
    }

    /// Path of `url` relative to the vault root, or nil if outside it.
    func relativePath(of url: URL) -> String? {
        VaultWriteGuard.relativePath(of: url.path, under: directory.root.path)
    }

    // MARK: - Private

    private func scan(for id: String) throws -> NoteFileEntry? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory.root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var conflictMatch: NoteFileEntry?
        for case let url as URL in enumerator {
            if Self.isInExcludedFolder(url, root: directory.root) {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard let entry = try? readEntry(at: url) else { continue }
            index.recordScanned(entry.relativePath, for: entry.file.id)
            guard entry.file.id == id else { continue }
            if NoteVaultIndex.isConflictCopy(relativePath: entry.relativePath) {
                if conflictMatch == nil { conflictMatch = entry }
                continue
            }
            index.setRelativePath(entry.relativePath, for: id)
            return entry
        }
        if let conflictMatch {
            index.setRelativePath(conflictMatch.relativePath, for: id)
        }
        return conflictMatch
    }

    private func recordWrite(of data: Data, file: NoteFile, at url: URL) {
        let fingerprint = NoteFileFingerprint.of(data: data, at: url)
        writeGuard.recordWrite(at: url, fingerprint: fingerprint)
        index.setLastWrittenFingerprint(fingerprint, for: file.id)
        if let relative = relativePath(of: url) {
            index.setRelativePath(relative, for: file.id)
            index.cache(NoteFileEntry(
                url: url,
                relativePath: relative,
                file: file,
                hasExplicitId: true,
                fingerprint: fingerprint
            ))
        }
    }

    /// Second half of a rename: drop the old file, but only when it is
    /// still exactly the note we expect. Failures are logged, never thrown —
    /// the new file is already the authoritative copy.
    private func removeSupersededFile(at url: URL, expectedId: String) {
        let relative = relativePath(of: url)
        guard Self.shouldRemoveSupersededFile(
            relativePath: relative ?? url.lastPathComponent,
            onDiskId: (try? readEntry(at: url))?.file.id,
            expectedId: expectedId
        ) else {
            Log.storage.info("NoteFileStore: kept \(url.lastPathComponent, privacy: .public) after rename (not the expected file)")
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
            writeGuard.recordRemoval(at: url)
            if let relative { index.removePath(relative) }
        } catch {
            Log.storage.error("NoteFileStore: failed to remove renamed-from file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Pure rename-cleanup rule: the superseded path may be removed only if
    /// it still parses as the same note and isn't a sync-conflict copy.
    nonisolated static func shouldRemoveSupersededFile(
        relativePath: String,
        onDiskId: String?,
        expectedId: String
    ) -> Bool {
        guard let onDiskId, onDiskId == expectedId else { return false }
        return !NoteVaultIndex.isConflictCopy(relativePath: relativePath)
    }

    /// Picks the target URL for a write. Existing files stay where they are
    /// (renamed in place on a title change); new daily notes land in
    /// `Daily/<YYYY-MM-DD>.md`, other new notes in the vault root.
    private func resolveTargetURL(for file: NoteFile, existing: URL?) throws -> URL {
        let existingIsRegular = existing.map {
            !NoteVaultIndex.isConflictCopy(relativePath: $0.lastPathComponent)
        } ?? false

        if file.frontmatter.isDailyNote, let date = file.frontmatter.dailyDate {
            // Daily notes are named by date, which never changes: keep the
            // file wherever it lives (the user may have filed it elsewhere).
            if let existing, existingIsRegular { return existing }
            let folder = try directory.dailyFolder()
            return try pickURL(in: folder, baseName: Self.dailyDateFormatter.string(from: date), id: file.id)
        }

        let desiredName = sanitize(filename: file.frontmatter.title.isEmpty
                                   ? "Untitled"
                                   : file.frontmatter.title)
        if let existing, existingIsRegular,
           existing.deletingPathExtension().lastPathComponent == desiredName {
            return existing
        }
        let folder = existing?.deletingLastPathComponent() ?? directory.root
        return try pickURL(in: folder, baseName: desiredName, id: file.id)
    }

    /// First of `<base>.md`, `<base> 2.md`, … in `folder` that is free or
    /// already belongs to `id`.
    private func pickURL(in folder: URL, baseName: String, id: String) throws -> URL {
        let fm = FileManager.default
        for i in 1...256 {
            let name = i == 1 ? baseName : "\(baseName) \(i)"
            let candidate = folder.appendingPathComponent("\(name).md")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            if let parsed = try? read(at: candidate), parsed.id == id { return candidate }
        }
        throw NoteFileStoreError.tooManyCollisions(baseName)
    }

    /// True when both URLs name the same file — by path, or by inode on the
    /// same volume (a case-only rename on a case-insensitive file system).
    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        if VaultWriteGuard.normalize(a.standardizedFileURL.path)
            == VaultWriteGuard.normalize(b.standardizedFileURL.path) {
            return true
        }
        let fm = FileManager.default
        guard let attrsA = try? fm.attributesOfItem(atPath: a.path),
              let attrsB = try? fm.attributesOfItem(atPath: b.path),
              let inodeA = (attrsA[.systemFileNumber] as? NSNumber)?.uint64Value,
              let inodeB = (attrsB[.systemFileNumber] as? NSNumber)?.uint64Value,
              let deviceA = (attrsA[.systemNumber] as? NSNumber)?.uint64Value,
              let deviceB = (attrsB[.systemNumber] as? NSNumber)?.uint64Value else {
            return false
        }
        return inodeA == inodeB && deviceA == deviceB
    }

    /// Moves `url` to the Trash where there is one (macOS); otherwise, or if
    /// trashing fails (e.g. a volume without a Trash), removes it.
    static func trashOrRemove(_ url: URL) throws {
        #if os(macOS)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return
        } catch {
            Log.storage.info("NoteFileStore: trash failed for \(url.lastPathComponent, privacy: .public), removing instead: \(error.localizedDescription, privacy: .public)")
        }
        #endif
        try FileManager.default.removeItem(at: url)
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
    nonisolated private static let dailyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

enum NoteFileStoreError: Error, Equatable, LocalizedError {
    case encodingFailed
    case tooManyCollisions(String)
    case changedSinceRead

    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "The note couldn't be encoded as UTF-8."
        case .tooManyCollisions(let name): return "Too many files are already named \u{201C}\(name)\u{201D}."
        case .changedSinceRead: return "The file changed on disk while Scribe was updating it."
        }
    }
}
