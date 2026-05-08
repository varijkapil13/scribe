import AppKit
import SwiftUI

// Custom attribute key storing the anchor text for [[wiki-links]].
// Set during extraHighlighter; read in mouseDown — no scanning needed.
extension NSAttributedString.Key {
    static let wikiAnchor = NSAttributedString.Key("scribe.wikiAnchor")
}

/// Bear-style inline markdown editor: a single NSTextView that formats
/// markdown syntax visually as you type. Syntax markers (**, *, #, etc.)
/// are dimmed; content (bold, italic, heading text) is styled.
///
/// No mode-switching. Always editable. Binding holds raw markdown string.
struct MarkdownEditorView: NSViewRepresentable {

    @Binding var text: String
    var placeholder: String = "Notes…"
    var font: NSFont = .systemFont(ofSize: 15)
    var extraHighlighter: ((NSMutableAttributedString) -> Void)? = nil
    var onWikiLinkTyped: ((String) -> Void)? = nil
    var onWikiLinkNavigate: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let tv = MarkdownNSTextView()
        tv.isRichText = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = font
        tv.textColor = .labelColor
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.focusRingType = .none
        tv.placeholderString = placeholder

        tv.textContainer?.containerSize = CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]

        scrollView.documentView = tv
        tv.delegate = context.coordinator
        let coordinator = context.coordinator
        tv.onLinkClick = { anchor in
            coordinator.parent.onWikiLinkNavigate?(anchor)
        }
        context.coordinator.textView = tv
        context.coordinator.parent = self
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? MarkdownNSTextView else { return }
        context.coordinator.parent = self
        let live = tv.string
        if live != text {
            if text.isEmpty {
                tv.textStorage?.beginEditing()
                tv.textStorage?.setAttributedString(NSAttributedString(string: ""))
                tv.textStorage?.endEditing()
                tv.string = ""
                tv.needsDisplay = true
            } else if tv.window?.firstResponder !== tv {
                tv.string = text
                context.coordinator.applyFormatting(to: tv)
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: MarkdownEditorView
        weak var textView: MarkdownNSTextView?

        init(_ parent: MarkdownEditorView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            if let mtv = tv as? MarkdownNSTextView {
                applyFormatting(to: mtv)
            }
            detectWikiLinkTyping(in: tv)
        }

        private func detectWikiLinkTyping(in tv: NSTextView) {
            let cursorPos = tv.selectedRange().location
            let text = tv.string
            let prefix = String(text.prefix(cursorPos))
            if let lastOpen = prefix.range(of: "[[", options: .backwards) {
                let afterOpen = String(prefix[lastOpen.upperBound...])
                if !afterOpen.contains("]]") {
                    parent.onWikiLinkTyped?(afterOpen)
                    return
                }
            }
            parent.onWikiLinkTyped?("")
        }

        func applyFormatting(to tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let raw = tv.string
            guard !raw.isEmpty else { return }
            let font = tv.font ?? parent.font
            let formatted = MarkdownFormatter.attributed(raw, font: font)
            // Apply extra highlighting (e.g., [[wiki-links]])
            let mutable = NSMutableAttributedString(attributedString: formatted)
            parent.extraHighlighter?(mutable)
            let saved = tv.selectedRanges
            storage.beginEditing()
            storage.setAttributedString(mutable)
            storage.endEditing()
            let len = storage.length
            tv.selectedRanges = saved.map { v in
                let r = v.rangeValue
                return NSValue(range: NSRange(
                    location: min(r.location, len),
                    length: min(r.length, max(0, len - r.location))
                ))
            }
            (tv as? MarkdownNSTextView)?.needsDisplay = true
        }
    }
}

// MARK: - NSTextView with placeholder

