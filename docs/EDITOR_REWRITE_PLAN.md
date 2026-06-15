# Editor Rewrite Plan

Status: **in progress** — Step 1 (foundation) landing in this PR.

## Decision

Replace Scribe's home-grown Markdown editor (`MarkdownEditorView`,
`MarkdownRenderer`, and the bespoke styling/parse stack) with the native,
actively-maintained **[CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor)**
engine (MIT, macOS 13+, TextKit 2, tree-sitter).

- **Why native:** the current editor reimplements text layout, syntax styling,
  folding, and live-preview by hand on top of `NSTextView`/TextKit. It is
  expensive to maintain and lags behind AppKit text features. CodeEditSourceEditor
  gives us a TextKit 2 view, tree-sitter highlighting, find/replace, a gutter,
  and code-completion hooks out of the box.
- **Strategy: replace-in-place.** We do *not* fork or vendor. We add the SPM
  dependency, build a Scribe-flavoured wrapper, reach feature parity behind the
  wrapper, then swap `NoteEditorView`'s text surface over in one cut and delete
  the old stack. The wrapper isolates Scribe from upstream API churn (the 0.15.x
  line changed the SwiftUI initializer significantly).
- **Pinned version:** `0.15.2` (exact). Transitive deps resolve via SPM:
  CodeEditTextView, CodeEditLanguages, CodeEditSymbols, TextFormation,
  swift-custom-dump, SwiftLintPlugin.
- **CI is the only compiler.** No local toolchain; every step is verified on the
  GitHub Actions `macos-26` runner. Each PR must compile there, and from Step 2
  onward each PR carries a CI screenshot for visual verification.

## Feature-parity matrix (current editor → CodeEditSourceEditor wrapper)

| Capability | Current editor | Target plan |
| --- | --- | --- |
| Live-preview Markdown styling | Custom TextKit attribute styling | tree-sitter Markdown highlighting + Scribe theme; live-preview decorations via a `TextViewCoordinator` |
| Headings / bold / italic / code / quotes | Yes | Theme `Attribute` styling + decoration coordinator |
| Callouts (`> [!note]`) | Yes (custom) | Decoration coordinator over blockquote nodes |
| Lists / checklists | Yes | tree-sitter list nodes; interactive checkbox toggles via coordinator |
| Tables | Yes | Rendered-table decoration; raw-edit fallback |
| Wiki-links `[[…]]` + navigation | Yes (custom link layer) | Link decoration + click handling through coordinator → existing navigation |
| Slash commands | `SlashCommandMenu` | Reuse `SlashCommandMenu` driven off the new editor's cursor/insertion API |
| Image embeds | Yes | Inline attachment decoration |
| Mermaid + PlantUML | Yes, via `DiagramRenderer` (WKWebView, off-screen) | **Reuse the existing `DiagramRenderer` unchanged**; fold fenced blocks and swap in rendered `NSImage` via coordinator |
| Math | — (new) | KaTeX/MathJax render reusing the `DiagramRenderer` WKWebView pattern |
| Footnotes | — (new) | tree-sitter footnote nodes + jump-to-definition |
| Note properties ("Bases") | — (new) | YAML frontmatter → typed properties + saved table/board/card views |

## Obsidian-"Bases" feature

Layer structured **note properties** over the existing YAML frontmatter, then
saved views over the property set:

1. Parse/serialize frontmatter into a typed property model (string, number,
   date, list, checkbox, select).
2. A property editor pane at the top of the note.
3. Saved **views** across notes: **table**, **board** (kanban by a select
   property), and **card** views, with filters/sort over properties. Reuses the
   notes query layer (GRDB) for backing data.

## Task-filter fix

Separate, scoped fix carried alongside the rewrite (not part of the editor
swap): correct the task list/calendar filter behaviour in `TaskListViewModel`
/ `TaskCalendarViewModel`. Sequenced as its own PR so it can ship independently.

## CI-screenshot verification loop

From Step 2 onward, each PR:

1. Builds on `macos-26` (XcodeGen → `xcodebuild`).
2. Launches the app / a hosting harness and captures a screenshot of the editor
   surface as a CI artifact.
3. The screenshot is attached to the PR for visual review of styling parity —
   the guard against silent visual regressions during the swap.

## Sequenced PRs

1. **Foundation (this PR).** Add `CodeEditSourceEditor` 0.15.2 to `project.yml`
   (macOS `Scribe` target only). Add `CodeEditNoteTextView` — a self-contained
   wrapper (Markdown language, line wrapping, app body font, design-token
   theme) with a `#Preview`. Add this plan. No behaviour change; proves SPM
   resolution + compile on CI.
2. **Wrapper hardening + CI screenshot loop.** Light/dark design-token theme,
   establish the screenshot artifact pipeline.
3. **Wire into `NoteEditorView` behind a flag.** New editor selectable; old
   editor remains default.
4. **Core Markdown parity.** Headings, emphasis, code, quotes, callouts, lists,
   checklists, tables via decoration coordinator.
5. **Links + commands.** Wiki-links + navigation, slash commands, image embeds.
6. **Diagrams + math + footnotes.** Reuse `DiagramRenderer` for Mermaid/PlantUML;
   add math and footnotes.
7. **Flip the default & delete the old stack.** Remove `MarkdownEditorView` /
   `MarkdownRenderer` and dead code.
8. **Bases.** Note properties over frontmatter + saved table/board/card views.
9. **Task-filter fix.** Independent, can land anytime.
