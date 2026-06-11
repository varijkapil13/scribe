# Markdown Editor Performance

## The problem (measured)

The editor's `Coordinator.applyFormatting` (`Scribe/UI/DesignSystem/MarkdownEditorView.swift`) does a **full-document rebuild on every keystroke *and* every caret move**: re-decompose storage → `MarkdownRenderer.attributed` re-parses + re-styles the **whole** source → three full-document fold regex passes → `storage.setAttributedString(mutable)` forcing a full TextKit relayout.

`MarkdownRenderPerfTests` measured just the parse+style cost (before the `setAttributedString` relayout on top):

| Note size | Render cost / call |
|---|---|
| ~1 KB | ~3 ms |
| ~7 KB | ~12 ms |
| ~28 KB | ~47 ms |

At 47 ms you're well below 60 fps per keystroke. Worse, the render cache keys on the **exact** cursor offset, so every caret move misses the cache and re-parses the whole doc; and typing fires the rebuild twice (text-change + the trailing selection-change).

## Shipped (safe, verified — 526/0, build green)

1. **Caret-only-move short-circuit** (`canSkipReformatForSelection`). A caret move that can't change the rendered output skips the full rebuild entirely. The render's only position-dependent decisions (Bear-style marker reveal, focus dim, folds) are *block*-scoped, so the skip is gated to be **provably output-preserving**:
   - only when the source is unchanged and the caret is collapsed;
   - only when **both** the new caret and the caret the last render styled are **strictly interior to the same source line** (so neither sits on a block boundary, where reveal's inclusive endpoints light up two adjacent blocks);
   - bail on marked text (IME), on any fenced ``` block (the one caret-sensitive multi-line fold), and on any width / focus-mode / focus-dim change.
   - Any uncertainty → returns false → full reformat runs. It can never show stale formatting.

   This kills the full re-parse + relayout on caret navigation, and removes the redundant second rebuild per keystroke.

2. **Hoisted the two fold regexes to static** (checklist + image) — they were recompiled via `try? NSRegularExpression(...)` on every `applyFormatting` call.

3. **Reused the bridged string** for the regex passes instead of re-bridging `mutable.string` twice.

> An adversarial review of the first cut of the skip found **6 real defects** (the original gated on `paragraphRange`, a different partition than the AST block — boundary moves would have shown stale markers; plus IME, fence-fold, focus-dim, and programmatic-selection edge cases). All are addressed by the strict-interior + guard design above.

## Remaining: incremental block rendering (the real fix for long-note typing)

The shipped work fixes caret navigation and typical-size notes, but a **single keystroke in a long note still re-parses + relays-out the whole document**. The Craft-grade fix is to restyle only the edited block.

**Approach:** from the edit delta, compute the dirty source paragraph, re-render only that block via a new `MarkdownRenderer.attributedBlock(...)`, and splice its **attributes** (`setAttributes`/`addAttributes`, never `setAttributedString`) into the live range inside one `beginEditing`/`endEditing` — so TextKit relays out one paragraph, not the doc. The existing full path stays as the fallback for any edit that crosses a block boundary, touches a fence/fold, or changes block structure.

**Stages:** (1) `attributedBlock` per-block render entry in `MarkdownRenderer`; (2) dirty-block computation from the edit delta; (3) the incremental attribute splice (core); (4) cross-block marker-reveal correctness; (5) headless tests + benchmark, then wire the eligibility gate.

**Invariants to preserve:** source round-trips (`decompose(storage).source == parent.text`); no whole-doc `setAttributedString` / `replaceCharacters` on the incremental path; never splice over a `.foldId` attachment (fall back); leave AppKit's post-insert caret untouched; re-stamp `.scribeBlockId` + all decoration attributes on the dirty range so `drawBackground` never reads a half-styled run; undo bookkeeping unchanged.

**Effort:** L. **Headless-verifiable:** `attributedBlock` correctness + fragment-length-equals-source-length, dirty-block computation as a pure function, the round-trip invariant, and the per-block perf win (extend `MarkdownRenderPerfTests`). **Needs interactive QA:** typing-latency feel on a real long note; that the `drawBackground`/`ensureLayout` crash does not recur under fast typing + fold expansion + resize; no marker-reveal flicker or caret jump on the incremental splice.
