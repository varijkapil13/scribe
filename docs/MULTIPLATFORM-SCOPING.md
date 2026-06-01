# Scribe → iPhone + iPad: Multiplatform Porting Scoping Document

**Status:** Feasibility / scoping only — not an implementation plan
**Subject:** Shipping Scribe on iPhone + iPad as a **notes + tasks app** (Craft × TickTick fusion). Recording/transcription is a Mac-only feature and is **excluded from iOS**.
**Date:** 2026-06-01 · **Revised** 2026-06-01 — product reframed: notes+tasks is the headline; no recording on iOS

---

## 1. Executive feasibility verdict

### Product framing (updated 2026-06-01)

Scribe's headline is **the best notes + tasks fusion** — Craft-grade writing × TickTick-grade task management in one app. **Recording/transcription is a secondary, macOS-only feature, not the headline**, and **the iPhone/iPad apps ship with no recording at all.**

This reframing **removes the only fundamental blocker** the original audit found. The "iOS cannot capture system/other-app audio" limitation is real, but it now only constrains a feature iOS deliberately does not ship. It is no longer a strategic obstacle — it is simply a `#if os(macOS)` boundary around code iOS never runs.

### What the iOS/iPadOS app IS

A **first-class notes + tasks client** that syncs with the Mac:
- The full **markdown notes** experience (the Craft half): browse, organize, search, and edit the vault.
- The full **tasks** experience (the TickTick half): lists, due dates, priorities, subtasks, projects, pins, batch ops, calendar.
- **Sync** of the vault + tasks DB with the Mac, so the same content is live on every device.
- **Bonus, not core:** transcripts captured on the Mac can appear as read-only notes via the synced vault — no recording or audio code required on iOS.

### What stays Mac-only (deliberately — not a limitation we're fighting)

- **Recording + live transcription** (mic + system audio via ScreenCaptureKit, the dual-source pipeline). Excluded from the iOS target entirely.
- The global rebindable hotkey (`KeyboardShortcuts`, macOS-only) and the menu-bar / floating-controller chrome that exists to serve recording.

### The new make-or-break: quality, not feasibility

With recording off the table, there is **no platform blocker** to an excellent iOS Scribe. The bar moves from *"is it possible?"* to *"is it as good as Craft and TickTick?"* — which makes the **markdown editor** the central engineering effort (no longer a deferrable item) and **sync correctness** the main reliability risk. Both are covered below.

> The original audio-capture analysis is preserved in §2 (the audio rows) only to document the isolation work that keeps recording cleanly macOS-only. It does not bear on the iOS product.

---

## 2. Per-area assessment

Effort legend: **S** = <1 day · **M** = 1–3 days · **L** = 1–2 weeks · **XL** = >2 weeks

> **Scope note (updated):** the **audio-capture, system-audio, microphone, session-coordination, and dual-pipeline rows below are OUT OF SCOPE for iOS** — recording is a Mac-only feature. They remain in the table only to document the `#if os(macOS)` isolation needed to keep the iOS target compiling without that code; they do **not** count toward iOS effort. The rows that matter for iOS are **notes** (editor / renderer / vault), **tasks**, **storage & sync**, **navigation/chrome**, and **distribution**.

