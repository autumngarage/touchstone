#!/usr/bin/env bash
#
# tests/test-open-pr-exit-contract.sh — guard the open-pr.sh exit contract.
#
# Failure mode being prevented (flagged by the user 2026-04-28 with concrete
# example outriderintel #90-94): a swarm agent runs `open-pr.sh --auto-merge`,
# the PR opens, review passes, but the agent's session ends before merge
# completes. The script must NEVER exit 0 unless the PR is actually merged on
# GitHub, and any non-success terminal state must print the PR URL so a human
# (or the next agent) can see what's stuck.
#
# Cases covered:
#   1. Happy path — PR opens, merge-pr.sh succeeds, state MERGED → exit 0.
#   2. merge-pr.sh fails (review blocks, conflict, etc.) → nonzero + URL printed.
#   3. merge-pr.sh exits 0 but PR is NOT actually merged (the silent-orphan
#      class — gh API hiccup post-review) → nonzero + URL printed.
#   4. merge-pr.sh missing on disk → nonzero + URL printed (no silent skip).
#   5. Contradictory --draft + --auto-merge → nonzero before PR mutation.
#
# Design: the script under test is copied into a temp dir, real `git` is used
# (the repo is local), and `gh` plus `merge-pr.sh` are stubbed out. Stub
# behaviour is keyed by env vars so each test scenario reuses the same mocks
# with different toggles.
#
set -euo pipefail

export GH_REPO="" GH_HOST="" GITHUB_SERVER_URL=""

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=stage-touchstone-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/stage-touchstone-libs.sh"

TEST_DIR="$(mktemp -d -t touchstone-test-open-pr.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

REPO_DIR="$TEST_DIR/repo"
SCRIPT_DIR="$TEST_DIR/scripts"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$REPO_DIR" "$SCRIPT_DIR" "$FAKE_BIN"

cp "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$SCRIPT_DIR/open-pr.sh"
cp "$TOUCHSTONE_ROOT/scripts/issue-claim-check.sh" "$SCRIPT_DIR/issue-claim-check.sh"
mkdir -p "$TEST_DIR/lib"
cp "$TOUCHSTONE_ROOT/lib/toml.sh" "$TEST_DIR/lib/toml.sh"
cp "$TOUCHSTONE_ROOT/lib/sha256.sh" "$TEST_DIR/lib/sha256.sh"
stage_touchstone_libs "$TOUCHSTONE_ROOT" "$TEST_DIR/scripts"

chmod +x "$SCRIPT_DIR/open-pr.sh" "$SCRIPT_DIR/issue-claim-check.sh"

# Real git inside a fresh repo with a feature branch checked out, so the
# branch-name and uncommitted-tree checks all use real behaviour.
git -C "$REPO_DIR" init -b main >/dev/null 2>&1
git -C "$REPO_DIR" config user.name "Touchstone Test"
git -C "$REPO_DIR" config user.email "touchstone@example.com"
printf 'base\n' >"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
# open-pr.sh materializes the merge gate from the BASE revision rather than
# running the copy in the PR's worktree (issue #640), so a realistic fixture
# has to carry scripts/merge-pr.sh and lib/ in its history the way a
# bootstrapped project does. Committing them on the first commit means every
# branch below — including the stacked-PR parents — inherits them.
mkdir -p "$REPO_DIR/scripts" "$REPO_DIR/lib"
cat >"$REPO_DIR/scripts/merge-pr.sh" <<'BASEGATE'
#!/usr/bin/env bash
# Trusted base copy of the merge gate. Scenarios drive the stub that the
# worktree copy delegates to, so this file only has to prove WHICH copy ran.
#
# The capability markers below are load-bearing, not decoration: open-pr.sh
# refuses to authorize with a base gate that predates the PR-visible review
# requirement or PR-base binding, and a fixture without them represents a
# legacy gate. Named functions rather than a version string so the check
# tracks the capabilities themselves:
# require_pr_feedback_clear / wait_for_pr_triggered_review /
# current_pr_base_revision.
printf 'trusted-base-gate\n' >>"${MERGE_STUB_LOG:-/dev/null}"
exec bash "${MERGE_STUB_DELEGATE:?merge stub delegate not set}" "$@"
BASEGATE
chmod +x "$REPO_DIR/scripts/merge-pr.sh"
printf '# placeholder library shipped on the base revision\n' >"$REPO_DIR/lib/.keep.sh"
git -C "$REPO_DIR" commit -m "base commit" >/dev/null 2>&1
# A base that predates the vendored gate, for the refuse-to-authorize case.
git -C "$REPO_DIR" branch base/no-gate
git -C "$REPO_DIR" add scripts/merge-pr.sh lib/.keep.sh
git -C "$REPO_DIR" commit -m "vendor touchstone delivery scripts" >/dev/null 2>&1
git -C "$REPO_DIR" remote add origin "$REPO_DIR"
git -C "$REPO_DIR" branch feature/parent
git -C "$REPO_DIR" checkout -b feat/test >/dev/null 2>&1
printf 'change\n' >>"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -m "test change" >/dev/null 2>&1

# Mock gh — behaviour controlled by env vars so each scenario reuses one mock.
# GH_PR_STATE   — value returned for `gh pr view --json state,mergedAt`
# GH_MERGED_AT  — mergedAt value returned for `gh pr view --json state,mergedAt`
# GH_HAS_EXISTING_PR — if "1", `gh pr list` returns an existing PR URL
# GH_PR_IS_DRAFT — live draft state returned for an existing PR
# GH_PR_BODY — value returned for existing PR claim-preflight body reads
# GH_PR_AUTHOR — value returned for existing PR claim-preflight author reads
cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "api" ] && [ "${2:-}" = "--hostname" ]; then
  shift 3
  set -- api "$@"
fi
case "$1 $2" in
  "repo view")
    json_fields=""
    jq_expr=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--json" ]; then
        json_fields="$arg"
      elif [ "$prev" = "--jq" ]; then
        jq_expr="$arg"
      fi
      prev="$arg"
    done
    if [ "$json_fields" = "defaultBranchRef" ]; then
      echo "main"
    elif [ "$json_fields" = "nameWithOwner" ]; then
      echo "autumngarage/touchstone"
    elif [ "$json_fields" = "url" ]; then
      echo "https://github.com/autumngarage/touchstone"
    else
      echo "unexpected gh repo view json: $json_fields jq: $jq_expr" >&2
      exit 1
    fi
    ;;
  "pr list")
    if [ "${GH_HAS_EXISTING_PR:-0}" = "1" ]; then
      printf 'https://example.test/touchstone/pull/777\t%s\t%s\t%s\t%s\n' \
        "${GH_EXISTING_PR_BASE:-main}" \
        "${GH_PR_HEAD_OID:-existing-pr-head}" \
        "${GH_PR_IS_DRAFT:-false}" \
        "${GH_PR_IS_CROSS_REPO:-false}"
    else
      echo ""
    fi
    ;;
  "pr create")
    printf '%s\n' "$*" >>"$GH_PR_CREATE_LOG"
    echo "https://example.test/touchstone/pull/123"
    ;;
  "pr ready")
    printf '%s\n' "$*" >>"$GH_PR_READY_LOG"
    ;;
  "pr view")
    json_fields=""
    jq_expr=""
    repo_arg=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--json" ]; then
        json_fields="$arg"
      elif [ "$prev" = "--jq" ]; then
        jq_expr="$arg"
      elif [ "$prev" = "--repo" ]; then
        repo_arg="$arg"
      fi
      prev="$arg"
    done
    if [ "$json_fields" = "body" ]; then
      case "$jq_expr" in
        ".body // \"\"") echo "${GH_PR_BODY:-}" ;;
        *) echo "unexpected gh pr view jq: $jq_expr" >&2; exit 1 ;;
      esac
      exit 0
    fi
    if [ "$json_fields" = "body,author" ]; then
      case "$jq_expr" in
        ".body // \"\"") echo "${GH_PR_BODY:-}" ;;
        ".author.login // empty") echo "${GH_PR_AUTHOR:-alice}" ;;
        *) echo "unexpected gh pr view jq: $jq_expr" >&2; exit 1 ;;
      esac
      exit 0
    fi
    if [ "$json_fields" = "state,mergedAt" ] \
      && [ "${GH_REQUIRE_REPO_FOR_MERGED_AT:-0}" = "1" ] \
      && [ -z "$repo_arg" ]; then
      echo "repository required after worktree cleanup" >&2
      exit 1
    fi
    if [ "$json_fields" = "state,mergedAt" ]; then
      printf '{"state":"%s","mergedAt":"%s"}\n' "${GH_PR_STATE:-OPEN}" "${GH_MERGED_AT:-}"
      exit 0
    fi
    if [ "$json_fields" = "mergedAt" ]; then
      echo "${GH_MERGED_AT:-}"
      exit 0
    fi
    if [ "$json_fields" = "headRefOid" ]; then
      git rev-parse HEAD
      exit 0
    fi
    if [ "$json_fields" = "isDraft" ]; then
      # Post-push re-read of draft state. Defaults to the pr-list snapshot
      # value; set GH_PR_VIEW_IS_DRAFT to simulate a concurrent actor
      # changing the PR between the snapshot and the push.
      echo "${GH_PR_VIEW_IS_DRAFT:-${GH_PR_IS_DRAFT:-false}}"
      exit 0
    fi
    echo "unexpected gh pr view json: $json_fields jq: $jq_expr" >&2
    exit 1
    ;;
  "api user")
    echo "${GH_PR_AUTHOR:-alice}"
    ;;
  "api --paginate")
    case "${3:-}" in
      */pulls/*/reviews*)
        # Formal reviews at the PR (issue #751 per-head idempotency).
        if [ "${GH_HEAD_REVIEWS_FAIL:-0}" = "1" ]; then
          echo "review listing unavailable" >&2
          exit 1
        fi
        if [ -n "${GH_HEAD_REVIEWS:-}" ]; then
          printf '%s\n' "$GH_HEAD_REVIEWS"
        fi
        ;;
      */statuses | */statuses\?*)
        # Durable review-request records; empty by default.
        if [ -n "${GH_REQUEST_STATUS_RECORDS:-}" ]; then
          printf '%s\n' "$GH_REQUEST_STATUS_RECORDS"
        fi
        ;;
      */issues/*/comments*)
        # Comment-channel review results: post-filter TSV rows of
        # login<TAB>reviewed-sha<TAB>created-at<TAB>verdict (later fields
        # may be absent — the script treats them as empty). The REAL jq
        # filter is exercised separately by Case 47 against actual jq.
        if [ "${GH_RESULT_COMMENTS_FAIL:-0}" = "1" ]; then
          echo "comment listing unavailable" >&2
          exit 1
        fi
        if [ "${GH_RESULT_COMMENTS_FAIL:-0}" = "silent" ]; then
          exit 1
        fi
        if [ -n "${GH_RESULT_COMMENT_AUTHORS:-}" ]; then
          printf '%s\n' "$GH_RESULT_COMMENT_AUTHORS"
        fi
        ;;
      *)
        # No other prior records.
        ;;
    esac
    ;;
  "api -X")
    printf '%s\n' "$*" >>"$GH_REVIEW_REQUEST_LOG"
    case "${4:-}" in
      repos/autumngarage/touchstone/statuses/*)
        echo "2026-07-29T00:00:00Z"
        ;;
      repos/autumngarage/touchstone/issues/*/comments)
        echo "2026-07-29T00:00:01Z"
        ;;
      *) echo "unexpected gh api POST args: $*" >&2; exit 1 ;;
    esac
    ;;
  "api repos/"*)
    api_path="$2"
    jq_expr=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--jq" ]; then
        jq_expr="$arg"
      fi
      prev="$arg"
    done
    if [[ "$api_path" = repos/autumngarage/touchstone/pulls/* ]] \
      && [ "$jq_expr" = '[.base.ref, .base.sha] | @tsv' ]; then
      printf '%s\t%s\n' "${GH_CREATED_PR_BASE:-${GH_EXISTING_PR_BASE:-main}}" "$(git rev-parse "${GH_CREATED_PR_BASE:-${GH_EXISTING_PR_BASE:-main}}")"
      exit 0
    fi
    case "$api_path" in
      repos/autumngarage/touchstone/collaborators/*/permission)
        echo "write"
        exit 0
        ;;
    esac
    case "$api_path:$jq_expr" in
      "repos/autumngarage/touchstone/pulls/777:.body // \"\"")
        echo "${GH_PR_BODY:-}"
        ;;
      "repos/autumngarage/touchstone/pulls/777:.user.login // empty")
        echo "${GH_PR_AUTHOR:-alice}"
        ;;
      "repos/autumngarage/touchstone/issues/"*":.state")
        echo "open"
        ;;
      "repos/autumngarage/touchstone/issues/52:.assignees | map(.login) | join(\"\\n\")")
        echo "alice"
        ;;
      "repos/autumngarage/touchstone/issues/"*":.assignees | map(.login) | join(\"\\n\")")
        :
        ;;
      *)
        echo "unexpected gh api args: $*" >&2
        exit 1
        ;;
    esac
    ;;
  "issue view")
    echo "issue claim check must use REST reads: $*" >&2
    exit 90
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/gh"

# Stub git push so the script doesn't try to talk to a real remote.
# We wrap real git via $REAL_GIT for everything else.
#
# GIT_ADVANCE_REF_AFTER_MERGE_BASE / GIT_ADVANCE_REF_TO simulate a concurrent
# actor moving a remote-tracking ref mid-run (Case 4e): after any `git
# merge-base` call — the last git read request_pr_triggered_review makes while
# validating the base — the named ref is advanced, the way a concurrent fetch
# lands a base that moved after review admission was checked.
REAL_GIT="$(command -v git)"
cat >"$FAKE_BIN/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "push" ]; then
  echo "[mock] git push \$*"
  if [ -n "\${GIT_PUSH_LOG:-}" ]; then
    printf '%s\n' "\$*" >>"\$GIT_PUSH_LOG"
  fi
  case " \$* " in
    *" --force-with-lease="*)
      exit "\${GIT_PUSH_LEASE_EXIT:-0}"
      ;;
  esac
  if [ "\${GIT_PUSH_PLAIN_EXIT:-0}" != 0 ]; then
    echo " ! [rejected]        (non-fast-forward)" >&2
    exit "\${GIT_PUSH_PLAIN_EXIT}"
  fi
  exit 0
fi

# GIT_REVERT_RANGE_REVLIST_FAIL simulates an unreadable ancestor for exactly
# the traversal the revert-vs-closing-reference guard performs (a plain
# two-dot range ending at HEAD; every other rev-list there passes --not). The
# guard used to read that range through a process substitution, which throws
# the traversal status away — the loop saw empty output and the branch read as
# "no reverts here".
if [ "\${1:-}" = "rev-list" ] && [ "\${GIT_REVERT_RANGE_REVLIST_FAIL:-0}" = "1" ]; then
  case " \$* " in
    *" --not "*) ;;
    *..HEAD*)
      echo "fatal: bad object (simulated unreadable ancestor)" >&2
      exit 128
      ;;
  esac
fi
if [ "\${1:-}" = "merge-base" ] && [ -n "\${GIT_ADVANCE_REF_AFTER_MERGE_BASE:-}" ]; then
  rc=0
  "$REAL_GIT" "\$@" || rc=\$?
  "$REAL_GIT" update-ref "\$GIT_ADVANCE_REF_AFTER_MERGE_BASE" "\$GIT_ADVANCE_REF_TO"
  exit "\$rc"
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$FAKE_BIN/git"

# Stub merge-pr.sh — behaviour controlled by MERGE_PR_EXIT (default 0).
# When nonzero, simulates a blocked PR review.
cat >"$SCRIPT_DIR/merge-pr.sh" <<'EOF'
#!/usr/bin/env bash
echo "[mock merge-pr.sh] called for PR $1"
printf '%s\n' "${TOUCHSTONE_PR_TRIGGERED_REVIEW_REQUEST_COUNT:-}" \
  >"$MERGE_PR_REQUEST_COUNT_FILE"
exit "${MERGE_PR_EXIT:-0}"
EOF
chmod +x "$SCRIPT_DIR/merge-pr.sh"

