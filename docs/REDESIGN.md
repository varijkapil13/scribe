# Scribe Redesign Blueprint — IINA · Craft · Arc

> Goal: make Scribe **look and feel** like the best native-Mac craft apps — IINA's
> recessive glass chrome + floating controller, Craft's calm editorial writing surface
> + spatial card navigation, Arc's command-bar-and-sidebar-first navigation — while
> staying a first-class macOS citizen and being **accessible to everyone**: assistive-tech
> users (VoiceOver, Dynamic Type, Increase Contrast, Reduce Transparency, Reduce Motion)
> *and* power/normal users (keyboard-first, command palette, discoverability).
>
> This is a plan, not a spec to merge. It is the synthesis of a full UX audit of the
> current app, the design DNA of the three reference apps, ~70 concrete file-anchored
> proposals, an adversarial critique, and a sequenced roadmap.

---

## 1. The thesis

Scribe is already three good products fused into one window (transcription + Obsidian-style
notes + TickTick-style tasks) with a thoughtful "editorial minimalism" design system
(serif headlines, 4/8 spacing, semantic color). What it lacks is the **connective tissue**
the reference apps are famous for:

- **No spine.** Everything is one flat `NavigationSplitView` with 7 interleaved sidebar
  sections and imperative `selection = …` jumps. There's no sense of "which app am I in,"
  no back/forward, no command surface that *does* things.
- **No glass discipline.** Materials appear in ~4 ad-hoc places; chrome and content aren't
  separated; there's no floating recorder, no auto-hiding controller.
- **No motion vocabulary.** `Motion` is duration-only — zero springs, zero
  `matchedGeometry`, zero haptics. Reduce-Motion is honored in only 3 views;
  Reduce-Transparency / Increase-Contrast / Differentiate-Without-Color in **zero**.
- **Half-built keyboard/command layer.** `UniversalSearchView` (⌘⇧F) is a search-only
  dimmed-backdrop overlay that never auto-focuses, has no arrow traversal, and can't run
  a single action. There is essentially no menu-bar command tree.

The redesign is therefore mostly **additive and architectural**, not a rewrite. The
biggest perceived-quality jumps come from a small foundation (tokens + a11y substrate),
then a navigation spine + command bar, then surface-by-surface polish.

### What each reference contributes

| App | The transferable kernel for Scribe |
|-----|-----------------------------------|
| **IINA** | Glass-for-overlays discipline; a **floating auto-hiding live-recording controller**; a **menu-bar / PiP mini-recorder** so capture survives a hidden window; hover-scrub transcript timeline; "looks like Apple made it" native bar. |
| **Craft** | A **calm, centered, measured writing surface**; **slash `/` menu** + selection format bubble; **focus mode**; per-note typography (System/Serif/Mono); **card-style backlinks** + spatial card push/pop; spring micro-interactions. |
| **Arc** | **Command Bar (⌘K) that runs verbs, not just search**; sidebar-first IA grouped into **Spaces** with ⌘1/2/3; **collapse-to-focus** sidebar; spatial spring transitions between contexts; ephemeral **quick-capture** window; per-Space accent *on chrome only*; restrained personality. |
| **Native HIG + a11y** | Everything degrades: materials→solid under Reduce Transparency, springs→instant under Reduce Motion, hairlines→stronger under Increase Contrast, color→glyph under Differentiate-Without-Color; a real menu tree; scalable type; a proper `Settings {}` scene. |

### What to deliberately NOT copy

- **Arc's full-window gradient theming** and tab-strip sidebar — fights the editorial
  direction and `NavigationSplitView` semantics. Accent tints **chrome only**, never content.
- **Arc's "lose by default" auto-archiving** — notes/transcripts are permanent records.
  Ephemerality belongs to a *view* ("Today"), never the data.
- **Craft's opaque block database** — keep plain-markdown as the canonical source; "blocks"
  are a rendering/interaction concept only (the `FoldRegistry` + source-level undo depend on it).
