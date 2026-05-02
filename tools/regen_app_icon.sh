#!/usr/bin/env bash
# Regenerates the AppIcon.appiconset PNGs from a single 1024×1024 source.
#
# Usage: ./tools/regen_app_icon.sh

set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p tools

swift tools/generate_icon.swift

OUT=Scribe/Resources/Assets.xcassets/AppIcon.appiconset
SRC=tools/AppIcon-1024.png

# Each entry: <png filename>:<pixel size>
declare -a sizes=(
  "icon_16x16.png:16"
  "icon_16x16@2x.png:32"
  "icon_32x32.png:32"
  "icon_32x32@2x.png:64"
  "icon_128x128.png:128"
  "icon_128x128@2x.png:256"
  "icon_256x256.png:256"
  "icon_256x256@2x.png:512"
  "icon_512x512.png:512"
  "icon_512x512@2x.png:1024"
)

for entry in "${sizes[@]}"; do
  name="${entry%%:*}"
  px="${entry##*:}"
  sips -s format png -z "$px" "$px" "$SRC" --out "$OUT/$name" >/dev/null
done

cat > "$OUT/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16x16.png"     },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_16x16@2x.png"  },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32x32.png"     },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_32x32@2x.png"  },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png"   },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png"},
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png"   },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png"},
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png"   },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png"}
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "AppIcon.appiconset regenerated."
