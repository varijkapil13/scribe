// Scribe/UI/DesignSystem/MarkdownRenderer.swift
import AppKit
import Markdown

// MARK: - Attribute keys (additions; existing keys live in MarkdownEditorView.swift)

extension NSAttributedString.Key {
    /// UUID grouping non-adjacent runs that belong to the same fenced code block.
    /// Used by drawBackground to draw a single rounded panel under the whole block.
    static let codeBlockId       = NSAttributedString.Key("scribe.codeBlockId")
    /// String language tag from a fence (` ```swift ` → "swift"), or empty.
    static let codeBlockLanguage = NSAttributedString.Key("scribe.codeBlockLanguage")
    /// Int blockquote nesting depth (1 = top level).
    static let blockquoteDepth   = NSAttributedString.Key("scribe.blockquoteDepth")
    /// UUID identifying the block (paragraph / heading / list-item / code-block / blockquote)
    /// that owns this run. Cursor-proximity marker reveal compares the cursor's owner-id
    /// against each marker's owner-id and only shows markers whose owner matches.
    static let scribeBlockId     = NSAttributedString.Key("scribe.blockId")
    /// Bool marking the bullet / number prefix range of a list item.
    static let scribeListMarker  = NSAttributedString.Key("scribe.listMarker")
    /// Bool marking the *content* portion (not the backticks) of an inline code span.
    /// drawBackground reads this to draw the pill.
    static let scribeInlineCode  = NSAttributedString.Key("scribe.inlineCode")
    /// Bool marking syntax marker characters (`**`, `*`, `_`, `~~`, `\``, `#`, `>`, `-`).
    /// Cursor-proximity reveal toggles these between dim-visible and hidden.
    static let scribeSyntaxMarker = NSAttributedString.Key("scribe.syntaxMarker")
    /// Bool marking a table cell. drawBackground reads this to draw row/column rules.
    static let scribeTableCell    = NSAttributedString.Key("scribe.tableCell")
    /// URL the renderer auto-detected (bare URL in text). Editor turns into a clickable link.
    static let scribeAutoLinkURL  = NSAttributedString.Key("scribe.autoLink")
}

// MARK: - Theme

struct MarkdownTheme {
    let baseFont: NSFont
    var dim: NSColor { .tertiaryLabelColor }
    var marker: NSColor { .quaternaryLabelColor }
    var primary: NSColor { .labelColor }
    var secondary: NSColor { .secondaryLabelColor }

    var monoFont: NSFont {
        .monospacedSystemFont(ofSize: baseFont.pointSize - 0.5, weight: .regular)
    }
    var codeBlockFont: NSFont {
        .monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular)
    }

    func headingFont(level: Int) -> NSFont {
        switch level {
        case 1: return .systemFont(ofSize: 26, weight: .bold)
        case 2: return .systemFont(ofSize: 21, weight: .semibold)
        case 3: return .systemFont(ofSize: 18, weight: .semibold)
        case 4: return .systemFont(ofSize: 16, weight: .semibold)
        case 5: return .systemFont(ofSize: baseFont.pointSize, weight: .semibold)
        default: return .systemFont(ofSize: baseFont.pointSize, weight: .medium)
        }
    }

    func headingSpacingBefore(level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 18
        case 3: return 14
        case 4: return 10
        default: return 8
        }
    }
}

// MARK: - Source-position map

/// Maps swift-markdown `SourceLocation` (1-based line + UTF-8 column) to
/// UTF-16 offsets in the original source string. We need UTF-16 offsets
/// because NSAttributedString ranges are UTF-16 based.
private struct SourceMap {
    /// UTF-16 offset of the start of each line. `lineStarts[0]` = 0.
    private let lineStarts: [Int]
    private let nsSource: NSString

    init(source: String) {
        self.nsSource = source as NSString
        var starts: [Int] = [0]
        var i = 0
        let len = nsSource.length
        while i < len {
            let c = nsSource.character(at: i)
            if c == 0x0A { // \n
                starts.append(i + 1)
            }
            i += 1
        }
        self.lineStarts = starts
    }