| Area | Verdict | Key blocker | Effort |
|---|---|---|---|
| **System / remote audio capture** (ScreenCaptureKit) | **Blocked** | No iOS API to capture other-app/system audio; ReplayKit cannot substitute. Feature is macOS-exclusive. | XL (to excise + redesign UX) |
| **Microphone capture** (AVAudioEngine) | Needs adaptation | No `AVAudioSession` config exists anywhere today; CoreAudio device enumeration/`AudioDeviceID` plumbing is macOS-only. | M |
| **Session coordination, buffering, metering** | Needs adaptation | Owns `SystemAudioCapture` directly + CoreAudio device APIs; must `#if os(macOS)`-gate to a mic-only manager. `AudioBufferManager` itself is fully portable. | S |
| **Transcription STT core** (SpeechAnalyzer/SpeechTranscriber) | **Portable** | None — all APIs exist on iOS 26. Only the audio *sources* feeding it change. | S |
| **Dual-pipeline speaker architecture** | Needs adaptation | "Remote" pipeline has no input on iOS; collapse to single mic pipeline (also halves STT memory). | M |
| **On-device model download** (AssetInventory) | **Portable** | None — system-managed, stored outside the app container, no app-size hit. | S |
| **Intelligence layer** (FoundationModels) | Needs adaptation | Device-gated (A17 Pro / M-series); already availability-gated in code. Keep off the live recording path on iOS. | S |
| **GRDB / SQLite / FTS5 storage** | **Portable** | None — GRDB declares `.iOS(.v11)`; `.applicationSupportDirectory` resolves in-sandbox automatically. | S |
| **Vault file IO** (NoteFileStore / reconciler / conflict detector) | Needs adaptation | Needs security-scoped access bracketing + `NSFileCoordinator` if vault is user-chosen or iCloud-synced (neither exists today). | M |
| **Vault location + security scoping** | Needs adaptation | **Zero** security-scoped bookmark support in codebase (verified); raw `UserDefaults` path string will not survive on iOS. `NSOpenPanel` → `UIDocumentPicker`. | L |
| **NoteVaultWatcher** (FSEvents) | **Rewrite** | FSEvents does not exist on iOS; needs `DispatchSource` (container) or `NSMetadataQuery`/`NSFilePresenter` (iCloud) behind a protocol. | M |
| **Markdown editor shell** (NSTextView + representable) | **Rewrite** | No 1:1 UITextView mapping for responder/key/drag model; `drawBackground` decorations have no iOS seam; `NSTextAttachmentCell` does not exist on UIKit. | XL |
| **Markdown renderer / theme** (AST → NSAttributedString) | Needs adaptation | Mechanical: `NSFont`/`NSColor` → `UIFont`/`UIColor` via typealias shim. AST walk + SourceMap stay shared. | M |
| **Quick-add task fields** (2× representables) | **Rewrite** | `NSTextField`/`NSTextView` subclasses, `keyDown` submit-on-Enter; reauthor as `UIViewRepresentable` or SwiftUI native. | L |
| **Diagram rendering** (headless WebKit + off-screen NSWindow) | Needs adaptation | macOS `NSWindow` keep-alive trick for WKWebView has no iOS analog; `NSImage` → `UIImage`. | M |
| **Image loading / caching** | Needs adaptation | Isolated; `NSImage` → `PlatformImage` typealias. | S |
| **Design-system color tokens** | Needs adaptation | macOS semantic `*BackgroundColor` family has no exact iOS twins — a deliberate mapping decision. | S |
| **Navigation core** (NavigationCoordinator / CommandRegistry) | **Portable** | None — pure `@Observable` / value types, zero platform deps. | S |
| **MainWindow split view + surface switcher** | Needs adaptation | iPhone-compact collapse breaks always-visible sidebar/footer/back-button; needs bottom `TabView` + per-tab `NavigationStack`. | L |
| **App Scene tree** (Window + Settings + .commands) | Needs adaptation | All three Scene constructs are macOS-only chrome; `Window`→`WindowGroup`, `Settings` scene → in-app screen, menu tree → in-app + iPad keyboard shortcuts. | L |
| **Command palette** (UniversalSearchView) | Needs adaptation | Hard-coded 580pt overlay + arrow-key-only selection; present as sheet, add touch row-tap. | M |
| **LiveControllerOverlay** (floating capsule) | Needs adaptation | Hover auto-hide + 22pt buttons fail on touch; re-target as persistent bottom bar with 44pt targets. | M |
| **TodayView** (HSplitView) | Needs adaptation | `HSplitView` is macOS-only; HStack on iPad, vertical stack/sheet on iPhone. | M |
| **AppDelegate** (lifecycle, hotkey, NSAlert flows) | Needs adaptation | `NSApp`/`NSWindow`/`NSAlert`/`NSWorkspace`/`CGRequestScreenCaptureAccess` all unavailable; needs UIKit/SwiftUI lifecycle. | L |
| **KeyboardShortcuts dependency** (global hotkey) | **Blocked** | Package is `.macOS`-only (Carbon `RegisterEventHotKey`); must be excluded from the iOS target behind a protocol. | M |
| **GRDB / swift-markdown / swift-cmark deps** | **Portable** | None — all declare iOS support. | S |
| **Entitlements** (sandbox off, audio-input, user-selected files) | Needs adaptation | All three keys are macOS-sandbox-specific; iOS needs a separate near-empty entitlements file. | S |
| **Distribution** (Hardened Runtime, notarization, Dev ID, DMG) | **Blocked** (n/a on iOS) | None of it applies; iOS needs App Store / TestFlight, Apple Distribution cert, `method=app-store`. | M |
| **xcodegen multiplatform target** | Needs adaptation | Single macOS target with macOS-only base settings; split into per-platform settings/Info.plist/entitlements. | M |

