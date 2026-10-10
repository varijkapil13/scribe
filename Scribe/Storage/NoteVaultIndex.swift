import CryptoKit
import Foundation

// MARK: - Fingerprint

/// Identity of one on-disk version of a note file: modification date + size
/// as a cheap fast path, plus a SHA-256 of the bytes as the authority.
///
/// Used to tell "the file is still the version we loaded / wrote" apart from
/// "something outside Scribe changed it" — both for the editor's
/// external-edit check and for the vault watcher's self-write suppression.
struct NoteFileFingerprint: Equatable, Sendable {
    var modificationDate: Date?
    var size: Int?
    var contentHash: String

    init(modificationDate: Date?, size: Int?, contentHash: String) {
        self.modificationDate = modificationDate
        self.size = size
        self.contentHash = contentHash
    }

    /// Fingerprint for `data` that Scribe just wrote to `url`. The
    /// modification date is read back from the file system so it matches
    /// what a later `current(at:)` stat returns.
    static func of(data: Data, at url: URL) -> NoteFileFingerprint {
        let stat = statFile(at: url)
        return NoteFileFingerprint(
            modificationDate: stat?.modificationDate,
            size: stat?.size ?? data.count,
            contentHash: hash(data)
        )
    }

    /// Current fingerprint of the file at `url`, or nil when it doesn't exist
    /// (or can't be read). When `known` still matches the file's modification
    /// date and size, it is returned as-is without reading the bytes.
    static func current(at url: URL, reusing known: NoteFileFingerprint? = nil) -> NoteFileFingerprint? {
        guard let stat = statFile(at: url) else { return nil }
        if let known, known.modificationDate != nil,
           known.modificationDate == stat.modificationDate, known.size == stat.size {
            return known
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NoteFileFingerprint(
            modificationDate: stat.modificationDate,
            size: stat.size,
            contentHash: hash(data)
        )
    }

    /// True when both fingerprints describe the same file contents: either the
    /// stat fast path agrees or the bytes hash identically (a `touch` changes
    /// the date but not the content).
    func describesSameContent(as other: NoteFileFingerprint) -> Bool {
        contentHash == other.contentHash
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Uncached stat (unlike `URL.resourceValues`, which caches per URL
    /// instance and would hide a change made after the first query).
    static func statFile(at url: URL) -> (modificationDate: Date?, size: Int)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        return (attributes[.modificationDate] as? Date, size)
    }
}

// MARK: - Stable ids

/// Ids for notes whose file carries no `id:` frontmatter (a file dropped in
/// by Finder / Obsidian / another tool).
///
/// Until Scribe pins an id into the file, the id is *derived* from the
/// vault-relative path, so every read — and every reconcile pass — agrees on
/// it. The reconciler then pins that same derived id into the frontmatter the
/// first time it indexes the file, after which the id survives renames.
enum NoteStableId {

    /// Deterministic UUID-formatted id for a vault-relative path. Unicode
    /// normalised (NFC) so a Finder-created NFD filename and its NFC spelling
    /// map to the same id.
    nonisolated static func derivedId(forRelativePath relativePath: String) -> String {
        let normalized = relativePath.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data("scribe-note-path:\(normalized)".utf8))
        var b = Array(digest)
        // Stamp RFC 4122 version (5-style, name-based) + variant bits so the
        // result parses as a regular UUID everywhere ids are validated.
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
        ))
        return uuid.uuidString
    }
}

// MARK: - Index

/// One parsed `.md` file plus the facts the index / reconciler need about it.
struct NoteFileEntry: Equatable, Sendable {
    var url: URL
    /// Path relative to the vault root, `/`-separated (e.g. `Projects/Plan.md`).
    var relativePath: String
    var file: NoteFile
    /// False when the id came from the path-derived fallback rather than an
    /// `id:` line in the file's frontmatter.
    var hasExplicitId: Bool
    var fingerprint: NoteFileFingerprint
}

