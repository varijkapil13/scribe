#!/usr/bin/env bash
# Regenerates the app icon for BOTH targets from a single source design
# (tools/render_app_icon.py — the "S monogram").
#
#   * macOS: slices tools/AppIcon-1024.png (squircle + shadow + alpha) into the
#            10-size AppIcon.appiconset the mac asset catalog expects.
#   * iOS:   copies the full-bleed opaque tools/AppIcon-ios-1024.png into the
#            ScribeiOS asset catalog as a single 1024 universal icon.
#
# Usage: ./tools/regen_app_icon.sh   (needs rsvg-convert, Pillow, sips)

set -euo pipefail

cd "$(dirname "$0")/.."

# 1. Render the two source PNGs.
python3 tools/render_app_icon.py

# 2. macOS — slice the squircle source into the asset-catalog sizes.
MAC_OUT=Scribe/Resources/Assets.xcassets/AppIcon.appiconset
MAC_SRC=tools/AppIcon-1024.png

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
  sips -s format png -z "$px" "$px" "$MAC_SRC" --out "$MAC_OUT/$name" >/dev/null
done

cat > "$MAC_OUT/Contents.json" <<'JSON'
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

# 3. iOS — single full-bleed 1024 universal icon.
IOS_OUT=ScribeiOS/Assets.xcassets/AppIcon.appiconset
mkdir -p "$IOS_OUT"
cp tools/AppIcon-ios-1024.png "$IOS_OUT/icon_1024.png"

cat > "$IOS_OUT/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

cat > "ScribeiOS/Assets.xcassets/Contents.json" <<'JSON'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "App icon regenerated for macOS (10 sizes) + iOS (1024 universal)."
