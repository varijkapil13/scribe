#!/usr/bin/env bash
# Re-signs an (ad-hoc signed) Scribe.app with a Developer ID identity, inside
# out, with the Hardened Runtime and a secure timestamp — what notarization
# requires. Used by .github/workflows/release-macos.yml when Developer ID
# secrets are configured; also runnable by hand:
#
#   scripts/codesign-developer-id.sh build/.../Scribe.app "<identity or SHA-1>" \
#       Scribe/Resources/Scribe.entitlements [keychain]
#
# Sparkle's nested helpers are signed the way Sparkle's documentation
# prescribes for non-sandboxed apps (Downloader.xpc keeps its entitlements).
set -euo pipefail

APP="${1:?usage: codesign-developer-id.sh APP IDENTITY ENTITLEMENTS [KEYCHAIN]}"
IDENTITY="${2:?usage: codesign-developer-id.sh APP IDENTITY ENTITLEMENTS [KEYCHAIN]}"
ENTITLEMENTS="${3:?usage: codesign-developer-id.sh APP IDENTITY ENTITLEMENTS [KEYCHAIN]}"
KEYCHAIN="${4:-}"

[ -d "$APP" ] || { echo "error: $APP not found" >&2; exit 1; }
[ -f "$ENTITLEMENTS" ] || { echo "error: $ENTITLEMENTS not found" >&2; exit 1; }

SIGN=(codesign --force --timestamp --options runtime --sign "$IDENTITY")
if [ -n "$KEYCHAIN" ]; then
  SIGN+=(--keychain "$KEYCHAIN")
fi

sign () {
  echo "Signing ${1#"$APP"/}"
  "${SIGN[@]}" "${@:2}" "$1"
}

FRAMEWORKS="$APP/Contents/Frameworks"

# 1. Sparkle: helpers first, then the framework.
SPARKLE="$FRAMEWORKS/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  B="$SPARKLE/Versions/B"
  [ -d "$B/XPCServices/Installer.xpc" ] && sign "$B/XPCServices/Installer.xpc"
  [ -d "$B/XPCServices/Downloader.xpc" ] && sign "$B/XPCServices/Downloader.xpc" --preserve-metadata=entitlements
  [ -e "$B/Autoupdate" ] && sign "$B/Autoupdate"
  [ -d "$B/Updater.app" ] && sign "$B/Updater.app"
  sign "$SPARKLE"
fi

# 2. Any other embedded frameworks / dylibs (SwiftPM products are usually
#    static, but sign whatever is there so notarization never trips on it).
if [ -d "$FRAMEWORKS" ]; then
  while IFS= read -r -d '' item; do
    case "$item" in
      "$SPARKLE") continue ;;
    esac
    sign "$item"
  done < <(find "$FRAMEWORKS" -mindepth 1 -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) -print0)
fi

# 3. Any plug-ins / login items / XPC services in the app itself.
for dir in "$APP/Contents/PlugIns" "$APP/Contents/XPCServices" "$APP/Contents/Library/LoginItems"; do
  [ -d "$dir" ] || continue
  while IFS= read -r -d '' item; do
    sign "$item"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0)
done

# 4. The app, with its entitlements.
sign "$APP" --entitlements "$ENTITLEMENTS"

codesign --verify --deep --strict --verbose=2 "$APP"
echo "Signed $APP"
