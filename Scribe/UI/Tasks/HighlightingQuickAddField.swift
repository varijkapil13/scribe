import AppKit
import SwiftUI

/// Quick-add text field that highlights recognised tokens as the user types:
///   - date phrases / abbreviations → orange
///   - #tags                        → system purple
///   - +projects                    → system green
///   - !priority                    → system red
///
/// Observes `Notification.Name.scribeFocusQuickAdd` to gain first-responder
/// status so the rest of `TaskListView` can trigger focus without needing a
/// `@FocusState` binding to an `NSViewRepresentable`.
struct HighlightingQuickAddField: NSViewRepresentable {

    @Binding var text: String
    /// Defaults to a syntax-hinting prompt so the quick-add power tokens
    /// (#tag +project !priority + natural dates) are discoverable without
    /// opening the help popover.
    var placeholder: String = "Add a task — #tag +project !priority, “tmr”…"
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NonScrollingTextField()
        tf.isBordered = false
        tf.drawsBackground = false
        tf.isEditable = true
        tf.isSelectable = true
        tf.font = .systemFont(ofSize: NSFont.systemFontSize)
        tf.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.placeholderTextColor,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
            ]
        )
        tf.focusRingType = .none
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.delegate = context.coordinator
        // No action/target — Enter is handled exclusively via doCommandBy:
        // so we don't double-fire onSubmit.

        context.coordinator.textField = tf
        context.coordinator.startObservingFocusNotification()
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        let liveText = tf.currentEditor()?.string ?? tf.stringValue
        if liveText != text {
            if text.isEmpty {
                // Commit cleared the model — force-clear the live field editor buffer
                // even if the field still has focus (e.g. right after Enter).
                if let editor = tf.currentEditor() as? NSTextView {
                    let empty = NSAttributedString(string: "")
                    editor.textStorage?.beginEditing()
                    editor.textStorage?.setAttributedString(empty)
                    editor.textStorage?.endEditing()
                }
                tf.stringValue = ""
            } else if tf.currentEditor() == nil {
                // Not editing: sync programmatic title changes.
                tf.stringValue = text
            }
            // else: user is mid-type, don't clobber their input.
        }
        let current = tf.currentEditor()?.string ?? tf.stringValue
        context.coordinator.applyHighlights(text: current)
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.stopObservingFocusNotification()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {

        var parent: HighlightingQuickAddField
        weak var textField: NSTextField?

        init(_ parent: HighlightingQuickAddField) {
            self.parent = parent
        }

        func startObservingFocusNotification() {
            // Selector-based (not the closure API) so we don't capture a
            // non-Sendable Coordinator in NotificationCenter's @Sendable block.
            // `.scribeFocusQuickAdd` is posted from the UI on the main thread.
            NotificationCenter.default.addObserver(
                self, selector: #selector(focusRequested),
                name: .scribeFocusQuickAdd, object: nil)
        }

        @objc private func focusRequested() {
            guard let tf = textField else { return }
            tf.window?.makeFirstResponder(tf)
        }

        func stopObservingFocusNotification() {
            NotificationCenter.default.removeObserver(self, name: .scribeFocusQuickAdd, object: nil)
        }

        // Sync text binding on every keystroke.
        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            let current = tf.currentEditor()?.string ?? tf.stringValue
            parent.text = current
            applyHighlights(text: current)
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }

        // MARK: Highlight application

        func applyHighlights(text: String) {
            guard let tf = textField else { return }
            let attributed = Self.buildAttributedString(
                for: text,
                font: tf.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            )
            if let editor = tf.currentEditor() as? NSTextView,
               let storage = editor.textStorage {
                let savedRanges = editor.selectedRanges
                storage.beginEditing()
                storage.setAttributedString(attributed)
                storage.endEditing()
                // Restore cursor – clamp to valid range in case text shrank.
                let length = storage.length
                editor.selectedRanges = savedRanges.map { value in
                    let r = value.rangeValue
                    let clamped = NSRange(location: min(r.location, length),
                                         length: min(r.length, max(0, length - r.location)))
                    return NSValue(range: clamped)
                }
            } else {
                tf.attributedStringValue = attributed
            }
        }

        private static func buildAttributedString(for text: String,
                                                   font: NSFont) -> NSAttributedString {
            let base: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
            let result = NSMutableAttributedString(string: text, attributes: base)

            let tokens = QuickAddParser.tokenRanges(in: text)
            for token in tokens {
                let nsRange = NSRange(token.range, in: text)
                let color: NSColor
                switch token.kind {
                case .date:     color = .systemOrange
                case .tag:      color = .systemPurple
                case .project:  color = .systemGreen
                case .priority: color = .systemRed
                }
                result.addAttribute(.foregroundColor, value: color, range: nsRange)
            }
            return result
        }
    }
}

// NSTextField subclass that prevents the built-in horizontal scrolling from
// resetting the attributed string during layout, which would erase highlights.
private final class NonScrollingTextField: NSTextField {
    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
    }
}
