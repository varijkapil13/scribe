// Scribe/Storage/NoteEmbedExpander.swift
import Foundation

/// One embedded note (or part of one) resolved for an `![[…]]` embed.
struct NoteEmbedResolution: Equatable, Sendable {
    let noteId: String
    let title: String
    /// The note's full markdown body (frontmatter excluded).
    let body: String
}

/// Pure handling of `![[Note]]`, `![[Note#Heading]]` and `![[Note#^block]]`
/// embeds: finding them in a body and expanding them one level deep for
/// exports. Embeds inside code (fenced blocks, inline code) are left alone.
enum NoteEmbedExpander {

    /// One `![[…]]` occurrence: its UTF-16 range in the body and its anchor.
    struct Occurrence: Equatable, Sendable {
        let location: Int
        let length: Int
        let anchor: String
        var target: WikiLinkTarget { WikiLinkTarget.parse(anchor) }
    }

    nonisolated private static let embedRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"!\[\[([^\[\]\n]+)\]\]"#)
    }()

    /// The embeds in `body`, in order, skipping any inside code and
    /// attachment embeds (`![[photo.png]]`, Obsidian-style), which aren't notes.
    nonisolated static func embeds(in body: String) -> [Occurrence] {
        let ns = body as NSString
        let protected = MarkdownCodeRanges.codeRanges(in: body)
        return embedRegex.matches(in: body, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            if protected.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) { return nil }
            let anchor = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard !anchor.isEmpty, !isAttachmentAnchor(anchor) else { return nil }
            return Occurrence(location: m.range.location, length: m.range.length, anchor: anchor)
        }
    }

    /// File extensions of non-note embeds (images, PDFs, audio, video).
    nonisolated static let attachmentExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff", "heic", "pdf",
        "mp3", "m4a", "wav", "aac", "ogg", "mp4", "mov", "m4v", "webm",
    ]

    /// True for `photo.png`, `scan.pdf#page=2`, `img.jpg|300` — an embed of
    /// a file rather than a note. Mirrors `ATTACHMENT_EMBED_RE` in
    /// editor-web/src/notepower.js.
    nonisolated static func isAttachmentAnchor(_ anchor: String) -> Bool {
        let name = anchor
            .split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: { $0 == "#" || $0 == "|" })
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        return !ext.isEmpty && attachmentExtensions.contains(ext)
    }

    /// The markdown an embed shows: the designated heading section / block
    /// of `resolution.body` (or all of it), with block anchors stripped and
    /// nested embeds turned into plain links so they never expand further.
    /// nil when the heading / block doesn't exist.
    nonisolated static func embeddedMarkdown(for target: WikiLinkTarget,
                                             resolution: NoteEmbedResolution) -> String? {
        guard let content = NoteBlockReference.content(for: target, in: resolution.body) else { return nil }
        let cleaned = NoteBlockReference.lines(of: content)
            .map(NoteBlockReference.strippingBlockId)
            .joined(separator: "\n")
        return degradingEmbedsToLinks(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A note literally titled `C# Tips` resolves on the whole anchor; its
    /// `#` is then part of the title, not a heading fragment.
    nonisolated static func effectiveTarget(_ target: WikiLinkTarget, anchor: String, resolvedTitle: String) -> WikiLinkTarget {
        guard target.hasFragment else { return target }
        let beforePipe = anchor
            .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if beforePipe.lowercased() == resolvedTitle.lowercased() {
            return WikiLinkTarget(title: resolvedTitle, alias: target.alias)
        }
        return target
    }

    /// Replaces every `![[x]]` (outside code) with `[[x]]`.
    nonisolated static func degradingEmbedsToLinks(_ body: String) -> String {
        let occurrences = embeds(in: body)
        guard !occurrences.isEmpty else { return body }
        let ns = NSMutableString(string: body)
        for occurrence in occurrences.reversed() {
            // Drop just the leading "!".
            ns.replaceCharacters(in: NSRange(location: occurrence.location, length: 1), with: "")
        }
        return ns as String
    }

    /// Expands each embed in `body` one level: the embed is replaced by the
    /// embedded content (see `embeddedMarkdown`). Cycle-safe — an embed of the
    /// note itself (no fragment) or of a note already in `ancestry` is left as
    /// a plain `[[link]]`, as is one whose target can't be resolved.
    ///
    /// - Parameters:
    ///   - currentNoteId: the note `body` belongs to (nil if unknown).
    ///   - resolve: resolves an embed anchor (`Note#Heading|alias`) to its
    ///     note, or nil.
    nonisolated static func expand(
        body: String,
        currentNoteId: String?,
        ancestry: Set<String> = [],
        resolve: (String) -> NoteEmbedResolution?
    ) -> String {
        let occurrences = embeds(in: body)
        guard !occurrences.isEmpty else { return body }
        var blocked = ancestry
        if let currentNoteId { blocked.insert(currentNoteId) }

        let ns = NSMutableString(string: body)
        for occurrence in occurrences.reversed() {
            let range = NSRange(location: occurrence.location, length: occurrence.length)
            let replacement: String
            let resolution: NoteEmbedResolution?
            var target = occurrence.target
            if target.refersToSameNote {
                // `![[#Heading]]`: a section of this same note. (Without a
                // fragment it is blocked below as a self-embed.)
                resolution = NoteEmbedResolution(noteId: currentNoteId ?? "", title: "", body: body)
            } else {
                resolution = resolve(occurrence.anchor)
                if let resolution {
                    target = effectiveTarget(target, anchor: occurrence.anchor, resolvedTitle: resolution.title)
                }
            }
            let isWholeSelfEmbed = target.refersToSameNote && !target.hasFragment
            if let resolution,
               !isWholeSelfEmbed,
               !(blocked.contains(resolution.noteId) && !target.hasFragment),
               !ancestry.contains(resolution.noteId),
               let markdown = embeddedMarkdown(for: target, resolution: resolution) {
                replacement = markdown
            } else {
                replacement = "[[\(occurrence.anchor)]]"
            }
            ns.replaceCharacters(in: range, with: replacement)
        }
        return ns as String
    }
}

/// UTF-16 ranges of markdown code (fenced blocks and inline code spans), so
/// link / embed / mention scanners can skip them.
enum MarkdownCodeRanges {

    nonisolated private static let inlineCodeRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"(`+)[^`\n](?:.*?[^`])?\1(?!`)"#)
    }()

    /// Fenced code blocks (whole lines, fences included) and inline code.
    nonisolated static func codeRanges(in body: String) -> [NSRange] {
        var ranges = fencedBlockRanges(in: body)
        let ns = body as NSString
        for m in inlineCodeRegex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            if !ranges.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                ranges.append(m.range)
            }
        }
        return ranges
    }

    /// Fenced code blocks as UTF-16 ranges covering their lines.
    nonisolated static func fencedBlockRanges(in body: String) -> [NSRange] {
        let ns = body as NSString
        var ranges: [NSRange] = []
        var location = 0
        var openStart: Int?
        var openFence: String?
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let fence = openFence {
                if let fenceChar = fence.first,
                   trimmed.count >= fence.count,
                   trimmed.allSatisfy({ $0 == fenceChar }) {
                    let start = openStart ?? lineRange.location
                    ranges.append(NSRange(location: start, length: NSMaxRange(lineRange) - start))
                    openFence = nil
                    openStart = nil
                }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker: Character = trimmed.hasPrefix("```") ? "`" : "~"
                openFence = String(trimmed.prefix { $0 == marker })
                openStart = lineRange.location
            }
            let next = NSMaxRange(lineRange)
            if next <= location { break }
            location = next
        }
        if let openStart {
            // Unclosed fence: code to the end of the document.
            ranges.append(NSRange(location: openStart, length: ns.length - openStart))
        }
        return ranges
    }
}

/// Resolves embed anchors to notes for exporters / the editor.
struct NoteEmbedLookup: Sendable {
    let resolve: @Sendable (String) -> NoteEmbedResolution?

    init(resolve: @escaping @Sendable (String) -> NoteEmbedResolution?) {
        self.resolve = resolve
    }

    /// Resolves through `store` (title lookup, then the body from disk).
    static func noteStore(_ store: NoteStore) -> NoteEmbedLookup {
        NoteEmbedLookup { anchor in
            guard let row = try? store.resolveLinkTarget(anchor: anchor),
                  let note = try? store.fetchNote(id: row.id) else { return nil }
            return NoteEmbedResolution(noteId: note.id, title: note.title, body: note.body)
        }
    }

    /// The app's shared store — touched only when an embed is resolved.
    static let live = NoteEmbedLookup { anchor in
        NoteEmbedLookup.noteStore(.shared).resolve(anchor)
    }
}
