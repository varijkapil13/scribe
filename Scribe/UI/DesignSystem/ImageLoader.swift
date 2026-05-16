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
        // Path-traversal guard: reject any path containing `..` segments so a
        // crafted markdown link can't escape the attachments root. The note
        // body is user-trusted but cheap to harden.
        if path.split(separator: "/").contains("..") { return nil }

        if let cached = cacheQueue.sync(execute: { fetchAndBump(path) }) {
            return cached
        }
        let url: URL
        if path.hasPrefix("file://") {
            url = URL(fileURLWithPath: String(path.dropFirst("file://".count)))
        } else if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            let root = AttachmentsDirectory.defaultRoot()
            url = root.appendingPathComponent(path)
        }
        guard let img = NSImage(contentsOf: url) else { return nil }
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
