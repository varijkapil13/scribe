# Rich Editor Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the note editor to Apple-Notes-feel: interactive checklists, sharper visual hierarchy, drag-drop images, and rendered markdown tables. Diagram folding stays untouched. Markdown is still the canonical persistence format.

**Architecture:** Reuse the existing `MarkdownFormatter` + `FoldRegistry` machinery. Checklists and images fold into `NSTextAttachment` via the same path diagrams use. Visual hierarchy lands as in-formatter attribute changes plus an `NSTextView.draw(_:in:)` override for blockquote bar and code-block fill. Tables render via per-row `paragraphStyle.tabStops`. New helper module `AttachmentsDirectory` for image file paths.

**Tech Stack:** Swift 6, AppKit, SwiftUI, NSTextView / NSLayoutManager, GRDB (for the existing storage layer), XCTest via SwiftPM.

---

## Project conventions (read once before starting)

- Sources under `Scribe/`, tests under `ScribeTests/`. Run with `swift test`. Filter: `swift test --filter <ClassName>`.
- After adding/removing files, regenerate Xcode project: `xcodegen`.
- Match the existing `MarkdownEditorView.swift` style: AppKit subclasses are nested or sit at file scope; coordinator owns mutation; `editSource` is the only path that mutates markdown source.
- Test new pure logic at the static-function level — `MarkdownNSTextView.listPrefix` is the pattern.
- No new third-party dependencies.

---

## Slice A — Interactive checklists

Adds tappable checkbox attachments backed by markdown `- [ ] / - [x]`. Smart Enter continues with an unchecked item. Toolbar button + `⌘⇧U` shortcut to insert.

### Task A.1: `listPrefix` continuation always restarts unchecked

**Files:**
- Modify: `Scribe/UI/DesignSystem/MarkdownEditorView.swift` (only the two `listPrefix` / `nextListPrefix` static funcs)
- Test: `ScribeTests/MarkdownListPrefixTests.swift` (new)

The current `listPrefix` already detects `[ ]` / `[xX]` but `nextListPrefix` doesn't normalise a checked item back to unchecked for the next line. Apple Notes always starts a new unchecked item after Enter on a checked one. Fix that.

- [ ] **Step 1: Write the failing test**

```swift
// ScribeTests/MarkdownListPrefixTests.swift
import XCTest
@testable import Scribe

final class MarkdownListPrefixTests: XCTestCase {

    func testListPrefixDetectsUncheckedChecklist() {
        XCTAssertEqual(MarkdownNSTextView.listPrefix(from: "- [ ] task"), "- [ ] ")
    }

    func testListPrefixDetectsCheckedChecklist() {
        XCTAssertEqual(MarkdownNSTextView.listPrefix(from: "- [x] done"), "- [x] ")
        XCTAssertEqual(MarkdownNSTextView.listPrefix(from: "- [X] done"), "- [X] ")
    }

    func testListPrefixDetectsPlainBullet() {
        XCTAssertEqual(MarkdownNSTextView.listPrefix(from: "- task"), "- ")
        XCTAssertEqual(MarkdownNSTextView.listPrefix(from: "* task"), "* ")
    }

    func testListPrefixDetectsNumbered() {
        XCTAssertEqual(MarkdownNSTextView.listPrefix(from: "1. task"), "1. ")
        XCTAssertEqual(MarkdownNSTextView.listPrefix(from: "  42. nested"), "  42. ")
    }

    func testListPrefixNilForPlainText() {
        XCTAssertNil(MarkdownNSTextView.listPrefix(from: "no list here"))
    }

    func testNextListPrefixIncrementsNumbered() {
        XCTAssertEqual(MarkdownNSTextView.nextListPrefix(from: "1. "), "2. ")
        XCTAssertEqual(MarkdownNSTextView.nextListPrefix(from: "  42. "), "  43. ")
    }

    func testNextListPrefixRestartsCheckedToUnchecked() {
        XCTAssertEqual(MarkdownNSTextView.nextListPrefix(from: "- [x] "), "- [ ] ")
        XCTAssertEqual(MarkdownNSTextView.nextListPrefix(from: "- [X] "), "- [ ] ")
    }

    func testNextListPrefixPreservesUnchecked() {
        XCTAssertEqual(MarkdownNSTextView.nextListPrefix(from: "- [ ] "), "- [ ] ")
    }

    func testNextListPrefixPreservesPlainBullet() {
        XCTAssertEqual(MarkdownNSTextView.nextListPrefix(from: "- "), "- ")
    }
}
```

- [ ] **Step 2: Run to verify failures**

```bash
swift test --filter MarkdownListPrefixTests
```

Expected: `testNextListPrefixRestartsCheckedToUnchecked` fails (current `nextListPrefix` returns `"- [x] "` unchanged). Others should pass on the current implementation.

- [ ] **Step 3: Update `nextListPrefix` in `Scribe/UI/DesignSystem/MarkdownEditorView.swift`**

Find the existing static func around line 766:

```swift
    static func nextListPrefix(from prefix: String) -> String {
        if let r = prefix.range(of: #"\d+"#, options: .regularExpression),
           let num = Int(prefix[r]) {
            return prefix.replacingCharacters(in: r, with: "\(num + 1)")
        }
        return prefix
    }
```

Replace with:

```swift
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
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter MarkdownListPrefixTests
```

Expected: 9/9 pass.

```bash
swift test 2>&1 | tail -3
```

Expected: full suite green (was 286; now 295).

- [ ] **Step 5: Commit**

```bash
git add Scribe/UI/DesignSystem/MarkdownEditorView.swift ScribeTests/MarkdownListPrefixTests.swift
git commit -m "feat(editor): checked checklist items restart unchecked on Enter"
```

---

### Task A.2: Checklist toggle helper (pure function)

**Files:**
- Create: `Scribe/UI/DesignSystem/ChecklistToggle.swift`
- Test: `ScribeTests/ChecklistToggleTests.swift`

A pure helper that takes a markdown string + a source character index, returns the new markdown with `[ ]` ↔ `[x]` toggled on the line containing that index (or nil if the line has no checkbox).

- [ ] **Step 1: Write the failing test**