---

## 3. Code-sharing architecture

The codebase has **zero `#if os()` guards today** (126 files, 16 import AppKit). Platform separation must be introduced from scratch. The good news: the costly-to-port pieces are well-contained, and several of the hardest-looking modules are *already* pure and unit-tested.

### Tier 1 — Extract into a shared Swift package (`ScribeCore`), ports verbatim or near-verbatim

These have no platform dependency and several already have dedicated test files that de-risk the move:

- **Storage / data layer** — `Scribe/Storage/DatabaseManager.swift`, `NoteStore.swift`, `TaskStore.swift`, `TranscriptStore.swift`, `Note.swift`, `NoteFile.swift`, `NoteFrontmatterCodec.swift`. GRDB + FTS5, all `@unchecked Sendable` queue wrappers, zero AppKit/CoreServices imports. `.applicationSupportDirectory` resolves in-sandbox on iOS unchanged.
- **Transcription engine core** — `Scribe/Intelligence/TranscriptionPipeline.swift`, `SpeechRecognizerEngine.swift` (the pipeline itself; the *source wiring* is platform-specific). Keep the `@MainActor` actor design.
- **On-device model management** — `AssetInventory` usage in the above (system-managed, no app-size hit).
- **Markdown parsing + fold + undo + transforms**:
  - `Scribe/UI/DesignSystem/FoldRegistry.swift` (covered by `FoldRegistryTests`)
  - `Scribe/UI/DesignSystem/MarkdownUndoBuffer.swift` (covered by `MarkdownUndoBufferTests`) — actually a portability *asset*: UITextView's UndoManager is equally broken by full-storage swaps, so this design solves the same problem on both platforms
  - `InlineMarkerEditor`, `ChecklistToggle.swift`, list-prefix logic (covered by `InlineFormatTests`, `ChecklistToggleTests`)
  - The `MarkdownRenderer` **AST walk + SourceMap + autolink + marker-reveal** logic (covered by `MarkdownRendererTests`) — only the concrete font/color types are platform-bound (see Tier 2)
- **Navigation + command model** — `Scribe/UI/MainWindow/NavigationCoordinator.swift`, `Scribe/UI/Command/CommandRegistry.swift`, `Scribe/UI/Command/CommandItem.swift`. Pure `@Observable` / value types. `CommandRegistry` is the single source of verbs for both menu and palette — on iOS the palette alone exposes every command even without a menu bar.
- **Vault reconciler logic** — `NoteIndexReconciler.swift`, `NoteConflictDetector.swift`, `VaultWriteGuard.swift` (logic is portable Foundation; the *access bracketing* is platform-specific — see §5).

Introduce a **platform typealias shim** in the shared package:
```
#if os(macOS)
typealias PlatformColor = NSColor; typealias PlatformFont = NSFont; typealias PlatformImage = NSImage
#else
typealias PlatformColor = UIColor; typealias PlatformFont = UIFont; typealias PlatformImage = UIImage
#endif
```
This unblocks `MarkdownRenderer.swift` (~12 font/color touch points), `ImageLoader.swift`, `DiagramRenderer.swift`, and `DesignTokens.swift`. The macOS `NSColor(name:){ bestMatch([.darkAqua]) }` dark/light closures map directly to `UIColor(dynamicProvider:)` reading `traitCollection.userInterfaceStyle`.

### Tier 2 — Mechanical adaptation, mostly shared with thin platform layers

