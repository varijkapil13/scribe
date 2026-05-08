import AppKit
import SwiftUI

// MARK: - Custom attribute keys

extension NSAttributedString.Key {
    static let wikiAnchor    = NSAttributedString.Key("scribe.wikiAnchor")
    static let codeBlockLine = NSAttributedString.Key("scribe.codeBlock")    // Bool: inside fenced block
    static let blockquoteLine = NSAttributedString.Key("scribe.blockquote")  // Bool: blockquote line
    static let horizontalRule = NSAttributedString.Key("scribe.hr")          // Bool: HR line
}

/// Bear-style inline markdown editor: a single NSTextView that formats
/// markdown syntax visually as you type. Syntax markers (**, *, #, etc.)
/// are dimmed; content (bold, italic, heading text) is styled.
struct MarkdownEditorView: NSViewRepresentable {

    @Binding var text: String
    var placeholder: String = "Notes…"
    var font: NSFont = .systemFont(ofSize: 15)
    var actions: EditorActions? = nil
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

        if let actions = actions {
            let coord = context.coordinator
            actions.bold          = { [weak coord] in coord?.applyMarker("**") }
            actions.italic        = { [weak coord] in coord?.applyMarker("*") }
            actions.strikethrough = { [weak coord] in coord?.applyMarker("~~") }
            actions.code          = { [weak coord] in coord?.applyMarker("`") }
            actions.link          = { [weak coord] in coord?.applyLinkFormat() }
            actions.blockquote    = { [weak coord] in coord?.applyLinePrefix("> ") }
            actions.unorderedList = { [weak coord] in coord?.applyLinePrefix("- ") }
            actions.orderedList   = { [weak coord] in coord?.applyOrderedList() }
            actions.setHeading    = { [weak coord] level in coord?.setHeading(level) }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? MarkdownNSTextView else { return }
        context.coordinator.parent = self
        let liveSource: String
        if let storage = tv.textStorage {
            liveSource = FoldRegistry.decompose(storage).source
        } else {
            liveSource = tv.string
        }
        if liveSource != text {
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

        /// Most recent registry produced by applyFormatting. Used by hover overlay and Edit button (Task 6).
        var foldRegistry: [FoldEntry] = []

        /// When set, applyFormatting uses this source-coord selection instead of reading
        /// the current display selection. Cleared after each apply.
        var pendingSourceSelectionOverride: NSRange? = nil

        /// Set during applyFormatting to suppress recursive selection-change reformat (Task 5).
        var isApplyingFormatting: Bool = false

        init(_ parent: MarkdownEditorView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if let mtv = tv as? MarkdownNSTextView {
                applyFormatting(to: mtv)
            }
            detectWikiLinkTyping(in: tv)
        }

        func applyMarker(_ marker: String) {
            editSource { source, sel in
                let (newText, newSel) = InlineMarkerEditor.toggle(in: source, selection: sel, marker: marker)
                return (newText, newSel)
            }
        }

        func applyLinkFormat() {
            var afterEditWasNonURL = false
            editSource { source, sel in
                let nsSource = source as NSString
                let selectedText = sel.length > 0 ? nsSource.substring(with: sel) : ""
                let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
                let isURL = URL(string: clipboard)?.scheme?.hasPrefix("http") == true
                afterEditWasNonURL = !isURL

                let replacement = isURL
                    ? "[\(selectedText.isEmpty ? "link" : selectedText)](\(clipboard))"
                    : "[["

                let newSource = nsSource.replacingCharacters(in: sel, with: replacement)
                let newSel: NSRange
                if isURL {
                    let len = (replacement as NSString).length
                    newSel = NSRange(location: sel.location + len, length: 0)
                } else {
                    newSel = NSRange(location: sel.location + 2, length: 0)
                }
                return (newSource, newSel)
            }
            if afterEditWasNonURL, let tv = textView {
                detectWikiLinkTyping(in: tv)
            }
        }

        /// Toggles a line-level prefix (e.g. "- " or "> ") on all selected lines.
        func applyLinePrefix(_ prefix: String) {
            editSource { source, sel in
                let nsSource = source as NSString
                let startLine = nsSource.lineRange(for: NSRange(location: sel.location, length: 0))
                let endLoc = max(sel.location, sel.location + sel.length - 1)
                let endAnchor = min(endLoc, max(0, nsSource.length - 1))
                let endLine = nsSource.lineRange(for: NSRange(location: endAnchor, length: 0))
                let blockRange = NSRange(location: startLine.location,
                                         length: endLine.location + endLine.length - startLine.location)
                let block = nsSource.substring(with: blockRange)
                var lines = block.components(separatedBy: "\n")
                if lines.last == "" { lines.removeLast() }

                let allHave = lines.allSatisfy { $0.hasPrefix(prefix) }
                let newLines = lines.map { line -> String in
                    if allHave { return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line }
                    return line.hasPrefix(prefix) ? line : prefix + line
                }
                let newBlock = newLines.joined(separator: "\n") + "\n"
                let newSource = nsSource.replacingCharacters(in: blockRange, with: newBlock)
                // Place cursor at end of edited block to preserve approximate position.
                let newCursor = blockRange.location + (newBlock as NSString).length
                return (newSource, NSRange(location: min(newCursor, (newSource as NSString).length), length: 0))
            }
        }

        func applyOrderedList() {
            editSource { source, sel in
                let nsSource = source as NSString
                let startLine = nsSource.lineRange(for: NSRange(location: sel.location, length: 0))
                let endLoc = max(sel.location, sel.location + sel.length - 1)
                let endAnchor = min(endLoc, max(0, nsSource.length - 1))
                let endLine = nsSource.lineRange(for: NSRange(location: endAnchor, length: 0))
                let blockRange = NSRange(location: startLine.location,
                                         length: endLine.location + endLine.length - startLine.location)
                let block = nsSource.substring(with: blockRange)
                var lines = block.components(separatedBy: "\n")
                if lines.last == "" { lines.removeLast() }

                let olPattern = #"^\s*\d+\. "#
                let allHave = lines.allSatisfy { $0.range(of: olPattern, options: .regularExpression) != nil }
                let newLines: [String]
                if allHave {
                    newLines = lines.map { line -> String in
                        if let r = line.range(of: olPattern, options: .regularExpression) { return String(line[r.upperBound...]) }
                        return line
                    }
                } else {
                    newLines = lines.enumerated().map { i, line -> String in
                        if line.range(of: olPattern, options: .regularExpression) != nil { return line }
                        return "\(i + 1). \(line)"
                    }
                }
                let newBlock = newLines.joined(separator: "\n") + "\n"
                let newSource = nsSource.replacingCharacters(in: blockRange, with: newBlock)
                let newCursor = blockRange.location + (newBlock as NSString).length
                return (newSource, NSRange(location: min(newCursor, (newSource as NSString).length), length: 0))
            }
        }

        func setHeading(_ level: Int) {
            editSource { source, sel in
                let nsSource = source as NSString
                let cursorLoc = sel.location
                let lineRange = nsSource.lineRange(for: NSRange(location: min(cursorLoc, nsSource.length), length: 0))
                let line = nsSource.substring(with: lineRange)

                let stripped: String
                if let match = line.range(of: #"^#{1,6} "#, options: .regularExpression) {
                    stripped = String(line[match.upperBound...])
                } else {
                    stripped = line
                }
                let newLine = level == 0 ? stripped : String(repeating: "#", count: level) + " " + stripped
                let newSource = nsSource.replacingCharacters(in: lineRange, with: newLine)

                let prefixLen = level == 0 ? 0 : level + 1
                let newCursor = min(lineRange.location + prefixLen, (newSource as NSString).length)
                return (newSource, NSRange(location: newCursor, length: 0))
            }
        }

        /// Edits the markdown source. The closure receives current source + source-coord selection
        /// and returns the new source + new source-coord selection. The helper decomposes storage,
        /// translates the display selection to source coords, runs the closure, resets storage to
        /// the new source (which clears any fold attachments — applyFormatting re-folds), and
        /// restores the new selection through the rebuilt registry.
        func editSource(_ edit: (String, NSRange) -> (newSource: String, newSelection: NSRange)) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let (currentSource, oldRegistry) = FoldRegistry.decompose(storage)
            let displaySel = tv.selectedRange()
            let s = FoldRegistry.sourceLocation(forDisplay: displaySel.location, registry: oldRegistry)
            let e = FoldRegistry.sourceLocation(forDisplay: displaySel.location + displaySel.length, registry: oldRegistry)
            let sourceSel = NSRange(location: s, length: max(0, e - s))

            let (newSource, newSourceSel) = edit(currentSource, sourceSel)

            tv.string = newSource
            pendingSourceSelectionOverride = newSourceSel
            applyFormatting(to: tv)
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
            isApplyingFormatting = true
            defer { isApplyingFormatting = false }

            // 1. Decompose current display into source + old registry.
            let (currentSource, oldRegistry) = FoldRegistry.decompose(storage)

            // 2. Determine source-coord selection (start + end) round-trip target.
            let sourceSel: NSRange
            if let override = pendingSourceSelectionOverride {
                sourceSel = override
                pendingSourceSelectionOverride = nil
            } else {
                let displaySel = tv.selectedRange()
                let s = FoldRegistry.sourceLocation(forDisplay: displaySel.location, registry: oldRegistry)
                let e = FoldRegistry.sourceLocation(forDisplay: displaySel.location + displaySel.length, registry: oldRegistry)
                sourceSel = NSRange(location: s, length: max(0, e - s))
            }

            // 3. Push reconstructed source up to the binding.
            if parent.text != currentSource {
                parent.text = currentSource
            }

            guard !currentSource.isEmpty else {
                tv.undoManager?.disableUndoRegistration()
                storage.beginEditing()
                storage.setAttributedString(NSAttributedString(string: ""))
                storage.endEditing()
                tv.undoManager?.enableUndoRegistration()
                foldRegistry = []
                return
            }

            // 4. Build base formatted attributed string from source.
            let font = tv.font ?? parent.font
            let formatted = MarkdownFormatter.attributed(currentSource, font: font)
            let mutable = NSMutableAttributedString(attributedString: formatted)
            parent.extraHighlighter?(mutable)

            // 5. Decide per-fence whether to fold; substitute attachments in reverse order
            //    so earlier nsRanges remain valid as we splice.
            let blocks = DiagramRenderer.extractBlocks(from: currentSource)
            let editorContentWidth = max(120, tv.bounds.width - tv.textContainerInset.width * 2)

            struct Decision { let block: DiagramBlock; let fold: Bool; let image: NSImage?; let id: UUID }
            var decisions: [Decision] = []
            for block in blocks {
                let blockStart = block.nsRange.location
                let blockEnd = blockStart + block.nsRange.length
                let inside: Bool
                if sourceSel.length == 0 {
                    inside = (sourceSel.location >= blockStart && sourceSel.location <= blockEnd)
                } else {
                    let selEnd = sourceSel.location + sourceSel.length
                    inside = sourceSel.location <= blockEnd && selEnd >= blockStart
                }
                if inside {
                    decisions.append(Decision(block: block, fold: false, image: nil, id: UUID()))
                    continue
                }
                let coord = self
                let img = DiagramRenderer.shared.image(type: block.type, source: block.source) { [weak coord] in
                    guard let coord, let tv = coord.textView else { return }
                    coord.applyFormatting(to: tv)
                }
                if let img {
                    decisions.append(Decision(block: block, fold: true, image: img, id: UUID()))
                } else {
                    // Render not ready (or failed) — leave source visible.
                    decisions.append(Decision(block: block, fold: false, image: nil, id: UUID()))
                }
            }

            for decision in decisions.reversed() where decision.fold {
                guard let img = decision.image else { continue }
                let attachment = NSTextAttachment()
                attachment.image = img
                let natural = img.size
                let scale = (natural.width > 0) ? min(1.0, editorContentWidth / natural.width) : 1.0
                attachment.bounds = NSRect(x: 0, y: 0,
                                           width: natural.width * scale,
                                           height: natural.height * scale)

                let attString = NSMutableAttributedString(attachment: attachment)
                let r = NSRange(location: 0, length: attString.length)
                attString.addAttribute(.foldSource, value: decision.block.fullText, range: r)
                attString.addAttribute(.foldId, value: decision.id, range: r)

                mutable.replaceCharacters(in: decision.block.nsRange, with: attString)
            }

            let (_, newRegistry) = FoldRegistry.decompose(mutable)
            foldRegistry = newRegistry

            // 6. Apply to storage; restore selection mapped through new registry.
            tv.undoManager?.disableUndoRegistration()
            storage.beginEditing()
            storage.setAttributedString(mutable)
            storage.endEditing()
            tv.undoManager?.enableUndoRegistration()
            let len = storage.length
            let dispStart = FoldRegistry.displayLocation(forSource: sourceSel.location, registry: newRegistry)
            let dispEnd = FoldRegistry.displayLocation(forSource: sourceSel.location + sourceSel.length, registry: newRegistry)
            let cs = max(0, min(dispStart, len))
            let ce = max(cs, min(dispEnd, len))
            tv.setSelectedRange(NSRange(location: cs, length: ce - cs))
            (tv as? MarkdownNSTextView)?.needsDisplay = true
        }
    }
}

