import SwiftUI
import UIKit

/// A `UITextView`-backed editor that applies lightweight, live Markdown syntax
/// highlighting as the user types. The buffer stays the *raw* Markdown string
/// (bound two-way to the model) — we only restyle attributes, never the text.
///
/// Scope (deliberately minimal — see `NoteEditorScreen`):
///   - bold `**…**`
///   - italic `*…*` / `_…_`
///   - inline code `` `…` ``
///   - headings `# …`
///   - list markers `- ` / `* ` / `1. `
///   - blockquote `> …`
///
/// NOT in scope (follow-up, intentionally deferred): TextKit-2 decoration
/// overlays, rendered checkboxes / attachments, link previews. Those require
/// layout-fragment decoration rather than plain attribute styling.
struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isScrollEnabled = true
        textView.backgroundColor = .clear
        textView.alwaysBounceVertical = true
        textView.autocorrectionType = .default
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        // Seed the buffer and initial styling.
        textView.attributedText = MarkdownHighlighter.attributedString(from: text)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // Only react to *external* changes (e.g. the model loaded the body from
        // disk). If the plain text already matches the binding, the change came
        // from the user and is already styled by `textViewDidChange` — touching
        // it here would clobber the caret.
        guard textView.text != text else { return }

        let selectedRange = textView.selectedRange
        context.coordinator.isApplyingStyling = true
        textView.attributedText = MarkdownHighlighter.attributedString(from: text)
        // Restore the caret, clamped to the (possibly shorter) new length.
        let length = (textView.text as NSString).length
        textView.selectedRange = NSRange(
            location: min(selectedRange.location, length),
            length: min(selectedRange.length, max(0, length - min(selectedRange.location, length)))
        )
        context.coordinator.isApplyingStyling = false
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: MarkdownTextView
        /// Guards against the styling pass (which mutates `textStorage`) being
        /// mistaken for a user edit and looping back through the binding.
        var isApplyingStyling = false

        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingStyling else { return }

            // Capture the caret before restyling — replacing attributes can
            // otherwise reset it to the end of the buffer.
            let selectedRange = textView.selectedRange
            let plain = textView.text ?? ""

            isApplyingStyling = true
            // Restyle in place. We keep the same characters, so the caret math
            // below is a straight restore.
            let styled = MarkdownHighlighter.attributedString(from: plain)
            let storage = textView.textStorage
            storage.beginEditing()
            storage.setAttributedString(styled)
            storage.endEditing()
            let length = (textView.text as NSString).length
            textView.selectedRange = NSRange(
                location: min(selectedRange.location, length),
                length: min(selectedRange.length, max(0, length - min(selectedRange.location, length)))
            )
            isApplyingStyling = false

            // Push the raw text back to the model (on the next runloop tick to
            // avoid mutating SwiftUI state during the UIKit edit callback).
            if parent.text != plain {
                DispatchQueue.main.async { [parent] in
                    parent.text = plain
                }
            }
        }
    }
}

// MARK: - Highlighter

/// Foundation/UIKit-only Markdown → `NSAttributedString` styler. Builds over a
/// base body font + label color, then overlays inline/block styles via simple
/// regexes. No text mutation: ranges map 1:1 onto the source string.
///
/// `@MainActor` because it touches UIKit (`UIFont`/`UIColor`) and is only ever
/// driven from the main thread (SwiftUI view methods + `UITextViewDelegate`).
@MainActor
enum MarkdownHighlighter {
    private static var baseFont: UIFont { UIFont.preferredFont(forTextStyle: .body) }
    private static var monoFont: UIFont {
        UIFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
    }

