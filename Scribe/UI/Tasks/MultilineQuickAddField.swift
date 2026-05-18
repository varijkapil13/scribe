import AppKit
import SwiftUI

/// Multiline quick-add field: first line is the task title (with token
/// highlights), remaining lines are notes (with lightweight Markdown highlights).
///
/// - `Return`     → insert newline
/// - `Cmd+Return` → submit (calls `onSubmit`)
/// - Height grows with content (clamped to `maxHeight`).
/// - Observes `.scribeFocusQuickAdd` notification to grab first-responder.
struct MultilineQuickAddField: NSViewRepresentable {

    @Binding var text: String
    @Binding var intrinsicHeight: CGFloat
    var placeholder: String = ""
    var minHeight: CGFloat = 36
    var maxHeight: CGFloat = 200
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // NSTextView must be embedded in an NSScrollView.
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask = [.width]
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = PlaceholderTextView()
        textView.placeholderString = placeholder
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.focusRingType = .none

        // Wrap to scrollView width, not a giant single line.
        textView.textContainer?.containerSize = CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        textView.delegate = context.coordinator
        let coordinator = context.coordinator
        textView.submitHandler = { [weak coordinator] in
            coordinator?.field.onSubmit()
        }
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.field = self
        context.coordinator.startObservingFocusNotification()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.field = self

        let liveText = textView.string
        if liveText != text {
            if text.isEmpty {
                // Programmatic clear (after commit) — force-clear storage.
                textView.textStorage?.beginEditing()
                textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
                textView.textStorage?.endEditing()
                textView.string = ""
                (textView as? PlaceholderTextView)?.needsDisplay = true
            } else if textView.window?.firstResponder !== textView {
                textView.string = text
            }
        }

        coordinator.applyHighlights()
        coordinator.updateHeight()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObservingFocusNotification()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        var field: MultilineQuickAddField
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        private var focusObserver: NSObjectProtocol?

        init(_ field: MultilineQuickAddField) {
            self.field = field
        }

        func startObservingFocusNotification() {
            focusObserver = NotificationCenter.default.addObserver(
                forName: .scribeFocusQuickAdd,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let tv = self?.textView else { return }
                tv.window?.makeFirstResponder(tv)
            }
        }

        func stopObservingFocusNotification() {
            if let obs = focusObserver {
                NotificationCenter.default.removeObserver(obs)
                focusObserver = nil
            }
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            field.text = tv.string
            applyHighlights()
            updateHeight()
            (tv as? PlaceholderTextView)?.needsDisplay = true
        }


        // MARK: Height

        func updateHeight() {
            guard let tv = textView, let sv = scrollView else { return }
            tv.layoutManager?.ensureLayout(for: tv.textContainer!)
            let used = tv.layoutManager?.usedRect(for: tv.textContainer!)
                ?? CGRect(x: 0, y: 0, width: sv.frame.width, height: field.minHeight)
            let inset = tv.textContainerInset.height * 2
            let desired = max(field.minHeight, min(field.maxHeight, used.height + inset + 2))
            if abs(desired - field.intrinsicHeight) > 1 {
                DispatchQueue.main.async { [weak self] in
                    self?.field.intrinsicHeight = desired
                }
            }
        }

        // MARK: Highlight

        func applyHighlights() {
            guard let tv = textView,
                  let storage = tv.textStorage else { return }
            let raw = tv.string
            let attributed = Self.buildAttributedString(
                for: raw,
                font: tv.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            )
            let savedRanges = tv.selectedRanges
            storage.beginEditing()
            storage.setAttributedString(attributed)
            storage.endEditing()
            let length = storage.length
            tv.selectedRanges = savedRanges.map { value in
                let r = value.rangeValue
                let clamped = NSRange(
                    location: min(r.location, length),
                    length: min(r.length, max(0, length - r.location))
                )
                return NSValue(range: clamped)
            }
        }

        private static func buildAttributedString(for text: String,
                                                   font: NSFont) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let lines = text.components(separatedBy: "\n")
            let noteFont = NSFont.systemFont(ofSize: font.pointSize - 0.5)

            for (i, line) in lines.enumerated() {
                if i > 0 { result.append(NSAttributedString(string: "\n")) }

                if i == 0 {
                    // Title line — token highlighting
                    let base: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: NSColor.labelColor
                    ]
                    let chunk = NSMutableAttributedString(string: line, attributes: base)
                    let tokens = QuickAddParser.tokenRanges(in: line)
                    for token in tokens {
                        let nsRange = NSRange(token.range, in: line)
                        let color: NSColor
                        switch token.kind {
                        case .date:     color = .systemOrange
                        case .tag:      color = .systemPurple
                        case .project:  color = .systemGreen
                        case .priority: color = .systemRed
                        }
                        chunk.addAttribute(.foregroundColor, value: color, range: nsRange)
                    }
                    result.append(chunk)
                } else {
                    // Notes lines — Bear-style Markdown highlighting via AST renderer.
                    result.append(MarkdownRenderer.attributed(line, font: noteFont))
                }
            }
            return result
        }

    }
}

// NSTextView subclass that draws a placeholder string and intercepts Cmd+Return.
private final class PlaceholderTextView: NSTextView {

    var placeholderString: String = "" {
        didSet { if string.isEmpty { needsDisplay = true } }
    }

    // Called before AppKit's key-binding system, so Cmd+Return is caught
    // reliably regardless of what selector it maps to.
    var submitHandler: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Return key (keyCode 36), Cmd held → submit
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            submitHandler?()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ]
        let inset = textContainerInset
        let containerOrigin = NSPoint(x: inset.width, y: inset.height)
        (placeholderString as NSString).draw(
            in: NSRect(
                x: containerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
                y: containerOrigin.y,
                width: bounds.width - containerOrigin.x * 2,
                height: bounds.height - containerOrigin.y * 2
            ),
            withAttributes: attrs
        )
    }
}
