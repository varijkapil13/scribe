# Scribe iOS / iPadOS — Implementation Plan

**Companion to** `docs/MULTIPLATFORM-SCOPING.md` (the *why* / feasibility). This doc is the *how* — the executable plan, the current status, the `ScribeCore` extraction manifest, and a measured cost calibration.

**Product frame (locked):** iOS/iPadOS Scribe is the **notes + tasks** half of the app (Craft × TickTick). **Recording/transcription is macOS-only** and is never compiled into the iOS target. macOS keeps its recording-forward UI unchanged.

---

## 0. Status — what's done (this session)

**Milestone 0 is split into 0a (foundation, DONE) and 0b (`ScribeCore` extraction, NEXT).**

### M0a — multiplatform project foundation ✅ (committed)
- `project.yml`: added `iOS: "18.0"` deployment target and a new **`ScribeiOS`** iOS/iPadOS app target (`TARGETED_DEVICE_FAMILY "1,2"`, generated Info.plist, no audio/recording packages) + its scheme. The macOS `Scribe` target and `ScribeUITests` are untouched.
- `ScribeiOS/ScribeiOSApp.swift`: a standalone SwiftUI `@main` stub (placeholder UI) so the iOS target compiles/links today, ahead of the real UI in M1. **No** audio / ScreenCaptureKit / KeyboardShortcuts.
- `Scribe/UI/DesignSystem/PlatformAliases.swift`: `PlatformColor` / `PlatformFont` / `PlatformImage` typealias shim (AppKit on macOS, UIKit on iOS) — groundwork for the renderer port.

**Decision:** iOS deployment target is **18.0, not 26.0.** The scoping doc's "iOS 26 for SpeechAnalyzer" floor is moot because iOS has no transcription. 18.0 maximizes device reach, supports all shared code (`@Observable`, Swift 6 concurrency, TextKit 2), and runs on the locally-installed 18.5 simulator.

**Verification (this machine):**
| Check | Result |
|---|---|
| `xcodegen generate` | ok |
| macOS app build (`Scribe`) | **BUILD SUCCEEDED** |
| Logic suite (`swift test`) | **525 / 0** |
| iOS sources type-check (`swiftc -typecheck` vs iphonesimulator26.5 SDK, iOS 18 triple) | **clean** (app stub + shim UIKit branch) |
| Full iOS `xcodebuild` | **blocked by environment** — iOS 26.5 platform/runtime not installed (Xcode › Settings › Components). Config is correct; install the iOS platform or a sim runtime to build/run locally. |

**Environment prerequisite for all iOS work:** install the iOS platform support — Xcode › Settings › Components › iOS 26.5 (or any iOS 18+ simulator runtime). Until then `xcodebuild` finds no eligible iOS destination, though sources type-check fine.

---

## M0b — `ScribeCore` shared package (NEXT — the larger half of M0)

Extract the portable logic into a Swift package both apps link. This is the high-churn step deliberately **not** auto-run unattended (it leaves the build red mid-flight); do it in reviewed increments, macOS staying green after each.

### The cost driver: the `public` access-control tax
Moving code into a separate module makes every cross-module reference fail until annotated `public`. The Storage layer is referenced by ~74 UI files, so the Storage move alone adds `import ScribeCore` to dozens of files and `public` to hundreds of declarations. **Extract leaf-first, in dependency order, building macOS green after each slice** rather than all at once.

### Extraction manifest (dependency order; build macOS after each tier)
1. **Pure leaves first** (smallest blast radius, already unit-tested):
   - `Scribe/UI/DesignSystem/FoldRegistry.swift` (FoldRegistryTests)
   - `Scribe/UI/DesignSystem/MarkdownUndoBuffer.swift` (MarkdownUndoBufferTests)
   - inline-format / checklist / list-prefix logic (InlineFormatTests, ChecklistToggleTests)
   - the `PlatformAliases.swift` shim (move it into the package so both platforms use it)
2. **Markdown render logic** — the AST walk + SourceMap + autolink + marker-reveal from `MarkdownRenderer.swift` (MarkdownRendererTests). Split platform-bound font/color out behind the shim + a theme protocol; keep the parse/layout logic in the package.
3. **Models + storage** — `Note.swift`, `NoteFile.swift`, `TodoTask.swift`, `NoteFrontmatterCodec.swift`, then `DatabaseManager.swift`, `NoteStore.swift`, `TaskStore.swift`, `TranscriptStore.swift` (their *_Tests come along). GRDB is the only dependency; it's iOS-ready. **This is the widest-blast-radius tier** — budget the most build-fix cycles here.
4. **Navigation + command model** — `NavigationCoordinator.swift`, `CommandRegistry.swift`, `CommandItem.swift` (pure `@Observable`/value types).
5. **Vault reconcile logic** — `NoteIndexReconciler.swift`, `NoteConflictDetector.swift`, `VaultWriteGuard.swift` (the *access bracketing* stays platform-specific — see M1 storage).

