// Scribe/Documents/Import/NoteImportSources.swift
//
// Source readers: turn an Evernote export, a Notion export folder, a
// Markdown folder (Bear / Obsidian / plain) or an exported Apple Notes
// folder into `ImportedNoteDraft`s. File-system access lives here; the text
// conversion is in the pure converters (HTMLMarkdownConverter,
// EvernoteENEXParser, MarkdownImportRewriter). Nonisolated — run off the
// main actor.

import Foundation
import UniformTypeIdentifiers

/// What the user is importing.
enum NoteImportKind: String, CaseIterable, Identifiable, Sendable {
    case evernote
    case notion
    case markdownFolder
    case appleNotes
    case documents

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .evernote: return "Evernote Export (.enex)…"
        case .notion: return "Notion Export…"
        case .markdownFolder: return "Markdown Folder (Bear, Obsidian)…"
        case .appleNotes: return "Apple Notes Export Folder…"
        case .documents: return "PDF or Image as Note…"
        }
    }

    var sourceLabel: String {
        switch self {
        case .evernote: return "Evernote"
        case .notion: return "Notion"
        case .markdownFolder: return "Markdown folder"
        case .appleNotes: return "Apple Notes"
        case .documents: return "Documents"
        }
    }
}

/// The drafts read from a source plus non-fatal problems.
struct NoteImportReadResult: Sendable {
    var drafts: [ImportedNoteDraft] = []
    var warnings: [String] = []
}

