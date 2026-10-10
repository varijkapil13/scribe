// Scribe/Shared/ScribeSharePayload.swift
//
// Share extension → app hand-off. The extension writes one folder per share
// into the App Group `ShareInbox/` (images first, `payload.json` last, so a
// folder without a payload is still being written) and opens
// `scribe://import-share`; the app imports and deletes each folder
// (`ScribeShareInboxImporter`). Shared with the ScribeShare extension;
// Foundation-only.

import Foundation

struct ScribeSharePayload: Codable, Equatable, Sendable {

    enum Destination: String, Codable, CaseIterable, Sendable, Hashable {
        case newNote
        case appendToInbox
        case newTask

        var label: String {
            switch self {
            case .newNote:       return "New note"
            case .appendToInbox: return "Append to Inbox note"
            case .newTask:       return "New task"
            }
        }
    }

    var id: String
    var createdAt: Date
    var destination: Destination
    /// What the user typed in the Title field (may be empty).
    var title: String
    /// Shared text (selection, page title, …); empty when none.
    var text: String
    /// Shared web URLs, absolute strings.
    var urls: [String]
    /// Image files saved next to `payload.json` in the item folder. Despite
    /// the name it may also list other shared files (the iOS Share extension
    /// sends PDFs this way); the importer links non-images instead of
    /// embedding them.
    var imageFileNames: [String]

    init(
        id: String = UUID().uuidString,
        createdAt: Date,
        destination: Destination,
        title: String,
        text: String,
        urls: [String],
        imageFileNames: [String]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.destination = destination
        self.title = title
        self.text = text
        self.urls = urls
        self.imageFileNames = imageFileNames
    }

    /// Whether there is anything to import.
    var hasContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !urls.isEmpty
            || !imageFileNames.isEmpty
    }
}

/// An image (or another file, e.g. a PDF) the Share extension received,
/// before it's written to the inbox.
struct ScribeShareImage: Sendable, Equatable {
    var data: Data
    /// Lower-case file extension without the dot (`png`, `jpg`, …).
    var fileExtension: String

    init(data: Data, fileExtension: String) {
        self.data = data
        self.fileExtension = fileExtension
    }
}

/// The `ShareInbox/` folder in the App Group container.
struct ScribeShareInbox: Sendable {

    static let payloadFileName = "payload.json"

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    init(container: URL) {
        self.directory = container.appendingPathComponent(ScribeAppGroup.shareInboxFolderName, isDirectory: true)
    }

    static func appGroup() -> ScribeShareInbox? {
        ScribeAppGroup.containerURL().map { ScribeShareInbox(container: $0) }
    }

    /// Writes one share: `<inbox>/<payload.id>/image-N.ext…` (documents
    /// such as PDFs: `document-N.ext`) then
    /// `payload.json` (atomically, last). `payload.imageFileNames` is filled
    /// in from `images`. Returns the item folder.
    @discardableResult
    func write(_ payload: ScribeSharePayload, images: [ScribeShareImage]) throws -> URL {
        let folder = directory.appendingPathComponent(Self.safeFolderName(payload.id), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var names: [String] = []
        for (index, image) in images.enumerated() {
            let ext = Self.safeExtension(image.fileExtension)
            let stem = Self.isDocumentExtension(ext) ? "document" : "image"
            let name = "\(stem)-\(index + 1).\(ext)"
            try image.data.write(to: folder.appendingPathComponent(name, isDirectory: false), options: .atomic)
            names.append(name)
        }
        var stored = payload
        stored.imageFileNames = names
        let data = try ScribeAppGroup.makeEncoder().encode(stored)
        try data.write(to: folder.appendingPathComponent(Self.payloadFileName, isDirectory: false), options: .atomic)
        return folder
    }

    /// Complete item folders (those with a `payload.json`), oldest first by
    /// folder modification date, then name.
    func pendingItemFolders() -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let folders = entries.filter { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir && fm.fileExists(atPath: url.appendingPathComponent(Self.payloadFileName).path)
        }
        return folders.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l == r ? lhs.lastPathComponent < rhs.lastPathComponent : l < r
        }
    }

    /// Decodes an item folder's payload.
    func readPayload(in folder: URL) throws -> ScribeSharePayload {
        let data = try Data(contentsOf: folder.appendingPathComponent(Self.payloadFileName, isDirectory: false))
        return try ScribeAppGroup.makeDecoder().decode(ScribeSharePayload.self, from: data)
    }

    /// The URL of an image listed in a payload, or nil when the name could
    /// escape the folder or the file is missing.
    func imageURL(named name: String, in folder: URL) -> URL? {
        guard Self.isSafeFileName(name) else { return nil }
        let url = folder.appendingPathComponent(name, isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Name safety

    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "." && name != ".."
            && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    static func safeFolderName(_ id: String) -> String {
        isSafeFileName(id) ? id : UUID().uuidString
    }

    /// Non-image files the iOS Share extension hands over (written as
    /// `document-N.ext`; everything else keeps the `image-N` name).
    static let documentExtensions: Set<String> = ["pdf"]

    static func isDocumentExtension(_ ext: String) -> Bool {
        documentExtensions.contains(ext.lowercased())
    }

    static func safeExtension(_ raw: String) -> String {
        let cleaned = String(raw.lowercased().unicodeScalars.filter {
            ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9")
        }.map(Character.init))
        return cleaned.isEmpty || cleaned.count > 10 ? "png" : cleaned
    }
}