- **`Scribe/UI/DesignSystem/MarkdownRenderer.swift`** (M) — abstract font/color behind the typealias/theme protocol; AST logic stays shared.
- **`Scribe/UI/DesignSystem/ImageLoader.swift`** (S) — `NSImage` → `PlatformImage`; LRU + path-traversal sandboxing fully portable.
- **`Scribe/UI/Notes/DiagramRenderer.swift`** (M) — `NSImage`→`UIImage`; replace the off-screen `NSWindow` WKWebView keep-alive with an iOS view-hierarchy attachment (zero-alpha view in key window) or `WKWebView.takeSnapshot`.
- **`Scribe/UI/DesignSystem/DesignTokens.swift`** + `TagTokenField.swift`, `ExportSheetView.swift` (S) — centralize palette; map `windowBackgroundColor`/`controlBackgroundColor`/`underPageBackgroundColor`/`textBackgroundColor` to `systemBackground`/`secondarySystemBackground` deliberately (not a 1:1 rename).

### Tier 3 — Platform-specific rewrites (the real cost)

**The markdown editor is the single largest porting cost** and the gating item for the whole iOS app.

- **`Scribe/UI/DesignSystem/MarkdownEditorView.swift`** (1751 LOC, **XL**) — `NSViewRepresentable` wrapping a custom `NSTextView` subclass. Must become `UIViewRepresentable` over `UITextView`. The blocking realities:
  - `NSTextView`'s responder/event model (`performKeyEquivalent`, `keyDown`, `NSEvent`, `mouseDown`) has no 1:1 UIKit mapping → `UIKeyCommand`, `UITextViewDelegate`, gesture recognizers.
  - **`drawBackground(in:)` has no UITextView seam.** All decorations (code-block panels, blockquote/callout bars, HRs, inline-code pills, bullet glyphs) must be re-architected as **TextKit 2 layout-fragment-driven overlays** (`NSTextLayoutManager.enumerateTextLayoutFragments`). This is a genuine rewrite, not a port.
  - **`NSTextAttachmentCell` does not exist in UIKit** — the custom-drawn checkbox (`ChecklistAttachmentCell`) must become a plain `NSTextAttachment` with pre-rendered checked/unchecked `UIImage`s.
  - **TextKit version mismatch**: the macOS editor is TextKit 1 (49 `NSLayoutManager`/glyph sites); UITextView defaults to TextKit 2. Rewrite geometry against `NSTextLayoutManager` rather than the fragile TextKit-1 compatibility path.
  - Drag-and-drop (`registerForDraggedTypes`/`NSDraggingInfo`) → `UIDropInteraction`.
  - Hover-driven marker reveal (`mouseMoved`/`NSTrackingArea`) has **no touch analog** — iPhone has no hover at all; the diagram edit-button-on-hover affordance needs a tap-based redesign.
  - **Performance unknown**: the design rebuilds the entire `NSTextStorage` via `setAttributedString` on *every keystroke, selection change, and resize*, then remaps the caret through the fold registry. Acceptable on a Mac CPU; on iPhone for long notes this may cause typing latency. **Measure before shipping**; possible incrementalization needed.
  - Mitigant: the `editSource` transform bodies, fold mapping, and undo buffer are already pure (Tier 1), so the rewrite is concentrated in the view shell + decorations.

- **`Scribe/UI/Tasks/MultilineQuickAddField.swift` + `HighlightingQuickAddField.swift`** (**L**) — two `NSTextView`/`NSTextField` subclasses with `keyDown` submit-on-Enter. Reauthor as `UIViewRepresentable` over `UITextView`/`UITextField`, or replace with SwiftUI `TextField`/`TextEditor` + `AttributedString` to avoid representables entirely. Highlighting logic reuses the typealias shim.

- **App lifecycle** — `Scribe/App/AppDelegate.swift` + `ScribeApp.swift` (**L**). `NSApplicationDelegateAdaptor` → `UIApplicationDelegateAdaptor`/SwiftUI lifecycle. Delete `observeMainWindowClose` (close-window-quits has no iOS concept). All three `NSAlert` permission flows → SwiftUI `.alert` + `UIApplication.openSettingsURLString`. `NSWorkspace.open` → `UIApplication.shared.open`. Keep the portable parts: migrations, crash recovery, store wiring, the `NotificationCenter` command routing.

### macOS-only chrome — keep behind `#if os(macOS)`, build an iOS replacement

