// Scribe/UI/Notes/EditorAttachmentFiles.swift
//
// Saving files pasted / dropped / imported into the CodeMirror note editor.
//
// The web editor sends the bytes (base64) plus the original filename and MIME
// type; this helper turns that into a safe file inside the note's attachments
// folder (`<vault>/attachments/<noteId>/<name>`, via `AttachmentsDirectory`)
// and returns the vault-relative path the editor embeds in markdown
// (`![name](attachments/<noteId>/<name>)`). The same helper decides which
// vault files the editor's `scribe-asset://vault/` URL scheme may serve back
// to the WKWebView for inline image display.
//
// Everything here is pure / Foundation-only and nonisolated so it can run off
// the main actor and be unit tested (EditorAttachmentFilesTests).

import Foundation
import UniformTypeIdentifiers

/// Why an editor attachment could not be saved.
enum EditorAttachmentFilesError: Error, LocalizedError, Equatable {
    case empty
    case tooLarge(bytes: Int)
    case invalidData
    case invalidNoteId

    var errorDescription: String? {
        switch self {
        case .empty:
            return "The file is empty."
        case .tooLarge(let bytes):
            let mb = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return "The file is too large (\(mb)). Attachments are limited to 50 MB."
        case .invalidData:
            return "The file data could not be read."
        case .invalidNoteId:
            return "The note's attachments folder is invalid."
        }
    }
}

/// A file saved into a note's attachments folder.
struct SavedEditorAttachment: Sendable, Equatable {
    /// Vault-relative path for markdown, e.g. `attachments/<noteId>/photo.png`.
    let relativePath: String
    /// Final (sanitized, de-duplicated) file name.
    let filename: String
    /// Absolute location on disk.
    let absoluteURL: URL
    /// Whether the editor should embed it as an image (`![]()`) or a link.
    let isImage: Bool
}

enum EditorAttachmentFiles {

    /// Hard cap on a single attachment (also enforced in JS before sending).
    static let maxBytes = 50 * 1024 * 1024

    /// Longest base name kept (characters, before the extension).
    static let maxBaseNameLength = 80

