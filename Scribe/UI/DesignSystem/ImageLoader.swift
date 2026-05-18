// Scribe/UI/DesignSystem/ImageLoader.swift
import AppKit
import Foundation

/// Loads and caches `NSImage`s referenced by markdown image links. Resolves
/// paths against the Scribe Application Support root so a markdown body like
/// `![](attachments/<noteId>/<file>.png)` works.
///
/// The cache is a bounded LRU: on a hit the entry is bumped to most-recent,
/// on overflow only the oldest entry is evicted (not the whole map). This
/// avoids visible flicker when the working set hovers near the cap.
enum ImageLoader {

    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]
    nonisolated(unsafe) private static var order: [String] = []
    nonisolated(unsafe) private static let cacheQueue = DispatchQueue(label: "scribe.imageloader.cache")
    private static let cacheCap = 32

    static func load(path: String) -> NSImage? {
        // Defence in depth: a markdown body is user-trusted today but might be
        // pasted from elsewhere tomorrow. We constrain every load to resolve
        // inside the per-app attachments root so a crafted link can't read
        // arbitrary files. Three guards, in order:
        //
        //   1. Reject `..` segments before any URL resolution.
        //   2. Resolve the candidate URL the same way as before.
        //   3. After standardising + resolving symlinks on both sides,
        //      enforce that the candidate's canonical path is a sub-path of
        //      the canonical attachments root. If not, refuse to load.
        //
        // Result: `![](attachments/<noteId>/<file>)` works; `![](/etc/passwd)`,
        // `![](file:///etc/passwd)`, and `![](attachments/../../../etc/...)`
        // all return nil.
        if path.split(separator: "/").contains("..") { return nil }

        if let cached = cacheQueue.sync(execute: { fetchAndBump(path) }) {
            return cached
        }

        let root = AttachmentsDirectory.defaultRoot()
        let candidate: URL
        if path.hasPrefix("file://") {
            candidate = URL(fileURLWithPath: String(path.dropFirst("file://".count)))
        } else if path.hasPrefix("/") {
            candidate = URL(fileURLWithPath: path)
        } else {
            candidate = root.appendingPathComponent(path)
        }

        let canonicalCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        // Require the candidate to be the root or live strictly underneath it.
        // The trailing "/" is what makes "/Foo/Scribe-evil" fail to match
        // "/Foo/Scribe".
        let rootPrefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        guard canonicalCandidate == canonicalRoot
                || canonicalCandidate.hasPrefix(rootPrefix) else {
            return nil
        }

        guard let img = NSImage(contentsOf: candidate) else { return nil }
        cacheQueue.sync { insert(path, img) }
        return img
    }

    // MARK: - LRU primitives (must run on cacheQueue)

    private static func fetchAndBump(_ key: String) -> NSImage? {
        guard let img = cache[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return img
    }

    private static func insert(_ key: String, _ img: NSImage) {
        if cache[key] != nil {
            order.removeAll { $0 == key }
        }
        cache[key] = img
        order.append(key)
        while order.count > cacheCap {
            let evicted = order.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }
}