/// In-memory id → vault-relative-path map, plus a per-path parse cache.
///
/// Built by the reconciler's full listing and kept current by every
/// `NoteFileStore` write / rename / delete, so looking up the file behind a
/// note id (autosave, fetch, properties) is one file read instead of a scan
/// that parses the whole vault. Lookups are verified against the file's own
/// frontmatter id and fall back to a scan on a miss, so a stale entry can
/// never point a write at the wrong file.
///
/// Shared by reference between copies of the same `NoteFileStore`.
final class NoteVaultIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var pathsById: [String: String] = [:]
    private var lastWrittenById: [String: NoteFileFingerprint] = [:]
    private var cacheByPath: [String: NoteFileEntry] = [:]
    private var hasCompleteListing = false

    init() {}

    /// True once a full vault listing populated the map. From then on, an
    /// id with *no* entry is known not to have a file (every Scribe write
    /// and every reconcile keeps the map current), so lookups can skip the
    /// fallback scan; a *stale* entry still falls back to scanning.
    var isComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return hasCompleteListing
    }

    // MARK: id → path

    func relativePath(for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return pathsById[id]
    }

    /// Records `relativePath` as the file for `id` — authoritative (used
    /// after Scribe itself wrote or verified that file).
    func setRelativePath(_ relativePath: String, for id: String) {
        lock.lock(); defer { lock.unlock() }
        pathsById[id] = relativePath
    }

    /// Records a mapping discovered while scanning. A `(conflicted copy)`
    /// never displaces a mapping to a regular file, and two regular files
    /// claiming one id resolve deterministically.
    func recordScanned(_ relativePath: String, for id: String) {
        lock.lock(); defer { lock.unlock() }
        Self.assign(relativePath, to: id, in: &pathsById)
    }

    func removeId(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        pathsById.removeValue(forKey: id)
        lastWrittenById.removeValue(forKey: id)
    }

    /// Drops any id still mapped to `relativePath` (the file is gone).
    func removePath(_ relativePath: String) {
        lock.lock(); defer { lock.unlock() }
        for (id, path) in pathsById where path == relativePath {
            pathsById.removeValue(forKey: id)
        }
        cacheByPath.removeValue(forKey: relativePath)
    }

    /// Replaces the whole map from a complete vault listing.
    func replaceAll(with entries: [NoteFileEntry]) {
        var fresh: [String: String] = [:]
        for entry in entries {
            Self.assign(entry.relativePath, to: entry.file.id, in: &fresh)
        }
        lock.lock(); defer { lock.unlock() }
        pathsById = fresh
        hasCompleteListing = true
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return pathsById.count
    }

    // MARK: Self-write fingerprints

    func lastWrittenFingerprint(for id: String) -> NoteFileFingerprint? {
        lock.lock(); defer { lock.unlock() }
        return lastWrittenById[id]
    }

    func setLastWrittenFingerprint(_ fingerprint: NoteFileFingerprint, for id: String) {
        lock.lock(); defer { lock.unlock() }
        lastWrittenById[id] = fingerprint
    }

    // MARK: Parse cache

    func cachedEntry(forPath relativePath: String) -> NoteFileEntry? {
        lock.lock(); defer { lock.unlock() }
        return cacheByPath[relativePath]
    }

    func cache(_ entry: NoteFileEntry) {
        lock.lock(); defer { lock.unlock() }
        cacheByPath[entry.relativePath] = entry
    }

    /// Keeps only cache entries for paths present in the latest listing.
    func pruneCache(keeping relativePaths: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        cacheByPath = cacheByPath.filter { relativePaths.contains($0.key) }
    }

    // MARK: Helpers

    nonisolated static func isConflictCopy(relativePath: String) -> Bool {
        let name = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        return NoteConflictDetector.stripConflictSuffix(name) != nil
    }

    private static func assign(_ relativePath: String, to id: String, in map: inout [String: String]) {
        if let existing = map[id], existing != relativePath,
           !isConflictCopy(relativePath: existing), isConflictCopy(relativePath: relativePath) {
            return
        }
        if let existing = map[id], existing != relativePath,
           !isConflictCopy(relativePath: existing), !isConflictCopy(relativePath: relativePath),
           existing < relativePath {
            // Two regular files claim the same id (a Finder duplicate):
            // pick deterministically so repeated passes agree.
            return
        }
        map[id] = relativePath
    }
}