- **IINA's media-centric defaults** — never pause capture on focus loss; never auto-hide the
  transcript itself (only the controller chrome); avoid Touch Bar / deprecated surfaces.
- **iOS-literal springs** — tune high-damping (~0.82) so motion reads crisp, not toy-bouncy.

---

## 2. Design principles (the spine everything hangs off)

1. **Glass floats, content is solid.** Vibrancy is reserved for transient chrome (command
   palette, floating recorder, inspectors, popovers). The note editor, transcript body, and
   task rows stay on opaque system surfaces. Every material has a Reduce-Transparency solid fallback.
2. **One command surface.** ⌘K is the single command bar (search nouns + run verbs). Every
   verb in it also lives in a real menu item. No surface invents its own ⌘K.
3. **Motion is feedback, gated centrally.** One `Motion.resolve(_:reduceMotion:)` helper; high
   damping; every spring/spatial transition degrades to a crossfade. Haptics where they confirm.
4. **Accessibility is the default path, not a mode.** The keyboard path and the VoiceOver path
   are the *same* path power users take. Color is never the only signal. Type scales.
5. **Editorial calm.** Centered measure, generous air, serif option, recessive chrome. Personality
   lives in copy and a few earned delight moments — not in chrome loudness.
6. **Additive over rewrite.** Reuse what's already excellent (daily-note strip, inline checkboxes,
   QuickAddParser, fan-out search VM, the AST renderer). Layer polish on top; don't regress it.

---

## 3. Current-state audit (condensed)

| Area | Strengths to preserve | Top pain points |
|------|----------------------|-----------------|
| **Navigation / IA** | Type-safe `MainSelection`; unified `TodayView` (note + tasks split); recording always reachable (pill + sidebar row). | 7 interleaved sections, no surface grouping; no back/forward; imperative `selection=` + NotificationCenter hops; `RecordingNavigationPolicy` is tested-but-dead code; Settings clobbers working context. |
| **Visual / Theming** | Real token system; editorial serif direction; semantic palette. | Materials in ~4 ad-hoc spots; depth faked with scattered `.opacity(0.06/0.08/0.12)`; fixed-point serif (no Dynamic Type); hardcoded `accentColor`, no themeable accent; **0 gradients, 0 Reduce-Transparency/Contrast handling**. |
| **Notes editor** | Source-canonical markdown; `FoldRegistry`; source-level undo; AST renderer; inline checkboxes; daily-note strip. | Full-bleed measure (120+ char lines); no slash menu; always-on top toolbar; no focus mode; serif identity never reaches the body; backlinks are thin chips; wiki-nav is an instant `.id` teleport. |
| **Tasks** | NL QuickAddParser; recurrence; reminders; FTS; drag-to-project. | **Three** editors for one entity; `TaskDetailPanel` Escape = silent discard (data-loss trap, despite an autosave VM); no inline editing; flat completion; keyboard shortcuts dead without a mouse-set focus; calendar hardcodes Sunday-first, no Today jump; `Project · <UUID>` leak. |
| **Search / Command / Keyboard / a11y** | Fan-out 3-store search VM; pure testable SectionBuilder. | ⌘⇧F overlay never auto-focuses, no arrow traversal, runs no actions; tasks route to `.tasks(.all)` (loses target); icon-only buttons rely on `.help()` (invisible to VoiceOver); almost no menu tree. |
| **Live recording / delight** | Pulsing record state; per-segment a11y labels; reduce-motion in `LiveSidebarRow`. | Recording trapped in one window (close = quit); no level meter (rawPeak is computed then thrown away); two divergent live feeds; transport is mouse-only; no onboarding; flat motion everywhere. |

---

## 4. Reference DNA → concrete Scribe moves

