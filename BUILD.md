# Building & Distributing Scribe

Scribe is a native macOS 26 (Apple Silicon) app. It builds two ways:

- **Logic tests** run via SwiftPM: `swift test`
- **The shippable app** builds via Xcode from the `xcodegen`-generated project.

## Prerequisites

| Tool | Install |
|------|---------|
| Xcode 26+ | App Store / developer.apple.com |
| XcodeGen | `brew install xcodegen` |
| create-dmg (optional, nicer DMGs) | `brew install create-dmg` |

The `.xcodeproj` is **generated** (git-ignored). Always run `xcodegen generate`
after pulling or after adding/removing source files.

## Build & run locally

```bash
xcodegen generate
open Scribe.xcodeproj        # then ⌘R in Xcode (see SwiftLint note below)
# …or headless:
DISABLE_SWIFTLINT=YES xcodebuild -project Scribe.xcodeproj -scheme Scribe \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation build
```

> **Why `DISABLE_SWIFTLINT=YES` and `-skipPackagePluginValidation`?** The
> `CodeEditSourceEditor` / `CodeEditTextView` dependencies attach the
> `lukepistrol/SwiftLintPlugins` *build-tool* plugin to their own targets.
> Xcode (a) refuses to run an untrusted package plugin in a non-interactive
> build — the bare command above fails with *"Validate plug-in 'SwiftLint'"*
> — and (b) then runs `swiftlint` against the vendored sources, which errors
> with *"The folder 'Output' doesn't exist."* `-skipPackagePluginValidation`
> bypasses the trust gate; `DISABLE_SWIFTLINT=YES` makes the plugin emit no
> commands at all (it reads the var from its `ProcessInfo` at plan time), so
> swiftlint never runs. We don't lint dependency sources anyway. CI sets both
> (`.github/workflows/ci.yml`). **In Xcode (⌘R):** click **Trust & Enable**
> on the SwiftLint plugin prompt the first time, or skip the prompt machine-wide
> once with `defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES`
> (Apple's key is misspelled — copy it verbatim).

On first launch macOS will prompt for **Microphone**, **Screen Recording**
(system-audio capture via ScreenCaptureKit — audio only, no video), and later
**Notifications** (the first time a task reminder is saved). All transcription
and AI run on-device.

## Producing a distributable build

Run the release script:

```bash
scripts/build_release.sh                              # archive → export → DMG
NOTARY_PROFILE=scribe-notary scripts/build_release.sh # …+ notarize & staple
```

Artifacts land in `build/` (`Scribe.app`, `Scribe-<version>.dmg`).

### Signing & notarization (one-time setup)

Distribution **outside the Mac App Store** (direct download / DMG) requires a
**Developer ID Application** certificate, which needs a paid **Apple Developer
Program** membership.

> The current keychain on this machine only has an *Apple Development* cert
> (fine for running locally, **not** for distribution). Until a *Developer ID
> Application* cert is installed, `build_release.sh` still produces a runnable,
> development-signed `Scribe.app` + DMG — but other users would see Gatekeeper
> warnings, so it is not yet publicly distributable.

1. **Create the cert** (once): Xcode → Settings → Accounts → Manage
   Certificates → ➕ → *Developer ID Application*. It installs into your login
   keychain. Confirm with:
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
2. **Store a notary credential** (once), using an
   [app-specific password](https://support.apple.com/102654):
   ```bash
   xcrun notarytool store-credentials scribe-notary \
     --apple-id "you@example.com" --team-id "U8A3QH6Y84" --password "abcd-efgh-ijkl-mnop"
   ```
3. **Build, notarize, staple**:
   ```bash
   NOTARY_PROFILE=scribe-notary scripts/build_release.sh
   ```
   The script archives (Release), exports a Developer-ID-signed app
   (`scripts/ExportOptions-DeveloperID.plist`), submits to Apple's notary
   service, staples the ticket, and packages the DMG. Ship `build/Scribe-*.dmg`.

### Version bumps

Edit `Scribe/Resources/Info.plist` → `CFBundleShortVersionString` (marketing,
e.g. `1.1`) and `CFBundleVersion` (build number, must increase for each
notarized upload). Then re-run the release script.

## Configuration reference

- **Signing/team/hardened-runtime** live in `project.yml` (regenerated into the
  project). Team `U8A3QH6Y84`, Hardened Runtime on, App Sandbox intentionally
  **off** (ScreenCaptureKit system-audio capture needs an unsandboxed,
  Developer-ID-signed build — see `Scribe/Resources/Scribe.entitlements`).
- **Entitlements**: audio-input, user-selected file read/write.
- **Min OS**: macOS 26.0 (`LSMinimumSystemVersion`). Apple Silicon only
  (`ARCHS=arm64`).
- **Usage strings** (mic / screen / speech) are in `Info.plist`.

## Troubleshooting

- *Build fails at "Validate plug-in 'SwiftLint'"* (3 failures) or *"The folder
  'Output' doesn't exist."* → the SwiftLint build-tool plugin from the CodeEdit
  dependencies. Build with `DISABLE_SWIFTLINT=YES … -skipPackagePluginValidation`
  (see *Build & run locally*); in Xcode click **Trust & Enable** on the plugin
  prompt. Your app code is fine — these are not compile errors.
- *"No signing certificate 'Developer ID Application'"* → see step 1 above.
- *Archive succeeds but export fails* → you have a development cert but no
  Developer ID cert; the script falls back to copying the archived app.
- *Notarization rejected* → run `xcrun notarytool log <submission-id>
  --keychain-profile scribe-notary` to see why (commonly: a nested binary
  isn't Hardened-Runtime-signed, or the build wasn't signed with Developer ID).
