# Scribe — iCloud Sync & Multiplatform Build Design

Decisions for shipping Scribe on iPhone/iPad with iCloud sync across all
devices. Extends `docs/IOS-MIGRATION-PLAN.md` (which it defers to for the
notes/tasks UI port) and `docs/MULTIPLATFORM-SCOPING.md` (the feasibility
audit). This doc is specifically the **sync architecture** and the **build/
target structure** decisions — the two things those docs left open or only
sketched for MVP.

> **Validation reality:** the dev environment has no Swift toolchain and the
> apps are Apple-framework-only; CI on `macos-26` is the only compiler. iCloud
> sync and on-device iOS UX **cannot be verified without real devices + an
> iCloud-enabled provisioning profile**. Everything here is built to compile
> (CI-gated) and designed correctly; items needing device validation are marked
> ⚠️DEVICE.

## D-iOS-1 — Code sharing: multiplatform target, not `ScribeCore` extraction

The migration plan's `ScribeCore` SPM extraction is the "right" long-term shape
but is explicitly flagged as *high-churn, leaves the build red mid-flight, not
safe to run unattended* (the `public` access-control tax across ~74 files).

**Decision:** ship iOS by compiling the **portable source files into the
`ScribeiOS` target directly** (via `project.yml` `sources` globs) and gating
platform code with `#if os(macOS)` / `#if canImport(AppKit)`. Same module, no
cross-module `public` tax, and each increment is independently CI-validatable.
The `ScribeCore` package remains the eventual destination; this is the
lower-risk path to a shipping iOS app first. Leaf-first inclusion order
(models → storage → pure logic → navigation/command → view models → iOS views),
keeping macOS green after each push.

## D-iOS-2 — Recording stays macOS-only (unchanged)

ScreenCaptureKit/CoreAudio/`KeyboardShortcuts`/`SpeechRecognizerEngine` and the
whole capture stack are excluded from the iOS target by source-exclusion +
`#if os(macOS)`. iOS = Notes + Tasks + Today + Sync.

## D-iOS-3 — App structure

- iPhone: bottom `TabView` → **Today · Notes · Tasks** (Capture tab omitted).
- iPad: `NavigationSplitView` (sidebar + detail), reusing the macOS navigation
  model (`NavigationCoordinator`/`MainSelection` are pure and portable).
- Lifecycle: SwiftUI `App` + `UIApplicationDelegateAdaptor` for the migration/
  reconcile/sync bootstrap that `AppDelegate` does on macOS (the portable parts
  only — no `NSApp`, no hotkey, no `NSAlert`).
- Settings: in-app screen (the macOS `Settings` scene is unavailable).

---

## Sync architecture

### D-Sync-1 — Two channels, chosen to preserve the Obsidian-vault ethos

Scribe's note **bodies are `.md` files** (the vault is the source of truth since
v13 dropped `notes.body`); **tasks/projects live only in SQLite** and have no
file representation. A single mechanism can't serve both well, so:

1. **Notes + attachments → iCloud Drive ubiquity container.**
   Move the vault into `iCloud.com.varij.scribe/Documents/Notes`. Both Mac and
   iOS point `NotesDirectory` at the ubiquity container. This syncs every note,
   its frontmatter, and attachments for free via iCloud's file sync — and keeps
   the files visible in the Files app / Obsidian (the whole point of the vault).
   The Mac's existing **reconcile-from-disk** machinery (`NoteIndexReconciler`,
   `VaultCoordinator`) already rebuilds the DB from the vault, so a synced vault
   "just works" on both ends once the watcher is portable (below).

2. **Tasks, projects, task-tags, reminders → CloudKit private database.**
   These aren't files. A `CloudTaskSyncEngine` mirrors the `tasks`/`projects`/
   `task_tags` tables to CKRecords in the user's private DB
   (`CKContainer.default().privateCloudDatabase`), with a `CKSyncEngine`-style
   change-token model: push on local change, pull on launch + remote-change
   push notification, **last-writer-wins** by `updatedAt`. Subtasks ride their
   parent task record (small, bounded).

