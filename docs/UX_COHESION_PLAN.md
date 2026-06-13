# Scribe — UX Cohesion Plan

Turns the cohesion review (recording lifecycle, notes knowledge graph, tasks
surface, cross-cutting consistency) into a sequenced, slice-by-slice plan.
Builds directly on `docs/REDESIGN.md` (the Arc/Craft/IINA spine) — this is the
"make it feel like *one* product" follow-through, not a new direction.

## Status legend

- ☐ not started · ◐ in progress · ☑ done · ⊘ dropped/superseded

## Thesis

Scribe is three good apps (recorder · notebook · to-do) behind one switcher.
The architecture to unify them already exists (`Surface` / `MainSelection` /
`NavigationCoordinator` with real Back/Forward, ⌘K search, `TodayView`). The
work is almost entirely in the **UI/UX layer**: close the seams between
features, and make shared verbs (create, delete, error, empty, navigate)
behave identically everywhere.

## Working constraints

- **No local Swift toolchain in the web/dev container, and the app targets
  macOS 26 / Apple-only frameworks** — nothing here compiles locally. The
  GitHub Actions CI added in `.github/workflows/ci.yml` (compile + `swift test`
  on `macos-26`) is the real validator. Therefore: **every slice that has pure
  logic must ship a logic test**, because that is the only automated safety net
  available without a local build. UI-only slices get a manual QA checklist.
- One PR per Phase (or per Slice for the larger ones), each green on CI before
  merge. Keep slices independently shippable.

## Decisions made (2026-06-13)

Settled with the product owner; Phase E is now unblocked.

- **D-1 · Canonical day view → `TodayView` is home.** The two month-grid
  calendars (`NoteCalendarView`, `TaskCalendarView`) collapse into a single
  shared component scoped by content.
- **D-2 · "Today" placement → top-level, surface-agnostic.** Promote to a
  top-level entry independent of the Capture/Notes/Tasks switcher; drop the
  redundant `NotesFilter.today`.
- **D-3 · Graph & Task Calendar → sidebar "Views" group.** Out of the footer
  and into a labelled, discoverable group.
- **D-4 · Post-stop → smart affordance + conditional nav.** Show a transient
  "Recording saved · View →" affordance; auto-navigate to the transcript only
  when the user was on the now-empty live view, never stealing focus from a
  note being written.

---

## Phase A — Shared conventions (do first; unblocks everything) · M

Establish the cross-cutting vocabulary so later slices conform instead of
inventing. Small code, high leverage.

### Slice A1 — One feedback language ☐
- **Goal:** kill the three-dialect error problem (auto-dismiss banner vs
  blocking `.alert` vs persistent inline text).
- **Convention (document in code + here):**
  - *Transient / recoverable / background* → `ErrorBanner` via
    `AppState.lastError`. (recording, vault, autosave, mirror-to-disk,
    export failures)
  - *Blocking, user-must-decide* → `.alert` (rare: destructive confirms,
    "couldn't open database").
  - *Inline field-level validation* only where tied to a specific control
    (e.g. invalid recurrence string next to the field) — never as a substitute
    for surfacing a failure.
- **Approach:** add a tiny `Feedback` helper on `AppState`
  (`report(_:)` → sets `lastError`; `notify(_:)` → success toast) so callers
  stop hand-rolling. Migrate the loud offenders: note-save error
  (`NoteDetailView.swift:169` blocking alert → keep as alert only for true
  failures, otherwise banner), Settings vault inline red/green
  (`SettingsPanes.swift`) → route through the banner/toast.
- **Files:** `AppState.swift`, `ErrorBanner.swift`, `NoteDetailView.swift`,
  `TaskDetailPanel.swift:65`, `SettingsPanes.swift`.
- **Tests:** unit-test the policy mapping (error category → channel) as a pure
  function so CI covers it.
- **Risk:** Low. Mostly routing. Acceptance: a forced failure in each surface
  produces the *same* banner treatment.

