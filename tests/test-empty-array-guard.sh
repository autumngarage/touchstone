#!/usr/bin/env bash
#
# tests/test-empty-array-guard.sh — guard against the bash 3.2 empty-array bug.
#
# Under bash 3.2 (macOS /bin/bash), "${arr[@]}" aborts with "arr[@]: unbound
# variable" when arr is empty and set -u is active. Bash 4.4+ treats it as an
# empty expansion. The safe idiom for both versions is:
#
#   ${arr[@]+"${arr[@]}"}
#
# This test heuristically scans every shell script Touchstone ships for the
# unsafe pattern: a name declared as =() somewhere in the same file and later
# expanded as "${name[@]}" without the guard. False positives are possible
# (e.g., array always populated before expansion); silence them with a
# trailing inline comment:  # empty-array-guard: safe — <reason>
#
# The check is intentionally heuristic — not a full dataflow analysis — so it
# may miss cross-file bugs. The goal is to catch the next "local foo=(); ...
# ${foo[@]}" pattern before it ships.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ERRORS=0
FILES_CHECKED=0

check_file() {
  local file="$1"
  local found_error=false

  # Collect array names declared as =() in this file.
  local declared_arrays=()
  while IFS= read -r line; do
    # Match: optional whitespace, optional "local ", name=()
    name="$(printf '%s' "$line" | sed 's/^[[:space:]]*//' | sed 's/^local[[:space:]][[:space:]]*//' | sed 's/=().*//')"
    # Ignore if name contains spaces or special chars (not a variable name).
    case "$name" in
      *[[:space:]]*|*[!a-zA-Z0-9_]*) continue ;;
    esac
    declared_arrays+=("$name")
  done < <(grep -E '^\s*(local\s+)?[a-zA-Z_][a-zA-Z0-9_]*=\(\)' "$file" 2>/dev/null || true)

  if [ "${#declared_arrays[@]}" -eq 0 ]; then
    return 0
  fi

  # For each declared array, look for unguarded expansion in the same file.
  local name
  for name in ${declared_arrays[@]+"${declared_arrays[@]}"}; do
    # Look for "${name[@]}" — unguarded expansion (fixed-string search avoids
    # bracket-class ambiguity in ERE when name contains no special chars).
    if grep -Fn '"${'"$name"'[@]}"' "$file" 2>/dev/null | \
         grep -v 'empty-array-guard: safe' >/dev/null 2>&1; then
      # Treat the expansion as guarded if the file uses any of:
      #   ${name[@]+"${name[@]}"}  — the direct bash 3.2 idiom
      #   ${#name[@]}              — a length check guards the expansion site
      if ! grep -qF '${'"$name"'[@]+' "$file" 2>/dev/null && \
         ! grep -qF '${#'"$name"'[@]}' "$file" 2>/dev/null; then
        echo "  WARN: $file: '${name}' declared =() but expanded as \"\${${name}[@]}\" without guard" >&2
        echo "        Use: \${${name}[@]+\"\${${name}[@]}\"}" >&2
        grep -Fn '"${'"$name"'[@]}"' "$file" 2>/dev/null | head -5 >&2 || true
        found_error=true
      fi
    fi
  done

  if [ "$found_error" = true ]; then
    ERRORS=$((ERRORS + 1))
  fi
}

# Scan all shell scripts Touchstone ships or uses.
while IFS= read -r file; do
  [ -n "$file" ] || continue
  check_file "$file"
  FILES_CHECKED=$((FILES_CHECKED + 1))
done < <(
  find \
    "$TOUCHSTONE_ROOT/bin" \
    "$TOUCHSTONE_ROOT/hooks" \
    "$TOUCHSTONE_ROOT/scripts" \
    "$TOUCHSTONE_ROOT/bootstrap" \
    "$TOUCHSTONE_ROOT/lib" \
    "$TOUCHSTONE_ROOT/tests" \
    -maxdepth 1 -type f \( -name '*.sh' -o -name 'touchstone' \) -print 2>/dev/null | sort
)

echo "==> Test: empty-array guard check on $FILES_CHECKED shell scripts"

if [ "$ERRORS" -gt 0 ]; then
  echo "" >&2
  echo "FAIL: $ERRORS file(s) have unguarded empty-array expansions." >&2
  echo "      These abort under bash 3.2 + set -u (macOS /bin/bash)." >&2
  echo "      Replace \"\${name[@]}\" with \${name[@]+\"\${name[@]}\"}" >&2
  echo "      or add '# empty-array-guard: safe — <reason>' to suppress." >&2
  exit 1
fi

echo "==> PASS: no unguarded empty-array expansions found"