final class MarkdownNSTextView: NSTextView {
    var placeholderString: String = ""
    var onLinkClick: ((String) -> Void)? = nil

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let sideInset = max(16, (newSize.width - 640) / 2)
        textContainerInset = NSSize(width: sideInset, height: 12)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard let onLinkClick, let storage = textStorage else { return }
        let pt = convert(event.locationInWindow, from: nil)
        guard let lm = layoutManager, let tc = textContainer else { return }
        let glyphIdx = lm.glyphIndex(for: pt, in: tc)
        guard glyphIdx < lm.numberOfGlyphs else { return }
        let charIdx = lm.characterIndexForGlyph(at: glyphIdx)
        guard charIdx < storage.length else { return }
        // Read the wikiAnchor attribute set by extraHighlighter — no scanning needed.
        let attrs = storage.attributes(at: charIdx, effectiveRange: nil)
        guard let anchor = attrs[.wikiAnchor] as? String, !anchor.isEmpty else { return }
        onLinkClick(anchor)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ]
        let pad = textContainerInset
        let linePad = textContainer?.lineFragmentPadding ?? 5
        (placeholderString as NSString).draw(
            in: NSRect(x: pad.width + linePad, y: pad.height,
                       width: bounds.width - pad.width * 2 - linePad,
                       height: bounds.height),
            withAttributes: attrs
        )
    }
}

// MARK: - Formatting engine

enum MarkdownFormatter {