# Helper: run open-pr.sh in the test repo with a given mock environment.
# Sets a clean PATH so only the fake gh+git are visible (plus system bins).
run_open_pr() {
  (
    cd "$REPO_DIR"
    if [ "${OPEN_PR_AUTO_MERGE:-1}" = "1" ]; then
      set -- --auto-merge "$@"
    fi
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
      GH_MERGED_AT="${GH_MERGED_AT:-}" \
      GH_PR_STATE="${GH_PR_STATE:-OPEN}" \
      GH_HAS_EXISTING_PR="${GH_HAS_EXISTING_PR:-0}" \
      GH_EXISTING_PR_BASE="${GH_EXISTING_PR_BASE:-main}" \
      GH_CREATED_PR_BASE="${GH_CREATED_PR_BASE:-}" \
      GH_PR_IS_DRAFT="${GH_PR_IS_DRAFT:-false}" \
      GH_PR_VIEW_IS_DRAFT="${GH_PR_VIEW_IS_DRAFT:-}" \
      GH_PR_BODY="${GH_PR_BODY:-}" \
      GH_PR_AUTHOR="${GH_PR_AUTHOR:-alice}" \
      GH_REQUIRE_REPO_FOR_MERGED_AT="${GH_REQUIRE_REPO_FOR_MERGED_AT:-0}" \
      GH_PR_HEAD_OID="${GH_PR_HEAD_OID:-existing-pr-head}" \
      GH_PR_IS_CROSS_REPO="${GH_PR_IS_CROSS_REPO:-false}" \
      GH_HEAD_REVIEWS="${GH_HEAD_REVIEWS:-}" \
      GH_HEAD_REVIEWS_FAIL="${GH_HEAD_REVIEWS_FAIL:-0}" \
      GH_REQUEST_STATUS_RECORDS="${GH_REQUEST_STATUS_RECORDS:-}" \
      GH_RESULT_COMMENT_AUTHORS="${GH_RESULT_COMMENT_AUTHORS:-}" \
      GH_RESULT_COMMENTS_FAIL="${GH_RESULT_COMMENTS_FAIL:-0}" \
      GIT_REVERT_RANGE_REVLIST_FAIL="${GIT_REVERT_RANGE_REVLIST_FAIL:-0}" \
      GIT_PUSH_PLAIN_EXIT="${GIT_PUSH_PLAIN_EXIT:-0}" \
      GIT_PUSH_LEASE_EXIT="${GIT_PUSH_LEASE_EXIT:-0}" \
      GIT_PUSH_LOG="$TEST_DIR/git-push.log" \
      MERGE_PR_EXIT="${MERGE_PR_EXIT:-0}" \
      MERGE_PR_REQUEST_COUNT_FILE="$TEST_DIR/merge-pr-request-count" \
      MERGE_STUB_DELEGATE="$SCRIPT_DIR/merge-pr.sh" \
      MERGE_STUB_LOG="$TEST_DIR/gate-provenance.log" \
      GH_PR_CREATE_LOG="$TEST_DIR/pr-create.log" \
      GH_PR_READY_LOG="$TEST_DIR/pr-ready.log" \
      GH_REVIEW_REQUEST_LOG="$TEST_DIR/review-request.log" \
      bash "${OPEN_PR_SCRIPT_DIR:-$SCRIPT_DIR}/open-pr.sh" "$@"
  )
}

reset_open_pr_logs() {
  : >"$TEST_DIR/pr-create.log"
  : >"$TEST_DIR/pr-ready.log"
  : >"$TEST_DIR/review-request.log"
  : >"$TEST_DIR/git-push.log"
  rm -f "$TEST_DIR/merge-pr-request-count"
}

# ---------------------------------------------------------------------------
# Case 1: happy path — exit 0, no orphan banner, mergedAt confirmed.
# ---------------------------------------------------------------------------
echo "==> Case 1: happy path"
OUT="$TEST_DIR/case1.out"
RC=0
GH_PR_STATE="MERGED" GH_MERGED_AT="2026-04-28T12:00:00Z" GH_HAS_EXISTING_PR=0 MERGE_PR_EXIT=0 \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q '==> Verified: PR #123 merged at 2026-04-28T12:00:00Z' "$OUT" \
  && grep -q '^1$' "$TEST_DIR/merge-pr-request-count" \
  && ! grep -q 'ORPHAN RISK' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected exit 0 + verified-merge line + no orphan banner" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 2: merge-pr.sh blocks on a review failure.
# Expect: nonzero exit + ORPHAN RISK banner with PR URL.
# ---------------------------------------------------------------------------
echo "==> Case 2: merge-pr.sh blocks on PR review"
OUT="$TEST_DIR/case2.out"
RC=0
GH_PR_STATE="OPEN" GH_MERGED_AT="" GH_HAS_EXISTING_PR=0 MERGE_PR_EXIT=1 \
  run_open_pr >"$OUT" 2>&1 || RC=$?

# The recovery banner must NOT advertise `--delete-branch`: an operator
# following the printed command deletes the head branch and closes any PR
# stacked on it (issue #713, PR #715 review). Recovery routes through the same
# non-deleting merge path the gate uses.
if [ "$RC" != "0" ] \
  && grep -q 'ORPHAN RISK: PR opened but not merged' "$OUT" \
  && grep -q 'https://example.test/touchstone/pull/123' "$OUT" \
  && grep -qE 'bash [^ ]*/merge-pr\.sh 123' "$OUT" \
  && ! grep -q -- '--delete-branch' "$OUT" \
  && grep -q 'gh pr close 123' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected nonzero exit + orphan banner + PR URL + recovery hints" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 2b: the orphan-recovery hint must survive a script path with spaces.
# The hint is copy-pasted by a human in an unknown shell: printed unquoted,
# the path splits into words and the advertised recovery never invokes
# merge-pr.sh (PR #715 review). The contract is printf %q rendering, so the
# expected fragment is computed with the same %q.
# ---------------------------------------------------------------------------
echo "==> Case 2b: orphan recovery hint shell-quotes a spaced script path"
SPACED_SCRIPT_DIR="$TEST_DIR/scripts with space"
mkdir -p "$SPACED_SCRIPT_DIR"
cp "$SCRIPT_DIR/open-pr.sh" "$SPACED_SCRIPT_DIR/open-pr.sh"
cp "$SCRIPT_DIR/issue-claim-check.sh" "$SPACED_SCRIPT_DIR/issue-claim-check.sh"
cp "$SCRIPT_DIR/merge-pr.sh" "$SPACED_SCRIPT_DIR/merge-pr.sh"
chmod +x "$SPACED_SCRIPT_DIR/open-pr.sh" "$SPACED_SCRIPT_DIR/issue-claim-check.sh" \
  "$SPACED_SCRIPT_DIR/merge-pr.sh"

OUT="$TEST_DIR/case2b.out"
RC=0
GH_PR_STATE="OPEN" GH_MERGED_AT="" GH_HAS_EXISTING_PR=0 MERGE_PR_EXIT=1 \
  OPEN_PR_SCRIPT_DIR="$SPACED_SCRIPT_DIR" \
  run_open_pr >"$OUT" 2>&1 || RC=$?

EXPECTED_HINT="bash $(printf '%q' "$SPACED_SCRIPT_DIR/merge-pr.sh") 123"
if [ "$RC" != "0" ] \
  && grep -q 'ORPHAN RISK: PR opened but not merged' "$OUT" \
  && grep -qF "$EXPECTED_HINT" "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: recovery hint must shell-quote the spaced merge-pr.sh path" >&2
  echo "    rc=$RC  expected fragment: $EXPECTED_HINT" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 3: silent orphan — merge-pr.sh exits 0 but mergedAt is empty.
# This is the dangerous case the new exit contract specifically catches:
# without verify_pr_merged the script would have exited 0 with an open PR.
# ---------------------------------------------------------------------------
echo "==> Case 3: silent orphan — merge-pr.sh exits 0 but PR not actually merged"
OUT="$TEST_DIR/case3.out"
RC=0
GH_PR_STATE="OPEN" GH_MERGED_AT="" GH_HAS_EXISTING_PR=0 MERGE_PR_EXIT=0 \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'merge-pr.sh exited 0 but PR #123 is not merged on GitHub' "$OUT" \
  && grep -q 'ORPHAN RISK: PR opened but not merged' "$OUT" \
  && grep -q 'https://example.test/touchstone/pull/123' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected nonzero exit + post-merge verification failure + orphan banner" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 4: the trusted base carries no merge gate — refuse, don't fall back.
#
# Before issue #640 this case hid the worktree copy of merge-pr.sh, because
# that copy was what ran. Now the gate is materialized from the base, so the
# meaningful absence is on the base: a project whose default branch predates
# the vendored delivery scripts must be refused, NOT quietly authorized by
# whatever the feature branch happens to contain.
# ---------------------------------------------------------------------------
echo "==> Case 4: trusted base carries no merge gate"
OUT="$TEST_DIR/case4.out"
RC=0
GH_PR_STATE="OPEN" GH_MERGED_AT="" GH_HAS_EXISTING_PR=0 \
  GH_CREATED_PR_BASE="base/no-gate" \
  run_open_pr --base base/no-gate >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'no scripts/merge-pr.sh' "$OUT" \
  && grep -q 'ORPHAN RISK: PR opened but not merged' "$OUT" \
  && grep -q 'https://example.test/touchstone/pull/123' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected nonzero exit + absent-base-gate error + orphan banner" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 4b: a PR that REWRITES the gate is authorized by the base gate.
#
# This is issue #640 itself. The worktree copy of merge-pr.sh is replaced with
# one that would authorize anything; the run must still go through the copy
# committed on the base, which is the only reviewed one. 12 of 40 recent
# commits on touchstone's own main modified these scripts, so this is the
# normal case for this repo, not an edge case.
# ---------------------------------------------------------------------------
echo "==> Case 4b: a PR rewriting merge-pr.sh is authorized by the BASE gate"
OUT="$TEST_DIR/case4b.out"
RC=0
: >"$TEST_DIR/gate-provenance.log"
CASE4B_RESTORE="$(git -C "$REPO_DIR" rev-parse HEAD)"
# Commit the edited gate on the feature branch — that is what a PR changing
# merge-pr.sh actually looks like, and open-pr.sh refuses to run on a dirty
# tree anyway.
cat >"$REPO_DIR/scripts/merge-pr.sh" <<'HOSTILE'
#!/usr/bin/env bash
# A gate edited by the PR under review. If this ever runs, the merge decision
# was made by unreviewed code and issue #640 has regressed.
printf 'worktree-gate\n' >>"${MERGE_STUB_LOG:-/dev/null}"
exit 0
HOSTILE
git -C "$REPO_DIR" add scripts/merge-pr.sh
git -C "$REPO_DIR" commit -m "PR edits the merge gate" >/dev/null 2>&1
GH_PR_STATE="MERGED" GH_MERGED_AT="2026-08-09T00:00:00Z" GH_HAS_EXISTING_PR=0 \
  run_open_pr >"$OUT" 2>&1 || RC=$?
git -C "$REPO_DIR" reset --hard "$CASE4B_RESTORE" >/dev/null 2>&1

if [ "$RC" = "0" ] \
  && grep -q 'trusted-base-gate' "$TEST_DIR/gate-provenance.log" \
  && ! grep -q 'worktree-gate' "$TEST_DIR/gate-provenance.log" \
  && grep -q 'Merge gate materialized from main' "$OUT" \
  && grep -q 'this branch modifies merge-pr.sh' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected the BASE gate to run, not the worktree copy" >&2
  echo "    rc=$RC" >&2
  echo "    provenance: $(tr '\n' ' ' <"$TEST_DIR/gate-provenance.log")" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 5: idempotency — invoked when a PR already exists, the script delegates
# to merge-pr.sh and verifies merge state. With merge-pr.sh succeeding and
# mergedAt populated, exit 0. (The earlier `exec` form also reached merge-pr;
# the new form additionally verifies — make sure the existing-PR path didn't
# regress on the happy path.)
# ---------------------------------------------------------------------------
echo "==> Case 5: existing-PR path with --auto-merge succeeds and verifies"
OUT="$TEST_DIR/case5.out"
RC=0
GH_PR_STATE="MERGED" GH_MERGED_AT="2026-04-28T13:00:00Z" GH_HAS_EXISTING_PR=1 GH_PR_BODY="Closes #52" MERGE_PR_EXIT=0 \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'PR already open' "$OUT" \
  && grep -q 'pass: @alice is assigned' "$OUT" \
  && grep -q '==> Verified: PR #777 merged at 2026-04-28T13:00:00Z' "$OUT" \
  && ! grep -q 'ORPHAN RISK' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected exit 0 + verified-merge for existing-PR path" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 6: existing PR path claim-preflights before merge-pr.sh.
# Expect: nonzero exit, claim-check remediation, and merge-pr.sh not called.
# ---------------------------------------------------------------------------
echo "==> Case 6: existing-PR path blocks unassigned issue before merge-pr.sh"
OUT="$TEST_DIR/case6.out"
RC=0
GH_PR_STATE="OPEN" GH_MERGED_AT="" GH_HAS_EXISTING_PR=1 GH_PR_BODY="Closes #50" MERGE_PR_EXIT=0 \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'Issue claim check failed' "$OUT" \
  && grep -q 'bash scripts/claim-issue.sh 50' "$OUT" \
  && ! grep -q '\[mock merge-pr.sh\] called' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected claim preflight to block before merge-pr.sh on existing PR" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 7: project-local PR body protocol check blocks before merge review.
# ---------------------------------------------------------------------------
echo "==> Case 7: PR body protocol preflight blocks before merge-pr.sh"
mkdir -p "$REPO_DIR/scripts"
cat >"$REPO_DIR/scripts/check-api-boundary-protocol.py" <<'EOF'
#!/usr/bin/env bash
[ "${GH_REPO:-}" = "autumngarage/touchstone" ] || {
  echo "missing GH_REPO context" >&2
  exit 43
}
case "${PR_NUMBER:-}" in
  123 | 777) ;;
  *) echo "missing PR_NUMBER context" >&2; exit 44 ;;
esac
case "${API_BOUNDARY_PR_BODY:-}" in
  *"Protocol: yes"*) exit 0 ;;
  *) echo "missing Protocol: yes" >&2; exit 42 ;;
esac
EOF
chmod +x "$REPO_DIR/scripts/check-api-boundary-protocol.py"
git -C "$REPO_DIR" add scripts/check-api-boundary-protocol.py
git -C "$REPO_DIR" commit -m "add body protocol checker" >/dev/null 2>&1

OUT="$TEST_DIR/case7.out"
RC=0
reset_open_pr_logs
GH_PR_STATE="OPEN" GH_MERGED_AT="" GH_HAS_EXISTING_PR=0 GH_PR_BODY="Missing protocol" MERGE_PR_EXIT=0 \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'Running PR body protocol preflight (new PR #123)' "$OUT" \
  && grep -q 'PR body protocol preflight failed for PR #123' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ] \
  && ! grep -q '\[mock merge-pr.sh\] called' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected PR body protocol preflight to block before merge-pr.sh" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 8: existing PR path uses the edited GitHub body and proceeds when fixed.
# ---------------------------------------------------------------------------
echo "==> Case 8: existing-PR protocol preflight uses edited body"
OUT="$TEST_DIR/case8.out"
RC=0
GH_PR_STATE="MERGED" GH_MERGED_AT="2026-04-28T14:00:00Z" GH_HAS_EXISTING_PR=1 GH_PR_BODY=$'Closes #52\n\nProtocol: yes' MERGE_PR_EXIT=0 \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'Running PR body protocol preflight (existing PR #777)' "$OUT" \
  && grep -q '==> Verified: PR #777 merged at 2026-04-28T14:00:00Z' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected existing-PR edited body to pass protocol preflight and merge" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 9: a new draft is a coordination surface. Creating it must not run the
