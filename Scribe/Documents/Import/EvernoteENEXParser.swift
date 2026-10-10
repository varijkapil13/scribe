// Scribe/Documents/Import/EvernoteENEXParser.swift
//
// Parses an Evernote export (.enex): one XML document with <note> elements,
// each carrying a title, dates, tags, ENML content (in CDATA) and base64
// <resource>s. Pure Foundation (XMLParser) + CryptoKit for the MD5 hashes
// ENML's <en-media hash="…"> uses to reference resources.

import CryptoKit
import Foundation

/// One attachment of an Evernote note.
struct EvernoteResource: Equatable, Sendable {
    var data: Data
    var mimeType: String
    var fileName: String?
    /// Lowercase hex MD5 of `data` — what `<en-media hash>` refers to.
    var hash: String
}

/// One note of an Evernote export.
struct EvernoteNote: Equatable, Sendable {
    var title: String
    var contentENML: String
    var created: Date?
    var updated: Date?
    var tags: [String]
    var resources: [EvernoteResource]
}

enum EvernoteENEXError: Error, LocalizedError, Equatable {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let reason): return "The Evernote export couldn't be read: \(reason)"
        }
    }
}

enum EvernoteENEXParser {

    /// Parses ENEX data. Throws only when the XML is unreadable before any
    /// note was found; a truncated file still yields the notes parsed so far.
    static func parse(data: Data) throws -> [EvernoteNote] {
        let delegate = ENEXParserDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let ok = parser.parse()
        if !ok, delegate.notes.isEmpty {
            let reason = parser.parserError?.localizedDescription ?? "invalid XML"
            throw EvernoteENEXError.unreadable(reason)
        }
        return delegate.notes
    }

    static func parse(contentsOf url: URL) throws -> [EvernoteNote] {
        try parse(data: Data(contentsOf: url))
    }

    /// Evernote timestamps: `20240131T094500Z` (UTC).
    static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        if let date = formatter.date(from: trimmed) { return date }
        let iso = ISO8601DateFormatter()
        return iso.date(from: trimmed)
    }

    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }

    /// Converts a note's ENML to Markdown, mapping each `<en-media>` through
    /// `embed(resource) -> markdown destination` (nil drops it). Images become
    /// `![name](dest)`, other files `[name](dest)`.
    static func markdown(
        for note: EvernoteNote,
        embed: @escaping (EvernoteResource) -> String?
    ) -> String {
        let byHash = Dictionary(note.resources.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })
        var options = HTMLMarkdownOptions()
        options.resolveMedia = { attributes in
            let hash = (attributes["hash"] ?? "").lowercased()
            guard let resource = byHash[hash], let destination = embed(resource) else { return nil }
            let name = resource.fileName ?? (resource.mimeType.hasPrefix("image/") ? "" : "Attachment")
            let label = HTMLMarkdownRenderer.escapeBrackets(name)
            let target = HTMLMarkdownRenderer.markdownDestination(destination)
            return resource.mimeType.lowercased().hasPrefix("image/")
                ? "![\(label)](\(target))"
                : "[\(label.isEmpty ? "Attachment" : label)](\(target))"
        }
        return HTMLMarkdownConverter.markdown(fromHTML: note.contentENML, options: options)
    }
}

/// XMLParser delegate collecting notes. Used synchronously inside
/// `EvernoteENEXParser.parse` only.
private final class ENEXParserDelegate: NSObject, XMLParserDelegate {
    var notes: [EvernoteNote] = []

    private var path: [String] = []
    private var text = ""
    private var current: EvernoteNote?
    private var resourceData = ""
    private var resourceMime = ""
    private var resourceFileName: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        path.append(elementName)
        text = ""
        switch elementName {
        case "note":
            current = EvernoteNote(title: "", contentENML: "", created: nil, updated: nil, tags: [], resources: [])
        case "resource":
            resourceData = ""
            resourceMime = ""
            resourceFileName = nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer {
            if !path.isEmpty { path.removeLast() }
            text = ""
        }
        let parent = path.count >= 2 ? path[path.count - 2] : ""
        let inResource = path.contains("resource")
        switch elementName {
        case "title" where parent == "note":
            current?.title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "content" where parent == "note":
            current?.contentENML = text
        case "created" where parent == "note":
            current?.created = EvernoteENEXParser.parseDate(text)
        case "updated" where parent == "note":
            current?.updated = EvernoteENEXParser.parseDate(text)
        case "tag" where parent == "note":
            let tag = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tag.isEmpty { current?.tags.append(tag) }
        case "data" where inResource && parent == "resource":
            resourceData = text
        case "mime" where inResource && parent == "resource":
            resourceMime = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "file-name" where inResource:
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { resourceFileName = name }
        case "resource":
            if let data = Data(base64Encoded: resourceData, options: .ignoreUnknownCharacters), !data.isEmpty {
                current?.resources.append(EvernoteResource(
                    data: data,
                    mimeType: resourceMime.isEmpty ? "application/octet-stream" : resourceMime,
                    fileName: resourceFileName,
                    hash: EvernoteENEXParser.md5Hex(data)
                ))
            }
        case "note":
            if let note = current { notes.append(note) }
            current = nil
        default:
            break
        }
    }
}
