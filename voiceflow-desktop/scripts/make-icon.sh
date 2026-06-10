#!/usr/bin/env bash
# make-icon.sh — convert a 1024×1024 PNG into a macOS .icns bundle.
#
# Input:  voiceflow-desktop/AppIcon.png  (1024×1024, RGBA, squircle baked in)
# Output: voiceflow-desktop/VoiceflowDesktop/Resources/AppIcon.icns
#
# Usage: scripts/make-icon.sh [path/to/source.png]
#   defaults to AppIcon.png in repo root.
#
# Generates the full Apple-required iconset (16, 32, 128, 256, 512 plus @2x
# variants), then runs `iconutil` to bundle it into a single .icns file.

set -euo pipefail

# Resolve repo paths
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$REPO_ROOT/AppIcon.png}"
OUT_DIR="$REPO_ROOT/VoiceflowDesktop/Resources"
ICONSET="$REPO_ROOT/.build/AppIcon.iconset"
ICNS="$OUT_DIR/AppIcon.icns"

if [ ! -f "$SOURCE" ]; then
  echo "❌ Source PNG not found: $SOURCE"
  echo ""
  echo "   Drop your 1024×1024 RGBA PNG at:"
  echo "     $SOURCE"
  echo ""
  echo "   Then re-run: make icon"
  exit 1
fi

# Verify dimensions (≥ 1024×1024)
W=$(sips -g pixelWidth  "$SOURCE" | awk '/pixelWidth/  {print $2}')
H=$(sips -g pixelHeight "$SOURCE" | awk '/pixelHeight/ {print $2}')
if [ "$W" -lt 1024 ] || [ "$H" -lt 1024 ]; then
  echo "❌ Source must be at least 1024×1024 (got ${W}×${H})"
  exit 1
fi

echo "▸ Source: $SOURCE  (${W}×${H})"

# ── Optional: apply Apple-style squircle mask ──────────────────────────────────
# If the user passes --mask (or VF_ICON_MASK=1), or if the PNG has fewer than ~1%
# transparent pixels in the corners, run squircle-mask.py to clean it up.
PREPARED="$REPO_ROOT/.build/AppIcon.prepared.png"
mkdir -p "$REPO_ROOT/.build"

needs_mask=0
if [ "${1:-}" = "--mask" ] || [ "${VF_ICON_MASK:-0}" = "1" ]; then
  needs_mask=1
elif command -v python3 >/dev/null 2>&1; then
  # Probe top-left corner pixel — if it's not transparent, we likely need masking.
  alpha_tl=$(python3 -c "
from PIL import Image
img = Image.open(r'''$SOURCE''').convert('RGBA')
print(img.getpixel((2, 2))[3])
" 2>/dev/null) || alpha_tl="?"
  if [ "$alpha_tl" != "?" ] && [ "$alpha_tl" != "0" ]; then
    echo "▸ Top-left pixel alpha=$alpha_tl (not transparent) — applying squircle mask"
    needs_mask=1
  fi
fi

if [ "$needs_mask" = "1" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ python3 not found — needed for squircle mask. Install Python 3 or pre-mask the PNG."
    exit 1
  fi
  python3 "$REPO_ROOT/scripts/squircle-mask.py" "$SOURCE" "$PREPARED"
  SOURCE="$PREPARED"
else
  echo "▸ Source already has transparent corners — no mask needed"
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET" "$OUT_DIR"

# All sizes Apple's iconutil expects
declare -a SIZES=(
  "16    icon_16x16.png"
  "32    icon_16x16@2x.png"
  "32    icon_32x32.png"
  "64    icon_32x32@2x.png"
  "128   icon_128x128.png"
  "256   icon_128x128@2x.png"
  "256   icon_256x256.png"
  "512   icon_256x256@2x.png"
  "512   icon_512x512.png"
  "1024  icon_512x512@2x.png"
)

for entry in "${SIZES[@]}"; do
  read -r size name <<< "$entry"
  sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/$name" >/dev/null
  echo "  ✓ $name  (${size}×${size})"
done

iconutil -c icns "$ICONSET" -o "$ICNS"
echo ""
echo "✅ Built $ICNS"
ls -lh "$ICNS"