### IINA
- Floating, auto-hiding **glass Live Recording Controller** (capsule: timer · dual level meter ·
  pause · stop · expand), placement setting (floating / docked-bottom / docked-top), hysteresis
  on auto-hide, **never** hides the transcript, always visible under VoiceOver/Reduce-Motion.
- **MenuBarExtra mini-recorder** (the `MenuBarIconRecording`/`Paused` assets already exist) +
  optional **always-on-top PiP `NSPanel`** that joins all Spaces.
- **Hover-scrub transcript timeline** with speaker/chapter markers (the dropped signature — worth building).
- Glass-for-overlays, solid-for-content; system accent on the active waveform/scrub fill.

### Craft
- **Centered reading measure** (~680 Regular / ~920 Wide) + page-width toggle.
- **Slash `/` menu** at the caret (reuses the `[[`-detection + `EditorActions` plumbing).
- **Selection-anchored floating format bubble**, retiring the always-on toolbar (with an
  "always show" a11y fallback).
- **Focus / typewriter mode** reusing the renderer's existing per-block `scribeBlockId` /
  `revealedBlockId`.
- **Per-note typeface** System / **New York serif** / Mono.
- **Card-style backlinks** (grid) + inline wiki-link preview pills + hover-peek.
- Spatial **card push/pop** with breadcrumb for sub-note navigation.

### Arc
- **⌘K Command Bar** = the existing fan-out search **+ an Actions section** (Start/Stop Recording,
  New Note/Task via QuickAddParser, Go to surface, Open Settings…), context-aware ordering,
  shortcut hints on every row, fully arrow-navigable.
- Sidebar regrouped into **three Surfaces** (Capture / Notes / Tasks) with **⌘1/2/3**; optional
  user Spaces later; **collapse-to-focus** (⌃⌘S) + hover-peek.
- **Spatial spring transitions** when switching surfaces; per-Space **accent tint on chrome only**.
- **Quick-Capture** ephemeral `NSPanel` (Little Arc) writing straight to Inbox.
- Restrained personality in copy + a recording-saved celebration.

### Native + dual accessibility
- One `Motion.resolve` reduce-motion gate; `scribeGlass(role:)` material with solid fallback;
  contrast-aware `cardBorder`/`divider`; `@ScaledMetric`/relative serif type; non-color
  `SemanticStyle` (glyph) for priority/speaker/recording.
- Real **Commands** tree (File / Edit-undo / Recording / View / Go / Help); native **`Settings {}`** scene.
- VoiceOver labels on every icon-only control; decorative keycaps `.accessibilityHidden`.

---

## 5. Roadmap (sequenced)

Front-load shared dependencies + the biggest perceived-quality lever, then go surface by
surface, weaving delight + accessibility into **each** phase (not appended at the end).

### Phase 0 — Foundations & Safety Rails  ·  ~1.5–2 wk · M
Land the substrate every later phase consumes, and fix two architectural traps **before**
any feature writes to them.
- **Motion tokens:** `snappy`/`bouncy`/`gentle` springs (high damping) + `Motion.resolve(_:reduceMotion:)` + `.scribeAnimation(_:value:)`.
- **Material tokens:** `scribeGlass(role: .chrome/.sidebar/.hud)` → solid `surfaceElevated` under Reduce Transparency / Increase Contrast.
- **Palette:** contrast-aware `cardBorder`/`divider` (0.06→~0.20 under `.increased`); tonal `fill(.hover/.selected/.strong)` + `accentFill` to replace scattered opacity literals.
- **Typography:** re-express `display/title1/title2` as serif relative styles / `@ScaledMetric` (same look at default size, now scales).
- **Theming rail:** `@Environment(\.scribeAccent)` defaulting to `Color.accentColor`; swap chrome-only accent sites.
- **Non-color cues:** `SemanticStyle` (glyph/shape) for priority/speaker/recording.
- **🔒 SAFETY (blocking):** extend `NoteFrontmatterCodec` to **round-trip unknown keys** (else future `cover:`/`icon:`/`font:` are silently dropped) — unit test green.
- **🔒 SAFETY (blocking):** add write-debounce + **self-induced-reconcile suppression** to `VaultCoordinator`/`NoteVaultWatcher` (else per-keystroke autosave trips its own FSEvents watcher).
- **Files:** `DesignTokens.swift`, `NoteFrontmatterCodec.swift`, `VaultCoordinator.swift`, `NoteVaultWatcher.swift`, `RecordingStatusPill.swift`, `PriorityBadge.swift`, `HeroRecordButton.swift`.
- **Exit:** tokens exist + wired into the existing 3 reduce-motion views; default appearance byte-for-byte unchanged; codec round-trips an unknown key; scripted autosave triggers no self-reconcile. No new surfaces shipped.