### Manifest mechanics
- Create `ScribeCore/` as a local SwiftPM package (`Sources/ScribeCore`, `Tests/ScribeCoreTests`); move the matching `ScribeTests` files in with their subjects.
- Update **both** manifests: `Package.swift` (new `ScribeCore` library target; `Scribe` + `ScribeTests` depend on it) and `project.yml` (add the local package; macOS `Scribe` and iOS `ScribeiOS` both depend on `ScribeCore`; `ScribeiOS` also gets GRDB + swift-markdown but **not** KeyboardShortcuts).
- **Exit criteria:** macOS app builds + 525 tests green; `ScribeCore` builds for **both** macOS and iOS; `ScribeiOS` links `ScribeCore`.

---

## M1 — Tasks + Notes client with sync · est. ~2–3 wk (human)

The first shippable TestFlight build, and already the core product.
- **iOS app shell:** `UIApplicationDelegateAdaptor`/SwiftUI lifecycle; iPhone bottom `TabView` (Notes / Tasks); iPad `NavigationSplitView`. Replace the stub.
- **Tasks: full parity** — lists, due dates, priorities, subtasks, projects, pins, batch ops, calendar (the task layer is highly portable; ship it first).
- **Notes: browse / organize / search** + a **baseline SwiftUI editor** (`TextEditor`/`AttributedString`) — usable create/edit; the rich editor is M2.
- **Sync + vault:** pin the vault to the app-container `Documents` (+ iCloud Documents container) — sidesteps security-scoped bookmarks for MVP. Rewrite `NoteVaultWatcher` off FSEvents → `DispatchSource` / `NSMetadataQuery` behind a `VaultChangeObserving` protocol; re-tune `VaultWriteGuard` for the new observer latency; reconcile on launch + `scenePhase`.
- Command palette as a `.sheet`; settings as an in-app screen; permissions/errors as SwiftUI alerts.
- **Exit:** notes + tasks created on either platform sync live; full task management + competent note editing on iPhone/iPad.

## M2 — Best-in-class notes editor (the headline, the long pole) · est. ~3–5 wk

Now **core**, not a deferral.
- Rewrite the editor on `UITextView` + **TextKit 2**: decorations as layout-fragment overlays (`drawBackground` has no UIKit seam), checkbox as a `UIImage` `NSTextAttachment` (no `NSTextAttachmentCell` on UIKit), `UIKeyCommand`/gesture responder model, drop interaction, placeholder overlay.
- **Profile typing latency early** — the per-keystroke full-`NSTextStorage` rebuild is the main perf risk on mobile; incrementalize if needed.
- Reauthor the quick-add task fields (or replace with SwiftUI native); host `DiagramRenderer`'s WKWebView on iOS; image attachments.
- **Exit:** iOS note editing matches the Mac's decoration richness and feels Craft-grade.

## M3 — iPad-grade polish · est. ~1–2 wk
- External-keyboard shortcut layer (`.keyboardShortcut`: ⌘K/⌘N/⌘1–3/⌘B/⌘I).
- Apple Pencil / Scribble text entry into notes.
- Multitasking / Stage Manager sizing; drag-and-drop between notes and tasks.

## Deferred / out of scope
- Arbitrary external Obsidian vault (UIDocumentPicker + security-scoped bookmarks + NSFileCoordinator) — container/iCloud pinning covers MVP.
- Read-only transcript viewing on iOS — essentially free once the vault syncs (Mac transcripts are notes); surface if wanted, no audio code.
- FoundationModels summarization on iOS — device-gated, on-demand, not core.
- **Recording on iOS — explicitly out of scope per product direction.**

---

## Cost calibration (M0a, measured)

**Honest caveat:** exact main-loop token accounting is not exposed to me mid-session, so totals below mix *measured* sub-task numbers with *reasoned* estimates. Treat token figures as order-of-magnitude.

**Measured anchors this session:**
- Read-only scoping workflow (8 scouts + synthesis, 9 agents): **568K tokens**, ~6.5 min wall.
- Test-infra build agent (5 files, build-for-testing): **127K tokens**, ~9.5 min wall.
- M0a foundation (this slice): a handful of file reads, ~8 edits/writes, ~6 build/verify cycles. Build timings: xcodegen 0.1s; macOS incremental build ~8s; `swift test` ~5s run; iOS type-check seconds. Estimated main-loop spend on the order of **a few hundred K tokens**; elapsed wall ~minutes of active work.

**Refined full-migration estimate (M0b → M3):**
| Milestone | Tokens (range) | Elapsed (with review/testing) |
|---|---|---|
| M0b `ScribeCore` extraction | 1–3M | ~2–4 days |
| M1 Tasks+Notes+Sync | 4–8M | ~1–2 weeks |
| M2 Editor (long pole) | 5–12M | ~2–4 weeks |
| M3 iPad polish | 1.5–4M | ~1 week |
| **Total** | **≈ 12–27M tokens** | **≈ 1.5–2 months** |

**What inflates it:** M2 editor perf may force an incrementalization redesign; iCloud sync is iteration-heavy; **I cannot fully verify iOS UX autonomously** (no screen capture / simulator-touch driving — same wall as the macOS visual pass), so M1–M3 need you in the loop running the sim/device, which dominates elapsed time. **What contains it:** storage/tasks/navigation/markdown core is already pure + unit-tested, so it ports cheaply and regressions are caught by the existing 525-test suite.
