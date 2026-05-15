import AppKit
import OSLog
import SwiftUI

// MARK: - Custom attribute keys

extension NSAttributedString.Key {
    static let wikiAnchor    = NSAttributedString.Key("scribe.wikiAnchor")
    static let codeBlockLine = NSAttributedString.Key("scribe.codeBlock")    // Bool: inside fenced block
    static let blockquoteLine = NSAttributedString.Key("scribe.blockquote")  // Bool: blockquote line
    static let horizontalRule = NSAttributedString.Key("scribe.hr")          // Bool: HR line
    static let checklistMarker = NSAttributedString.Key("scribe.checklist")  // Bool: checkbox attachment
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
    var noteId: String? = nil   // NEW

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

        tv.noteId = noteId
        tv.registerForDraggedTypes([.fileURL, .png, .tiff])

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
            actions.checklist     = { [weak coord] in coord?.toggleChecklistOnSelection() }
            actions.insertTable   = { [weak coord] in coord?.insertTableTemplate() }
            actions.setHeading    = { [weak coord] level in coord?.setHeading(level) }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? MarkdownNSTextView else { return }
        context.coordinator.parent = self
        tv.noteId = noteId
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

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingFormatting,
                  let tv = notification.object as? MarkdownNSTextView else { return }
            // Selection changed — fold/unfold decision depends on cursor position, so reformat.
            // The work is bounded by note size and image renders are cached.
            applyFormatting(to: tv)
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

        func insertTableTemplate() {
            let template = "\n| Column 1 | Column 2 |\n|----------|----------|\n|          |          |\n"
            editSource { source, sel in
                let nsSource = source as NSString
                let new = nsSource.replacingCharacters(in: sel, with: template)
                let len = (template as NSString).length
                return (new, NSRange(location: sel.location + len, length: 0))
            }
        }

