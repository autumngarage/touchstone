#!/usr/bin/env bash
#
# tests/test-issue-tracker.sh — the issue discipline is tracker-agnostic (#743).
#
# Two invariants:
#   1. A project that declares no tracker behaves exactly as it did before the
#      declaration existed: GitHub, enforced.
#   2. A project that declares another tracker keeps the discipline without the
#      GitHub-only machinery running at all — no gh invocation, no hard failure.
#
# The fixture mirrors the shipped layout (scripts/ next to lib/) so the config
# lookup being exercised is the one downstream projects and the CI checkout
# actually use.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-issue-tracker.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0
fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    fail "$label: expected '$expected', got '$actual'"
  fi
}

assert_file_contains() {
  local file="$1" needle="$2"
  if ! grep -qF -- "$needle" "$file"; then
    fail "expected $file to contain '$needle'"
    sed -e 's/^/    | /' "$file" >&2
  fi
}

assert_file_empty() {
  local file="$1" why="$2"
  if [ -s "$file" ]; then
    fail "$why; got:"
    sed -e 's/^/    | /' "$file" >&2
  fi
}

assert_file_empty_of() {
  local why="$1" file="$2" needle="$3"
  if grep -qF -- "$needle" "$file"; then
    fail "$why; got:"
    sed -e 's/^/    | /' "$file" >&2
  fi
}

# ---------------------------------------------------------------------------
# Fixture: a project tree carrying the shipped scripts, libs, and a gh stub
# that records every invocation.
# ---------------------------------------------------------------------------
PROJECT="$TEST_DIR/project"
mkdir -p "$PROJECT/scripts" "$PROJECT/lib" "$TEST_DIR/bin"
cp "$TOUCHSTONE_ROOT/scripts/claim-issue.sh" "$PROJECT/scripts/"
cp "$TOUCHSTONE_ROOT/scripts/issue-claim-check.sh" "$PROJECT/scripts/"
cp "$TOUCHSTONE_ROOT/lib/toml.sh" "$PROJECT/lib/"
if [ -f "$TOUCHSTONE_ROOT/lib/issue-tracker.sh" ]; then
  cp "$TOUCHSTONE_ROOT/lib/issue-tracker.sh" "$PROJECT/lib/"
fi

cat >"$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"${GH_CALL_LOG:?}"

case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "api user")
    echo "${GH_USER_LOGIN:-alice}"
    exit 0
    ;;
  "issue view")
    case "$*" in
      *"--json state"*)
        echo OPEN
        exit 0
        ;;
      *"--json assignees"*)
        # First read is pre-claim, later reads are post-claim: claim-issue.sh
        # re-reads to detect a concurrent assignee.
        count=0
        [ -f "${GH_VIEW_COUNT_FILE:?}" ] && count="$(cat "$GH_VIEW_COUNT_FILE")"
        count=$((count + 1))
        printf '%s' "$count" >"$GH_VIEW_COUNT_FILE"
        if [ "$count" -eq 1 ]; then
          printf '%s' "${GH_PRE_ASSIGNEES:-}"
        else
          printf '%s' "${GH_POST_ASSIGNEES:-}"
        fi
        exit 0
        ;;
    esac
    ;;
  "issue edit" | "issue comment") exit 0 ;;
  "repo view")
    case "$*" in
      *nameWithOwner*)
        echo "acme/widget"
        exit 0
        ;;
      *url*)
        echo "https://github.com/acme/widget"
        exit 0
        ;;
    esac
    ;;
  "api repos/acme/widget/issues/12")
    case "$*" in
      *".state"*)
        echo open
        exit 0
        ;;
      *assignees*)
        printf '%s' "${GH_ASSIGNEES:-}"
        exit 0
        ;;
    esac
    ;;
esac

echo "unexpected gh invocation: $*" >&2
exit 1
EOF
chmod +x "$TEST_DIR/bin/gh"

write_config() {
  printf '%s\n' "$1" >"$PROJECT/.touchstone-review.toml"
}

GH_LOG="$TEST_DIR/gh-calls.log"

# Runs a fixture script with only the stub gh on PATH, from a cwd that has no
# config of its own: the tracker must be resolved from the script's own
# project root, which is what the CI base checkout relies on.
run_fixture() {
  local script="$1" out="$2"
  shift 2
  : >"$GH_LOG"
  rm -f "$TEST_DIR/gh-views.count"
  (
    cd "$TEST_DIR" || exit 2
    PATH="$TEST_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      GH_CALL_LOG="$GH_LOG" \
      GH_VIEW_COUNT_FILE="$TEST_DIR/gh-views.count" \
      GH_USER_LOGIN="${GH_USER_LOGIN:-alice}" \
      GH_PRE_ASSIGNEES="${GH_PRE_ASSIGNEES:-}" \
      GH_POST_ASSIGNEES="${GH_POST_ASSIGNEES:-}" \
      GH_ASSIGNEES="${GH_ASSIGNEES:-}" \
      bash "$PROJECT/scripts/$script" "$@"
  ) >"$out" 2>&1
}

