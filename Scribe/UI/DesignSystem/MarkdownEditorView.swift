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
        // Switching notes invalidates the undo history — pressing Cmd-Z
        // on note B should never revert to note A's body.
        if tv.noteId != noteId {
            context.coordinator.resetUndoHistory()
        }
        tv.noteId = noteId
        let liveSource: String
        if let storage = tv.textStorage {
            liveSource = FoldRegistry.decompose(storage).source
        } else {
            liveSource = tv.string
        }
        if liveSource != text {
            // Single storage write per update tick. The earlier two-step
            // sequence (`tv.string = text` followed by `applyFormatting`)
            // queued two storage replacements back-to-back, leaving
            // NSLayoutManager's glyph cache in a transient state that the
            // next `drawBackground` → `ensureLayoutForTextContainer` would
            // crash on with `[NSRLEArray objectAtRunIndex:length:]`. Route
            // every external write through `applyFormatting(sourceOverride:)`
            // so storage is updated exactly once.
            if text.isEmpty {
                context.coordinator.applyFormatting(to: tv, sourceOverride: "")
                tv.needsDisplay = true
            } else if tv.window?.firstResponder !== tv {
                context.coordinator.applyFormatting(to: tv, sourceOverride: text)
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

        /// Source-level undo state. The AST renderer destroys AppKit's
        /// position-based undo on every keystroke (full storage swap via
        /// setAttributedString), so we record snapshots of the markdown
        /// source instead and apply them through the same `editSource`
        /// path toolbar actions use. See `MarkdownUndoBuffer` for the
        /// coalescing rules.
        private var undoBuffer = MarkdownUndoBuffer()
        /// True while applying an undo/redo, so the change-recording
        /// path doesn't push the in-progress state back into the stack.
        private var isApplyingUndoRedo: Bool = false

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
                let (newSource, newCursor) = ChecklistToggle.toggleListMarker(source: source, selection: sel)
                return (newSource, NSRange(location: newCursor, length: 0))
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

            // Toolbar / shortcut edits are deliberate, atomic actions —
            // flush any in-flight typing burst so the previous burst and
            // the new edit end up as separate undo steps.
            undoBuffer.endTypingBurst()

            pendingSourceSelectionOverride = newSourceSel
            applyFormatting(to: tv, sourceOverride: newSource)
        }

        // MARK: - Source-level undo / redo

        /// Clears the undo / redo stacks. Called when the editor switches
        /// to a different note so the new note doesn't inherit history
        /// from the previous one.
        func resetUndoHistory() {
            undoBuffer.reset()
        }

        func recordChangeForUndo(source: String, selection: NSRange) {
            // The undo/redo apply path already advanced the buffer's
            // pointer through popUndo / popRedo — the subsequent
            // applyFormatting just paints the storage. Skip the record
            // so we don't double-count.
            if isApplyingUndoRedo { return }
            undoBuffer.record(source: source, selection: selection)
        }

        @discardableResult
        func performSourceUndo() -> Bool {
            guard let snap = undoBuffer.popUndo(), let tv = textView else { return false }
            applyUndoRedoSnapshot(snap, to: tv)
            return true
        }

        @discardableResult
        func performSourceRedo() -> Bool {
            guard let snap = undoBuffer.popRedo(), let tv = textView else { return false }
            applyUndoRedoSnapshot(snap, to: tv)
            return true
        }

        private func applyUndoRedoSnapshot(_ snap: MarkdownUndoBuffer.Snapshot, to tv: NSTextView) {
            isApplyingUndoRedo = true
            defer { isApplyingUndoRedo = false }
            pendingSourceSelectionOverride = snap.selection
            applyFormatting(to: tv, sourceOverride: snap.source)
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
                recordChangeForUndo(source: currentSource, selection: sourceSel)
                return
            }

            // 4. Build base formatted attributed string from source.
            //    The AST-driven `MarkdownRenderer` replaces the legacy regex
            //    `MarkdownFormatter` and handles nesting, autolinks, and the
            //    cursor-proximity marker reveal. We pass the source-coord cursor
            //    so the renderer can keep markers visible only inside the active
            //    block (Bear-style).
            let font = tv.font ?? parent.font
            let cursorForReveal = sourceSel.location
            let formatted = MarkdownRenderer.attributed(
                currentSource,
                font: font,
                cursorOffset: cursorForReveal
            )
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

            recordChangeForUndo(source: currentSource, selection: sourceSel)
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

        // Compute the visible character range so per-character decoration passes
        // (inline-code pills, list bullets) only scan what's actually on screen
        // instead of the entire document on every redraw.
        let visibleRange: NSRange = {
            // dirtyRect is in the text view's coordinate space; shift into the
            // text container's space by subtracting the container origin.
            let containerRect = rect.offsetBy(dx: -origin.x, dy: -origin.y)
            let glyphRange = lm.glyphRange(forBoundingRect: containerRect, in: tc)
            return lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        }()

        drawCodeBlocks(storage: storage, lm: lm, tc: tc, origin: origin)
        drawBlockquotes(storage: storage, lm: lm, tc: tc, origin: origin)
        drawHorizontalRules(storage: storage, lm: lm, tc: tc, origin: origin)
        drawInlineCodePills(storage: storage, lm: lm, tc: tc, origin: origin, in: visibleRange)
        drawListBullets(storage: storage, lm: lm, tc: tc, origin: origin, in: visibleRange)
    }

    private func drawCodeBlocks(storage: NSTextStorage, lm: NSLayoutManager,
                                  tc: NSTextContainer, origin: NSPoint) {
        // Single soft fill — no border. The fill alone provides enough
        // figure/ground contrast; a stroke on top reads as "boxed in" and
        // fights the surrounding prose.
        let bgColor = NSColor(name: nil) { app in
            app.bestMatch(from: [.darkAqua]) == .darkAqua
                ? NSColor(white: 1.0, alpha: 0.06)
                : NSColor(white: 0.0, alpha: 0.04)
        }
        // Language tag — very low contrast so it reads as metadata, not chrome.
        let langColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.65)

        forContiguousRanges(in: storage, key: .codeBlockLine) { charRange in
            let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            let cr = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            // Generous internal padding (10pt top/bottom) — code blocks should
            // feel like a "room" you enter, not a thin sliver behind the text.
            let blockRect = NSRect(
                x: origin.x - 4,
                y: cr.minY + origin.y - 10,
                width: bounds.width - origin.x * 2 + 8,
                height: cr.height + 20
            )
            let path = NSBezierPath(roundedRect: blockRect, xRadius: 8, yRadius: 8)
            bgColor.setFill()
            path.fill()

            // Language label, top-right, low contrast.
            let lang = storage.attribute(.codeBlockLanguage, at: charRange.location,
                                          effectiveRange: nil) as? String ?? ""
            guard !lang.isEmpty else { return }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium),
                .foregroundColor: langColor,
                .kern: 0.4,
            ]
            let label = NSAttributedString(string: lang.uppercased(), attributes: attrs)
            let labelSize = label.size()
            let labelOrigin = NSPoint(
                x: blockRect.maxX - labelSize.width - 10,
                y: blockRect.maxY - labelSize.height - 4
            )
            label.draw(at: labelOrigin)
        }
    }

    private func drawInlineCodePills(storage: NSTextStorage, lm: NSLayoutManager,
                                      tc: NSTextContainer, origin: NSPoint,
                                      in scanRange: NSRange) {
        // Borderless pill. Border on inline code reads as "input field" —
        // a soft fill alone is enough to mark the run as code.
        let pillColor = NSColor(name: nil) { app in
            app.bestMatch(from: [.darkAqua]) == .darkAqua
                ? NSColor(white: 1.0, alpha: 0.10)
                : NSColor(white: 0.0, alpha: 0.05)
        }
        // Scan only the visible character range to avoid walking the entire
        // storage on every redraw — long documents would otherwise enumerate
        // every inline-code span just to redraw the on-screen ones.
        var i = scanRange.location
        let total = min(NSMaxRange(scanRange), storage.length)
        while i < total {
            var effective = NSRange()
            let hasAttr = storage.attribute(.scribeInlineCode, at: i,
                                             effectiveRange: &effective) as? Bool == true
            if hasAttr {
                let glyphRange = lm.glyphRange(forCharacterRange: effective,
                                                 actualCharacterRange: nil)
                lm.enumerateEnclosingRects(
                    forGlyphRange: glyphRange,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: tc
                ) { rect, _ in
                    // Tight padding (2pt horizontal, 1pt vertical) so the pill
                    // hugs the glyphs; tighter than block-code by design.
                    let pill = NSRect(
                        x: rect.minX + origin.x - 2,
                        y: rect.minY + origin.y - 0.5,
                        width: rect.width + 4,
                        height: rect.height + 1
                    )
                    pillColor.setFill()
                    NSBezierPath(roundedRect: pill, xRadius: 3.5, yRadius: 3.5).fill()
                }
                i = NSMaxRange(effective)
            } else {
                i = effective.length > 0 ? NSMaxRange(effective) : i + 1
            }
        }
    }

    private func drawBlockquotes(storage: NSTextStorage, lm: NSLayoutManager,
                                   tc: NSTextContainer, origin: NSPoint) {
        // Bear-style blockquote: just an accent-tinted vertical bar to the
        // left of the indented italic text. No background — the italic + indent
        // + bar combination is the visual; adding a fill makes it feel boxed.
        let barColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.6)

        forContiguousRanges(in: storage, key: .blockquoteLine) { charRange in
            let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            let cr = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            // 3pt bar, sitting flush against the leading edge of the text
            // container, full block height with a tiny inset top/bottom so it
            // doesn't crash into the line above/below.
            let barRect = NSRect(
                x: origin.x + 4,
                y: cr.minY + origin.y + 2,
                width: 3,
                height: cr.height - 4
            )
            barColor.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func drawHorizontalRules(storage: NSTextStorage, lm: NSLayoutManager,
                                       tc: NSTextContainer, origin: NSPoint) {
        // Subtle but clearly visible line — separatorColor was nearly invisible
        // against the body. Use a tinted gray with explicit alpha so it reads
        // as an intentional break.
        let lineColor = NSColor(name: nil) { app in
            app.bestMatch(from: [.darkAqua]) == .darkAqua
                ? NSColor(white: 1.0, alpha: 0.18)
                : NSColor(white: 0.0, alpha: 0.14)
        }
        forContiguousRanges(in: storage, key: .horizontalRule) { charRange in
            let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            let cr = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let midY = cr.midY + origin.y
            // Inset 24pt from each side — full-bleed HRs read as table borders.
            let inset: CGFloat = 24
            let hrRect = NSRect(
                x: origin.x + inset,
                y: midY - 0.5,
                width: bounds.width - origin.x * 2 - inset * 2,
                height: 1
            )
            lineColor.setFill()
            hrRect.fill()
        }
    }

    private func drawListBullets(storage: NSTextStorage, lm: NSLayoutManager,
                                   tc: NSTextContainer, origin: NSPoint,
                                   in scanRange: NSRange) {
        // Unordered list markers (`-`, `*`, `+`) are rendered with their bullet
        // glyph as foreground=clear by the renderer. We overlay a real bullet
        // glyph (• at depth 0, ◦ at depth 1+) at the original char's position,
        // sized to match the surrounding text. Walk only the visible range so
        // documents with hundreds of bullet points don't pay for off-screen
        // glyph redraws on every scroll tick.
        let bulletColor = NSColor.tertiaryLabelColor
        let plain = storage.string as NSString
        var i = scanRange.location
        let total = min(NSMaxRange(scanRange), storage.length)
        while i < total {
            var effective = NSRange()
            let isMarker = storage.attribute(.scribeListMarker, at: i,
                                              effectiveRange: &effective) as? Bool == true
            guard isMarker else {
                i = effective.length > 0 ? NSMaxRange(effective) : i + 1
                continue
            }
            // Find the bullet character — the first non-space, non-digit char.
            let markerText = plain.substring(with: effective)
            guard let bulletCharIndex = markerText.firstIndex(where: { "-*+".contains($0) }) else {
                // Ordered list (digit prefix) — leave the number as-is.
                i = NSMaxRange(effective)
                continue
            }
            let bulletOffset = markerText.distance(from: markerText.startIndex, to: bulletCharIndex)
            let bulletCharRange = NSRange(location: effective.location + bulletOffset, length: 1)
            let depth = storage.attribute(.scribeListDepth, at: effective.location,
                                           effectiveRange: nil) as? Int ?? 0
            let glyph = depth == 0 ? "•" : "◦"

            // Compute the glyph's bounding rect so we can centre the bullet.
            let glyphRange = lm.glyphRange(forCharacterRange: bulletCharRange,
                                             actualCharacterRange: nil)
            guard glyphRange.length > 0 else {
                i = NSMaxRange(effective)
                continue
            }
            let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)

            // Slightly larger and centred against the cap-height of the row.
            let bulletFont = NSFont.systemFont(ofSize: 13, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: bulletFont,
                .foregroundColor: bulletColor,
            ]
            let bullet = NSAttributedString(string: glyph, attributes: attrs)
            let size = bullet.size()
            let drawAt = NSPoint(
                x: rect.midX + origin.x - size.width / 2,
                y: rect.midY + origin.y - size.height / 2 + 0.5
            )
            bullet.draw(at: drawAt)
            i = NSMaxRange(effective)
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
            case "z":  coord?.performSourceUndo();  return true
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
            case "z", "Z":  coord?.performSourceRedo();    return true
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

        // Checklist case is the ONLY path that skips super — we don't want
        // the cursor to land on the attachment glyph itself; the toggle is
        // the entire interaction. Sniff for it first.
        if glyphIdx < lm.numberOfGlyphs {
            let charIdx = lm.characterIndexForGlyph(at: glyphIdx)
            if charIdx < storage.length {
                let attrs = storage.attributes(at: charIdx, effectiveRange: nil)
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
            }
        }

        // Every non-checklist path delegates to super FIRST so AppKit can
        // place the cursor / start selection before we hand off to any
        // navigation callback that may tear down the editor.
        super.mouseDown(with: event)

        if glyphIdx < lm.numberOfGlyphs {
            let charIdx = lm.characterIndexForGlyph(at: glyphIdx)
            if charIdx < storage.length {
                let attrs = storage.attributes(at: charIdx, effectiveRange: nil)
                if let onLinkClick,
                   let anchor = attrs[.wikiAnchor] as? String, !anchor.isEmpty {
                    onLinkClick(anchor)
                }
            }
        }
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