- **MenuBarExtra / `.commands` menu tree** — there is no `MenuBarExtra` in the codebase, but the `.commands` block in `ScribeApp.swift` is macOS chrome. On iPad, re-express the verbs as `.keyboardShortcut` modifiers on in-view buttons + the command palette so ⌘K/⌘N/⌘1–3 still work with a hardware keyboard. On iPhone, the palette alone carries them.
- **`Settings` scene** (macOS-only) → in-app `SettingsRootView` pushed from a toolbar gear / tab.
- **`LiveControllerOverlay.swift`** floating capsule — re-target as a persistent docked bottom bar / Dynamic-Island-style pill (see §4).
- **`KeyboardShortcuts` (sindresorhus)** — package declares `.macOS(.v10_15)` only; uses Carbon `RegisterEventHotKey`. **Must not be linked into the iOS target** (SPM will fail to resolve it). Extract `KeyboardShortcutManager.swift` behind a thin `ShortcutBinding` protocol; `#if os(macOS)` the import. Drop the `KeyboardShortcuts.Recorder` from the iOS Settings pane (`SettingsPanes.swift`). On iOS there is no rebindable global hotkey; recording is toggled from on-screen UI (and optionally a Shortcuts App Intent / Control Center control as a *separate feature*, not a port).

---

## 4. Touch / compact UX adaptation

### iPhone (compact, one column)

The single `NavigationSplitView` in `MainWindowView.swift` auto-collapses to a stack on compact width, which breaks every always-visible affordance:

- **Surface switcher** (Arc-style segmented control pinned via `safeAreaInset(.top)`) → a **bottom `TabView`** with Capture / Notes / Tasks tabs mapping 1:1 to `Surface`, each tab rooting its own `NavigationStack` at that surface's list.
- **Footer icon strip** (calendar/completed/graph/settings) → overflow menu or tab-level toolbar buttons.
- **In-pane Back button** (`ToolbarItem(placement: .navigation)`) — `.navigation` placement is macOS-only and the system back chevron is redundant; remove it.
- **Command palette** (`UniversalSearchView.swift`) → present as `.sheet`/`.fullScreenCover`, not a hard-coded 580pt centered overlay. Arrow-key selection (`onKeyPress`/`onExitCommand`) is a no-op without a keyboard; **tap-to-run must be a first-class path**, and add a swipe-down/Cancel dismiss.
- **`LiveControllerOverlay`** → persistent docked bottom bar / pill while recording. Drop the hover auto-hide hysteresis entirely (no hover on touch). **Grow the 22pt glyph buttons to the 44pt touch minimum.** Keep the VoiceOver/Reduce-Motion pinned-visible logic — it is already the correct default for touch.
- **`TodayView`** `HSplitView` → vertical stack (note on top, tasks below) or tasks-as-sheet; the side-by-side rail does not fit.

### iPad (regular columns)

- `NavigationSplitView` largely survives with two/three columns. **Drop the fixed `.frame(minWidth: 720/920)`** — harmful on iOS. Change `.searchable(placement: .sidebar)` (macOS-only) to `.automatic`/`.navigationBarDrawer`.
- **External keyboard**: re-attach ⌘K/⌘N/⌘1–3/⌘B/⌘I as `.keyboardShortcut` on buttons and command-palette actions (foreground-only, hardware-keyboard, not user-rebindable). Keep `keyboardShortcut(.space)`/(⌘.) transport on the live controller with on-screen equivalents.
- **`TodayView`** `HSplitView` → non-draggable `HStack` or two-column arrangement.
- **Multitasking / Stage Manager**: the app must tolerate arbitrary window sizes — another reason to drop hardcoded min-frames.
- **Apple Pencil**: a genuine *additive* opportunity for the notes surface (Scribble text entry into the editor, handwriting in note bodies). Out of MVP scope, but iPad is the natural home for it.

### Touch idioms that fail silently and need explicit redesign (not just compile fixes)
`onHover`, `NSTrackingArea`, `onExitCommand`, arrow-key-only list navigation, sub-44pt tap targets, `HSplitView`, `.searchable(placement:.sidebar)`, `ToolbarItem(placement:.navigation)`.

---

## 5. Storage & sync reality on iOS

**GRDB/SQLite/FTS5 is confirmed portable and is NOT a risk.** The entire risk is concentrated in the **vault + watcher layer**.

