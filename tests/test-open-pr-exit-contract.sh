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
SCRIPT_DIR="$TEST_DIR/scripts"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$REPO_DIR" "$SCRIPT_DIR" "$FAKE_BIN"

cp "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$SCRIPT_DIR/open-pr.sh"
cp "$TOUCHSTONE_ROOT/scripts/issue-claim-check.sh" "$SCRIPT_DIR/issue-claim-check.sh"
chmod +x "$SCRIPT_DIR/open-pr.sh" "$SCRIPT_DIR/issue-claim-check.sh"

# Real git inside a fresh repo with a feature branch checked out, so the
# branch-name and uncommitted-tree checks all use real behaviour.
git -C "$REPO_DIR" init -b main >/dev/null 2>&1
git -C "$REPO_DIR" config user.name "Touchstone Test"
git -C "$REPO_DIR" config user.email "touchstone@example.com"
printf 'base\n' >"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -m "base commit" >/dev/null 2>&1
git -C "$REPO_DIR" checkout -b feat/test >/dev/null 2>&1
printf 'change\n' >>"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -m "test change" >/dev/null 2>&1

# Mock gh — behaviour controlled by env vars so each scenario reuses one mock.
# GH_PR_STATE   — value returned for `gh pr view --json state,mergedAt`
# GH_MERGED_AT  — mergedAt value returned for `gh pr view --json state,mergedAt`
# GH_HAS_EXISTING_PR — if "1", `gh pr list` returns an existing PR URL
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
      printf 'https://example.test/touchstone/pull/777\tmain\n'
    else
      echo ""
    fi
    ;;
  "pr create")
    # Last positional is the body file flag pair; we only need to emit a URL.
    echo "https://example.test/touchstone/pull/123"
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
    echo "unexpected gh pr view json: $json_fields jq: $jq_expr" >&2
    exit 1
    ;;
  "api user")
    echo "${GH_PR_AUTHOR:-alice}"
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
# When nonzero, simulates "Conductor blocked" or similar review-failure.
cat >"$SCRIPT_DIR/merge-pr.sh" <<'EOF'
#!/usr/bin/env bash
echo "[mock merge-pr.sh] called for PR $1"
exit "${MERGE_PR_EXIT:-0}"
EOF
chmod +x "$SCRIPT_DIR/merge-pr.sh"

# Helper: run open-pr.sh in the test repo with a given mock environment.
# Sets a clean PATH so only the fake gh+git are visible (plus system bins).
run_open_pr() {
  (
    cd "$REPO_DIR"
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
      GH_MERGED_AT="${GH_MERGED_AT:-}" \
      GH_PR_STATE="${GH_PR_STATE:-OPEN}" \
      GH_HAS_EXISTING_PR="${GH_HAS_EXISTING_PR:-0}" \
      GH_PR_BODY="${GH_PR_BODY:-}" \
      GH_PR_AUTHOR="${GH_PR_AUTHOR:-alice}" \
      GH_REQUIRE_REPO_FOR_MERGED_AT="${GH_REQUIRE_REPO_FOR_MERGED_AT:-0}" \
      MERGE_PR_EXIT="${MERGE_PR_EXIT:-0}" \
      bash "$SCRIPT_DIR/open-pr.sh" --auto-merge
  )
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
  && ! grep -q 'ORPHAN RISK' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected exit 0 + verified-merge line + no orphan banner" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# Case 2: merge-pr.sh blocks (review failure / conductor blocked).
# Expect: nonzero exit + ORPHAN RISK banner with PR URL.
# ---------------------------------------------------------------------------
echo "==> Case 2: merge-pr.sh blocks (Conductor blocks review)"
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
GH_PR_STATE="OPEN" GH_MERGED_AT="" GH_HAS_EXISTING_PR=0 GH_PR_BODY="Missing protocol" MERGE_PR_EXIT=0 \
  run_open_pr >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'Running PR body protocol preflight (new PR #123)' "$OUT" \
  && grep -q 'PR body protocol preflight failed for PR #123' "$OUT" \
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
# Case 9: post-merge verification still works after merge-pr.sh has removed
# the current worktree. The real failure mode is that gh can no longer infer
# the repository from cwd; the fix is to use the captured --repo explicitly.
# ---------------------------------------------------------------------------
echo "==> Case 9: post-merge verification uses captured repo context"
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
# Case 10: verify_pr_merged stays sourceable by itself and treats state=MERGED
# as authoritative when mergedAt is briefly empty.
# ---------------------------------------------------------------------------
echo "==> Case 10: extracted verify_pr_merged handles state=MERGED without helpers"
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
# Summary
# ---------------------------------------------------------------------------
if [ "$ERRORS" = "0" ]; then
  echo "==> PASS: open-pr.sh exit contract holds across orphan-risk paths"
  exit 0
fi
echo "==> FAIL: $ERRORS case(s) regressed" >&2
exit 1