    static func attributed(_ text: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if i > 0 { result.append(.init(string: "\n")) }
            result.append(formattedLine(line, font: font))
        }
        return result
    }

    // MARK: Per-line

    private static func formattedLine(_ line: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: line, attributes: base(font))
        let dim    = NSColor.tertiaryLabelColor
        let mono   = NSFont.monospacedSystemFont(ofSize: font.pointSize - 0.5, weight: .regular)

        // Headings: up to 3 levels
        if let (hashes, rest) = parseHeading(line) {
            let level = min(hashes, 3)
            let size: CGFloat = font.pointSize + CGFloat([4, 2, 1][level - 1])
            let headFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.bold), size: size)
                        ?? NSFont.boldSystemFont(ofSize: size)
            let prefixLen = hashes + 1            // "# " or "## " etc.
            let prefixRange = NSRange(location: 0, length: min(prefixLen, line.utf16.count))
            let textRange  = NSRange(location: prefixLen, length: max(0, line.utf16.count - prefixLen))
            result.addAttribute(.foregroundColor, value: dim, range: prefixRange)
            if textRange.length > 0 { result.addAttribute(.font, value: headFont, range: textRange) }
            // Inline on the heading text
            applyInline(to: result, offset: prefixLen, text: rest, baseFont: headFont, dim: dim, mono: mono)
            return result
        }

        // Blockquote: > text
        if line.hasPrefix("> ") {
            let quoteRange = NSRange(location: 0, length: 2)
            result.addAttribute(.foregroundColor, value: dim, range: quoteRange)
            result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                range: NSRange(location: 2, length: max(0, line.utf16.count - 2)))
        }

        // List bullets: - / * / + / 1.
        if let prefixLen = listPrefixLength(line) {
            let bulletRange = NSRange(location: 0, length: prefixLen)
            result.addAttribute(.foregroundColor, value: dim, range: bulletRange)
        }

        // Horizontal rule: --- or *** (whole line)
        if line.trimmingCharacters(in: .whitespaces).matches(#"^[-*_]{3,}$"#) {
            result.addAttribute(.foregroundColor, value: dim, range: NSRange(location: 0, length: line.utf16.count))
            return result
        }

        applyInline(to: result, offset: 0, text: line, baseFont: font, dim: dim, mono: mono)
        return result
    }

    // MARK: Inline formatting

    private static func applyInline(
        to str: NSMutableAttributedString,
        offset: Int,
        text: String,
        baseFont: NSFont,
        dim: NSColor,
        mono: NSFont
    ) {
        let boldItalic = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits([.bold, .italic]), size: baseFont.pointSize) ?? baseFont
        let bold       = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits(.bold), size: baseFont.pointSize) ?? baseFont
        let italic     = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic), size: baseFont.pointSize) ?? baseFont

        // Order matters: process longest markers first to avoid partial matches.
        // Bold-italic ***...***
        apply(pattern: #"\*{3}([^*\n]+?)\*{3}"#, in: text, offset: offset, to: str) { markerRanges, contentRange in
            markerRanges.forEach { str.addAttribute(.foregroundColor, value: dim, range: $0) }
            str.addAttribute(.font, value: boldItalic, range: contentRange)
        }
        // Bold **...**
        apply(pattern: #"\*{2}([^*\n]+?)\*{2}"#, in: text, offset: offset, to: str) { markerRanges, contentRange in
            markerRanges.forEach { str.addAttribute(.foregroundColor, value: dim, range: $0) }
            str.addAttribute(.font, value: bold, range: contentRange)
        }
        // Bold __...__
        apply(pattern: #"_{2}([^_\n]+?)_{2}"#, in: text, offset: offset, to: str) { markerRanges, contentRange in
            markerRanges.forEach { str.addAttribute(.foregroundColor, value: dim, range: $0) }
            str.addAttribute(.font, value: bold, range: contentRange)
        }
        // Italic *...*
        apply(pattern: #"(?<!\*)\*([^*\n]+?)\*(?!\*)"#, in: text, offset: offset, to: str) { markerRanges, contentRange in
            markerRanges.forEach { str.addAttribute(.foregroundColor, value: dim, range: $0) }
            str.addAttribute(.font, value: italic, range: contentRange)
        }
        // Italic _..._
        apply(pattern: #"(?<!_)_([^_\n]+?)_(?!_)"#, in: text, offset: offset, to: str) { markerRanges, contentRange in
            markerRanges.forEach { str.addAttribute(.foregroundColor, value: dim, range: $0) }
            str.addAttribute(.font, value: italic, range: contentRange)
        }
        // Inline code `...`
        apply(pattern: #"`([^`\n]+?)`"#, in: text, offset: offset, to: str) { markerRanges, contentRange in
            markerRanges.forEach { str.addAttribute(.foregroundColor, value: dim, range: $0) }
            str.addAttribute(.font, value: mono, range: contentRange)
            str.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: contentRange)
        }
        // Strikethrough ~~...~~
        apply(pattern: #"~~([^~\n]+?)~~"#, in: text, offset: offset, to: str) { markerRanges, contentRange in
            markerRanges.forEach { str.addAttribute(.foregroundColor, value: dim, range: $0) }
            str.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: contentRange)
        }
    }

    // MARK: Pattern helper

    private static func apply(
        pattern: String,
        in text: String,
        offset: Int,
        to str: NSMutableAttributedString,
        _ apply: ([NSRange], NSRange) -> Void
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let fullText = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: fullText) {
            guard match.numberOfRanges >= 2 else { continue }
            let fullNS    = match.range
            let captureNS = match.range(at: 1)
            guard captureNS.location != NSNotFound, fullNS.location != NSNotFound else { continue }

            let fullOff    = NSRange(location: fullNS.location + offset,    length: fullNS.length)
            let captureOff = NSRange(location: captureNS.location + offset, length: captureNS.length)

            let prefixLen = captureOff.location - fullOff.location
            let suffixLen = (fullOff.location + fullOff.length) - (captureOff.location + captureOff.length)
            var markers: [NSRange] = []
            if prefixLen > 0 { markers.append(NSRange(location: fullOff.location, length: prefixLen)) }
            if suffixLen > 0 { markers.append(NSRange(location: captureOff.location + captureOff.length, length: suffixLen)) }

            apply(markers, captureOff)
        }
    }

    // MARK: Small helpers

    private static func base(_ font: NSFont) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.7
        style.paragraphSpacing = 8
        return [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style
        ]
    }

    private static func parseHeading(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        var i = line.startIndex
        var count = 0
        while i < line.endIndex, line[i] == "#" {
            count += 1
            i = line.index(after: i)
        }
        guard count <= 6, i < line.endIndex, line[i] == " " else { return nil }
        let rest = String(line[line.index(after: i)...])
        return (count, rest)
    }

    private static func listPrefixLength(_ line: String) -> Int? {
        // "- ", "* ", "+ ", "  - ", numbered "1. "
        if let r = line.range(of: #"^\s*[-*+] "#, options: .regularExpression) {
            return line.distance(from: line.startIndex, to: r.upperBound)
        }
        if let r = line.range(of: #"^\s*\d+\. "#, options: .regularExpression) {
            return line.distance(from: line.startIndex, to: r.upperBound)
        }
        return nil
    }
}

private extension String {
    func matches(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern))
            .map { $0.firstMatch(in: self, range: NSRange(startIndex..., in: self)) != nil } ?? false
    }
}