### The single biggest storage blocker: no security-scoped bookmarks
The codebase has **zero** `bookmarkData` / `startAccessingSecurityScopedResource` usage (verified by grep). Today the vault location is persisted as a **raw `UserDefaults` path string** (`NotesDirectory.userOverridePath`, key `notesVaultPath`) and the folder is chosen via `NSOpenPanel`. On iOS:

- A raw path string to a user-chosen Files-app/iCloud folder **silently loses sandbox access after relaunch**.
- To support an Obsidian-style external vault you must store `URL.bookmarkData(options: .withSecurityScope...)` and bracket *every* read/write/enumeration with `startAccessingSecurityScopedResource()`/`stopAccessing()` throughout `NoteFileStore.swift`, `VaultCoordinator.copyTree`, and the reconciler.
- `realpath(3)` canonicalization + `/private` prefix stripping in `NotesDirectory.swift`/`VaultCoordinator.swift` are macOS-shaped and meaningless inside the iOS container.

### No FSEvents on iOS
`Scribe/Storage/NoteVaultWatcher.swift` is built directly on CoreServices `FSEventStreamCreate` — **no iOS equivalent**. Rewrite behind a `VaultChangeObserving` protocol, keeping the existing `onChange() -> reconcile()` contract so `VaultCoordinator` is unaffected:
- **In-container / Files vault** → `DispatchSource.makeFileSystemObjectSource` on a directory FD. Caveat: a directory FD source **does not recurse into `Daily/`** — needs per-subdir sources.
- **iCloud Drive vault** → `NSMetadataQuery` (`NSMetadataQueryUbiquitousDocumentsScope`) / `NSFilePresenter`.
- The watcher must **re-arm on `scenePhase == .active` and tear down on background** — DispatchSource/metadata observers behave differently across app suspension than a long-lived FSEvents stream.
- `VaultWriteGuard`'s self-write suppression window is tuned to FSEvents' ~0.5s latency; it **must be re-tuned** for whatever iOS observer replaces the watcher, or autosaves will trigger spurious mid-edit reconciles.

### iCloud materialization + coordination hazards
An iCloud-synced vault introduces **non-materialized placeholder files** (`listAll`/`findURL`/`read` need `startDownloadingUbiquitousItem` + metadata-driven materialization) and **concurrent-write races** (the file IO layer uses no `NSFileCoordinator`/`NSFilePresenter` today). `AttachmentsDirectory` co-locates images in the vault root, inheriting the same constraints.

### Recommended MVP storage path
**Pin the vault to the app container's `Documents` (optionally an iCloud Documents container) on iOS.** This sidesteps bookmarks entirely — `~/Documents/Scribe/Notes` (`.documentDirectory`) resolves in-sandbox unchanged — gates out only the `NSOpenPanel` picker, and lets sync ride iCloud's own machinery. The cost is losing macOS's "point me at any existing Obsidian folder" parity, which is an acceptable Phase-1 tradeoff. Defer the arbitrary-folder + security-scoped-bookmark path to a later milestone.

---

## 6. Distribution & entitlements

The macOS app is configured for the **exact opposite** of iOS, and the central tension is the system-audio capability:

| Concern | macOS today | iOS requirement |
|---|---|---|
| App Sandbox | **OFF** (`com.apple.security.app-sandbox=false`, deliberately, for ScreenCaptureKit) | **Mandatory and implicit** — no opt-out; the key is meaningless/rejected |
| Hardened Runtime | ON (`ENABLE_HARDENED_RUNTIME=YES`, `--options=runtime`) | Does not exist — must NOT leak into iOS target |
| Distribution | Developer ID + notarytool + staple + DMG | App Store / TestFlight only; Apple Distribution cert; `method=app-store`; Transporter/Fastlane |
| Audio entitlement | `com.apple.security.device.audio-input` | Gated purely by `NSMicrophoneUsageDescription` — drop the entitlement |
| File access | `com.apple.security.files.user-selected.read-write` | No equivalent; runtime-granted via `UIDocumentPicker` — drop the entitlement |
| Screen capture | `NSScreenCaptureUsageDescription` + Screen Recording TCC | **Must be removed** — App Review rejects an unused screen-capture string |

