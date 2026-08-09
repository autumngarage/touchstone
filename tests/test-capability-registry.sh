#!/usr/bin/env bash
#
# tests/test-capability-registry.sh — every shipped capability declares a
# mission job, and every declared capability exists.
#
# This is the deterministic half of Touchstone's scope filter. The filter
# itself ("does it constrain the agent, or merely serve it?") lives in
# TOUCHSTONE.md and is a judgement call. What this test enforces is that the
# judgement is *made and recorded* — a new script cannot enter the shipped
# surface by simply existing.
#
# Fast tier: deterministic, offline, no network, no model quota.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="$TOUCHSTONE_ROOT/capabilities.toml"

# shellcheck source=../lib/toml.sh
source "$TOUCHSTONE_ROOT/lib/toml.sh"

FAILURES=0
fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}
pass() { echo "  ok  $*"; }

[ -f "$REGISTRY" ] || {
  echo "FAIL: capabilities.toml is missing" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Load the registry. toml_parse hands the section name back with its quotes.
# ---------------------------------------------------------------------------
REG_DIR="$(mktemp -d -t touchstone-capreg.XXXXXX)"
trap 'rm -rf "$REG_DIR"' EXIT

registry_collect() {
  local section="$1" key="$2" value="$3" path entry
  path="$(toml_unquote "$section")"
  [ -n "$path" ] || return 0
  entry="$REG_DIR/$(printf '%s' "$path" | tr '/' '%')"
  printf '%s\t%s\n' "$key" "$value" >>"$entry"
  printf '%s\n' "$path" >>"$REG_DIR/.paths"
}

: >"$REG_DIR/.paths"
toml_parse "$REGISTRY" registry_collect

declared_paths() { sort -u "$REG_DIR/.paths"; }

entry_file() { printf '%s/%s' "$REG_DIR" "$(printf '%s' "$1" | tr '/' '%')"; }

entry_value() {
  local path="$1" key="$2" file
  file="$(entry_file "$path")"
  [ -f "$file" ] || return 1
  # Print everything after the first tab. Assigning $1="" would rebuild the
  # record with OFS (a space), silently prefixing every value.
  awk -F'\t' -v k="$key" '$1 == k { print substr($0, index($0, "\t") + 1); exit }' "$file"
}

# ---------------------------------------------------------------------------
# 1. Shipped surface == declared surface, in both directions.
# ---------------------------------------------------------------------------
echo "==> surface parity"
SHIPPED="$REG_DIR/.shipped"
: >"$SHIPPED"
for f in "$TOUCHSTONE_ROOT"/bin/touchstone \
  "$TOUCHSTONE_ROOT"/bootstrap/*.sh \
  "$TOUCHSTONE_ROOT"/hooks/*.sh \
  "$TOUCHSTONE_ROOT"/lib/*.sh \
  "$TOUCHSTONE_ROOT"/scripts/*.sh; do
  [ -f "$f" ] || continue
  printf '%s\n' "${f#"$TOUCHSTONE_ROOT"/}" >>"$SHIPPED"
done
sort -u -o "$SHIPPED" "$SHIPPED"

while IFS= read -r path; do
  grep -qxF "$path" "$SHIPPED" || fail "$path is declared in capabilities.toml but does not exist"
done < <(declared_paths)

while IFS= read -r path; do
  declared_paths | grep -qxF "$path" \
    || fail "$path ships but is not declared in capabilities.toml — declare its mission job or delete it"
done <"$SHIPPED"

[ "$FAILURES" -eq 0 ] && pass "$(wc -l <"$SHIPPED" | tr -d ' ') shipped files, all declared"

# ---------------------------------------------------------------------------
# 2. Each entry declares a valid job and a non-boilerplate why.
# ---------------------------------------------------------------------------
echo "==> entry validity"
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
          if ! declared_paths | grep -qxF "$dep"; then
            fail "$path serves '$dep', which is not a declared capability"
            continue
          fi
          dep_job="$(entry_value "$dep" job || true)"
          [ "$dep_job" = "support" ] \
            && fail "$path serves '$dep', which is itself support — support must bottom out in a mission job"
        done
      fi
      ;;
    mirror)
      target="$(entry_value "$path" mirrors || true)"
      if [ -z "$target" ]; then
        fail "$path is a mirror but names no target (mirrors = \"...\")"
      elif [ ! -f "$TOUCHSTONE_ROOT/$target" ]; then
        fail "$path mirrors '$target', which does not exist"
      elif ! cmp -s "$TOUCHSTONE_ROOT/$path" "$TOUCHSTONE_ROOT/$target"; then
        fail "$path has drifted from its mirror target '$target' — they must stay byte-identical"
      fi
      ;;
    cut)
      tracked="$(entry_value "$path" tracked || true)"
      case "$tracked" in
        \#[0-9]*) CUT_COUNT=$((CUT_COUNT + 1)) ;;
        "") fail "$path is marked cut but names no tracking issue (tracked = \"#N\")" ;;
        *) fail "$path has tracked='$tracked'; expected an issue reference like \"#694\"" ;;
      esac
      ;;
  esac
done < <(declared_paths)

[ "$FAILURES" -eq 0 ] && pass "all entries declare a valid job, why, and job-specific requirements"

# ---------------------------------------------------------------------------
# 3. Report the condemned surface. Visible every run, never silently normal.
# ---------------------------------------------------------------------------
echo "==> scope debt"
if [ "$CUT_COUNT" -eq 0 ]; then
  pass "no capabilities are awaiting removal"
else
  cut_lines=0
  while IFS= read -r path; do
    [ "$(entry_value "$path" job || true)" = "cut" ] || continue
    n="$(wc -l <"$TOUCHSTONE_ROOT/$path" | tr -d ' ')"
    cut_lines=$((cut_lines + n))
    echo "  cut  $path ($n lines, $(entry_value "$path" tracked))"
  done < <(declared_paths)
  echo "  $CUT_COUNT capabilit$([ "$CUT_COUNT" -eq 1 ] && echo y || echo ies) awaiting removal, $cut_lines lines"
fi

echo
if [ "$FAILURES" -ne 0 ]; then
  echo "capability registry: $FAILURES failure(s)" >&2
  exit 1
fi
echo "capability registry: all checks passed"
