#!/usr/bin/env bash
#
# tests/test-steering-size-caps.sh — scope guardrails: steering-doc size caps
# and the capability registry that governs the shipped executable surface.
#
# The whole point of the TOUCHSTONE.md routing layer is to keep auto-loaded
# context lean: rules that fire on every turn live in TOUCHSTONE.md (which
# CLAUDE.md @-imports and AGENTS.md/GEMINI.md inline via the managed block),
# and everything else is routed via skills or principles/*.md.
#
# These caps catch the failure mode where someone adds a fourth section to
# TOUCHSTONE.md without thinking about the per-turn cost. If a cap is hit,
# either:
#   - move the new content to principles/* or skills/ and route to it from
#     the TOUCHSTONE.md routing table, OR
#   - raise the cap deliberately, with the reasoning documented in the
#     commit message.
#
# Codex's project_doc_max_bytes default is 32 KiB; AGENTS.md staying under
# 24 KiB leaves headroom for project-specific tail content.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ERRORS=0
fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

assert_under() {
  local label="$1" path="$2" cap_bytes="$3"
  if [ ! -f "$path" ]; then
    fail "$label: file not found: $path"
    return
  fi
  local actual
  actual="$(wc -c <"$path" | tr -d '[:space:]')"
  if [ "$actual" -gt "$cap_bytes" ]; then
    fail "$label: $path is $actual bytes, cap is $cap_bytes (raise the cap deliberately or trim the file)"
  else
    printf '  OK: %s — %s bytes (cap %s)\n' "$label" "$actual" "$cap_bytes"
  fi
}

echo "==> TOUCHSTONE.md size cap (8 KiB — lean router)"
assert_under "TOUCHSTONE.md" "$TOUCHSTONE_ROOT/TOUCHSTONE.md" 8192

echo "==> AGENTS.md size cap (24 KiB — leaves headroom under Codex's 32 KiB default)"
assert_under "AGENTS.md" "$TOUCHSTONE_ROOT/AGENTS.md" 24576
assert_under "templates/AGENTS.md" "$TOUCHSTONE_ROOT/templates/AGENTS.md" 24576

echo "==> GEMINI.md size cap (24 KiB — same headroom)"
assert_under "GEMINI.md" "$TOUCHSTONE_ROOT/GEMINI.md" 24576
assert_under "templates/GEMINI.md" "$TOUCHSTONE_ROOT/templates/GEMINI.md" 24576

# =============================================================================
# Capability registry — the same guardrail applied to the executable surface.
#
# The size caps above stop steering docs growing without a decision. These
# checks stop the shipped code surface growing without one: every file under
# the governed directories must declare, in capabilities.toml, which of the
# three mission jobs it serves (TOUCHSTONE.md "Scope"). A new script cannot
# enter the product by simply existing.
#
# These live here rather than in their own file because the repo's review
# guide asks new assertions to join an existing self-test, and because
# preflight already selects this test for steering paths — folding them in
# means a governed-path change cannot skip the parity check (PR #703 review).
# =============================================================================

REGISTRY="$TOUCHSTONE_ROOT/capabilities.toml"
# shellcheck source=../lib/toml.sh
source "$TOUCHSTONE_ROOT/lib/toml.sh"

echo "==> capability registry: surface parity"

if [ ! -f "$REGISTRY" ]; then
  fail "capabilities.toml is missing"
