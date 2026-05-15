// Scribe/UI/DesignSystem/ImageLoader.swift
import AppKit
import Foundation

/// Loads and caches `NSImage`s referenced by markdown image links. Resolves
/// paths against the Scribe Application Support root so a markdown body like
/// `![](attachments/<noteId>/<file>.png)` works.
enum ImageLoader {

    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]
    nonisolated(unsafe) private static let cacheQueue = DispatchQueue(label: "scribe.imageloader.cache")
    private static let cacheCap = 32

    static func load(path: String) -> NSImage? {
        if let cached = cacheQueue.sync(execute: { cache[path] }) {
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
        cacheQueue.sync {
            if cache.count >= cacheCap {
                cache.removeAll()
            }
            cache[path] = img
        }
        return img
    }
}