    /// Convert (line, column) — both 1-based, column counted in UTF-8 — to a
    /// UTF-16 offset. For ASCII / BMP content the two are identical, which
    /// covers ~all real-world cases; for non-BMP we approximate by clamping.
    func offset(line: Int, column: Int) -> Int {
        guard line >= 1, line - 1 < lineStarts.count else {
            return min(nsSource.length, max(0, line < 1 ? 0 : nsSource.length))
        }
        let lineStart = lineStarts[line - 1]
        let lineEnd = (line - 1 + 1 < lineStarts.count) ? lineStarts[line] - 1 : nsSource.length
        return min(lineEnd, lineStart + max(0, column - 1))
    }

    func range(for sourceRange: SourceRange) -> NSRange? {
        let start = offset(line: sourceRange.lowerBound.line, column: sourceRange.lowerBound.column)
        let end = offset(line: sourceRange.upperBound.line, column: sourceRange.upperBound.column)
        guard end >= start, end <= nsSource.length else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

// MARK: - Renderer

enum MarkdownRenderer {

    /// Walk the AST and emit an `NSAttributedString` that preserves the source
    /// byte-for-byte. All styling is applied as attributes over the original
    /// text — we never rewrite the source. This keeps the editor's selection,
    /// undo and cursor positions stable.
    ///
    /// - Parameter cursorOffset: when supplied, the renderer dims-but-shows
    ///   syntax markers (`**`, `*`, `_`, `\``, `~~`, leading `#`/`>`/`-`) only
    ///   for the block under the cursor; all other markers get `.foregroundColor`
    ///   = clear so they don't render. Pass `nil` to keep markers visible
    ///   everywhere (initial loads, exports).
    static func attributed(
        _ source: String,
        font: NSFont,
        cursorOffset: Int? = nil
    ) -> NSAttributedString {
        guard !source.isEmpty else { return NSAttributedString() }
        let theme = MarkdownTheme(baseFont: font)
        let map = SourceMap(source: source)
        let document = Document(parsing: source, options: [.parseBlockDirectives])
        let out = NSMutableAttributedString(string: source)

        // Baseline body attributes — applied to everything, then refined per-block.
        let baseParagraph = NSMutableParagraphStyle()
        baseParagraph.lineHeightMultiple = 1.5
        baseParagraph.paragraphSpacing = 2
        out.addAttributes([
            .font: theme.baseFont,
            .foregroundColor: theme.primary,
            .paragraphStyle: baseParagraph,
        ], range: NSRange(location: 0, length: out.length))

        var revealedBlockId: UUID?

        // Walk children once to layout block-level attributes.
        for child in document.children {
            applyBlock(
                child, to: out, source: source, map: map, theme: theme,
                blockquoteDepth: 0, cursorOffset: cursorOffset,
                revealedBlockId: &revealedBlockId
            )
        }

        // Autolink: detect bare URLs in text that aren't already part of a link.
        autolinkBareURLs(in: out, source: source)

        // Cursor-proximity reveal: hide markers whose block is not the cursor's block.
        if cursorOffset != nil {
            applyMarkerReveal(to: out, revealedBlockId: revealedBlockId, theme: theme)
        }

        return out
    }

    // MARK: - Block dispatch

    private static func applyBlock(
        _ node: Markup,
        to out: NSMutableAttributedString,
        source: String,
        map: SourceMap,
        theme: MarkdownTheme,
        blockquoteDepth: Int,
        cursorOffset: Int?,
        revealedBlockId: inout UUID?
    ) {
        guard let nodeRange = node.range, let range = map.range(for: nodeRange) else { return }
        let blockId = UUID()
        out.addAttribute(.scribeBlockId, value: blockId,
                         range: clamp(range, to: out.length))
        if let cursor = cursorOffset, range.contains(cursor) || cursor == range.location {
            revealedBlockId = blockId
        }

        switch node {
        case let h as Heading:
            applyHeading(h, range: range, out: out, theme: theme, blockId: blockId)

        case let cb as CodeBlock:
            applyCodeBlock(cb, range: range, out: out, theme: theme, blockId: blockId)

        case let bq as BlockQuote:
            applyBlockQuote(bq, range: range, out: out, theme: theme,
                            depth: blockquoteDepth + 1, blockId: blockId,
                            source: source, map: map, cursorOffset: cursorOffset,
                            revealedBlockId: &revealedBlockId)

        case let list as UnorderedList:
            applyList(list, range: range, out: out, theme: theme, ordered: false,
                      source: source, map: map, cursorOffset: cursorOffset,
                      revealedBlockId: &revealedBlockId)

        case let list as OrderedList:
            applyList(list, range: range, out: out, theme: theme, ordered: true,
                      source: source, map: map, cursorOffset: cursorOffset,
                      revealedBlockId: &revealedBlockId)

        case is ThematicBreak:
            out.addAttribute(.horizontalRule, value: true, range: clamp(range, to: out.length))
            out.addAttribute(.foregroundColor, value: NSColor.clear, range: clamp(range, to: out.length))

        case let para as Paragraph:
            // Paragraphs only need inline pass; no extra block style.
            applyInline(in: para, range: range, out: out, theme: theme, blockId: blockId, map: map)

        case let table as Markdown.Table:
            applyTable(table, range: range, out: out, theme: theme, blockId: blockId, map: map)

        default:
            // Unknown / unsupported block — leave defaults; still recurse so
            // inline content gets formatted.
            for child in node.children {
                if let inline = child as? InlineMarkup {
                    applyInlineNode(inline, out: out, theme: theme,
                                     blockId: blockId, map: map)
                }
            }
        }
    }

    // MARK: - Headings

    private static func applyHeading(
        _ heading: Heading,
        range: NSRange,
        out: NSMutableAttributedString,
        theme: MarkdownTheme,
        blockId: UUID
    ) {
        let level = heading.level
        let font = theme.headingFont(level: level)
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.2
        style.paragraphSpacingBefore = theme.headingSpacingBefore(level: level)
        style.paragraphSpacing = 6
        let clamped = clamp(range, to: out.length)
        out.addAttribute(.font, value: font, range: clamped)
        out.addAttribute(.paragraphStyle, value: style, range: clamped)
        out.addAttribute(.foregroundColor, value: theme.primary, range: clamped)

        // Dim the leading "#"+ space.
        let nsSource = out.string as NSString
        let lineRange = nsSource.lineRange(for: NSRange(location: clamped.location, length: 0))
        let line = nsSource.substring(with: lineRange)
        if let match = line.range(of: #"^#{1,6} "#, options: .regularExpression) {
            let prefixLen = line.distance(from: line.startIndex, to: match.upperBound)
            let prefixRange = NSRange(location: lineRange.location, length: prefixLen)
            out.addAttribute(.foregroundColor, value: theme.marker, range: clamp(prefixRange, to: out.length))
            out.addAttribute(.scribeSyntaxMarker, value: true, range: clamp(prefixRange, to: out.length))
            out.addAttribute(.scribeBlockId, value: blockId, range: clamp(prefixRange, to: out.length))
        }

        // Apply inline children (covers bold/italic inside headings).
        applyInline(in: heading, range: clamped, out: out, theme: theme, blockId: blockId, map: nil)
    }

    // MARK: - Code blocks

    private static func applyCodeBlock(
        _ cb: CodeBlock,
        range: NSRange,
        out: NSMutableAttributedString,
        theme: MarkdownTheme,
        blockId: UUID
    ) {
        let clamped = clamp(range, to: out.length)
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.4
        style.headIndent = 16
        style.firstLineHeadIndent = 16
        style.paragraphSpacingBefore = 6
        style.paragraphSpacing = 6
        out.addAttributes([
            .font: theme.codeBlockFont,
            .foregroundColor: theme.primary,
            .paragraphStyle: style,
            .codeBlockLine: true,
            .codeBlockId: blockId,
            .codeBlockLanguage: cb.language ?? "",
        ], range: clamped)

        // Dim the fence lines (first + last line of the block, if they exist).
        let nsSource = out.string as NSString
        let firstLine = nsSource.lineRange(for: NSRange(location: clamped.location, length: 0))
        out.addAttribute(.foregroundColor, value: theme.marker, range: clamp(firstLine, to: out.length))
        out.addAttribute(.scribeSyntaxMarker, value: true, range: clamp(firstLine, to: out.length))

        let lastCharLoc = max(clamped.location, clamped.location + clamped.length - 1)
        if lastCharLoc < nsSource.length {
            let lastLine = nsSource.lineRange(for: NSRange(location: lastCharLoc, length: 0))
            if lastLine.location != firstLine.location {
                out.addAttribute(.foregroundColor, value: theme.marker, range: clamp(lastLine, to: out.length))
                out.addAttribute(.scribeSyntaxMarker, value: true, range: clamp(lastLine, to: out.length))
            }
        }
    }

    // MARK: - Blockquote

    private static func applyBlockQuote(
        _ bq: BlockQuote,
        range: NSRange,
        out: NSMutableAttributedString,
        theme: MarkdownTheme,
        depth: Int,
        blockId: UUID,
        source: String,
        map: SourceMap,
        cursorOffset: Int?,
        revealedBlockId: inout UUID?
    ) {
        let clamped = clamp(range, to: out.length)
        out.addAttribute(.blockquoteLine, value: true, range: clamped)
        out.addAttribute(.blockquoteDepth, value: depth, range: clamped)
        out.addAttribute(.foregroundColor, value: theme.secondary, range: clamped)

        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.5
        style.headIndent = CGFloat(depth) * 22
        style.firstLineHeadIndent = CGFloat(depth) * 22
        style.paragraphSpacing = 2
        out.addAttribute(.paragraphStyle, value: style, range: clamped)

        // Dim the "> " prefix at the start of each line inside this block.
        let nsSource = out.string as NSString
        var loc = clamped.location
        while loc < clamped.location + clamped.length {
            let lineRange = nsSource.lineRange(for: NSRange(location: loc, length: 0))
            let line = nsSource.substring(with: lineRange)
            if let match = line.range(of: #"^>+ ?"#, options: .regularExpression) {
                let prefixLen = line.distance(from: line.startIndex, to: match.upperBound)
                let prefixRange = NSRange(location: lineRange.location, length: prefixLen)
                out.addAttribute(.foregroundColor, value: theme.marker, range: clamp(prefixRange, to: out.length))
                out.addAttribute(.scribeSyntaxMarker, value: true, range: clamp(prefixRange, to: out.length))
                out.addAttribute(.scribeBlockId, value: blockId, range: clamp(prefixRange, to: out.length))
            }
            loc = lineRange.location + lineRange.length
            if lineRange.length == 0 { break }
        }

        // Recurse children — blockquote contains other blocks.
        for child in bq.children {
            applyBlock(child, to: out, source: source, map: map, theme: theme,
                       blockquoteDepth: depth, cursorOffset: cursorOffset,
                       revealedBlockId: &revealedBlockId)
        }
    }

    // MARK: - Lists

    private static func applyList(
        _ list: Markup,
        range: NSRange,
        out: NSMutableAttributedString,
        theme: MarkdownTheme,
        ordered: Bool,
        source: String,
        map: SourceMap,
        cursorOffset: Int?,
        revealedBlockId: inout UUID?
    ) {
        for case let item as ListItem in list.children {
            guard let itemRange = item.range.flatMap(map.range(for:)) else { continue }
            let clampedItem = clamp(itemRange, to: out.length)
            let depth = listDepth(of: item)
            let indentBase = CGFloat(depth) * 22
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.5
            style.paragraphSpacing = 1
            style.firstLineHeadIndent = indentBase
            style.headIndent = indentBase + 20
            out.addAttribute(.paragraphStyle, value: style, range: clampedItem)

            let blockId = UUID()
            out.addAttribute(.scribeBlockId, value: blockId, range: clampedItem)
            if let cursor = cursorOffset, clampedItem.contains(cursor) || cursor == clampedItem.location {
                revealedBlockId = blockId
            }

            // Find and tag the list-item marker (`-`, `*`, `+`, or `1.`) at the start of the first line.
            let nsSource = out.string as NSString
            let firstLine = nsSource.lineRange(for: NSRange(location: clampedItem.location, length: 0))
            let lineText = nsSource.substring(with: firstLine)
            let markerPattern = ordered ? #"^\s*(\d+\.) "# : #"^\s*([-*+]) "#
            if let match = lineText.range(of: markerPattern, options: .regularExpression) {
                let markerEnd = lineText.distance(from: lineText.startIndex, to: match.upperBound)
                let markerRange = NSRange(location: firstLine.location, length: markerEnd)
                out.addAttribute(.scribeListMarker, value: true, range: clamp(markerRange, to: out.length))
                out.addAttribute(.foregroundColor, value: theme.marker, range: clamp(markerRange, to: out.length))
                out.addAttribute(.scribeBlockId, value: blockId, range: clamp(markerRange, to: out.length))
            }

            // Recurse into list-item children (may contain paragraphs, nested lists).
            for child in item.children {
                applyBlock(child, to: out, source: source, map: map, theme: theme,
                           blockquoteDepth: 0, cursorOffset: cursorOffset,
                           revealedBlockId: &revealedBlockId)
            }
        }
    }

    private static func listDepth(of node: Markup) -> Int {
        var depth = 0
        var current: Markup? = node.parent
        while let n = current {
            if n is UnorderedList || n is OrderedList { depth += 1 }
            current = n.parent
        }
        return max(0, depth - 1) // depth=0 for the outermost list
    }

    // MARK: - Inline (entry points)

    /// Walks all inline descendants of a block and applies inline styling.
    private static func applyInline(
        in block: Markup,
        range: NSRange,
        out: NSMutableAttributedString,
        theme: MarkdownTheme,
        blockId: UUID,
        map: SourceMap?
    ) {
        for inline in block.children {
            if let im = inline as? InlineMarkup {
                applyInlineNode(im, out: out, theme: theme, blockId: blockId, map: map)
            } else if let inner = inline as? Paragraph {
                // Some block-in-block cases (e.g. list-item → paragraph) — recurse.
                applyInline(in: inner, range: range, out: out, theme: theme,
                             blockId: blockId, map: map)
            }
        }
    }

    private static func applyInlineNode(
        _ node: InlineMarkup,
        out: NSMutableAttributedString,
        theme: MarkdownTheme,
        blockId: UUID,
        map: SourceMap?
    ) {
        guard let nodeRange = node.range, let r = map?.range(for: nodeRange) else {
            // No source range available — recurse children only.
            for child in node.children {
                if let c = child as? InlineMarkup {
                    applyInlineNode(c, out: out, theme: theme, blockId: blockId, map: map)
                }
            }
            return
        }
        let clamped = clamp(r, to: out.length)

        switch node {
        case let strong as Strong:
            applyEmphasisLike(node: strong, fullRange: clamped, out: out, theme: theme,
                               blockId: blockId, map: map, traits: .bold)

        case let emph as Emphasis:
            applyEmphasisLike(node: emph, fullRange: clamped, out: out, theme: theme,
                               blockId: blockId, map: map, traits: .italic)

        case let strike as Strikethrough:
            applyEmphasisLike(node: strike, fullRange: clamped, out: out, theme: theme,
                               blockId: blockId, map: map, traits: [],
                               strikethrough: true)

        case let code as InlineCode:
            applyInlineCode(code, fullRange: clamped, out: out, theme: theme, blockId: blockId)

        case let link as Link:
            applyLink(link, fullRange: clamped, out: out, theme: theme, blockId: blockId, map: map)

        case let image as Markdown.Image:
            // We mark the image span dim so it reads as a token; the editor's
            // existing image-fold pass will replace it with an attachment.
            out.addAttribute(.foregroundColor, value: theme.dim, range: clamped)
            out.addAttribute(.scribeSyntaxMarker, value: true, range: clamped)
            _ = image

        default:
            // Text, SoftBreak, LineBreak, HTML — no styling needed.
            for child in node.children {
                if let c = child as? InlineMarkup {
                    applyInlineNode(c, out: out, theme: theme, blockId: blockId, map: map)
                }
            }
        }
    }

    // MARK: - Emphasis / Strong / Strikethrough

    private static func applyEmphasisLike(
        node: InlineMarkup,
        fullRange: NSRange,
        out: NSMutableAttributedString,
        theme: MarkdownTheme,
        blockId: UUID,
        map: SourceMap?,
        traits: NSFontDescriptor.SymbolicTraits,
        strikethrough: Bool = false
    ) {
        // Locate the content (children's union range) so we can dim the markers.
        let childRanges: [NSRange] = node.children.compactMap { child -> NSRange? in
            guard let r = child.range else { return nil }
            return map?.range(for: r)
        }
        let contentRange: NSRange
        if let first = childRanges.first {
            let start = first.location
            let end = childRanges.map { $0.location + $0.length }.max() ?? (first.location + first.length)
            contentRange = clamp(NSRange(location: start, length: end - start), to: out.length)
        } else {
            contentRange = fullRange
        }

        // Apply trait to content while preserving any prior trait on overlapping runs
        // (e.g. **bold _italic_** — the italic child already saw the italic trait).
        if !traits.isEmpty {
            out.enumerateAttribute(.font, in: contentRange, options: []) { value, sub, _ in
                let current = (value as? NSFont) ?? theme.baseFont
                let descriptor = current.fontDescriptor.withSymbolicTraits(
                    current.fontDescriptor.symbolicTraits.union(traits)
                )
                if let traited = NSFont(descriptor: descriptor, size: current.pointSize) {
                    out.addAttribute(.font, value: traited, range: sub)
                }
            }
        }
        if strikethrough {
            out.addAttribute(.strikethroughStyle,
                             value: NSUnderlineStyle.single.rawValue, range: contentRange)
        }

        // Marker ranges = fullRange minus contentRange (prefix + suffix).
        let prefixLen = contentRange.location - fullRange.location
        let suffixStart = contentRange.location + contentRange.length
        let suffixLen = (fullRange.location + fullRange.length) - suffixStart
        if prefixLen > 0 {
            let r = NSRange(location: fullRange.location, length: prefixLen)
            out.addAttribute(.foregroundColor, value: theme.marker, range: clamp(r, to: out.length))
            out.addAttribute(.scribeSyntaxMarker, value: true, range: clamp(r, to: out.length))
            out.addAttribute(.scribeBlockId, value: blockId, range: clamp(r, to: out.length))
        }
        if suffixLen > 0 {
            let r = NSRange(location: suffixStart, length: suffixLen)
            out.addAttribute(.foregroundColor, value: theme.marker, range: clamp(r, to: out.length))
            out.addAttribute(.scribeSyntaxMarker, value: true, range: clamp(r, to: out.length))
            out.addAttribute(.scribeBlockId, value: blockId, range: clamp(r, to: out.length))
        }

        // Recurse into children to allow nested emphasis.
        for child in node.children {
            if let c = child as? InlineMarkup {
                applyInlineNode(c, out: out, theme: theme, blockId: blockId, map: map)
            }
        }
    }

    // MARK: - Inline code

    private static func applyInlineCode(
        _ node: InlineCode,
        fullRange: NSRange,
        out: NSMutableAttributedString,
        theme: MarkdownTheme,
        blockId: UUID
    ) {
        // Source includes the backticks; AST `.code` gives the content. Find the
        // backtick run on each side by scanning the source text.
        let nsSource = out.string as NSString
        guard fullRange.length > 0, fullRange.location + fullRange.length <= nsSource.length else { return }
        let raw = nsSource.substring(with: fullRange)
        var leading = 0
        for ch in raw {
            if ch == "`" { leading += 1 } else { break }
        }
        var trailing = 0
        for ch in raw.reversed() {
            if ch == "`" { trailing += 1 } else { break }
        }
        guard leading > 0, trailing > 0, leading + trailing < fullRange.length else { return }

        let contentRange = NSRange(
            location: fullRange.location + leading,
            length: fullRange.length - leading - trailing
        )
        out.addAttribute(.font, value: theme.monoFont, range: contentRange)
        out.addAttribute(.foregroundColor, value: theme.secondary, range: contentRange)
        out.addAttribute(.scribeInlineCode, value: true, range: contentRange)
        out.addAttribute(.scribeBlockId, value: blockId, range: contentRange)

        let prefix = NSRange(location: fullRange.location, length: leading)
        let suffix = NSRange(location: contentRange.location + contentRange.length, length: trailing)
        out.addAttribute(.foregroundColor, value: theme.marker, range: prefix)
        out.addAttribute(.scribeSyntaxMarker, value: true, range: prefix)
        out.addAttribute(.foregroundColor, value: theme.marker, range: suffix)
        out.addAttribute(.scribeSyntaxMarker, value: true, range: suffix)
    }

    // MARK: - Links

    private static func applyLink(
        _ link: Link,
        fullRange: NSRange,
        out: NSMutableAttributedString,
        theme: MarkdownTheme,
        blockId: UUID,
        map: SourceMap?
    ) {
        // Source: `[label](url)` or `[label](url "title")` or autolink `<url>`.
        let nsSource = out.string as NSString
        guard fullRange.length > 0, fullRange.location + fullRange.length <= nsSource.length else { return }
        let raw = nsSource.substring(with: fullRange)

        if raw.hasPrefix("[") {
            // Standard link.
            // Find `]` followed by `(` to split label/url.
            if let closeBracket = raw.firstIndex(of: "]") {
                let labelLen = raw.distance(from: raw.startIndex, to: closeBracket)
                let labelRange = NSRange(location: fullRange.location + 1, length: max(0, labelLen - 1))
                let urlStart = fullRange.location + labelLen + 1   // past `](`
                let markerStart = NSRange(location: fullRange.location, length: 1) // `[`
                let markerMid   = NSRange(location: fullRange.location + labelLen, length: 2) // `](`
                let urlLen = (fullRange.location + fullRange.length) - urlStart - 1
                let urlRange = NSRange(location: urlStart + 1, length: max(0, urlLen))
                let closeParen = NSRange(location: fullRange.location + fullRange.length - 1, length: 1)

                // Style the label as a link.
                if labelRange.length > 0 {
                    out.addAttribute(.foregroundColor, value: NSColor.linkColor, range: clamp(labelRange, to: out.length))
                    out.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                     range: clamp(labelRange, to: out.length))
                    if let dest = link.destination, let url = URL(string: dest) {
                        out.addAttribute(.link, value: url, range: clamp(labelRange, to: out.length))
                    }
                }
                // Markers dimmed.
                for r in [markerStart, markerMid, urlRange, closeParen] {
                    let c = clamp(r, to: out.length)
                    if c.length > 0 {
                        out.addAttribute(.foregroundColor, value: theme.marker, range: c)
                        out.addAttribute(.scribeSyntaxMarker, value: true, range: c)
                        out.addAttribute(.scribeBlockId, value: blockId, range: c)
                    }
                }
            }
        } else if raw.hasPrefix("<"), raw.hasSuffix(">") {
            // Autolink in `<…>` form.
            let inner = NSRange(location: fullRange.location + 1, length: fullRange.length - 2)
            out.addAttribute(.foregroundColor, value: NSColor.linkColor, range: clamp(inner, to: out.length))
            out.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: clamp(inner, to: out.length))
            if let dest = link.destination, let url = URL(string: dest) {
                out.addAttribute(.link, value: url, range: clamp(inner, to: out.length))
            }
            let lt = NSRange(location: fullRange.location, length: 1)
            let gt = NSRange(location: fullRange.location + fullRange.length - 1, length: 1)
            for r in [lt, gt] {
                out.addAttribute(.foregroundColor, value: theme.marker, range: r)
                out.addAttribute(.scribeSyntaxMarker, value: true, range: r)
            }
        }
        _ = map
    }

