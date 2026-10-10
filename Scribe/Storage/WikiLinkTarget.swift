// Scribe/Storage/WikiLinkTarget.swift
import Foundation

/// The parts of a `[[wiki link]]` anchor (the text between the brackets):
///
///     [[Title]]                 → title
///     [[Title|alias]]           → title + display alias
///     [[Title#Heading]]         → a heading inside the note
///     [[Title#^block-id]]       → a `^block-id` anchored paragraph / list item
///     [[#Heading]] / [[#^id]]   → a heading / block in the *same* note
///
/// Embeds (`![[…]]`) use the same anchor grammar; the leading `!` is not part
/// of the anchor. Pure and Foundation-only (compiled into the iOS target).
struct WikiLinkTarget: Equatable, Hashable, Sendable {
    /// Note title (trimmed). Empty for a same-note link (`[[#Heading]]`).
    var title: String
    /// Heading text after `#` (trimmed), when the link targets a heading.
    var heading: String?
    /// Block id after `#^` (without the caret), when the link targets a block.
    var blockId: String?
    /// Display text after `|`, if any.
    var alias: String?

    init(title: String, heading: String? = nil, blockId: String? = nil, alias: String? = nil) {
        self.title = title
        self.heading = heading
        self.blockId = blockId
        self.alias = alias
    }

    /// True when the link points inside the note it is written in.
    var refersToSameNote: Bool { title.isEmpty }

    /// True when the link targets a heading or block rather than the note.
    var hasFragment: Bool { heading != nil || blockId != nil }

    /// Parses the inner text of a wiki link.
    nonisolated static func parse(_ anchor: String) -> WikiLinkTarget {
        var rest = Substring(anchor)
        var alias: String?
        if let pipe = rest.firstIndex(of: "|") {
            let raw = rest[rest.index(after: pipe)...].trimmingCharacters(in: .whitespaces)
            alias = raw.isEmpty ? nil : raw
            rest = rest[..<pipe]
        }
        var heading: String?
        var blockId: String?
        if let hash = rest.firstIndex(of: "#") {
            let fragment = rest[rest.index(after: hash)...].trimmingCharacters(in: .whitespaces)
            rest = rest[..<hash]
            if fragment.hasPrefix("^") {
                let id = String(fragment.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !id.isEmpty { blockId = id }
            } else if !fragment.isEmpty {
                heading = fragment
            }
        }
        return WikiLinkTarget(
            title: rest.trimmingCharacters(in: .whitespaces),
            heading: heading,
            blockId: blockId,
            alias: alias
        )
    }

    /// Titles to try, in order, when resolving `anchor` to a note: the whole
    /// text before any `|alias` first (so a note literally titled `C# Tips`
    /// keeps resolving), then the title with any `#fragment` removed.
    /// Empty candidates are dropped; duplicates (case-insensitive) collapse.
    nonisolated static func lookupCandidates(forAnchor anchor: String) -> [String] {
        let beforePipe = anchor
            .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let parsedTitle = parse(anchor).title
        var out: [String] = []
        for candidate in [beforePipe, parsedTitle] where !candidate.isEmpty {
            if !out.contains(where: { $0.lowercased() == candidate.lowercased() }) {
                out.append(candidate)
            }
        }
        return out
    }

    /// The anchor text this target serialises to (without brackets).
    var anchorText: String {
        var out = title
        if let heading { out += "#" + heading }
        if let blockId { out += "#^" + blockId }
        if let alias { out += "|" + alias }
        return out
    }
}