# final body protocol, emit review-request statuses/comments, or call merge.
# ---------------------------------------------------------------------------
echo "==> Case 9: new draft skips semantic review and final body protocol"
OUT="$TEST_DIR/case13.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=0 GH_PR_BODY="Missing protocol" \
  run_open_pr --draft >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'Opened as draft; no semantic review was requested' "$OUT" \
  && grep -q -- '--draft' "$TEST_DIR/pr-create.log" \
  && ! grep -q 'Running PR body protocol preflight' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ] \
  && ! grep -q '\[mock merge-pr.sh\] called' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected new draft creation without final protocol or review" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 10: updating an existing draft with --draft keeps it draft and emits no
# final body preflight or semantic-review request.
# ---------------------------------------------------------------------------
echo "==> Case 10: existing draft update remains review-free"
OUT="$TEST_DIR/case14.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=true \
  GH_PR_BODY="Missing protocol" run_open_pr --draft >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'PR remains a draft; no semantic review was requested' "$OUT" \
  && ! grep -q 'Running PR body protocol preflight' "$OUT" \
  && [ ! -s "$TEST_DIR/pr-ready.log" ] \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected existing draft update to remain review-free" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 11: --draft on an existing ready PR is refused before the push. Prior
# exact-head review markers and @codex comments on the ready PR must not be
# left reusable behind a demoted draft, and the refusal must land before the
# push so the ready PR's reviewed head is never updated by this invocation.
# ---------------------------------------------------------------------------
echo "==> Case 11: --draft on an existing ready PR is refused before push"
OUT="$TEST_DIR/case15.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_BODY="Missing protocol" run_open_pr --draft >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'already ready for review; refusing --draft' "$OUT" \
  && ! grep -q '\[mock\] git push' "$OUT" \
  && [ ! -s "$TEST_DIR/pr-ready.log" ] \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected --draft on a ready PR to be refused before push" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 12: an existing draft without a final-shipping flag remains draft and
# tells the caller how to ship it, rather than requesting review implicitly.
# ---------------------------------------------------------------------------
echo "==> Case 12: existing draft without --auto-merge stays review-free"
OUT="$TEST_DIR/case16.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=true \
  GH_PR_BODY="Missing protocol" run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'PR is still a draft; no semantic review was requested' "$OUT" \
  && grep -q 'Rerun with --auto-merge to mark it ready' "$OUT" \
  && ! grep -q 'Running PR body protocol preflight' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected non-final invocation to leave draft review-free" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 13: final shipping of an existing draft runs both deterministic
# preflights, marks ready, requests exactly one review, then merges.
# ---------------------------------------------------------------------------
echo "==> Case 13: --auto-merge transitions draft after preflight and reviews once"
OUT="$TEST_DIR/case17.out"
RC=0
reset_open_pr_logs
GH_PR_STATE="MERGED" GH_MERGED_AT="2026-08-03T15:00:00Z" \
  GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=true \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' MERGE_PR_EXIT=0 \
  run_open_pr >"$OUT" 2>&1 || RC=$?
protocol_line="$(grep -n 'Running PR body protocol preflight' "$OUT" | head -1 | cut -d: -f1)"
ready_line="$(grep -n 'Marking draft PR #777 ready for review' "$OUT" | head -1 | cut -d: -f1)"
review_line="$(grep -n 'Requested GitHub Codex review' "$OUT" | head -1 | cut -d: -f1)"
review_comments="$(grep -c 'issues/777/comments' "$TEST_DIR/review-request.log" || true)"

if [ "$RC" = "0" ] \
  && [ -n "$protocol_line" ] && [ -n "$ready_line" ] && [ -n "$review_line" ] \
  && [ "$protocol_line" -lt "$ready_line" ] \
  && [ "$ready_line" -lt "$review_line" ] \
  && grep -q '^pr ready 777$' "$TEST_DIR/pr-ready.log" \
  && [ "$review_comments" = "1" ] \
  && grep -q '^1$' "$TEST_DIR/merge-pr-request-count" \
  && grep -q 'Verified: PR #777 merged at 2026-08-03T15:00:00Z' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected preflight -> ready -> one review -> verified merge" >&2
  echo "    rc=$RC protocol=$protocol_line ready=$ready_line review=$review_line comments=$review_comments" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 14: an existing ready PR with an invalid contract fails deterministic
# preflight before any review-request status or comment is emitted.
# ---------------------------------------------------------------------------
echo "==> Case 14: existing PR protocol failure precedes review request"
OUT="$TEST_DIR/case18.out"
RC=0
reset_open_pr_logs
GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_BODY=$'Closes #52\n\nMissing protocol' MERGE_PR_EXIT=0 \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'PR body protocol preflight failed for PR #777' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ] \
  && ! grep -q '\[mock merge-pr.sh\] called' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected invalid existing PR to fail before review request" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 15: post-merge verification still works after merge-pr.sh has removed
# the current worktree. The real failure mode is that gh can no longer infer
# the repository from cwd; the fix is to use the captured --repo explicitly.
# ---------------------------------------------------------------------------
echo "==> Case 15: post-merge verification uses captured repo context"
OUT="$TEST_DIR/case9.out"
RC=0
GH_PR_STATE="MERGED" GH_MERGED_AT="2026-05-17T17:10:41Z" GH_HAS_EXISTING_PR=0 GH_PR_BODY="Protocol: yes" GH_REQUIRE_REPO_FOR_MERGED_AT=1 MERGE_PR_EXIT=0 \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q '==> Verified: PR #123 merged at 2026-05-17T17:10:41Z' "$OUT" \
  && ! grep -q 'merge-pr.sh exited 0 but PR #123 is not merged on GitHub' "$OUT" \
  && ! grep -q 'ORPHAN RISK' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected verified merge using captured --repo context" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 16: verify_pr_merged stays sourceable by itself and treats state=MERGED
# as authoritative when mergedAt is briefly empty.
# ---------------------------------------------------------------------------
echo "==> Case 16: extracted verify_pr_merged handles state=MERGED without helpers"
VERIFY_FUNCTIONS="$TEST_DIR/verify-functions.sh"
VERIFY_COUNTER="$TEST_DIR/verify-calls"
VERIFY_PAYLOAD_DIR="$TEST_DIR/verify-payloads"
mkdir -p "$VERIFY_PAYLOAD_DIR"
awk '/^verify_pr_merged\(\)/,/^}$/' "$SCRIPT_DIR/open-pr.sh" >"$VERIFY_FUNCTIONS"
cat >>"$VERIFY_FUNCTIONS" <<'STUB'
gh() {
  if [ "$1" != "pr" ] || [ "$2" != "view" ]; then
    printf 'unexpected gh call: %s\n' "$*" >&2
    return 1
  fi
  local n
  n="$(cat "$VERIFY_COUNTER" 2>/dev/null || echo 0)"
  n=$((n + 1))
  printf '%s\n' "$n" >"$VERIFY_COUNTER"
  if [ -f "$VERIFY_PAYLOAD_DIR/$n" ]; then
    cat "$VERIFY_PAYLOAD_DIR/$n"
    return 0
  fi
  return 1
}
STUB
# shellcheck source=/dev/null
source "$VERIFY_FUNCTIONS"
printf '0\n' >"$VERIFY_COUNTER"
printf '{"state":"MERGED","mergedAt":""}\n' >"$VERIFY_PAYLOAD_DIR/1"
if out="$(VERIFY_PR_MERGED_BACKOFF_SEC=0 verify_pr_merged 900 2>&1)" \
  && grep -q 'state=MERGED' <<<"$out" \
  && [ "$(cat "$VERIFY_COUNTER")" = "1" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected extracted verify_pr_merged to accept MERGED state with empty mergedAt" >&2
  printf 'output: %s\n' "$out" >&2
  printf 'calls: %s\n' "$(cat "$VERIFY_COUNTER" 2>/dev/null || echo 0)" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 17: a new stacked PR states where the merge actually lands. Merges
# retain the head branch (issue #713, PR #715), so the old "squash orphans
# stacked children" warning must be gone; what must be said instead is that
# --auto-merge here merges into the PARENT branch, and children need
# retargeting + a rebase after their parent lands.
# ---------------------------------------------------------------------------
git -C "$REPO_DIR" commit --allow-empty -m $'exercise stacked warning\n\nProtocol: yes' >/dev/null 2>&1
echo "==> Case 17: new stacked PR names its real merge target"
OUT="$TEST_DIR/case11.out"
RC=0
GH_PR_STATE="MERGED" GH_MERGED_AT="2026-07-29T12:00:00Z" GH_HAS_EXISTING_PR=0 \
  GH_CREATED_PR_BASE="feature/parent" \
  GH_PR_BODY="Protocol: yes" MERGE_PR_EXIT=0 \
  run_open_pr --base feature/parent >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'merges this PR into feature/parent, not main' "$OUT" \
  && grep -q 'rebase once their parent lands' "$OUT" \
  && ! grep -q 'orphans' "$OUT" \
  && ! grep -q 'To ship straight to main' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected new-stack note to name the parent-branch merge target" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 18: an existing stacked PR additionally gets the concrete retarget
# command for shipping straight to the default branch instead.
# ---------------------------------------------------------------------------
echo "==> Case 18: existing stacked PR gets its concrete retarget command"
OUT="$TEST_DIR/case12.out"
RC=0
GH_PR_STATE="MERGED" GH_MERGED_AT="2026-07-29T12:10:00Z" \
  GH_HAS_EXISTING_PR=1 GH_EXISTING_PR_BASE="feature/parent" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' MERGE_PR_EXIT=0 \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'merges this PR into feature/parent, not main' "$OUT" \
  && grep -q 'To ship straight to main instead: gh pr edit 777 --base main' "$OUT" \
  && ! grep -q 'orphans' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected existing-stack note to include the explicit PR retarget" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 19: a current-base review request must not be spent on a branch whose
# head predates that base. This is deterministic before review or merge.
# ---------------------------------------------------------------------------
echo "==> Case 19: stale merge base blocks before review admission"
STALE_FEATURE_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
git -C "$REPO_DIR" checkout -q main
printf 'new base work\n' >"$REPO_DIR/base-advance.txt"
git -C "$REPO_DIR" add base-advance.txt
git -C "$REPO_DIR" commit -q -m "advance base during final evidence"
git -C "$REPO_DIR" checkout -q feat/test
if [ "$(git -C "$REPO_DIR" rev-parse HEAD)" != "$STALE_FEATURE_HEAD" ]; then
  echo "    FAIL: stale-base fixture changed the feature head" >&2
  ERRORS=$((ERRORS + 1))
fi
OUT="$TEST_DIR/case19.out"
RC=0
reset_open_pr_logs
GH_HAS_EXISTING_PR=1 GH_EXISTING_PR_BASE="main" GH_PR_IS_DRAFT=false \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' MERGE_PR_EXIT=0 \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'head does not contain the current main revision' "$OUT" \
  && grep -q 'No review request was recorded or submitted' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ] \
  && ! grep -q '\[mock merge-pr.sh\] called' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: stale base should fail before review intent, comment, or merge" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 20: --draft and --auto-merge promise incompatible terminal states. The
# contradiction must fail before discovery, push, claim, or GitHub mutation.
# Test both the new-PR and existing-PR environment because neither may turn a
# failed terminal delivery request into an intentionally open draft.
# ---------------------------------------------------------------------------
echo "==> Case 20: contradictory draft auto-merge fails before mutation"
for existing_pr in 0 1; do
  OUT="$TEST_DIR/case20-$existing_pr.out"
  RC=0
  reset_open_pr_logs
  OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR="$existing_pr" \
    run_open_pr --draft --auto-merge >"$OUT" 2>&1 || RC=$?

  if [ "$RC" != "0" ] \
    && grep -q -- '--draft and --auto-merge are mutually exclusive' "$OUT" \
    && ! grep -q '\[mock\] git push' "$OUT" \
    && [ ! -s "$TEST_DIR/pr-create.log" ] \
    && [ ! -s "$TEST_DIR/pr-ready.log" ] \
    && [ ! -s "$TEST_DIR/review-request.log" ] \
    && [ ! -f "$TEST_DIR/merge-pr-request-count" ]; then
    echo "    PASS: existing_pr=$existing_pr"
  else
    echo "    FAIL: contradictory flags mutated delivery state (existing_pr=$existing_pr)" >&2
    echo "    rc=$RC" >&2
    cat "$OUT" >&2
    ERRORS=$((ERRORS + 1))
  fi
done

# ---------------------------------------------------------------------------
# Cases 26-27: draft-ness authorizes the review-free exits, so it must be
# re-read after the push. A concurrent actor marking the draft ready between
# the pr-list snapshot and the push must not let the new head skip review.
# ---------------------------------------------------------------------------
echo "==> Case 26: --draft fails closed when the draft was concurrently promoted"
OUT="$TEST_DIR/case26.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=true \
  GH_PR_VIEW_IS_DRAFT=false GH_PR_BODY="Missing protocol" \
  run_open_pr --draft >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'marked ready for review while this draft update pushed' "$OUT" \
  && [ ! -s "$TEST_DIR/pr-ready.log" ] \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected concurrent promotion to fail a --draft update closed" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 27: concurrently promoted draft routes through final shipping"
OUT="$TEST_DIR/case27.out"
RC=0
reset_open_pr_logs
# Final shipping enforces the current-base gate; earlier cases advanced main,
# so bring the fixture branch up to date before exercising the reroute.
git -C "$REPO_DIR" rebase main >/dev/null 2>&1
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=true \
  GH_PR_VIEW_IS_DRAFT=false GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'concurrently marked ready; routing through final shipping' "$OUT" \
  && [ -s "$TEST_DIR/review-request.log" ] \
  && [ ! -s "$TEST_DIR/pr-ready.log" ] \
  && ! grep -q 'PR is still a draft' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected promoted draft to receive a review request via final shipping" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 28: concurrently demoted ready PR takes the review-free draft path"
OUT="$TEST_DIR/case28.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_VIEW_IS_DRAFT=true GH_PR_BODY="Missing protocol" \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'concurrently converted to draft; treating it as a draft' "$OUT" \
  && grep -q 'PR is still a draft; no semantic review was requested' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ] \
  && [ ! -s "$TEST_DIR/pr-ready.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected demoted PR to exit review-free as a draft" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 29: demoted PR under --auto-merge re-promotes and reviews once"
OUT="$TEST_DIR/case29.out"
RC=0
reset_open_pr_logs
GH_PR_STATE="MERGED" GH_MERGED_AT="2026-08-05T23:00:00Z" \
  GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false GH_PR_VIEW_IS_DRAFT=true \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' MERGE_PR_EXIT=0 \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'concurrently converted to draft; treating it as a draft' "$OUT" \
  && grep -q '^pr ready 777$' "$TEST_DIR/pr-ready.log" \
  && [ -s "$TEST_DIR/review-request.log" ] \
  && grep -q 'Verified: PR #777 merged' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected demoted PR under --auto-merge to re-promote and merge" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Cases 30-32 (issue #630): a rejected push on a branch with an open PR is
# the sanctioned rebase-after-takeover flow. Retry once with
# --force-with-lease pinned to the snapshot's observed PR head; fail closed
# without an open PR or when the lease is stale.
# ---------------------------------------------------------------------------
echo "==> Case 30: rebased PR branch resumes via guarded force-with-lease"
OUT="$TEST_DIR/case30.out"
RC=0
reset_open_pr_logs
# The observed remote head is an ancestor of local HEAD, so every remote
# change is incorporated and the guarded retry may publish the rebase.
OBSERVED_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
LOCAL_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$OBSERVED_HEAD" \
  GIT_PUSH_PLAIN_EXIT=1 GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'Retrying with --force-with-lease pinned to observed PR head' "$OUT" \
  && grep -q -- "--force-with-lease=feat/test:$OBSERVED_HEAD" "$TEST_DIR/git-push.log" \
  && grep -q -- "$LOCAL_HEAD:refs/heads/feat/test" "$TEST_DIR/git-push.log" \
  && [ -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected guarded lease retry to resume the rebased PR branch" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" "$TEST_DIR/git-push.log" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 31: rejected push without an open PR fails closed"
OUT="$TEST_DIR/case31.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=0 GIT_PUSH_PLAIN_EXIT=1 \
  GH_PR_BODY="Protocol: yes" run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'no open PR authorizes a guarded retry' "$OUT" \
  && ! grep -q -- '--force-with-lease' "$TEST_DIR/git-push.log" \
  && [ ! -s "$TEST_DIR/pr-create.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected non-PR branch push rejection to fail closed" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 32: stale lease fails closed without overwriting unseen work"
OUT="$TEST_DIR/case32.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$(git -C "$REPO_DIR" rev-parse HEAD)" \
  GIT_PUSH_PLAIN_EXIT=1 GIT_PUSH_LEASE_EXIT=1 \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'refusing to overwrite unseen work' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected stale lease to fail closed" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 33: unincorporated remote commits refuse the guarded retry"
OUT="$TEST_DIR/case33.out"
RC=0
reset_open_pr_logs
# Fabricate a commit object that exists locally but whose change was never
# incorporated into the branch history — a remote-only review commit seen by
# the snapshot from a stale checkout. Plumbing only; the worktree stays clean.
SIDE_BLOB="$(git -C "$REPO_DIR" hash-object -w /dev/stdin <<<"remote only change")"
SIDE_TREE="$(printf '100644 blob %s\tremote-only.txt\n' "$SIDE_BLOB" | git -C "$REPO_DIR" mktree)"
SIDE_SHA="$(git -C "$REPO_DIR" commit-tree "$SIDE_TREE" -p "$(git -C "$REPO_DIR" rev-parse HEAD)" -m "remote only commit")"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$SIDE_SHA" \
  GIT_PUSH_PLAIN_EXIT=1 GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'whose changes are not in this checkout' "$OUT" \
  && ! grep -q -- '--force-with-lease' "$TEST_DIR/git-push.log" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected unincorporated remote commits to refuse the retry" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 35: remote merge commit outside local history refuses the retry"
OUT="$TEST_DIR/case35.out"
RC=0
reset_open_pr_logs
# A merge of two LOCAL ancestors whose resolution tree differs from both:
# git cherry sees no unincorporated non-merge commits, but the resolution
# content exists nowhere locally — exactly the case patch comparison cannot
# prove. Plumbing only; the worktree stays clean.
MERGE_BLOB="$(git -C "$REPO_DIR" hash-object -w /dev/stdin <<<"merge resolution only")"
MERGE_TREE="$(printf '100644 blob %s\tresolution-only.txt\n' "$MERGE_BLOB" | git -C "$REPO_DIR" mktree)"
MERGE_SHA="$(git -C "$REPO_DIR" commit-tree "$MERGE_TREE" -p "$(git -C "$REPO_DIR" rev-parse HEAD)" -p "$(git -C "$REPO_DIR" rev-parse HEAD~1)" -m "remote merge with unseen resolution")"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$MERGE_SHA" \
  GIT_PUSH_PLAIN_EXIT=1 GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'Merge resolutions cannot be proven' "$OUT" \
  && ! grep -q -- '--force-with-lease' "$TEST_DIR/git-push.log" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected remote merge commit to refuse the guarded retry" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 36: history traversal failure refuses the retry (fail closed)"
OUT="$TEST_DIR/case36.out"
RC=0
reset_open_pr_logs
# A commit object that exists locally but references a missing parent: the
# existence check passes, then rev-list/cherry fail traversing. A check that
# could not run must not read as clean.
BROKEN_COMMIT="$(printf 'tree %s\nparent aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nauthor T <t@e.co> 1700000000 +0000\ncommitter T <t@e.co> 1700000000 +0000\n\nbroken ancestry\n' \
  "$(git -C "$REPO_DIR" rev-parse 'HEAD^{tree}')" \
  | git -C "$REPO_DIR" hash-object -t commit -w --stdin --literally)"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$BROKEN_COMMIT" \
  GIT_PUSH_PLAIN_EXIT=1 GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'could not be traversed' "$OUT" \
  && ! grep -q -- '--force-with-lease' "$TEST_DIR/git-push.log" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected traversal failure to refuse the retry" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 37: whitespace-only remote variant refuses the retry"
OUT="$TEST_DIR/case37.out"
RC=0
reset_open_pr_logs
# A remote commit whose patch differs from the local commit ONLY by trailing
# whitespace: git cherry's patch-ids treat them as equivalent, but whitespace
# is behaviorally significant — exact-content evidence must refuse.
WS_BLOB="$(git -C "$REPO_DIR" cat-file -p HEAD:file.txt | sed 's/change/change /' | git -C "$REPO_DIR" hash-object -w --stdin)"
OLD_BLOB="$(git -C "$REPO_DIR" rev-parse HEAD:file.txt)"
WS_TREE="$(git -C "$REPO_DIR" ls-tree HEAD | sed "s/$OLD_BLOB/$WS_BLOB/" | git -C "$REPO_DIR" mktree)"
WS_SHA="$(git -C "$REPO_DIR" commit-tree "$WS_TREE" -p "$(git -C "$REPO_DIR" rev-parse HEAD~1)" -m "test change")"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$WS_SHA" \
  GIT_PUSH_PLAIN_EXIT=1 GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'byte-for-byte' "$OUT" \
  && ! grep -q -- '--force-with-lease' "$TEST_DIR/git-push.log" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected whitespace-only remote variant to refuse the retry" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 38: git replace refs cannot spoof the integration evidence"
OUT="$TEST_DIR/case38.out"
RC=0
reset_open_pr_logs
# A replace ref maps the remote-only commit onto the local HEAD: with
# replacement objects honored, every inspection would see the local commit
# and bless the force-push while the lease matches the original remote SHA.
# The inspections must run with GIT_NO_REPLACE_OBJECTS=1 and refuse.
SPOOF_BLOB="$(git -C "$REPO_DIR" hash-object -w /dev/stdin <<<"spoofed remote content")"
SPOOF_TREE="$(printf '100644 blob %s\tspoofed-only.txt\n' "$SPOOF_BLOB" | git -C "$REPO_DIR" mktree)"
SPOOF_SHA="$(git -C "$REPO_DIR" commit-tree "$SPOOF_TREE" -p "$(git -C "$REPO_DIR" rev-parse HEAD~1)" -m "spoofed remote commit")"
git -C "$REPO_DIR" replace "$SPOOF_SHA" "$(git -C "$REPO_DIR" rev-parse HEAD)"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$SPOOF_SHA" \
  GIT_PUSH_PLAIN_EXIT=1 GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?
git -C "$REPO_DIR" replace -d "$SPOOF_SHA" >/dev/null 2>&1 || true

if [ "$RC" != "0" ] \
  && grep -q 'whose changes are not in this checkout' "$OUT" \
  && ! grep -q -- '--force-with-lease' "$TEST_DIR/git-push.log" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected replace-ref spoof to be refused" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 40: duplicate remote patches each require their own local twin"
OUT="$TEST_DIR/case40.out"
RC=0
reset_open_pr_logs
# Remote history carries the same patch TWICE (add X, revert X, add X
# again); the local branch incorporates the add and the revert ONCE each.
# Set-membership matching would let both remote adds claim the single
# local twin and force one occurrence away (touchstone#674).
CASE40_BASE="$(git -C "$REPO_DIR" rev-parse HEAD)"
CASE40_BLOB="$(git -C "$REPO_DIR" hash-object -w /dev/stdin <<<"duplicate patch payload")"
CASE40_TREE_X="$(git -C "$REPO_DIR" ls-tree HEAD | {
  cat
  printf '100644 blob %s\tdup-patch.txt\n' "$CASE40_BLOB"
} | git -C "$REPO_DIR" mktree)"
CASE40_TREE_BASE="$(git -C "$REPO_DIR" rev-parse "HEAD^{tree}")"
CASE40_A1="$(git -C "$REPO_DIR" commit-tree "$CASE40_TREE_X" -p "$CASE40_BASE" -m "remote add X")"
CASE40_R="$(git -C "$REPO_DIR" commit-tree "$CASE40_TREE_BASE" -p "$CASE40_A1" -m "remote revert X")"
CASE40_A2="$(git -C "$REPO_DIR" commit-tree "$CASE40_TREE_X" -p "$CASE40_R" -m "remote re-add X")"
CASE40_L1="$(git -C "$REPO_DIR" commit-tree "$CASE40_TREE_X" -p "$CASE40_BASE" -m "local add X")"
CASE40_L2="$(git -C "$REPO_DIR" commit-tree "$CASE40_TREE_BASE" -p "$CASE40_L1" -m "local revert X")"
git -C "$REPO_DIR" reset -q --hard "$CASE40_L2"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE40_A2" \
  GIT_PUSH_PLAIN_EXIT=1 GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?
