// Extensions/ScribeQuickLook/ScribeMarkdownPreviewViewController.swift
//
// Quick Look preview extension for Markdown files (Finder space-bar preview
// of vault notes). View-based: a read-only, scrollable NSTextView showing the
// note rendered by ScribeMarkdownAttributedRenderer. Lives outside Scribe/
// (SwiftPM compiles all of Scribe/ into the app executable); built only by
// Xcode as the ScribeQuickLook target and embedded in the app.

import AppKit
import Quartz

final class ScribeMarkdownPreviewViewController: NSViewController, @preconcurrency QLPreviewingController {

    /// Previews of huge files stay responsive: only the first 1 MB is shown.
    private static let maxPreviewBytes = 1_000_000

    private var textView: NSTextView?

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 800))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.autoresizingMask = [.width, .height]

        let contentSize = scrollView.contentSize
        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        self.textView = textView
        view = scrollView
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let data = try Self.readPrefix(of: url)
        // Lenient decode: a prefix cut mid-character is repaired, not dropped.
        let text = String(decoding: data, as: UTF8.self)
        _ = view  // ensures loadView() has run
        textView?.textStorage?.setAttributedString(ScribeMarkdownAttributedRenderer.render(text))
        textView?.scrollToBeginningOfDocument(nil)
    }

    private static func readPrefix(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: maxPreviewBytes) ?? Data()
    }
}