Transcripts/sessions stay Mac-local for now (they reference the vault note and
aren't needed on iOS); revisit if read-only transcript viewing is wanted.

### D-Sync-2 — Vault change observation behind a protocol

`NoteVaultWatcher` is FSEvents (macOS-only). Introduce `VaultChangeObserving`
with two implementations, keeping the existing `onChange → reconcile()` contract
so `VaultCoordinator` is untouched:
- macOS local: existing FSEvents watcher.
- iCloud (both platforms): `NSMetadataQuery` over `NSMetadataQueryUbiquitous-
  DocumentsScope` (handles non-materialized placeholders +
  `startDownloadingUbiquitousItem`).
`VaultWriteGuard`'s self-write suppression window is re-tuned for the metadata-
query latency (currently tuned to FSEvents ~0.5s). ⚠️DEVICE: the suppression
window needs on-device tuning.

### D-Sync-3 — Conflict handling

- **Notes (files):** iCloud surfaces conflicts as `NSFileVersion` conflict
  versions. `NoteConflictDetector` already exists; wire it to resolve by
  newest-`updatedAt` frontmatter and keep the loser as a `*.conflict.md`
  sidecar (never silently drop user text). ⚠️DEVICE.
- **Tasks (CloudKit):** last-writer-wins on `updatedAt`; deletes are tombstoned
  (a `deletedAt` column / `CKRecord` deletion) so a delete on one device
  propagates rather than being resurrected by a stale push.

### D-Sync-4 — Migration / opt-in

Moving the vault into the ubiquity container is a one-time, opt-in migration
(Settings → "Sync with iCloud"): copy the local vault into the container,
re-point `NotesDirectory`, reconcile. Reversible. Default off until the user
opts in so we never silently upload a user's notes. ⚠️DEVICE.

### D-Sync-5 — Entitlements / capabilities

- iOS + macOS both gain: `com.apple.developer.icloud-container-identifiers` =
  `iCloud.com.varij.scribe`, `com.apple.developer.icloud-services` =
  `CloudKit` + `CloudDocuments`, `com.apple.developer.ubiquity-container-
  identifiers`, and the CloudKit push entitlement (`aps-environment`) for
  remote-change notifications.
- macOS keeps sandbox **off** (recording); iOS sandbox is implicit. Separate
  entitlements files per platform (`Scribe-macOS.entitlements` /
  `Scribe-iOS.entitlements`). ⚠️DEVICE: requires the Apple Developer account to
  provision the iCloud container + push.

---

## Build/target structure (`project.yml`)

- Per-platform `INFOPLIST_FILE` and `CODE_SIGN_ENTITLEMENTS`; move macOS-only
  base settings (`ENABLE_HARDENED_RUNTIME`, `OTHER_CODE_SIGN_FLAGS`,
  `MACOSX_DEPLOYMENT_TARGET`, `EXCLUDED_ARCHS[sdk=macosx*]`) into
  `settings.platform.macOS` so they never leak into the iOS build.
- `ScribeiOS` sources: shared portable files + `ScribeiOS/` UI; **exclude** the
  recording/AppKit-only files. `KeyboardShortcuts` not linked on iOS.
- iOS Info.plist: `UIApplicationSceneManifest`, orientations, `NSMicrophone-/
  NSSpeechRecognitionUsageDescription` dropped (no recording), **no**
  `NSScreenCaptureUsageDescription` (App Review rejects an unused string).

## CI

Add an **iOS build job** (`xcodebuild -scheme ScribeiOS -destination 'platform=
iOS Simulator,name=iPhone 16'`, signing disabled) so the iOS target is compiled
on every push — the only automated guard available without devices. The macOS
build + `swift test` jobs stay as the authoritative gates.

## Honest status legend for the PR

- ☑ CI-compiles (macOS + iOS) and unit-tested where logic is pure.
- ⚠️DEVICE — correct by design + compiles, but requires a real device + iCloud
  provisioning to verify (all live-sync behavior, conflict resolution, watcher
  latency tuning, migration).
