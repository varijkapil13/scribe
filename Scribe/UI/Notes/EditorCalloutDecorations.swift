//
//  EditorCalloutDecorations.swift
//  Scribe
//
//  Obsidian callout rendering + focus-mode dimming for the
//  CodeEditSourceEditor-backed note editor (``CodeEditNoteTextView`` /
//  ``NoteEditorCoordinator``). Reproduces two visuals from the old
//  ``MarkdownEditorView`` on the new TextKit-2 engine:
//
//    • Callouts — `> [!type] Title` blockquotes get a type-tinted left bar, a
//      soft tinted panel behind the whole block, and an SF Symbol drawn beside
//      the title (see ``EditorCalloutStyle`` for the type→colour/icon mapping).
//    • Focus mode — when the `noteEditor.focusMode` preference is on, every
//      block except the one containing the caret is dimmed.
//
//  ── Why an overlay, not attributes ───────────────────────────────────────
//  The tree-sitter highlighter owns the text view's attributes, so writing
//  foreground colours / backgrounds for callouts would fight it (and regress
//  syntax highlighting). CodeEditSourceEditor 0.15.2 / CodeEditTextView 0.12.1
//  expose no per-range "background decoration" API. What they DO expose is:
//    • `TextLayoutManager.rectsFor(range:)` — bounding rects (text-view coords,
//      flipped top-left origin) for every line fragment a range touches, and
//    • `TextView` is a flipped document view whose `LineFragmentView`s are
//      `isOpaque == false`.
//  So we draw with two non-interactive overlay `NSView`s that are subviews of
//  the (document-sized, scrolling) text view:
//    • a BACK overlay (kept ordered behind the line fragments) paints the
//      callout panels + bars + icons — visible through the transparent
//      fragment views, and
//    • a FRONT overlay (kept ordered above the fragments) paints the focus-mode
//      scrim over the non-active blocks.
//  Both scroll with the text because they're subviews of the document view; we
//  size them to the text view's bounds and recompute geometry whenever the
//  text, selection, or layout changes.
//
//  ── Deferred ──────────────────────────────────────────────────────────────
//  • Nested callouts (a callout inside a callout) render only the outermost
//    block's panel — the regex pass keys off the first `> [!type]` line and
//    tints the contiguous top-level blockquote. This matches the old editor
//    (which only upgraded depth-1 blockquotes).
//  • The type icon is drawn as a badge in the panel's top-right corner. The new
//    engine doesn't indent blockquote text (the old editor reserved a 24pt
//    head-indent the tree-sitter layout doesn't apply), so a leading-gutter icon
//    would sit over the `> [!type]` markers; the top-right badge stays in clear
//    space. The headline Obsidian-parity visual (tinted bar + soft panel) is the
//    primary cue, with the icon reinforcing the type.
//
//  ── SwiftPM build boundary ───────────────────────────────────────────────
//  Imports CodeEditSourceEditor / CodeEditTextView and is therefore excluded
//  from the SwiftPM `Scribe` target (see Package.swift, alongside
//  CodeEditNoteTextView.swift / CodeEditNoteSupport.swift /
//  EditorDiagramFolding.swift).
//

import AppKit
import CodeEditSourceEditor
import CodeEditTextView

// MARK: - Model

/// A resolved callout block: the document range of the contiguous top-level
/// blockquote, plus its type keyword (`note`, `tip`, …) and the range of the
/// `[!type]` marker on the first line (used to anchor the icon).
private struct CalloutRegion {
    let blockRange: NSRange
    let kind: String
    /// Range of the title text on the first line (after the `[!type]` marker),
    /// or the marker range itself when there is no title.
    let titleAnchor: NSRange
}

// MARK: - Overlay view

/// A non-interactive overlay drawn behind or in front of the text. Painting is
/// delegated back to the controller via `onDraw` so all the geometry lives in
/// one place.
private final class CalloutOverlayView: NSView {
    var onDraw: (@MainActor (CGRect) -> Void)?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        onDraw?(dirtyRect)
    }
}

// MARK: - Controller

/// Scans the editor's markdown for `> [!type]` callouts and draws their tinted
/// panels / bars / icons, and (when focus mode is on) dims every block except
/// the caret's. Purely visual — never mutates the document.
@MainActor
final class CalloutDecorationController: NSObject {

