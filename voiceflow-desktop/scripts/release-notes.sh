#!/usr/bin/env bash
# release-notes.sh — append (or finalise) an entry in CHANGELOG.md.
#
# Two modes:
#   1. Append to "Unreleased" (default)
#         scripts/release-notes.sh
#         → reads commits since the latest git tag (or all commits if none)
#         → groups commits by Keep-a-Changelog section based on subject prefix
#         → prepends them under the existing "## [Unreleased]" heading
#
#   2. Roll "Unreleased" → versioned section
#         scripts/release-notes.sh 0.3.0
#         → renames the current "## [Unreleased]" heading to
#           "## [0.3.0] — YYYY-MM-DD"
#         → inserts a fresh empty "## [Unreleased]" above it
#         → optionally tags the commit (`git tag -a v0.3.0 -m "Voiceflow 0.3.0"`)
#           when --tag is passed
#
# Commit-subject conventions used by the auto-categoriser (case-insensitive):
#   add / feat / new      → ### Added
#   fix / bug             → ### Fixed
#   change / update / refactor → ### Changed
#   remove / drop         → ### Removed
#   docs / chore / build / ci → ### Internal
#   anything else         → ### Changed (default)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGELOG="$REPO_ROOT/CHANGELOG.md"
VERSION="${1:-}"
TAG_FLAG="${2:-}"

if [ ! -f "$CHANGELOG" ]; then
  echo "❌ CHANGELOG.md not found at $CHANGELOG"
  exit 1
fi

# ─── Resolve commit range ─────────────────────────────────────────────────────
LAST_TAG=$(git -C "$REPO_ROOT" describe --tags --abbrev=0 2>/dev/null || true)
if [ -n "$LAST_TAG" ]; then
  RANGE="${LAST_TAG}..HEAD"
  echo "▸ Commits since $LAST_TAG"
else
  RANGE=""
  echo "▸ No tags yet — using full history"
fi

# ─── Categorise commits into Keep-a-Changelog buckets ─────────────────────────
TMP=$(mktemp -d)
ADDED="$TMP/added"; FIXED="$TMP/fixed"; CHANGED="$TMP/changed"
REMOVED="$TMP/removed"; INTERNAL="$TMP/internal"
: > "$ADDED"; : > "$FIXED"; : > "$CHANGED"; : > "$REMOVED"; : > "$INTERNAL"

while IFS=$'\t' read -r subject hash; do
  [ -z "$subject" ] && continue
  # Skip "Co-Authored-By" footer lines and merge commits
  case "$subject" in Merge\ *) continue ;; esac

  lower=$(echo "$subject" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    add\ *|added\ *|feat\ *|feat:\ *|feature\ *|new\ *)
      echo "- $subject ($hash)" >> "$ADDED" ;;
    fix\ *|fixed\ *|fix:\ *|bug\ *|bugfix\ *)
      echo "- $subject ($hash)" >> "$FIXED" ;;
    remove\ *|removed\ *|drop\ *|delete\ *)
      echo "- $subject ($hash)" >> "$REMOVED" ;;
    docs\ *|chore\ *|build\ *|ci\ *|test\ *|refactor\ *|refactor:\ *)
      echo "- $subject ($hash)" >> "$INTERNAL" ;;
    *)
      echo "- $subject ($hash)" >> "$CHANGED" ;;
  esac
done < <(git -C "$REPO_ROOT" log --pretty=format:'%s%x09%h' $RANGE 2>/dev/null || true)

# ─── Build the markdown block ─────────────────────────────────────────────────
BLOCK="$TMP/block.md"
: > "$BLOCK"

emit_section() {
  local title="$1"; local file="$2"
  if [ -s "$file" ]; then
    {
      echo ""
      echo "### $title"
      cat "$file"
    } >> "$BLOCK"
  fi
}
emit_section "Added"    "$ADDED"
emit_section "Changed"  "$CHANGED"
emit_section "Fixed"    "$FIXED"
emit_section "Removed"  "$REMOVED"
emit_section "Internal" "$INTERNAL"

if [ ! -s "$BLOCK" ]; then
  echo "▸ No new commits since $LAST_TAG. Nothing to append."
  rm -rf "$TMP"
  [ -z "$VERSION" ] && exit 0
fi

# ─── Two paths: append to Unreleased vs. roll into a versioned section ───────
DATE=$(date +%Y-%m-%d)

if [ -z "$VERSION" ]; then
  # Append mode — insert BLOCK after the "## [Unreleased]" heading
  python3 - "$CHANGELOG" "$BLOCK" <<'PY'
import sys, re
path, block_path = sys.argv[1], sys.argv[2]
src = open(path).read()
block = open(block_path).read().rstrip() + "\n"

m = re.search(r"^## \[Unreleased\][^\n]*\n", src, flags=re.M)
if not m:
    print("❌ No '## [Unreleased]' heading found in CHANGELOG.md"); sys.exit(1)

# Skip any HTML comment immediately under the heading
insert_at = m.end()
tail = src[insert_at:]
comment = re.match(r"\n?<!--[^>]*-->\n", tail)
if comment:
    insert_at += comment.end()

new = src[:insert_at] + block + src[insert_at:]
open(path, "w").write(new)
print("✓ Appended", block_path, "under [Unreleased]")
PY
  echo "✅ Updated $CHANGELOG (Unreleased)"
else
  # Release mode — rename Unreleased to versioned + insert new empty Unreleased
  python3 - "$CHANGELOG" "$BLOCK" "$VERSION" "$DATE" <<'PY'
import sys, re
path, block_path, version, date = sys.argv[1:5]
src = open(path).read()
block = open(block_path).read().rstrip() + "\n"

m = re.search(r"^(## \[Unreleased\][^\n]*\n)(.*?)(?=^## \[)", src, flags=re.M | re.S)
if not m:
    # No prior versioned section yet — match Unreleased to the rest of file
    m = re.search(r"^(## \[Unreleased\][^\n]*\n)(.*)\Z", src, flags=re.M | re.S)
if not m:
    print("❌ No '## [Unreleased]' heading found"); sys.exit(1)

existing_unreleased = m.group(2).rstrip("\n")
# Combine the existing-Unreleased content with the freshly generated block
combined = (existing_unreleased + "\n" + block).strip("\n") + "\n"

new_section = f"## [Unreleased]\n\n<!-- New entries since the last tagged release land here. -->\n\n---\n\n## [{version}] — {date}\n\n{combined}"
src = src[:m.start()] + new_section + src[m.end():]
open(path, "w").write(src)
print(f"✓ Rolled Unreleased → [{version}] — {date}")
PY
  echo "✅ Updated $CHANGELOG ([${VERSION}])"

  if [ "$TAG_FLAG" = "--tag" ]; then
    git -C "$REPO_ROOT" tag -a "v${VERSION}" -m "Voiceflow ${VERSION}" 2>&1
    echo "✅ Tagged v${VERSION}"
  else
    echo "▸ Tip: review the diff, commit, then tag with: git tag -a v${VERSION} -m \"Voiceflow ${VERSION}\""
  fi
fi

rm -rf "$TMP"
