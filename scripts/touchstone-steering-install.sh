#!/usr/bin/env bash
#
# scripts/touchstone-steering-install.sh — put the universal contract where
# every agent on this machine reads it.
#
# Usage:
#   bash scripts/touchstone-steering-install.sh install [--home DIR] [--dry-run]
#   bash scripts/touchstone-steering-install.sh check   [--home DIR]
#   bash scripts/touchstone-steering-install.sh uninstall [--home DIR]
#
# Steering was the only Touchstone layer that propagated by copying. Merge
# rules live in one GitHub ruleset, the validation workflow in one pinned SHA,
# tool logic in one Homebrew formula — but the contract itself was pasted into
# every consumer, so every edit meant a pull request per repository. Measured
# 2026-08-18: zero of ten consumer copies matched, and several instructed
# agents to do what the contract forbids.
#
# This installs it once per machine instead. Claude Code, Codex, and Gemini
# each read a user-level instruction file and layer project files over it, so
# a managed block there reaches every repository at once and a project keeps
# the last word.
#
# The block is delimited, idempotent, and never touches a byte outside its
# markers. Content you wrote in those files is yours.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE="$ROOT/TOUCHSTONE.md"
BEGIN_MARKER='<!-- touchstone:steering:start -->'
END_MARKER='<!-- touchstone:steering:end -->'

# driver:relative path. Every supported driver reads a user-level instruction
# file and layers project files over it.
TARGETS=(
  "claude:.claude/CLAUDE.md"
  "codex:.codex/AGENTS.md"
  "gemini:.gemini/GEMINI.md"
)

