#!/usr/bin/env python3
"""
squircle-mask.py — apply a clean macOS squircle mask to an app-icon PNG.

Why: Nano Banana / DALL-E / etc. sometimes deliver icons with non-transparent
corners (white, checker-pattern artefacts, slightly off squircle geometry).
macOS Big Sur+ displays the PNG as-is in Finder, Dock and menu — so we need
the corners to be truly transparent.

This script:
  1. Reads a square PNG (any size, any background).
  2. Computes Apple's squircle path (superellipse with n ≈ 5) at the same size.
  3. Composites the input onto the squircle alpha mask.
  4. Adds a few pixels of padding from the canvas edge so the icon doesn't
     touch the bounds (Apple's guidelines reserve this margin).
  5. Writes a clean RGBA PNG with transparent corners.

Usage: scripts/squircle-mask.py input.png [output.png]
       (defaults to overwriting input)
"""

from __future__ import annotations
import sys
import os
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("❌ Pillow not installed. Run: python3 -m pip install --user Pillow")
    sys.exit(1)


# Apple-style squircle: superellipse with exponent n. n=5 matches macOS icons closely.
SQUIRCLE_N = 5.0
# Padding from canvas edge as a fraction of canvas size.
# Measured against the Nano Banana source via pixel probing: the baked-in fake
# transparency checkerboard extends to ~10.7% of the canvas before the real
# squircle starts, so the mask insets 11% to land on pure artwork. This also
# matches Apple's ~10% icon margin guideline.
# Override at runtime: VF_ICON_PADDING=0.08 ./scripts/squircle-mask.py …
PADDING_RATIO = float(os.environ.get("VF_ICON_PADDING", "0.11"))


def make_squircle_mask(size: int, n: float = SQUIRCLE_N, pad: int = 0) -> Image.Image:
    """Build an L-mode mask of a squircle inscribed in (size × size) with `pad` margin."""
    mask = Image.new("L", (size, size), 0)
    px = mask.load()
    inner = size - 2 * pad
    if inner <= 0:
        return mask
    cx = cy = size / 2.0
    half = inner / 2.0
    for y in range(size):
        ny = (y - cy) / half
        if abs(ny) >= 1.0:
            continue
        # Solve |x|^n + |y|^n = 1 for x at this y
        x_max_norm = (1.0 - abs(ny) ** n) ** (1.0 / n)
        x_max = x_max_norm * half
        x0 = max(0, int(cx - x_max))
        x1 = min(size, int(cx + x_max) + 1)
        for x in range(x0, x1):
            nx = (x - cx) / half
            if abs(nx) ** n + abs(ny) ** n <= 1.0:
                px[x, y] = 255
    return mask


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: squircle-mask.py input.png [output.png]")
        return 2
    src = Path(sys.argv[1]).expanduser()
    dst = Path(sys.argv[2]).expanduser() if len(sys.argv) >= 3 else src
    if not src.exists():
        print(f"❌ Not found: {src}")
        return 1

    img = Image.open(src).convert("RGBA")
    w, h = img.size
    if w != h:
        # Center-crop to square first
        side = min(w, h)
        left = (w - side) // 2
        top = (h - side) // 2
        img = img.crop((left, top, left + side, top + side))

    size = img.size[0]
    pad = int(size * PADDING_RATIO)
    mask = make_squircle_mask(size, n=SQUIRCLE_N, pad=pad)

    # Build output by compositing the source onto a transparent canvas using the mask.
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask=mask)

    out.save(dst, format="PNG")
    print(f"✅ Squircle mask applied  →  {dst}  ({size}×{size}, padding {pad}px)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