    static func attributedString(from text: String) -> NSAttributedString {
        let full = NSRange(location: 0, length: (text as NSString).length)
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: baseFont,
            .foregroundColor: UIColor.label,
        ])
        guard full.length > 0 else { return result }

        // Block-level styles first (line-anchored), then inline spans.
        applyHeadings(result, full: full)
        applyBlockquotes(result, full: full)
        applyListMarkers(result, full: full)
        applyInlineCode(result, full: full)
        applyBold(result, full: full)
        applyItalic(result, full: full)
        return result
    }

    // MARK: Block-level

    /// `# …` … `###### …` — bold + scaled font for the whole line; the marker
    /// is dimmed.
    private static func applyHeadings(_ s: NSMutableAttributedString, full: NSRange) {
        enumerate(#"(?m)^(#{1,6})[ \t]+(.+)$"#, in: s, full: full) { match, str in
            let hashes = match.range(at: 1)
            let level = hashes.length
            let scale: CGFloat = max(1.0, 1.6 - CGFloat(level - 1) * 0.1)
            let size = baseFont.pointSize * scale
            let headingFont = UIFont.systemFont(ofSize: size, weight: .bold)
            s.addAttribute(.font, value: headingFont, range: match.range)
            dim(s, range: hashes)
        }
    }

    /// `> …` — secondary color for the whole line.
    private static func applyBlockquotes(_ s: NSMutableAttributedString, full: NSRange) {
        enumerate(#"(?m)^[ \t]*>[ \t]?.*$"#, in: s, full: full) { match, _ in
            s.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: match.range)
        }
    }

    /// Unordered (`- `, `* `, `+ `) and ordered (`1. `) list markers — the
    /// marker glyph is tinted; the content keeps base styling.
    private static func applyListMarkers(_ s: NSMutableAttributedString, full: NSRange) {
        enumerate(#"(?m)^[ \t]*([-*+]|\d+\.)[ \t]+"#, in: s, full: full) { match, _ in
            let marker = match.range(at: 1)
            s.addAttribute(.foregroundColor, value: UIColor.tintColor, range: marker)
            s.addAttribute(.font, value: UIFont.systemFont(
                ofSize: baseFont.pointSize, weight: .semibold), range: marker)
        }
    }

    // MARK: Inline

    /// `` `code` `` — monospace + secondary background; backticks dimmed.
    private static func applyInlineCode(_ s: NSMutableAttributedString, full: NSRange) {
        enumerate(#"`([^`\n]+)`"#, in: s, full: full) { match, _ in
            s.addAttribute(.font, value: monoFont, range: match.range)
            s.addAttribute(.backgroundColor, value: UIColor.secondarySystemFill, range: match.range)
            dim(s, range: match.range)
        }
    }

    /// `**bold**` / `__bold__` — bold body font; markers dimmed.
    private static func applyBold(_ s: NSMutableAttributedString, full: NSRange) {
        let bold = UIFont.systemFont(ofSize: baseFont.pointSize, weight: .bold)
        enumerate(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, in: s, full: full) { match, _ in
            s.addAttribute(.font, value: bold, range: match.range)
            dim(s, range: NSRange(location: match.range.location, length: 2))
            dim(s, range: NSRange(location: NSMaxRange(match.range) - 2, length: 2))
        }
    }

    /// `*italic*` / `_italic_` — italic body font; markers dimmed. Runs after
    /// bold so the doubled markers are already consumed.
    private static func applyItalic(_ s: NSMutableAttributedString, full: NSRange) {
        let italic = italicFont(ofSize: baseFont.pointSize)
        // Single `*`/`_` not adjacent to another (so `**` bold is skipped).
        enumerate(#"(?<![*_\w])([*_])(?=\S)([^*_\n]+?)(?<=\S)\1(?![*_\w])"#, in: s, full: full) { match, _ in
            s.addAttribute(.font, value: italic, range: match.range)
            dim(s, range: NSRange(location: match.range.location, length: 1))
            dim(s, range: NSRange(location: NSMaxRange(match.range) - 1, length: 1))
        }
    }

    // MARK: Helpers

    private static func italicFont(ofSize size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size)
        if let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }

    private static func dim(_ s: NSMutableAttributedString, range: NSRange) {
        guard range.location >= 0, NSMaxRange(range) <= s.length else { return }
        s.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel, range: range)
    }

    /// Enumerates regex matches, clamping to the live string length so a stale
    /// `full` range can never index out of bounds.
    private static func enumerate(
        _ pattern: String,
        in s: NSMutableAttributedString,
        full: NSRange,
        body: (NSTextCheckingResult, NSMutableAttributedString) -> Void
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let safe = NSRange(location: 0, length: s.length)
        regex.enumerateMatches(in: s.string, options: [], range: safe) { match, _, _ in
            if let match { body(match, s) }
        }
    }
}