    private weak var textView: TextView?

    /// Back overlay: callout panels + bars + icons, behind the text glyphs.
    private weak var backOverlay: CalloutOverlayView?
    /// Front overlay: the focus-mode scrim, above the text glyphs.
    private weak var frontOverlay: CalloutOverlayView?

    /// The clip view we observe for scroll-driven bounds changes (so we can
    /// re-assert overlay z-order + repaint as new line fragments are laid out
    /// lazily during scrolling). Held weakly for observer teardown.
    private weak var observedClip: NSClipView?

    // Current state, captured on each refresh and read back inside `draw`.
    private var callouts: [CalloutRegion] = []
    private var focusModeEnabled = false
    private var focusDimAlpha: CGFloat = 0.18
    private var activeBlockRange: NSRange?

    /// Matches an Obsidian callout marker on a blockquote's first line:
    /// `> [!type]` with an optional `+`/`-` fold hint. Capture group 1 is the
    /// type keyword.
    private static let calloutRegex = try? NSRegularExpression(
        pattern: #"^>\s*\[!([A-Za-z]+)\][-+]?"#,
        options: [.anchorsMatchLines]
    )

    // MARK: Lifecycle

    func attach(to textView: TextView) {
        self.textView = textView

        let back = CalloutOverlayView(frame: textView.bounds)
        back.autoresizingMask = [.width, .height]
        back.onDraw = { [weak self] rect in self?.drawCallouts(in: rect) }
        textView.addSubview(back, positioned: .below, relativeTo: nil)
        self.backOverlay = back

        let front = CalloutOverlayView(frame: textView.bounds)
        front.autoresizingMask = [.width, .height]
        front.onDraw = { [weak self] rect in self?.drawFocusDim(in: rect) }
        textView.addSubview(front, positioned: .above, relativeTo: nil)
        self.frontOverlay = front

        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            // Selector-based observer (not the closure form) so no `@Sendable`
            // closure has to capture this `@MainActor`, non-Sendable controller.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: clip
            )
            observedClip = clip
        }
    }

    func detach() {
        if let observedClip {
            NotificationCenter.default.removeObserver(
                self, name: NSView.boundsDidChangeNotification, object: observedClip
            )
        }
        observedClip = nil
        backOverlay?.removeFromSuperview()
        frontOverlay?.removeFromSuperview()
        backOverlay = nil
        frontOverlay = nil
        textView = nil
        callouts = []
        activeBlockRange = nil
    }

    // MARK: Refresh

    /// Recomputes callout regions + the focus-mode active block and repaints.
    /// Safe to call on every text / selection change.
    /// - Parameters:
    ///   - selection: the primary selection range (document coords).
    ///   - focusMode: whether focus-mode dimming is on.
    ///   - dimAlpha: scrim opacity for dimmed blocks (0…1).
    func refresh(selection: NSRange, focusMode: Bool, dimAlpha: CGFloat) {
        guard let textView else { return }
        let source = textView.string as NSString

        callouts = Self.computeCallouts(in: source)
        focusModeEnabled = focusMode
        focusDimAlpha = dimAlpha
        activeBlockRange = focusMode ? Self.blockRange(in: source, containing: selection.location) : nil

        // New fragments may have been added below our back overlay during an
        // edit; re-assert z-order so panels stay behind text and the scrim above.
        reassertOrder()
        backOverlay?.needsDisplay = true
        frontOverlay?.needsDisplay = true
    }

    /// Scroll-driven repaint. The clip view posts this on the main thread, so
    /// `assumeIsolated` is safe.
    @objc
    private nonisolated func clipBoundsDidChange(_ note: Notification) {
        MainActor.assumeIsolated {
            // Lazily-laid-out fragments during scroll can land below the back
            // overlay (covering text) or above the front scrim; re-assert
            // z-order and repaint both layers for the new viewport.
            reassertOrder()
            backOverlay?.needsDisplay = true
            frontOverlay?.needsDisplay = true
        }
    }

    private func reassertOrder() {
        guard let textView, let backOverlay, let frontOverlay else { return }
        textView.addSubview(backOverlay, positioned: .below, relativeTo: nil)
        textView.addSubview(frontOverlay, positioned: .above, relativeTo: nil)
    }

    // MARK: Callout scanning

    /// Finds every top-level callout in `source`. A callout is a contiguous run
    /// of `>`-prefixed lines whose first line carries a `[!type]` marker.
    private static func computeCallouts(in source: NSString) -> [CalloutRegion] {
        guard let regex = calloutRegex, source.length > 0 else { return [] }
        let full = NSRange(location: 0, length: source.length)
        var regions: [CalloutRegion] = []

        for match in regex.matches(in: source as String, range: full) {
            let markerRange = match.range
            guard match.numberOfRanges >= 2,
                  match.range(at: 1).location != NSNotFound else { continue }
            let kind = source.substring(with: match.range(at: 1))

            // The marker must start at the beginning of its line (anchored regex
            // already guarantees this with `.anchorsMatchLines`).
            let firstLine = source.lineRange(for: NSRange(location: markerRange.location, length: 0))

            // Extend the block downward over consecutive `>`-prefixed lines.
            var blockEnd = NSMaxRange(firstLine)
            while blockEnd < source.length {
                let next = source.lineRange(for: NSRange(location: blockEnd, length: 0))
                let lineText = source.substring(with: next)
                let trimmed = lineText.drop(while: { $0 == " " || $0 == "\t" })
                guard trimmed.first == ">" else { break }
                blockEnd = NSMaxRange(next)
                if next.length == 0 { break }
            }
            // Trim a single trailing newline so the panel doesn't bleed into the
            // blank line after the callout.
            var blockLength = blockEnd - firstLine.location
            if blockLength > 0,
               source.character(at: firstLine.location + blockLength - 1) == 0x0A {
                blockLength -= 1
            }
            let blockRange = NSRange(location: firstLine.location, length: max(0, blockLength))

            // Title anchor: text on the first line after the marker, else the
            // marker itself.
            let afterMarker = NSMaxRange(markerRange)
            let firstLineEnd = NSMaxRange(firstLine)
            let titleAnchor: NSRange
            if afterMarker < firstLineEnd {
                titleAnchor = NSRange(location: afterMarker, length: firstLineEnd - afterMarker)
            } else {
                titleAnchor = markerRange
            }

            regions.append(CalloutRegion(blockRange: blockRange, kind: kind, titleAnchor: titleAnchor))
        }
        return regions
    }

    /// The contiguous "block" (paragraph-ish run delimited by blank lines)
    /// containing `location`, used as the focus-mode active region. Blank lines
    /// (only whitespace) bound the block.
    private static func blockRange(in source: NSString, containing location: Int) -> NSRange {
        guard source.length > 0 else { return NSRange(location: 0, length: 0) }
        let loc = min(max(0, location), source.length)
        let caretLine = source.lineRange(for: NSRange(location: min(loc, max(0, source.length - 1)), length: 0))

        // If the caret is on a blank line, the active block is just that line.
        func isBlank(_ range: NSRange) -> Bool {
            let text = source.substring(with: range)
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if isBlank(caretLine) { return caretLine }

        // Walk up while previous lines are non-blank.
        var start = caretLine.location
        while start > 0 {
            let prev = source.lineRange(for: NSRange(location: start - 1, length: 0))
            if isBlank(prev) { break }
            start = prev.location
        }
        // Walk down while following lines are non-blank.
        var end = NSMaxRange(caretLine)
        while end < source.length {
            let next = source.lineRange(for: NSRange(location: end, length: 0))
            if isBlank(next) { break }
            end = NSMaxRange(next)
        }
        return NSRange(location: start, length: end - start)
    }

    // MARK: Drawing — callouts (back overlay)

    private func drawCallouts(in dirtyRect: CGRect) {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let viewWidth = textView.bounds.width
        let leftInset = textView.edgeInsets.left
        let rightInset = textView.edgeInsets.right

        for callout in callouts {
            guard callout.blockRange.length > 0 else { continue }
            let rects = layoutManager.rectsFor(range: callout.blockRange)
            guard !rects.isEmpty else { continue }
            // Union the line-fragment rects vertically; the panel spans the full
            // text column width (the fragment rects are text-width only).
            let minY = rects.map(\.minY).min() ?? 0
            let maxY = rects.map(\.maxY).max() ?? 0
            let tint = EditorCalloutStyle.tint(for: callout.kind)

            let panel = NSRect(
                x: leftInset,
                y: minY,
                width: max(0, viewWidth - leftInset - rightInset),
                height: maxY - minY
            )
            guard panel.intersects(dirtyRect) else { continue }

            // Soft tinted panel behind the whole block.
            tint.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: panel.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()

            // Tinted left bar flush to the leading edge.
            let bar = NSRect(x: panel.minX + 2, y: panel.minY + 3, width: 3, height: panel.height - 6)
            tint.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()

            drawIcon(for: callout, tint: tint, panel: panel, layoutManager: layoutManager)
        }
    }

    /// Draws the type's SF Symbol as a badge in the top-right corner of the
    /// panel's first line — clear space that never collides with the `> [!type]`
    /// markers the tree-sitter layout leaves at the line start.
    private func drawIcon(
        for callout: CalloutRegion,
        tint: NSColor,
        panel: NSRect,
        layoutManager: TextLayoutManager
    ) {
        // Vertically centre on the first title line (top of the block).
        let titleRects = layoutManager.rectsFor(range: callout.titleAnchor)
        let firstLineMidY = titleRects.first?.midY ?? (panel.minY + 10)
        let size: CGFloat = 13
        // Palette colour config tints the symbol to the callout's tint without
        // any image-redraw closure (avoids a `@Sendable` drawing handler).
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        guard let symbol = NSImage(
            systemSymbolName: EditorCalloutStyle.symbolName(for: callout.kind),
            accessibilityDescription: callout.kind
        )?.withSymbolConfiguration(config) else { return }
        symbol.isTemplate = false

        let iconRect = NSRect(
            x: panel.maxX - size - 8,
            y: firstLineMidY - size / 2,
            width: size,
            height: size
        )
        // `respectFlipped` keeps the glyph upright in our flipped overlay.
        symbol.draw(in: iconRect, from: .zero, operation: .sourceOver,
                    fraction: 1.0, respectFlipped: true, hints: nil)
    }

    // MARK: Drawing — focus dim (front overlay)

    private func drawFocusDim(in dirtyRect: CGRect) {
        guard focusModeEnabled, let textView, let layoutManager = textView.layoutManager else { return }
        let source = textView.string as NSString
        guard source.length > 0 else { return }

        guard let active = activeBlockRange else { return }  // empty doc — dim nothing

        // The editor sits on Scribe's surface chrome with a transparent
        // background (`useThemeBackground: false`), so we dim by laying a
        // translucent scrim of the surface colour over the non-active blocks.
        // This approximates the old editor's text-alpha dimming without touching
        // attributes (which the tree-sitter highlighter owns).
        let scrimBase: NSColor
        if let cg = textView.layer?.backgroundColor, let resolved = NSColor(cgColor: cg),
           resolved.alphaComponent > 0.01 {
            scrimBase = resolved
        } else {
            scrimBase = .textBackgroundColor
        }
        scrimBase.withAlphaComponent(1 - focusDimAlpha).setFill()

        let docHeight = textView.bounds.height
        let viewWidth = textView.bounds.width

        // Dim everything outside the active block: the span above it and the span
        // below it. Drawn as two full-width bands so it's cheap regardless of
        // document length and never touches the active paragraph.
        let activeRects = layoutManager.rectsFor(range: clamp(active, length: source.length))
        let topY = activeRects.map(\.minY).min() ?? 0
        let bottomY = activeRects.map(\.maxY).max() ?? docHeight

        let aboveBand = NSRect(x: 0, y: 0, width: viewWidth, height: max(0, topY))
        if aboveBand.height > 0, aboveBand.intersects(dirtyRect) { aboveBand.fill() }

        let belowBand = NSRect(x: 0, y: bottomY, width: viewWidth, height: max(0, docHeight - bottomY))
        if belowBand.height > 0, belowBand.intersects(dirtyRect) { belowBand.fill() }
    }

    private func clamp(_ range: NSRange, length: Int) -> NSRange {
        let loc = max(0, min(range.location, length))
        let len = max(0, min(range.length, length - loc))
        return NSRange(location: loc, length: len)
    }
}
