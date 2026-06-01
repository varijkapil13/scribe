#!/usr/bin/env bash
#
# build_release.sh — produce a distributable Scribe.app (+ optional DMG +
# notarization) for direct (non-App-Store) distribution.
#
# Usage:
#   scripts/build_release.sh                 # archive + export + DMG (no notarize)
#   NOTARY_PROFILE=scribe-notary scripts/build_release.sh   # …+ notarize & staple
#
# Prerequisites (see BUILD.md):
#   • Xcode 26+ and `xcodegen` (brew install xcodegen)
#   • A "Developer ID Application" certificate in your login keychain
#     (Apple Developer Program membership required). Without it, export falls
#     back to a local development-signed build that is NOT distributable.
#   • For notarization: a stored notarytool profile created once via
#       xcrun notarytool store-credentials <profile> \
#         --apple-id you@example.com --team-id U8A3QH6Y84 --password <app-specific-pw>
#     then pass its name via NOTARY_PROFILE.
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/Scribe.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/Scribe.app"
SCHEME="Scribe"
CONFIG="Release"

log() { printf "\033[1;34m▸ %s\033[0m\n" "$*"; }
die() { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

command -v xcodegen >/dev/null || die "xcodegen not found — brew install xcodegen"

log "Regenerating Xcode project from project.yml"
xcodegen generate >/dev/null

log "Cleaning build/"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

log "Archiving ($CONFIG)…"
xcodebuild archive \
  -project Scribe.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  | xcpretty 2>/dev/null || xcodebuild archive \
  -project Scribe.xcodeproj -scheme "$SCHEME" -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE"

[ -d "$ARCHIVE" ] || die "Archive failed — no $ARCHIVE"

# Does the keychain have a Developer ID Application cert?
HAS_DEVID=0
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  HAS_DEVID=1
fi

if [ "$HAS_DEVID" -eq 1 ]; then
  log "Exporting Developer-ID-signed app…"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist scripts/ExportOptions-DeveloperID.plist
else
  log "No 'Developer ID Application' cert found — exporting the archived app AS-IS"
  log "  (development-signed; usable locally, NOT distributable until re-signed — see BUILD.md)"
  mkdir -p "$EXPORT_DIR"
  cp -R "$ARCHIVE/Products/Applications/Scribe.app" "$APP"
fi

[ -d "$APP" ] || die "Export failed — no $APP"
log "App built: $APP"

# Optional notarization (requires a Developer-ID-signed app + a notary profile).
if [ -n "${NOTARY_PROFILE:-}" ] && [ "$HAS_DEVID" -eq 1 ]; then
  log "Notarizing via profile '$NOTARY_PROFILE' (this can take a few minutes)…"
  ZIP="$BUILD_DIR/Scribe-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  log "Stapling ticket"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP" && log "Notarization stapled ✓"
elif [ -n "${NOTARY_PROFILE:-}" ]; then
  log "Skipping notarization — needs a Developer ID Application cert first."
fi

# DMG packaging (uses create-dmg if present, else a plain hdiutil image).
DMG="$BUILD_DIR/Scribe-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist").dmg"
log "Packaging DMG → $DMG"
if command -v create-dmg >/dev/null; then
  create-dmg --overwrite "$APP" "$BUILD_DIR" >/dev/null 2>&1 || true
  # create-dmg names by app + version; normalize to $DMG if it produced something else.
  PRODUCED="$(ls -t "$BUILD_DIR"/*.dmg 2>/dev/null | head -1 || true)"
  [ -n "$PRODUCED" ] && [ "$PRODUCED" != "$DMG" ] && mv "$PRODUCED" "$DMG"
else
  STAGE="$BUILD_DIR/dmg-stage"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG"
  hdiutil create -volname "Scribe" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
fi
[ -f "$DMG" ] && log "DMG ready: $DMG" || die "DMG creation failed"

log "Done. Artifacts in $BUILD_DIR/"
