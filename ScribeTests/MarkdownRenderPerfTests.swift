// ScribeTests/MarkdownRenderPerfTests.swift
//
// Quantifies the cost of the editor's per-keystroke / per-caret-move render
// path so optimizations target the real bottleneck and improvements are
// measurable. Prints ms/call; does not gate CI on absolute timings.

import XCTest
import AppKit
@testable import Scribe

final class MarkdownRenderPerfTests: XCTestCase {

    /// A realistic note body: headings, paragraphs with inline marks, lists,
    /// blockquotes, and fenced code — repeated to reach a target size.
    private func doc(sections: Int) -> String {
        var s = "# Meeting notes\n\n"
        for i in 0..<sections {
            s += """
            ## Section \(i)

            This is a paragraph with **bold**, *italic*, `code`, ~~strike~~, and a [link](https://example.com). Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor.

            - first item
            - second item with **emphasis**
            - third item

            > A blockquote with some commentary about section \(i).

            ```swift
            let value = \(i)
            print(value)
            ```


            """
        }
        return s
    }

    func testRenderCostByDocSize() {
        let font = NSFont.systemFont(ofSize: 14)
        print("\n=== MarkdownRenderer.attributed cost (per-keystroke / per-caret-move) ===")
        for sections in [3, 20, 80] {
            let source = doc(sections: sections)
            let bytes = source.utf8.count
            let iters = 25

            // cursor-varied → cache miss each call (mirrors typing & caret moves)
            let t0 = Date()
            for k in 0..<iters {
                let cursor = (k * 137) % max(1, (source as NSString).length)
                _ = MarkdownRenderer.attributed(source, font: font, cursorOffset: cursor)
            }
            let missMs = Date().timeIntervalSince(t0) / Double(iters) * 1000

            // same cursor → cache hit (mirrors resize / repaint)
            let t1 = Date()
            for _ in 0..<iters {
                _ = MarkdownRenderer.attributed(source, font: font, cursorOffset: 10)
            }
            let hitMs = Date().timeIntervalSince(t1) / Double(iters) * 1000

            print(String(format: "  %6d bytes | cache-MISS %6.2f ms/call | cache-HIT %6.3f ms/call",
                         bytes, missMs, hitMs))
            XCTAssertGreaterThan(missMs, 0)
        }
        print("======================================================================\n")
    }
}
