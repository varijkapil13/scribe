import Foundation

/// One file-system event delivered by `NoteVaultWatcher`. Kept free of
/// CoreServices types so the filter logic stays portable and unit-testable.
struct NoteVaultEvent: Equatable, Sendable {
    var path: String
    var isDirectory: Bool
    /// FSEvents coalesced / dropped events (`MustScanSubDirs`, root changed,
    /// …): the path alone can't say what changed, so always reconcile.
    var requiresFullScan: Bool

    init(path: String, isDirectory: Bool = false, requiresFullScan: Bool = false) {
        self.path = path
        self.isDirectory = isDirectory
        self.requiresFullScan = requiresFullScan
    }
}

/// Per-path suppression of the vault watcher for Scribe's own writes.
///
/// Every app-initiated mutation through `NoteFileStore` records the path it
/// touched together with the state it left behind (the written file's
/// fingerprint, or "absent" for a removal). When FSEvents later reports that
/// path, the event is ignored only if the file on disk *still* matches that
/// expectation — so an external edit (Obsidian, iCloud sync) to the same file
/// moments after an autosave is never swallowed, and edits to *other* files
/// are never affected at all. (The previous design suppressed every event in
/// a global one-second window after any write, which dropped real external
/// changes.)
final class VaultWriteGuard: @unchecked Sendable {

    static let shared = VaultWriteGuard()

    enum Expectation: Equatable, Sendable {
        case present(NoteFileFingerprint)
        case absent
    }

    private struct Record {
        let expectation: Expectation
        let recordedAt: Date
    }

    private let lock = NSLock()
    private var records: [String: Record] = [:]

    /// How long an expectation is honoured. Comfortably longer than the
    /// watcher's FSEvents latency; expired records are pruned lazily.
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 30) {
        self.ttl = ttl
    }

    // MARK: Recording

    func recordWrite(at url: URL, fingerprint: NoteFileFingerprint, now: Date = Date()) {
        record(.present(fingerprint), forPath: url.path, now: now)
    }

    func recordRemoval(at url: URL, now: Date = Date()) {
        record(.absent, forPath: url.path, now: now)
    }

    /// Legacy no-op kept for source compatibility with callers written for
    /// the old global time window. `NoteFileStore` now records every write
    /// per path automatically, so there is nothing to stamp here.
    func recordSelfWrite(at time: Date = Date()) {}

    private func record(_ expectation: Expectation, forPath path: String, now: Date) {
        let key = Self.normalize(path)
        lock.lock(); defer { lock.unlock() }
        records[key] = Record(expectation: expectation, recordedAt: now)
        if records.count > 256 {
            records = records.filter { now.timeIntervalSince($0.value.recordedAt) < ttl }
        }
    }

    // MARK: Querying

    /// The live expectation for `path`, if a self-write was recorded there
    /// within the TTL.
    func expectation(forPath path: String, now: Date = Date()) -> Expectation? {
        let key = Self.normalize(path)
        lock.lock(); defer { lock.unlock() }
        guard let record = records[key] else { return nil }
        guard now.timeIntervalSince(record.recordedAt) < ttl else {
            records.removeValue(forKey: key)
            return nil
        }
        return record.expectation
    }

    /// True when the event at `path` is fully explained by Scribe's own
    /// recorded write: an expectation exists and the file on disk still
    /// matches it. Reads the file only when the stat fast path disagrees.
    func isOwnWrite(atPath path: String, now: Date = Date()) -> Bool {
        guard let expectation = expectation(forPath: path, now: now) else { return false }
        let url = URL(fileURLWithPath: path)
        switch expectation {
        case .absent:
            return NoteFileFingerprint.statFile(at: url) == nil
        case .present(let expected):
            return Self.matches(expectation, current: NoteFileFingerprint.current(at: url, reusing: expected))
        }
    }

    /// Pure comparison: does the on-disk state (`current`, nil = no file)
    /// match what Scribe left there?
    nonisolated static func matches(_ expectation: Expectation, current: NoteFileFingerprint?) -> Bool {
        switch expectation {
        case .absent:
            return current == nil
        case .present(let expected):
            guard let current else { return false }
            return current.describesSameContent(as: expected)
        }
    }

    /// Decides whether a batch of watcher events needs a reconcile. Events
    /// for hidden paths (`.git`, `.obsidian`, atomic-write temp files) and
    /// non-markdown files never do; markdown events need one unless
    /// `isOwnWrite` explains them; directory events and coalesced events
    /// always do.
    nonisolated static func requiresReconcile(
        events: [NoteVaultEvent],
        root: URL,
        isOwnWrite: (String) -> Bool
    ) -> Bool {
        for event in events {
            if event.requiresFullScan { return true }
            guard let relative = relativePath(of: event.path, under: root.path) else {
                // The root itself (or an unexpected path): be safe.
                return true
            }
            let components = relative.split(separator: "/")
            if components.contains(where: { $0.hasPrefix(".") }) { continue }
            if event.isDirectory { return true }
            let ext = (relative as NSString).pathExtension.lowercased()
            if ext.isEmpty { return true }          // could be a folder move
            guard ext == "md" else { continue }      // attachments, images, …
            if isOwnWrite(event.path) { continue }
            return true
        }
        return false
    }

    // MARK: Paths

    /// Strips macOS's `/private` alias and trailing slashes so FSEvents paths
    /// and Scribe-constructed URLs compare equal.
    nonisolated static func normalize(_ path: String) -> String {
        var p = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// `path` relative to `root` (both normalised), or nil when `path` is the
    /// root itself or lies outside it.
    nonisolated static func relativePath(of path: String, under root: String) -> String? {
        let p = normalize(path)
        let r = normalize(root)
        let prefix = r == "/" ? "/" : r + "/"
        guard p.hasPrefix(prefix) else { return nil }
        let rel = String(p.dropFirst(prefix.count))
        return rel.isEmpty ? nil : rel
    }
}
