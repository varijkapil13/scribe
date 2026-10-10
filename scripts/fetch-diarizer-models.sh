#!/usr/bin/env bash
# Downloads the speaker-diarization Core ML models that FluidAudio's offline
# diarizer needs into build-resources/DiarizerModels/, where the Xcode
# "Bundle speaker-diarization models" build phase copies them into the app.
#
# The revision is pinned to what FluidAudio 0.17.7 expects
# (ModelNames.Repo.diarizer.revision); bump both together.
#
# Usage: scripts/fetch-diarizer-models.sh            (from the repo root)
set -euo pipefail

REPO="FluidInference/speaker-diarization-coreml"
REVISION="df2625ac79a7ac6b65ad868fee6d80f320da4232"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/build-resources/DiarizerModels/speaker-diarization-coreml"
# Only what OfflineDiarizerModels.load reads (about 22 MB).
WANTED='^(Segmentation|FBank|Embedding|PldaRho)\.mlmodelc/|^plda-parameters\.json$'

if [ -f "$DEST/.fluidaudio-revision" ] && [ "$(cat "$DEST/.fluidaudio-revision")" = "$REVISION" ]; then
  echo "Diarizer models already present at $DEST"
  exit 0
fi

rm -rf "$DEST"
mkdir -p "$DEST"

files=$(curl -fsSL "https://huggingface.co/api/models/$REPO/tree/$REVISION?recursive=1" \
  | python3 -c 'import json,sys; [print(f["path"]) for f in json.load(sys.stdin) if f["type"]=="file"]' \
  | grep -E "$WANTED")

for path in $files; do
  mkdir -p "$DEST/$(dirname "$path")"
  curl -fsSL --retry 3 -o "$DEST/$path" "https://huggingface.co/$REPO/resolve/$REVISION/$path"
done

# FluidAudio treats a cache with this marker as complete for the pinned
# revision and won't try to re-download it.
printf '%s' "$REVISION" > "$DEST/.fluidaudio-revision"
echo "Fetched $(echo "$files" | wc -l | tr -d ' ') files into $DEST ($(du -sh "$DEST" | cut -f1))"