ACTION="${1:-}"
[ -n "$ACTION" ] || {
  sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
shift

HOME_DIR="${HOME:-}"
DRY_RUN=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      [ "$#" -ge 2 ] || {
        echo "ERROR: --home requires a directory" >&2
        exit 2
      }
      HOME_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[ -n "$HOME_DIR" ] || die "no home directory: set HOME or pass --home"
[ -f "$SOURCE" ] || die "canonical steering is missing: $SOURCE"

# A marker line in the source would be copied into the block and make the very
# next check reject it.
for marker in "$BEGIN_MARKER" "$END_MARKER"; do
  if awk -v m="$marker" '$0 == m { found = 1 } END { exit !found }' "$SOURCE"; then
    die "canonical steering contains a managed marker line; document markers only in inline code"
  fi
done

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-steering-install.XXXXXX")" || die "could not create workspace"
trap 'rm -rf "$TMP_DIR"' EXIT

render_block() {
  local out="$1"
  {
    printf '%s\n' "$BEGIN_MARKER"
    cat <<'EOF'

<!-- Installed by touchstone. Do not edit between the markers; edit the
     project's TOUCHSTONE.md upstream and reinstall. Everything outside the
     markers is yours. Remove with: touchstone steering uninstall -->
EOF
    cat "$SOURCE"
    if [ -n "$(tail -c 1 "$SOURCE")" ]; then printf '\n'; fi
    printf '%s\n' "$END_MARKER"
  } >"$out"
}

# Rebuild one file: everything before the block, the block, everything after.
# Byte-exact outside the markers, including a tail that ends without a newline.
compose() {
  local path="$1" block="$2" out="$3" begin_line end_line begin_count end_count tail_offset

  if [ ! -f "$path" ]; then
    cat "$block" >"$out"
    return 0
  fi

  begin_count="$(awk -v m="$BEGIN_MARKER" '$0 == m { c++ } END { print c + 0 }' "$path")"
  end_count="$(awk -v m="$END_MARKER" '$0 == m { c++ } END { print c + 0 }' "$path")"

  if [ "$begin_count" = 0 ] && [ "$end_count" = 0 ]; then
    # No managed block yet: append, preserving the operator's own content.
    cat "$path" >"$out"
    if [ -s "$path" ] && [ -n "$(tail -c 1 "$path")" ]; then printf '\n' >>"$out"; fi
    printf '\n' >>"$out"
    cat "$block" >>"$out"
    return 0
  fi

  [ "$begin_count" = 1 ] || die "$path has $begin_count exact-line start markers, expected 0 or 1"
  [ "$end_count" = 1 ] || die "$path has $end_count exact-line end markers, expected 0 or 1"
  begin_line="$(awk -v m="$BEGIN_MARKER" '$0 == m { print NR; exit }' "$path")"
  end_line="$(awk -v m="$END_MARKER" '$0 == m { print NR; exit }' "$path")"
  [ "$begin_line" -lt "$end_line" ] || die "$path has its end marker before its start marker"

  if [ "$((begin_line - 1))" -gt 0 ]; then
    head -n "$((begin_line - 1))" "$path" >"$out"
  else
    : >"$out"
  fi
  cat "$block" >>"$out"
  tail_offset="$(head -n "$end_line" "$path" | wc -c | tr -d ' ')"
  tail -c "+$((tail_offset + 1))" "$path" >>"$out"
}

# Remove the block and the blank line that introduced it, leaving the rest
# byte-identical.
compose_removal() {
  local path="$1" out="$2" begin_line end_line tail_offset
  begin_line="$(awk -v m="$BEGIN_MARKER" '$0 == m { print NR; exit }' "$path")"
  end_line="$(awk -v m="$END_MARKER" '$0 == m { print NR; exit }' "$path")"
  [ -n "$begin_line" ] && [ -n "$end_line" ] || return 1
  local keep=$((begin_line - 1))
  if [ "$keep" -gt 0 ] && [ -z "$(sed -n "${keep}p" "$path")" ]; then
    keep=$((keep - 1))
  fi
  if [ "$keep" -gt 0 ]; then
    head -n "$keep" "$path" >"$out"
  else
    : >"$out"
  fi
  tail_offset="$(head -n "$end_line" "$path" | wc -c | tr -d ' ')"
  tail -c "+$((tail_offset + 1))" "$path" >>"$out"
}

BLOCK="$TMP_DIR/block"
render_block "$BLOCK"

CHANGED=0
DRIFTED=0

for entry in "${TARGETS[@]}"; do
  driver="${entry%%:*}"
  relative="${entry#*:}"
  path="$HOME_DIR/$relative"
  composed="$TMP_DIR/$driver"

  case "$ACTION" in
    install | check)
      compose "$path" "$BLOCK" "$composed"
      ;;
    uninstall)
      if [ ! -f "$path" ] || ! compose_removal "$path" "$composed"; then
        printf '  absent: %s\n' "$relative"
        continue
      fi
      ;;
    *) die "unknown action '$ACTION'; expected install, check, or uninstall" ;;
  esac

  # check compares the managed block only. Comparing whole files would call
  # every operator edit outside the markers "drift", and comparing against a
  # tail rebuilt from the same file would hide real block drift.
  if [ "$ACTION" = check ]; then
    if [ -f "$path" ] \
      && awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" \
        '$0 == b { inside = 1 } inside { print } $0 == e { inside = 0 }' "$path" \
      | cmp -s - "$BLOCK"; then
      printf '  ok: %s carries the current contract\n' "$relative"
    else
      printf '  DRIFT: %s does not carry the current contract\n' "$relative" >&2
      DRIFTED=$((DRIFTED + 1))
    fi
    continue
  fi

  if [ -f "$path" ] && cmp -s "$path" "$composed"; then
    continue
  fi

  if [ "$DRY_RUN" = true ]; then
    printf '  would update: %s\n' "$path"
    CHANGED=$((CHANGED + 1))
    continue
  fi

  mkdir -p "$(dirname "$path")" || die "could not create $(dirname "$path")"
  staged="$path.touchstone-steering.$$"
  cp "$composed" "$staged" || {
    rm -f -- "$staged"
    die "could not stage $path"
  }
  mv -f -- "$staged" "$path" || {
    rm -f -- "$staged"
    die "could not write $path"
  }
  printf '  %s: %s\n' "$([ "$ACTION" = uninstall ] && printf removed || printf installed)" "$relative"
  CHANGED=$((CHANGED + 1))
done

case "$ACTION" in
  check)
    if [ "$DRIFTED" -ne 0 ]; then
      echo "ERROR: $DRIFTED user-level steering file(s) do not carry the current contract" >&2
      echo "Run: touchstone steering install" >&2
      exit 1
    fi
    echo "==> PASS: every supported driver reads the current contract"
    ;;
  install)
    if [ "$CHANGED" -eq 0 ]; then
      echo "==> already current: machine-level steering matches the contract"
    else
      echo "==> steering reaches every agent on this machine; repositories carry none"
    fi
    ;;
  uninstall)
    echo "==> removed from $CHANGED file(s); content outside the markers untouched"
    ;;
esac
