#!/usr/bin/env bash
#
# tests/test-doctor.sh — fixture tests for doctor semantics and review stats.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOUCHSTONE_BIN="$TOUCHSTONE_ROOT/bin/touchstone"
TEST_DIR="$(mktemp -d -t touchstone-test-doctor.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

assert_contains() {
  local file="$1" needle="$2"
  if ! grep -q -- "$needle" "$file" 2>/dev/null; then
    echo "FAIL: expected '$file' to contain '$needle'" >&2
    echo "  ---- file content ----" >&2
    sed 's/^/    /' "$file" >&2 || true
    echo "  ----------------------" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

assert_exit() {
  local actual="$1" expected="$2" label="$3"
  if [ "$actual" -ne "$expected" ]; then
    echo "FAIL: $label exit code: expected $expected, got $actual" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

run_touchstone() {
  local fake_home="$1"
  shift
  HOME="$fake_home" \
    NO_COLOR=1 \
    TOUCHSTONE_NO_AUTO_UPDATE=1 \
    bash "$TOUCHSTONE_BIN" "$@"
}

run_review_stats() {
  local fake_home="$1"
  shift
  run_touchstone "$fake_home" review-stats "$@"
}

run_doctor() {
  local fake_home="$1"
  shift
  run_touchstone "$fake_home" doctor "$@"
}

write_fake_install_tools() {
  local dir="$1" conductor_mode="$2" latest_version="${3:-}" version
  version="$(tr -d '[:space:]' <"$TOUCHSTONE_ROOT/VERSION")"
  [ -n "$latest_version" ] || latest_version="$version"
  mkdir -p "$dir"
  for tool in gh pre-commit gitleaks shellcheck shfmt; do
    cat >"$dir/$tool" <<'EOF_FAKE_TOOL'
#!/usr/bin/env bash
exit 0
EOF_FAKE_TOOL
    chmod +x "$dir/$tool"
  done
  cat >"$dir/curl" <<EOF_FAKE_CURL
#!/usr/bin/env bash
printf '{"tag_name":"v%s"}\n' "$latest_version"
EOF_FAKE_CURL
  chmod +x "$dir/curl"
  if [ "$conductor_mode" = "present" ]; then
    cat >"$dir/conductor" <<'EOF_FAKE_CONDUCTOR'
#!/usr/bin/env bash
if [ "${1:-}" = "doctor" ] && [ "${2:-}" = "--json" ]; then
  printf '{"providers":[{"configured":true}]}\n'
  exit 0
fi
exit 0
EOF_FAKE_CONDUCTOR
    chmod +x "$dir/conductor"
  fi
}

timestamp_now() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

write_row() {
  local file="$1" timestamp="$2" repo="$3" branch="$4" sha="$5" reason="$6" detail="$7"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$timestamp" "$repo" "$branch" "$sha" "$reason" "$detail" >>"$file"
}

echo "==> Test: touchstone doctor and review-stats"
echo "    Test dir: $TEST_DIR"

FAKE_HOME="$TEST_DIR/home"
mkdir -p "$FAKE_HOME"

# --------------------------------------------------------------------------
# Test 1: doctor help preserves project capability option and omits metrics
# --------------------------------------------------------------------------
echo ""
echo "--- Test 1: doctor help is structural ---"

HELP_OUT="$TEST_DIR/help.out"
set +e
run_doctor "$FAKE_HOME" --help >"$HELP_OUT" 2>&1
HELP_EXIT=$?
set -e

assert_exit "$HELP_EXIT" 0 "help"
assert_contains "$HELP_OUT" "touchstone doctor --require-capability <name>"
assert_contains "$HELP_OUT" "Require a project-local Touchstone workflow capability"
if grep -Eq -- "fail-open trends|--log-path|--threshold" "$HELP_OUT"; then
  echo "FAIL: doctor help should not expose review metrics" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 2: doctor rejects old metrics flags
# --------------------------------------------------------------------------
echo ""
echo "--- Test 2: doctor metrics moved to review-stats ---"

DOCTOR_METRICS_OUT="$TEST_DIR/doctor-metrics.out"
set +e
run_doctor "$FAKE_HOME" --log-path "$TEST_DIR/no-such-log" >"$DOCTOR_METRICS_OUT" 2>&1
DOCTOR_METRICS_EXIT=$?
set -e

assert_exit "$DOCTOR_METRICS_EXIT" 2 "doctor metrics flags"
assert_contains "$DOCTOR_METRICS_OUT" "review metrics moved to: touchstone review-stats"

# --------------------------------------------------------------------------
# Test 2b: installation doctor fails hard when Conductor is missing
# --------------------------------------------------------------------------
echo ""
echo "--- Test 2b: installation doctor requires conductor peer ---"

MISSING_CONDUCTOR_BIN="$TEST_DIR/missing-conductor-bin"
write_fake_install_tools "$MISSING_CONDUCTOR_BIN" "missing"
MISSING_CONDUCTOR_OUT="$TEST_DIR/missing-conductor.out"
set +e
PATH="$MISSING_CONDUCTOR_BIN:/usr/bin:/bin" run_doctor "$FAKE_HOME" --installation >"$MISSING_CONDUCTOR_OUT" 2>&1
MISSING_CONDUCTOR_EXIT=$?
set -e

assert_exit "$MISSING_CONDUCTOR_EXIT" 1 "missing conductor peer"
assert_contains "$MISSING_CONDUCTOR_OUT" "the pre-push review hook will not run without conductor"
assert_contains "$MISSING_CONDUCTOR_OUT" "brew install autumngarage/conductor/conductor"
assert_contains "$MISSING_CONDUCTOR_OUT" "autumn-garage doctrine 0009"

# --------------------------------------------------------------------------
# Test 2c: installation doctor exits zero when Conductor is present
# --------------------------------------------------------------------------
echo ""
echo "--- Test 2c: installation doctor accepts conductor peer ---"

PRESENT_CONDUCTOR_BIN="$TEST_DIR/present-conductor-bin"
write_fake_install_tools "$PRESENT_CONDUCTOR_BIN" "present"
PRESENT_CONDUCTOR_OUT="$TEST_DIR/present-conductor.out"
set +e
PATH="$PRESENT_CONDUCTOR_BIN:/usr/bin:/bin" run_doctor "$FAKE_HOME" --installation >"$PRESENT_CONDUCTOR_OUT" 2>&1
PRESENT_CONDUCTOR_EXIT=$?
set -e

assert_exit "$PRESENT_CONDUCTOR_EXIT" 0 "present conductor peer"
assert_contains "$PRESENT_CONDUCTOR_OUT" "conductor: $PRESENT_CONDUCTOR_BIN/conductor (at least one provider configured)"

# --------------------------------------------------------------------------
# Test 2c.1: installation doctor never falls through a broken first launcher
# --------------------------------------------------------------------------
echo ""
echo "--- Test 2c.1: installation doctor probes the resolved conductor path ---"

BROKEN_CONDUCTOR_BIN="$TEST_DIR/broken-conductor-bin"
OLDER_CONDUCTOR_BIN="$TEST_DIR/older-conductor-bin"
write_fake_install_tools "$BROKEN_CONDUCTOR_BIN" "missing"
write_fake_install_tools "$OLDER_CONDUCTOR_BIN" "present"
cat >"$BROKEN_CONDUCTOR_BIN/conductor" <<EOF_BROKEN_CONDUCTOR
#!$TEST_DIR/missing-conductor-interpreter
exit 0
EOF_BROKEN_CONDUCTOR
chmod +x "$BROKEN_CONDUCTOR_BIN/conductor"
cat >"$OLDER_CONDUCTOR_BIN/conductor" <<'EOF_OLDER_CONDUCTOR'
#!/usr/bin/env bash
printf 'invoked\n' >"${TOUCHSTONE_OLDER_CONDUCTOR_MARKER:?}"
if [ "${1:-}" = "doctor" ] && [ "${2:-}" = "--json" ]; then
  printf '{"providers":[{"configured":true}]}\n'
fi
EOF_OLDER_CONDUCTOR
chmod +x "$OLDER_CONDUCTOR_BIN/conductor"

SHADOWED_CONDUCTOR_OUT="$TEST_DIR/shadowed-conductor.out"
older_conductor_marker="$TEST_DIR/older-conductor-invoked"
set +e
PATH="$BROKEN_CONDUCTOR_BIN:$OLDER_CONDUCTOR_BIN:/usr/bin:/bin" \
  TOUCHSTONE_OLDER_CONDUCTOR_MARKER="$older_conductor_marker" \
  run_doctor "$FAKE_HOME" --installation >"$SHADOWED_CONDUCTOR_OUT" 2>&1
SHADOWED_CONDUCTOR_EXIT=$?
set -e

assert_exit "$SHADOWED_CONDUCTOR_EXIT" 1 "broken resolved conductor peer"
assert_contains "$SHADOWED_CONDUCTOR_OUT" "conductor: $BROKEN_CONDUCTOR_BIN/conductor (unhealthy or no provider configured"
if [ -e "$older_conductor_marker" ]; then
  echo "FAIL: installation doctor invoked an older shadowed conductor" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 2d: installation doctor ignores stale older latest-release metadata
# --------------------------------------------------------------------------
echo ""
echo "--- Test 2d: installation doctor accepts installed version newer than latest release ---"

STALE_LATEST_BIN="$TEST_DIR/stale-latest-bin"
write_fake_install_tools "$STALE_LATEST_BIN" "present" "0.0.1"
STALE_LATEST_OUT="$TEST_DIR/stale-latest.out"
set +e
PATH="$STALE_LATEST_BIN:/usr/bin:/bin" run_doctor "$FAKE_HOME" --installation >"$STALE_LATEST_OUT" 2>&1
STALE_LATEST_EXIT=$?
set -e

assert_exit "$STALE_LATEST_EXIT" 0 "stale latest release"
assert_contains "$STALE_LATEST_OUT" "newer than latest GitHub release v0.0.1"
if grep -q "available (you have" "$STALE_LATEST_OUT"; then
  echo "FAIL: stale older latest release should not be reported as an available upgrade" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 3: review-stats missing log exits 0 with friendly message
# --------------------------------------------------------------------------
echo ""
echo "--- Test 3: review-stats missing log ---"

MISSING_OUT="$TEST_DIR/missing.out"
set +e
run_review_stats "$FAKE_HOME" --log-path "$TEST_DIR/no-such-log" >"$MISSING_OUT" 2>&1
MISSING_EXIT=$?
set -e

assert_exit "$MISSING_EXIT" 0 "missing log"
assert_contains "$MISSING_OUT" "no review log found; conductor review hasn't run on this machine yet"

# --------------------------------------------------------------------------
# Test 4: empty log exits 0 with the same friendly message
# --------------------------------------------------------------------------
echo ""
echo "--- Test 4: review-stats empty log ---"

EMPTY_LOG="$TEST_DIR/empty.log"
: >"$EMPTY_LOG"
EMPTY_OUT="$TEST_DIR/empty.out"
set +e
run_review_stats "$FAKE_HOME" --log-path "$EMPTY_LOG" >"$EMPTY_OUT" 2>&1
EMPTY_EXIT=$?
set -e

assert_exit "$EMPTY_EXIT" 0 "empty log"
assert_contains "$EMPTY_OUT" "no review log found; conductor review hasn't run on this machine yet"

# --------------------------------------------------------------------------
# Test 5: no fail-opens reports zero rate and exits 0
# --------------------------------------------------------------------------
echo ""
echo "--- Test 5: review-stats no fail-opens ---"

NOW="$(timestamp_now)"
NO_FAIL_LOG="$TEST_DIR/no-fail.log"
write_row "$NO_FAIL_LOG" "$NOW" "/tmp/repo-a" "main" "abc1234" "ran" "clean"
write_row "$NO_FAIL_LOG" "$NOW" "/tmp/repo-b" "feat/x" "def5678" "ran" "clean"

NO_FAIL_OUT="$TEST_DIR/no-fail.out"
set +e
run_review_stats "$FAKE_HOME" --log-path "$NO_FAIL_LOG" >"$NO_FAIL_OUT" 2>&1
NO_FAIL_EXIT=$?
set -e

assert_exit "$NO_FAIL_EXIT" 0 "no fail-opens"
assert_contains "$NO_FAIL_OUT" "Last 7 days"
assert_contains "$NO_FAIL_OUT" "total reviews: 2"
assert_contains "$NO_FAIL_OUT" "fail-open: 0 (0.0%)"
assert_contains "$NO_FAIL_OUT" "FAIL_OPEN_TIMEOUT: 0"
assert_contains "$NO_FAIL_OUT" "none recorded"

# --------------------------------------------------------------------------
# Test 6: mixed rows count fail-open codes and ignore disabled/skipped rows
# --------------------------------------------------------------------------
echo ""
echo "--- Test 6: review-stats mixed events ---"

MIXED_LOG="$TEST_DIR/mixed.log"
write_row "$MIXED_LOG" "2000-01-01T00:00:00+0000" "/tmp/old" "main" "0000000" "FAIL_OPEN_TIMEOUT" "too-old"
write_row "$MIXED_LOG" "$NOW" "/tmp/repo-a" "main" "1111111" "ran" "clean"
write_row "$MIXED_LOG" "$NOW" "/tmp/repo-b" "feat/a" "2222222" "FAIL_OPEN_TIMEOUT" "fail-open:timeout"
write_row "$MIXED_LOG" "$NOW" "/tmp/repo-c" "feat/b" "3333333" "FAIL_OPEN_PARSE_ERROR" "fail-open:malformed sentinel"
write_row "$MIXED_LOG" "$NOW" "/tmp/repo-d" "feat/c" "4444444" "config-disabled" "disabled"

MIXED_OUT="$TEST_DIR/mixed.out"
set +e
run_review_stats "$FAKE_HOME" --log-path "$MIXED_LOG" --threshold 80 >"$MIXED_OUT" 2>&1
MIXED_EXIT=$?
set -e

assert_exit "$MIXED_EXIT" 0 "mixed events under threshold"
assert_contains "$MIXED_OUT" "total reviews: 3"
assert_contains "$MIXED_OUT" "fail-open: 2 (66.7%)"
assert_contains "$MIXED_OUT" "FAIL_OPEN_TIMEOUT: 1"
assert_contains "$MIXED_OUT" "FAIL_OPEN_PARSE_ERROR: 1"
assert_contains "$MIXED_OUT" "repo: /tmp/repo-c"
assert_contains "$MIXED_OUT" "detail: fail-open:malformed sentinel"

# --------------------------------------------------------------------------
# Test 7: threshold warning exits 2
# --------------------------------------------------------------------------
echo ""
echo "--- Test 7: review-stats threshold warning ---"

THRESHOLD_LOG="$TEST_DIR/threshold.log"
write_row "$THRESHOLD_LOG" "$NOW" "/tmp/repo-a" "main" "aaaaaaa" "ran" "clean"
write_row "$THRESHOLD_LOG" "$NOW" "/tmp/repo-b" "feat/a" "bbbbbbb" "FAIL_OPEN_REVIEWER_ERROR" "fail-open:reviewer"

THRESHOLD_OUT="$TEST_DIR/threshold.out"
set +e
run_review_stats "$FAKE_HOME" --log-path "$THRESHOLD_LOG" >"$THRESHOLD_OUT" 2>&1
THRESHOLD_EXIT=$?
set -e

assert_exit "$THRESHOLD_EXIT" 2 "threshold warning"
assert_contains "$THRESHOLD_OUT" "fail-open: 1 (50.0%)"
assert_contains "$THRESHOLD_OUT" "FAIL_OPEN_REVIEWER_ERROR: 1"
assert_contains "$THRESHOLD_OUT" "exceeds 25%"

# --------------------------------------------------------------------------
# Test 8: TOUCHSTONE_REVIEW_LOG env override is honored and read-only
# --------------------------------------------------------------------------
echo ""
echo "--- Test 8: review-stats env override and read-only behavior ---"

ENV_LOG="$TEST_DIR/env.log"
write_row "$ENV_LOG" "$NOW" "/tmp/repo-env" "main" "eeeeeee" "ran" "clean"
BEFORE_SUM="$(cksum "$ENV_LOG")"

ENV_OUT="$TEST_DIR/env.out"
set +e
TOUCHSTONE_REVIEW_LOG="$ENV_LOG" run_review_stats "$FAKE_HOME" >"$ENV_OUT" 2>&1
ENV_EXIT=$?
set -e
AFTER_SUM="$(cksum "$ENV_LOG")"

assert_exit "$ENV_EXIT" 0 "env override"
assert_contains "$ENV_OUT" "log: $ENV_LOG"
if [ "$BEFORE_SUM" != "$AFTER_SUM" ]; then
  echo "FAIL: doctor modified the review log fixture" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 9: --require-capability implies project mode
# --------------------------------------------------------------------------
echo ""
echo "--- Test 9: doctor --require-capability implies project mode ---"

CAPABILITY_PROJECT="$TEST_DIR/capability-project"
mkdir -p "$CAPABILITY_PROJECT"
git -C "$TOUCHSTONE_ROOT" rev-parse HEAD >"$CAPABILITY_PROJECT/.touchstone-version"

CAPABILITY_OUT="$TEST_DIR/capability-doctor.out"
set +e
(cd "$CAPABILITY_PROJECT" && run_doctor "$FAKE_HOME" --require-capability worktree-lifecycle) >"$CAPABILITY_OUT" 2>&1
CAPABILITY_EXIT=$?
set -e

assert_exit "$CAPABILITY_EXIT" 0 "doctor --require-capability"
assert_contains "$CAPABILITY_OUT" "Capability 'worktree-lifecycle' is available"
if grep -q -- "Touchstone Doctor" "$CAPABILITY_OUT"; then
  echo "FAIL: --require-capability should not fall through to installation doctor" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 10: bare doctor checks structural project state, not installation state
# --------------------------------------------------------------------------
echo ""
echo "--- Test 10: bare doctor recognizes modern project marker ---"

MODERN_PROJECT="$TEST_DIR/modern-project"
mkdir -p "$MODERN_PROJECT"
git -C "$TOUCHSTONE_ROOT" rev-parse HEAD >"$MODERN_PROJECT/.touchstone-version"

MODERN_DOCTOR_OUT="$TEST_DIR/modern-doctor.out"
set +e
(cd "$MODERN_PROJECT" && run_doctor "$FAKE_HOME") >"$MODERN_DOCTOR_OUT" 2>&1
MODERN_DOCTOR_EXIT=$?
set -e

if [ "$MODERN_DOCTOR_EXIT" -eq 0 ]; then
  echo "FAIL: incomplete project doctor should report missing structural pieces" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$MODERN_DOCTOR_OUT" "Touchstone Project Doctor"
assert_contains "$MODERN_DOCTOR_OUT" ".pre-commit-config.yaml is missing"
assert_contains "$MODERN_DOCTOR_OUT" ".touchstone-manifest missing"

# --------------------------------------------------------------------------
# Test 11: bare doctor checks structural project state, not metrics
# --------------------------------------------------------------------------
echo ""
echo "--- Test 11: bare doctor surfaces migration debt ---"

LEGACY_PROJECT="$TEST_DIR/legacy-project"
mkdir -p "$LEGACY_PROJECT"
printf 'legacy-sha\n' >"$LEGACY_PROJECT/.toolkit-version"
LEGACY_DOCTOR_OUT="$TEST_DIR/legacy-doctor.out"
set +e
(cd "$LEGACY_PROJECT" && run_doctor "$FAKE_HOME") >"$LEGACY_DOCTOR_OUT" 2>&1
LEGACY_DOCTOR_EXIT=$?
set -e

if [ "$LEGACY_DOCTOR_EXIT" -eq 0 ]; then
  echo "FAIL: bare doctor should fail on migration debt" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$LEGACY_DOCTOR_OUT" "Legacy .toolkit-version found"
assert_contains "$LEGACY_DOCTOR_OUT" "touchstone migrate-from-toolkit"
if grep -Eq -- "fail-open|review log" "$LEGACY_DOCTOR_OUT"; then
  echo "FAIL: bare doctor should not print review metrics" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 12: doctor surfaces review config migration debt
# --------------------------------------------------------------------------
echo ""
echo "--- Test 12: doctor surfaces review config migration debt ---"

REVIEW_SCHEMA_PROJECT="$TEST_DIR/review-schema-project"
mkdir -p "$REVIEW_SCHEMA_PROJECT"
git -C "$REVIEW_SCHEMA_PROJECT" init -q
git -C "$REVIEW_SCHEMA_PROJECT" config user.email test@example.com
git -C "$REVIEW_SCHEMA_PROJECT" config user.name "Touchstone Test"
git -C "$REVIEW_SCHEMA_PROJECT" commit --allow-empty -q -m "initial"
git -C "$TOUCHSTONE_ROOT" rev-parse HEAD >"$REVIEW_SCHEMA_PROJECT/.touchstone-version"
cat >"$REVIEW_SCHEMA_PROJECT/.codex-review.toml" <<'EOF_REVIEW_SCHEMA'
[review]
reviewers = ["codex", "claude"]
EOF_REVIEW_SCHEMA

REVIEW_SCHEMA_OUT="$TEST_DIR/review-schema-doctor.out"
set +e
(cd "$REVIEW_SCHEMA_PROJECT" && run_doctor "$FAKE_HOME") >"$REVIEW_SCHEMA_OUT" 2>&1
REVIEW_SCHEMA_EXIT=$?
set -e

if [ "$REVIEW_SCHEMA_EXIT" -eq 0 ]; then
  echo "FAIL: doctor should fail on review config migration debt" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$REVIEW_SCHEMA_OUT" ".codex-review.toml uses legacy 1.x review schema"
assert_contains "$REVIEW_SCHEMA_OUT" "touchstone migrate-review-config"

# --------------------------------------------------------------------------
# Test 13: project doctor fails hard when review is enabled but Conductor is missing
# --------------------------------------------------------------------------
echo ""
echo "--- Test 13: project doctor requires conductor peer for review ---"

PROJECT_PEER="$TEST_DIR/project-peer"
mkdir -p "$PROJECT_PEER"
git -C "$PROJECT_PEER" init -q
git -C "$PROJECT_PEER" config user.email test@example.com
git -C "$PROJECT_PEER" config user.name "Touchstone Test"
git -C "$PROJECT_PEER" commit --allow-empty -q -m "initial"
git -C "$TOUCHSTONE_ROOT" rev-parse HEAD >"$PROJECT_PEER/.touchstone-version"
cat >"$PROJECT_PEER/.touchstone-review.toml" <<'EOF_PROJECT_PEER'
[review]
enabled = true
reviewer = "conductor"
EOF_PROJECT_PEER

PROJECT_PEER_OUT="$TEST_DIR/project-peer.out"
set +e
(cd "$PROJECT_PEER" && PATH="$MISSING_CONDUCTOR_BIN:/usr/bin:/bin" run_doctor "$FAKE_HOME") >"$PROJECT_PEER_OUT" 2>&1
PROJECT_PEER_EXIT=$?
set -e

if [ "$PROJECT_PEER_EXIT" -eq 0 ]; then
  echo "FAIL: project doctor should fail when review is enabled and conductor is missing" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$PROJECT_PEER_OUT" "the pre-push review hook will not run without conductor"
assert_contains "$PROJECT_PEER_OUT" "brew install autumngarage/conductor/conductor"

if [ "$ERRORS" -ne 0 ]; then
  echo ""
  echo "FAILED: $ERRORS error(s)" >&2
  exit 1
fi

echo ""
echo "PASS: touchstone doctor tests"
