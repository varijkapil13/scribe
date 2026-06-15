//
//  EditorDiagramFolding.swift
//  Scribe
//
//  Inline diagram + image rendering for the CodeEditSourceEditor-backed note
//  editor (``CodeEditNoteTextView`` / ``NoteEditorCoordinator``). Mirrors the
//  old ``MarkdownEditorView`` behaviour: fenced ```mermaid``` / ```plantuml```
//  blocks and `![alt](path)` image embeds render inline as their image, and
//  placing the caret inside a rendered region reveals its source for editing.
//
//  ── How this differs from the old editor ─────────────────────────────────
//  The old editor folded a block by *replacing* the source range with an
//  `NSTextAttachment` whose `bounds` reserved the image's full height in the
//  layout. CodeEditTextView (0.12.1) instead exposes a bespoke *overlay*
//  attachment manager (`TextLayoutManager.attachments`): an attachment is added
//  for a document range WITHOUT mutating the underlying string, and is drawn by
//  a `TextAttachment.draw(in:rect:)` callback. Crucially the protocol exposes
//  only a `width` — the layout reserves a single line's HEIGHT for the
//  attachment (see `LineFragmentRenderer`), there is no public per-attachment
//  height. The drawing `CGContext` is not clipped, so we still draw the full
//  image, but we cannot grow the reserved vertical space the way the old
//  `NSTextAttachment.bounds` did. We therefore keep the document string as the
//  source of truth (attachments are display-only) and reveal-on-caret by simply
//  not folding any region the selection currently intersects.
//
//  ── SwiftPM build boundary ───────────────────────────────────────────────
//  Imports CodeEditSourceEditor / CodeEditTextView and is therefore excluded
//  from the SwiftPM `Scribe` target (see Package.swift, alongside
//  CodeEditNoteTextView.swift / CodeEditNoteSupport.swift).
//

import AppKit
import CodeEditSourceEditor
import CodeEditTextView

// MARK: - Attachment

/// A display-only ``TextAttachment`` that draws a rendered diagram / embedded
/// image inline. The underlying markdown source is untouched; this overlay just
/// paints `image` in place of the folded range.
///
/// Layout note: CodeEditTextView reserves a single line's height for any
/// attachment (the protocol is width-only). We scale the image to fit the
/// available content width and draw it top-aligned into the (unclipped) drawing
/// context so the whole image is visible. `width` reflects the scaled image so
/// horizontal layout stays correct.
final class DiagramImageAttachment: TextAttachment {

    /// The fully-rendered image (diagram or embedded picture).
    let image: NSImage

    /// The drawn size after fitting to the content width (aspect preserved).
    let drawnSize: NSSize

    var isSelected: Bool = false

    init(image: NSImage, maxWidth: CGFloat) {
        self.image = image
        let natural = image.size
        let cap = max(1, maxWidth)
        if natural.width > 0, natural.width > cap {
            let scale = cap / natural.width
            self.drawnSize = NSSize(width: natural.width * scale, height: natural.height * scale)
        } else {
            self.drawnSize = natural
        }
    }

    /// Horizontal space the attachment claims in its line fragment.
    var width: CGFloat { drawnSize.width }

    func draw(in context: CGContext, rect: NSRect) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        // `rect` is one line tall (the layout reserves a single line height for
        // attachments). The context is not clipped, so draw the full image at
        // its fitted size, top-aligned to the line's origin.
        //
        // The editor draws in a flipped (top-left origin) context, where a raw
        // `CGContext.draw(_:in:)` would render the bitmap upside-down. Flip the
        // image's local space back so it paints right-side-up: translate to the
        // bottom of the draw rect and invert the y axis before drawing.
        let drawRect = NSRect(x: rect.minX, y: rect.minY, width: drawnSize.width, height: drawnSize.height)
        context.saveGState()
        context.translateBy(x: drawRect.minX, y: drawRect.minY + drawRect.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: NSRect(x: 0, y: 0, width: drawRect.width, height: drawRect.height))
        context.restoreGState()
        if isSelected {
            context.saveGState()
            context.setStrokeColor(NSColor.selectedTextBackgroundColor.cgColor)
            context.setLineWidth(2)
            context.stroke(drawRect.insetBy(dx: 1, dy: 1))
            context.restoreGState()
        }
    }

    /// Double-click / Enter on the attachment reveals the source for editing by
    /// discarding the overlay; the controller re-folds once the caret leaves.
    func attachmentAction() -> TextAttachmentAction { .discard }
}

// MARK: - Folding controller

/// Scans the editor's markdown source for fenced diagram blocks and image
/// embeds, and maintains ``DiagramImageAttachment`` overlays for them through
/// CodeEditTextView's attachment manager.
///
/// Reveal-on-caret: any region the current selection intersects is left
/// unfolded (source visible) so the user can edit it; moving the caret away
/// re-folds it. The markdown string is never mutated — overlays are purely
/// visual — so saving always writes the original source.
@MainActor
final class DiagramFoldingController {

    private weak var textView: TextView?

    /// The source + content width of the last successful refresh, so we can skip
    /// redundant work on pure caret moves that don't change folding.
    private var lastSource: String = ""
    private var lastContentWidth: CGFloat = -1
    private var lastFoldedRanges: [NSRange] = []