### Phase 1 — Navigation Spine & Command Bar  ·  ~3–4 wk · L  ← biggest "feels like a new app" jump
- **`NavigationCoordinator`** (`@Observable`): `current` + back/forward stacks, `navigate/goBack/goForward`, ⌘[ / ⌘]. Route *all* sidebar selection, detail `onNavigate`, and the recording auto-flip through it — finally calling the dead-but-tested `RecordingNavigationPolicy`.
- **Surfaces:** `Surface` enum (Capture/Notes/Tasks) + top-of-sidebar segmented switcher + **⌘1/2/3**; regroup the 7 sections under surface ownership (NavigationSplitView stays — no tab-swapping). Add **`.session(id)`** (transcript archive) and **`.task(id)`** (deep-link) to `MainSelection`.
- **The ONE command palette:** rebuild `UniversalSearchView` → auto-focus, arrow traversal, Return-runs-highlighted, **⌘K** (⌘⇧F legacy alias one release), Actions section above content, context-aware ordering, glass backdrop with fallback. Rename VM to `CommandPalette*` over the existing pure SectionBuilder; fix the `.tasks(.all)` routing bug.
- **Native Settings scene** (`Settings {}`, ⌘,); remove `.settings` from `MainSelection` + the NotificationCenter plumbing; verify the close-quits guard still ignores the (differently-identified) Settings window.
- **Menu tree** (Go/File/Recording/View/Edit/Help) via a shared `AppCommandRouter` so menu ≡ palette; expose `MarkdownUndoBuffer` via `CommandGroup(.undoRedo)`; **⌃⌘S** sidebar collapse-to-focus (no peek yet).
- **Exit:** ⌘K creates a note/task + starts/stops recording, fully arrow-navigable, every row labeled + announces count; ⌘1/2/3 + ⌘[/] work; Settings is a native window; transcript reachable via `.session(id)`; **exactly one** command-bar implementation and one shortcut-allocation table in the repo.