    /// Folder used when the editor has no note id yet (an unsaved daily-note
    /// draft): `attachments/unfiled/`.
    static let unfiledFolder = "unfiled"

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg", "avif",
    ]

    // MARK: - Names

    /// Turns an arbitrary pasted / dropped file name into a safe, portable file
    /// name: path components dropped, only letters / digits / `-` / `_` kept
    /// in the base (everything else becomes `-`), runs collapsed, length
    /// capped, and a lowercase extension kept or derived from the MIME type.
    /// Never returns an empty, hidden (`.x`) or traversal (`..`) name.
    static func sanitizedFilename(_ raw: String, mimeType: String?) -> String {
        // Last path component only (both separators), no NULs / control chars.
        var name = raw.replacingOccurrences(of: "\\", with: "/")
        if let last = name.split(separator: "/", omittingEmptySubsequences: true).last {
            name = String(last)
        } else {
            name = ""
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        var base = name
        var ext = ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            base = String(name[..<dot])
            ext = String(name[name.index(after: dot)...])
        }

        ext = String(ext.lowercased().unicodeScalars.filter { isASCIIAlphanumeric($0) }.map(Character.init))
        if ext.count > 10 { ext = "" }
        if ext.isEmpty { ext = preferredExtension(forMIMEType: mimeType) ?? "bin" }

        var cleaned = ""
        var lastWasDash = false
        for scalar in base.unicodeScalars {
            let keep = CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
            if keep && scalar != "-" {
                cleaned.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                cleaned.append("-")
                lastWasDash = true
            }
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        if cleaned.count > maxBaseNameLength {
            cleaned = String(cleaned.prefix(maxBaseNameLength))
            cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        }
        if cleaned.isEmpty {
            cleaned = (mimeType ?? "").lowercased().hasPrefix("image/") || imageExtensions.contains(ext)
                ? "image" : "attachment"
        }
        return "\(cleaned).\(ext)"
    }

    /// Returns `name`, or `name-2.ext`, `name-3.ext`, … — the first candidate
    /// for which `isTaken` is false.
    static func uniqueFilename(_ name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let (base, ext) = splitExtension(name)
        for n in 2...9_999 {
            let candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            if !isTaken(candidate) { return candidate }
        }
        let token = UUID().uuidString.prefix(8).lowercased()
        return ext.isEmpty ? "\(base)-\(token)" : "\(base)-\(token).\(ext)"
    }

    /// Whether a saved attachment should be embedded as an image.
    static func isImage(filename: String, mimeType: String?) -> Bool {
        if let mime = mimeType?.lowercased(), mime.hasPrefix("image/") { return true }
        return imageExtensions.contains(splitExtension(filename).ext.lowercased())
    }

    /// The per-note folder name: the note id, or `unfiled` when there is none.
    /// Rejects ids that could escape `attachments/`.
    static func folderName(forNoteId noteId: String?) throws -> String {
        guard let raw = noteId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return unfiledFolder
        }
        if raw == "." || raw == ".." || raw.contains("/") || raw.contains("\\") || raw.contains("\0") {
            throw EditorAttachmentFilesError.invalidNoteId
        }
        return raw
    }

    /// Vault-relative markdown path for a saved file.
    static func relativePath(folder: String, filename: String) -> String {
        "attachments/\(folder)/\(filename)"
    }

    /// Small, deterministic MIME → extension table, falling back to UTType.
    static func preferredExtension(forMIMEType mimeType: String?) -> String? {
        guard let mime = mimeType?.lowercased().split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces), !mime.isEmpty else { return nil }
        switch mime {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/tiff": return "tiff"
        case "image/bmp": return "bmp"
        case "image/svg+xml": return "svg"
        case "image/avif": return "avif"
        case "application/pdf": return "pdf"
        case "text/plain": return "txt"
        case "text/markdown": return "md"
        case "text/csv": return "csv"
        case "application/zip": return "zip"
        default:
            return UTType(mimeType: mime)?.preferredFilenameExtension
        }
    }

    // MARK: - Saving

    /// Decodes base64 from the web editor and saves it. Size is checked on the
    /// encoded length first so an oversized payload isn't decoded at all.
    static func saveBase64(
        _ base64: String,
        suggestedName: String,
        mimeType: String?,
        noteId: String?,
        root: URL
    ) throws -> SavedEditorAttachment {
        // 4 base64 chars encode 3 bytes; allow for padding.
        let estimated = (base64.utf8.count / 4) * 3
        if estimated > maxBytes + 3 { throw EditorAttachmentFilesError.tooLarge(bytes: estimated) }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            throw EditorAttachmentFilesError.invalidData
        }
        return try save(data: data, suggestedName: suggestedName, mimeType: mimeType, noteId: noteId, root: root)
    }

    /// Saves `data` into `<root>/attachments/<noteId or unfiled>/` under a
    /// sanitized, unique name. Never overwrites an existing file.
    static func save(
        data: Data,
        suggestedName: String,
        mimeType: String?,
        noteId: String?,
        root: URL
    ) throws -> SavedEditorAttachment {
        guard !data.isEmpty else { throw EditorAttachmentFilesError.empty }
        guard data.count <= maxBytes else { throw EditorAttachmentFilesError.tooLarge(bytes: data.count) }

        let folder = try folderName(forNoteId: noteId)
        let dir = try AttachmentsDirectory.directory(forNoteId: folder, root: root)
        let fm = FileManager.default
        let sanitized = sanitizedFilename(suggestedName, mimeType: mimeType)

        var filename = uniqueFilename(sanitized) { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        var dest = dir.appendingPathComponent(filename)
        do {
            try data.write(to: dest, options: .withoutOverwriting)
        } catch {
            // Lost a race with another writer for the same name: retry once
            // with a random suffix (still never overwriting).
            let (base, ext) = splitExtension(sanitized)
            let token = UUID().uuidString.prefix(8).lowercased()
            filename = ext.isEmpty ? "\(base)-\(token)" : "\(base)-\(token).\(ext)"
            dest = dir.appendingPathComponent(filename)
            try data.write(to: dest, options: .withoutOverwriting)
        }

        return SavedEditorAttachment(
            relativePath: relativePath(folder: folder, filename: filename),
            filename: filename,
            absoluteURL: dest,
            isImage: isImage(filename: filename, mimeType: mimeType)
        )
    }

    // MARK: - Serving (scribe-asset://vault/…)

    /// Resolves a vault-relative request path (already percent-decoded, e.g.
    /// `attachments/<noteId>/photo.png`) to a file the editor may display.
    /// Only image files inside `<root>/attachments/` qualify: `..` segments,
    /// absolute paths, non-images and symlinks escaping the folder are refused.
    /// Returns nil when refused or missing.
    static func servedAttachmentURL(forRequestPath rawPath: String, root: URL) -> URL? {
        var path = rawPath
        while path.hasPrefix("/") { path.removeFirst() }
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first == "attachments", components.count >= 2 else { return nil }
        guard !components.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { return nil }
        guard isImage(filename: String(components[components.count - 1]), mimeType: nil) else { return nil }

        let candidate = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }

        let attachmentsRoot = root.appendingPathComponent("attachments", isDirectory: true)
        let canonicalCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalRoot = attachmentsRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPrefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        guard canonicalCandidate.hasPrefix(rootPrefix) else { return nil }
        return candidate
    }

    /// MIME type for a served attachment.
    static func mimeType(forFilename filename: String) -> String {
        switch splitExtension(filename).ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "tif", "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        case "svg": return "image/svg+xml"
        case "avif": return "image/avif"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Helpers

    private static func splitExtension(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
    }
}
