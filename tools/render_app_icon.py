#!/usr/bin/env python3
"""Render Scribe's app icon (the "S monogram") to the two source PNGs the asset
catalogs need:

  * tools/AppIcon-1024.png      — macOS: Apple-grid squircle (824 in 1024) with a
                                  glassy top highlight + baked soft shadow, alpha
                                  preserved (macOS expects the shape baked in).
  * tools/AppIcon-ios-1024.png  — iOS: full-bleed, fully opaque, NO alpha (iOS
                                  masks the corners itself and rejects alpha).

`tools/regen_app_icon.sh` calls this, then slices the macOS sizes with `sips`
and copies the iOS 1024 into ScribeiOS/Assets.xcassets. Requires rsvg-convert
and Pillow.
"""
import subprocess
import pathlib
from PIL import Image

OUT = pathlib.Path(__file__).parent
SIDE = 1024

# Brand gradient (Arc-modern blue → deep indigo).
TOP = "#2E78F2"
BOT = "#152780"

# macOS Apple-grid: rounded-rect body 824 centered in 1024 (~100px margin).
M = 100
W = SIDE - 2 * M
RX = round(W * 0.2237)

# The "S" monogram — a bold ribbon stroke, authored in the 100..924 body space
# so it sits identically whether the body is the inset squircle (macOS) or the
# full-bleed square (iOS).
S_PATH = ("M662 392 C612 330 430 318 372 392 C312 470 392 520 512 540 "
          "C632 560 712 612 652 690 C594 764 412 752 362 690")
S_GLYPH = (f'<path d="{S_PATH}" fill="none" stroke="#ffffff" stroke-width="96" '
           f'stroke-linecap="round" stroke-linejoin="round"/>')

GRAD = (f'<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="{TOP}"/>'
        f'<stop offset="1" stop-color="{BOT}"/></linearGradient>')

GLOSS = ('<linearGradient id="gloss" x1="0" y1="0" x2="0" y2="1">'
         '<stop offset="0" stop-color="#ffffff" stop-opacity="0.22"/>'
         '<stop offset="0.42" stop-color="#ffffff" stop-opacity="0.05"/>'
         '<stop offset="0.55" stop-color="#ffffff" stop-opacity="0"/>'
         '</linearGradient>')


def macos_svg():
    body = f'<rect x="{M}" y="{M}" width="{W}" height="{W}" rx="{RX}" ry="{RX}"/>'
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{SIDE}" height="{SIDE}" viewBox="0 0 {SIDE} {SIDE}">
  <defs>
    {GRAD}{GLOSS}
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="22" stdDeviation="26" flood-color="#000000" flood-opacity="0.30"/>
    </filter>
    <clipPath id="bodyclip">{body}</clipPath>
  </defs>
  <g filter="url(#shadow)"><g fill="url(#bg)">{body}</g></g>
  <g clip-path="url(#bodyclip)"><rect x="{M}" y="{M}" width="{W}" height="{W}" fill="url(#gloss)"/></g>
  {S_GLYPH}
</svg>'''


def ios_svg():
    # Full-bleed: gradient + gloss span the whole 1024 square, no rounded
    # corners, no shadow (iOS masks + shades). Glyph keeps body-space coords.
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{SIDE}" height="{SIDE}" viewBox="0 0 {SIDE} {SIDE}">
  <defs>{GRAD}{GLOSS}</defs>
  <rect x="0" y="0" width="{SIDE}" height="{SIDE}" fill="url(#bg)"/>
  <rect x="0" y="0" width="{SIDE}" height="{SIDE}" fill="url(#gloss)"/>
  {S_GLYPH}
</svg>'''


def render(svg, png):
    svg_path = OUT / (png.stem + ".svg")
    svg_path.write_text(svg)
    subprocess.run(["rsvg-convert", "-w", str(SIDE), "-h", str(SIDE),
                    str(svg_path), "-o", str(png)], check=True)


# macOS source — keep alpha.
mac_png = OUT / "AppIcon-1024.png"
render(macos_svg(), mac_png)

# iOS source — flatten to opaque RGB (strip alpha; iOS rejects an alpha channel).
ios_png = OUT / "AppIcon-ios-1024.png"
render(ios_svg(), ios_png)
Image.open(ios_png).convert("RGB").save(ios_png)

print(f"wrote {mac_png.name} (macOS, alpha) and {ios_png.name} (iOS, opaque RGB)")