### Critical entitlements actions
- **Do not share `Scribe.entitlements` across platforms.** Create a separate, near-empty `Scribe-iOS.entitlements` that omits `app-sandbox`, `device.audio-input`, and `files.user-selected.read-write`.
- **Strip `NSScreenCaptureUsageDescription` from the iOS Info.plist** and exclude all ScreenCaptureKit sources from the iOS target. App Review *will* flag an iOS build that ships a screen-capture string it cannot use. This must be done by **excluding sources / per-platform Info.plist**, not just disabling at runtime.

### Usage strings
- `NSMicrophoneUsageDescription` — already in the shared Info.plist, carries over.
- `NSSpeechRecognitionUsageDescription` — already present, identical on iOS. Keep `requiresOnDeviceRecognition = true` for the privacy promise.

### xcodegen multiplatform structure (`project.yml`)
Recommended approach — **cross-platform target** (`platform: [macOS, iOS]`) to minimize duplication:
1. `options.deploymentTarget: { macOS: '26.0', iOS: '26.0' }` (iOS 26 required for `SpeechAnalyzer`).
2. **Move all macOS-only base settings into `settings.platform.macOS`**: `ENABLE_HARDENED_RUNTIME`, `OTHER_CODE_SIGN_FLAGS=--options=runtime`, `MACOSX_DEPLOYMENT_TARGET`, `EXCLUDED_ARCHS[sdk=macosx*]`. If these stay in `base`, the iOS build carries invalid macOS signing flags.
3. Per-platform `INFOPLIST_FILE` (`Info-macOS.plist` *with* the screen-capture string, `Info-iOS.plist` *without*) and `CODE_SIGN_ENTITLEMENTS` (`Scribe-macOS.entitlements` / `Scribe-iOS.entitlements`).
4. **Exclude macOS-only sources from iOS**: `SystemAudioCapture.swift`, ScreenCaptureKit files, `KeyboardShortcutManager.swift` (or `#if os(macOS)` them).
5. **Per-target dependency lists**: GRDB + swift-markdown shared; `KeyboardShortcuts` excluded from iOS.
6. iOS Info.plist needs `UIApplicationSceneManifest`, supported orientations, and the `audio` `UIBackgroundMode` for background recording. **Do not share `NSPrincipalClass=NSApplication`** — it is wrong for iOS.
7. Keep `PRODUCT_BUNDLE_IDENTIFIER` shared (`com.varij.scribe`).
8. Leave `scripts/build_release.sh` (macOS) untouched; add a parallel iOS lane + `ExportOptions-iOS-AppStore.plist`.

---

## 7. Phased roadmap

> Efforts are rough engineering estimates for the porting work itself, excluding QA hardening, App Review iteration, and design polish.

### Milestone 0 — Project structure & shared core (foundation) · ~1 week
**Recommended first milestone.** Lowest risk, unblocks everything else.
- Split `project.yml` into a cross-platform target with per-platform settings/Info.plist/entitlements (§6).
- Extract `ScribeCore` Swift package: storage, navigation/command model, tasks logic, markdown parse/fold/undo/transform logic (all Tier 1; tests come along).
- Add the `PlatformColor`/`PlatformFont`/`PlatformImage` typealias shim.
- **Exclude the entire recording stack from iOS** (per-target source exclusion / `#if os(macOS)`): ScreenCaptureKit, `SystemAudioCapture`, `MicrophoneCapture`, CoreAudio device APIs, the dual `SpeechRecognizerEngine` pipeline, and `KeyboardShortcuts`. The iOS target never compiles audio code.
- **Exit criteria:** macOS app still builds and passes its test suite unchanged; iOS target compiles and links against `ScribeCore` with zero audio/recording code.

### Milestone 1 — Tasks + Notes client with sync · ~2–3 weeks
The first thing worth shipping to TestFlight — and already the core product.
- iOS app lifecycle (`UIApplicationDelegateAdaptor`/SwiftUI), iPhone bottom `TabView` (Notes / Tasks) + iPad `NavigationSplitView` (§4).
- **Tasks: full parity** — lists, due dates, priorities, subtasks, projects, pins, batch ops, calendar. The task layer is highly portable; this is where iOS earns its keep early.
- **Notes: browse / organize / search** + a **solid baseline editor** (SwiftUI `TextEditor` / `AttributedString` path) good enough to create and edit notes, with the full rich-decoration editor deferred to M2.
- Vault pinned to app-container `Documents` + iCloud Documents container; reconciler on launch + `scenePhase`; `NoteVaultWatcher` rewritten on `DispatchSource` / `NSMetadataQuery` (§5).
- Command palette as a sheet; settings as an in-app screen; permission/error UX as SwiftUI alerts.
- **Exit criteria:** notes + tasks created on either platform sync live; full task management + competent note editing on iPhone/iPad.

