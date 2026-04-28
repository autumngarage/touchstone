#!/usr/bin/env bash
#
# tests/test-review-skip-logging.sh — verify hooks/codex-review.sh writes
# a structured TSV audit line every time it skips review or actually runs.
# Without this audit trail, a Conductor outage during a critical week
# would be invisible — see "No silent failures" in
# principles/engineering-principles.md.
#
# Each assertion isolates the log file via TOUCHSTONE_REVIEW_LOG so the
# test never touches the real ~/.touchstone-review-log.

set -euo pipefail

TOUCHSTONE_ROOT="${TOUCHSTONE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOOK="$TOUCHSTONE_ROOT/hooks/codex-review.sh"

TEST_DIR="$(mktemp -d -t touchstone-test-skip-log.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

# Strip out env vars that pre-commit / pre-push sets so tests start from a
# clean baseline (mirrors test-review-hook.sh).
unset PRE_COMMIT \
      PRE_COMMIT_FROM_REF PRE_COMMIT_TO_REF \
      PRE_COMMIT_LOCAL_BRANCH PRE_COMMIT_REMOTE_BRANCH \
      PRE_COMMIT_REMOTE_NAME PRE_COMMIT_REMOTE_URL \
      CODEX_REVIEW_FORCE CODEX_REVIEW_NO_AUTOFIX CODEX_REVIEW_DISABLE_CACHE \
      CODEX_REVIEW_ENABLED CODEX_REVIEW_IN_PROGRESS

new_repo() {
  # new_repo <dir> [--with-config-toml]
  local dir="$1"; shift || true
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  printf 'base\n' > "$dir/file.txt"
  if [ "${1:-}" = "--with-config-toml" ]; then
    cat > "$dir/.codex-review.toml" <<'EOF'
[review]
enabled = true
reviewer = "conductor"
[review.conductor]
prefer = "best"
effort = "max"
EOF
  fi
  git -C "$dir" add . && git -C "$dir" commit -qm init
  printf 'change\n' >> "$dir/file.txt"
  git -C "$dir" add . && git -C "$dir" commit -qm change
}

# Build a fake-bin dir with a working `conductor` mock that emits CLEAN.
make_fake_bin_with_conductor() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/gh" <<'EOF'
#!/usr/bin/env bash
echo main
EOF
  cat > "$dir/conductor" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ]; then
  printf '{"providers":[{"configured":true}]}\n'; exit 0
fi
printf 'CODEX_REVIEW_CLEAN\n'
EOF
  chmod +x "$dir/gh" "$dir/conductor"
}

# Build a fake-bin dir WITHOUT conductor — used to simulate the
# conductor-missing skip path. Still ships `gh` so default-branch
# resolution succeeds.
make_fake_bin_without_conductor() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/gh" <<'EOF'
#!/usr/bin/env bash
echo main
EOF
  chmod +x "$dir/gh"
}

# Run the hook and capture stdout+stderr to a sink so the test output stays
# tidy. The hook's exit code is returned so callers can assert on it.
run_hook_in() {
  local repo="$1"; shift
  local sink="$1"; shift
  (
    cd "$repo"
    "$@" bash "$HOOK" > "$sink" 2>&1
  )
}

# Assert the log file's last line has reason_code == $expected and is a
# valid 6-field TSV. Increments $ERRORS on failure.
assert_last_log_reason() {
  local label="$1" log="$2" expected="$3"

  if [ ! -s "$log" ]; then
    echo "FAIL [$label]: log file empty or missing: $log" >&2
    ERRORS=$((ERRORS + 1))
    return
  fi

  local last
  last="$(tail -n 1 "$log")"

  # Count tab-separated fields — must be exactly 6 (5 tabs).
  local tab_count
  tab_count="$(printf '%s' "$last" | tr -cd '\t' | wc -c | tr -d ' ')"
  if [ "$tab_count" != "5" ]; then
    echo "FAIL [$label]: expected 6 tab-separated fields (5 tabs), got $tab_count" >&2
    echo "  line: $last" >&2
    ERRORS=$((ERRORS + 1))
    return
  fi

  local reason
  reason="$(printf '%s' "$last" | awk -F'\t' '{print $5}')"
  if [ "$reason" != "$expected" ]; then
    echo "FAIL [$label]: expected reason '$expected', got '$reason'" >&2
    echo "  line: $last" >&2
    ERRORS=$((ERRORS + 1))
    return
  fi

  echo "==> PASS [$label]: logged reason=$expected"
}

# ---------------------------------------------------------------------------
# Test 1: conductor-missing — PATH stripped of `conductor`
# ---------------------------------------------------------------------------
echo "==> Test: conductor-missing skip path logs reason=conductor-missing"
REPO1="$TEST_DIR/repo1"
BIN1="$TEST_DIR/bin1"
LOG1="$TEST_DIR/log1.tsv"
new_repo "$REPO1" --with-config-toml
make_fake_bin_without_conductor "$BIN1"

