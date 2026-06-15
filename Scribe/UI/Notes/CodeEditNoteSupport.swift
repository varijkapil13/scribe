//
//  CodeEditNoteSupport.swift
//  Scribe
//
//  Theme + coordinator for the CodeEditSourceEditor-backed note editor
//  (``CodeEditNoteTextView``). Split out so the SwiftUI view stays small.
//
//  ── SwiftPM build boundary ───────────────────────────────────────────────
//  Imports CodeEditSourceEditor / CodeEditTextView and is therefore excluded
//  from the SwiftPM `Scribe` target (see Package.swift, alongside
//  CodeEditNoteTextView.swift). xcodebuild compiles it normally.
//

import SwiftUI
import AppKit
import CodeEditSourceEditor
import CodeEditTextView

// MARK: - Theme

extension EditorTheme {

    /// A Scribe-flavoured Markdown theme for the given color scheme. Colors map
    /// onto AppKit semantic colors where possible (so the editor tracks the
    /// system palette) with syntax tints drawn from ``DesignTokens/Palette``.
    static func scribe(for scheme: ColorScheme) -> EditorTheme {
        let isDark = scheme == .dark
        // CodeEditSourceEditor's minimap themer calls `brightnessComponent` on
        // theme colors, which throws an NSException for catalog/semantic
        // NSColors (e.g. `.textColor`, dynamic system colors) that aren't in an
        // RGB color space — crashing the app when the editor applies its theme.
        // Resolve every color into sRGB up front so brightness math is always
        // valid. (The theme is re-derived per color scheme, so flattening the
        // dynamic colors here is fine.)
        func rgb(_ color: NSColor) -> NSColor {
            color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) ?? color
        }
        // Code / fences read as monospace strings; emphasis + headings lean on
        // the accent family. We keep body text on the semantic label color so
        // contrast tracks the system.
        let accent = rgb(NSColor(DesignTokens.Palette.speakerYou))
        let codeTint = rgb(NSColor(DesignTokens.Palette.priorityLow))
        let numberTint = rgb(NSColor(DesignTokens.Palette.priorityMedium))
        let typeTint = rgb(NSColor(DesignTokens.Palette.speakerRemote))

        return EditorTheme(
            text: Attribute(color: rgb(.textColor)),
            insertionPoint: rgb(.textColor),
            invisibles: Attribute(color: rgb(.tertiaryLabelColor)),
            // Transparent background is requested via useThemeBackground=false;
            // this value is only used if a caller flips that on.
            background: rgb(isDark ? NSColor(white: 0.11, alpha: 1) : .textBackgroundColor),
            lineHighlight: rgb(.unemphasizedSelectedContentBackgroundColor),
            selection: rgb(.selectedTextBackgroundColor),
            // Markdown heading / strong markers surface as keywords — bold accent.
            keywords: Attribute(color: accent, bold: true),
            commands: Attribute(color: accent),
            types: Attribute(color: typeTint),
            attributes: Attribute(color: typeTint),
            variables: Attribute(color: rgb(.textColor)),
            values: Attribute(color: numberTint),
            numbers: Attribute(color: numberTint),
            strings: Attribute(color: codeTint),
            characters: Attribute(color: codeTint),
            comments: Attribute(color: rgb(.secondaryLabelColor), italic: true)
        )
    }
}

// MARK: - Coordinator

/// A ``TextViewCoordinator`` that captures the editor's `TextView` and wires
/// the note-editor behaviours onto it: checkbox toggling, wiki-link clicks,
/// slash-command detection, the selection-anchored bubble geometry, and the
/// `EditorActions` editing verbs.
///
/// The coordinator owns NO SwiftUI state — it receives a value-typed ``Host``
/// snapshot of the callbacks each time the representable rebuilds, so it always
/// invokes the freshest closures.
@MainActor
final class NoteEditorCoordinator: NSObject, @MainActor TextViewCoordinator {