# ---------------------------------------------------------------------------
echo "==> Case 1: no [issues] declaration keeps the GitHub claim path"
# ---------------------------------------------------------------------------
write_config '[review]
preflight_required = true'
OUT="$TEST_DIR/case1.out"
GH_PRE_ASSIGNEES="" GH_POST_ASSIGNEES="alice" \
  run_fixture claim-issue.sh "$OUT" 12 "dispatch: case1" || fail "case 1 expected exit 0"
assert_file_contains "$GH_LOG" "issue edit 12 --add-assignee @me"
assert_file_contains "$GH_LOG" "issue comment 12 --body dispatch: case1"

# ---------------------------------------------------------------------------
echo "==> Case 2: a linear project claims without touching gh"
# ---------------------------------------------------------------------------
write_config '[issues]
tracker = "linear"
key_prefix = "CON"'
OUT="$TEST_DIR/case2.out"
RC=0
run_fixture claim-issue.sh "$OUT" CON-7 || RC=$?
# Exit 3, never 0: nothing was claimed, and a dispatching agent branches on
# this. Exiting 0 would let a scripted claim silently no-op (#743 review).
assert_eq "case 2 rc" "3" "$RC"
assert_file_contains "$OUT" "MANUAL CLAIM REQUIRED"
assert_file_contains "$OUT" "Assign CON-7 to yourself"
assert_file_contains "$OUT" "Fixes CON-7"
assert_file_contains "$OUT" "Exit 3 (manual action required): nothing has been claimed yet."
assert_file_empty "$GH_LOG" "case 2: the linear claim path must not invoke gh at all"

# ---------------------------------------------------------------------------
echo "==> Case 3: a linear project refuses a GitHub-shaped reference"
# ---------------------------------------------------------------------------
OUT="$TEST_DIR/case3.out"
RC=0
run_fixture claim-issue.sh "$OUT" 743 || RC=$?
assert_eq "case 3 rc" "2" "$RC"
assert_file_contains "$OUT" "is not a linear issue reference; expected a Linear issue key like CON-123"

# ---------------------------------------------------------------------------
echo "==> Case 4: key_prefix pins references to one team"
# ---------------------------------------------------------------------------
OUT="$TEST_DIR/case4.out"
RC=0
run_fixture claim-issue.sh "$OUT" ABC-7 || RC=$?
assert_eq "case 4 rc" "2" "$RC"
assert_file_contains "$OUT" "expected a Linear issue key like CON-123"

# ---------------------------------------------------------------------------
echo "==> Case 5: an unimplemented tracker fails closed with the remedy"
# ---------------------------------------------------------------------------
write_config '[issues]
tracker = "jira"'
OUT="$TEST_DIR/case5.out"
RC=0
run_fixture claim-issue.sh "$OUT" 12 || RC=$?
assert_eq "case 5 rc" "2" "$RC"
assert_file_contains "$OUT" "unknown issue tracker 'jira'"
assert_file_contains "$OUT" 'Set [issues].tracker = "github" or [issues].tracker = "linear"'
assert_file_empty "$GH_LOG" "case 5: an unhonorable declaration must fail before any transport runs"

OUT="$TEST_DIR/case5b.out"
BODY="$TEST_DIR/body-jira.md"
printf 'Closes #12\n' >"$BODY"
RC=0
run_fixture issue-claim-check.sh "$OUT" --body-file "$BODY" --author alice || RC=$?
assert_eq "case 5b rc" "2" "$RC"
assert_file_contains "$OUT" "unknown issue tracker 'jira'"

# ---------------------------------------------------------------------------
echo "==> Case 6: key_prefix under GitHub is a declaration error, not a no-op"
# ---------------------------------------------------------------------------
write_config '[issues]
tracker = "github"
key_prefix = "CON"'
OUT="$TEST_DIR/case6.out"
RC=0
run_fixture claim-issue.sh "$OUT" 12 || RC=$?
assert_eq "case 6 rc" "2" "$RC"
assert_file_contains "$OUT" "key_prefix applies to the linear tracker only"

# ---------------------------------------------------------------------------
echo "==> Case 7: the claim check reports linear references and checks no assignee"
# ---------------------------------------------------------------------------
write_config '[issues]
tracker = "linear"
key_prefix = "CON"'
BODY="$TEST_DIR/body-linear.md"
printf 'Some prose.\n\nFixes CON-42\nfixes con-42\n' >"$BODY"
OUT="$TEST_DIR/case7.out"
RC=0
run_fixture issue-claim-check.sh "$OUT" --body-file "$BODY" --author alice || RC=$?
# Exit 3, never 0: references were found and NOTHING was verified, so callers
# (open-pr, the CI workflow, merge-pr's substitution) each decide in the open
# what an unverifiable claim means rather than reading a green check.
assert_eq "case 7 rc" "3" "$RC"
assert_file_contains "$OUT" "has no claim-verification transport"
assert_file_contains "$OUT" "referenced: CON-42"
assert_file_contains "$OUT" "Exit 3 (unverifiable): this check enforced nothing for those references."
assert_eq "case 7 dedupes case-variant refs" "1" "$(grep -c 'referenced: CON-42' "$OUT")"
assert_file_empty "$GH_LOG" "case 7: a body-file check under linear must not invoke gh"