```swift
// ScribeTests/ChecklistToggleTests.swift
import XCTest
@testable import Scribe

final class ChecklistToggleTests: XCTestCase {

    func testToggleUncheckedToChecked() {
        let source = "- [ ] buy milk"
        let result = ChecklistToggle.toggle(source: source, atLocation: 0)
        XCTAssertEqual(result, "- [x] buy milk")
    }

    func testToggleCheckedToUnchecked() {
        let source = "- [x] buy milk"
        let result = ChecklistToggle.toggle(source: source, atLocation: 0)
        XCTAssertEqual(result, "- [ ] buy milk")
    }

    func testToggleNormalisesCapitalXToLowercase() {
        let source = "- [X] buy milk"
        let result = ChecklistToggle.toggle(source: source, atLocation: 0)
        XCTAssertEqual(result, "- [ ] buy milk")
    }

    func testToggleOnlyLineContainingLocation() {
        let source = "- [ ] first\n- [ ] second"
        // Location 12 is inside "- [ ] second".
        let result = ChecklistToggle.toggle(source: source, atLocation: 12)
        XCTAssertEqual(result, "- [ ] first\n- [x] second")
    }

    func testToggleReturnsNilForNonChecklistLine() {
        let source = "plain text"
        XCTAssertNil(ChecklistToggle.toggle(source: source, atLocation: 0))
    }

    func testToggleHandlesIndentedChecklist() {
        let source = "  - [ ] nested"
        let result = ChecklistToggle.toggle(source: source, atLocation: 0)
        XCTAssertEqual(result, "  - [x] nested")
    }
}
```

- [ ] **Step 2: Run to verify fail**

```bash
swift test --filter ChecklistToggleTests
```

