#!/usr/bin/env bash
#
# tests/test-delivery-metrics.sh — offline coverage for the delivery-metrics
# reporter. `collect` needs GitHub and is therefore not exercised here beyond
# its argument handling; `report` is pure text processing and is fully covered.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/delivery-metrics.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-metrics-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0

fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}

pass() { echo "  ok: $*"; }

[ -f "$SCRIPT" ] || {
  echo "ERROR: missing $SCRIPT" >&2
  exit 1
}

# number  created  merged  first_commit  lines  files  commits  reviews
#
# Times are epoch seconds. The small bucket carries one deliberate outlier so
# the median/tail distinction is asserted, not assumed: four fast records and
# one slow one must produce a small median and a large max.
FIXTURE="$TMP_DIR/records.tsv"
cat >"$FIXTURE" <<'EOF'
101	1786000000	1786000300	1786000000	5	1	1	0
102	1786000000	1786000600	1786000000	20	2	1	0
103	1786000000	1786000600	1786000000	21	2	1	0
104	1786000000	1786000600	1786000000	22	2	1	0
105	1786000000	1786000600	1786000000	23	2	1	0
106	1786000000	1786036000	1786000000	24	2	9	11
107	1786000000	1786003600	1786000000	100	5	3	2
108	1786000000	1786007200	1786000000	4000	40	12	20
EOF

OUT="$TMP_DIR/report.txt"
bash "$SCRIPT" report "$FIXTURE" >"$OUT" 2>&1 || fail "report exited nonzero on a valid fixture"

grep -q "8 merged pull requests" "$OUT" || fail "record count not reported"
grep -q "tiny   (<10 lines)" "$OUT" || fail "tiny bucket row missing"
grep -q "large  (250+)" "$OUT" || fail "large bucket row missing"

# Bucket assignment: 5 lines is tiny, 20-24 are small, 100 is medium, 4000 large.
small_row="$(grep "small  (10-49)" "$OUT")"
case "$small_row" in
  *" 5 "*) pass "small bucket counted five records" ;;
  *) fail "small bucket count wrong: $small_row" ;;
esac

# The outlier must move max without dragging the median with it. Four records
# at 10m and one at 600m: median stays 10m, max reports 600m.
case "$small_row" in
  *"10m"*"600m"*) pass "median stays low while max exposes the outlier" ;;
  *) fail "expected median 10m and max 600m in: $small_row" ;;
esac

# The slowest listing must surface the outlier by PR number.
grep -q "slowest merged changes" "$OUT" || fail "slowest listing missing"
grep -qE "#106 +600m" "$OUT" || fail "slowest listing did not rank the outlier first"

# Merged-only scope is stated in the output, because a reader who misses it
# will draw exactly the wrong conclusion from a healthy-looking table.
grep -q "MERGED PULL REQUESTS ONLY" "$OUT" \
  || fail "report does not disclose that unmerged changes are excluded"

# Malformed input fails closed rather than reporting partial numbers.
BAD="$TMP_DIR/bad.tsv"
printf '101\t1786000000\t1786000300\n' >"$BAD"
if bash "$SCRIPT" report "$BAD" >/dev/null 2>&1; then
  fail "report accepted a record with the wrong field count"
else
  pass "report rejects malformed records"
fi

# An empty input is not an error, but must not print a table implying zero cost.
EMPTY="$TMP_DIR/empty.tsv"
: >"$EMPTY"
empty_out="$(bash "$SCRIPT" report "$EMPTY" 2>&1)"
[ "$empty_out" = "no records" ] || fail "empty input produced: $empty_out"
pass "empty input reports no records"

# Unknown arguments fail closed. The vendored open-pr.sh treated an unknown
# flag as a positional and opened a PR titled '--body-file'; that class does
# not get to reappear here.
if bash "$SCRIPT" collect --body-file /tmp/nope >/dev/null 2>&1; then
  fail "collect accepted an unknown argument"
else
  pass "collect rejects unknown arguments"
fi

if bash "$SCRIPT" nonsense >/dev/null 2>&1; then
  fail "unknown action accepted"
else
  pass "unknown action rejected"
fi

if bash "$SCRIPT" collect --limit 0 >/dev/null 2>&1; then
  fail "collect accepted --limit 0"
else
  pass "collect rejects a non-positive limit"
fi

if bash "$SCRIPT" collect --repo notaslug >/dev/null 2>&1; then
  fail "collect accepted a malformed --repo"
else
  pass "collect rejects a malformed --repo"
fi

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES check(s) failed" >&2
  exit 1
fi
echo "PASS tests/test-delivery-metrics.sh"
