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

# The source must not itself contain a marker line: the block copy would
# inject a second marker into every target, and the very next validation
# would reject all four files the render just reported as updated.
for marker in "$BEGIN_MARKER" "$END_MARKER"; do
  if awk -v m="$marker" '$0 == m { found = 1 } END { exit !found }' "$SOURCE"; then
    die "canonical steering contains a managed marker line; document markers only in inline code, never on their own line"
  fi
done

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
  local path="$1" out="$2" begin_count end_count begin_line end_line tail_offset
  # Whole-line counts, matching the awk extraction below exactly. grep -cF
  # also counts indented or embedded occurrences, which awk would then miss —
  # the render would copy the whole file and append a second block, exiting 0.
  begin_count="$(awk -v m="$BEGIN_MARKER" '$0 == m { c++ } END { print c + 0 }' "$path")"
  end_count="$(awk -v m="$END_MARKER" '$0 == m { c++ } END { print c + 0 }' "$path")"
  [ "$begin_count" = 1 ] || die "$path has $begin_count exact-line start markers, expected exactly 1 (an indented or embedded marker does not count)"
  [ "$end_count" = 1 ] || die "$path has $end_count exact-line end markers, expected exactly 1 (an indented or embedded marker does not count)"
  begin_line="$(awk -v m="$BEGIN_MARKER" '$0 == m { print NR; exit }' "$path")"
  end_line="$(awk -v m="$END_MARKER" '$0 == m { print NR; exit }' "$path")"
  [ "$begin_line" -lt "$end_line" ] || die "$path has its end marker before its start marker"
  head -n "$((begin_line - 1))" "$path" >"$out"
  printf '%s\n' "$BEGIN_MARKER" >>"$out"
  header >>"$out"
  cat "$SOURCE" >>"$out"
  # A source without a final newline would weld the end marker onto its last
  # line, producing a block the next validation rejects. Normalize inside the
  # managed block only; the source file itself is not touched.
  if [ -n "$(tail -c 1 "$SOURCE")" ]; then
    printf '\n' >>"$out"
  fi
  printf '%s\n' "$END_MARKER" >>"$out"
  # Byte-exact tail: awk print would append a newline to project-owned content
  # that ends without one, mutating bytes outside the markers in violation of
  # the ownership boundary. Copy from the byte after the end-marker line.
  tail_offset="$(head -n "$end_line" "$path" | wc -c | tr -d ' ')"
  tail -c "+$((tail_offset + 1))" "$path" >>"$out"
}

DRIFTED=0
CHANGED=0

# Phase 1: validate and render every target into the workspace. A malformed
# fourth target must not leave the first three already replaced, so no target
# is touched until every render has succeeded.
for target in "${TARGETS[@]}"; do
  path="$ROOT/$target"
  [ -f "$path" ] || die "steering target is missing: $target"
  rendered="$TMP_DIR/$(printf '%s' "$target" | tr '/' '_')"
  render_one "$path" "$rendered"
done

# Phase 2: report or install. Every render above succeeded.
for target in "${TARGETS[@]}"; do
  path="$ROOT/$target"
  rendered="$TMP_DIR/$(printf '%s' "$target" | tr '/' '_')"

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

  # Same-directory staging plus rename: a redirection onto the target would
  # truncate it before writing, so a full disk or an interrupt mid-copy could
  # destroy project-owned bytes the error path cannot restore. rename(2)
  # within one filesystem replaces the file whole or not at all.
  staged="$path.render-steering.$$"
  if ! cp "$rendered" "$staged"; then
    rm -f -- "$staged"
    die "could not stage $target"
  fi
  mv -f -- "$staged" "$path" || {
    rm -f -- "$staged"
    die "could not replace $target"
  }
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
