// Extensions/ScribeQuickLook/ScribeMarkdownAttributedRenderer.swift
//
// Renders a Markdown note into an NSAttributedString for the Quick Look
// preview. Block structure comes from `ScribeMarkdownPreviewParser`
// (Scribe/Shared, unit-tested); inline emphasis, code, strikethrough and
// links come from Foundation's `AttributedString(markdown:)`. No dependencies.

import AppKit
import Foundation

@MainActor
enum ScribeMarkdownAttributedRenderer {

    private static let bodySize: CGFloat = 14

    static func render(_ markdown: String) -> NSAttributedString {
        let document = ScribeMarkdownPreviewParser.parse(markdown)
        let output = NSMutableAttributedString()

        if let title = document.title {
            let isRepeatedAsHeading: Bool = {
                if case .heading(_, let text)? = document.blocks.first {
                    return text.caseInsensitiveCompare(title) == .orderedSame
                }
                return false
            }()
            if !isRepeatedAsHeading {
                append(.heading(level: 1, text: title), to: output)
            }
        }
        for block in document.blocks {
            append(block, to: output)
        }
        return output
    }

    // MARK: - Blocks

    private static func append(_ block: ScribeMarkdownPreviewBlock, to output: NSMutableAttributedString) {
        if output.length > 0 {
            output.append(NSAttributedString(string: "\n"))
        }
        switch block {
        case .heading(let level, let text):
            let sizes: [CGFloat] = [26, 21, 18, 16, 15, 14]
            let size = sizes[max(0, min(sizes.count - 1, level - 1))]
            let style = paragraphStyle(spacingBefore: level <= 2 ? 14 : 10, spacingAfter: 4)
            output.append(inline(text, size: size, weight: .bold, paragraph: style))

        case .paragraph(let text):
            output.append(inline(text, paragraph: paragraphStyle(spacingAfter: 8)))

        case .bullet(let indent, let text):
            output.append(listItem(marker: "•", text: text, indent: indent))

        case .numbered(let indent, let marker, let text):
            output.append(listItem(marker: marker, text: text, indent: indent))

        case .task(let indent, let isChecked, let text):
            let item = listItem(marker: isChecked ? "☑︎" : "☐", text: text, indent: indent)
            if isChecked {
                let muted = NSMutableAttributedString(attributedString: item)
                muted.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                   range: NSRange(location: 0, length: muted.length))
                output.append(muted)
            } else {
                output.append(item)
            }

        case .quote(let text):
            let style = paragraphStyle(spacingAfter: 8, indent: 16)
            let quoted = NSMutableAttributedString(attributedString: inline(text, paragraph: style))
            quoted.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                range: NSRange(location: 0, length: quoted.length))
            output.append(quoted)

        case .code(_, let text):
            let style = paragraphStyle(spacingAfter: 8, indent: 12)
            output.append(NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: bodySize - 1, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.quaternaryLabelColor,
                .paragraphStyle: style,
            ]))

        case .rule:
            let style = paragraphStyle(spacingBefore: 4, spacingAfter: 8)
            output.append(NSAttributedString(string: String(repeating: "─", count: 32), attributes: [
                .font: NSFont.systemFont(ofSize: bodySize),
                .foregroundColor: NSColor.separatorColor,
                .paragraphStyle: style,
            ]))
        }
    }

    private static func listItem(marker: String, text: String, indent: Int) -> NSAttributedString {
        let level = CGFloat(min(indent, 6))
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 8 + level * 18
        style.headIndent = 8 + level * 18 + 20
        style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent)]
        style.paragraphSpacing = 3
        let line = NSMutableAttributedString(string: "\(marker)\t", attributes: [
            .font: NSFont.systemFont(ofSize: bodySize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])
        line.append(inline(text, paragraph: style))
        return line
    }

    // MARK: - Inline

    /// Inline Markdown → attributed text. `[[Wiki links]]` are shown as their
    /// title in the link colour.
    private static func inline(
        _ text: String,
        size requestedSize: CGFloat? = nil,
        weight: NSFont.Weight = .regular,
        paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        let size = requestedSize ?? bodySize
        let prepared = text.replacingOccurrences(
            of: "\\[\\[([^\\]|]+)(\\|([^\\]]+))?\\]\\]",
            with: "[$1](#)",
            options: .regularExpression
        )
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        guard let parsed = try? AttributedString(markdown: prepared, options: options) else {
            return NSAttributedString(string: text, attributes: base)
        }

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var attributes = base
            let intent = run.inlinePresentationIntent ?? []
            attributes[.font] = font(size: size, weight: weight, intent: intent)
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if intent.contains(.code) {
                attributes[.backgroundColor] = NSColor.quaternaryLabelColor
            }
            if let link = run.link {
                attributes[.foregroundColor] = NSColor.linkColor
                if link.absoluteString != "#" {
                    attributes[.link] = link
                }
            }
            result.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return result
    }

    private static func font(size: CGFloat, weight: NSFont.Weight, intent: InlinePresentationIntent) -> NSFont {
        if intent.contains(.code) {
            return NSFont.monospacedSystemFont(ofSize: size - 1, weight: weight)
        }
        let isBold = intent.contains(.stronglyEmphasized) || weight == .bold
        var font = NSFont.systemFont(ofSize: size, weight: isBold ? .bold : weight)
        if intent.contains(.emphasized) {
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        return font
    }

    private static func paragraphStyle(
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat,
        indent: CGFloat = 0
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.lineSpacing = 2
        return style
    }
}