git -C "$REPO_DIR" reset -q --hard "$CASE40_BASE"

if [ "$RC" != "0" ] \
  && grep -q 'whose changes are not in this checkout' "$OUT" \
  && ! grep -q -- '--force-with-lease' "$TEST_DIR/git-push.log" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: duplicate remote patches must not share one local twin" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 41: absent lib/preflight.sh fails closed (issue #689)"
OUT="$TEST_DIR/case41.out"
RC=0
reset_open_pr_logs
mv "$TEST_DIR/lib/preflight.sh" "$TEST_DIR/lib/preflight.sh.hidden"
OPEN_PR_AUTO_MERGE=0 GH_PR_BODY="Protocol: yes" run_open_pr >"$OUT" 2>&1 || RC=$?
mv "$TEST_DIR/lib/preflight.sh.hidden" "$TEST_DIR/lib/preflight.sh"
if [ "$RC" != "0" ] \
  && grep -q 'lib/preflight.sh is missing; required preflight validation cannot run' "$OUT" \
  && [ ! -s "$TEST_DIR/git-push.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: missing preflight module must fail closed before any push" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 39: fork-backed PR never authorizes the guarded retry"
OUT="$TEST_DIR/case39.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_IS_CROSS_REPO=true \
  GH_PR_HEAD_OID="$(git -C "$REPO_DIR" rev-parse HEAD)" \
  GIT_PUSH_PLAIN_EXIT=1 GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'fork-backed (cross-repository)' "$OUT" \
  && ! grep -q -- '--force-with-lease' "$TEST_DIR/git-push.log" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected fork-backed PR to refuse the guarded retry" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 34: unknown observed head refuses the guarded retry"
OUT="$TEST_DIR/case34.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="ffffffffffffffffffffffffffffffffffffffff" \
  GIT_PUSH_PLAIN_EXIT=1 GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'is not present locally' "$OUT" \
  && ! grep -q -- '--force-with-lease' "$TEST_DIR/git-push.log" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected unknown observed head to refuse the retry" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Cases 48-50 (issue #714): a closing reference records an INTENT, written
# early in a PR's life; nothing re-checks that the intent survived to the
# merged tree. PR #680 carried `Closes #593` on its first commit and reverted
# that fix on its fifth — the squash merge kept the trailer, GitHub closed
# #593, and the bug read as resolved for two days while it was still live.
# ---------------------------------------------------------------------------
echo "==> Case 48: a revert of an earlier commit's fix blocks its closing reference"
OUT="$TEST_DIR/case48.out"
RC=0
reset_open_pr_logs
CASE714_BASE="$(git -C "$REPO_DIR" rev-parse HEAD)"
printf 'the fix\n' >"$REPO_DIR/case714-fix.txt"
git -C "$REPO_DIR" add case714-fix.txt
git -C "$REPO_DIR" commit -q -m "fix: the UNSTABLE tolerance" -m "Closes-issue: #52"
CASE714_FIX="$(git -C "$REPO_DIR" rev-parse HEAD)"
printf 'unrelated\n' >"$REPO_DIR/case714-other.txt"
git -C "$REPO_DIR" add case714-other.txt
git -C "$REPO_DIR" commit -q -m "chore: unrelated follow-up"
git -C "$REPO_DIR" revert --no-edit "$CASE714_FIX" >/dev/null
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=0 GH_PR_BODY="Protocol: yes" \
  run_open_pr >"$OUT" 2>&1 || RC=$?

# The refusal has to land BEFORE the push: nothing about this branch should
# reach the remote while its closing reference is unverified.
if [ "$RC" != "0" ] \
  && grep -q 'closes issue(s) that a revert in the same PR may have undone' "$OUT" \
  && grep -q 'Unconfirmed closing reference(s): #52' "$OUT" \
  && [ ! -s "$TEST_DIR/git-push.log" ] \
  && [ ! -s "$TEST_DIR/pr-create.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: a reverted fix must not ship its closing reference" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 49: the recorded audit verdict ships the reference it names"
OUT="$TEST_DIR/case49.out"
RC=0
reset_open_pr_logs
git -C "$REPO_DIR" commit -q --allow-empty \
  -m "chore: audit closing refs against revert" \
  -m "[skip-revert-trailer-check] #52 verified present in HEAD"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=0 GH_PR_BODY="Protocol: yes" \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'shipping unverified closing reference(s): #52' "$OUT" \
  && [ -s "$TEST_DIR/pr-create.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: a recorded audit verdict must ship, and must say what it waived" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 49b: the audit verdict survives a range larger than a pipe buffer"
OUT="$TEST_DIR/case49b.out"
RC=0
reset_open_pr_logs
# `git log <range> | grep -q` under `set -o pipefail` reports 141 when grep
# matches early and git log is left holding more output than the pipe buffer
# takes: the match reads as NO match, and the documented escape silently stops
# working on exactly the long-lived branches most likely to carry a revert.
# The token goes on the NEWEST commit (git log emits newest-first) with ~190KB
# of message behind it, which makes the SIGPIPE deterministic rather than
# racy — two commits, no 300-commit fixture.
{
  echo "chore: a commit with a very large message body"
  echo
  awk 'BEGIN { for (i = 0; i < 4000; i++) print "padding padding padding padding padding padding" }'
} >"$TEST_DIR/big-commit-message.txt"
git -C "$REPO_DIR" commit -q --allow-empty -F "$TEST_DIR/big-commit-message.txt"
git -C "$REPO_DIR" commit -q --allow-empty \
  -m "chore: audit closing refs against revert" \
  -m "[skip-revert-trailer-check] #52 verified present in HEAD"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=0 GH_PR_BODY="Protocol: yes" \
  run_open_pr >"$OUT" 2>&1 || RC=$?
git -C "$REPO_DIR" reset -q --hard "$CASE714_BASE"

if [ "$RC" = "0" ] \
  && grep -q 'shipping unverified closing reference(s): #52' "$OUT" \
  && [ -s "$TEST_DIR/pr-create.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: a large commit-message range must not swallow the audit verdict" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 50: a revert that carries its own closing reference is self-consistent"
OUT="$TEST_DIR/case50.out"
RC=0
reset_open_pr_logs
printf 'the bad feature\n' >"$REPO_DIR/case714-bad.txt"
git -C "$REPO_DIR" add case714-bad.txt
git -C "$REPO_DIR" commit -q -m "feat: the bad feature"
git -C "$REPO_DIR" revert --no-edit HEAD >/dev/null
git -C "$REPO_DIR" commit -q --amend \
  -m "revert(feat): back out the bad feature" \
  -m "Closes-issue: #52"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=0 GH_PR_BODY="Protocol: yes" \
  run_open_pr >"$OUT" 2>&1 || RC=$?
git -C "$REPO_DIR" reset -q --hard "$CASE714_BASE"

# The revert IS the fix here, so the reference needs no separate verdict —
# and the guard must not force one, or every revert-shaped PR would be
# taught to reach for the waiver token.
if [ "$RC" = "0" ] \
  && grep -q 'every closing reference is carried by a revert itself' "$OUT" \
  && ! grep -q 'may have undone' "$OUT" \
  && [ -s "$TEST_DIR/pr-create.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: a self-consistent revert must ship without a waiver" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Cases 53-57 (issue #714, PR #807 review): the four holes the first cut of
# the revert guard left open. Each one made the guard return success on a
# branch whose closing reference would still auto-close a live issue.
# ---------------------------------------------------------------------------
echo "==> Case 53: an unreadable branch history fails the revert guard closed"
OUT="$TEST_DIR/case53.out"
RC=0
reset_open_pr_logs
# `while ... done < <(git rev-list ...)` discards the traversal status: a
# corrupt ancestor produced empty output, the loop found no revert, and the
# guard reported a clean branch. A check that could not run is not a clean
# check — capture and validate the revision list BEFORE iterating.
GIT_REVERT_RANGE_REVLIST_FAIL=1 \
  OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=0 GH_PR_BODY="Protocol: yes" \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q "history for the revert-vs-closing-reference" "$OUT" \
  && [ ! -s "$TEST_DIR/git-push.log" ] \
  && [ ! -s "$TEST_DIR/pr-create.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: an unreadable history must not read as 'no revert here'" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 54: a revert that is itself reverted needs a fresh verdict"
OUT="$TEST_DIR/case54.out"
RC=0
reset_open_pr_logs
# C2 reverts a bad C1 and carries `Closes-issue: #52` — self-consistent, the
# revert IS the fix. C3 then reverts C2, putting the bad change back. Treating
# every reference on any revert as permanently self-consistent shipped #52
# anyway and merge auto-closed an issue whose fix had been undone twice.
printf 'the bad change\n' >"$REPO_DIR/case54-bad.txt"
git -C "$REPO_DIR" add case54-bad.txt
git -C "$REPO_DIR" commit -q -m "feat: the bad change"
CASE54_C1="$(git -C "$REPO_DIR" rev-parse HEAD)"
git -C "$REPO_DIR" revert --no-edit "$CASE54_C1" >/dev/null
{
  printf 'Revert "feat: the bad change"\n\n'
  printf 'This reverts commit %s.\n\n' "$CASE54_C1"
  printf 'Closes-issue: #52\n'
} >"$TEST_DIR/case54-c2.msg"
git -C "$REPO_DIR" commit -q --amend -F "$TEST_DIR/case54-c2.msg"
CASE54_C2="$(git -C "$REPO_DIR" rev-parse HEAD)"
git -C "$REPO_DIR" revert --no-edit "$CASE54_C2" >/dev/null
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=0 GH_PR_BODY="Protocol: yes" \
  run_open_pr >"$OUT" 2>&1 || RC=$?
git -C "$REPO_DIR" reset -q --hard "$CASE714_BASE"

if [ "$RC" != "0" ] \
  && grep -q 'Reverted revert(s) restored the change behind: #52' "$OUT" \
  && [ ! -s "$TEST_DIR/git-push.log" ] \
  && [ ! -s "$TEST_DIR/pr-create.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: a reverted revert must not keep its closing reference" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 55: a closing reference persisted in the PR body is judged too"
OUT="$TEST_DIR/case55.out"
RC=0
reset_open_pr_logs
# The diagnostic tells the operator to write `Refs #N` instead of `Closes #N`.
# On an EXISTING PR that empties the commit-borne set while `Closes #52` stays
# in the PR body, which is what merge actually reads — the guard passed and
# GitHub closed the issue anyway.
printf 'temporary\n' >"$REPO_DIR/case55-bad.txt"
git -C "$REPO_DIR" add case55-bad.txt
git -C "$REPO_DIR" commit -q -m "feat: temporary" -m "Refs #52"
git -C "$REPO_DIR" revert --no-edit HEAD >/dev/null
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$(git -C "$REPO_DIR" rev-parse HEAD)" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?
git -C "$REPO_DIR" reset -q --hard "$CASE714_BASE"

if [ "$RC" != "0" ] \
  && grep -q 'Persisted in the PR body, where merge reads it: #52' "$OUT" \
  && grep -q 'Unconfirmed closing reference(s): #52' "$OUT" \
  && [ ! -s "$TEST_DIR/git-push.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: commit bodies are not the only source of closing references" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 56: a verdict authorizes only the issues it named"
OUT="$TEST_DIR/case56.out"
RC=0
reset_open_pr_logs
# An unconditional substring check made the first waiver on a branch a
# permanent bypass: a verdict naming only #52 also authorized a later
# `Closes #99` nobody ever audited.
printf 'the fix\n' >"$REPO_DIR/case56-fix.txt"
git -C "$REPO_DIR" add case56-fix.txt
git -C "$REPO_DIR" commit -q -m "fix: the tolerance" -m "Closes-issue: #52"
CASE56_FIX="$(git -C "$REPO_DIR" rev-parse HEAD)"
printf 'unrelated\n' >"$REPO_DIR/case56-other.txt"
git -C "$REPO_DIR" add case56-other.txt
git -C "$REPO_DIR" commit -q -m "chore: unrelated follow-up"
git -C "$REPO_DIR" revert --no-edit "$CASE56_FIX" >/dev/null
git -C "$REPO_DIR" commit -q --allow-empty \
  -m "chore: audit closing refs against revert" \
  -m "[skip-revert-trailer-check] #52 verified present in HEAD"
printf 'later\n' >"$REPO_DIR/case56-later.txt"
git -C "$REPO_DIR" add case56-later.txt
git -C "$REPO_DIR" commit -q -m "feat: work added after the audit" -m "Closes-issue: #99"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=0 GH_PR_BODY="Protocol: yes" \
  run_open_pr >"$OUT" 2>&1 || RC=$?
git -C "$REPO_DIR" reset -q --hard "$CASE714_BASE"

if [ "$RC" != "0" ] \
  && grep -q 'do not authorize: #99' "$OUT" \
  && [ ! -s "$TEST_DIR/git-push.log" ] \
  && [ ! -s "$TEST_DIR/pr-create.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: a verdict naming #52 must not authorize an unaudited #99" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 57: a verdict written before a later revert is not honored"
OUT="$TEST_DIR/case57.out"
RC=0
reset_open_pr_logs
# The other half of the same hole: reverts added AFTER the verdict stayed
# waived, so an audit of yesterday's branch authorized today's revert.
printf 'the fix\n' >"$REPO_DIR/case57-fix.txt"
git -C "$REPO_DIR" add case57-fix.txt
git -C "$REPO_DIR" commit -q -m "fix: the tolerance" -m "Closes-issue: #52"
CASE57_FIX="$(git -C "$REPO_DIR" rev-parse HEAD)"
printf 'unrelated\n' >"$REPO_DIR/case57-other.txt"
git -C "$REPO_DIR" add case57-other.txt
git -C "$REPO_DIR" commit -q -m "chore: unrelated follow-up"
CASE57_OTHER="$(git -C "$REPO_DIR" rev-parse HEAD)"
git -C "$REPO_DIR" revert --no-edit "$CASE57_FIX" >/dev/null
git -C "$REPO_DIR" commit -q --allow-empty \
  -m "chore: audit closing refs against revert" \
  -m "[skip-revert-trailer-check] #52 verified present in HEAD"
git -C "$REPO_DIR" revert --no-edit "$CASE57_OTHER" >/dev/null
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=0 GH_PR_BODY="Protocol: yes" \
  run_open_pr >"$OUT" 2>&1 || RC=$?
git -C "$REPO_DIR" reset -q --hard "$CASE714_BASE"

if [ "$RC" != "0" ] \
  && grep -q 'Verdict(s) that predate a later revert on this branch are not honored' "$OUT" \
  && grep -q 'Unconfirmed closing reference(s): #52' "$OUT" \
  && [ ! -s "$TEST_DIR/git-push.log" ] \
  && [ ! -s "$TEST_DIR/pr-create.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: a verdict that predates a later revert must not waive it" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Cases 51-52 (issue #721): the force-push integration evidence must identify
# CONTENT, not patch text. Hashing a patch with its hunk coordinates stripped
# leaves the patch with no location identity, so the same textual edit made to
# two different occurrences of a repeated block fingerprints identically — and
# the guard force-pushes away a remote commit it never incorporated.
# ---------------------------------------------------------------------------
echo "==> Case 51: an identical edit at a different offset refuses the guarded retry"
OUT="$TEST_DIR/case51.out"
RC=0
reset_open_pr_logs
CASE51_BASE="$(git -C "$REPO_DIR" rev-parse HEAD)"
awk 'BEGIN { for (i = 0; i < 40; i++) print "same" }' >"$REPO_DIR/repeat.txt"
git -C "$REPO_DIR" add repeat.txt
git -C "$REPO_DIR" commit -q -m "add a block of identical lines"
CASE51_SHARED="$(git -C "$REPO_DIR" rev-parse HEAD)"
CASE51_OLD_BLOB="$(git -C "$REPO_DIR" rev-parse HEAD:repeat.txt)"
# Two commits that insert the SAME line into the SAME file, one near the top
# and one near the bottom of a block of identical lines. With three lines of
# context on either side the patch TEXT of the two is byte-identical once hunk
# coordinates are stripped; only the resulting blob tells them apart.
CASE51_TOP_BLOB="$(awk 'NR == 10 { print "MARKER" } { print }' "$REPO_DIR/repeat.txt" \
  | git -C "$REPO_DIR" hash-object -w --stdin)"
CASE51_BOTTOM_BLOB="$(awk 'NR == 30 { print "MARKER" } { print }' "$REPO_DIR/repeat.txt" \
  | git -C "$REPO_DIR" hash-object -w --stdin)"
CASE51_TOP_TREE="$(git -C "$REPO_DIR" ls-tree HEAD | sed "s/$CASE51_OLD_BLOB/$CASE51_TOP_BLOB/" | git -C "$REPO_DIR" mktree)"
CASE51_BOTTOM_TREE="$(git -C "$REPO_DIR" ls-tree HEAD | sed "s/$CASE51_OLD_BLOB/$CASE51_BOTTOM_BLOB/" | git -C "$REPO_DIR" mktree)"
CASE51_REMOTE="$(git -C "$REPO_DIR" commit-tree "$CASE51_TOP_TREE" -p "$CASE51_SHARED" -m "insert marker")"
CASE51_LOCAL="$(git -C "$REPO_DIR" commit-tree "$CASE51_BOTTOM_TREE" -p "$CASE51_SHARED" -m "insert marker")"
git -C "$REPO_DIR" reset -q --hard "$CASE51_LOCAL"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE51_REMOTE" \
  GIT_PUSH_PLAIN_EXIT=1 GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'whose changes are not in this checkout' "$OUT" \
  && ! grep -q -- '--force-with-lease' "$TEST_DIR/git-push.log" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: an unincorporated remote edit at another offset must not be forced away" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" "$TEST_DIR/git-push.log" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 52: the same content reached through a different parent still authorizes"
OUT="$TEST_DIR/case52.out"
RC=0
reset_open_pr_logs
# The complementary invariant, so "refuse everything" cannot pass Case 51:
# a real rebase produces the same content under a different parent, and the
# guarded resume exists precisely to publish it. The extra local no-op commit
# also exercises the empty-change-list path, which contributes no twin.
CASE52_REMOTE="$(git -C "$REPO_DIR" commit-tree "$CASE51_TOP_TREE" -p "$CASE51_SHARED" -m "insert marker (remote)")"
CASE52_NOOP="$(git -C "$REPO_DIR" commit-tree "$(git -C "$REPO_DIR" rev-parse "$CASE51_SHARED^{tree}")" -p "$CASE51_SHARED" -m "no-op rebase artifact")"
CASE52_LOCAL="$(git -C "$REPO_DIR" commit-tree "$CASE51_TOP_TREE" -p "$CASE52_NOOP" -m "insert marker (rebased)")"
git -C "$REPO_DIR" reset -q --hard "$CASE52_LOCAL"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE52_REMOTE" \
  GIT_PUSH_PLAIN_EXIT=1 GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?
git -C "$REPO_DIR" reset -q --hard "$CASE51_BASE"

if [ "$RC" = "0" ] \
  && grep -q 'every observed-head change is incorporated locally' "$OUT" \
  && grep -q -- "--force-with-lease=feat/test:$CASE52_REMOTE" "$TEST_DIR/git-push.log" \
  && grep -q -- "$CASE52_LOCAL:refs/heads/feat/test" "$TEST_DIR/git-push.log"; then
  echo "    PASS"
else
  echo "    FAIL: a rebased twin of the same content must still authorize the resume" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" "$TEST_DIR/git-push.log" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 58: a rebase onto a parent that edits the same file still ships"
OUT="$TEST_DIR/case58.out"
RC=0
reset_open_pr_logs
# Post-image blob identity rejected the most ordinary reconciled rebase there
# is (PR #807 review): the new parent edits ANOTHER PART of the same file, so
# the rebased commit's delta is byte-identical while its whole-file post-image
# is not. Nothing the operator can do — fetch, rebase, rerun — clears that
# refusal, which makes the guard unusable rather than safe.
CASE58_BASE="$(git -C "$REPO_DIR" rev-parse HEAD)"
{
  echo "header line 1"
  echo "header line 2"
  awk 'BEGIN { for (i = 3; i <= 40; i++) printf "body line %d\n", i }'
} >"$REPO_DIR/case58.txt"
git -C "$REPO_DIR" add case58.txt
git -C "$REPO_DIR" commit -q -m "add a file with a top and a bottom"
CASE58_SHARED="$(git -C "$REPO_DIR" rev-parse HEAD)"
CASE58_OLD_BLOB="$(git -C "$REPO_DIR" rev-parse HEAD:case58.txt)"
CASE58_FEATURE_BLOB="$(sed 's/^body line 38$/body line 38 EDITED-BY-FEATURE/' "$REPO_DIR/case58.txt" \
  | git -C "$REPO_DIR" hash-object -w --stdin)"
CASE58_MAIN_BLOB="$(sed 's/^header line 1$/header line 1 EDITED-BY-MAIN/' "$REPO_DIR/case58.txt" \
  | git -C "$REPO_DIR" hash-object -w --stdin)"
CASE58_BOTH_BLOB="$(sed -e 's/^header line 1$/header line 1 EDITED-BY-MAIN/' \
  -e 's/^body line 38$/body line 38 EDITED-BY-FEATURE/' "$REPO_DIR/case58.txt" \
  | git -C "$REPO_DIR" hash-object -w --stdin)"
CASE58_FEATURE_TREE="$(git -C "$REPO_DIR" ls-tree HEAD | sed "s/$CASE58_OLD_BLOB/$CASE58_FEATURE_BLOB/" | git -C "$REPO_DIR" mktree)"
CASE58_MAIN_TREE="$(git -C "$REPO_DIR" ls-tree HEAD | sed "s/$CASE58_OLD_BLOB/$CASE58_MAIN_BLOB/" | git -C "$REPO_DIR" mktree)"
CASE58_BOTH_TREE="$(git -C "$REPO_DIR" ls-tree HEAD | sed "s/$CASE58_OLD_BLOB/$CASE58_BOTH_BLOB/" | git -C "$REPO_DIR" mktree)"
CASE58_REMOTE="$(git -C "$REPO_DIR" commit-tree "$CASE58_FEATURE_TREE" -p "$CASE58_SHARED" -m "feat: edit the bottom")"
CASE58_NEW_PARENT="$(git -C "$REPO_DIR" commit-tree "$CASE58_MAIN_TREE" -p "$CASE58_SHARED" -m "chore: edit the top")"
CASE58_LOCAL="$(git -C "$REPO_DIR" commit-tree "$CASE58_BOTH_TREE" -p "$CASE58_NEW_PARENT" -m "feat: edit the bottom (rebased)")"
git -C "$REPO_DIR" reset -q --hard "$CASE58_LOCAL"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE58_REMOTE" \
  GIT_PUSH_PLAIN_EXIT=1 GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

# The post-images genuinely differ — that is the whole point of the case, and
# asserting it here keeps the fixture honest if someone "simplifies" it later.
if [ "$(git -C "$REPO_DIR" rev-parse "$CASE58_REMOTE:case58.txt")" \
  = "$(git -C "$REPO_DIR" rev-parse "$CASE58_LOCAL:case58.txt")" ]; then
  echo "    FAIL: fixture no longer differs in its post-image blob" >&2
  ERRORS=$((ERRORS + 1))
elif [ "$RC" = "0" ] \
  && grep -q 'every observed-head change is incorporated locally' "$OUT" \
  && grep -q -- "--force-with-lease=feat/test:$CASE58_REMOTE" "$TEST_DIR/git-push.log" \
  && grep -q -- "$CASE58_LOCAL:refs/heads/feat/test" "$TEST_DIR/git-push.log"; then
  echo "    PASS"
else
  echo "    FAIL: a reconciled rebase must be publishable, not permanently refused" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" "$TEST_DIR/git-push.log" >&2
  ERRORS=$((ERRORS + 1))
fi
git -C "$REPO_DIR" reset -q --hard "$CASE58_BASE"

echo "==> Case 59: the same states in the wrong order refuse the guarded retry"
OUT="$TEST_DIR/case59.out"
RC=0
reset_open_pr_logs
# Remote applied X -> Y -> Z; this checkout applied X -> Z -> Y, so local HEAD
# is Y and the remote head's final Z content exists nowhere locally. An
# unordered pool of per-commit evidence found a twin for both Y and Z and
# force-pushed Z away — the exact defect class issue #721 exists to prevent,
# reintroduced by the fix for it. Ordered correspondence runs out of
# candidates instead.
CASE59_BASE="$(git -C "$REPO_DIR" rev-parse HEAD)"
printf 'state-seed\n' >"$REPO_DIR/case59.txt"
git -C "$REPO_DIR" add case59.txt
git -C "$REPO_DIR" commit -q -m "add case59.txt"
CASE59_SHARED="$(git -C "$REPO_DIR" rev-parse HEAD)"
CASE59_SEED_BLOB="$(git -C "$REPO_DIR" rev-parse HEAD:case59.txt)"
case59_tree() {
  local blob
  blob="$(printf '%s\n' "$1" | git -C "$REPO_DIR" hash-object -w --stdin)"
  git -C "$REPO_DIR" ls-tree "$CASE59_SHARED" \
    | sed "s/$CASE59_SEED_BLOB/$blob/" \
    | git -C "$REPO_DIR" mktree
}
CASE59_TREE_X="$(case59_tree state-x)"
CASE59_TREE_Y="$(case59_tree state-y)"
CASE59_TREE_Z="$(case59_tree state-z)"
CASE59_RX="$(git -C "$REPO_DIR" commit-tree "$CASE59_TREE_X" -p "$CASE59_SHARED" -m "remote X")"
CASE59_RY="$(git -C "$REPO_DIR" commit-tree "$CASE59_TREE_Y" -p "$CASE59_RX" -m "remote Y")"
CASE59_RZ="$(git -C "$REPO_DIR" commit-tree "$CASE59_TREE_Z" -p "$CASE59_RY" -m "remote Z")"
CASE59_LX="$(git -C "$REPO_DIR" commit-tree "$CASE59_TREE_X" -p "$CASE59_SHARED" -m "local X")"
CASE59_LZ="$(git -C "$REPO_DIR" commit-tree "$CASE59_TREE_Z" -p "$CASE59_LX" -m "local Z")"
CASE59_LY="$(git -C "$REPO_DIR" commit-tree "$CASE59_TREE_Y" -p "$CASE59_LZ" -m "local Y")"
git -C "$REPO_DIR" reset -q --hard "$CASE59_LY"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE59_RZ" \
  GIT_PUSH_PLAIN_EXIT=1 GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?
git -C "$REPO_DIR" reset -q --hard "$CASE59_BASE"

# Naming the commit pins WHICH remote change had no ordered counterpart: the
# final Z. A blanket refusal that named X or Y would mean something else broke.
if [ "$RC" != "0" ] \
  && grep -q "carries commit ${CASE59_RZ:0:12}" "$OUT" \
  && grep -q 'whose changes are not in this checkout' "$OUT" \
  && ! grep -q -- '--force-with-lease' "$TEST_DIR/git-push.log" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: a reordered local history must not force away the remote's final state" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" "$TEST_DIR/git-push.log" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Cases 42-44 (issue #751): the review request is idempotent per head. A
# trusted formal review already bound to the exact current head (with its
# durable request evidence in place) means the head is reviewed — a second
# invocation must say so and must NOT post another @codex request. A review
# bound to a DIFFERENT commit gives no such license: the new head requests
# normally. A failed review lookup is reported as inspection failure and
# falls back to the evidence-based idempotency — never treated as "reviewed"
# or "not reviewed".
# ---------------------------------------------------------------------------
echo "==> Case 42: reviewed unchanged head is not re-requested"
OUT="$TEST_DIR/case42.out"
RC=0
reset_open_pr_logs
CASE42_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
CASE42_BASE_SHA="$(git -C "$REPO_DIR" rev-parse main)"
CASE42_RECORDS="$(printf 'touchstone/review-request-intent\t2026-08-01T00:00:00Z\thenrymodisett\tpr=777 base=%s\ntouchstone/review-request-complete\t2026-08-01T00:00:05Z\thenrymodisett\tpr=777 base=%s intent=2026-08-01T00:00:00Z trigger=2026-08-01T00:00:05Z' \
  "$CASE42_BASE_SHA" "$CASE42_BASE_SHA")"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE42_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE42_RECORDS" \
  GH_HEAD_REVIEWS="$(printf 'chatgpt-codex-connector[bot]\t%s\tCOMMENTED\t2026-08-01T00:00:06Z' "$CASE42_HEAD")" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'is already reviewed: a trusted formal review exists for this exact head; not re-requesting' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected reviewed unchanged head to skip the review request" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 42b (PR #755 review): --fresh-review overrides the per-head idempotency.
# Without it, a BODY-ONLY finding deadlocks: the merge gate cannot accept it
# via thread resolution and says "request a fresh review", while this script
# answers "already reviewed" and requests nothing. The flag must spend a real
# request on the identical evidence state that Case 42 skips.
echo "==> Case 42b: --fresh-review forces a request on a reviewed unchanged head"
OUT="$TEST_DIR/case42b.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE42_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE42_RECORDS" \
  GH_HEAD_REVIEWS="$(printf 'chatgpt-codex-connector[bot]\t%s\tCOMMENTED\t2026-08-01T00:00:06Z' "$CASE42_HEAD")" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr --fresh-review >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q -- '--fresh-review: forcing a new review request' "$OUT" \
  && [ -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: --fresh-review must override the idempotent skip and post a request" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 42c (PR #755 review, round 5): a DISMISSED review is revoked evidence
# and must NOT satisfy request idempotency. The merge gate refuses dismissed
# reviews, so a state-blind skip here would suppress the only re-request that
# could produce valid evidence — open-pr.sh saying "already reviewed" while
# merge-pr.sh says "not reviewed", until timeout.
echo "==> Case 42c: a dismissed review does not suppress the review request"
OUT="$TEST_DIR/case42c.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE42_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE42_RECORDS" \
  GH_HEAD_REVIEWS="$(printf 'chatgpt-codex-connector[bot]\t%s\tDISMISSED\t2026-08-01T00:00:07Z' "$CASE42_HEAD")" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && ! grep -q 'is already reviewed' "$OUT" \
  && grep -q 'posting a fresh request intent' "$OUT" \
  && [ -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: a dismissed review must not satisfy per-head idempotency" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 42d (PR #755 review, round 8): a review submitted BETWEEN the request
# intent and its @codex trigger predates the ask — it was never this
# request's answer, so its later dismissal must NOT consume the request. The
# real answer is still in flight; the correct behavior is the ordinary
# idempotent skip, not a replacement request.
echo "==> Case 42d: a dismissed pre-trigger review does not consume the request"
OUT="$TEST_DIR/case42d.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE42_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE42_RECORDS" \
  GH_HEAD_REVIEWS="$(printf 'chatgpt-codex-connector[bot]\t%s\tDISMISSED\t2026-08-01T00:00:03Z' "$CASE42_HEAD")" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'already requested for head' "$OUT" \
  && ! grep -q 'posting a fresh request intent' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: a pre-trigger dismissal must leave the in-flight request alone" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 42e (PR #755 review, round 9): a post-trigger dismissal must consume
# the request even when an OLDER live review shares the head — the
# reviewed-head skip would otherwise fire first and strand the gate between
# a rejected dismissed answer and a review that predates the request.
echo "==> Case 42e: consumption wins over the reviewed-head skip"
OUT="$TEST_DIR/case42e.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE42_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE42_RECORDS" \
  GH_HEAD_REVIEWS="$(printf 'chatgpt-codex-connector[bot]\t%s\tCOMMENTED\t2026-07-31T00:00:00Z\nchatgpt-codex-connector[bot]\t%s\tDISMISSED\t2026-08-01T00:00:07Z' "$CASE42_HEAD" "$CASE42_HEAD")" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'posting a fresh request intent' "$OUT" \
  && ! grep -q 'is already reviewed' "$OUT" \
  && [ -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: an older live review must not shadow a consumed request" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 42f (PR #755 review, round 10): the mirror of 42e — a LIVE
# post-trigger answer plus a dismissed post-trigger review on the same head.
# The request WAS answered; the dismissal of a sibling must not consume it,
# or a plain rerun spends a full review cycle for nothing.
echo "==> Case 42f: a live post-trigger answer shields the request from consumption"
OUT="$TEST_DIR/case42f.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE42_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE42_RECORDS" \
  GH_HEAD_REVIEWS="$(printf 'chatgpt-codex-connector[bot]\t%s\tCOMMENTED\t2026-08-01T00:00:09Z\nchatgpt-codex-connector[bot]\t%s\tDISMISSED\t2026-08-01T00:00:07Z' "$CASE42_HEAD" "$CASE42_HEAD")" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'is already reviewed' "$OUT" \
  && ! grep -q 'posting a fresh request intent' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: a live post-trigger answer must prevent dismissal consumption" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Cases 45a/45b (#760): the review-round budget. Three spent trusted rounds on
# a PR mean the fourth request is refused — past a small number of rounds,
# findings historically stop being defects in the diff (#706 closed after 6;
# #755 spent 7 on a 60-line core). Which refusal depends on the head (#775):
# a head WITHOUT durable request evidence cannot take the merge-if-answered
# exit — merge-pr.sh refuses evidence-less heads and points back at
# open-pr.sh, so recommending it names an unavailable remedy and costs a full
# round-trip to discover the bounce. That refusal must name the override with
# an honest pre-filled reason instead. The override spends a round
# deliberately, with the reason recorded in the PR-visible request comment.
echo "==> Case 45a: past budget without head request evidence names the deadlock (#775)"
OUT="$TEST_DIR/case45a.out"
RC=0
reset_open_pr_logs
CASE45_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
CASE45_BASE_SHA="$(git -C "$REPO_DIR" rev-parse main)"
CASE45_REVIEWS="$(printf 'chatgpt-codex-connector[bot]\tstale-head-1\tCOMMENTED\t2026-08-01T00:00:01Z\nchatgpt-codex-connector[bot]\tstale-head-2\tCOMMENTED\t2026-08-01T01:00:01Z\nchatgpt-codex-connector[bot]\tstale-head-3\tDISMISSED\t2026-08-01T02:00:01Z')"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE45_HEAD" \
  GH_HEAD_REVIEWS="$CASE45_REVIEWS" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'review round(s); the budget is 3 (#760)' "$OUT" \
  && grep -q 'budget/evidence deadlock' "$OUT" \
  && grep -q "'merge if answered' is NOT available" "$OUT" \
  && grep -q -- '--round-budget-override' "$OUT" \
  && grep -q 'head advanced by rebase/fix after budget spent; prior rounds reviewed the substance' "$OUT" \
  && ! grep -q 'run: bash scripts/merge-pr.sh' "$OUT" \
  && ! grep -q 'Merge if answered' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: an evidence-less head past budget must name the deadlock and the override, not the merge-pr bounce" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 45e (#775): the deadlock refusal is scoped to evidence-less heads. A
# head WITH durable request evidence and an answered review keeps the original
# exits — merge-if-answered genuinely is available there, so the refusal must
# keep recommending it. --fresh-review is the only route to the budget gate
# with intact evidence.
echo "==> Case 45e: past budget with head request evidence keeps the merge exit"
OUT="$TEST_DIR/case45e.out"
RC=0
reset_open_pr_logs
CASE45E_RECORDS="$(printf 'touchstone/review-request-intent\t2026-08-01T00:00:00Z\thenrymodisett\tpr=777 base=%s\ntouchstone/review-request-complete\t2026-08-01T00:00:05Z\thenrymodisett\tpr=777 base=%s intent=2026-08-01T00:00:00Z trigger=2026-08-01T00:00:05Z' \
  "$CASE45_BASE_SHA" "$CASE45_BASE_SHA")"
CASE45E_REVIEWS="$(printf 'chatgpt-codex-connector[bot]\tstale-head-1\tCOMMENTED\t2026-08-01T00:00:01Z\nchatgpt-codex-connector[bot]\tstale-head-2\tCOMMENTED\t2026-08-01T01:00:01Z\nchatgpt-codex-connector[bot]\t%s\tCOMMENTED\t2026-08-01T02:00:01Z' "$CASE45_HEAD")"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE45_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE45E_RECORDS" \
  GH_HEAD_REVIEWS="$CASE45E_REVIEWS" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr --fresh-review >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'review round(s); the budget is 3 (#760)' "$OUT" \
  && grep -q 'Merge if answered' "$OUT" \
  && grep -q "run: bash scripts/merge-pr.sh 777" "$OUT" \
  && grep -q 'If the gate REFUSES' "$OUT" \
  && grep -q 'Split the PR' "$OUT" \
  && grep -q 'preserving the corpus' "$OUT" \
  && ! grep -q 'budget/evidence deadlock' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: a head with usable request evidence must keep the merge-if-answered exit" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 45b: the override spends the round with a durable reason"
OUT="$TEST_DIR/case45b.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE45_HEAD" \
  GH_HEAD_REVIEWS="$CASE45_REVIEWS" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr --round-budget-override "post-rebase re-review after base moved" >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'Round budget (3) exceeded deliberately: post-rebase re-review' "$OUT" \
  && grep -q 'Round-budget override: post-rebase re-review' "$TEST_DIR/review-request.log"; then
  echo "    PASS"
else
  echo "    FAIL: the override must spend the round and record the reason durably" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 45c (PR #765 review): a malformed budget must refuse loudly, not
# silently disable the cap — bash's numeric -ge prints a diagnostic but
# evaluates false inside `if`, which would let every request through.
echo "==> Case 45c: a malformed TOUCHSTONE_REVIEW_ROUND_BUDGET refuses loudly"
OUT="$TEST_DIR/case45c.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE45_HEAD" \
  TOUCHSTONE_REVIEW_ROUND_BUDGET="three" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'TOUCHSTONE_REVIEW_ROUND_BUDGET must be a non-negative integer' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: a non-integer budget must refuse the request explicitly" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 45d (PR #765 review): comment-delivered results ("Reviewed commit:"
# issue comments from a trusted author) are spent rounds — merge-pr.sh
# counts that channel, so a budget reading only /pulls/N/reviews would be
# evadable by channel. Three trusted result comments, zero formal reviews:
# the fourth request is refused.
echo "==> Case 45d: comment-channel review results count toward the budget"
OUT="$TEST_DIR/case45d.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE45_HEAD" \
  GH_RESULT_COMMENT_AUTHORS=$'chatgpt-codex-connector[bot]\nchatgpt-codex-connector[bot]\nchatgpt-codex-connector[bot]' \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'review round(s); the budget is 3 (#760)' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: trusted result comments must spend rounds like formal reviews" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 43: review bound to another commit does not license the new head"
OUT="$TEST_DIR/case43.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE42_HEAD" \
  GH_HEAD_REVIEWS="$(printf 'chatgpt-codex-connector[bot]\t%s' "$CASE42_BASE_SHA")" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && ! grep -q 'is already reviewed' "$OUT" \
  && grep -q 'Requested GitHub Codex review' "$OUT" \
  && grep -q 'issues/777/comments' "$TEST_DIR/review-request.log"; then
  echo "    PASS"
else
  echo "    FAIL: expected a new head to request review despite an old-commit review" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 44: failed review lookup reports itself and falls back to request evidence"
OUT="$TEST_DIR/case44.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE42_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE42_RECORDS" \
  GH_HEAD_REVIEWS_FAIL=1 \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'could not determine whether head' "$OUT" \
  && ! grep -q 'is already reviewed' "$OUT" \
  && grep -q 'review already requested for head' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected lookup failure to be visible and fall back to request evidence" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Cases 46a-46e (#759): a request the reviewer skipped. The observed shape:
# a pushed head gets CI and a durable request record but never a review,
# while the same reviewer serves other PRs — and the recovery gesture the
# guidance implied (an empty commit) draws no review either. Past the stall
# threshold the idempotent skip must say so and name the recovery
# (--fresh-review), which retires the stale request record and re-asks for
# the SAME head without a new commit. The report never fires a request by
# itself, and an answered head is never re-requested.
# ---------------------------------------------------------------------------
echo "==> Case 46a: a stalled unanswered request is reported with the recovery named"
OUT="$TEST_DIR/case46a.out"
RC=0
reset_open_pr_logs
CASE46_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
CASE46_BASE_SHA="$(git -C "$REPO_DIR" rev-parse main)"
# Trigger timestamp far in the past relative to any test run: unanswered and
# well past the default 30-minute threshold.
CASE46_RECORDS="$(printf 'touchstone/review-request-intent\t2026-08-01T00:00:00Z\thenrymodisett\tpr=777 base=%s\ntouchstone/review-request-complete\t2026-08-01T00:00:05Z\thenrymodisett\tpr=777 base=%s intent=2026-08-01T00:00:00Z trigger=2026-08-01T00:00:05Z' \
  "$CASE46_BASE_SHA" "$CASE46_BASE_SHA")"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE46_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE46_RECORDS" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'review already requested for head' "$OUT" \
  && grep -q 'has been unanswered for' "$OUT" \
  && grep -q 'stall threshold of 30 minute(s) (TOUCHSTONE_REVIEW_STALL_MINUTES)' "$OUT" \
  && grep -q -- 'bash scripts/open-pr.sh --fresh-review' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: a stalled request must be reported with --fresh-review named, without firing a request" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 46b: a request inside the threshold is latency, not a stall — the
# report must stay silent so "in flight" is not misread as "skipped".
echo "==> Case 46b: a young unanswered request is not reported as stalled"
OUT="$TEST_DIR/case46b.out"
RC=0
reset_open_pr_logs
CASE46B_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CASE46B_RECORDS="$(printf 'touchstone/review-request-intent\t%s\thenrymodisett\tpr=777 base=%s\ntouchstone/review-request-complete\t%s\thenrymodisett\tpr=777 base=%s intent=%s trigger=%s' \
  "$CASE46B_NOW" "$CASE46_BASE_SHA" "$CASE46B_NOW" "$CASE46_BASE_SHA" "$CASE46B_NOW" "$CASE46B_NOW")"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE46_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE46B_RECORDS" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'review already requested for head' "$OUT" \
  && ! grep -q 'stall threshold' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: an in-flight request must not be reported as stalled" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 46c: the threshold is env-overridable — a huge TOUCHSTONE_REVIEW_STALL_MINUTES
# silences the report on the same stalled fixture.
echo "==> Case 46c: TOUCHSTONE_REVIEW_STALL_MINUTES overrides the stall threshold"
OUT="$TEST_DIR/case46c.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE46_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE46_RECORDS" \
  TOUCHSTONE_REVIEW_STALL_MINUTES=99999999 \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'review already requested for head' "$OUT" \
  && ! grep -q 'stall threshold' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: an overridden threshold must silence the stall report" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 46d: the recovery itself. --fresh-review on the stalled unanswered
# head retires the stale request record — a FRESH intent is posted rather
# than the abandoned 2026-08-01 intent being reused — and the trigger comment
# goes out for the same head with no new commit.
echo "==> Case 46d: --fresh-review retires the stalled request and re-asks the same head"
OUT="$TEST_DIR/case46d.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE46_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE46_RECORDS" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr --fresh-review >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'was never answered (#759)' "$OUT" \
  && grep -q 'retiring the stale request record' "$OUT" \
  && grep -q 'review-request-intent' "$TEST_DIR/review-request.log" \
  && ! grep -q 'intent=2026-08-01T00:00:00Z' "$TEST_DIR/review-request.log" \
  && grep -q 'issues/777/comments' "$TEST_DIR/review-request.log"; then
  echo "    PASS"
else
  echo "    FAIL: stall recovery must retire the stale intent and post a fresh request" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  cat "$TEST_DIR/review-request.log" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 46e: the answer already arrived — the reviewed-head skip holds and no
# stall report or re-request fires, no matter how old the trigger is.
echo "==> Case 46e: an answered head is never reported stalled or re-requested"
OUT="$TEST_DIR/case46e.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE46_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE46_RECORDS" \
  GH_HEAD_REVIEWS="$(printf 'chatgpt-codex-connector[bot]\t%s\tCOMMENTED\t2026-08-01T00:00:09Z' "$CASE46_HEAD")" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'is already reviewed' "$OUT" \
  && ! grep -q 'stall threshold' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: an answered head must not trip the stall path" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 46f (#759, pre-PR verifier finding): a trusted "Reviewed commit:"
# ISSUE COMMENT naming this head IS the reviewer's answer — clean results
# normally arrive on this channel — so the stall report must not declare the
# head unanswered no matter how old the trigger is.
echo "==> Case 46f: a comment-channel answer suppresses the stall report"
OUT="$TEST_DIR/case46f.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE46_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE46_RECORDS" \
  GH_RESULT_COMMENT_AUTHORS="$(printf 'chatgpt-codex-connector[bot]\t%.10s\t2026-08-01T02:00:00Z\tclean' "$CASE46_HEAD")" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'review already requested for head' "$OUT" \
  && ! grep -q 'unanswered for' "$OUT" \
  && ! grep -q -- '--fresh-review' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: a head answered on the comment channel must not be reported stalled" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 46g: --fresh-review on that comment-answered head must take the
# "despite existing evidence" branch, not retire a request that WAS answered.
echo "==> Case 46g: fresh-review on a comment-answered head is not stall retirement"
OUT="$TEST_DIR/case46g.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE46_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE46_RECORDS" \
  GH_RESULT_COMMENT_AUTHORS="$(printf 'chatgpt-codex-connector[bot]\t%.10s\t2026-08-01T02:00:00Z\tclean' "$CASE46_HEAD")" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr --fresh-review >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'despite existing evidence' "$OUT" \
  && ! grep -q 'never answered (#759)' "$OUT" \
  && [ -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: fresh-review must not claim a comment-answered request was never answered" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 45f (#775 x #759, pre-PR verifier finding): at the stall x budget
# intersection, the stall report sends the driver to --fresh-review; the
# budget refusal that follows must recognize the head is still unanswered and
# print the deadlock exit (override), not bounce to merge-pr.sh for a head it
# just declared unanswered. One comment round is spent by a stale-sha result;
# two more by stale formal reviews.
# Case 46h (PR #781 review): an answer that PREDATES this request's trigger
# answered an earlier ask — it must not suppress the stall report for the
# newest request.
echo "==> Case 46h: a pre-trigger comment answer does not suppress the stall report"
OUT="$TEST_DIR/case46h.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE46_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE46_RECORDS" \
  GH_RESULT_COMMENT_AUTHORS="$(printf 'chatgpt-codex-connector[bot]\t%.10s\t2026-07-31T00:00:00Z\tclean' "$CASE46_HEAD")" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'unanswered for' "$OUT" \
  && grep -q -- '--fresh-review' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: an answer predating the trigger must not suppress the stall report" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 46i (PR #781 review): a FAILED comment lookup is unknown, not absence.
# Stall classification must suppress with a visible warning instead of
# recommending a recovery that spends a review cycle on incomplete state.
echo "==> Case 46i: comment lookup failure suppresses stall classification loudly"
OUT="$TEST_DIR/case46i.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE46_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE46_RECORDS" \
  GH_RESULT_COMMENTS_FAIL=1 \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'comment-result lookup failed' "$OUT" \
  && ! grep -q 'unanswered for' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: a failed comment lookup must suppress stall classification with a warning" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 45g (PR #781 rounds 2-3): a NON-CLEAN comment answer means the
# reviewer DID answer — whether the merge gate accepts it is the gate's own
# verdict, so the refusal prints the conditional exits (merge if accepted;
# override with the gate's refusal as the reason otherwise), never a
# confident deadlock claim and never an unconditional merge recommendation.
echo "==> Case 45g: a non-clean comment answer at budget gets the conditional exits"
OUT="$TEST_DIR/case45g.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE46_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE46_RECORDS" \
  GH_HEAD_REVIEWS="$(printf 'chatgpt-codex-connector[bot]\tstale-head-1\tCOMMENTED\t2026-08-01T00:00:01Z\nchatgpt-codex-connector[bot]\tstale-head-2\tCOMMENTED\t2026-08-01T01:00:01Z')" \
  GH_RESULT_COMMENT_AUTHORS="$(printf 'chatgpt-codex-connector[bot]\t%.10s\t2026-08-01T02:00:00Z\tnon-clean' "$CASE46_HEAD")" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr --fresh-review >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'Merge if answered' "$OUT" \
  && grep -q 'If the gate REFUSES' "$OUT" \
  && grep -q -- '--round-budget-override' "$OUT" \
  && ! grep -q 'budget/evidence deadlock' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: an answered head must get the conditional exits, not a deadlock claim" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 45h (PR #781 rounds 2-3): a post-trigger COMMENTED formal review is
# an ANSWER; whether it carries mergeable inline threads or is body-only is
# the merge gate's verdict, so the refusal prints the conditional exits.
echo "==> Case 45h: a post-trigger formal answer at budget gets the conditional exits"
OUT="$TEST_DIR/case45h.out"
RC=0
reset_open_pr_logs
CASE45H_REVIEWS="$(printf 'chatgpt-codex-connector[bot]\tstale-head-1\tCOMMENTED\t2026-08-01T00:00:01Z\nchatgpt-codex-connector[bot]\tstale-head-2\tCOMMENTED\t2026-08-01T01:00:01Z\nchatgpt-codex-connector[bot]\t%s\tCOMMENTED\t2026-08-01T02:00:01Z' "$CASE46_HEAD")"
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE46_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE46_RECORDS" \
  GH_HEAD_REVIEWS="$CASE45H_REVIEWS" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr --fresh-review >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'Merge if answered' "$OUT" \
  && grep -q 'If the gate REFUSES' "$OUT" \
  && ! grep -q 'budget/evidence deadlock' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: a formal answer must get the conditional exits, not a deadlock claim" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 46j (PR #781 round 2): a formal review that PREDATES the request
# trigger answered an older ask — the reviewed-head skip must not hide the
# stalled replacement request.
echo "==> Case 46j: a pre-trigger formal review does not hide the stalled request"
OUT="$TEST_DIR/case46j.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE46_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE46_RECORDS" \
  GH_HEAD_REVIEWS="$(printf 'chatgpt-codex-connector[bot]\t%s\tCOMMENTED\t2026-07-31T00:00:00Z' "$CASE46_HEAD")" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && ! grep -q 'is already reviewed' "$OUT" \
  && grep -q 'unanswered for' "$OUT" \
  && grep -q -- '--fresh-review' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: a pre-trigger formal review must not report the head as already reviewed" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 46k (PR #781 override round): a post-trigger comment answer shields
# the request from dismissal consumption — merge-pr.sh ignores the dismissed
# formal review and can accept the comment, so at budget the refusal keeps
# the conditional exits and the idempotent skip does not replace the request.
# Case 46i-b (PR #781 override round 2): the SAME suppression must hold when
# the lookup dies with no diagnostic at all — status, not string emptiness,
# is the tri-state.
echo "==> Case 46i-b: a silent comment-lookup failure still suppresses stall classification"
OUT="$TEST_DIR/case46ib.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE46_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE46_RECORDS" \
  GH_RESULT_COMMENTS_FAIL=silent \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'comment-result lookup failed' "$OUT" \
  && ! grep -q 'unanswered for' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: a silent lookup failure must not read as confirmed absence" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 46k: a comment answer shields the request from dismissal consumption"
OUT="$TEST_DIR/case46k.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE46_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE46_RECORDS" \
  GH_HEAD_REVIEWS="$(printf 'chatgpt-codex-connector[bot]\t%s\tDISMISSED\t2026-08-01T00:00:07Z' "$CASE46_HEAD")" \
  GH_RESULT_COMMENT_AUTHORS="$(printf 'chatgpt-codex-connector[bot]\t%.10s\t2026-08-01T02:00:00Z\tclean' "$CASE46_HEAD")" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && ! grep -q 'posting a fresh request intent' "$OUT" \
  && grep -q 'review already requested for head' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: a comment answer must shield the request from dismissal consumption" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 45f: budget refusal on a stalled unanswered head names the override"
OUT="$TEST_DIR/case45f.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_HEAD_OID="$CASE46_HEAD" \
  GH_REQUEST_STATUS_RECORDS="$CASE46_RECORDS" \
  GH_HEAD_REVIEWS="$(printf 'chatgpt-codex-connector[bot]\tstale-head-1\tCOMMENTED\t2026-08-01T00:00:01Z\nchatgpt-codex-connector[bot]\tstale-head-2\tCOMMENTED\t2026-08-01T01:00:01Z')" \
  GH_RESULT_COMMENT_AUTHORS=$'chatgpt-codex-connector[bot]\tdeadbeef00\t2026-08-01T02:00:00Z\tclean' \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr --fresh-review >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'budget/evidence deadlock' "$OUT" \
  && grep -q -- '--round-budget-override' "$OUT" \
  && ! grep -q 'run: bash scripts/merge-pr.sh' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: the budget refusal must not point a stalled unanswered head at merge-pr" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Cases 21-23: review policy is validated before any publish step, and draft
# coordination never depends on it. Commit a malformed .touchstone-review.toml
# to the trusted base (main) — every final-shipping invocation must now fail
# BEFORE `gh pr create` / `gh pr ready`, while draft invocations still work.
# These run last because they mutate the shared repo's main branch.
# ---------------------------------------------------------------------------
git -C "$REPO_DIR" checkout main >/dev/null 2>&1
printf '[review.pr_triggered]\nrequest_on_push = "sometimes"\n' \
  >"$REPO_DIR/.touchstone-review.toml"
git -C "$REPO_DIR" add .touchstone-review.toml
git -C "$REPO_DIR" commit -m "malformed review policy" >/dev/null 2>&1
git -C "$REPO_DIR" checkout feat/test >/dev/null 2>&1

echo "==> Case 21: malformed policy fails a new ready PR before gh pr create"
OUT="$TEST_DIR/case21.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=0 GH_PR_BODY="Protocol: yes" \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'request_on_push must be true' "$OUT" \
  && [ ! -s "$TEST_DIR/pr-create.log" ] \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected malformed policy to fail before gh pr create" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 22: malformed policy fails draft promotion before push and gh pr ready"
OUT="$TEST_DIR/case22.out"
RC=0
reset_open_pr_logs
GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=true \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'request_on_push must be true' "$OUT" \
  && ! grep -q '\[mock\] git push' "$OUT" \
  && [ ! -s "$TEST_DIR/pr-ready.log" ] \
  && [ ! -s "$TEST_DIR/review-request.log" ] \
  && ! grep -q '\[mock merge-pr.sh\] called' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected malformed policy to fail before push and gh pr ready" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 24: malformed policy fails a ready-PR update before push"
OUT="$TEST_DIR/case24.out"
RC=0
reset_open_pr_logs
GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'request_on_push must be true' "$OUT" \
  && ! grep -q '\[mock\] git push' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ] \
  && ! grep -q '\[mock merge-pr.sh\] called' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected malformed policy to fail before pushing to a ready PR" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 25: unsupported review provider fails a ready-PR update before push"
git -C "$REPO_DIR" checkout main >/dev/null 2>&1
printf '[review.pr_triggered]\nrequest_on_push = true\nprovider = "other"\n' \
  >"$REPO_DIR/.touchstone-review.toml"
git -C "$REPO_DIR" add .touchstone-review.toml
git -C "$REPO_DIR" commit -m "unsupported review provider" >/dev/null 2>&1
git -C "$REPO_DIR" checkout feat/test >/dev/null 2>&1
OUT="$TEST_DIR/case25.out"
RC=0
reset_open_pr_logs
GH_HAS_EXISTING_PR=1 GH_PR_IS_DRAFT=false \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'only supports \[review.pr_triggered\].provider = "github-codex"' "$OUT" \
  && ! grep -q '\[mock\] git push' "$OUT" \
  && [ ! -s "$TEST_DIR/review-request.log" ] \
  && ! grep -q '\[mock merge-pr.sh\] called' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected unsupported provider to fail before pushing to a ready PR" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi
git -C "$REPO_DIR" checkout main >/dev/null 2>&1
printf '[review.pr_triggered]\nrequest_on_push = "sometimes"\n' \
  >"$REPO_DIR/.touchstone-review.toml"
git -C "$REPO_DIR" add .touchstone-review.toml
git -C "$REPO_DIR" commit -m "restore malformed review policy" >/dev/null 2>&1
git -C "$REPO_DIR" checkout feat/test >/dev/null 2>&1

echo "==> Case 23: draft coordination succeeds despite malformed review policy"
OUT="$TEST_DIR/case23.out"
RC=0
reset_open_pr_logs
OPEN_PR_AUTO_MERGE=0 GH_HAS_EXISTING_PR=0 GH_PR_BODY="Missing protocol" \
  run_open_pr --draft >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'Opened as draft; no semantic review was requested' "$OUT" \
  && grep -q -- '--draft' "$TEST_DIR/pr-create.log" \
  && [ ! -s "$TEST_DIR/review-request.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected draft creation to ignore review policy entirely" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Every read of an object from the TRUSTED BASE must disable replacement
# objects. A `refs/replace/<oid>` entry makes cat-file, archive, and show
# transparently serve a substituted object while the displayed OID is unchanged
# — so the extracted merge gate, or the review policy governing it, could be
# attacker-supplied with the reviewed SHA printed beside it. This code exists to
# take authorization out of the PR's control, so it must not read through a
# redirection the PR can add (PR #707 review).
echo "==> Trusted-base object reads disable replacement objects"
unprotected="$(grep -nE '(^|[^_A-Z])git (show|archive|cat-file)' \
  "$TOUCHSTONE_ROOT/scripts/open-pr.sh" \
  | grep -vE 'GIT_NO_REPLACE_OBJECTS' \
  | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
if [ -n "$unprotected" ]; then
  echo "    FAIL: object read without GIT_NO_REPLACE_OBJECTS=1:" >&2
  printf '%s\n' "$unprotected" | sed 's/^/      /' >&2
  ERRORS=$((ERRORS + 1))
else
  echo "    PASS"
fi

# A base gate predating the PR-visible review requirement must be REFUSED, not
# executed. Running it would let the very PR that introduces the review gate
# merge without one — "run the gate from the base" is only a safety property
# while the base's gate is at least as strong as the contract (PR #707 review).
#
# This case drives open-pr.sh for real against such a base, exactly like
# Case 4 does for an absent gate: a base branch whose committed merge-pr.sh
# carries none of the capability markers, with a feature branch stacked on it
# so review admission (base-ancestry) passes and the run reaches the
# authorizer. The refusal must fire BEFORE the legacy gate executes.
echo "==> Case 4c: a legacy base gate without the review requirement is refused"
OUT="$TEST_DIR/case4c.out"
RC=0
reset_open_pr_logs
: >"$TEST_DIR/gate-provenance.log"
CASE4C_RESTORE="$(git -C "$REPO_DIR" branch --show-current)"
git -C "$REPO_DIR" checkout -q -b base/legacy-gate base/no-gate
mkdir -p "$REPO_DIR/scripts" "$REPO_DIR/lib"
cat >"$REPO_DIR/scripts/merge-pr.sh" <<'LEGACYGATE'
#!/usr/bin/env bash
# A gate from before the PR-visible review era: it merges directly, with no
# review wait and no base binding. If this ever runs, the capability check
# has regressed.
printf 'legacy-base-gate\n' >>"${MERGE_STUB_LOG:-/dev/null}"
gh pr merge "$1" --squash
LEGACYGATE
chmod +x "$REPO_DIR/scripts/merge-pr.sh"
printf '# legacy base library\n' >"$REPO_DIR/lib/.keep.sh"
git -C "$REPO_DIR" add scripts/merge-pr.sh lib/.keep.sh
git -C "$REPO_DIR" commit -qm "legacy gate" >/dev/null 2>&1
git -C "$REPO_DIR" checkout -q -b feat/legacy-child
printf 'legacy change\n' >>"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -qm "change stacked on legacy base" >/dev/null 2>&1
if grep -q 'require_pr_feedback_clear\|wait_for_pr_triggered_review\|current_pr_base_revision' \
  "$REPO_DIR/scripts/merge-pr.sh" 2>/dev/null; then
  echo "    FAIL: the legacy fixture accidentally carries a capability marker" >&2
  ERRORS=$((ERRORS + 1))
fi
GH_PR_STATE="OPEN" GH_MERGED_AT="" GH_HAS_EXISTING_PR=0 \
  GH_CREATED_PR_BASE="base/legacy-gate" \
  run_open_pr --base base/legacy-gate >"$OUT" 2>&1 || RC=$?
git -C "$REPO_DIR" checkout -q "$CASE4C_RESTORE"

if [ "$RC" != "0" ] \
  && grep -q 'predates the' "$OUT" \
  && grep -q 'PR-visible review requirement' "$OUT" \
  && ! grep -q 'legacy-base-gate' "$TEST_DIR/gate-provenance.log" \
  && grep -q 'ORPHAN RISK: PR opened but not merged' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected nonzero exit + legacy-gate refusal + gate never executed" >&2
  echo "    rc=$RC" >&2
  echo "    provenance: $(tr '\n' ' ' <"$TEST_DIR/gate-provenance.log")" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# A base gate that waits for review but predates PR-base binding
# (current_pr_base_revision, c38e5d6) reviews against origin/<default branch>
# rather than the PR's actual base — a stacked PR would be authorized against
# the wrong diff. It must be refused even though it carries the review-wait
# pair (PR #707 review).
echo "==> Case 4d: a base gate with review wait but no PR-base binding is refused"
OUT="$TEST_DIR/case4d.out"
RC=0
reset_open_pr_logs
: >"$TEST_DIR/gate-provenance.log"
CASE4D_RESTORE="$(git -C "$REPO_DIR" branch --show-current)"
git -C "$REPO_DIR" checkout -q -b base/prebinding-gate base/no-gate
mkdir -p "$REPO_DIR/scripts" "$REPO_DIR/lib"
cat >"$REPO_DIR/scripts/merge-pr.sh" <<'PREBINDINGGATE'
#!/usr/bin/env bash
# A gate from after the review requirement but before PR-base binding: it
# carries the review-wait pair yet always reviews against the default branch.
# If this ever runs, a stacked PR can merge on the wrong diff.
require_pr_feedback_clear() { :; }
wait_for_pr_triggered_review() { :; }
printf 'prebinding-base-gate\n' >>"${MERGE_STUB_LOG:-/dev/null}"
exit 0
PREBINDINGGATE
chmod +x "$REPO_DIR/scripts/merge-pr.sh"
printf '# pre-binding base library\n' >"$REPO_DIR/lib/.keep.sh"
git -C "$REPO_DIR" add scripts/merge-pr.sh lib/.keep.sh
git -C "$REPO_DIR" commit -qm "pre-binding gate" >/dev/null 2>&1
git -C "$REPO_DIR" checkout -q -b feat/prebinding-child
printf 'prebinding change\n' >>"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -qm "change stacked on pre-binding base" >/dev/null 2>&1
if grep -q 'current_pr_base_revision' "$REPO_DIR/scripts/merge-pr.sh" 2>/dev/null; then
  echo "    FAIL: the pre-binding fixture accidentally carries the base-binding marker" >&2
  ERRORS=$((ERRORS + 1))
fi
GH_PR_STATE="OPEN" GH_MERGED_AT="" GH_HAS_EXISTING_PR=0 \
  GH_CREATED_PR_BASE="base/prebinding-gate" \
  run_open_pr --base base/prebinding-gate >"$OUT" 2>&1 || RC=$?
git -C "$REPO_DIR" checkout -q "$CASE4D_RESTORE"

if [ "$RC" != "0" ] \
  && grep -q "lacks 'current_pr_base_revision'" "$OUT" \
  && ! grep -q 'prebinding-base-gate' "$TEST_DIR/gate-provenance.log" \
  && grep -q 'ORPHAN RISK: PR opened but not merged' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected refusal naming current_pr_base_revision + gate never executed" >&2
  echo "    rc=$RC" >&2
  echo "    provenance: $(tr '\n' ' ' <"$TEST_DIR/gate-provenance.log")" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# The authorizer must be extracted at the exact base OID the review request
# was validated against, not at whatever origin/<base> is cached as by
# extraction time. refs/remotes/origin/<base> is shared mutable state any
# concurrent process can refresh; if the base advances between validation and
# extraction (a stacked parent landing, a concurrent merge), following the
# ref would run a gate from a commit the review admission never saw
# (PR #707 review). The git wrapper simulates the concurrent fetch by
# advancing the remote-tracking ref right after the base-ancestry check — the
# last git read of the validation.
echo "==> Case 4e: gate extraction binds to the validated base OID, not the moved ref"
OUT="$TEST_DIR/case4e.out"
RC=0
reset_open_pr_logs
: >"$TEST_DIR/gate-provenance.log"
CASE4E_RESTORE="$(git -C "$REPO_DIR" branch --show-current)"
git -C "$REPO_DIR" checkout -q -b base/toctou-gate base/no-gate
mkdir -p "$REPO_DIR/scripts" "$REPO_DIR/lib"
cat >"$REPO_DIR/scripts/merge-pr.sh" <<'VALIDATEDGATE'
#!/usr/bin/env bash
# The base gate at the revision review admission validated. Capability
# markers so the legacy refusal is not what decides this case:
# require_pr_feedback_clear / wait_for_pr_triggered_review /
# current_pr_base_revision.
printf 'validated-gate\n' >>"${MERGE_STUB_LOG:-/dev/null}"
exec bash "${MERGE_STUB_DELEGATE:?merge stub delegate not set}" "$@"
VALIDATEDGATE
chmod +x "$REPO_DIR/scripts/merge-pr.sh"
printf '# toctou base library\n' >"$REPO_DIR/lib/.keep.sh"
git -C "$REPO_DIR" add scripts/merge-pr.sh lib/.keep.sh
git -C "$REPO_DIR" commit -qm "toctou validated gate" >/dev/null 2>&1
TOCTOU_VALIDATED_OID="$(git -C "$REPO_DIR" rev-parse base/toctou-gate)"
git -C "$REPO_DIR" checkout -q -b feat/toctou-child
printf 'toctou change\n' >>"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -qm "change stacked on toctou base" >/dev/null 2>&1
# The base as it looks AFTER it advanced: same capability markers, different
# gate. If this one runs, extraction followed the moved ref.
git -C "$REPO_DIR" checkout -q -b base/toctou-advanced base/toctou-gate
cat >"$REPO_DIR/scripts/merge-pr.sh" <<'ADVANCEDGATE'
#!/usr/bin/env bash
# A base gate that landed after review admission was validated. Capability
# markers so the capability check accepts it:
# require_pr_feedback_clear / wait_for_pr_triggered_review /
# current_pr_base_revision.
printf 'advanced-gate\n' >>"${MERGE_STUB_LOG:-/dev/null}"
exec bash "${MERGE_STUB_DELEGATE:?merge stub delegate not set}" "$@"
ADVANCEDGATE
git -C "$REPO_DIR" add scripts/merge-pr.sh
git -C "$REPO_DIR" commit -qm "toctou advanced gate" >/dev/null 2>&1
TOCTOU_ADVANCED_OID="$(git -C "$REPO_DIR" rev-parse base/toctou-advanced)"
git -C "$REPO_DIR" checkout -q feat/toctou-child
GH_PR_STATE="MERGED" GH_MERGED_AT="2026-08-11T00:00:00Z" GH_HAS_EXISTING_PR=0 \
  GH_CREATED_PR_BASE="base/toctou-gate" \
  GIT_ADVANCE_REF_AFTER_MERGE_BASE="refs/remotes/origin/base/toctou-gate" \
  GIT_ADVANCE_REF_TO="$TOCTOU_ADVANCED_OID" \
  run_open_pr --base base/toctou-gate >"$OUT" 2>&1 || RC=$?
git -C "$REPO_DIR" checkout -q "$CASE4E_RESTORE"

if [ "$RC" = "0" ] \
  && grep -q 'validated-gate' "$TEST_DIR/gate-provenance.log" \
  && ! grep -q 'advanced-gate' "$TEST_DIR/gate-provenance.log" \
  && grep -q "Merge gate materialized from base/toctou-gate @ ${TOCTOU_VALIDATED_OID:0:12}" "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected the gate from the VALIDATED base OID, not the moved ref" >&2
  echo "    rc=$RC" >&2
  echo "    validated: $TOCTOU_VALIDATED_OID" >&2
  echo "    advanced:  $TOCTOU_ADVANCED_OID" >&2
  echo "    provenance: $(tr '\n' ' ' <"$TEST_DIR/gate-provenance.log")" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 47 (PR #781 review, P1): the LIVE comment-result jq program must
# compile and classify with real jq — the stub serves post-filter rows, so
# without this the filter itself is never executed and an uncompilable
# program silently zeroes comment rounds and answers.
# ---------------------------------------------------------------------------
echo "==> Case 47: the live comment-result jq filter compiles and classifies"
CASE47_JQ_LINE="$(grep "^  OPEN_PR_RESULT_COMMENT_JQ=" "$SCRIPT_DIR/open-pr.sh" || true)"
if [ -z "$CASE47_JQ_LINE" ]; then
  echo "    FAIL: could not extract OPEN_PR_RESULT_COMMENT_JQ from open-pr.sh (extraction guard)" >&2
  ERRORS=$((ERRORS + 1))
else
  eval "${CASE47_JQ_LINE#  }"
  CASE47_JSON='[
    {"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-08-01T02:00:00Z","body":"Codex Review: Didn'"'"'t find any major issues. Bravo.\n\n**Reviewed commit:** `abc1234de0`"},
    {"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-08-01T03:00:00Z","body":"### Codex Review\n\nHere are findings.\n\n**Reviewed commit:** `abc1234de0`"},
    {"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-08-01T04:00:00Z","body":"Reviewed commit: coming soon, no sha here"},
    {"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-08-01T05:30:00Z","body":"You have reached your Codex usage limits for security reviews."},
    {"user":{"login":"someone"},"created_at":"2026-08-01T05:00:00Z","body":"unrelated"}
  ]'
  CASE47_OUT="$(printf '%s' "$CASE47_JSON" | jq -r "$OPEN_PR_RESULT_COMMENT_JQ" 2>&1)" || CASE47_OUT="JQ_FAILED: $CASE47_OUT"
  if printf '%s' "$CASE47_OUT" | grep -q '^JQ_FAILED'; then
    echo "    FAIL: the live jq program does not run: $CASE47_OUT" >&2
    ERRORS=$((ERRORS + 1))
  elif printf '%s\n' "$CASE47_OUT" | grep -q $'^chatgpt-codex-connector\[bot\]\tabc1234de0\t2026-08-01T02:00:00Z\tclean$' \
    && printf '%s\n' "$CASE47_OUT" | grep -q $'^chatgpt-codex-connector\[bot\]\tabc1234de0\t2026-08-01T03:00:00Z\tnon-clean$' \
    && printf '%s\n' "$CASE47_OUT" | grep -q $'^chatgpt-codex-connector\[bot\]\t\t2026-08-01T04:00:00Z\tnon-clean$' \
    && ! printf '%s\n' "$CASE47_OUT" | grep -q 'usage limits' \
    && [ "$(printf '%s\n' "$CASE47_OUT" | grep -c .)" = "3" ]; then
    echo "    PASS"
  else
    echo "    FAIL: live jq filter misclassified the fixture comments" >&2
    printf '%s\n' "$CASE47_OUT" >&2
    ERRORS=$((ERRORS + 1))
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [ "$ERRORS" = "0" ]; then
  echo "==> PASS: open-pr.sh exit contract holds across orphan-risk paths"
  exit 0
fi
echo "==> FAIL: $ERRORS case(s) regressed" >&2
exit 1