### Milestone 2 — Best-in-class notes editor (the headline, the long pole) · ~3–5 weeks
This is now a **core** milestone, not a deferral — "best notes app" demands it.
- **Markdown editor rewrite** on `UITextView` + TextKit 2: decorations as layout-fragment overlays, checkbox as `UIImage` attachment, `UIKeyCommand` / gesture responder model, drop-interaction, placeholder overlay. **Profile typing latency on long notes early** (the per-keystroke full-storage rebuild is the perf risk).
- Quick-add task fields reauthored (or replaced with SwiftUI native).
- `DiagramRenderer` WKWebView iOS hosting; image attachments.
- **Exit criteria:** notes editing on iOS matches the Mac's decoration richness and feels Craft-grade.

### Milestone 3 — iPad-grade polish · ~1–2 weeks
- iPad external-keyboard shortcut layer (⌘K / ⌘N / ⌘1–3 / ⌘B / ⌘I via `.keyboardShortcut`).
- **Apple Pencil / Scribble** text entry into notes (iPad's natural advantage).
- Multitasking / Stage Manager sizing; drag-and-drop between notes and tasks.

### Defer (post-MVP or indefinitely)
- **Arbitrary external Obsidian vault** via `UIDocumentPicker` + security-scoped bookmarks + `NSFileCoordinator`. Container/iCloud pinning covers most users first.
- **Read-only transcript viewing** on iOS — essentially free once the vault syncs (Mac transcripts live as notes); surface it if wanted, requires no audio code.
- FoundationModels summarization/search on iOS — device-gated (A17 Pro / M-series), run on-demand, not core.
- **Recording on iOS — explicitly out of scope per product direction.** If ever revisited, mic-only in-person capture (iPad + external mic) would be its own scoping effort; it is not part of this plan.

---

## 8. Bottom line

**Is this worth doing? Yes — and with recording off the table, there is no fundamental blocker. The iOS port is a clean, high-value build.**

With the product reframed around the **notes + tasks fusion**, the one immovable fact that dominated the original analysis — iOS can't capture other-app audio — stops mattering. It only ever constrained recording, and recording is now a Mac-only feature behind a `#if os(macOS)` wall. What's left is exactly the part of Scribe that ports *well*: the data layer, the navigation/command model, the tasks engine, and the markdown parse/fold/undo/transform core are portable or already pure and unit-tested.

**Recommended sequence:** foundation (M0) → tasks + notes + sync (M1, shippable) → best-in-class editor (M2, the headline) → iPad polish (M3). Ship M1 fast to get a useful tasks+notes client into hands, then invest in the editor that earns the "best notes app" claim.

**The two biggest risks, ranked** (note: the old #1, product-expectation risk, is gone):
1. **The markdown editor rewrite** (XL, the engineering long pole — and now a *core* deliverable, not a deferral). `MarkdownEditorView.swift` (1751 LOC) on TextKit 1 with `drawBackground` decorations and `NSTextAttachmentCell` checkboxes has *no shim path* — it is a from-scratch TextKit 2 `UITextView` build, and its per-keystroke full-storage rebuild has unproven performance on mobile CPUs. M1 ships a competent baseline editor so the product is usable while M2 builds the rich one.
2. **Vault sync correctness** (subtle, high-blast-radius). No security-scoped bookmarks, no `NSFileCoordinator`, FSEvents gone. Pinning to the app container + iCloud for MVP sidesteps the worst, but iCloud materialization + reconcile-vs-sync races are real hazards that must be designed for from M1.

**The honest one-liner:** Scribe is a notes + tasks app that happens to record meetings on the Mac. The iPhone/iPad apps drop the recording and double down on being the best place to *write and organize* — which is the product's real center of gravity anyway.