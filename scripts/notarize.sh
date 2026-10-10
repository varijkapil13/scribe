#!/usr/bin/env bash
# Submits a .zip / .dmg / .pkg to Apple's notary service and waits for the
# verdict; prints the notary log and fails when it isn't "Accepted". Used by
# .github/workflows/release-macos.yml. Credentials come from the environment,
# App Store Connect API key preferred:
#
#   NOTARY_API_KEY        contents of the AuthKey_XXXX.p8 (PEM text or base64)
#   NOTARY_API_KEY_ID     its key ID
#   NOTARY_API_ISSUER_ID  the issuer ID
# or
#   APPLE_ID, APPLE_APP_PASSWORD (app-specific password), APPLE_TEAM_ID
#
#   scripts/notarize.sh dist/Scribe-v1.0.0.dmg
set -euo pipefail

FILE="${1:?usage: notarize.sh FILE}"
[ -f "$FILE" ] || { echo "error: $FILE not found" >&2; exit 1; }

AUTH=()
if [ -n "${NOTARY_API_KEY:-}" ] && [ -n "${NOTARY_API_KEY_ID:-}" ] && [ -n "${NOTARY_API_ISSUER_ID:-}" ]; then
  KEY_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/notary-key.XXXXXX")"
  trap 'rm -rf "$KEY_DIR"' EXIT
  KEY_FILE="$KEY_DIR/AuthKey_${NOTARY_API_KEY_ID}.p8"
  if printf '%s' "$NOTARY_API_KEY" | grep -q "BEGIN PRIVATE KEY"; then
    printf '%s\n' "$NOTARY_API_KEY" > "$KEY_FILE"
  else
    printf '%s' "$NOTARY_API_KEY" | base64 --decode > "$KEY_FILE"
  fi
  chmod 600 "$KEY_FILE"
  AUTH=(--key "$KEY_FILE" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER_ID")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
  AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID")
else
  echo "error: no notarization credentials in the environment" >&2
  exit 1
fi

echo "Submitting $(basename "$FILE") for notarization…"
OUT="$(xcrun notarytool submit "$FILE" "${AUTH[@]}" --wait --output-format json)" || true
echo "$OUT"

field () { # $1 = JSON key
  printf '%s' "$OUT" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get(sys.argv[1], ""))
except Exception:
    print("")' "$1"
}
ID="$(field id)"
STATUS="$(field status)"

if [ "$STATUS" != "Accepted" ]; then
  if [ -n "$ID" ]; then
    xcrun notarytool log "$ID" "${AUTH[@]}" || true
  fi
  echo "::error::Notarization of $(basename "$FILE") ended with status: ${STATUS:-unknown}"
  exit 1
fi
echo "Notarized $(basename "$FILE") (submission $ID)"