enum NoteImportSources {

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "txt"]
    static let htmlExtensions: Set<String> = ["html", "htm"]

    // MARK: - Evernote

    static func readEvernote(_ urls: [URL]) -> NoteImportReadResult {
        var result = NoteImportReadResult()
        for url in urls {
            do {
                let notes = try EvernoteENEXParser.parse(contentsOf: url)
                let notebook = url.deletingPathExtension().lastPathComponent
                for note in notes {
                    result.drafts.append(evernoteDraft(note, notebook: notebook, sourceName: url.lastPathComponent))
                }
                if notes.isEmpty {
                    result.warnings.append("\(url.lastPathComponent) contains no notes.")
                }
            } catch {
                result.warnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    static func evernoteDraft(_ note: EvernoteNote, notebook: String, sourceName: String) -> ImportedNoteDraft {
        var collector = ImportAttachmentCollector()
        var embedded = Set<String>()
        var body = EvernoteENEXParser.markdown(for: note) { resource in
            embedded.insert(resource.hash)
            return registerResource(resource, into: &collector)
        }
        // Resources the ENML never referenced still come along, listed at the end.
        let leftovers = note.resources.filter { !embedded.contains($0.hash) }
        if !leftovers.isEmpty {
            var lines: [String] = []
            for resource in leftovers {
                let destination = registerResource(resource, into: &collector)
                let label = HTMLMarkdownRenderer.escapeBrackets(resource.fileName ?? "Attachment")
                lines.append(resource.mimeType.lowercased().hasPrefix("image/")
                             ? "![\(label)](\(destination))"
                             : "- [\(label)](\(destination))")
            }
            body += (body.isEmpty ? "" : "\n\n") + lines.joined(separator: "\n")
        }
        return ImportedNoteDraft(
            title: note.title.isEmpty ? "Untitled" : note.title,
            body: body,
            tags: note.tags,
            createdAt: note.created,
            updatedAt: note.updated,
            notebookPath: notebook.isEmpty ? [] : [notebook],
            attachments: collector.attachments,
            sourceName: "\(sourceName) › \(note.title.isEmpty ? "Untitled" : note.title)"
        )
    }

    static func registerResource(_ resource: EvernoteResource, into collector: inout ImportAttachmentCollector) -> String {
        let name = resource.fileName
            ?? "attachment.\(EditorAttachmentFiles.preferredExtension(forMIMEType: resource.mimeType) ?? "bin")"
        return collector.register(
            ImportedAttachmentSource(content: .data(resource.data), filename: name, mimeType: resource.mimeType),
            dedupeKey: resource.hash
        )
    }

    // MARK: - Notion

    static func readNotion(root: URL) -> NoteImportReadResult {
        var result = NoteImportReadResult()
        let files = walk(root)
        let rootTitle = MarkdownImportRewriter.stripNotionId(root.lastPathComponent)
        let notebookPath = rootTitle.isEmpty ? [] : [rootTitle]

        let pageFiles = files.filter { markdownExtensions.contains($0.url.pathExtension.lowercased()) }
        let csvFiles = files.filter { $0.url.pathExtension.lowercased() == "csv" }
        let csvNames = Set(csvFiles.map { $0.relativePath.lowercased() })
        // Notion writes "DB <id>.csv" and "DB <id>_all.csv"; keep one per database.
        let databases = csvFiles.filter { file in
            let lower = file.relativePath.lowercased()
            if lower.hasSuffix("_all.csv") { return true }
            return !csvNames.contains(String(lower.dropLast(4)) + "_all.csv")
        }
        let pageTitles = Set(pageFiles.map { MarkdownImportRewriter.notionTitle(forFileName: $0.url.lastPathComponent).lowercased() })

        for file in pageFiles {
            do {
                let contents = try readText(file.url)
                let title = MarkdownImportRewriter.notionTitle(forFileName: file.url.lastPathComponent)
                var collector = ImportAttachmentCollector()
                let folder = (file.relativePath as NSString).deletingLastPathComponent
                var body = MarkdownImportRewriter.removingLeadingTitleHeading(contents, title: title)
                body = MarkdownImportRewriter.rewriteLinks(in: body) { match in
                    notionReplacement(for: match, folder: folder, root: root, collector: &collector)
                }
                body = MarkdownImportRewriter.rewriteImageTags(in: body) { src in
                    attachmentPlaceholder(forRelative: src, folder: folder, root: root, collector: &collector)
                }
                let attrs = fileDates(file.url)
                result.drafts.append(ImportedNoteDraft(
                    title: title,
                    body: body,
                    createdAt: attrs.created,
                    updatedAt: attrs.modified,
                    notebookPath: notebookPath,
                    attachments: collector.attachments,
                    sourceName: file.relativePath
                ))
            } catch {
                result.warnings.append("\(file.relativePath): \(error.localizedDescription)")
            }
        }

        for file in databases {
            do {
                let rows = MarkdownImportRewriter.parseCSV(try readText(file.url))
                guard !rows.isEmpty else { continue }
                var name = (file.url.lastPathComponent as NSString).deletingPathExtension
                if name.lowercased().hasSuffix("_all") { name = String(name.dropLast(4)) }
                let title = MarkdownImportRewriter.stripNotionId(name)
                let table = MarkdownImportRewriter.markdownTable(fromCSV: rows) { value in
                    pageTitles.contains(value.lowercased())
                }
                let attrs = fileDates(file.url)
                result.drafts.append(ImportedNoteDraft(
                    title: title,
                    body: table,
                    createdAt: attrs.created,
                    updatedAt: attrs.modified,
                    notebookPath: notebookPath,
                    sourceName: file.relativePath
                ))
            } catch {
                result.warnings.append("\(file.relativePath): \(error.localizedDescription)")
            }
        }
        return result
    }

    private static func notionReplacement(
        for match: MarkdownLinkMatch,
        folder: String,
        root: URL,
        collector: inout ImportAttachmentCollector
    ) -> String? {
        guard !match.isExternal else { return nil }
        let decoded = match.decodedDestination
        let ext = (decoded as NSString).pathExtension.lowercased()
        if !match.isImage, markdownExtensions.contains(ext) || ext == "csv" {
            var name = ((decoded as NSString).lastPathComponent as NSString).deletingPathExtension
            if name.lowercased().hasSuffix("_all") { name = String(name.dropLast(4)) }
            let title = MarkdownImportRewriter.stripNotionId(name)
            return title.isEmpty ? nil : "[[\(title)]]"
        }
        guard let placeholder = attachmentPlaceholder(forRelative: match.destination, folder: folder, root: root, collector: &collector) else {
            return nil
        }
        return match.isImage ? "![\(match.text)](\(placeholder))" : "[\(match.text)](\(placeholder))"
    }

    // MARK: - Markdown folder (Bear, Obsidian, plain)

    static func readMarkdownFolder(root: URL) -> NoteImportReadResult {
        var result = NoteImportReadResult()
        let files = walk(root)
        let index = FileNameIndex(files: files)
        let rootName = root.lastPathComponent

        for file in files where file.isNoteFile {
            do {
                let draft = try markdownDraft(for: file, root: root, rootName: rootName, index: index)
                result.drafts.append(draft)
            } catch {
                result.warnings.append("\(file.relativePath): \(error.localizedDescription)")
            }
        }
        return result
    }

    static func markdownDraft(for file: WalkedFile, root: URL, rootName: String, index: FileNameIndex) throws -> ImportedNoteDraft {
        let contents = try readText(file.url)
        let (meta, rawBody) = MarkdownImportRewriter.splitFrontmatter(contents)
        let fallbackTitle = file.noteTitle
        let title = meta.title ?? fallbackTitle
        var collector = ImportAttachmentCollector()
        let folder = file.linkBaseFolder
        var body = MarkdownImportRewriter.removingLeadingTitleHeading(rawBody, title: title)
        body = MarkdownImportRewriter.rewriteLinks(in: body) { match in
            guard !match.isExternal else { return nil }
            let decoded = match.decodedDestination
            let ext = (decoded as NSString).pathExtension.lowercased()
            if !match.isImage, markdownExtensions.contains(ext) {
                let name = ((decoded as NSString).lastPathComponent as NSString).deletingPathExtension
                return name.isEmpty ? nil : "[[\(name)]]"
            }
            var placeholder = attachmentPlaceholder(forRelative: match.destination, folder: folder, root: root, collector: &collector)
            if placeholder == nil {
                placeholder = attachmentPlaceholder(byName: decoded, index: index, collector: &collector)
            }
            guard let placeholder else { return nil }
            return match.isImage ? "![\(match.text)](\(placeholder))" : "[\(match.text)](\(placeholder))"
        }
        body = MarkdownImportRewriter.rewriteEmbeds(in: body) { target in
            let ext = (target as NSString).pathExtension.lowercased()
            if ext.isEmpty || markdownExtensions.contains(ext) {
                return "[[\((target as NSString).deletingPathExtension)]]"
            }
            var placeholder = attachmentPlaceholder(byName: target, index: index, collector: &collector)
            if placeholder == nil {
                placeholder = attachmentPlaceholder(forRelative: target, folder: folder, root: root, collector: &collector)
            }
            guard let placeholder else { return nil }
            let label = (target as NSString).lastPathComponent
            return EditorAttachmentFiles.isImage(filename: target, mimeType: nil)
                ? "![\(label)](\(placeholder))"
                : "[\(label)](\(placeholder))"
        }
        body = MarkdownImportRewriter.rewriteImageTags(in: body) { src in
            attachmentPlaceholder(forRelative: src, folder: folder, root: root, collector: &collector)
        }
        let dates = fileDates(file.url)
        return ImportedNoteDraft(
            title: title,
            body: body,
            tags: meta.tags,
            createdAt: meta.created ?? dates.created,
            updatedAt: meta.updated ?? dates.modified,
            notebookPath: [rootName] + file.folderComponents,
            attachments: collector.attachments,
            extra: meta.extra,
            sourceName: file.relativePath
        )
    }

    // MARK: - Apple Notes (exported HTML / Markdown folder)

    static func readAppleNotes(root: URL) -> NoteImportReadResult {
        var result = NoteImportReadResult()
        let files = walk(root)
        let index = FileNameIndex(files: files)
        let rootName = root.lastPathComponent
        for file in files {
            let ext = file.url.pathExtension.lowercased()
            do {
                if htmlExtensions.contains(ext) {
                    result.drafts.append(try appleNotesHTMLDraft(for: file, root: root, rootName: rootName))
                } else if file.isNoteFile {
                    result.drafts.append(try markdownDraft(for: file, root: root, rootName: rootName, index: index))
                }
            } catch {
                result.warnings.append("\(file.relativePath): \(error.localizedDescription)")
            }
        }
        return result
    }

    static func appleNotesHTMLDraft(for file: WalkedFile, root: URL, rootName: String) throws -> ImportedNoteDraft {
        let html = try readText(file.url)
        var collector = ImportAttachmentCollector()
        let folder = (file.relativePath as NSString).deletingLastPathComponent
        var options = HTMLMarkdownOptions()
        options.resolveImage = { src, _ in
            if let decoded = decodeDataURI(src) {
                let ext = EditorAttachmentFiles.preferredExtension(forMIMEType: decoded.mimeType) ?? "png"
                return collector.register(ImportedAttachmentSource(
                    content: .data(decoded.data), filename: "image.\(ext)", mimeType: decoded.mimeType
                ))
            }
            return attachmentPlaceholder(forRelative: src, folder: folder, root: root, collector: &collector)
        }
        let title = HTMLMarkdownConverter.documentTitle(inHTML: html) ?? file.noteTitle
        var body = HTMLMarkdownConverter.markdown(fromHTML: html, options: options)
        body = MarkdownImportRewriter.removingLeadingTitleHeading(body, title: title)
        // Apple Notes puts the title in the first line as plain bold text too.
        body = removingLeadingLine(body, equalTo: title)
        let dates = fileDates(file.url)
        return ImportedNoteDraft(
            title: title,
            body: body,
            createdAt: dates.created,
            updatedAt: dates.modified,
            notebookPath: [rootName] + file.folderComponents,
            attachments: collector.attachments,
            sourceName: file.relativePath
        )
    }

    static func removingLeadingLine(_ body: String, equalTo title: String) -> String {
        var lines = body.components(separatedBy: "\n")
        guard let first = lines.first else { return body }
        let stripped = first.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_"))
            .trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty, stripped.caseInsensitiveCompare(title) == .orderedSame else { return body }
        lines.removeFirst()
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    // MARK: - Shared helpers

    /// A file found under an import root.
    struct WalkedFile: Equatable, Sendable {
        var url: URL
        /// Path relative to the import root, `/`-separated.
        var relativePath: String
        /// For a Bear `.textbundle`, the bundle's path (links inside the
        /// bundle resolve against it and the bundle names the note).
        var bundleRelativePath: String?

        var isNoteFile: Bool {
            NoteImportSources.markdownExtensions.contains(url.pathExtension.lowercased())
        }

        /// Folder components (notebook path), outside any text bundle.
        var folderComponents: [String] {
            let base = bundleRelativePath ?? relativePath
            return (base as NSString).deletingLastPathComponent
                .split(separator: "/").map(String.init)
        }

        /// Folder relative links in this file resolve against.
        var linkBaseFolder: String {
            if let bundleRelativePath { return bundleRelativePath }
            return (relativePath as NSString).deletingLastPathComponent
        }

        /// File (or text bundle) name without its extension.
        var noteTitle: String {
            let name = ((bundleRelativePath ?? relativePath) as NSString).lastPathComponent
            return (name as NSString).deletingPathExtension
        }
    }

    /// Recursively lists regular files under `root`, skipping hidden files
    /// and folders (`.obsidian`, `.trash`, `.git`, …). A `.textbundle` /
    /// `.textpack` folder contributes only its `text.*` file, tagged with the
    /// bundle path; its assets are reachable through links.
    static func walk(_ root: URL) -> [WalkedFile] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [WalkedFile] = []
        for case let url as URL in enumerator {
            guard let relative = relativePath(of: url, under: root) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                let ext = url.pathExtension.lowercased()
                if ext == "textbundle" || ext == "textpack" {
                    enumerator.skipDescendants()
                    let candidates = ["text.md", "text.markdown", "text.txt"]
                    if let text = candidates.map({ url.appendingPathComponent($0) })
                        .first(where: { fm.fileExists(atPath: $0.path) }) {
                        out.append(WalkedFile(
                            url: text,
                            relativePath: relative + "/" + text.lastPathComponent,
                            bundleRelativePath: relative
                        ))
                    }
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            out.append(WalkedFile(url: url, relativePath: relative, bundleRelativePath: nil))
        }
        return out.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    static func relativePath(of url: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// Case-insensitive file-name → file lookup for Obsidian-style
    /// `![[image.png]]` embeds (which name a file anywhere in the vault).
    struct FileNameIndex: Sendable {
        private var byName: [String: WalkedFile] = [:]

        init(files: [WalkedFile]) {
            for file in files where !file.isNoteFile {
                let key = file.url.lastPathComponent.lowercased()
                if byName[key] == nil { byName[key] = file }
            }
        }

        func file(forName name: String) -> WalkedFile? {
            byName[((name as NSString).lastPathComponent).lowercased()]
        }
    }

    /// Registers the file a relative link points at (resolved against the
    /// linking file's folder, staying inside the import root). Nil when the
    /// link is external or the file doesn't exist.
    static func attachmentPlaceholder(
        forRelative destination: String,
        folder: String,
        root: URL,
        collector: inout ImportAttachmentCollector
    ) -> String? {
        guard !destination.isEmpty, !MarkdownImportRewriter.hasURLScheme(destination) else { return nil }
        let decoded = destination.removingPercentEncoding ?? destination
        for candidate in [decoded, destination] {
            guard let relative = MarkdownImportRewriter.resolveRelative(candidate, fromFolder: folder) else { continue }
            let url = root.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            // Must stay inside the import root (no symlink escapes).
            guard self.relativePath(of: url, under: root) != nil else { continue }
            return collector.register(
                ImportedAttachmentSource(content: .file(url), filename: url.lastPathComponent, mimeType: nil),
                dedupeKey: relative.lowercased()
            )
        }
        return nil
    }

    static func attachmentPlaceholder(
        byName name: String,
        index: FileNameIndex,
        collector: inout ImportAttachmentCollector
    ) -> String? {
        guard let file = index.file(forName: name),
              FileManager.default.fileExists(atPath: file.url.path) else { return nil }
        return collector.register(
            ImportedAttachmentSource(content: .file(file.url), filename: file.url.lastPathComponent, mimeType: nil),
            dedupeKey: file.relativePath.lowercased()
        )
    }

    /// `data:<mime>;base64,<payload>` → bytes. Nil for anything else.
    static func decodeDataURI(_ uri: String) -> (mimeType: String, data: Data)? {
        guard uri.lowercased().hasPrefix("data:"), let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[uri.index(uri.startIndex, offsetBy: 5)..<comma]
        guard header.lowercased().hasSuffix(";base64") else { return nil }
        let mime = String(header.dropLast(7))
        let payload = String(uri[uri.index(after: comma)...])
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters), !data.isEmpty else { return nil }
        return (mime.isEmpty ? "application/octet-stream" : mime, data)
    }

    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    static func fileDates(_ url: URL) -> (created: Date?, modified: Date?) {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return (values?.creationDate, values?.contentModificationDate)
    }
}