### Slice A2 — Empty states everywhere ☐
- **Goal:** no blank dead-end screens; one component, one tone.
- **Approach:** make `NoteListView` (stop re-implementing — `NoteListView.swift:40`),
  `TaskListView`, and `GraphView` use `EmptyStateView`, each with a clear
  primary action ("Create your first note", "Add a task", "Link two notes to
  see your graph").
- **Files:** `EmptyStateView.swift` (verify action-button API), `NoteListView.swift`,
  `TaskListView.swift`, `GraphView.swift`.
- **Tests:** N/A (pure view); manual QA: each list empty shows guidance + CTA.
- **Risk:** Low.

---

## Phase B — Close the recording → transcript → task lifecycle · L  ← highest product value

The reason the app exists; today it loses the user at every handoff.

### Slice B1 — Don't abandon the user after Stop ☐  (decision D-4)
- **Goal:** after `stopSession()`, the finished recording is one obvious step
  away (or already shown), and the async summary/analysis arrival is signalled.
- **Approach:**
  - In `stopSession`, capture `finishedSessionId`; emit a completion signal
    (e.g. `AppState.lastFinishedSessionId` + a `.scribeSessionFinished` note).
  - `RecordingNavigationPolicy`: if the user is on `.live` (now empty), route to
    `.session(finishedSessionId)`. Otherwise (they were taking notes) show a
    transient "Recording saved · View →" affordance that deep-links to the
    session, without stealing focus.
  - When auto-summary/auto-analysis completes, surface a subtle "Summary ready"
    cue on the relevant note/session chip instead of silent background landing.
- **Files:** `AppState.swift:407–463`, `RecordingNavigationPolicy.swift`,
  `MainWindowView.swift` (onChange of finished id), `LiveSessionView.swift`,
  `NoteSessionAutoSection.swift`.
- **Tests:** extend `RecordingNavigationPolicyTests` — add the stop→destination
  cases (on-live vs on-note) so the policy is pinned, not implicit.
- **Risk:** Medium (navigation timing; the existing auto-create "flash" race
  lives next door — see B1.1).

### Slice B1.1 — De-fragilize the auto-create→navigate ordering ☐
- **Goal:** remove the implicit "post notification before flipping
  `isTranscribing`" contract that the policy test flags as a flash risk.
- **Approach:** make the navigate + state flip a single routed transition
  through `NavigationCoordinator.replaceCurrent` rather than racing a
  notification against an `onChange`.
- **Files:** `AppDelegate.swift:241–264`, `MainWindowView.swift`,
  `RecordingNavigationPolicy.swift`.
- **Tests:** policy test asserting no intermediate `.live` frame for the
  auto-create path. **Risk:** Medium.

### Slice B2 — Bidirectional, navigable task ↔ recording links ☐
- **Goal:** trace a task back to its meeting and see a meeting's spawned tasks.
- **Approach:**
  - `TaskDetailPanel` "From: ⟨meeting⟩" becomes a **button** → navigates to
    `.session(sourceSessionId)`; graceful "recording was deleted" state when the
    session is gone (orphaned `sourceSessionId`).
  - `TranscriptDetailView`: add a "Tasks from this recording" section, resolved
    via `sourceSessionId`. Already-converted action items show "Open task".
  - Extract a pure `LinkedTasksResolver` (sessionId → [TodoTask]) for testability.
- **Files:** `TaskDetailPanel.swift:61–64`, `TranscriptDetailView.swift`,
  `TranscriptDetailViewModel.swift`, `TaskStore.swift` (fetch by
  `sourceSessionId`), new `LinkedTasksResolver`.
- **Tests:** resolver unit tests (linked / none / orphaned). **Risk:** Medium.

### Slice B3 — Action-item → task keeps its context ☐
- **Goal:** converted tasks land in the meeting's project, not always Inbox.
- **Approach:** thread the source note's notebook/project (if any) and the
  session id through `ActionItemConverter.draft` so the task carries
  `projectId` + `sourceSessionId`.
- **Files:** `ActionItemConverter.swift:52–60`, `TranscriptDetailViewModel.swift`,
  `NoteSessionAutoSection.swift`.
- **Tests:** extend `ActionItemConverterTests` for project/source propagation.
  **Risk:** Low.

### Slice B4 — Live-view continuity cue ☐ (defer / optional)
- **Goal:** the three live renderings (`LiveSessionView`,
  `NoteLiveRecordingPane`, `LiveControllerOverlay`) read as one session.
- **Approach:** shared header ("Recording · 04:12") + a single "Expand / In note"
  toggle; align the in-note pane's listening-state with the full view.
- **Files:** the three live views; consider extracting a shared `LiveFeedHeader`.
  **Risk:** Medium. Lower priority than B1–B3.

---

## Phase C — Notes knowledge layer · M

Make the graph features feel first-class and trustworthy.

### Slice C1 — Note tags UI ☐  ← cheapest high-impact
- **Goal:** view + edit a note's tags from the editor (the data + sidebar
  already exist; the editor just doesn't expose it).
- **Approach:** add a `TagTokenField` (reuse the Tasks component) to the
  `NoteDetailView` header metadata row; wire to `vm.tags` + `vm.markDirty()`;
  autocomplete from `NoteStore.allNoteTags()`.
- **Files:** `NoteDetailView.swift:52–98`, `NoteDetailViewModel.swift`
  (already loads `tags`), `TagTokenField.swift` (confirm reusable outside Tasks).
- **Tests:** VM round-trip (set tags → save → reload). **Risk:** Low.

### Slice C2 — Broken wiki-links visible & detectable ☐
- **Goal:** links are visually distinct; renaming/deleting a target surfaces the
  break instead of silently dangling.
- **Approach:** style resolved vs unresolved `[[links]]` differently in the
  renderer; a pure `WikiLinkResolver` flags anchors with no matching title; a
  small "N unresolved links" affordance in the note (optional: a fix-up menu).
- **Files:** `MarkdownRenderer.swift`, `NoteStore.swift` (resolve pass, ~:300),
  new `WikiLinkResolver`.
- **Tests:** resolver unit tests (resolved/unresolved/case-insensitive).
  **Risk:** Medium (renderer is hot-path — keep styling additive).

### Slice C3 — Tag views are navigable ☐
- **Goal:** tasks listed under a tag are clickable (today they're inert `Text`).
- **Approach:** make `TaggedContentView` task rows buttons → `.task(id)`; add
  counts to the unified tag section.
- **Files:** `TaggedContentView.swift`. **Tests:** N/A; manual. **Risk:** Low.

---

## Phase D — Orientation & discoverability · M  (D-2/D-3 decisions)

### Slice D1 — Onboarding teaches the product, not just recording ☐
- **Goal:** new users learn Capture/Notes/Tasks + quick-add power.
- **Approach:** add a step previewing the three-surface switcher and "what lives
  where"; add a quick-add syntax hint (placeholder text + first-use coachmark)
  so `#tag +project !priority` + dates aren't hidden behind a popover.
- **Files:** `OnboardingView.swift` (Step model), `HighlightingQuickAddField.swift`
  (placeholder), `TaskListView.swift` (first-use hint). **Risk:** Low.

### Slice D2 — Promote Graph + Task Calendar ☐ (decision D-3)
- **Goal:** stop hiding primary features in the footer icon strip.
- **Approach:** add a sidebar "Views" group (Graph under Notes, Calendar under
  Tasks); keep footer for truly tertiary destinations or retire it.
- **Files:** `MainWindowView.swift:550–584`. **Risk:** Low.

### Slice D3 — Detail-pane context / breadcrumb ☐
- **Goal:** you always know where you are after a deep-link/⌘K jump.
- **Approach:** a subtle breadcrumb in note/task/transcript headers
  ("Notebook › Note", "Inbox › Task", "Recordings › Session"), derived from the
  current `MainSelection`.
- **Files:** detail headers + a small `Breadcrumb` view. **Risk:** Low.

---

## Phase E — Day-planning unification · L  (BLOCKED on D-1/D-2)

### Slice E1 — One day model, one calendar component ☐
- **Goal:** collapse the "three todays / three calendars" redundancy.
- **Approach (per D-1 default):** make `TodayView` the canonical home; extract a
  single shared month-grid calendar component parameterized by content
  (notes / tasks / both) so `NoteCalendarView` and `TaskCalendarView` stop
  diverging; share selected-date state so navigating a date is consistent
  everywhere; remove the redundant `NotesFilter.today` entry in favour of the
  promoted top-level Today.
- **Files:** `TodayView.swift`, `TaskCalendarView.swift`, `NoteCalendarView.swift`,
  `CalendarMonthGrid.swift`, `MainWindowView.swift` (selection model).
- **Tests:** date-filtering/bucketing logic (`.today` vs `.dueOn`) pinned.
  **Risk:** Medium–High (touches navigation model + two calendars). Do last.

---

## Sequencing & dependencies

```
A1, A2  ──►  B1 ─► B1.1 ─► B2 ─► B3     (B4 optional, anytime after B1)
                         │
C1 (independent, do early — cheapest win)
C2, C3 (after A2)
D1, D2, D3 (after A; D2 needs D-3 decision)
E1 (LAST — needs D-1 & D-2 decisions; biggest blast radius)
```

Recommended first PR: **A1 + A2 + C1 + B1** — establishes the conventions and
lands the two highest-impact, lowest-risk wins (note tags, post-stop nav).

## Effort / risk summary

| Phase | Slices | Effort | Risk | Notes |
|-------|--------|--------|------|-------|
| A | A1, A2 | M | Low | Conventions; unblocks all |
| B | B1, B1.1, B2, B3, (B4) | L | Med | Highest product value |
| C | C1, C2, C3 | M | Low–Med | C1 first (cheap) |
| D | D1, D2, D3 | M | Low | Needs D-3 decision for D2 |
| E | E1 | L | Med–High | Blocked on D-1/D-2; do last |

## Validation strategy (no local build)

1. **CI is the compiler.** Each PR must be green on `.github/workflows/ci.yml`
   (compile + `swift test` on `macos-26`) before merge.
2. **Logic-first.** Pull decision logic into pure, testable units
   (`LinkedTasksResolver`, `WikiLinkResolver`, feedback-policy mapping, calendar
   date-bucketing) and unit-test them — the only automated coverage achievable
   without a local build.
3. **Manual QA checklist per slice** (acceptance criteria above) for UI-only work.
4. Land behind no flags where safe; keep slices independently revertible.
