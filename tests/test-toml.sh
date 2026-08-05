#!/usr/bin/env bash
set -euo pipefail

# tests/test-toml.sh — verify the toml.sh library.

REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$REPO_ROOT/lib/toml.sh"

test_results=""
test_callback() {
  local section="$1"
  local key="$2"
  local value="$3"
  if [[ "$value" == "["* ]]; then
    value="$(toml_normalize_array "$value")"
  fi
  test_results="${test_results}${section}:${key}=${value}|"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: $msg"
    echo "  Expected: $expected"
    echo "  Actual:   $actual"
    exit 1
  else
    echo "PASS: $msg"
  fi
}

# Case 1: Simple keys
printf 'a = 1\nb = "two"' >test.toml
test_results=""
toml_parse test.toml test_callback
assert_eq ":a=1|:b=two|" "$test_results" "Simple keys"

# Case 2: Sections
printf '[sec]\nkey = "val"' >test.toml
test_results=""
toml_parse test.toml test_callback
assert_eq "sec:key=val|" "$test_results" "Sections"

# Case 3: Arrays
printf 'arr = ["a", "b"]' >test.toml
test_results=""
toml_parse test.toml test_callback
assert_eq ":arr=a,b|" "$test_results" "Single-line array"

# Case 4: Multiline arrays
printf 'arr = [\n"a",\n"b"\n]' >test.toml
test_results=""
toml_parse test.toml test_callback
assert_eq ":arr=a,b|" "$test_results" "Multiline array"

# Case 5: Array normalization
assert_eq "a,b" "$(toml_normalize_array '["a", "b"]')" "Array normalization"
assert_eq "a,b" "$(toml_normalize_array '[ "a" , "b" ]')" "Array normalization with spaces"

# Case 6: Brackets inside quoted multiline array values
printf 'arr = [\n"chatgpt-codex-connector",\n"chatgpt-codex-connector[bot]",\n"reviewer"\n]' >test.toml
test_results=""
toml_parse test.toml test_callback
assert_eq ":arr=chatgpt-codex-connector,chatgpt-codex-connector[bot],reviewer|" \
  "$test_results" "Quoted brackets do not terminate multiline arrays"

rm test.toml

# Case 7 (regression, issue #620): downstream projects run Semgrep p/default
# with --error against synced Touchstone files. The `local IFS` split in
# toml_normalize_array is safe (local scoping), but Semgrep's ifs-tampering
# rule cannot model that and blocks every consumer's security gate unless the
# targeted suppression ships with the file. Guard the annotation so a
# refactor cannot silently drop it again.
if ! grep -q 'nosemgrep: bash.lang.security.ifs-tampering.ifs-tampering' \
  "$REPO_ROOT/lib/toml.sh"; then
  echo "FAIL: lib/toml.sh lost its targeted ifs-tampering nosemgrep annotation"
  echo "  Downstream Semgrep-gated projects (see issue #620) fail their"
  echo "  security scan on the synced file without it."
  exit 1
fi
echo "PASS: ifs-tampering nosemgrep annotation present (issue #620 guard)"

echo "All TOML tests passed."
