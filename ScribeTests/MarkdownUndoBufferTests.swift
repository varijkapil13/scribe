// ScribeTests/MarkdownUndoBufferTests.swift
import XCTest
@testable import Scribe

/// Tests for the source-level undo buffer that backs MarkdownEditorView.
/// The buffer is value-state with no view dependencies, so the
/// interesting behaviour (coalescing, boundaries, redo invalidation,
/// reset, seed-on-first-record) is straightforward to exercise.
final class MarkdownUndoBufferTests: XCTestCase {

    private func sel(_ loc: Int = 0) -> NSRange { NSRange(location: loc, length: 0) }

    // MARK: - Seed

    func testFirstRecordSeedsWithoutPushing() {
        var buf = MarkdownUndoBuffer()
        let pushed = buf.record(source: "Hello", selection: sel(5))
        XCTAssertFalse(pushed)
        XCTAssertTrue(buf.undoStack.isEmpty)
        XCTAssertEqual(buf.currentSource, "Hello")
    }

    func testUndoAfterSeedNoOp() {
        var buf = MarkdownUndoBuffer()
        buf.record(source: "Hello", selection: sel(5))
        XCTAssertNil(buf.popUndo())
    }

    // MARK: - Basic undo / redo

    func testUndoReturnsPriorState() {
        var buf = MarkdownUndoBuffer()
        buf.record(source: "Hello", selection: sel(5), now: t(0))
        buf.record(source: "Hello world", selection: sel(11), now: t(1.0))
        let snap = buf.popUndo()
        XCTAssertEqual(snap?.source, "Hello")
    }

    func testRedoRestoresPoppedState() {
        var buf = MarkdownUndoBuffer()
        buf.record(source: "a", selection: sel(1), now: t(0))
        buf.record(source: "ab", selection: sel(2), now: t(1.0))
        _ = buf.popUndo()
        let redo = buf.popRedo()
        XCTAssertEqual(redo?.source, "ab")
    }

    func testNewChangeAfterUndoClearsRedo() {
        var buf = MarkdownUndoBuffer()
        buf.record(source: "a", selection: sel(1), now: t(0))
        buf.record(source: "ab", selection: sel(2), now: t(1.0))
        _ = buf.popUndo()
        buf.record(source: "aX", selection: sel(2), now: t(2.0))
        XCTAssertTrue(buf.redoStack.isEmpty)
    }

    // MARK: - Coalescing

    func testRapidTypingCoalescesIntoOneSnapshot() {
        var buf = MarkdownUndoBuffer()
        buf.record(source: "h", selection: sel(1), now: t(0))
        // Each keystroke within the coalesce window only updates the
        // "current" pointer; a single snapshot anchors the burst.
        buf.record(source: "he", selection: sel(2), now: t(0.1))
        buf.record(source: "hel", selection: sel(3), now: t(0.2))
        buf.record(source: "hell", selection: sel(4), now: t(0.3))
        buf.record(source: "hello", selection: sel(5), now: t(0.4))
        XCTAssertEqual(buf.undoStack.count, 1)
        let snap = buf.popUndo()
        XCTAssertEqual(snap?.source, "h")
    }

    func testGapBeyondWindowFlushesBurst() {
        var buf = MarkdownUndoBuffer()
        buf.record(source: "h", selection: sel(1), now: t(0))
        buf.record(source: "he", selection: sel(2), now: t(0.1))
        // Gap > coalesce window — next keystroke starts a new snapshot.
        buf.record(source: "hex", selection: sel(3), now: t(2.0))
        XCTAssertEqual(buf.undoStack.count, 2)
    }

    func testNewlineForcesNewSnapshot() {
        var buf = MarkdownUndoBuffer()
        buf.record(source: "first", selection: sel(5), now: t(0))
        buf.record(source: "firsta", selection: sel(6), now: t(0.1))
        buf.record(source: "firsta\n", selection: sel(7), now: t(0.2))
        // Newline is a hard boundary regardless of timing.
        XCTAssertEqual(buf.undoStack.count, 2)
    }

    func testLargeDeltaForcesNewSnapshot() {
        var buf = MarkdownUndoBuffer()
        buf.record(source: "abc", selection: sel(3), now: t(0))
        // Simulate a paste — multi-character insert in one go.
        buf.record(source: "abcXXXXXXXX", selection: sel(11), now: t(0.05))
        XCTAssertEqual(buf.undoStack.count, 1)
        // The paste is its own undo step (hardBoundary) — the next
        // character starts another snapshot rather than coalescing
        // back onto the paste.
        buf.record(source: "abcXXXXXXXXy", selection: sel(12), now: t(0.10))
        XCTAssertEqual(buf.undoStack.count, 2)
    }

    func testEndTypingBurstBreaksCoalesce() {
        var buf = MarkdownUndoBuffer()
        buf.record(source: "a", selection: sel(1), now: t(0))
        buf.record(source: "ab", selection: sel(2), now: t(0.1))
        // Toolbar action / editSource — flushes the burst boundary.
        buf.endTypingBurst()
        buf.record(source: "abc", selection: sel(3), now: t(0.2))
        XCTAssertEqual(buf.undoStack.count, 2)
    }

    // MARK: - Reset / cap

    func testResetClearsBothStacks() {
        var buf = MarkdownUndoBuffer()
        buf.record(source: "a", selection: sel(1), now: t(0))
        buf.record(source: "ab", selection: sel(2), now: t(1.0))
        _ = buf.popUndo()
        buf.reset()
        XCTAssertTrue(buf.undoStack.isEmpty)
        XCTAssertTrue(buf.redoStack.isEmpty)
        XCTAssertEqual(buf.currentSource, "")
    }

    func testResetReseedsOnNextRecord() {
        var buf = MarkdownUndoBuffer()
        buf.record(source: "first note", selection: sel(0), now: t(0))
        buf.reset()
        // Switching notes — the first record after reset should NOT
        // push the previous note's contents.
        buf.record(source: "second note", selection: sel(0), now: t(1.0))
        XCTAssertTrue(buf.undoStack.isEmpty)
        XCTAssertEqual(buf.currentSource, "second note")
    }

    func testStackCapTrimsOldestEntries() {
        var buf = MarkdownUndoBuffer()
        buf.stackCap = 5
        buf.record(source: "0", selection: sel(0), now: t(0))
        // Need each push to be a separate hard-boundary event so all
        // ten registrations land on the stack.
        for i in 1...10 {
            buf.record(source: "0\(i)\n", selection: sel(0), now: t(Double(i) * 5.0))
        }
        XCTAssertEqual(buf.undoStack.count, 5)
    }

    // MARK: - Helpers

    private func t(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }
}