// MARK: - NSTextView subclass

final class MarkdownNSTextView: NSTextView {
    var placeholderString: String = ""
    var onLinkClick: ((String) -> Void)? = nil

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let newInset = NSSize(width: 20, height: 16)
        guard newInset != textContainerInset else { return }
        textContainerInset = newInset
    }

    // MARK: - Custom background drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let storage = textStorage, let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        let origin = textContainerOrigin

        drawCodeBlocks(storage: storage, lm: lm, tc: tc, origin: origin)
        drawBlockquotes(storage: storage, lm: lm, tc: tc, origin: origin)
        drawHorizontalRules(storage: storage, lm: lm, tc: tc, origin: origin)
    }

    private func drawCodeBlocks(storage: NSTextStorage, lm: NSLayoutManager,
                                  tc: NSTextContainer, origin: NSPoint) {
        let bgColor = NSColor(name: nil) { app in
            app.bestMatch(from: [.darkAqua]) == .darkAqua
                ? NSColor(white: 1.0, alpha: 0.09)
                : NSColor(white: 0.0, alpha: 0.06)
        }

        forContiguousRanges(in: storage, key: .codeBlockLine) { charRange in
            let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            var cr = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let blockRect = NSRect(
                x: 4,
                y: cr.minY + origin.y - 6,
                width: bounds.width - 8,
                height: cr.height + 12
            )
            let path = NSBezierPath(roundedRect: blockRect, xRadius: 6, yRadius: 6)
            bgColor.setFill()
            path.fill()
            _ = cr  // suppress unused warning
        }
    }

    private func drawBlockquotes(storage: NSTextStorage, lm: NSLayoutManager,
                                   tc: NSTextContainer, origin: NSPoint) {
        let borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.45)
        let bgColor = NSColor(name: nil) { app in
            app.bestMatch(from: [.darkAqua]) == .darkAqua
                ? NSColor(white: 1.0, alpha: 0.04)
                : NSColor(white: 0.0, alpha: 0.03)
        }

        forContiguousRanges(in: storage, key: .blockquoteLine) { charRange in
            let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            let cr = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let blockRect = NSRect(
                x: origin.x,
                y: cr.minY + origin.y - 3,
                width: bounds.width - origin.x * 2,
                height: cr.height + 6
            )
            bgColor.setFill()
            NSBezierPath(roundedRect: blockRect, xRadius: 4, yRadius: 4).fill()

            let borderRect = NSRect(x: origin.x, y: blockRect.minY, width: 3, height: blockRect.height)
            borderColor.setFill()
            NSBezierPath(roundedRect: borderRect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func drawHorizontalRules(storage: NSTextStorage, lm: NSLayoutManager,
                                       tc: NSTextContainer, origin: NSPoint) {
        let lineColor = NSColor.separatorColor
        forContiguousRanges(in: storage, key: .horizontalRule) { charRange in
            let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            let cr = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let midY = cr.midY + origin.y
            let hrRect = NSRect(x: origin.x, y: midY - 0.5,
                                width: bounds.width - origin.x * 2, height: 1)
            lineColor.setFill()
            hrRect.fill()
        }
    }

    /// Iterates contiguous character ranges marked with `key` and calls `body` for each block.
    private func forContiguousRanges(in storage: NSTextStorage,
                                      key: NSAttributedString.Key,
                                      body: (NSRange) -> Void) {
        var i = 0
        let total = storage.length
        while i < total {
            var effectiveRange = NSRange()
            let hasAttr = storage.attribute(key, at: i, effectiveRange: &effectiveRange) != nil
            if hasAttr {
                var blockEnd = NSMaxRange(effectiveRange)
                while blockEnd < total {
                    var nextRange = NSRange()
                    if storage.attribute(key, at: blockEnd, effectiveRange: &nextRange) != nil {
                        blockEnd = NSMaxRange(nextRange)
                    } else { break }
                }
                body(NSRange(location: effectiveRange.location, length: blockEnd - effectiveRange.location))
                i = blockEnd
            } else {
                i = NSMaxRange(effectiveRange)
            }
        }
    }

    // MARK: - Smart Enter, Tab, Backtab

    override func insertNewline(_ sender: Any?) {
        guard let coord = delegate as? MarkdownEditorView.Coordinator else {
            super.insertNewline(sender)
            return
        }
        coord.editSource { source, sel in
            let nsSource = source as NSString
            let lineRange = nsSource.lineRange(for: NSRange(location: sel.location, length: 0))
            let line = nsSource.substring(with: lineRange).trimmingCharacters(in: .newlines)

            // Blockquote continuation
            if line.hasPrefix("> ") {
                let content = String(line.dropFirst(2))
                if content.isEmpty {
                    let newSource = nsSource.replacingCharacters(in: lineRange, with: "\n")
                    return (newSource, NSRange(location: lineRange.location + 1, length: 0))
                }
                let insertion = "\n> "
                let cursor = sel.location
                let newSource = nsSource.replacingCharacters(in: NSRange(location: cursor, length: 0), with: insertion)
                return (newSource, NSRange(location: cursor + (insertion as NSString).length, length: 0))
            }

            // List continuation
            if let prefix = Self.listPrefix(from: line) {
                if line == prefix {
                    let newSource = nsSource.replacingCharacters(in: lineRange, with: "\n")
                    return (newSource, NSRange(location: lineRange.location + 1, length: 0))
                }
                let next = Self.nextListPrefix(from: prefix)
                let insertion = "\n" + next
                let cursor = sel.location
                let newSource = nsSource.replacingCharacters(in: NSRange(location: cursor, length: 0), with: insertion)
                return (newSource, NSRange(location: cursor + (insertion as NSString).length, length: 0))
            }

            // Plain newline
            let cursor = sel.location
            let newSource = nsSource.replacingCharacters(in: NSRange(location: cursor, length: 0), with: "\n")
            return (newSource, NSRange(location: cursor + 1, length: 0))
        }
    }

    override func insertTab(_ sender: Any?) {
        guard let coord = delegate as? MarkdownEditorView.Coordinator else {
            super.insertTab(sender); return
        }
        coord.editSource { source, sel in
            let nsSource = source as NSString
            let lineRange = nsSource.lineRange(for: NSRange(location: sel.location, length: 0))
            let line = nsSource.substring(with: lineRange).trimmingCharacters(in: .newlines)
            if Self.listPrefix(from: line) != nil {
                let newSource = nsSource.replacingCharacters(in: NSRange(location: lineRange.location, length: 0), with: "  ")
                return (newSource, NSRange(location: sel.location + 2, length: sel.length))
            }
            let newSource = nsSource.replacingCharacters(in: sel, with: "  ")
            return (newSource, NSRange(location: sel.location + 2, length: 0))
        }
    }

    override func insertBacktab(_ sender: Any?) {
        guard let coord = delegate as? MarkdownEditorView.Coordinator else {
            super.insertBacktab(sender); return
        }
        var didStrip = false
        coord.editSource { source, sel in
            let nsSource = source as NSString
            let lineRange = nsSource.lineRange(for: NSRange(location: sel.location, length: 0))
            let line = nsSource.substring(with: lineRange).trimmingCharacters(in: .newlines)
            if Self.listPrefix(from: line) != nil && (line.hasPrefix("  ") || line.hasPrefix("\t")) {
                let strip = line.hasPrefix("\t") ? 1 : 2
                let stripRange = NSRange(location: lineRange.location, length: strip)
                let newSource = nsSource.replacingCharacters(in: stripRange, with: "")
                didStrip = true
                let newCursor = max(lineRange.location, sel.location - strip)
                return (newSource, NSRange(location: newCursor, length: max(0, sel.length)))
            }
            return (source, sel) // no change — fall through to super
        }
        if !didStrip {
            super.insertBacktab(sender)
        }
    }

    static func listPrefix(from line: String) -> String? {
        if let r = line.range(of: #"^(\s*[-*+] (\[[ xX]\] )?)"#, options: .regularExpression) {
            return String(line[r])
        }
        if let r = line.range(of: #"^\s*\d+\. "#, options: .regularExpression) {
            return String(line[r])
        }
        return nil
    }

    static func nextListPrefix(from prefix: String) -> String {
        if let r = prefix.range(of: #"\d+"#, options: .regularExpression),
           let num = Int(prefix[r]) {
            return prefix.replacingCharacters(in: r, with: "\(num + 1)")
        }
        if prefix.contains("[x]") || prefix.contains("[X]") {
            return prefix
                .replacingOccurrences(of: "[x]", with: "[ ]")
                .replacingOccurrences(of: "[X]", with: "[ ]")
        }
        return prefix
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers ?? ""
        let coord = delegate as? MarkdownEditorView.Coordinator

        if mods == .command {
            switch key {
            case "b":  coord?.applyMarker("**");    return true
            case "i":  coord?.applyMarker("*");     return true
            case "`":  coord?.applyMarker("`");     return true
            case "k":  coord?.applyLinkFormat();    return true
            case "z":  undoManager?.undo();         return true
            default: break
            }
        }
        if mods == [.command, .shift] {
            switch key {
            case "x", "X": coord?.applyMarker("~~");       return true
            case ".":       coord?.applyLinePrefix("> ");   return true
            case "8":       coord?.applyLinePrefix("- ");   return true
            case "7":       coord?.applyOrderedList();      return true
            case "z", "Z":  undoManager?.redo();            return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
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
        let monoFont = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
        let dim = NSColor.tertiaryLabelColor
        var inFence = false

        for (i, line) in lines.enumerated() {
            if i > 0 {
                // Mark the inter-line newline as codeBlock when inside a fence,
                // so drawBackground finds one contiguous range per block.
                let nl = NSMutableAttributedString(string: "\n")
                if inFence {
                    nl.addAttribute(.codeBlockLine, value: true,
                                    range: NSRange(location: 0, length: 1))
                    nl.addAttributes(codeLineAttrs(font: monoFont),
                                     range: NSRange(location: 0, length: 1))
                }
                result.append(nl)
            }

            if line.hasPrefix("```") {
                inFence.toggle()
                let display = line.isEmpty ? " " : line
                let fenceAttr = NSMutableAttributedString(string: display,
                                                           attributes: codeLineAttrs(font: monoFont))
                let full = NSRange(location: 0, length: fenceAttr.length)
                fenceAttr.addAttribute(.foregroundColor, value: dim, range: full)
                fenceAttr.addAttribute(.codeBlockLine, value: true, range: full)
                result.append(fenceAttr)
            } else if inFence {
                let display = line.isEmpty ? " " : line
                let codeAttr = NSMutableAttributedString(string: display,
                                                          attributes: codeLineAttrs(font: monoFont))
                codeAttr.addAttribute(.codeBlockLine, value: true,
                                      range: NSRange(location: 0, length: codeAttr.length))
                result.append(codeAttr)
            } else {
                result.append(formattedLine(line, font: font))
            }
        }
        return result
    }

    private static func codeLineAttrs(font: NSFont) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.4
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        style.headIndent = 14
        style.firstLineHeadIndent = 14
        return [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
    }

    // MARK: Per-line

    private static func formattedLine(_ line: String, font: NSFont) -> NSAttributedString {
        let dim  = NSColor.tertiaryLabelColor
        let mono = NSFont.monospacedSystemFont(ofSize: font.pointSize - 0.5, weight: .regular)

        // Horizontal rule — invisible text, drawn by drawBackground
        if line.trimmingCharacters(in: .whitespaces).matches(#"^[-*_]{3,}$"#) {
            let hrStyle = NSMutableParagraphStyle()
            hrStyle.paragraphSpacingBefore = 8
            hrStyle.paragraphSpacing = 8
            let result = NSMutableAttributedString(string: line, attributes: [
                .font: font, .foregroundColor: NSColor.clear, .paragraphStyle: hrStyle
            ])
            result.addAttribute(.horizontalRule, value: true,
                                range: NSRange(location: 0, length: line.utf16.count))
            return result
        }

        // Headings
        if let (hashes, rest) = parseHeading(line) {
            let level = min(hashes, 3)
            let sizes: [CGFloat] = [28, 22, 18]
            let spacingsBefore: [CGFloat] = [24, 18, 12]
            let size = sizes[level - 1]
            let headFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.bold), size: size)
                        ?? NSFont.boldSystemFont(ofSize: size)
            let headMono = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)

            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.2
            style.paragraphSpacingBefore = spacingsBefore[level - 1]
            style.paragraphSpacing = 6

            let result = NSMutableAttributedString(string: line, attributes: [
                .font: headFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style
            ])
            let prefixLen = hashes + 1
            let prefixRange = NSRange(location: 0, length: min(prefixLen, line.utf16.count))
            let textRange = NSRange(location: min(prefixLen, line.utf16.count),
                                    length: max(0, line.utf16.count - prefixLen))
            // Dim the # markers heavily
            result.addAttribute(.foregroundColor, value: NSColor.quaternaryLabelColor, range: prefixRange)
            result.addAttribute(.font, value: NSFont.systemFont(ofSize: font.pointSize - 1), range: prefixRange)
            if textRange.length > 0 {
                applyInline(to: result, offset: prefixLen, text: rest,
                            baseFont: headFont, dim: dim, mono: headMono)
            }
            return result
        }

        // Blockquote
        if line.hasPrefix("> ") {
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.5
            style.paragraphSpacing = 1
            style.headIndent = 28
            style.firstLineHeadIndent = 28

            let result = NSMutableAttributedString(string: line, attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style
            ])
            let prefixLen = min(2, line.utf16.count)
            result.addAttribute(.foregroundColor, value: NSColor.quaternaryLabelColor,
                                range: NSRange(location: 0, length: prefixLen))
            result.addAttribute(.blockquoteLine, value: true,
                                range: NSRange(location: 0, length: line.utf16.count))
            if line.utf16.count > 2 {
                let content = String(line.dropFirst(2))
                applyInline(to: result, offset: 2, text: content,
                            baseFont: font, dim: dim, mono: mono)
            }
            return result
        }

        // Lists — hanging indent so text wraps under content, not under bullet
        let result = NSMutableAttributedString(string: line, attributes: base(font))
        if let prefixLen = listPrefixLength(line) {
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            let indentBase: CGFloat = CGFloat(leadingSpaces / 2) * 20
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.5
            style.paragraphSpacing = 1
            style.firstLineHeadIndent = indentBase
            style.headIndent = indentBase + 18
            result.addAttribute(.paragraphStyle, value: style,
                                range: NSRange(location: 0, length: line.utf16.count))
            result.addAttribute(.foregroundColor, value: dim,
                                range: NSRange(location: 0, length: prefixLen))
        }

        applyInline(to: result, offset: 0, text: line, baseFont: font, dim: dim, mono: mono)
        return result
    }

    // MARK: Inline formatting

    private static func applyInline(
        to str: NSMutableAttributedString,
        offset: Int, text: String, baseFont: NSFont, dim: NSColor, mono: NSFont
    ) {
        let boldItalic = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits([.bold, .italic]),
                                size: baseFont.pointSize) ?? baseFont
        let bold   = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits(.bold),   size: baseFont.pointSize) ?? baseFont
        let italic = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic), size: baseFont.pointSize) ?? baseFont

        apply(pattern: #"\*{3}([^*\n]+?)\*{3}"#, in: text, offset: offset, to: str) { m, c in
            m.forEach { str.addAttribute(.foregroundColor, value: dim, range: $0) }
            str.addAttribute(.font, value: boldItalic, range: c)
        }
        apply(pattern: #"\*{2}([^*\n]+?)\*{2}"#, in: text, offset: offset, to: str) { m, c in
            m.forEach { str.addAttribute(.foregroundColor, value: dim, range: $0) }
            str.addAttribute(.font, value: bold, range: c)
        }
        apply(pattern: #"_{2}([^_\n]+?)_{2}"#, in: text, offset: offset, to: str) { m, c in
            m.forEach { str.addAttribute(.foregroundColor, value: dim, range: $0) }
            str.addAttribute(.font, value: bold, range: c)
        }
        apply(pattern: #"(?<!\*)\*([^*\n]+?)\*(?!\*)"#, in: text, offset: offset, to: str) { m, c in
            m.forEach { str.addAttribute(.foregroundColor, value: dim, range: $0) }
            str.addAttribute(.font, value: italic, range: c)
        }
        apply(pattern: #"(?<!_)_([^_\n]+?)_(?!_)"#, in: text, offset: offset, to: str) { m, c in
            m.forEach { str.addAttribute(.foregroundColor, value: dim, range: $0) }
            str.addAttribute(.font, value: italic, range: c)
        }
        // Inline code — subtle box, secondary color (no orange)
        let inlineCodeBg = NSColor(name: nil) { app in
            app.bestMatch(from: [.darkAqua]) == .darkAqua
                ? NSColor(white: 1.0, alpha: 0.10)
                : NSColor(white: 0.0, alpha: 0.07)
        }
        apply(pattern: #"`([^`\n]+?)`"#, in: text, offset: offset, to: str) { m, c in
            let fullRange = NSRange(location: m.first?.location ?? c.location,
                                    length: (m.last.map { $0.location + $0.length } ?? (c.location + c.length))
                                           - (m.first?.location ?? c.location))
            str.addAttribute(.font, value: mono, range: c)
            str.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: c)
            str.addAttribute(.backgroundColor, value: inlineCodeBg, range: fullRange)
            m.forEach { str.addAttribute(.foregroundColor, value: dim, range: $0) }
        }
        apply(pattern: #"~~([^~\n]+?)~~"#, in: text, offset: offset, to: str) { m, c in
            m.forEach { str.addAttribute(.foregroundColor, value: dim, range: $0) }
            str.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: c)
        }
    }

    // MARK: Pattern helper

    private static func apply(
        pattern: String, in text: String, offset: Int,
        to str: NSMutableAttributedString,
        _ body: ([NSRange], NSRange) -> Void
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
            body(markers, captureOff)
        }
    }

    // MARK: Helpers

    private static func base(_ font: NSFont) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.5
        style.paragraphSpacing = 2
        return [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
    }

    private static func parseHeading(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        var i = line.startIndex
        var count = 0
        while i < line.endIndex, line[i] == "#" { count += 1; i = line.index(after: i) }
        guard count <= 6, i < line.endIndex, line[i] == " " else { return nil }
        return (count, String(line[line.index(after: i)...]))
    }

    private static func listPrefixLength(_ line: String) -> Int? {
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

// MARK: - Inline marker toggle

enum InlineMarkerEditor {

    static func toggle(
        in text: String, selection: NSRange, marker: String
    ) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let mlen = marker.utf16.count

        if selection.length == 0 {
            let inserted = marker + marker
            let newText = ns.replacingCharacters(in: selection, with: inserted)
            return (newText, NSRange(location: selection.location + mlen, length: 0))
        }

        let selected = ns.substring(with: selection)
        if selected.hasPrefix(marker) && selected.hasSuffix(marker) && selected.utf16.count > mlen * 2 {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            return (ns.replacingCharacters(in: selection, with: inner),
                    NSRange(location: selection.location, length: inner.utf16.count))
        }

        let beforeLoc = selection.location - mlen
        let afterLoc = selection.location + selection.length
        if beforeLoc >= 0 && afterLoc + mlen <= ns.length {
            let before = ns.substring(with: NSRange(location: beforeLoc, length: mlen))
            let after  = ns.substring(with: NSRange(location: afterLoc,  length: mlen))
            if before == marker && after == marker {
                let expandedRange = NSRange(location: beforeLoc, length: selection.length + mlen * 2)
                return (ns.replacingCharacters(in: expandedRange, with: selected),
                        NSRange(location: beforeLoc, length: selected.utf16.count))
            }
        }

        let wrapped = marker + selected + marker
        return (ns.replacingCharacters(in: selection, with: wrapped),
                NSRange(location: selection.location, length: wrapped.utf16.count))
    }
}