    // MARK: - Tables

    private static func applyTable(
        _ table: Markdown.Table,
        range: NSRange,
        out: NSMutableAttributedString,
        theme: MarkdownTheme,
        blockId: UUID,
        map: SourceMap
    ) {
        let clamped = clamp(range, to: out.length)
        // Mark each line as a table cell row so drawBackground can lay out grid lines.
        let nsSource = out.string as NSString
        var loc = clamped.location
        while loc < clamped.location + clamped.length {
            let lineRange = nsSource.lineRange(for: NSRange(location: loc, length: 0))
            let c = clamp(lineRange, to: out.length)
            if c.length > 0 {
                out.addAttribute(.scribeTableCell, value: true, range: c)
                out.addAttribute(.font, value: theme.monoFont, range: c)
            }
            loc = lineRange.location + lineRange.length
            if lineRange.length == 0 { break }
        }
        _ = map
    }

    // MARK: - Autolink bare URLs

    private static let urlRegex: NSRegularExpression = {
        // Match http(s)://… up to whitespace or closing punctuation.
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(
            pattern: #"https?://[^\s<>\[\]\(\)`]+"#
        )
    }()

    private static func autolinkBareURLs(in out: NSMutableAttributedString, source: String) {
        let full = NSRange(location: 0, length: out.length)
        for match in urlRegex.matches(in: source, range: full) {
            let r = match.range
            // Skip if already inside a Link (has .link), or inside code (.scribeInlineCode / .codeBlockLine).
            if out.attribute(.link, at: r.location, effectiveRange: nil) != nil { continue }
            if out.attribute(.scribeInlineCode, at: r.location, effectiveRange: nil) as? Bool == true { continue }
            if out.attribute(.codeBlockLine, at: r.location, effectiveRange: nil) as? Bool == true { continue }
            guard let url = URL(string: (source as NSString).substring(with: r)) else { continue }
            out.addAttribute(.link, value: url, range: r)
            out.addAttribute(.foregroundColor, value: NSColor.linkColor, range: r)
            out.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            out.addAttribute(.scribeAutoLinkURL, value: url, range: r)
        }
    }

    // MARK: - Cursor-proximity reveal

    /// Walk all `.scribeSyntaxMarker` runs; if their `.scribeBlockId` doesn't match
    /// the cursor's owner, hide them by setting foreground to clear.
    private static func applyMarkerReveal(
        to out: NSMutableAttributedString,
        revealedBlockId: UUID?,
        theme: MarkdownTheme
    ) {
        let full = NSRange(location: 0, length: out.length)
        out.enumerateAttribute(.scribeSyntaxMarker, in: full, options: []) { value, range, _ in
            guard (value as? Bool) == true else { return }
            let owner = out.attribute(.scribeBlockId, at: range.location, effectiveRange: nil) as? UUID
            if owner == revealedBlockId {
                // Cursor is in this block — keep markers visible (already dimmed).
                return
            }
            // Hide: set foreground to clear. Glyphs still take space (preserves
            // selection / undo positions); they just don't render visibly.
            out.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        }
    }

    // MARK: - Helpers

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let loc = max(0, min(range.location, length))
        let len = max(0, min(range.length, length - loc))
        return NSRange(location: loc, length: len)
    }
}