Expected: compile error (`ChecklistToggle` doesn't exist).

- [ ] **Step 3: Create the helper**

```swift
// Scribe/UI/DesignSystem/ChecklistToggle.swift
import Foundation

/// Pure helper for toggling a markdown checklist item's `[ ]` ↔ `[x]` state.
/// Operates on the line that contains the given character location.
enum ChecklistToggle {

    /// Returns a copy of `source` with the checklist marker on the line
    /// containing `atLocation` flipped between `[ ]` and `[x]`. Capital `X`
    /// is treated as checked and normalised to lowercase `x` when toggled.
    /// Returns `nil` when the line has no checkbox marker.
    static func toggle(source: String, atLocation: Int) -> String? {
        let nsSource = source as NSString
        guard atLocation >= 0, atLocation <= nsSource.length else { return nil }
        let lineRange = nsSource.lineRange(for: NSRange(location: atLocation, length: 0))
        let line = nsSource.substring(with: lineRange).trimmingCharacters(in: .newlines)

        guard let markerRange = line.range(of: #"\[[ xX]\]"#, options: .regularExpression) else {
            return nil
        }
        let marker = String(line[markerRange])
        let toggled = (marker == "[ ]") ? "[x]" : "[ ]"
        let newLine = line.replacingCharacters(in: markerRange, with: toggled)
        // Preserve any trailing newline from the original line range.
        let original = nsSource.substring(with: lineRange)
        let suffix = String(original.suffix(while: { $0.isNewline }))
        let result = nsSource.replacingCharacters(in: lineRange, with: newLine + suffix)
        return result
    }
}

private extension String {
    /// Returns the suffix where every character matches `predicate`.
    func suffix(while predicate: (Character) -> Bool) -> String {
        var idx = endIndex
        while idx > startIndex {
            let prev = index(before: idx)
            if predicate(self[prev]) {
                idx = prev
            } else {
                break
            }
        }
        return String(self[idx...])
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter ChecklistToggleTests
```

Expected: 6/6 pass.

- [ ] **Step 5: Commit**

```bash
git add Scribe/UI/DesignSystem/ChecklistToggle.swift ScribeTests/ChecklistToggleTests.swift
git commit -m "feat(editor): ChecklistToggle pure helper for [ ] ↔ [x]"
```

---

### Task A.3: Render checkboxes as folded attachments

**Files:**
- Modify: `Scribe/UI/DesignSystem/MarkdownEditorView.swift`

Insert checkbox rendering into the same `applyFormatting` pass that handles diagram folds. The checkbox replaces the literal `- [ ] ` / `- [x] ` characters with an `NSTextAttachment` whose cell draws a 16pt circle/checkmark glyph.

- [ ] **Step 1: Read current `applyFormatting` end-to-end**

Read `Scribe/UI/DesignSystem/MarkdownEditorView.swift` lines 300–500. Find where `mutable` is built and where decisions for diagrams are applied (around lines 350–410). Checkboxes will be applied AFTER diagrams are folded (so checkbox NSRanges don't shift under the diagram splice).

- [ ] **Step 2: Add the attachment cell type at file scope** (above `MarkdownNSTextView`)

```swift
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
```

- [ ] **Step 3: Add a checkbox detection + fold pass after the diagram fold pass**

Inside `Coordinator.applyFormatting`, find the block that applies the `decisions` loop in reverse (the `for decision in decisions.reversed() where decision.fold` block). After it, before `let (_, newRegistry) = FoldRegistry.decompose(mutable)`, insert:

```swift
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
```

Add the `.checklistMarker` key alongside the existing `.wikiAnchor` declaration at the top of the file:

```swift
extension NSAttributedString.Key {
    static let wikiAnchor    = NSAttributedString.Key("scribe.wikiAnchor")
    static let codeBlockLine = NSAttributedString.Key("scribe.codeBlock")
    static let blockquoteLine = NSAttributedString.Key("scribe.blockquote")
    static let horizontalRule = NSAttributedString.Key("scribe.hr")
    static let checklistMarker = NSAttributedString.Key("scribe.checklist")
}
```

- [ ] **Step 4: Build & smoke test**

```bash
swift build
swift test 2>&1 | tail -3
```

Build succeeds; suite stays green at 295 (no new tests; UI-only change).

Manual smoke:
1. Open a note.
2. Type `- [ ] foo`. Verify the `- [ ] ` collapses into a circle glyph with `foo` after it.
3. Type `- [x] done`. Verify circle is filled + checkmark + `done` is struck through.

- [ ] **Step 5: Commit**

```bash
git add Scribe/UI/DesignSystem/MarkdownEditorView.swift
git commit -m "feat(editor): render markdown checkboxes as tappable attachment glyphs"
```

---

### Task A.4: Click toggles checkbox state

**Files:**
- Modify: `Scribe/UI/DesignSystem/MarkdownEditorView.swift` (extend `mouseDown` in `MarkdownNSTextView`)

The existing `mouseDown` already handles fold-expand for diagrams and wiki-link nav. Add a third branch: if the clicked character has `.checklistMarker` true, toggle via `ChecklistToggle` and re-run formatting.

- [ ] **Step 1: Find the existing `mouseDown` override**

```bash
grep -n "override func mouseDown" Scribe/UI/DesignSystem/MarkdownEditorView.swift
```

Read the existing body. It handles wiki-link `.wikiAnchor` clicks (calls `onWikiLinkNavigate`) and fold-expand (sets selection to expand the fold).

- [ ] **Step 2: Insert the checklist branch at the top of `mouseDown`**

After the early `guard` / location-resolution code, before the wiki-link check, add:

```swift
        // Checklist click → toggle the markdown source.
        if attributedString().length > 0,
           charIndex < attributedString().length,
           attributedString().attribute(.checklistMarker, at: charIndex, effectiveRange: nil) as? Bool == true,
           let coord = delegate as? MarkdownEditorView.Coordinator {
            // Map display char index back to source location.
            let storage = textStorage ?? NSTextStorage()
            let registry = FoldRegistry.decompose(storage).registry
            let sourceLoc = FoldRegistry.sourceLocation(forDisplay: charIndex, registry: registry)
            coord.editSource { source, _ in
                if let updated = ChecklistToggle.toggle(source: source, atLocation: sourceLoc) {
                    return (updated, NSRange(location: sourceLoc, length: 0))
                }
                return (source, NSRange(location: sourceLoc, length: 0))
            }
            return
        }
```

Adjust the variable name `charIndex` to whatever the existing `mouseDown` uses — read the file to confirm. If the existing code computes the character index via `characterIndex(for:)`, mirror that.

- [ ] **Step 3: Build & manual smoke**

```bash
swift build
```

Manual:
1. Type `- [ ] task`. Click the circle. Verify it flips to filled + `task` strikes through.
2. Click again — flips back.
3. Toggle persistence: close the note, re-open. State survives.

- [ ] **Step 4: Commit**

```bash
git add Scribe/UI/DesignSystem/MarkdownEditorView.swift
git commit -m "feat(editor): clicking checkbox attachment toggles markdown source"
```

---

### Task A.5: Toolbar button + `⌘⇧U` shortcut to insert checklist

**Files:**
- Modify: `Scribe/UI/Notes/FormatToolbar.swift`
- Modify: `Scribe/UI/DesignSystem/MarkdownEditorView.swift` (wire `EditorActions.checklist` and `performKeyEquivalent`)

- [ ] **Step 1: Add the action to `EditorActions`**

In `Scribe/UI/Notes/FormatToolbar.swift`:

```swift
@Observable
final class EditorActions {
    var bold: (() -> Void)?
    var italic: (() -> Void)?
    var strikethrough: (() -> Void)?
    var code: (() -> Void)?
    var link: (() -> Void)?
    var blockquote: (() -> Void)?
    var unorderedList: (() -> Void)?
    var orderedList: (() -> Void)?
    var checklist: (() -> Void)?
    var setHeading: ((Int) -> Void)?
}
```

Add the toolbar button in the same file, in the body's button row after the `list.number` button:

```swift
            ToolbarButton(systemImage: "checklist", tooltip: "Checklist (⌘⇧U)") { actions.checklist?() }
```

- [ ] **Step 2: Wire the action in `MarkdownEditorView`**

In `Scribe/UI/DesignSystem/MarkdownEditorView.swift`, find where the other `EditorActions` closures are assigned (search for `actions?.bold = `). Add:

```swift
        actions?.checklist = { [weak coord] in coord?.toggleChecklistOnSelection() }
```

Add the method on `Coordinator`:

```swift
        func toggleChecklistOnSelection() {
            editSource { source, sel in
                let nsSource = source as NSString
                let lineRange = nsSource.lineRange(for: sel)
                let line = nsSource.substring(with: lineRange).trimmingCharacters(in: .newlines)
                // If the line is already a checklist, no-op (the regex below would
                // otherwise insert another marker before the existing one).
                if line.range(of: #"^\s*- \[[ xX]\] "#, options: .regularExpression) != nil {
                    return (source, sel)
                }
                let newLine = "- [ ] " + line
                let newSource = nsSource.replacingCharacters(in: lineRange,
                                                             with: newLine + (lineRange.length > line.count ? "\n" : ""))
                let shift = ("- [ ] " as NSString).length
                return (newSource, NSRange(location: sel.location + shift, length: 0))
            }
        }
```

- [ ] **Step 3: Add the `⌘⇧U` keyboard shortcut**

In `Scribe/UI/DesignSystem/MarkdownEditorView.swift`, find the `performKeyEquivalent` override on `MarkdownNSTextView` (search for `performKeyEquivalent`). Add a case for `cmd-shift-U`:

```swift
        if event.modifierFlags.contains([.command, .shift]),
           event.charactersIgnoringModifiers?.lowercased() == "u",
           let coord = delegate as? MarkdownEditorView.Coordinator {
            coord.toggleChecklistOnSelection()
            return true
        }
```

Place it alongside the other shortcut cases (`⌘B`, `⌘I`, etc.). If the file doesn't yet have a `performKeyEquivalent` override, add one — copy the shape from another AppKit view in the codebase if available, or use the standard `override func performKeyEquivalent(with event: NSEvent) -> Bool { … }`.

- [ ] **Step 4: Build & smoke**

```bash
swift build
swift test 2>&1 | tail -3
```

Manual: click in a note body, press `⌘⇧U`. Verify `- [ ] ` is inserted before the line and renders as a checkbox.

- [ ] **Step 5: Commit**

```bash
git add Scribe/UI/DesignSystem/MarkdownEditorView.swift Scribe/UI/Notes/FormatToolbar.swift
git commit -m "feat(editor): checklist toolbar button + ⌘⇧U shortcut"
```

---

### Slice A verification gate

```bash
swift test
```

Expected: green (295). Manual: type-edit-toggle-collapse-persist round-trip works.

---

## Slice B — Visual hierarchy polish

In-formatter typography tweaks plus an `NSTextView.draw` override for blockquote accent bar and code-block background fill.

### Task B.1: Heading sizes + auto-title for first H1

**Files:**
- Modify: `Scribe/UI/DesignSystem/MarkdownEditorView.swift` (inside `MarkdownFormatter`)

- [ ] **Step 1: Locate the heading attribute application**

```bash
grep -n "H1\|H2\|H3\|font.*Heading\|heading" Scribe/UI/DesignSystem/MarkdownEditorView.swift | head -10
```

Find the section in `MarkdownFormatter.attributed(...)` where each line's heading level is computed and applied. The current sizes are: H1=22, H2=18, H3=16.

- [ ] **Step 2: Apply auto-title detection**

In the `MarkdownFormatter` line-walk, declare a local at the top of the iteration:

```swift
        var seenFirstH1 = false
```

Where the H1 attributes are applied (font.bold + size 22), branch on `seenFirstH1`:

```swift
            // existing H1 detection block — replace size table with:
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
            let headingFont = NSFont.systemFont(ofSize: size, weight: weight)
            mutable.addAttribute(.font, value: headingFont, range: lineRange)
```

Use the actual variable names and ranges already in place — the literal code above is illustrative; adapt it to fit the surrounding method's existing structure (the formatter likely has one place where heading attributes get applied; modify that single block).

- [ ] **Step 3: Build & smoke**

```bash
swift build
swift test 2>&1 | tail -3
```

Manual: create a note starting with `# Big title` on the first line, then `## Section` and `# Another H1`. Verify the first H1 is noticeably bigger than the second.

- [ ] **Step 4: Commit**

```bash
git add Scribe/UI/DesignSystem/MarkdownEditorView.swift
git commit -m "polish(editor): first H1 styled as auto-title; bumped H2/H3 sizes"
```

---

### Task B.2: Blockquote accent bar + code-block background

**Files:**
- Modify: `Scribe/UI/DesignSystem/MarkdownEditorView.swift` (`MarkdownNSTextView`)

`MarkdownFormatter` already tags lines with `.blockquoteLine` and `.codeBlockLine` attributes. We just need to draw decorations behind those line fragments.

- [ ] **Step 1: Override `draw(_:in:)` (or `drawBackground`) on `MarkdownNSTextView`**

Add a method to `MarkdownNSTextView`:

```swift
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager = self.layoutManager,
              let container = self.textContainer,
              let storage = self.textStorage else { return }

        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: rect, in: container)
        let visibleChars = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)

        // Code-block fill — pale rectangle behind every line carrying .codeBlockLine.
        let codeFill = DesignTokens.Palette.surfaceSunken.withAlphaComponent(0.5)
        storage.enumerateAttribute(.codeBlockLine, in: visibleChars) { value, range, _ in
            guard (value as? Bool) == true else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, usedRect, _, _, _ in
                let drawRect = lineRect.offsetBy(dx: self.textContainerOrigin.x,
                                                 dy: self.textContainerOrigin.y)
                let inset = NSRect(x: drawRect.minX,
                                   y: drawRect.minY,
                                   width: max(usedRect.width + 16, drawRect.width - 16),
                                   height: drawRect.height)
                codeFill.setFill()
                NSBezierPath(roundedRect: inset, xRadius: 4, yRadius: 4).fill()
            }
        }

        // Blockquote bar — 4pt-wide accent bar to the left of any line carrying .blockquoteLine.
        let barColor = NSColor.controlAccentColor.withAlphaComponent(0.5)
        storage.enumerateAttribute(.blockquoteLine, in: visibleChars) { value, range, _ in
            guard (value as? Bool) == true else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, _, _ in
                let drawRect = lineRect.offsetBy(dx: self.textContainerOrigin.x,
                                                 dy: self.textContainerOrigin.y)
                let bar = NSRect(x: drawRect.minX + self.textContainerInset.width - 8,
                                 y: drawRect.minY,
                                 width: 4,
                                 height: drawRect.height)
                barColor.setFill()
                NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
            }
        }
    }
```

If `DesignTokens.Palette.surfaceSunken` returns a SwiftUI `Color`, wrap with `NSColor(_:)`:

```swift
        let codeFill = NSColor(DesignTokens.Palette.surfaceSunken).withAlphaComponent(0.5)
```

Check `DesignTokens.swift` for the actual return type and adapt.

- [ ] **Step 2: Build & smoke**

```bash
swift build
```

Manual: in a note, type:

```
> A wise quote.

`code in a fence`
```

(with a fenced ```code``` block too). Verify the blockquote line has a left accent bar; the fenced lines have a subtle background fill.

- [ ] **Step 3: Commit**

```bash
git add Scribe/UI/DesignSystem/MarkdownEditorView.swift
git commit -m "polish(editor): blockquote accent bar + code-block background fill"
```

---

### Slice B verification gate

```bash
swift test
```

Expected: 295/295 green. Manual: visual hierarchy reads cleaner.

---

## Slice C — Image drag-drop

### Task C.1: `AttachmentsDirectory` helper

**Files:**
- Create: `Scribe/Storage/AttachmentsDirectory.swift`
- Test: `ScribeTests/AttachmentsDirectoryTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// ScribeTests/AttachmentsDirectoryTests.swift
import XCTest
@testable import Scribe

final class AttachmentsDirectoryTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testDirectoryCreatesParent() throws {
        let dir = try AttachmentsDirectory.directory(forNoteId: "note-42", root: tempRoot)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testDirectoryReturnsSameForSameNoteId() throws {
        let a = try AttachmentsDirectory.directory(forNoteId: "n", root: tempRoot)
        let b = try AttachmentsDirectory.directory(forNoteId: "n", root: tempRoot)
        XCTAssertEqual(a.path, b.path)
    }

    func testStoreCopiesIntoDirectoryAndReturnsRelativePath() throws {
        // Create a source file to copy.
        let sourceFile = tempRoot.appendingPathComponent("source.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: sourceFile)

        let result = try AttachmentsDirectory.store(
            sourceURL: sourceFile,
            forNoteId: "note-1",
            root: tempRoot
        )

        // Returned relative path should be "attachments/note-1/<uuid>.png".
        XCTAssertTrue(result.relativePath.hasPrefix("attachments/note-1/"))
        XCTAssertTrue(result.relativePath.hasSuffix(".png"))
        // The destination file exists.
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.absoluteURL.path))
        // The original source is untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))
    }

    func testCleanupRemovesNoteDirectory() throws {
        let dir = try AttachmentsDirectory.directory(forNoteId: "n", root: tempRoot)
        try Data().write(to: dir.appendingPathComponent("a.png"))
        try AttachmentsDirectory.cleanup(forNoteId: "n", root: tempRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testCleanupOnMissingDirectoryIsNoOp() throws {
        XCTAssertNoThrow(try AttachmentsDirectory.cleanup(forNoteId: "ghost", root: tempRoot))
    }
}
```

- [ ] **Step 2: Run tests**

```bash
swift test --filter AttachmentsDirectoryTests
```

Expected: compile error.

- [ ] **Step 3: Implement**

```swift
// Scribe/Storage/AttachmentsDirectory.swift
import Foundation

/// Resolves per-note attachment paths under
/// `~/Library/Application Support/Scribe/attachments/<noteId>/`.
///
/// The `root` parameter exists for testability — production callers omit it
/// and get the default Application Support root.
enum AttachmentsDirectory {

    struct StoredAttachment {
        /// Path relative to `root` (e.g. `attachments/note-1/abc.png`). Suitable
        /// for embedding in a markdown body so other installations / exports can
        /// resolve it from the same root.
        let relativePath: String
        /// Absolute file URL.
        let absoluteURL: URL
    }

    static func defaultRoot() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return appSupport.appendingPathComponent("Scribe", isDirectory: true)
    }

    /// Returns the directory for a note's attachments, creating it (and any
    /// intermediate directories) if missing.
    @discardableResult
    static func directory(forNoteId noteId: String, root: URL = defaultRoot()) throws -> URL {
        let dir = root
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(noteId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies `sourceURL` into the note's attachments directory under a new
    /// UUID-based filename, preserving the original extension. Returns both
    /// the relative path (for markdown embedding) and the absolute URL.
    static func store(
        sourceURL: URL,
        forNoteId noteId: String,
        root: URL = defaultRoot()
    ) throws -> StoredAttachment {
        let ext = sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension
        let filename = "\(UUID().uuidString).\(ext)"
        let dir = try directory(forNoteId: noteId, root: root)
        let dest = dir.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        let relative = "attachments/\(noteId)/\(filename)"
        return StoredAttachment(relativePath: relative, absoluteURL: dest)
    }

    /// Removes the note's attachments directory if present. No-op when missing.
    static func cleanup(forNoteId noteId: String, root: URL = defaultRoot()) throws {
        let dir = root
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(noteId, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter AttachmentsDirectoryTests
```

Expected: 5/5 pass.

- [ ] **Step 5: Commit**

```bash
git add Scribe/Storage/AttachmentsDirectory.swift ScribeTests/AttachmentsDirectoryTests.swift
git commit -m "feat(storage): AttachmentsDirectory helper for per-note image storage"
```

---

### Task C.2: `NoteStore.deleteNote` cleans up attachments folder

**Files:**
- Modify: `Scribe/Storage/NoteStore.swift`
- Test: `ScribeTests/NoteStoreTests.swift` (append)

- [ ] **Step 1: Write the failing test**

Append to `ScribeTests/NoteStoreTests.swift`:

```swift
    func testDeleteNoteRemovesAttachmentsFolder() throws {
        let store = NoteStore(databaseManager: db)
        let note = try store.createNote(title: "Has images", body: "")

        // Create the attachments folder via the helper to simulate a drop.
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = try AttachmentsDirectory.directory(forNoteId: note.id, root: tempRoot)
        try Data().write(to: dir.appendingPathComponent("image.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))

        // Inject the temp root via a static override (see step 3 — we'll add a
        // shared `rootOverride` testing seam on AttachmentsDirectory).
        AttachmentsDirectory.rootOverrideForTesting = tempRoot
        defer { AttachmentsDirectory.rootOverrideForTesting = nil }

        try store.deleteNote(id: note.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path),
                       "deleteNote should remove the attachments folder")
        try? FileManager.default.removeItem(at: tempRoot)
    }
```

- [ ] **Step 2: Add the testing seam to AttachmentsDirectory**

Edit `Scribe/Storage/AttachmentsDirectory.swift`. Add a static var that production never sets:

```swift
enum AttachmentsDirectory {
    /// Test-only override of the storage root. Production code uses
    /// `defaultRoot()`. Setting this lets `NoteStore.deleteNote` (which
    /// doesn't take a `root` parameter) be exercised against a temp dir.
    nonisolated(unsafe) static var rootOverrideForTesting: URL?

    static func defaultRoot() -> URL {
        if let override = rootOverrideForTesting { return override }
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return appSupport.appendingPathComponent("Scribe", isDirectory: true)
    }
    // … rest unchanged …
}
```

- [ ] **Step 3: Extend `NoteStore.deleteNote` to call cleanup**

Edit `Scribe/Storage/NoteStore.swift`. The current `deleteNote` (after slice 20.1.3) is:

```swift
    func deleteNote(id: String) throws {
        try db.write { database in
            try database.execute(
                sql: "DELETE FROM sessions WHERE noteId = ?",
                arguments: [id]
            )
            _ = try Note.deleteOne(database, key: id)
        }
    }
```

Add a best-effort cleanup AFTER the DB write succeeds:

```swift
    func deleteNote(id: String) throws {
        try db.write { database in
            try database.execute(
                sql: "DELETE FROM sessions WHERE noteId = ?",
                arguments: [id]
            )
            _ = try Note.deleteOne(database, key: id)
        }
        // Best-effort: remove the note's attachments folder. Failures are
        // logged but don't propagate — the DB row is already gone.
        do {
            try AttachmentsDirectory.cleanup(forNoteId: id)
        } catch {
            Log.storage.error("Failed to clean attachments for note \(id, privacy: .public): \(error.localizedDescription, privacy: .private)")
        }
    }
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter NoteStoreTests
```

Expected: existing 22 tests still pass + the new 1 = 23 in this filter.

```bash
swift test 2>&1 | tail -3
```

Full suite green (was 300; now 301 with the new test — actual count depends on Slice A's new tests, just verify failure count is 0).

- [ ] **Step 5: Commit**

```bash
git add Scribe/Storage/AttachmentsDirectory.swift \
        Scribe/Storage/NoteStore.swift \
        ScribeTests/NoteStoreTests.swift
git commit -m "feat(note-store): deleteNote cleans up attachments folder"
```

---

### Task C.3: NSTextView accepts image drops + inserts markdown

**Files:**
- Modify: `Scribe/UI/DesignSystem/MarkdownEditorView.swift`
- Modify: `Scribe/UI/Notes/NoteEditorView.swift` (pass noteId through)
- Modify: `Scribe/UI/Notes/NoteDetailView.swift` (pass `vm.note.id`)

- [ ] **Step 1: Plumb `noteId` to MarkdownEditorView**

In `Scribe/UI/DesignSystem/MarkdownEditorView.swift`, add the property:

```swift
struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Notes…"
    var font: NSFont = .systemFont(ofSize: 15)
    var actions: EditorActions? = nil
    var extraHighlighter: ((NSMutableAttributedString) -> Void)? = nil
    var onWikiLinkTyped: ((String) -> Void)? = nil
    var onWikiLinkNavigate: ((String) -> Void)? = nil
    var noteId: String? = nil   // NEW — required for image drop
```

In `makeNSView`, after constructing the `MarkdownNSTextView` `tv`:

```swift
        tv.noteId = noteId
```

In `updateNSView`, keep it in sync:

```swift
        if let textView = scrollView.documentView as? MarkdownNSTextView {
            textView.noteId = noteId
        }
```

On `MarkdownNSTextView`, add the stored property:

```swift
    var noteId: String?
```

- [ ] **Step 2: Register for drag types**

In `MarkdownNSTextView`, override `init(frame:textContainer:)` or set up at `awakeFromNib`. The cleanest approach: do it in the existing initializer. Find where the text view is constructed (`MarkdownNSTextView()` in `makeNSView`) and immediately after construction add:

```swift
        tv.registerForDraggedTypes([.fileURL, .png, .tiff])
```

`.fileURL` requires importing `UniformTypeIdentifiers` if not already; the constants are on `NSPasteboard.PasteboardType`.

- [ ] **Step 3: Override drag handlers on `MarkdownNSTextView`**

Add to `MarkdownNSTextView`:

```swift
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAcceptDrop(sender) else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAcceptDrop(sender) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canAcceptDrop(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let noteId else { return false }
        let pb = sender.draggingPasteboard

        // Resolve a file URL — either a direct file or written-out raw image data.
        var sourceURL: URL?
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first, isImage(url: first) {
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

        // Store the image into the note's attachments folder.
        let stored: AttachmentsDirectory.StoredAttachment
        do {
            stored = try AttachmentsDirectory.store(sourceURL: sourceURL, forNoteId: noteId)
        } catch {
            Log.app.error("Image drop failed: \(error.localizedDescription, privacy: .private)")
            return false
        }

        // Insert markdown at the drop point.
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

    private func canAcceptDrop(_ sender: NSDraggingInfo) -> Bool {
        guard noteId != nil else { return false }
        let pb = sender.draggingPasteboard
        if pb.types?.contains(.png) == true { return true }
        if pb.types?.contains(.tiff) == true { return true }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            return urls.contains(where: isImage(url:))
        }
        return false
    }

    private func isImage(url: URL) -> Bool {
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "bmp", "heic", "webp"]
        return imageExts.contains(url.pathExtension.lowercased())
    }
```

- [ ] **Step 4: Pass `noteId` from the parent view**

In `Scribe/UI/Notes/NoteEditorView.swift`, add the parameter:

```swift
struct NoteEditorView: View {
    @Binding var text: String
    var noteStore: NoteStore
    var noteId: String? = nil
    var onNavigate: (String) -> Void
    // …
```

In the body, pass it to `MarkdownEditorView`:

```swift
                MarkdownEditorView(
                    text: $text,
                    placeholder: "Write your note…",
                    actions: editorActions,
                    extraHighlighter: highlightWikiLinks(_:),
                    onWikiLinkTyped: { … },
                    onWikiLinkNavigate: { anchor in onNavigate(anchor) },
                    noteId: noteId
                )
```

In `Scribe/UI/Notes/NoteDetailView.swift`, update the `NoteEditorView` call site to pass `vm.note.id`:

```swift
            NoteEditorView(
                text: Binding(
                    get: { vm.note.body },
                    set: { vm.note.body = $0; vm.markDirty() }
                ),
                noteStore: .shared,
                noteId: vm.note.id,
                onNavigate: { anchor in vm.handleWikiLinkNavigate(anchor: anchor) }
            )
```

- [ ] **Step 5: Build & smoke**

```bash
swift build
swift test 2>&1 | tail -3
```

Manual: open a note, drag a `.png` from Finder onto the editor. Verify a markdown link `![](attachments/<noteId>/<uuid>.png)` is inserted and a file appears at that path. Image rendering is the next task — for now we just verify the file is copied and the link inserted.

- [ ] **Step 6: Commit**

```bash
git add Scribe/UI/DesignSystem/MarkdownEditorView.swift \
        Scribe/UI/Notes/NoteEditorView.swift \
        Scribe/UI/Notes/NoteDetailView.swift
git commit -m "feat(editor): accept dropped images; copy to attachments folder + insert markdown"
```

---

### Task C.4: Fold image markdown links into inline image attachments

**Files:**
- Modify: `Scribe/UI/DesignSystem/MarkdownEditorView.swift` (formatter)

- [ ] **Step 1: Add an image-fold pass in `applyFormatting`**

Inside `Coordinator.applyFormatting`, after the checklist-fold pass (added in Task A.3), add an image-fold pass. Image links in markdown look like `![alt](path)`. The path is either absolute (`file:///…`) or relative to `~/Library/Application Support/Scribe/`.

```swift
            // Image folds — match `![alt](path)`. Resolve path against the
            // app's support directory and the note's attachments folder.
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
```

- [ ] **Step 2: Add the `ImageLoader` cache helper**

At file scope in `MarkdownEditorView.swift` (or a new file `Scribe/UI/DesignSystem/ImageLoader.swift` — preferred):

```swift
// Scribe/UI/DesignSystem/ImageLoader.swift
import AppKit
import Foundation

/// Loads and caches `NSImage`s referenced by markdown image links. Resolves
/// paths against the Scribe Application Support directory so a markdown
/// body like `![](attachments/<noteId>/<file>.png)` works.
enum ImageLoader {

    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]
    nonisolated(unsafe) private static let cacheQueue = DispatchQueue(label: "scribe.imageloader.cache")
    private static let cacheCap = 32

    static func load(path: String) -> NSImage? {
        if let cached = cacheQueue.sync(execute: { cache[path] }) {
            return cached
        }
        let url: URL
        if path.hasPrefix("file://") || path.hasPrefix("/") {
            url = URL(fileURLWithPath: path.replacingOccurrences(of: "file://", with: ""))
        } else {
            let root = AttachmentsDirectory.defaultRoot()
            url = root.appendingPathComponent(path)
        }
        guard let img = NSImage(contentsOf: url) else { return nil }
        cacheQueue.sync {
            if cache.count >= cacheCap {
                cache.removeAll() // simple flush; LRU is overkill for note attachments
            }
            cache[path] = img
        }
        return img
    }
}
```

- [ ] **Step 3: Build & smoke**

```bash
swift build
swift test 2>&1 | tail -3
```

Manual: drop an image onto a note. Verify the markdown link is replaced by the image inline. Position the cursor inside the link → it should expand back to source for editing (existing fold-expand behaviour).

- [ ] **Step 4: Commit**

```bash
git add Scribe/UI/DesignSystem/MarkdownEditorView.swift \
        Scribe/UI/DesignSystem/ImageLoader.swift
git commit -m "feat(editor): fold ![](path) image links into inline image attachments"
```

---

### Slice C verification gate

```bash
swift test
```

Manual flow:
1. Open a note.
2. Drag a `.png` from Finder onto the editor — link inserted, image renders inline.
3. Click inside the image to expand back to `![](…)` source.
4. Delete the note — confirm `~/Library/Application Support/Scribe/attachments/<noteId>/` is gone.

---

## Slice D — Markdown tables

### Task D.1: `MarkdownTable.detect(lines:)` returns table block metadata

**Files:**
- Create: `Scribe/UI/DesignSystem/MarkdownTable.swift`
- Test: `ScribeTests/MarkdownTableTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// ScribeTests/MarkdownTableTests.swift
import XCTest
@testable import Scribe

final class MarkdownTableTests: XCTestCase {

    func testDetectsSimpleTable() {
        let source = """
        | A | B |
        |---|---|
        | 1 | 2 |
        """
        let tables = MarkdownTable.detect(in: source)
        XCTAssertEqual(tables.count, 1)
        let t = tables[0]
        XCTAssertEqual(t.columnCount, 2)
        XCTAssertEqual(t.headerRow, 0)
        XCTAssertEqual(t.separatorRow, 1)
        XCTAssertEqual(t.bodyRows, [2])
    }

    func testRequiresSeparatorRowImmediatelyAfterHeader() {
        let source = """
        | A | B |
        | 1 | 2 |
        """
        let tables = MarkdownTable.detect(in: source)
        XCTAssertEqual(tables.count, 0, "No separator row → not a table")
    }

    func testHandlesMultipleTables() {
        let source = """
        | A | B |
        |---|---|
        | 1 | 2 |

        Some prose.

        | X | Y | Z |
        |---|---|---|
        | a | b | c |
        | d | e | f |
        """
        let tables = MarkdownTable.detect(in: source)
        XCTAssertEqual(tables.count, 2)
        XCTAssertEqual(tables[0].columnCount, 2)
        XCTAssertEqual(tables[1].columnCount, 3)
        XCTAssertEqual(tables[1].bodyRows.count, 2)
    }

    func testComputesColumnWidthsFromContent() {
        let source = """
        | A | Title |
        |---|---|
        | hello | x |
        """
        let tables = MarkdownTable.detect(in: source)
        XCTAssertEqual(tables[0].columnWidths, [5, 5]) // "hello" wins col 1, "Title" wins col 2
    }
}
```

- [ ] **Step 2: Run failing tests**

```bash
swift test --filter MarkdownTableTests
```

Expected: compile error.

- [ ] **Step 3: Implement**

```swift
// Scribe/UI/DesignSystem/MarkdownTable.swift
import Foundation

/// A detected markdown pipe table inside a source body. Line indexes are
/// 0-based into the array returned by `source.components(separatedBy: "\n")`.
struct DetectedMarkdownTable: Equatable {
    let headerRow: Int
    let separatorRow: Int
    let bodyRows: [Int]
    let columnCount: Int
    /// Max content character count per column across header + body rows.
    let columnWidths: [Int]
}

enum MarkdownTable {

    /// Returns every detected table block in source order.
    static func detect(in source: String) -> [DetectedMarkdownTable] {
        let lines = source.components(separatedBy: "\n")
        var result: [DetectedMarkdownTable] = []

        var i = 0
        while i < lines.count - 1 {
            let header = lines[i]
            let separator = lines[i + 1]
            guard isPipeRow(header), isSeparator(separator) else {
                i += 1
                continue
            }
            let headerCells = cells(in: header)
            let columnCount = headerCells.count

            var bodyRows: [Int] = []
            var j = i + 2
            while j < lines.count, isPipeRow(lines[j]), cells(in: lines[j]).count == columnCount {
                bodyRows.append(j)
                j += 1
            }

            // Column widths: max of (header cell text length, max body cell length per column).
            var widths = headerCells.map { $0.count }
            for row in bodyRows {
                let bodyCells = cells(in: lines[row])
                for (col, txt) in bodyCells.enumerated() where col < widths.count {
                    widths[col] = max(widths[col], txt.count)
                }
            }

            result.append(DetectedMarkdownTable(
                headerRow: i,
                separatorRow: i + 1,
                bodyRows: bodyRows,
                columnCount: columnCount,
                columnWidths: widths
            ))
            i = j
        }
        return result
    }

    private static func isPipeRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.filter({ $0 == "|" }).count >= 2
    }

    private static func isSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return false }
        let interior = trimmed.dropFirst().dropLast()
        return interior.allSatisfy { c in
            c == "-" || c == ":" || c == "|" || c == " " || c == "\t"
        } && interior.contains("-")
    }

    private static func cells(in line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let inner = trimmed.dropFirst().dropLast()
        return inner.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter MarkdownTableTests
```

Expected: 4/4 pass.

- [ ] **Step 5: Commit**

```bash
git add Scribe/UI/DesignSystem/MarkdownTable.swift ScribeTests/MarkdownTableTests.swift
git commit -m "feat(editor): MarkdownTable.detect — locate pipe-table blocks in source"
```

---

### Task D.2: Render tables with aligned columns

**Files:**
- Modify: `Scribe/UI/DesignSystem/MarkdownEditorView.swift`

- [ ] **Step 1: Add a table-render pass in `MarkdownFormatter`**

In `MarkdownFormatter.attributed(...)`, after the per-line attribute application but before returning, call:

```swift
        applyTableStyling(to: mutable, source: source, font: font)
```

Add the helper at file scope (inside `MarkdownFormatter`):

```swift
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

            // Separator row: visually hide by dimming + tracking it out into a thin rule.
            if table.separatorRow < lineRanges.count {
                let sepRange = lineRanges[table.separatorRow]
                if sepRange.location + sepRange.length <= attr.length {
                    attr.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: sepRange)
                    attr.addAttribute(.font, value: monoFont, range: sepRange)
                }
            }
        }
    }
```

This is a minimal implementation — it uses monospace font + paragraph tab stops so cells visually align. The cell text in source is still `| A | B |` with `|` characters visible; we're leaning on monospace alignment, not substituting characters.

- [ ] **Step 2: Build & smoke**

```bash
swift build
swift test 2>&1 | tail -3
```

Manual: type a markdown table in a note. Verify columns align under each other with consistent widths even when contents have different lengths.

- [ ] **Step 3: Commit**

```bash
git add Scribe/UI/DesignSystem/MarkdownEditorView.swift
git commit -m "feat(editor): render markdown tables with column-aligned cells"
```

---

### Task D.3: Toolbar button to insert starter table

**Files:**
- Modify: `Scribe/UI/Notes/FormatToolbar.swift`
- Modify: `Scribe/UI/DesignSystem/MarkdownEditorView.swift`

- [ ] **Step 1: Add `insertTable` to `EditorActions`**

```swift
@Observable
final class EditorActions {
    // … existing fields …
    var insertTable: (() -> Void)?
}
```

Add the button in `FormatToolbar`:

```swift
            ToolbarButton(systemImage: "tablecells", tooltip: "Insert Table") { actions.insertTable?() }
```

- [ ] **Step 2: Wire the action**

In `MarkdownEditorView.makeNSView` (where the other actions are wired):

```swift
        actions?.insertTable = { [weak coord] in coord?.insertTableTemplate() }
```

Add the method to `Coordinator`:

```swift
        func insertTableTemplate() {
            let template = "\n| Column 1 | Column 2 |\n|----------|----------|\n|          |          |\n"
            editSource { source, sel in
                let nsSource = source as NSString
                let new = nsSource.replacingCharacters(in: sel, with: template)
                let len = (template as NSString).length
                return (new, NSRange(location: sel.location + len, length: 0))
            }
        }
```

- [ ] **Step 3: Build & smoke**

```bash
swift build
swift test 2>&1 | tail -3
```

Manual: click the Insert Table button. Verify the 2×2 starter table renders with aligned columns.

- [ ] **Step 4: Commit**

```bash
git add Scribe/UI/Notes/FormatToolbar.swift \
        Scribe/UI/DesignSystem/MarkdownEditorView.swift
git commit -m "feat(editor): insert-table toolbar button"
```

---

### Slice D verification gate

```bash
swift test
```

Manual: type a table, verify alignment; insert via toolbar button; mix table + text + checklist + image in one note and confirm rendering.

---

## Final verification

After all four slices:

```bash
swift test
xcodegen
xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug build
```

All green. Manual:
- Checklists toggle on click; smart-Enter restarts unchecked.
- `⌘⇧U` inserts a checklist; toolbar button does the same.
- First H1 in body reads as a big title; subsequent H1s standard size.
- Blockquotes have an accent bar; code blocks have a subtle background fill.
- Dropping an image inserts a markdown link and renders the image inline.
- Deleting a note removes its attachments folder.
- Markdown tables render with column-aligned cells; insert-table button adds a 2×2 starter.

## Update PLAN.md

- [ ] Append to Phase 2 (Notes Obsidian replacement) area of `PLAN.md`:

```markdown
- [x] **Slice 15-rich-editor-p2 — Apple-Notes-feel editor (rich phase 2).**
      Interactive checklists (`- [ ] / - [x]`) rendered as tappable
      attachments; smart Enter on checked items restarts unchecked.
      Auto-title typography for first H1; bumped H2/H3 sizes; blockquote
      accent bar + code-block background fill. Image drag-drop into
      `~/Library/Application Support/Scribe/attachments/<noteId>/` with
      inline rendering via the existing fold mechanism; deleting a note
      cleans the attachments folder. Markdown pipe tables rendered with
      column-aligned cells; toolbar Insert-Table button.
```

- [ ] Commit:

```bash
git add PLAN.md
git commit -m "docs(plan): mark rich-editor phase 2 complete"
```

---

## Self-review checklist

- [ ] Every section in the spec maps to at least one task above.
- [ ] No `TBD` / `TODO` / "add validation" placeholders.
- [ ] Type consistency: `MarkdownNSTextView.listPrefix`, `MarkdownNSTextView.nextListPrefix`, `ChecklistToggle.toggle`, `ChecklistAttachmentCell`, `AttachmentsDirectory.directory/store/cleanup/StoredAttachment`, `ImageLoader.load`, `MarkdownTable.detect`, `DetectedMarkdownTable`, `applyTableStyling`, `EditorActions.checklist/insertTable`.
- [ ] `.checklistMarker` attribute key consistently used in Tasks A.3 and A.4.
- [ ] `FoldRegistry` doesn't need a "kind" tag — we route via the new `.checklistMarker` attribute on the click path (Task A.4).
- [ ] `noteId` plumbing in Task C.3 reaches `MarkdownNSTextView` and is checked before accepting drops.
- [ ] Migration: none required (no DB schema changes).
- [ ] Markdown remains the canonical persistence format throughout.