    /// A value snapshot of everything the wrapper passes down. Replaced on each
    /// SwiftUI update so closures never go stale.
    struct Host {
        var noteId: String? = nil
        var actions: EditorActions? = nil
        var onWikiLinkNavigate: ((String) -> Void)? = nil
        var onSlashTyped: ((String, CGRect) -> Void)? = nil
        var onWikiLinkTyped: ((String) -> Void)? = nil
        var onSelectionChanged: ((CGRect?) -> Void)? = nil
        var slashMenuActive: Bool = false
        var onSlashMove: ((Bool) -> Void)? = nil
        var onSlashCommit: (() -> Bool)? = nil
        var onSlashDismiss: (() -> Bool)? = nil
    }

    var host = Host(slashMenuActive: false) {
        didSet { reinstallActions() }
    }

    private weak var controller: TextViewController?
    private weak var textView: TextView?
    private var clickRecognizer: NSClickGestureRecognizer?
    private var keyMonitor: Any?

    /// Inline diagram / image rendering. Folds ```mermaid``` / ```plantuml```
    /// fences and `![alt](path)` embeds into display-only image overlays,
    /// revealing the source when the caret enters a region. See
    /// ``DiagramFoldingController``.
    private let diagramFolding = DiagramFoldingController()

    // MARK: TextViewCoordinator

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        self.textView = controller.textView
        installClickRecognizer(on: controller.textView)
        installKeyMonitor()
        reinstallActions()
        diagramFolding.attach(to: controller.textView)
        refreshDiagramFolding(positions: controller.cursorPositions)
    }

    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
        reportSlashAndWiki(positions: newPositions)
        reportSelectionGeometry(positions: newPositions)
        refreshDiagramFolding(positions: newPositions)
    }

    func textViewDidChangeText(controller: TextViewController) {
        reportSlashAndWiki(positions: controller.cursorPositions)
        refreshDiagramFolding(positions: controller.cursorPositions)
    }

    func destroy() {
        if let recognizer = clickRecognizer { textView?.removeGestureRecognizer(recognizer) }
        clickRecognizer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        diagramFolding.detach()
        controller = nil
        textView = nil
    }

    /// Recomputes inline diagram / image overlays for the current selection.
    private func refreshDiagramFolding(positions: [CursorPosition]) {
        let selection = positions.first?.range ?? NSRange(location: 0, length: 0)
        diagramFolding.refresh(selection: selection)
    }

    // MARK: - Slash-menu key interception

    /// While the slash menu is open and our text view is first responder, route
    /// up/down/Return/Esc to the menu instead of the text view. Implemented as a
    /// local key monitor because CodeEditTextView's `TextView` can't be
    /// subclassed from here. Typing still reaches the text view (the monitor
    /// only claims the navigation keys), so the menu keeps filtering.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Extract only Sendable value types before hopping to the main
            // actor — `NSEvent` is not Sendable, so it can't cross the
            // isolation boundary into `assumeIsolated`. (Local monitors already
            // fire on the main thread, so the assertion always holds.)
            let keyCode = event.keyCode
            let modifiersEmpty = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask).isEmpty
            let consumed = MainActor.assumeIsolated {
                self.handleKeyDown(keyCode: keyCode, modifiersEmpty: modifiersEmpty)
            }
            return consumed ? nil : event
        }
    }

    /// Returns `true` when the slash menu consumed the key (so the monitor
    /// should swallow the event), `false` to let it reach the text view.
    private func handleKeyDown(keyCode: UInt16, modifiersEmpty: Bool) -> Bool {
        guard host.slashMenuActive,
              let textView, isFirstResponder(textView) else { return false }
        guard modifiersEmpty else { return false }
        switch keyCode {
        case 125: host.onSlashMove?(true);  return true   // down
        case 126: host.onSlashMove?(false); return true   // up
        case 36, 76, 48:                                  // Return / keypad Enter / Tab
            return host.onSlashCommit?() == true
        case 53:                                          // Escape
            return host.onSlashDismiss?() == true
        default:
            return false
        }
    }

    private func isFirstResponder(_ textView: TextView) -> Bool {
        guard let responder = textView.window?.firstResponder else { return false }
        return responder === textView
    }

    // MARK: - Source / selection access

    private var source: NSString { (textView?.string ?? "") as NSString }

    /// The caret location (UTF-16 offset). Falls back to 0.
    private var caretLocation: Int {
        textView?.selectedRange().location ?? 0
    }

    private var selectedRange: NSRange {
        textView?.selectedRange() ?? NSRange(location: 0, length: 0)
    }

    /// Replaces `range` with `string` through the text view (so undo + the
    /// SwiftUI binding both update) and places the caret at `caret`.
    private func replace(_ range: NSRange, with string: String, caret: Int) {
        guard let textView else { return }
        textView.replaceCharacters(in: range, with: string)
        let clamped = max(0, min(caret, (textView.string as NSString).length))
        textView.selectionManager.setSelectedRange(NSRange(location: clamped, length: 0))
    }

    // MARK: - Click handling (checkboxes + wiki links)

    private func installClickRecognizer(on textView: TextView) {
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        // Don't swallow the click: AppKit still places the caret / starts the
        // selection. We only *additionally* act when the click lands on a
        // checkbox marker or wiki link.
        recognizer.delaysPrimaryMouseButtonEvents = false
        recognizer.delegate = self
        textView.addGestureRecognizer(recognizer)
        clickRecognizer = recognizer
    }

    @objc private func handleClick(_ sender: NSClickGestureRecognizer) {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let point = sender.location(in: textView)
        guard let offset = layoutManager.textOffsetAtPoint(point) else { return }

        // Checkbox toggle takes priority — clicking the marker flips state.
        if let toggleRange = checkboxMarkerRange(at: offset) {
            toggleCheckbox(in: toggleRange.lineRange)
            return
        }
        // Wiki link navigation.
        if let anchor = wikiAnchor(at: offset) {
            host.onWikiLinkNavigate?(anchor)
        }
    }

    /// If `offset` falls on the `[ ]` / `[x]` marker of a checklist line,
    /// returns the line range so the caller can toggle it.
    private func checkboxMarkerRange(at offset: Int) -> (lineRange: NSRange, markerRange: NSRange)? {
        let ns = source
        guard offset >= 0, offset <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: min(offset, ns.length), length: 0))
        let line = ns.substring(with: lineRange)
        guard let markerR = line.range(of: #"^\s*[-*+] \[[ xX]\]"#, options: .regularExpression) else { return nil }
        let markerNS = NSRange(markerR, in: line)
        // The click must land within (roughly) the marker, not the trailing text.
        let absoluteMarker = NSRange(location: lineRange.location + markerNS.location,
                                     length: markerNS.length)
        guard offset >= absoluteMarker.location, offset <= NSMaxRange(absoluteMarker) + 1 else { return nil }
        return (lineRange, absoluteMarker)
    }

    private func toggleCheckbox(in lineRange: NSRange) {
        let src = textView?.string ?? ""
        guard let updated = ChecklistToggle.toggle(source: src, atLocation: lineRange.location) else { return }
        // Replace the whole document range with the toggled source. Cheapest
        // correct path given ChecklistToggle returns the full new source.
        let fullRange = NSRange(location: 0, length: (src as NSString).length)
        let caret = caretLocation
        replace(fullRange, with: updated, caret: min(caret, (updated as NSString).length))
    }

    /// Returns the inner anchor text if `offset` is inside a `[[wiki link]]`.
    private func wikiAnchor(at offset: Int) -> String? {
        let ns = source
        guard offset >= 0, offset <= ns.length else { return nil }
        // Scan the current line for [[...]] spans containing the offset.
        let lineRange = ns.lineRange(for: NSRange(location: min(offset, ns.length), length: 0))
        let line = ns.substring(with: lineRange)
        guard let regex = Self.wikiRegex else { return nil }
        let lineNS = line as NSString
        var found: String?
        regex.enumerateMatches(in: line, range: NSRange(location: 0, length: lineNS.length)) { match, _, stop in
            guard let match, match.numberOfRanges >= 2 else { return }
            let absolute = NSRange(location: lineRange.location + match.range.location,
                                   length: match.range.length)
            if offset >= absolute.location, offset <= NSMaxRange(absolute) {
                let inner = lineNS.substring(with: match.range(at: 1))
                found = inner.trimmingCharacters(in: .whitespaces)
                stop.pointee = true
            }
        }
        return found
    }

    private static let wikiRegex = try? NSRegularExpression(pattern: #"\[\[([^\[\]]+)\]\]"#)

    // MARK: - Slash + wiki typing detection

    private func reportSlashAndWiki(positions: [CursorPosition]) {
        // Only a single collapsed caret drives the slash / completion UIs.
        guard let position = positions.first,
              position.range.length == 0 else {
            host.onSlashTyped?("", .zero)
            host.onWikiLinkTyped?("")
            return
        }
        detectSlash(at: position.range.location)
        detectWikiTyping(at: position.range.location)
    }

    private func detectSlash(at cursor: Int) {
        guard let onSlashTyped = host.onSlashTyped else { return }
        let ns = source
        let safe = min(max(0, cursor), ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: safe, length: 0))
        let toCursor = ns.substring(with: NSRange(location: lineRange.location, length: safe - lineRange.location))
        let stripped = toCursor.drop(while: { $0 == " " || $0 == "\t" })
        guard stripped.first == "/" else { onSlashTyped("", .zero); return }
        let query = String(stripped.dropFirst())
        guard !query.contains(" ") else { onSlashTyped("", .zero); return }
        onSlashTyped(query, caretRectInViewport(at: safe))
    }

    private func detectWikiTyping(at cursor: Int) {
        guard let onWikiLinkTyped = host.onWikiLinkTyped else { return }
        let ns = source
        let safe = min(max(0, cursor), ns.length)
        let prefix = ns.substring(to: safe)
        if let openRange = prefix.range(of: "[[", options: .backwards) {
            let afterOpen = String(prefix[openRange.upperBound...])
            if !afterOpen.contains("]]") {
                onWikiLinkTyped(afterOpen)
                return
            }
        }
        onWikiLinkTyped("")
    }

    // MARK: - Geometry

    /// The caret rect at `offset` in the enclosing scroll view's viewport space
    /// (origin top-left), so SwiftUI overlays anchor correctly regardless of
    /// scroll. Always returns a positive-size rect.
    private func caretRectInViewport(at offset: Int) -> CGRect {
        guard let textView, let layoutManager = textView.layoutManager,
              var rect = layoutManager.rectForOffset(offset) else { return .zero }
        if rect.width < 1 { rect.size.width = 2 }
        if rect.height < 1 { rect.size.height = textView.lineHeight }
        return convertToViewport(rect, in: textView)
    }

    private func reportSelectionGeometry(positions: [CursorPosition]) {
        guard let onSelectionChanged = host.onSelectionChanged else { return }
        guard let position = positions.first, position.range.length > 0,
              let textView, let layoutManager = textView.layoutManager else {
            onSelectionChanged(nil)
            return
        }
        guard let startRect = layoutManager.rectForOffset(position.range.location),
              let endRect = layoutManager.rectForOffset(NSMaxRange(position.range)) else {
            onSelectionChanged(nil)
            return
        }
        // Union the start + end glyph rects — good enough to anchor the bubble.
        let union = startRect.union(endRect)
        onSelectionChanged(convertToViewport(union, in: textView))
    }

    /// Converts a rect in the text view's coordinate space into the enclosing
    /// scroll view's visible viewport space.
    private func convertToViewport(_ rect: NSRect, in textView: TextView) -> CGRect {
        guard let clip = textView.enclosingScrollView?.contentView else { return rect }
        let offset = clip.bounds.origin
        return rect.offsetBy(dx: -offset.x, dy: -offset.y)
    }

    // MARK: - EditorActions

    /// Installs the editing verbs onto the host's ``EditorActions`` so the
    /// toolbar, format bubble, and slash menu reuse a single editing path.
    private func reinstallActions() {
        guard let actions = host.actions else { return }
        actions.bold          = { [weak self] in self?.applyMarker("**") }
        actions.italic        = { [weak self] in self?.applyMarker("*") }
        actions.strikethrough = { [weak self] in self?.applyMarker("~~") }
        actions.code          = { [weak self] in self?.applyMarker("`") }
        actions.link          = { [weak self] in self?.applyLink() }
        actions.blockquote    = { [weak self] in self?.applyLinePrefix("> ") }
        actions.unorderedList = { [weak self] in self?.applyLinePrefix("- ") }
        actions.orderedList   = { [weak self] in self?.applyOrderedList() }
        actions.checklist     = { [weak self] in self?.toggleChecklist() }
        actions.insertTable   = { [weak self] in self?.insert("\n| Column 1 | Column 2 |\n|----------|----------|\n|          |          |\n") }
        actions.setHeading    = { [weak self] level in self?.setHeading(level) }
        actions.insertCodeBlock        = { [weak self] in self?.insertCodeBlock() }
        actions.insertDivider          = { [weak self] in self?.insert("\n---\n") }
        actions.insertImagePlaceholder = { [weak self] in self?.insertImagePlaceholder() }
        actions.clearSlashToken        = { [weak self] in self?.clearSlashToken() }
    }

    private func applyMarker(_ marker: String) {
        let sel = selectedRange
        let (newText, newSel) = InlineMarkerEditor.toggle(in: textView?.string ?? "", selection: sel, marker: marker)
        let fullRange = NSRange(location: 0, length: source.length)
        replace(fullRange, with: newText, caret: newSel.location)
        if let textView, newSel.length > 0 {
            textView.selectionManager.setSelectedRange(newSel)
        }
    }

    private func applyLink() {
        let sel = selectedRange
        let ns = source
        let selectedText = sel.length > 0 ? ns.substring(with: sel) : ""
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        let isURL = URL(string: clipboard)?.scheme?.hasPrefix("http") == true
        let replacement = isURL
            ? "[\(selectedText.isEmpty ? "link" : selectedText)](\(clipboard))"
            : "[["
        let caret = isURL ? sel.location + (replacement as NSString).length : sel.location + 2
        replace(sel, with: replacement, caret: caret)
    }

    private func applyLinePrefix(_ prefix: String) {
        editBlock { lines in
            let allHave = lines.allSatisfy { $0.hasPrefix(prefix) }
            return lines.map { line in
                if allHave { return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line }
                return line.hasPrefix(prefix) ? line : prefix + line
            }
        }
    }

    private func applyOrderedList() {
        let olPattern = #"^\s*\d+\. "#
        editBlock { lines in
            let allHave = lines.allSatisfy { $0.range(of: olPattern, options: .regularExpression) != nil }
            if allHave {
                return lines.map { line in
                    if let r = line.range(of: olPattern, options: .regularExpression) { return String(line[r.upperBound...]) }
                    return line
                }
            }
            return lines.enumerated().map { i, line in
                let content: String
                if let r = line.range(of: olPattern, options: .regularExpression) {
                    content = String(line[r.upperBound...])
                } else {
                    content = line
                }
                return "\(i + 1). \(content)"
            }
        }
    }

    /// Applies a transform across all lines spanned by the selection, then
    /// replaces that block in place.
    private func editBlock(_ transform: ([String]) -> [String]) {
        let ns = source
        let sel = selectedRange
        let startLine = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let endAnchor = min(max(sel.location, NSMaxRange(sel) - 1), max(0, ns.length - 1))
        let endLine = ns.lineRange(for: NSRange(location: endAnchor, length: 0))
        let blockRange = NSRange(location: startLine.location,
                                 length: NSMaxRange(endLine) - startLine.location)
        let block = ns.substring(with: blockRange)
        var lines = block.components(separatedBy: "\n")
        let hadTrailingNewline = lines.last == ""
        if hadTrailingNewline { lines.removeLast() }
        let newLines = transform(lines)
        var newBlock = newLines.joined(separator: "\n")
        if hadTrailingNewline { newBlock += "\n" }
        let caret = blockRange.location + (newBlock as NSString).length
        replace(blockRange, with: newBlock, caret: caret)
    }

    private func toggleChecklist() {
        let (newSource, newCursor) = ChecklistToggle.toggleListMarker(source: textView?.string ?? "", selection: selectedRange)
        let fullRange = NSRange(location: 0, length: source.length)
        replace(fullRange, with: newSource, caret: newCursor)
    }

    private func setHeading(_ level: Int) {
        let ns = source
        let cursor = caretLocation
        let lineRange = ns.lineRange(for: NSRange(location: min(cursor, ns.length), length: 0))
        let lineWithNL = ns.substring(with: lineRange)
        let line = lineWithNL.trimmingCharacters(in: .newlines)
        let trailing = lineWithNL.hasSuffix("\n") ? "\n" : ""
        let stripped: String
        if let m = line.range(of: #"^#{1,6} "#, options: .regularExpression) {
            stripped = String(line[m.upperBound...])
        } else {
            stripped = line
        }
        let newLine = (level == 0 ? stripped : String(repeating: "#", count: level) + " " + stripped) + trailing
        let prefixLen = level == 0 ? 0 : level + 1
        replace(lineRange, with: newLine, caret: lineRange.location + prefixLen)
    }

    private func insert(_ template: String) {
        let sel = selectedRange
        replace(sel, with: template, caret: sel.location + (template as NSString).length)
    }

    private func insertCodeBlock() {
        let template = "```\n\n```\n"
        let sel = selectedRange
        replace(sel, with: template, caret: sel.location + ("```\n" as NSString).length)
    }

    private func insertImagePlaceholder() {
        let template = "![](path)"
        let sel = selectedRange
        // Caret lands on the "path" placeholder.
        replace(sel, with: template, caret: sel.location + ("![](" as NSString).length)
        if let textView {
            let pathStart = sel.location + ("![](" as NSString).length
            textView.selectionManager.setSelectedRange(NSRange(location: pathStart, length: ("path" as NSString).length))
        }
    }

    /// Removes the active `/query` token at the caret before a slash command
    /// runs, so the typed text doesn't linger.
    private func clearSlashToken() {
        let ns = source
        let cursor = caretLocation
        let lineRange = ns.lineRange(for: NSRange(location: min(cursor, ns.length), length: 0))
        let toCursor = ns.substring(with: NSRange(location: lineRange.location, length: cursor - lineRange.location))
        let leading = toCursor.prefix(while: { $0 == " " || $0 == "\t" })
        let afterLeading = toCursor.dropFirst(leading.count)
        guard afterLeading.first == "/" else { return }
        let slashStart = lineRange.location + (leading as NSString).length
        let deleteRange = NSRange(location: slashStart, length: cursor - slashStart)
        replace(deleteRange, with: "", caret: slashStart)
    }
}

// MARK: - Gesture delegate

extension NoteEditorCoordinator: NSGestureRecognizerDelegate {
    /// Let our click recognizer run alongside the text view's own mouse
    /// handling rather than instead of it — the caret still moves on click.
    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer
    ) -> Bool {
        true
    }
}