        func toggleChecklistOnSelection() {
            editSource { source, sel in
                let nsSource = source as NSString
                let lineRange = nsSource.lineRange(for: sel)
                let line = nsSource.substring(with: lineRange).trimmingCharacters(in: .newlines)
                // If the line is already a checklist, no-op so we don't insert a second marker.
                if line.range(of: #"^\s*- \[[ xX]\] "#, options: .regularExpression) != nil {
                    return (source, sel)
                }
                let newLine = "- [ ] " + line
                let trailingNewline = lineRange.length > (line as NSString).length ? "\n" : ""
                let newSource = nsSource.replacingCharacters(in: lineRange,
                                                             with: newLine + trailingNewline)
                let shift = ("- [ ] " as NSString).length
                return (newSource, NSRange(location: sel.location + shift, length: 0))
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
        /// translates the display selection to source coords, runs the closure, then hands the
        /// new source straight to `applyFormatting` which is the single point that touches storage.
        ///
        /// We deliberately do NOT do `tv.string = newSource` here: that would queue a second
        /// `setAttributedString`-equivalent in addition to the one inside applyFormatting, and a
        /// double invalidation in quick succession leaves NSLayoutManager's glyph cache in a
        /// transient state that crashes the next `drawBackground`-driven `ensureLayout` with
        /// `[NSRLEArray objectAtRunIndex:length:]`.
        func editSource(_ edit: (String, NSRange) -> (newSource: String, newSelection: NSRange)) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let (currentSource, oldRegistry) = FoldRegistry.decompose(storage)
            let displaySel = tv.selectedRange()
            let s = FoldRegistry.sourceLocation(forDisplay: displaySel.location, registry: oldRegistry)
            let e = FoldRegistry.sourceLocation(forDisplay: displaySel.location + displaySel.length, registry: oldRegistry)
            let sourceSel = NSRange(location: s, length: max(0, e - s))

            let (newSource, newSourceSel) = edit(currentSource, sourceSel)

            pendingSourceSelectionOverride = newSourceSel
            applyFormatting(to: tv, sourceOverride: newSource)
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

        /// Reformat the editor.
        ///
        /// When `sourceOverride` is provided, the source is taken verbatim and the storage is
        /// replaced exactly once (with the freshly-built display attributed string). When it's
        /// nil, the source is reconstructed from the current storage's `.foldSource`-tagged runs.
        /// `editSource` and other source-mutating callers MUST pass `sourceOverride` so we
        /// avoid a `tv.string = …` write followed by a `setAttributedString` write in quick
        /// succession — that double-invalidation can crash `drawBackground`'s `ensureLayout`.
        func applyFormatting(to tv: NSTextView, sourceOverride: String? = nil) {
            guard let storage = tv.textStorage else { return }
            isApplyingFormatting = true
            defer { isApplyingFormatting = false }

            // 1. Determine the source — either provided directly or decomposed from storage.
            //    When provided, oldRegistry is empty (caller must supply pendingSourceSelectionOverride
            //    so we don't try to map a display-coord selection through an empty registry).
            let currentSource: String
            let oldRegistry: [FoldEntry]
            if let s = sourceOverride {
                currentSource = s
                oldRegistry = []
            } else {
                let decomposed = FoldRegistry.decompose(storage)
                currentSource = decomposed.source
                oldRegistry = decomposed.registry
            }

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

            // Checkbox folds — match `- [ ] ` or `- [x] ` at the start of a
            // list item (allowing leading whitespace). The match length is
            // exactly the marker including the trailing space, so e.g.
            // "- [ ] task" → fold the first 6 chars into an attachment, the
            // " task" remains as text.
            let checklistRegex = try? NSRegularExpression(
                pattern: #"^(\s*- \[[ xX]\] )"#,
                options: [.anchorsMatchLines]
            )
            if let regex = checklistRegex {
                let plain = mutable.string as NSString
                let matches = regex.matches(in: mutable.string, options: [],
                                            range: NSRange(location: 0, length: plain.length))
                // Apply in reverse so earlier ranges stay valid.
                for match in matches.reversed() {
                    let markerRange = match.range(at: 1)
                    let marker = plain.substring(with: markerRange)
                    // marker is e.g. "- [ ] " — find the bracket char to read state.
                    let isChecked: Bool = marker.contains("[x]") || marker.contains("[X]")

                    let attachment = NSTextAttachment()
                    attachment.attachmentCell = ChecklistAttachmentCell(isChecked: isChecked)

                    let attStr = NSMutableAttributedString(attachment: attachment)
                    attStr.addAttribute(.foldSource, value: marker, range: NSRange(location: 0, length: attStr.length))
                    attStr.addAttribute(.foldId, value: UUID(), range: NSRange(location: 0, length: attStr.length))
                    attStr.addAttribute(.checklistMarker, value: true, range: NSRange(location: 0, length: attStr.length))

                    mutable.replaceCharacters(in: markerRange, with: attStr)

                    // Strikethrough + dim the rest of the line if checked.
                    if isChecked {
                        let lineRange = plain.lineRange(for: NSRange(location: markerRange.location, length: 0))
                        // Recompute in display coords: the marker just shrank from `markerRange.length` to 1 char.
                        let displayLineStart = markerRange.location
                        let displayLineLen = lineRange.length - markerRange.length + 1  // +1 for the attachment
                        let trailingRange = NSRange(
                            location: displayLineStart + 1, // skip attachment
                            length: max(0, displayLineLen - 1)
                        )
                        let clamped = trailingRange.intersection(NSRange(location: 0, length: mutable.length)) ?? trailingRange
                        if clamped.length > 0 {
                            mutable.addAttribute(.strikethroughStyle,
                                                 value: NSUnderlineStyle.single.rawValue,
                                                 range: clamped)
                            mutable.addAttribute(.foregroundColor,
                                                 value: NSColor.secondaryLabelColor,
                                                 range: clamped)
                        }
                    }
                }
            }

            // Image folds — match `![alt](path)`. Skip matches inside a code
            // block (those should stay as raw markdown).
            let imageRegex = try? NSRegularExpression(
                pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#,
                options: []
            )
            if let regex = imageRegex {
                let plain = mutable.string as NSString
                let matches = regex.matches(in: mutable.string, options: [],
                                            range: NSRange(location: 0, length: plain.length))
                for match in matches.reversed() {
                    let fullRange = match.range
                    // Skip if the match is inside a code block (carries .codeBlockLine).
                    if mutable.attribute(.codeBlockLine, at: fullRange.location, effectiveRange: nil) as? Bool == true {
                        continue
                    }
                    let pathRange = match.range(at: 2)
                    let path = plain.substring(with: pathRange)
                    guard let image = ImageLoader.load(path: path) else { continue }

                    let attachment = NSTextAttachment()
                    attachment.image = image
                    let maxW = min(editorContentWidth, 480)
                    let scale = (image.size.width > 0) ? min(1.0, maxW / image.size.width) : 1.0
                    attachment.bounds = NSRect(
                        x: 0, y: 0,
                        width: image.size.width * scale,
                        height: image.size.height * scale
                    )

                    let attStr = NSMutableAttributedString(attachment: attachment)
                    let originalSource = plain.substring(with: fullRange)
                    attStr.addAttribute(.foldSource, value: originalSource, range: NSRange(location: 0, length: attStr.length))
                    attStr.addAttribute(.foldId, value: UUID(), range: NSRange(location: 0, length: attStr.length))
                    mutable.replaceCharacters(in: fullRange, with: attStr)
                }
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

        /// Place the cursor in the body of the fold's source range and trigger a reformat
        /// so the fence expands to editable source.
        func expandFold(id: UUID) {
            guard let tv = textView,
                  let fold = foldRegistry.first(where: { $0.id == id }) else { return }
            // Read the fold's source from the storage attribute (carries the full fence text).
            let foldSource = tv.textStorage?.attribute(.foldSource, at: fold.displayLocation,
                                                       effectiveRange: nil) as? String
            guard let src = foldSource else { return }
            let nsSrc = src as NSString
            // Body begins after the opening fence line — i.e., after the first newline.
            let firstNL = nsSrc.range(of: "\n")
            let bodyOffset = (firstNL.location != NSNotFound) ? (firstNL.location + 1) : 0

            pendingSourceSelectionOverride = NSRange(
                location: fold.sourceLocation + bodyOffset,
                length: 0
            )
            applyFormatting(to: tv)
        }
    }
}

// MARK: - Checkbox attachment

/// Tappable checkbox glyph. The attachment carries the markdown source for
/// the entire checkbox marker (`- [ ] ` or `- [x] `) on `.foldSource` so
/// FoldRegistry.decompose can reconstruct the original line.
final class ChecklistAttachmentCell: NSTextAttachmentCell {
    let isChecked: Bool
    init(isChecked: Bool) {
        self.isChecked = isChecked
        super.init(imageCell: NSImage(size: NSSize(width: 16, height: 16)))
    }
    required init(coder: NSCoder) { fatalError("not supported") }

    override func cellSize() -> NSSize { NSSize(width: 18, height: 16) }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -3)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let inset: CGFloat = 1
        let box = NSRect(x: cellFrame.minX + inset,
                         y: cellFrame.minY + inset,
                         width: cellFrame.width - 2 - inset * 2,
                         height: cellFrame.height - inset * 2)
        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        if isChecked {
            NSColor.controlAccentColor.setFill()
            path.fill()
            // Checkmark
            let check = NSBezierPath()
            check.move(to: NSPoint(x: box.minX + 3.5, y: box.midY))
            check.line(to: NSPoint(x: box.minX + box.width * 0.42, y: box.minY + 3.5))
            check.line(to: NSPoint(x: box.maxX - 2.5, y: box.maxY - 3.5))
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            NSColor.tertiaryLabelColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

// MARK: - NSTextView subclass

final class MarkdownNSTextView: NSTextView {
    var placeholderString: String = ""
    var onLinkClick: ((String) -> Void)? = nil
    var noteId: String?

    private var foldTrackingArea: NSTrackingArea?
    private(set) var hoveredFoldId: UUID?

    private lazy var editButton: NSButton = {
        let b = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit diagram")
        b.imagePosition = .imageOnly
        b.imageScaling = .scaleProportionallyDown
        b.wantsLayer = true
        b.layer?.cornerRadius = 4
        b.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.85).cgColor
        b.layer?.borderColor = NSColor.separatorColor.cgColor
        b.layer?.borderWidth = 0.5
        b.target = self
        b.action = #selector(editButtonTapped(_:))
        b.isHidden = true
        return b
    }()

    private var lastContentWidth: CGFloat = 0
    private var resizeReformatScheduled = false

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let newInset = NSSize(width: 20, height: 16)
        if newInset != textContainerInset {
            textContainerInset = newInset
        }
        let contentWidth = newSize.width - newInset.width * 2
        if abs(contentWidth - lastContentWidth) > 0.5 {
            lastContentWidth = contentWidth
            scheduleResizeReformat()
        }
    }

    private func scheduleResizeReformat() {
        if resizeReformatScheduled { return }
        resizeReformatScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeReformatScheduled = false
            if let coord = self.delegate as? MarkdownEditorView.Coordinator {
                coord.applyFormatting(to: self)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = foldTrackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: visibleRect,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        foldTrackingArea = ta
        if editButton.superview == nil { addSubview(editButton) }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let viewPoint = convert(event.locationInWindow, from: nil)
        updateHoverOverlay(at: viewPoint)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hideEditButton()
    }

    private func updateHoverOverlay(at viewPoint: NSPoint) {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else {
            hideEditButton(); return
        }
        // glyphIndex(for:in:) wants container coords, which differ from view coords
        // by textContainerOrigin.
        let inset = textContainerOrigin
        let containerPoint = NSPoint(x: viewPoint.x - inset.x, y: viewPoint.y - inset.y)
        let glyphIdx = lm.glyphIndex(for: containerPoint, in: tc)
        guard glyphIdx < lm.numberOfGlyphs else { hideEditButton(); return }
        let charIdx = lm.characterIndexForGlyph(at: glyphIdx)
        guard charIdx < storage.length,
              let id = storage.attribute(.foldId, at: charIdx, effectiveRange: nil) as? UUID else {
            hideEditButton(); return
        }
        // boundingRect(forGlyphRange:in:) returns container coords; convert back to view coords.
        let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: charIdx, length: 1),
                                        actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        let frameInView = rect.offsetBy(dx: inset.x, dy: inset.y)
        // Position button at top-right with 8pt inset.
        let bx = frameInView.maxX - editButton.frame.width - 8
        let by = frameInView.minY + 8
        editButton.frame = NSRect(x: bx, y: by, width: 24, height: 24)
        editButton.isHidden = false
        hoveredFoldId = id
    }

    private func hideEditButton() {
        editButton.isHidden = true
        hoveredFoldId = nil
    }

    @objc private func editButtonTapped(_ sender: Any?) {
        guard let id = hoveredFoldId,
              let coord = delegate as? MarkdownEditorView.Coordinator else { return }
        coord.expandFold(id: id)
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
        // Accent-tinted bar at the leading edge, matches Apple Notes' visual.
        let barColor = NSColor.controlAccentColor.withAlphaComponent(0.55)
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

            let borderRect = NSRect(x: origin.x, y: blockRect.minY, width: 4, height: blockRect.height)
            barColor.setFill()
            NSBezierPath(roundedRect: borderRect, xRadius: 2, yRadius: 2).fill()
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
        // Numbered list: increment the counter.
        if let r = prefix.range(of: #"\d+"#, options: .regularExpression),
           let num = Int(prefix[r]) {
            return prefix.replacingCharacters(in: r, with: "\(num + 1)")
        }
        // Checklist: a checked-off item starts a new line UNCHECKED (matches Apple Notes).
        if let r = prefix.range(of: #"\[[xX]\]"#, options: .regularExpression) {
            return prefix.replacingCharacters(in: r, with: "[ ]")
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
            case "u", "U":  coord?.toggleChecklistOnSelection(); return true
            case "z", "Z":  undoManager?.redo();            return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let storage = textStorage,
              let lm = layoutManager,
              let tc = textContainer else {
            super.mouseDown(with: event)
            return
        }
        let pt = convert(event.locationInWindow, from: nil)
        let glyphIdx = lm.glyphIndex(for: pt, in: tc)
        if glyphIdx < lm.numberOfGlyphs {
            let charIdx = lm.characterIndexForGlyph(at: glyphIdx)
            if charIdx < storage.length {
                let attrs = storage.attributes(at: charIdx, effectiveRange: nil)

                // Checklist click → toggle the markdown source.
                if let isChecklist = attrs[.checklistMarker] as? Bool, isChecklist,
                   let coord = delegate as? MarkdownEditorView.Coordinator {
                    let registry = FoldRegistry.decompose(storage).registry
                    let sourceLoc = FoldRegistry.sourceLocation(forDisplay: charIdx, registry: registry)
                    coord.editSource { source, _ in
                        if let updated = ChecklistToggle.toggle(source: source, atLocation: sourceLoc) {
                            return (updated, NSRange(location: sourceLoc, length: 0))
                        }
                        return (source, NSRange(location: sourceLoc, length: 0))
                    }
                    return
                }

                // Wiki-link click.
                if let onLinkClick,
                   let anchor = attrs[.wikiAnchor] as? String, !anchor.isEmpty {
                    super.mouseDown(with: event)
                    onLinkClick(anchor)
                    return
                }
            }
        }

        super.mouseDown(with: event)
    }

    // MARK: - Image drag-and-drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canAcceptDrop(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canAcceptDrop(sender) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        canAcceptDrop(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let noteId else { return false }
        let pb = sender.draggingPasteboard

        // Resolve a source URL — either a direct file or written-out raw image data.
        var sourceURL: URL?
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first, isImageFile(url: first) {
            sourceURL = first
        } else if let data = pb.data(forType: .png) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
            try? data.write(to: tmp)
            sourceURL = tmp
        } else if let data = pb.data(forType: .tiff),
                  let rep = NSBitmapImageRep(data: data),
                  let png = rep.representation(using: .png, properties: [:]) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
            try? png.write(to: tmp)
            sourceURL = tmp
        }
        guard let sourceURL else { return false }

        // Copy into the note's attachments folder.
        let stored: AttachmentsDirectory.StoredAttachment
        do {
            stored = try AttachmentsDirectory.store(sourceURL: sourceURL, forNoteId: noteId)
        } catch {
            Log.app.error("Image drop failed: \(error.localizedDescription, privacy: .private)")
            return false
        }

        // Insert the markdown at the drop point.
        let dropPoint = convert(sender.draggingLocation, from: nil)
        let charIndex = characterIndexForInsertion(at: dropPoint)
        let markdown = "![](\(stored.relativePath))"
        guard let coord = delegate as? MarkdownEditorView.Coordinator else { return false }
        coord.editSource { source, _ in
            let nsSource = source as NSString
            let safeIndex = min(Int(charIndex), nsSource.length)
            let new = nsSource.replacingCharacters(in: NSRange(location: safeIndex, length: 0), with: markdown)
            return (new, NSRange(location: safeIndex + (markdown as NSString).length, length: 0))
        }
        return true
    }

    private func canAcceptDrop(_ sender: any NSDraggingInfo) -> Bool {
        guard noteId != nil else { return false }
        let pb = sender.draggingPasteboard
        if pb.types?.contains(.png) == true { return true }
        if pb.types?.contains(.tiff) == true { return true }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            return urls.contains(where: isImageFile(url:))
        }
        return false
    }

