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
TEST_DIR="$(mktemp -d -t touchstone-test-open-pr.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

REPO_DIR="$TEST_DIR/repo"
OPEN_PR_WORKTREE_PATH=""
SCRIPT_DIR="$TEST_DIR/scripts"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$REPO_DIR" "$SCRIPT_DIR" "$FAKE_BIN"

cp "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$SCRIPT_DIR/open-pr.sh"
cp "$TOUCHSTONE_ROOT/scripts/issue-claim-check.sh" "$SCRIPT_DIR/issue-claim-check.sh"
mkdir -p "$TEST_DIR/lib"
cp "$TOUCHSTONE_ROOT/lib/events.sh" "$TEST_DIR/lib/events.sh"
cp "$TOUCHSTONE_ROOT/lib/toml.sh" "$TEST_DIR/lib/toml.sh"
chmod +x "$SCRIPT_DIR/open-pr.sh" "$SCRIPT_DIR/issue-claim-check.sh"

# Real git inside a fresh repo with a feature branch checked out, so the
# branch-name and uncommitted-tree checks all use real behaviour.
git -C "$REPO_DIR" init -b main >/dev/null 2>&1
git -C "$REPO_DIR" config user.name "Touchstone Test"
git -C "$REPO_DIR" config user.email "touchstone@example.com"
printf 'base\n' >"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -m "base commit" >/dev/null 2>&1
git -C "$REPO_DIR" remote add origin "$REPO_DIR"
git -C "$REPO_DIR" branch feature/parent
git -C "$REPO_DIR" checkout -b feat/test >/dev/null 2>&1
printf 'change\n' >>"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -m "test change" >/dev/null 2>&1
OPEN_PR_WORKTREE_PATH="$(cd "$REPO_DIR" && pwd -P)"

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
      printf 'https://example.test/touchstone/pull/777\t%s\t%s\t%s\n' \
        "${GH_EXISTING_PR_BASE:-main}" \
        "${GH_PR_HEAD_OID:-existing-pr-head}" \
        "${GH_PR_IS_DRAFT:-false}"
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
    # No prior durable review-request records.
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
REAL_GIT="$(command -v git)"
cat >"$FAKE_BIN/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "push" ]; then
  echo "[mock] git push \$*"
  exit 0
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
      MERGE_PR_EXIT="${MERGE_PR_EXIT:-0}" \
      MERGE_PR_REQUEST_COUNT_FILE="$TEST_DIR/merge-pr-request-count" \
      GH_PR_CREATE_LOG="$TEST_DIR/pr-create.log" \
      GH_PR_READY_LOG="$TEST_DIR/pr-ready.log" \
      GH_REVIEW_REQUEST_LOG="$TEST_DIR/review-request.log" \
      TOUCHSTONE_EVENTS_FILE="$TEST_DIR/open-pr-events.ndjson" \
      bash "$SCRIPT_DIR/open-pr.sh" "$@"
  )
}

reset_open_pr_logs() {
  : >"$TEST_DIR/pr-create.log"
  : >"$TEST_DIR/pr-ready.log"
  : >"$TEST_DIR/review-request.log"
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
  && grep -q "\"event\":\"review_requested\".*\"worktree_path\":\"$OPEN_PR_WORKTREE_PATH\".*\"phase\":\"open-pr\".*\"request_count\":1" \
    "$TEST_DIR/open-pr-events.ndjson" \
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

if [ "$RC" != "0" ] \
  && grep -q 'ORPHAN RISK: PR opened but not merged' "$OUT" \
  && grep -q 'https://example.test/touchstone/pull/123' "$OUT" \
  && grep -q 'gh pr merge 123 --squash --delete-branch' "$OUT" \
  && grep -q 'gh pr close 123' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected nonzero exit + orphan banner + PR URL + recovery hints" >&2
  echo "    rc=$RC" >&2
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
# Case 4: merge-pr.sh missing on disk — script must NOT silently exit 0.
# Earlier behaviour: WARNING + fall through to exit 0 (the orphan trap).
# New behaviour: ERROR + nonzero exit + orphan banner.
# ---------------------------------------------------------------------------
echo "==> Case 4: merge-pr.sh missing on disk"
OUT="$TEST_DIR/case4.out"
RC=0
mv "$SCRIPT_DIR/merge-pr.sh" "$SCRIPT_DIR/merge-pr.sh.hidden"
GH_PR_STATE="OPEN" GH_MERGED_AT="" GH_HAS_EXISTING_PR=0 \
  run_open_pr >"$OUT" 2>&1 || RC=$?
mv "$SCRIPT_DIR/merge-pr.sh.hidden" "$SCRIPT_DIR/merge-pr.sh"

if [ "$RC" != "0" ] \
  && grep -q 'merge-pr.sh not found' "$OUT" \
  && grep -q 'ORPHAN RISK: PR opened but not merged' "$OUT" \
  && grep -q 'https://example.test/touchstone/pull/123' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected nonzero exit + missing-script error + orphan banner" >&2
  echo "    rc=$RC" >&2
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
# Case 17: a new stacked PR explains how to produce child-only history.
# ---------------------------------------------------------------------------
git -C "$REPO_DIR" commit --allow-empty -m $'exercise stacked warning\n\nProtocol: yes' >/dev/null 2>&1
echo "==> Case 17: new stacked PR recovery preserves an independent slice"
OUT="$TEST_DIR/case11.out"
RC=0
GH_PR_STATE="MERGED" GH_MERGED_AT="2026-07-29T12:00:00Z" GH_HAS_EXISTING_PR=0 \
  GH_CREATED_PR_BASE="feature/parent" \
  GH_PR_BODY="Protocol: yes" MERGE_PR_EXIT=0 \
  run_open_pr --base feature/parent >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'rebase/cherry-pick child-only commits onto main' "$OUT" \
  && grep -q 'rerun without --base to open an independent PR' "$OUT" \
  && ! grep -q 'gh pr edit' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected new-stack recovery to require child-only history" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 18: an existing stacked PR must also be retargeted on GitHub.
# ---------------------------------------------------------------------------
echo "==> Case 18: existing stacked PR recovery retargets the PR"
OUT="$TEST_DIR/case12.out"
RC=0
GH_PR_STATE="MERGED" GH_MERGED_AT="2026-07-29T12:10:00Z" \
  GH_HAS_EXISTING_PR=1 GH_EXISTING_PR_BASE="feature/parent" \
  GH_PR_BODY=$'Closes #52\n\nProtocol: yes' MERGE_PR_EXIT=0 \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'rebase/cherry-pick child-only commits onto main' "$OUT" \
  && grep -q 'gh pr edit 777 --base main' "$OUT" \
  && ! grep -q 'rerun without --base to open an independent PR' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected existing-stack recovery to include explicit PR retarget" >&2
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

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [ "$ERRORS" = "0" ]; then
  echo "==> PASS: open-pr.sh exit contract holds across orphan-risk paths"
  exit 0
fi
echo "==> FAIL: $ERRORS case(s) regressed" >&2
exit 1
