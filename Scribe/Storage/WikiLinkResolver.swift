// Scribe/Storage/WikiLinkResolver.swift
import Foundation

/// Pure, Foundation-only detector for *broken* `[[wiki links]]` in a note body.
///
/// A wiki link is broken when its anchor does not resolve to the title of any
/// existing note. Resolution mirrors `NoteStore` exactly:
///   - anchors are extracted with the same `\[\[([^\[\]]+)\]\]` pattern used by
///     `NoteStore.parseWikiLinks` (inner text, whitespace-trimmed),
///   - matching is case-insensitive against existing note titles
///     (`LOWER(title) = LOWER(anchor)` in `NoteStore.upsertNote` /
///     `NoteStore.resolveTitle` / `NoteIndexReconciler`).
///
/// Alias form (`[[Title|alias]]`) and heading / block links
/// (`[[Title#Heading]]`, `[[Title#^id]]`) resolve on their title, exactly as
/// `NoteStore` resolves them (see `WikiLinkTarget.lookupCandidates`).
enum WikiLinkResolver {

    /// Same pattern as `NoteStore.wikiLinkRegex` — captures the inner text of a
    /// `[[...]]` link, disallowing nested brackets.
    private static let wikiLinkRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\[\[([^\[\]]+)\]\]"#)
    }()

    /// Returns the wiki-link anchors in `body` that do **not** resolve to any
    /// title in `existingTitles`.
    ///
    /// - Parameters:
    ///   - existingTitles: titles of all existing notes. Matched
    ///     case-insensitively.
    ///   - body: a note body that may contain `[[wiki links]]`.
    /// - Returns: the unresolved anchors, in first-seen order, de-duplicated
    ///   (case-insensitively). Each returned anchor is the trimmed inner text
    ///   exactly as `NoteStore` would store it.
    static func unresolvedAnchors(existingTitles: some Sequence<String>,
                                  body: String) -> [String] {
        let known = Set(existingTitles.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        })

        var seen = Set<String>()
        var result: [String] = []
        let range = NSRange(body.startIndex..., in: body)

        for match in wikiLinkRegex.matches(in: body, range: range) {
            guard let r = Range(match.range(at: 1), in: body) else { continue }
            let anchor = String(body[r]).trimmingCharacters(in: .whitespaces)
            guard !anchor.isEmpty else { continue }

            // Resolve against the part before an optional `|alias`, then the
            // title without a `#Heading` / `#^block` fragment. A same-note
            // link (`[[#Heading]]`) always resolves.
            if WikiLinkTarget.parse(anchor).refersToSameNote { continue }
            let candidates = WikiLinkTarget.lookupCandidates(forAnchor: anchor)
            guard !candidates.isEmpty else { continue }
            guard !candidates.contains(where: { known.contains($0.lowercased()) }) else { continue }
            guard seen.insert(anchor.lowercased()).inserted else { continue }
            result.append(anchor)
        }
        return result
    }
}