# ---------------------------------------------------------------------------
echo "==> Case 8: GitHub-shaped references in a linear project are not enforced"
# ---------------------------------------------------------------------------
BODY="$TEST_DIR/body-linear-hash.md"
printf 'Closes #12\n' >"$BODY"
OUT="$TEST_DIR/case8.out"
RC=0
run_fixture issue-claim-check.sh "$OUT" --body-file "$BODY" --author alice || RC=$?
assert_eq "case 8 rc" "0" "$RC"
assert_file_contains "$OUT" "No closing issue references found in PR body"
assert_file_empty "$GH_LOG" "case 8: a linear project must not query the GitHub issue API"

# ---------------------------------------------------------------------------
echo "==> Case 9: the GitHub adapter still fails an unclaimed issue"
# ---------------------------------------------------------------------------
write_config '[review]
preflight_required = true'
BODY="$TEST_DIR/body-github.md"
printf 'Closes #12\n' >"$BODY"
OUT="$TEST_DIR/case9.out"
RC=0
GH_ASSIGNEES="bob" run_fixture issue-claim-check.sh "$OUT" --body-file "$BODY" --author alice || RC=$?
assert_eq "case 9 rc" "1" "$RC"
assert_file_contains "$OUT" "Issue claim check failed"
assert_file_contains "$OUT" "bash scripts/claim-issue.sh 12"

OUT="$TEST_DIR/case9b.out"
RC=0
GH_ASSIGNEES="alice" run_fixture issue-claim-check.sh "$OUT" --body-file "$BODY" --author alice || RC=$?
assert_eq "case 9b rc" "0" "$RC"
assert_file_contains "$OUT" "All referenced issues are claimed by the PR author."

# ---------------------------------------------------------------------------
echo "==> Case 10: the shipped template documents the declaration"
# ---------------------------------------------------------------------------
assert_file_contains "$TOUCHSTONE_ROOT/templates/touchstone-review.toml" '# tracker = "linear"'
assert_file_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" 'Which tracker holds the issues'

# ---------------------------------------------------------------------------
echo "==> Case 11: the CI backstop decides what an unverifiable check means"
# ---------------------------------------------------------------------------
# The workflow is the last caller of the exit-code contract, and the only one
# that can turn "nothing was enforced" into a green required check. Run its
# actual shell step against a stub helper so the mapping is executed, not
# merely read: 3 passes WITH a notice, and every other status is untouched.
WORKFLOW="$TOUCHSTONE_ROOT/.github/workflows/issue-claim-check.yml"
STEP_SCRIPT="$TEST_DIR/claim-check-step.sh"
awk '
  /^        run: \|$/ { collecting = 1; next }
  collecting { sub(/^          /, ""); print }
' "$WORKFLOW" >"$STEP_SCRIPT"
if [ ! -s "$STEP_SCRIPT" ]; then
  fail "case 11: could not extract the claim-check workflow step from $WORKFLOW"
fi

STEP_DIR="$TEST_DIR/workflow-step"
mkdir -p "$STEP_DIR/.touchstone-claim-base/scripts"
run_workflow_step() {
  local helper_exit="$1" out="$2"
  cat >"$STEP_DIR/.touchstone-claim-base/scripts/issue-claim-check.sh" <<EOF
#!/usr/bin/env bash
echo "stub trusted-base helper"
exit $helper_exit
EOF
  (
    cd "$STEP_DIR" || exit 2
    PR_NUMBER=1 bash "$STEP_SCRIPT"
  ) >"$out" 2>&1
}

RC=0
run_workflow_step 3 "$TEST_DIR/step-unverifiable.out" || RC=$?
assert_eq "case 11 unverifiable rc" "0" "$RC"
assert_file_contains "$TEST_DIR/step-unverifiable.out" "::notice::Claim ownership was NOT verified"

RC=0
run_workflow_step 1 "$TEST_DIR/step-refuted.out" || RC=$?
assert_eq "case 11 refuted rc" "1" "$RC"
assert_file_empty_of "case 11: a refuted claim must not print the unverifiable notice" \
  "$TEST_DIR/step-refuted.out" "::notice::"

RC=0
run_workflow_step 0 "$TEST_DIR/step-verified.out" || RC=$?
assert_eq "case 11 verified rc" "0" "$RC"
assert_file_empty_of "case 11: a verified claim must not print the unverifiable notice" \
  "$TEST_DIR/step-verified.out" "::notice::"

RC=0
run_workflow_step 2 "$TEST_DIR/step-error.out" || RC=$?
assert_eq "case 11 environment-error rc" "2" "$RC"

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS case(s) failed"
  exit 1
fi

echo ""
echo "==> PASS: issue discipline dispatches on the declared tracker across 11 cases"