    private func isImageFile(url: URL) -> Bool {
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "bmp", "heic", "webp"]
        return imageExts.contains(url.pathExtension.lowercased())
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
        var seenFirstH1 = false   // tracks whether the auto-title H1 has been rendered

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
                result.append(formattedLine(line, font: font, seenFirstH1: &seenFirstH1))
            }
        }
        applyTableStyling(to: result, source: text, font: font)
        return result
    }

    private static func applyTableStyling(
        to attr: NSMutableAttributedString,
        source: String,
        font: NSFont
    ) {
        let tables = MarkdownTable.detect(in: source)
        guard !tables.isEmpty else { return }
        let lines = source.components(separatedBy: "\n")
        let monoFont = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
        let monoFontBold = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold)
        let approxCharWidth = monoFont.maximumAdvancement.width
        // Pre-compute line ranges in the source so we can map row index to NSRange in attr.
        var lineRanges: [NSRange] = []
        var cursor = 0
        for line in lines {
            let len = (line as NSString).length
            lineRanges.append(NSRange(location: cursor, length: len))
            cursor += len + 1 // \n
        }
        for table in tables {
            // Build tab stops cumulatively: each column gets width chars + 2-char padding.
            var tabStops: [NSTextTab] = []
            var x: CGFloat = 0
            for w in table.columnWidths {
                x += CGFloat(w + 2) * approxCharWidth
                tabStops.append(NSTextTab(textAlignment: .left, location: x))
            }
            let paraStyle = NSMutableParagraphStyle()
            paraStyle.tabStops = tabStops
            paraStyle.defaultTabInterval = approxCharWidth * 8

            // Apply to header + body rows.
            let applyRows = [table.headerRow] + table.bodyRows
            for row in applyRows {
                guard row < lineRanges.count else { continue }
                let range = lineRanges[row]
                guard range.location + range.length <= attr.length else { continue }
                attr.addAttribute(.font,
                                  value: row == table.headerRow ? monoFontBold : monoFont,
                                  range: range)
                attr.addAttribute(.paragraphStyle, value: paraStyle, range: range)
            }

            // Separator row: visually dim so it's quieter than data rows.
            if table.separatorRow < lineRanges.count {
                let sepRange = lineRanges[table.separatorRow]
                if sepRange.location + sepRange.length <= attr.length {
                    attr.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: sepRange)
                    attr.addAttribute(.font, value: monoFont, range: sepRange)
                }
            }
        }
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

    private static func formattedLine(_ line: String, font: NSFont, seenFirstH1: inout Bool) -> NSAttributedString {
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
            let spacingsBefore: [CGFloat] = [24, 18, 12]

            let size: CGFloat
            let weight: NSFont.Weight
            if level == 1 {
                if !seenFirstH1 {
                    size = 28
                    weight = .semibold
                    seenFirstH1 = true
                } else {
                    size = 22
                    weight = .bold
                }
            } else if level == 2 {
                size = 20
                weight = .semibold
            } else { // 3+
                size = 17
                weight = .semibold
            }

            let headFont = NSFont.systemFont(ofSize: size, weight: weight)
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
