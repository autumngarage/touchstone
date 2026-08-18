#!/usr/bin/env bash
#
# scripts/render-steering.sh — keep the managed steering blocks equal to
# TOUCHSTONE.md.
#
# Usage:
#   bash scripts/render-steering.sh           # rewrite every managed block
#   bash scripts/render-steering.sh --check   # report drift, change nothing
#
# TOUCHSTONE.md is canonical. AGENTS.md and GEMINI.md carry the same content
# inside `<!-- touchstone:steering:start -->` / `:end` markers because Codex and
# Gemini read those filenames; content outside the markers is the project's own
# and is never touched.
#
# This existed before as lib/touchstone-block.sh and went out with the strip,
# leaving the blocks hand-mirrored across four files. Hand-mirroring is how ten
# consumer repositories ended up with zero matching copies of this contract, and
# it taxes the most frequently edited file in the repository.
#
# --check is the half that matters: a renderer nobody runs still drifts.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE="$ROOT/TOUCHSTONE.md"
BEGIN_MARKER='<!-- touchstone:steering:start -->'
END_MARKER='<!-- touchstone:steering:end -->'

TARGETS=(
  "AGENTS.md"
  "GEMINI.md"
  "templates/AGENTS.md"
  "templates/GEMINI.md"
)

CHECK_ONLY=false
case "${1:-}" in
  --check) CHECK_ONLY=true ;;
  "") ;;
  -h | --help)
    sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
  *)
    echo "ERROR: unknown argument '$1'" >&2
    exit 2
    ;;
esac

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[ -f "$SOURCE" ] || die "canonical steering is missing: $SOURCE"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-render-steering.XXXXXX")" || die "could not create workspace"
trap 'rm -rf "$TMP_DIR"' EXIT

header() {
  cat <<'EOF'

<!-- Generated from TOUCHSTONE.md by scripts/render-steering.sh.
     Do not edit between the markers; edit TOUCHSTONE.md and re-run it.
     Content outside the markers is the project's own. -->
EOF
}

# Rebuild one file: everything before the start marker, the marker, the
# generated block, the end marker, then everything after it. Content outside
# the markers is copied byte for byte.
render_one() {
  local path="$1" out="$2" begin_count end_count
  begin_count="$(grep -cF "$BEGIN_MARKER" "$path" || true)"
  end_count="$(grep -cF "$END_MARKER" "$path" || true)"
  [ "$begin_count" = 1 ] || die "$path has $begin_count start markers, expected exactly 1"
  [ "$end_count" = 1 ] || die "$path has $end_count end markers, expected exactly 1"
  awk -v begin_marker="$BEGIN_MARKER" -v end_marker="$END_MARKER" \
    '$0 == begin_marker { exit } { print }' "$path" >"$out"
  printf '%s\n' "$BEGIN_MARKER" >>"$out"
  header >>"$out"
  cat "$SOURCE" >>"$out"
  printf '%s\n' "$END_MARKER" >>"$out"
  awk -v end_marker="$END_MARKER" \
    'seen { print } $0 == end_marker { seen = 1 }' "$path" >>"$out"
}

DRIFTED=0
CHANGED=0

for target in "${TARGETS[@]}"; do
  path="$ROOT/$target"
  [ -f "$path" ] || die "steering target is missing: $target"
  rendered="$TMP_DIR/$(printf '%s' "$target" | tr '/' '_')"
  render_one "$path" "$rendered"

  if cmp -s "$path" "$rendered"; then
    [ "$CHECK_ONLY" = true ] && printf '  ok: %s matches TOUCHSTONE.md\n' "$target"
    continue
  fi

  if [ "$CHECK_ONLY" = true ]; then
    printf '  DRIFT: %s does not match TOUCHSTONE.md\n' "$target" >&2
    diff "$path" "$rendered" | head -20 >&2 || true
    DRIFTED=$((DRIFTED + 1))
    continue
  fi

  cat "$rendered" >"$path" || die "could not write $target"
  printf '  updated: %s\n' "$target"
  CHANGED=$((CHANGED + 1))
done

if [ "$CHECK_ONLY" = true ]; then
  if [ "$DRIFTED" -ne 0 ]; then
    echo "ERROR: $DRIFTED managed block(s) drifted from TOUCHSTONE.md" >&2
    echo "Run: bash scripts/render-steering.sh" >&2
    exit 1
  fi
  echo "==> PASS: every managed block matches TOUCHSTONE.md"
  exit 0
fi

if [ "$CHANGED" -eq 0 ]; then
  echo "==> already current: no managed block changed"
else
  echo "==> rendered $CHANGED managed block(s) from TOUCHSTONE.md"
fi