run_hook_in "$REPO1" "$TEST_DIR/out1.txt" \
  env PATH="$BIN1:/usr/bin:/bin:/usr/sbin:/sbin" \
      TOUCHSTONE_REVIEW_LOG="$LOG1" \
      CODEX_REVIEW_BASE="HEAD~1" \
      CODEX_REVIEW_DISABLE_CACHE=1 \
  || true
assert_last_log_reason "conductor-missing" "$LOG1" "conductor-missing"

# ---------------------------------------------------------------------------
# Test 2: config-disabled — [review].enabled=false in .codex-review.toml
# ---------------------------------------------------------------------------
echo "==> Test: config-disabled skip path logs reason=config-disabled"
REPO2="$TEST_DIR/repo2"
BIN2="$TEST_DIR/bin2"
LOG2="$TEST_DIR/log2.tsv"
mkdir -p "$REPO2"
git -C "$REPO2" init -q
git -C "$REPO2" config user.email t@t
git -C "$REPO2" config user.name t
cat > "$REPO2/.codex-review.toml" <<'EOF'
[review]
enabled = false
reviewer = "conductor"
EOF
printf 'a\n' > "$REPO2/f.txt"
git -C "$REPO2" add . && git -C "$REPO2" commit -qm init
printf 'b\n' >> "$REPO2/f.txt"
git -C "$REPO2" add . && git -C "$REPO2" commit -qm change
make_fake_bin_with_conductor "$BIN2"

run_hook_in "$REPO2" "$TEST_DIR/out2.txt" \
  env PATH="$BIN2:/usr/bin:/bin:/usr/sbin:/sbin" \
      TOUCHSTONE_REVIEW_LOG="$LOG2" \
      CODEX_REVIEW_BASE="HEAD~1" \
      CODEX_REVIEW_DISABLE_CACHE=1 \
  || true
assert_last_log_reason "config-disabled" "$LOG2" "config-disabled"

# ---------------------------------------------------------------------------
# Test 3: review-disabled-by-user — CODEX_REVIEW_ENABLED=false at env layer
#
# The hook honors CODEX_REVIEW_ENABLED as a per-push override that wins
# over the TOML setting. The user-prompt called this "force-skip env var
# setting (whatever the existing hook honors)" — CODEX_REVIEW_ENABLED is
# the canonical user-facing skip toggle today.
# ---------------------------------------------------------------------------
echo "==> Test: CODEX_REVIEW_ENABLED=false logs reason=review-disabled-by-user"
REPO3="$TEST_DIR/repo3"
BIN3="$TEST_DIR/bin3"
LOG3="$TEST_DIR/log3.tsv"
new_repo "$REPO3" --with-config-toml
make_fake_bin_with_conductor "$BIN3"

run_hook_in "$REPO3" "$TEST_DIR/out3.txt" \
  env PATH="$BIN3:/usr/bin:/bin:/usr/sbin:/sbin" \
      TOUCHSTONE_REVIEW_LOG="$LOG3" \
      CODEX_REVIEW_ENABLED=false \
      CODEX_REVIEW_BASE="HEAD~1" \
      CODEX_REVIEW_DISABLE_CACHE=1 \
  || true
assert_last_log_reason "review-disabled-by-user" "$LOG3" "review-disabled-by-user"

# ---------------------------------------------------------------------------
# Test 4: ran — successful review with mock conductor returning CLEAN
#
# The denominator the audit needs: skip-rate = skips / (skips + ran).
# ---------------------------------------------------------------------------
echo "==> Test: successful review logs reason=ran (audit denominator)"
REPO4="$TEST_DIR/repo4"
BIN4="$TEST_DIR/bin4"
LOG4="$TEST_DIR/log4.tsv"
new_repo "$REPO4" --with-config-toml
make_fake_bin_with_conductor "$BIN4"

run_hook_in "$REPO4" "$TEST_DIR/out4.txt" \
  env PATH="$BIN4:/usr/bin:/bin:/usr/sbin:/sbin" \
      TOUCHSTONE_REVIEW_LOG="$LOG4" \
      CODEX_REVIEW_BASE="HEAD~1" \
      CODEX_REVIEW_DISABLE_CACHE=1 \
  || { echo "FAIL: hook exited non-zero on a clean review" >&2; cat "$TEST_DIR/out4.txt" >&2; ERRORS=$((ERRORS + 1)); }
assert_last_log_reason "ran" "$LOG4" "ran"