else
  REG_DIR="$(mktemp -d -t touchstone-capreg.XXXXXX)"
  trap 'rm -rf "$REG_DIR"' EXIT

  registry_collect() {
    local section="$1" key="$2" value="$3" path
    path="$(toml_unquote "$section")"
    [ -n "$path" ] || return 0
    printf '%s\t%s\n' "$key" "$value" >>"$REG_DIR/$(printf '%s' "$path" | tr '/' '%')"
    printf '%s\n' "$path" >>"$REG_DIR/paths.raw"
  }

  : >"$REG_DIR/paths.raw"
  toml_parse "$REGISTRY" registry_collect
  # Materialize the declared set ONCE. Re-sorting it per entry made this
  # check quadratic in capability count (PR #703 review).
  sort -u "$REG_DIR/paths.raw" >"$REG_DIR/declared"

  entry_value() {
    local file
    file="$REG_DIR/$(printf '%s' "$1" | tr '/' '%')"
    [ -f "$file" ] || return 1
    # Print everything after the first tab. Assigning $1="" would rebuild the
    # record with OFS (a space) and silently prefix every value.
    awk -F'\t' -v k="$2" '$1 == k { print substr($0, index($0, "\t") + 1); exit }' "$file"
  }

  # Enumerate the governed surface RECURSIVELY. Top-level globs let a file in
  # a subdirectory (scripts/helpers/check.sh) or without a .sh suffix ship
  # undeclared, which is the exact hole this check exists to close (PR #703
  # review). Exclusions are explicit: dotfiles and prose.
  #
  # Symlinks count too: `-type f` alone let a symlinked capability ship with no
  # declaration at all, and the check still reported full parity (PR #703
  # review). `\( -type f -o -type l \)` covers both.
  #
  # Enumerated from INSIDE $TOUCHSTONE_ROOT so paths come out relative. Piping
  # absolute paths through `sed "s|^$TOUCHSTONE_ROOT/||"` interpolates the
  # checkout path into a regex, so a directory containing `[` or `.` would
  # fail to strip and every file would read as undeclared (PR #703 review).
  (
    cd "$TOUCHSTONE_ROOT" || exit 1
    find bin bootstrap hooks lib scripts \
      \( -type f -o -type l \) ! -name '.*' ! -name '*.md' -print 2>/dev/null
  ) | sort -u >"$REG_DIR/shipped"

  while IFS= read -r path; do
    grep -qxF "$path" "$REG_DIR/shipped" \
      || fail "capabilities.toml declares $path, which does not exist"
  done <"$REG_DIR/declared"

  while IFS= read -r path; do
    grep -qxF "$path" "$REG_DIR/declared" \
      || fail "$path ships but is not declared in capabilities.toml — declare its mission job or delete it"
  done <"$REG_DIR/shipped"

  printf '  OK: %s shipped files enumerated, %s declared\n' \
    "$(wc -l <"$REG_DIR/shipped" | tr -d ' ')" "$(wc -l <"$REG_DIR/declared" | tr -d ' ')"

  echo "==> capability registry: entry validity"
  CUT_COUNT=0
  while IFS= read -r path; do
    job="$(entry_value "$path" job || true)"
    why="$(entry_value "$path" why || true)"

    case "$job" in
      constrain | legible | carry | support | mirror | cut) ;;
      "") fail "$path declares no job" ;;
      *) fail "$path declares unknown job '$job'" ;;
    esac

    if [ -z "$why" ]; then
      fail "$path declares no why"
    elif [ "${#why}" -lt 30 ]; then
      fail "$path has a why of ${#why} chars; say what the file does, not what category it is"
    fi

    case "$job" in
      support)
        serves="$(entry_value "$path" serves || true)"
        if [ -z "$serves" ]; then
          fail "$path is support but names no consumers (serves = [...])"
        else
          for dep in $(toml_normalize_array "$serves" | tr ',' ' '); do
            [ -n "$dep" ] || continue
            if ! grep -qxF "$dep" "$REG_DIR/declared"; then
              fail "$path serves '$dep', which is not a declared capability"
              continue
            fi
            [ "$(entry_value "$dep" job || true)" = "support" ] \
              && fail "$path serves '$dep', which is itself support — support must bottom out in a mission job"
          done
        fi
        ;;
      mirror)
        target="$(entry_value "$path" mirrors || true)"
        target_job="$(entry_value "$target" job 2>/dev/null || true)"
        if [ -z "$target" ]; then
          fail "$path is a mirror but names no target (mirrors = \"...\")"
        elif [ "$target" = "$path" ]; then
          # A self-mirror satisfies "target exists" and "cmp matches" while
          # never bottoming out in a mission job — a free pass through the
          # whole check (PR #703 review).
          fail "$path mirrors itself; a mirror must point at another capability"
        elif [ ! -f "$TOUCHSTONE_ROOT/$target" ]; then
          fail "$path mirrors '$target', which does not exist"
        elif ! grep -qxF "$target" "$REG_DIR/declared"; then
          fail "$path mirrors '$target', which is not a declared capability"
        elif [ "$target_job" = "mirror" ] || [ "$target_job" = "cut" ] || [ -z "$target_job" ]; then
          fail "$path mirrors '$target' (job='$target_job'); a mirror must resolve to a real mission job"
        elif ! cmp -s "$TOUCHSTONE_ROOT/$path" "$TOUCHSTONE_ROOT/$target"; then
          fail "$path has drifted from its mirror target '$target' — they must stay byte-identical"
        fi
        ;;
      cut)
        tracked="$(entry_value "$path" tracked || true)"
        # Anchored: a glob like #[0-9]* also accepts "#7oops" and would let a
        # condemned file pass with no real tracking issue (PR #703 review).
        if printf '%s' "$tracked" | grep -qE '^#[0-9]+$'; then
          CUT_COUNT=$((CUT_COUNT + 1))
        elif [ -z "$tracked" ]; then
          fail "$path is marked cut but names no tracking issue (tracked = \"#N\")"
        else
          fail "$path has tracked='$tracked'; expected an issue reference like \"#694\""
        fi
        ;;
    esac
  done <"$REG_DIR/declared"

  echo "==> capability registry: scope debt"
  if [ "$CUT_COUNT" -eq 0 ]; then
    echo "  OK: no capabilities are awaiting removal"
  else
    cut_lines=0
    while IFS= read -r path; do
      [ "$(entry_value "$path" job || true)" = "cut" ] || continue
      n="$(wc -l <"$TOUCHSTONE_ROOT/$path" | tr -d ' ')"
      cut_lines=$((cut_lines + n))
      printf '  cut: %s (%s lines, %s)\n' "$path" "$n" "$(entry_value "$path" tracked)"
    done <"$REG_DIR/declared"
    printf '  %s capabilities awaiting removal, %s lines\n' "$CUT_COUNT" "$cut_lines"
  fi
fi

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS scope-guardrail check(s) failed"
  exit 1
fi
echo ""
echo "==> PASS: steering-doc size caps and capability registry are respected"