### Phase 2 — Notes: Calm Writing & Spatial Browsing  ·  ~3–4 wk · L
- Centered measure + Regular/Wide toggle (do first — highest impact/effort).
- Slash `/` menu (reuse detection + `EditorActions`); selection format bubble (reuse `updateHoverOverlay` geometry); focus/typewriter mode (reuse `scribeBlockId`); per-note typeface (persisted via the Phase-0 frontmatter passthrough); card push/pop + breadcrumb + card backlinks + hover-peek (reuse `NavigationCoordinator`); optional page cover/icon (frontmatter, contrast-guaranteed scrim).
- GraphView: navigable node list for VoiceOver + static settled layout under Reduce Motion.
- **Exit:** measured column; keyboard-driven `/`; format bubble never traps caret; focus mode keeps active text ≥4.5:1; Serif persists *and survives an external Obsidian edit*; wiki-nav animates as reversible cards w/ breadcrumb + ⌘[; all transitions crossfade under Reduce Motion.

### Phase 3 — Tasks: One Inspector, Inline Editing, Drag-to-Schedule  ·  ~3 wk · L
- Unify on **one autosaving** `TaskDetailPanel`; **delete `TaskEditorView`**; kill the Escape-discard data-loss trap (flush on dismiss).
- Co-land **`.task(id)` deep-link with the keyboard-focus rework** so `focusedTaskId` has one owner (the critique's desync risk).
- Full keyboard nav (arrow/j-k focus, Enter/Space/⌘⌫, Tab, visible focus ring, composed labels).
- Delightful completion (spring check + settle + `sensoryFeedback`, reduce-motion gated).
- Inline due/priority/project + double-click title edit — **each with a context-menu keyboard equivalent**.
- Drag-to-schedule (bucket reschedule, in-bucket reorder, calendar-day drop) — **with keyboard equivalents incl. calendar-day**.
- Polish: locale `firstWeekday` + Today jump + week/agenda; tag token field + symbol-grid picker; persist per-filter collapse; fix `Project · <UUID>`; translucent inspector via Phase-0 glass.
- **Exit:** one editor; autosave with no data loss; palette deep-link + keyboard focus share one `focusedTaskId`; completion springs (instant+haptic under Reduce Motion); inline edits via hover **and** keyboard; calendar reschedule has a keyboard path; collapse persists; real project name.

### Phase 4 — Live Recording, Mini-Recorder & Multi-Window  ·  ~4–5 wk · XL · high-risk
- Publish smoothed **dual-source** level (mic + system audio) from the already-computed `rawPeak`; reusable `LevelMeterView` (a11y-hidden, static under Reduce Motion).
- Extract **one** `LiveTranscriptFeed` (compact/comfortable); commit a **non-color speaker cue** into the live feed; resolve the VoiceOver firehose with a **rate-limited live-region + "read latest" verb**, not per-segment spam.
- Floating auto-hiding **glass Live Controller** (hysteresis; never hides transcript; always-on under VO/Reduce-Motion/focus; placement setting).
- **Resolve multi-window/close-quits:** refactor `observeMainWindowClose` so a recorder surface can keep the app alive (`setActivationPolicy(.accessory)`), **opt-in** AppStorage flag; define key-window routing + persistence policy.
- **MenuBarExtra** mini-recorder; optional **PiP `NSPanel`** with **solved** keyboard/VoiceOver reachability (becomes key on demand; Stop also on global hotkey + menu).
- Live transport shortcuts (Space=pause, ⌘.=stop) scoped to the live view; confident persistent Record CTA w/ non-color state; first-run onboarding (primes mic + *defines when* ScreenCaptureKit is relevant + previews model download).
- **Exit:** dual-source meter + shared feed w/ non-color speaker cue; controller auto-hides safely; closing the window with a recorder enabled keeps recording; Stop reachable by keyboard/VO from PiP; onboarding primes in context; restoration policy documented.

### Phase 5 — Intelligence, Transcript Archive, Export & Cross-Cutting Polish  ·  ~4–6 wk · XL (backlog, prioritize)
Absorbs the **two biggest uncovered surfaces** the critique flagged — they're arguably the
product's hero value, last only because they depend on Phase-1 routes + Phase-4 surfaces.
- **Transcript/session archive:** browsable/searchable Sessions library via Capture + `.session(id)`; extend `EmptyStateView`/`ErrorBanner`.
- **AI/intelligence UX:** streaming-token/shimmer reveal + retry/error states for `MeetingSummarizer`/`TranscriptAnalyzer`; graceful **FoundationModels-unavailable** state; VoiceOver/keyboard-navigable summaries/action-items/insights (audit the underlined tab bar).
- **Unify search:** reconcile the FTS palette with the semantic `SmartSearchEngine` into **one** "ask/find" surface with scope chips (not two parallel systems).
- **Export/share:** right-side slide-in inspector (IINA pattern) over `ExportManager`; surface **MCP** vault-mutation activity, reconciled with autosave/card-nav.
- **Delight finish:** recording stop→**saved celebration**; **hover-scrub transcript timeline** w/ speaker/chapter markers; spring/matchedGeometry for DailyNote week↔month + Record→Live morph.
- **a11y close-out:** wire an **NSTextView Dynamic-Type scale factor** into `MarkdownTheme` (the known-unsolved hole — the editor is where users live); finish icon-label pass; **accessible conflict-resolution** flow for `NoteConflictDetector` with a VoiceOver announcement when the vault changes under an open note.

---

## 6. Quick-win starter kit (highest impact-per-effort; can land inside Phase 0/1)

1. **Motion tokens + `Motion.resolve(reduceMotion:)`** — S; unblocks everything; one reduce-motion gate.
2. **⌘K + auto-focus the palette field** (`@FocusState` + `.onAppear`) — the most jarring current defect; one-liner.
3. **Contrast-aware `cardBorder`** (0.06→~0.20 under `.increased`) — fixes washed-out dark-mode hairlines app-wide.
4. **Serif headlines → relative styles** (`Font.system(.largeTitle, design: .serif)`) — Larger Text finally works, zero layout change.
5. **`.accessibilityLabel` on the 4 footer icons + sidebar +/pencil** — they're invisible to VoiceOver today.
6. **Fix the `.tasks(.all)` routing bug** — found tasks land in the right place.
7. **Wrap `toggleCompleted` in `withAnimation(.snappy)` + `symbolEffect(.bounce)` + `sensoryFeedback(.success)`** — instant tactile delight, reduce-motion safe.
8. **Forward mic `rawPeak` → smoothed `inputLevel`** — the cheapest unlock for every level meter.
9. **Gradient + edge highlight on `HeroRecordButton`** — flat capsule → physical glass pill (gated under Reduce Transparency).
10. **Rename `TaskDetailPanel` "Close (discard changes)" → "Close"** + Escape just dismisses — removes a real data-loss trap (the VM already autosaves).

---

## 7. Risks, conflicts & mitigations

1. **Three competing "command bar" designs** (IA's coordinator-routed, Command-System's registry, Notes' own ⌘K, Live's verbs) touch the same files. → **Phase 1 owns ONE palette** end-to-end; all surfaces contribute action rows to one `CommandRegistry`; ratify a single **shortcut-allocation table** before any Phase-1 palette code merges.
2. **Autosave-everywhere vs the live vault watcher**, and **frontmatter keys silently dropped** by the fixed codec. → Both fixed in **Phase 0 as blocking exit criteria** (write-debounce + self-reconcile suppression; codec unknown-key passthrough + round-trip test). No autosave/frontmatter feature merges until green.
3. **Multi-window additions vs `observeMainWindowClose`** (terminates on `main` close). → Settings scene (Phase 1) is safe (different identifier); defer the actual keep-alive/`setActivationPolicy` refactor to **Phase 4**, one owner, **opt-in** flag, key-window routing defined.
4. **Split View aliasing** (two panes on shared singletons + one `focusedTaskId`). → **De-scope Split View off the critical path**; gate on a per-pane focus model owned by the coordinator. In Tasks, **never** ship `.task(id)` and the keyboard model in separate releases.
5. **Archive + AI under-scoped** (the actual hero value) and **two parallel search systems**. → Phase 5 is explicitly XL/backlog; de-risk early by adding `.session(id)` in Phase 1 and folding semantic search **into** the one palette (scope chips), not a second surface.
6. **Visual drift toward the Arc look it rejected** + **shortcut-chord collisions**. → Gradients/edge-highlights opt-in, decorative-only, dropped under Increase Contrast/Reduce Transparency; per-Space accent tints **chrome only**; publish the shortcut table (⌘K palette · ⌘1/2/3 surfaces · ⌘[/] history · ⌃⌘S sidebar · focus mode = a non-reserved chord); every new binding registers against it.

---

## 8. Decisions to lock before/early in implementation

1. **Command bar reconciliation** → **Single palette** (one `CommandPaletteViewModel` + one `CommandRegistry` on ⌘K; surfaces contribute rows; no per-surface ⌘K).
2. **Settings** → **Native `Settings {}` scene** (HIG-correct; close-quits guard is safe; stops clobbering working context).
3. **Keep-alive when the main window closes** → **Opt-in AppStorage flag, default = today's close-quits**; keep-alive only when the flag is on AND a recorder surface is enabled + a session is live.
4. **Per-note typeface / cover / icon persistence** → **Frontmatter, gated on the Phase-0 unknown-key passthrough** (keeps `.md` canonical + Obsidian-compatible); if passthrough slips, store app-side rather than ship silent data loss.
5. **Live transcript for VoiceOver** → **Rate-limited live-region + a "read latest" command** (not per-segment spam, not silence); decide cadence in Phase 4 when the feed is unified.
6. **Archive + AI scope** → **Full hero treatment as an explicit XL Phase 5**, de-risked from Phase 1 (`.session(id)` route + unified search-from-the-start).

---

## 9. Proposal catalog (file-anchored, by area)

> Effort S/M/L/XL · Risk low/med/high. Full rationale + implementation sketch per proposal lives
> in the workflow output; this is the index.

### Visual Language & Theming
- **Material token layer** w/ Reduce-Transparency fallback (`scribeGlass(.chrome/.sidebar/.hud)`) — M/low — `DesignTokens.swift`, `MainWindowView.swift`, `UniversalSearchView.swift`, `FormatToolbar.swift`.
- **Theme model**: user accent + per-Space accent, **chrome-tint only** — L/med — reuses `Project.color` + `Color(hex:)`.
- **Dynamic-Type serif scale** (`@ScaledMetric`/relative styles) — M/med.
- **Per-note typeface** System/Serif/Mono via existing `MarkdownEditorView.font` param — M/med.
- **Spring motion tokens** + reduce-motion gate — S/low (foundational).
- **Tonal neutral + accent ramps** replacing ad-hoc opacity; contrast-aware borders — M/low.
- **Window shell** art-direction: unified translucent toolbar + inset rounded content — M/med.
- **Edge-highlight + gradient depth** on floating surfaces + record button — S/low.
- **Shape/glyph state encoding** (Differentiate-Without-Color) for priority/speaker/recording — S/low.

### Information Architecture & Navigation
- **`NavigationCoordinator`** w/ back/forward, retiring imperative `selection=`/NotificationCenter hops — M/med.
- **Three Surfaces** + ⌘1/2/3 + top switcher; add `.session(id)` route — L/med.
- **⌘K Command Bar that runs verbs** (focus-managed) — L/med.
- **Native Settings scene** — M/med.
- **Collapse-to-focus** sidebar (⌃⌘S) + hover-peek — S/low.
- **Spatial card push/pop** + breadcrumb + hover-peek for notes — L/med.
- **Split View** (de-scoped to optional) — L/med.
- **macOS menu command tree** — M/low.

### Command System & Keyboard-First UX
- **`CommandPaletteViewModel` + unified `CommandItem`** (search + actions) — L/med.
- **Full keyboard nav** (one `@FocusState`, arrow traversal, Cmd-digit quick-pick) — M/low.
- **⌘K rebind + menu tree** — M/low.
- **`.task(id)` routing + ranking** — M/med.
- **Type-to-create from palette** via `QuickAddParser` — M/med.
- **Context-aware palette** + Reduce-Transparency/Motion — S/low.
- **Live transport shortcuts + shortcut cheat-sheet** — M/low.

### Notes Editor & Reading Experience
- **Centered measure + Regular/Wide** — S/low.
- **Slash `/` menu** at caret — M/med.
- **Selection format bubble** (retire top toolbar) — M/med.
- **Focus / typewriter mode** (reuse block ids) — M/med.
- **Card backlinks + inline wiki pills + hover-peek** — M/med.
- **Spatial card push/pop + breadcrumb** — L/med.
- **Per-note typeface** — M/low.
- **Page cover + icon** (frontmatter) — L/med.
- **Spring tokens + a11y gates for editor chrome** — S/low.

### Tasks Experience
- **Collapse 3 editors → one autosaving inspector** (delete `TaskEditorView`; kill data-loss trap) — M/med.
- **Inline in-row editing** (due/priority/project/title) — L/med.
- **Delightful completion** (spring + settle + haptic, reduce-motion gated) — M/low.
- **Full keyboard list nav** — M/med.
- **Drag-to-schedule everywhere** (+ keyboard equivalents) — L/med.
- **Calendar polish** (locale week start, Today, week/agenda, day deep-link) — L/low.
- **Tag token field + project symbol picker** — M/low.
- **Translucent inspector + focus-expand quick-add** — S/low.
- **Persist per-filter collapse + fix UUID header** — S/low.

### Live Recording, Transcription & Mini-Player
- **Publish smoothed audio level** (the missing "I can hear you") — M/low.
- **Extract one `LiveTranscriptFeed`** — M/low.
- **Floating auto-hiding glass controller** — L/med.
- **MenuBarExtra mini-recorder** — L/med.
- **PiP always-on-top `NSPanel`** across Spaces — XL/high.
- **Transport shortcuts + Recording menu** — M/low.
- **Spring shared-element Record→Live morph + haptics** — M/med.
- **Persistent confident Record CTA + non-color state** — S/low.

### Motion, Micro-interactions & Delight
- **Spring + reduce-motion tokens** (foundation) — S/low.
- **Task completion delight** — M/med.
- **Spatial surface-switch transitions** (Arc Space-switch) — M/med.
- **Craft card push/pop w/ matchedGeometry** — L/med.
- **Recording transport feedback + morph** — L/med.
- **Live audio-level waveform** — M/med.
- **First-run onboarding** w/ in-context permission priming — L/low.
- **Streaming transcript segment entrance** — S/low.

### Accessibility (Dual: Assistive + Power-User)
- **Centralize a11y-environment handling** in DesignTokens (motion/transparency/contrast/differentiate) — M/low.
- **Real Commands menu tree** — M/med.
- **Command Palette focus-trap + arrow-nav + announced counts** — L/med.
- **Dynamic-Type type scale** (`@ScaledMetric`/relative) — L/med.
- **Keyboard-first task list + autosaving inspector** — L/med.
- **VoiceOver labels for icon-only chrome + non-color cues** — S/low.
- **GraphView accessible + motion-aware** — M/med.
- **Live recording keyboard transport + accessible feedback** — M/med.

---

## 10. Open product surfaces the original areas under-scoped (from the critique)

These are **not optional** — several are core value:
- **Transcript/session archive** — there is no `.session(id)` route or browse/search UX for past meetings (the core artifact of a transcription app).
- **AI/intelligence UX** — summary/insights generation states, FoundationModels-unavailable handling, and reconciling the **two** search systems (FTS palette vs semantic `SmartSearchEngine`).
- **File-vault reality** — external-edit reconcile mid-edit, the deferred **conflict-resolution** flow (`NoteConflictDetector`), vault busy/error surfacing.
- **Dual-source audio** — metering/visualizing *you* vs *remote*, and *when* ScreenCaptureKit permission is relevant.
- **Export/share** UX; **MCP** activity legibility; **multi-window/state-restoration** semantics once scenes are added; an **empty/error/loading** state system for all new surfaces.
- **Missing delight to design in:** AI summary streaming reveal; recording-saved celebration; hover-scrub timeline; Little-Arc quick-capture; editable speaker identity; URL→rich-link card; daily-note spring.

---

*Generated from a full codebase UX audit + IINA/Craft/Arc/native-HIG DNA distillation +
8-area proposal pass + adversarial critique + roadmap synthesis.*
