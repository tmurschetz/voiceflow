#!/usr/bin/env python3
"""
menubar-icon.py — extract a black-on-transparent menu bar template image
from the colored AppIcon.png.

Strategy:
  1. Read AppIcon.png (the original, before squircle masking — we want the V mark
     before the white halo got compressed against the squircle edge).
  2. Find white-ish pixels by luminance threshold → these become opaque black.
  3. Everything else → transparent.
  4. Crop to the V-with-wave bounding box + small padding.
  5. Render at 22pt × 22pt (44×44 @2x, 66×66 @3x) for menu bar use.

Apple convention: menu bar icons are template images — black + alpha, system
tints them automatically based on light/dark mode and active state.

Output:
  VoiceflowDesktop/Resources/MenuBarIcon.png      (22×22)
  VoiceflowDesktop/Resources/MenuBarIcon@2x.png   (44×44)
  VoiceflowDesktop/Resources/MenuBarIcon@3x.png   (66×66)
"""

from __future__ import annotations
import sys
import os
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("❌ Pillow not installed. Run: python3 -m pip install --user Pillow")
    sys.exit(1)

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE = REPO_ROOT / "AppIcon.png"
OUT_DIR = REPO_ROOT / "VoiceflowDesktop" / "Resources"

# Pixels brighter than this are considered "the white V-mark".
# Higher = stricter: keeps only the solid white core of the V+wave, drops the
# soft glow/halo so the menu bar mark renders as a clean monochrome shape with
# no surrounding rectangle or rim.
LUMINANCE_THRESHOLD = int(os.environ.get("VF_MENUBAR_THRESHOLD", "240"))
# Padding around the bounding box, as a fraction of its larger dimension
PADDING_RATIO = 0.06


def luminance(r: int, g: int, b: int) -> float:
    return 0.299 * r + 0.587 * g + 0.114 * b


def main() -> int:
    if not SOURCE.exists():
        print(f"❌ Source not found: {SOURCE}")
        return 1

    img = Image.open(SOURCE).convert("RGBA")
    w, h = img.size
    px = img.load()

    # Build a black-on-transparent layer where white-ish source pixels survive
    template = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    tx = template.load()

    min_x, min_y, max_x, max_y = w, h, 0, 0
    found = 0
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a < 50:
                continue
            lum = luminance(r, g, b)
            if lum >= LUMINANCE_THRESHOLD:
                # Hard threshold: the V+wave is fully opaque, halo is fully cut.
                # Only the very brightest pixels survive — produces a clean
                # monochrome shape with no surrounding rectangle/rim.
                tx[x, y] = (0, 0, 0, 255)
                found += 1
                if x < min_x: min_x = x
                if y < min_y: min_y = y
                if x > max_x: max_x = x
                if y > max_y: max_y = y

    if found == 0:
        print(f"❌ No pixels above luminance {LUMINANCE_THRESHOLD} found in {SOURCE.name}")
        print("   Adjust with: VF_MENUBAR_THRESHOLD=180 scripts/menubar-icon.py")
        return 1

    # Crop to bounding box + padding
    box_w = max_x - min_x
    box_h = max_y - min_y
    pad = int(max(box_w, box_h) * PADDING_RATIO)
    crop_x0 = max(0, min_x - pad)
    crop_y0 = max(0, min_y - pad)
    crop_x1 = min(w, max_x + pad + 1)
    crop_y1 = min(h, max_y + pad + 1)
    cropped = template.crop((crop_x0, crop_y0, crop_x1, crop_y1))

    # Center on a square canvas so the icon is balanced
    side = max(cropped.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    paste_x = (side - cropped.size[0]) // 2
    paste_y = (side - cropped.size[1]) // 2
    square.paste(cropped, (paste_x, paste_y), mask=cropped)

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # Render the three resolutions Apple expects for menu bar
    sizes = {
        "MenuBarIcon.png":     22,
        "MenuBarIcon@2x.png":  44,
        "MenuBarIcon@3x.png":  66,
    }
    for name, target in sizes.items():
        out = square.resize((target, target), Image.LANCZOS)
        out.save(OUT_DIR / name, format="PNG")
        print(f"  ✓ {name} ({target}×{target})")

    print(f"✅ Built menu bar template from {found} bright pixels (luminance ≥ {LUMINANCE_THRESHOLD})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