# ---------------------------------------------------------------------------
# Test 5: malformed .codex-review.toml does not break the hook
#
# Today's TOML parser is permissive — it skips lines it doesn't recognize
# rather than aborting. There is no `config-parse-error` skip site to hit
# yet (the reason code is reserved for future use). The regression we
# care about is: a malformed TOML must still leave the audit log in a
# consistent state — the hook must reach SOME log call rather than
# crashing without writing anything.
# ---------------------------------------------------------------------------
echo "==> Test: malformed .codex-review.toml does not crash logging"
REPO5="$TEST_DIR/repo5"
BIN5="$TEST_DIR/bin5"
LOG5="$TEST_DIR/log5.tsv"
mkdir -p "$REPO5"
git -C "$REPO5" init -q
git -C "$REPO5" config user.email t@t
git -C "$REPO5" config user.name t
# Garbage TOML: unmatched bracket, malformed key, etc.
cat > "$REPO5/.codex-review.toml" <<'EOF'
[review
this-is = not = valid =
=== no key here ===
EOF
printf 'a\n' > "$REPO5/f.txt"
git -C "$REPO5" add . && git -C "$REPO5" commit -qm init
printf 'b\n' >> "$REPO5/f.txt"
git -C "$REPO5" add . && git -C "$REPO5" commit -qm change
make_fake_bin_with_conductor "$BIN5"

run_hook_in "$REPO5" "$TEST_DIR/out5.txt" \
  env PATH="$BIN5:/usr/bin:/bin:/usr/sbin:/sbin" \
      TOUCHSTONE_REVIEW_LOG="$LOG5" \
      CODEX_REVIEW_BASE="HEAD~1" \
      CODEX_REVIEW_DISABLE_CACHE=1 \
  || true
if [ -s "$LOG5" ]; then
  echo "==> PASS: malformed TOML still produced a log entry"
else
  echo "FAIL: malformed TOML left log file empty" >&2
  cat "$TEST_DIR/out5.txt" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Test 6: rollover at 1000 entries
#
# Pre-seed the log with 1000 lines, run the hook once, assert the file
# still has exactly 1000 lines (the oldest was dropped, the new entry
# was appended).
# ---------------------------------------------------------------------------
echo "==> Test: log rollover caps the file at 1000 entries"
REPO6="$TEST_DIR/repo6"
BIN6="$TEST_DIR/bin6"
LOG6="$TEST_DIR/log6.tsv"
new_repo "$REPO6" --with-config-toml
make_fake_bin_with_conductor "$BIN6"

# Seed 1000 entries with synthetic but format-compliant lines.
: > "$LOG6"
i=0
while [ "$i" -lt 1000 ]; do
  printf 'seed-ts\trepo\tbranch\tsha\tseed\trow-%s\n' "$i" >> "$LOG6"
  i=$((i + 1))
done

seeded_count="$(wc -l < "$LOG6" | tr -d ' ')"
if [ "$seeded_count" != "1000" ]; then
  echo "FAIL: seeding sanity check — expected 1000 lines, got $seeded_count" >&2
  ERRORS=$((ERRORS + 1))
fi

run_hook_in "$REPO6" "$TEST_DIR/out6.txt" \
  env PATH="$BIN6:/usr/bin:/bin:/usr/sbin:/sbin" \
      TOUCHSTONE_REVIEW_LOG="$LOG6" \
      CODEX_REVIEW_BASE="HEAD~1" \
      CODEX_REVIEW_DISABLE_CACHE=1 \
  || { echo "FAIL: hook exited non-zero in rollover test" >&2; cat "$TEST_DIR/out6.txt" >&2; ERRORS=$((ERRORS + 1)); }

final_count="$(wc -l < "$LOG6" | tr -d ' ')"
if [ "$final_count" = "1000" ]; then
  echo "==> PASS: log capped at 1000 entries after rollover"
else
  echo "FAIL: expected 1000 lines after rollover, got $final_count" >&2
  ERRORS=$((ERRORS + 1))
fi

# Confirm the oldest seed entry was dropped (row-0 should no longer
# appear) and the newest entry isn't a seed line.
if grep -q '	row-0$' "$LOG6"; then
  echo "FAIL: oldest entry (row-0) was not evicted on rollover" >&2
  ERRORS=$((ERRORS + 1))
fi

last_reason="$(tail -n 1 "$LOG6" | awk -F'\t' '{print $5}')"
if [ "$last_reason" = "seed" ]; then
  echo "FAIL: tail of log is still a seed entry — new event not appended" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Test 7: format invariants — every line is exactly 6 tab-separated fields
# ---------------------------------------------------------------------------
echo "==> Test: every log entry is exactly 6 tab-separated fields"
ALL_LOGS_OK=true
for log in "$LOG1" "$LOG2" "$LOG3" "$LOG4" "$LOG6"; do
  [ -s "$log" ] || continue
  # awk: fail if any line has a field count != 6.
  if ! awk -F'\t' 'NF != 6 { exit 1 }' "$log"; then
    echo "FAIL: $log has lines that are not 6-field TSV" >&2
    ALL_LOGS_OK=false
    ERRORS=$((ERRORS + 1))
  fi
done
if [ "$ALL_LOGS_OK" = true ]; then
  echo "==> PASS: all logs are 6-field TSV"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [ "$ERRORS" -ne 0 ]; then
  echo "FAIL: $ERRORS skip-logging assertion(s) failed" >&2
  exit 1
fi
echo "==> PASS: all skip-logging assertions passed"