    private static let imageRegex = try? NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#
    )

    func attach(to textView: TextView) {
        self.textView = textView
    }

    func detach() {
        removeAllManagedAttachments()
        textView = nil
        lastSource = ""
        lastContentWidth = -1
        lastFoldedRanges = []
    }

    /// Recomputes which regions should be folded and reconciles the attachment
    /// overlays. Safe to call on every text / selection change — it short
    /// circuits when nothing relevant changed.
    /// - Parameter selection: the current primary selection range (document
    ///   coords). Regions intersecting it are revealed (not folded).
    func refresh(selection: NSRange) {
        guard let textView else { return }
        let source = textView.string
        let contentWidth = availableContentWidth(in: textView)

        let desired = computeFoldRanges(source: source, selection: selection, contentWidth: contentWidth)

        // Skip the reconcile when the inputs and the resulting fold set are
        // identical to last time (the common pure-caret-move case).
        if source == lastSource, contentWidth == lastContentWidth, desired.map(\.range) == lastFoldedRanges {
            return
        }
        lastSource = source
        lastContentWidth = contentWidth
        lastFoldedRanges = desired.map(\.range)

        reconcile(desired: desired, in: textView, contentWidth: contentWidth)
    }

    // MARK: - Fold computation

    private struct FoldCandidate {
        let range: NSRange
        let image: NSImage
    }

    /// All regions that *should* be folded right now, with their images already
    /// in the cache. Diagram renders that aren't cached yet kick off an async
    /// render (via the shared ``DiagramRenderer``) and re-`refresh` when ready;
    /// they're simply omitted until the image lands.
    private func computeFoldRanges(source: String, selection: NSRange, contentWidth: CGFloat) -> [FoldCandidate] {
        var candidates: [FoldCandidate] = []

        // Diagram fences (mermaid / plantuml). Reuse DiagramRenderer's parser.
        let blocks = DiagramRenderer.extractBlocks(from: source)
        for block in blocks {
            guard !intersects(selection, block.nsRange) else { continue }
            let image = DiagramRenderer.shared.image(type: block.type, source: block.source) { [weak self] in
                guard let self, let textView = self.textView else { return }
                // Image landed in cache — recompute with the live selection.
                self.refresh(selection: textView.selectedRange())
            }
            if let image {
                candidates.append(FoldCandidate(range: block.nsRange, image: image))
            }
        }

        // Image embeds `![alt](path)`. Skip any that fall inside a fenced
        // diagram block (those stay as raw markdown, matching the old editor).
        if let regex = Self.imageRegex {
            let ns = source as NSString
            let full = NSRange(location: 0, length: ns.length)
            for match in regex.matches(in: source, range: full) {
                let range = match.range
                guard !intersects(selection, range) else { continue }
                guard !isInsideFence(range, blocks: blocks) else { continue }
                let path = ns.substring(with: match.range(at: 2))
                guard let image = ImageLoader.load(path: path) else { continue }
                candidates.append(FoldCandidate(range: range, image: image))
            }
        }

        return candidates
    }

    /// True when `range` lies within one of the diagram fence ranges (so an
    /// `![]()` inside a ```mermaid``` block isn't double-folded).
    private func isInsideFence(_ range: NSRange, blocks: [DiagramBlock]) -> Bool {
        for block in blocks where NSLocationInRange(range.location, block.nsRange) {
            return true
        }
        return false
    }

    private func intersects(_ selection: NSRange, _ range: NSRange) -> Bool {
        // A collapsed caret anywhere within (inclusive of both ends) the region
        // reveals it; a non-empty selection reveals any region it overlaps.
        if selection.length == 0 {
            return selection.location >= range.location && selection.location <= NSMaxRange(range)
        }
        return NSIntersectionRange(selection, range).length > 0
            || (selection.location <= range.location && NSMaxRange(selection) >= NSMaxRange(range))
    }

    // MARK: - Reconcile

    private func reconcile(desired: [FoldCandidate], in textView: TextView, contentWidth: CGFloat) {
        // Remove every attachment we previously added; rebuild from scratch.
        // The set is small (handful of diagrams/images per note) so the simple
        // teardown/rebuild is cheaper than diffing and avoids stale overlays
        // after an edit shifts ranges.
        removeAllManagedAttachments()

        let manager = textView.layoutManager.attachments
        // Add in ascending order; the manager keeps them sorted and ignores
        // overlaps, but our candidates never overlap by construction.
        for candidate in desired.sorted(by: { $0.range.location < $1.range.location }) {
            let attachment = DiagramImageAttachment(image: candidate.image, maxWidth: contentWidth)
            manager.add(attachment, for: candidate.range)
        }
        textView.layoutManager.setNeedsLayout()
        textView.needsDisplay = true
    }

    private func removeAllManagedAttachments() {
        guard let textView else { return }
        let manager = textView.layoutManager.attachments
        // Query the live document for every attachment that is ours, rather than
        // trusting `managedRanges` — an edit can shift attachment ranges (the
        // manager re-anchors them via `textUpdated`) so our cached offsets may be
        // stale. Removing by the manager's current ranges keeps us in sync and
        // never disturbs attachments owned by other features.
        let docRange = NSRange(location: 0, length: (textView.string as NSString).length)
        let ours = manager.getAttachmentsOverlapping(docRange)
            .filter { $0.attachment is DiagramImageAttachment }
        // Remove from the back so earlier offsets stay valid.
        for any in ours.sorted(by: { $0.range.location > $1.range.location }) {
            manager.remove(atOffset: any.range.location)
        }
    }

    // MARK: - Geometry

    /// The width available for an inline image: the text container width minus
    /// its line-fragment padding, capped so very wide diagrams stay readable.
    private func availableContentWidth(in textView: TextView) -> CGFloat {
        let viewWidth = textView.enclosingScrollView?.contentView.bounds.width ?? textView.bounds.width
        let inset = (textView.edgeInsets.left + textView.edgeInsets.right)
        let usable = max(120, viewWidth - inset - 24)
        return min(usable, 640)
    }
}
