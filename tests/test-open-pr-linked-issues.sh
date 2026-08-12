#!/usr/bin/env bash
#
# tests/test-open-pr-linked-issues.sh — guard issue-closing PR body injection.
#
# open-pr.sh should derive linked issues from commit message bodies on the PR
# branch and inject GitHub closing keywords into the PR body before creating
# the PR. The source of truth is the branch commits since the merge-base with
# the target branch; base-branch history must not leak into the new PR body.
#
set -euo pipefail

export GH_REPO="" GH_HOST="" GITHUB_SERVER_URL=""

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=stage-touchstone-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/stage-touchstone-libs.sh"

TEST_DIR="$(mktemp -d -t touchstone-test-open-pr-linked.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

SCRIPT_DIR="$TEST_DIR/scripts"
FAKE_BIN="$TEST_DIR/bin"
REMOTE_DIR="$TEST_DIR/remote.git"
REPO_DIR="$TEST_DIR/repo"
mkdir -p "$SCRIPT_DIR" "$FAKE_BIN"

cp "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$SCRIPT_DIR/open-pr.sh"
stage_touchstone_libs "$TOUCHSTONE_ROOT" "$SCRIPT_DIR"
cp "$TOUCHSTONE_ROOT/scripts/issue-claim-check.sh" "$SCRIPT_DIR/issue-claim-check.sh"
chmod +x "$SCRIPT_DIR/open-pr.sh" "$SCRIPT_DIR/issue-claim-check.sh"

# Fake gh: captures --body-file content so this test can assert on the exact
# PR body that would be sent to GitHub. Git push still talks to a real local
# bare remote so branch/upstream behavior stays realistic.
cat >"$FAKE_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${GH_CALL_LOG:-}" ]; then
  printf '%s\n' "$*" >>"$GH_CALL_LOG"
fi
if [ "${1:-}" = "api" ] && [ "${2:-}" = "--hostname" ]; then
  shift 3
  set -- api "$@"
fi
case "$1 $2" in
  "api user")
    echo "alice"
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
    issue_number="${api_path##*/}"
    if [[ "$api_path" == */pulls/* ]]; then
      case "$jq_expr" in
        '.body // ""')
          # An open PR with no body is the ordinary case; only the cases that
          # assert on a body set FAKE_PR_BODY_FILE.
          if [ -n "${FAKE_PR_BODY_FILE:-}" ]; then
            cat "$FAKE_PR_BODY_FILE"
          else
            echo ""
          fi
          ;;
        '.user.login // empty') echo "alice" ;;
        '[.base.ref, .base.sha] | @tsv')
          printf 'main\t%s\n' "$(git rev-parse main)"
          ;;
        *) echo "unexpected pull REST args: $*" >&2; exit 1 ;;
      esac
      exit 0
    fi
    if [[ "$api_path" == */issues/*/comments ]]; then
      exit 0
    fi
    case "$jq_expr" in
      ".state")
        case "$issue_number" in
          51) echo "closed" ;;
          *) echo "open" ;;
        esac
        ;;
      '.assignees | map(.login) | join("\n")')
        case "$issue_number" in
          42 | 43 | 52 | 465) echo "alice" ;;
          6[0-9]) echo "alice" ;;
          53) echo "bob" ;;
          *) : ;;
        esac
        ;;
      *)
        echo "unexpected gh api args: $*" >&2
        exit 1
        ;;
    esac
    ;;
  "repo view")
    if [ "${FAKE_REPO_RESOLUTION_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    json_fields=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--json" ]; then
        json_fields="$arg"
      fi
      prev="$arg"
    done
    case "$json_fields" in
      nameWithOwner) echo "autumngarage/touchstone" ;;
      url) echo "${FAKE_REPO_URL:-https://github.com/autumngarage/touchstone}" ;;
      *) echo "main" ;;
    esac
    ;;
  "pr list")
    # Default: no PR for this branch, so every case takes the create path.
    # GH_HAS_EXISTING_PR=1 routes a case through the update path instead.
    if [ "${GH_HAS_EXISTING_PR:-0}" = "1" ]; then
      printf 'https://example.test/touchstone/pull/4242\tmain\t%s\tfalse\tfalse\n' \
        "$(git rev-parse HEAD)"
    else
      echo ""
    fi
    ;;
  "pr create")
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--body-file" ]; then
        echo "=== BODY ==="
        cat "$arg"
        printf '\n=== END BODY ===\n'
      fi
      prev="$arg"
    done
    echo "https://example.test/touchstone/pull/4242"
    ;;
  "pr view")
    json_fields=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--json" ]; then
        json_fields="$arg"
      fi
      prev="$arg"
    done
    case "$json_fields" in
      headRefOid) git rev-parse HEAD ;;
      isDraft) echo false ;;
      body)
        if [ -n "${FAKE_PR_BODY_FILE:-}" ]; then
          cat "$FAKE_PR_BODY_FILE"
        else
          echo ""
        fi
        ;;
      state,mergedAt) printf '{"state":"MERGED","mergedAt":"2026-07-29T00:00:02Z"}\n' ;;
      *) echo "unexpected gh pr view args: $*" >&2; exit 1 ;;
    esac
    ;;
  "api --paginate")
    # No prior durable review-request records.
    ;;
  "api -X")
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
  "issue view")
    echo "issue claim check must use REST reads: $*" >&2
    exit 90
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
GHEOF
chmod +x "$FAKE_BIN/gh"

git init --bare "$REMOTE_DIR" >/dev/null 2>&1
git clone "$REMOTE_DIR" "$REPO_DIR" >/dev/null 2>&1
git -C "$REPO_DIR" switch -c main >/dev/null 2>&1
git -C "$REPO_DIR" config user.name "Touchstone Test"
git -C "$REPO_DIR" config user.email "touchstone@example.com"
mkdir -p "$REPO_DIR/.github"
cp "$TOUCHSTONE_ROOT/templates/pull_request_template.md" "$REPO_DIR/.github/pull_request_template.md"
printf 'base\n' >"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add .github/pull_request_template.md file.txt
git -C "$REPO_DIR" commit -m "base commit

Closes #99" >/dev/null 2>&1
git -C "$REPO_DIR" push -u origin main >/dev/null 2>&1

git -C "$REPO_DIR" switch -c feat/issue-close-test >/dev/null 2>&1
printf 'change\n' >>"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -m "test change

Exercise linked issue detection.

Closes #42" >/dev/null 2>&1
printf 'second change\n' >>"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -m "test trailer

Exercise trailer-style linked issue detection.

Refs: #43
Fixes: #42" >/dev/null 2>&1

echo "==> Case 1: commit bodies with closing keywords inject Linked Issues section"
OUT="$TEST_DIR/linked.out"
RC=0
: >"$TEST_DIR/gh-calls.log"
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_CALL_LOG="$TEST_DIR/gh-calls.log" \
    bash "$SCRIPT_DIR/open-pr.sh"
) >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q '^## Linked Issues$' "$OUT" \
  && grep -q '^Closes #42$' "$OUT" \
  && ! grep -q '^Closes #43$' "$OUT" \
  && ! grep -q '^Closes #99$' "$OUT" \
  && [ "$(grep -c '^Closes #42$' "$OUT")" = "1" ] \
  && grep -q '^## Summary$' "$OUT" \
  && grep -q 'pass: @alice is assigned' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected exit 0 + Linked Issues section with Closes #42" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

make_case_branch() {
  local branch="$1"
  local body="$2"
  git -C "$REPO_DIR" switch main >/dev/null 2>&1
  git -C "$REPO_DIR" switch -c "$branch" >/dev/null 2>&1
  printf '%s\n' "$branch" >>"$REPO_DIR/file.txt"
  git -C "$REPO_DIR" add file.txt
  git -C "$REPO_DIR" commit -m "test $branch

$body" >/dev/null 2>&1
}

echo "==> Case 2: unassigned open issue blocks before PR creation"
make_case_branch feat/unassigned-claim-check "Closes #50"
OUT="$TEST_DIR/unassigned.out"
RC=0
: >"$TEST_DIR/gh-calls.log"
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_CALL_LOG="$TEST_DIR/gh-calls.log" \
    bash "$SCRIPT_DIR/open-pr.sh"
) >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'Issue claim check failed' "$OUT" \
  && grep -q 'bash scripts/claim-issue.sh 50' "$OUT" \
  && ! grep -q '^pr create' "$TEST_DIR/gh-calls.log"; then
  echo "    PASS"
else
  echo "    FAIL: expected unassigned issue to block before gh pr create" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  cat "$TEST_DIR/gh-calls.log" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 3: [skip-claim-check] bypasses local claim preflight"
make_case_branch feat/skip-claim-check "Closes #50

[skip-claim-check]"
OUT="$TEST_DIR/skip.out"
RC=0
: >"$TEST_DIR/gh-calls.log"
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_CALL_LOG="$TEST_DIR/gh-calls.log" \
    bash "$SCRIPT_DIR/open-pr.sh"
) >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q '\[skip-claim-check\] token found' "$OUT" \
  && grep -q '^pr create' "$TEST_DIR/gh-calls.log"; then
  echo "    PASS"
else
  echo "    FAIL: expected skip token to allow PR creation" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  cat "$TEST_DIR/gh-calls.log" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 4: closed issue passes local claim preflight"
make_case_branch feat/closed-claim-check "Closes #51"
OUT="$TEST_DIR/closed.out"
RC=0
: >"$TEST_DIR/gh-calls.log"
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_CALL_LOG="$TEST_DIR/gh-calls.log" \
    bash "$SCRIPT_DIR/open-pr.sh"
) >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'issue is closed; skipping' "$OUT" \
  && grep -q '^pr create' "$TEST_DIR/gh-calls.log"; then
  echo "    PASS"
else
  echo "    FAIL: expected closed issue to allow PR creation" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  cat "$TEST_DIR/gh-calls.log" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 5: assigned open issue passes local claim preflight"
make_case_branch feat/assigned-claim-check "Closes #52"
OUT="$TEST_DIR/assigned.out"
RC=0
: >"$TEST_DIR/gh-calls.log"
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_CALL_LOG="$TEST_DIR/gh-calls.log" \
    bash "$SCRIPT_DIR/open-pr.sh"
) >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'pass: @alice is assigned' "$OUT" \
  && grep -q '^pr create' "$TEST_DIR/gh-calls.log"; then
  echo "    PASS"
else
  echo "    FAIL: expected assigned issue to allow PR creation" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  cat "$TEST_DIR/gh-calls.log" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 6: fully-qualified same-repo issue is enforced"
BODY="$TEST_DIR/same-repo-qualified.md"
printf 'Closes outriderintel/outrider#50\n' >"$BODY"
OUT="$TEST_DIR/same-repo-qualified.out"
RC=0
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_REPO="outriderintel/outrider" \
    bash "$SCRIPT_DIR/issue-claim-check.sh" --body-file "$BODY" --author alice
) >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q 'Issue claim check failed' "$OUT" \
  && grep -q 'bash scripts/claim-issue.sh 50' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected fully-qualified same-repo issue to be enforced" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 7: fully-qualified cross-repo issue is skipped"
BODY="$TEST_DIR/cross-repo-qualified.md"
printf 'Closes another-org/other-project#50\n' >"$BODY"
OUT="$TEST_DIR/cross-repo-qualified.out"
RC=0
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_REPO="outriderintel/outrider" \
    bash "$SCRIPT_DIR/issue-claim-check.sh" --body-file "$BODY" --author alice
) >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'Skipping cross-repo reference' "$OUT" \
  && grep -q 'No closing issue references found' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected fully-qualified cross-repo issue to be skipped" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 8: all GitHub closing verbs plus closes-issue are enforced"
BODY="$TEST_DIR/all-closing-verbs.md"
cat >"$BODY" <<'EOF_BODY'
Close #60
Closes #61
Closed #62
Fix #63
Fixes #64
Fixed #65
Resolve #66
Resolves #67
Resolved #68
Closes-issue: #69
EOF_BODY
OUT="$TEST_DIR/all-closing-verbs.out"
RC=0
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_REPO="autumngarage/touchstone" \
    bash "$SCRIPT_DIR/issue-claim-check.sh" --body-file "$BODY" --author alice
) >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q 'All referenced issues are claimed by the PR author.' "$OUT"; then
  missing_issue=false
  for issue in 60 61 62 63 64 65 66 67 68 69; do
    if ! grep -q "==> Checking issue #$issue" "$OUT"; then
      missing_issue=true
    fi
  done
  if [ "$missing_issue" = false ]; then
    echo "    PASS"
  else
    echo "    FAIL: expected all closing verbs to produce issue checks" >&2
    cat "$OUT" >&2
    ERRORS=$((ERRORS + 1))
  fi
else
  echo "    FAIL: expected all closing verbs to pass when assigned" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 9: PR mode uses Actions-token-compatible REST reads"
BODY="$TEST_DIR/pr-rest.md"
printf 'Closes #465\n' >"$BODY"
OUT="$TEST_DIR/pr-rest.out"
: >"$TEST_DIR/gh-calls.log"
GH_REPO="" GH_HOST="" GITHUB_SERVER_URL="" \
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  GH_CALL_LOG="$TEST_DIR/gh-calls.log" FAKE_PR_BODY_FILE="$BODY" \
  bash "$SCRIPT_DIR/issue-claim-check.sh" --pr-number 77 >"$OUT" 2>&1 || ERRORS=$((ERRORS + 1))
if grep -q 'All referenced issues are claimed by the PR author.' "$OUT" \
  && grep -q '^api repos/autumngarage/touchstone/pulls/77 ' "$TEST_DIR/gh-calls.log" \
  && ! grep -Eq '^(pr|issue) view ' "$TEST_DIR/gh-calls.log"; then
  echo "    PASS"
else
  echo "    FAIL: expected PR mode to use REST reads exclusively" >&2
  cat "$OUT" >&2
  cat "$TEST_DIR/gh-calls.log" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 10: claim bypass does not require repository context"
BODY="$TEST_DIR/bypass-outside-repo.md"
printf '[skip-claim-check]\n' >"$BODY"
OUT="$TEST_DIR/bypass-outside-repo.out"
: >"$TEST_DIR/gh-calls.log"
GH_REPO="" GH_HOST="" GITHUB_SERVER_URL="" \
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  GH_CALL_LOG="$TEST_DIR/gh-calls.log" FAKE_REPO_RESOLUTION_FAIL=1 \
  bash "$SCRIPT_DIR/issue-claim-check.sh" --body-file "$BODY" --author alice >"$OUT" 2>&1
if grep -q 'bypassing issue claim check' "$OUT" \
  && ! grep -q '^repo view' "$TEST_DIR/gh-calls.log"; then
  echo "    PASS"
else
  echo "    FAIL: expected bypass before repository resolution" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 11: host-qualified GH_REPO separates host from REST path"
: >"$TEST_DIR/gh-calls.log"
GH_REPO="github.example.com/autumngarage/touchstone" GH_HOST="" GITHUB_SERVER_URL="" \
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  GH_CALL_LOG="$TEST_DIR/gh-calls.log" FAKE_PR_BODY_FILE="$TEST_DIR/pr-rest.md" \
  bash "$SCRIPT_DIR/issue-claim-check.sh" --pr-number 77 >"$TEST_DIR/host-qualified.out" 2>&1
if grep -q '^api --hostname github.example.com repos/autumngarage/touchstone/pulls/77 ' "$TEST_DIR/gh-calls.log" \
  && ! grep -q 'repos/github.example.com/' "$TEST_DIR/gh-calls.log"; then
  echo "    PASS"
else
  echo "    FAIL: expected host-qualified GH_REPO to use --hostname" >&2
  cat "$TEST_DIR/gh-calls.log" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 12: Actions server URL selects the enterprise host"
: >"$TEST_DIR/gh-calls.log"
GH_REPO="autumngarage/touchstone" GH_HOST="" GITHUB_SERVER_URL="https://github.example.com" \
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  GH_CALL_LOG="$TEST_DIR/gh-calls.log" FAKE_PR_BODY_FILE="$TEST_DIR/pr-rest.md" \
  bash "$SCRIPT_DIR/issue-claim-check.sh" --pr-number 77 >"$TEST_DIR/actions-host.out" 2>&1
if grep -q '^api --hostname github.example.com repos/autumngarage/touchstone/pulls/77 ' "$TEST_DIR/gh-calls.log"; then
  echo "    PASS"
else
  echo "    FAIL: expected GITHUB_SERVER_URL to select the API host" >&2
  cat "$TEST_DIR/gh-calls.log" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 13: local enterprise checkout derives host from repository URL"
: >"$TEST_DIR/gh-calls.log"
GH_REPO="" GH_HOST="" GITHUB_SERVER_URL="" \
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  GH_CALL_LOG="$TEST_DIR/gh-calls.log" FAKE_PR_BODY_FILE="$TEST_DIR/pr-rest.md" \
  FAKE_REPO_URL="https://github.example.com/autumngarage/touchstone" \
  bash "$SCRIPT_DIR/issue-claim-check.sh" --pr-number 77 >"$TEST_DIR/local-enterprise.out" 2>&1
if grep -q '^api --hostname github.example.com repos/autumngarage/touchstone/pulls/77 ' "$TEST_DIR/gh-calls.log"; then
  echo "    PASS"
else
  echo "    FAIL: expected repository URL to select the API host" >&2
  cat "$TEST_DIR/gh-calls.log" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 14: enterprise failure comments use the resolved REST host"
BODY="$TEST_DIR/pr-rest-unassigned.md"
printf 'Closes #50\n' >"$BODY"
: >"$TEST_DIR/gh-calls.log"
RC=0
GH_REPO="autumngarage/touchstone" GH_HOST="" GITHUB_SERVER_URL="https://github.example.com" \
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  GH_CALL_LOG="$TEST_DIR/gh-calls.log" FAKE_PR_BODY_FILE="$BODY" \
  bash "$SCRIPT_DIR/issue-claim-check.sh" --pr-number 77 --comment-pr \
  >"$TEST_DIR/enterprise-comment.out" 2>&1 || RC=$?
if [ "$RC" != "0" ] \
  && grep -q '^api --hostname github.example.com repos/autumngarage/touchstone/issues/77/comments ' "$TEST_DIR/gh-calls.log" \
  && grep -q 'remediation comment posted' "$TEST_DIR/enterprise-comment.out"; then
  echo "    PASS"
else
  echo "    FAIL: expected failure comment to use the resolved enterprise host" >&2
  cat "$TEST_DIR/enterprise-comment.out" >&2
  cat "$TEST_DIR/gh-calls.log" >&2
  ERRORS=$((ERRORS + 1))
fi

# The next four cases vary the [issues] declaration the STAGED claim checker
# reads. It resolves policy from its own project root ($TEST_DIR) before $PWD
# — the precedence a CI base checkout depends on — so each case writes the
# declaration there and clears it again; leaving one in place would silently
# retrack every case that follows.
write_staged_tracker_config() {
  printf '%s\n' "$1" >"$TEST_DIR/.touchstone-review.toml"
}

echo "==> Case 15: a tracker declaration this Touchstone cannot honor fails closed"
write_staged_tracker_config '[issues]
tracker = "jira"'
BODY="$TEST_DIR/jira-body.md"
printf 'Closes #50\n' >"$BODY"
OUT="$TEST_DIR/jira.out"
RC=0
: >"$TEST_DIR/gh-calls.log"
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_CALL_LOG="$TEST_DIR/gh-calls.log" \
    bash "$SCRIPT_DIR/issue-claim-check.sh" --body-file "$BODY" --author alice
) >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "2" ] \
  && grep -q "unknown issue tracker 'jira'" "$OUT" \
  && ! grep -q 'api repos/' "$TEST_DIR/gh-calls.log"; then
  echo "    PASS"
else
  echo "    FAIL: expected an unhonorable declaration to fail before any transport runs" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 16: a non-GitHub tracker reports its references and verifies nothing"
write_staged_tracker_config '[issues]
tracker = "linear"
key_prefix = "CON"'
BODY="$TEST_DIR/linear-body.md"
printf 'Some prose.\n\nFixes CON-42\nfixes con-42\n' >"$BODY"
OUT="$TEST_DIR/linear-body.out"
RC=0
: >"$TEST_DIR/gh-calls.log"
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_CALL_LOG="$TEST_DIR/gh-calls.log" \
    bash "$SCRIPT_DIR/issue-claim-check.sh" --body-file "$BODY" --author alice
) >"$OUT" 2>&1 || RC=$?

# Exit 3, never 0: references were found and NOTHING was verified, so callers
# (open-pr, the CI workflow, merge-pr's substitution) each decide in the open
# what an unverifiable claim means rather than reading a green check.
if [ "$RC" = "3" ] \
  && grep -q 'has no claim-verification transport' "$OUT" \
  && grep -q 'referenced: CON-42' "$OUT" \
  && [ "$(grep -c 'referenced: CON-42' "$OUT")" = "1" ] \
  && grep -q 'Exit 3 (unverifiable): this check enforced nothing for those references.' "$OUT" \
  && [ ! -s "$TEST_DIR/gh-calls.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected an unverifiable tracker to report refs, dedupe them, and skip gh" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  cat "$TEST_DIR/gh-calls.log" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 17: GitHub closing syntax under another tracker is refused, not ignored"
# Regression for the #743 review: a commit trailer such as `Closes-issue: #50`
# survives into the PR body of a Linear project, and GitHub closes issue #50
# on merge whatever the project declares. Reporting "no closing issue
# references found" here was a clean preflight in front of a live auto-close.
BODY="$TEST_DIR/linear-github-syntax.md"
printf 'Fixes CON-42\n\nCloses-issue: #50\n' >"$BODY"
OUT="$TEST_DIR/linear-github-syntax.out"
RC=0
: >"$TEST_DIR/gh-calls.log"
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_CALL_LOG="$TEST_DIR/gh-calls.log" \
    bash "$SCRIPT_DIR/issue-claim-check.sh" --body-file "$BODY" --author alice
) >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "1" ] \
  && grep -q "this PR body closes GitHub issues, but this project's issues live in linear" "$OUT" \
  && grep -q 'Closes-issue: #50' "$OUT" \
  && grep -q 'Fixes CON-123' "$OUT" \
  && ! grep -q 'No closing issue references found' "$OUT" \
  && [ ! -s "$TEST_DIR/gh-calls.log" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected wrong-tracker closing syntax to be refused with a rewrite remedy" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 18: an explicit github declaration keeps the enforcing adapter"
write_staged_tracker_config '[issues]
tracker = "github"'
BODY="$TEST_DIR/declared-github.md"
printf 'Closes #50\n' >"$BODY"
OUT="$TEST_DIR/declared-github.out"
RC=0
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$SCRIPT_DIR/issue-claim-check.sh" --body-file "$BODY" --author alice
) >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "1" ] \
  && grep -q 'Issue claim check failed' "$OUT" \
  && grep -q 'bash scripts/claim-issue.sh 50' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected a declared github tracker to enforce assignment" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi
rm -f "$TEST_DIR/.touchstone-review.toml"

echo "==> Case 19: the CI backstop decides what an unverifiable check means"
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

STEP_ERRORS=0
if [ ! -s "$STEP_SCRIPT" ]; then
  echo "    could not extract the claim-check workflow step from $WORKFLOW" >&2
  STEP_ERRORS=$((STEP_ERRORS + 1))
fi
while read -r helper_rc expected_rc notice; do
  [ -n "$helper_rc" ] || continue
  RC=0
  run_workflow_step "$helper_rc" "$TEST_DIR/step-$helper_rc.out" || RC=$?
  if [ "$RC" != "$expected_rc" ]; then
    echo "    helper exit $helper_rc: expected step rc $expected_rc, got $RC" >&2
    STEP_ERRORS=$((STEP_ERRORS + 1))
  fi
  if [ "$notice" = "notice" ]; then
    grep -q '::notice::Claim ownership was NOT verified' "$TEST_DIR/step-$helper_rc.out" || {
      echo "    helper exit $helper_rc: expected the not-verified notice" >&2
      STEP_ERRORS=$((STEP_ERRORS + 1))
    }
  elif grep -q '::notice::' "$TEST_DIR/step-$helper_rc.out"; then
    echo "    helper exit $helper_rc: must not print the unverifiable notice" >&2
    STEP_ERRORS=$((STEP_ERRORS + 1))
  fi
  # helper exit, expected step exit, whether the not-verified notice is due.
done <<'STEP_MAPPINGS'
3 0 notice
1 1 silent
0 0 silent
2 2 silent
STEP_MAPPINGS
if [ "$STEP_ERRORS" = "0" ]; then
  echo "    PASS"
else
  echo "    FAIL: the workflow step mismapped the claim-check exit contract" >&2
  ERRORS=$((ERRORS + 1))
fi

# The remaining cases declare a non-GitHub tracker in the repository itself,
# so they must stay LAST: every case above reads the same checkout and expects
# GitHub semantics.
echo "==> Case 20: an unverifiable tracker reports, and does not block, open-pr"
git -C "$REPO_DIR" switch main >/dev/null 2>&1
printf '[issues]\ntracker = "linear"\nkey_prefix = "CON"\n' >"$REPO_DIR/.touchstone-review.toml"
git -C "$REPO_DIR" add .touchstone-review.toml
git -C "$REPO_DIR" commit -m "declare the linear tracker" >/dev/null 2>&1
git -C "$REPO_DIR" push origin main >/dev/null 2>&1
make_case_branch feat/linear-claim-check "Fixes CON-9"
OUT="$TEST_DIR/linear-claim-check.out"
RC=0
: >"$TEST_DIR/gh-calls.log"
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_CALL_LOG="$TEST_DIR/gh-calls.log" \
    bash "$SCRIPT_DIR/open-pr.sh"
) >"$OUT" 2>&1 || RC=$?

# Exit 3 from the claim check is "found references, verified nothing". open-pr
# must neither die on it (it is not a failure) nor swallow it (it is not a
# pass): it ships, and says out loud that nothing was verified.
if [ "$RC" = "0" ] \
  && grep -q "Tracker 'linear' has no claim-verification transport" "$OUT" \
  && grep -q 'referenced: CON-9' "$OUT" \
  && grep -q 'Claim ownership was NOT verified' "$OUT" \
  && ! grep -q 'pass: @alice is assigned' "$OUT" \
  && grep -q '^pr create' "$TEST_DIR/gh-calls.log"; then
  echo "    PASS"
else
  echo "    FAIL: expected an unverifiable tracker to ship with an explicit not-verified notice" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  cat "$TEST_DIR/gh-calls.log" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 21: a GitHub closing trailer under another tracker blocks the PR"
# Regression for the #743 review, second channel: `gh pr merge --squash`
# carries the branch's commit messages into the default branch when no merge
# body is supplied, so GitHub auto-closes #50 from the trailer alone. Before
# the fix this branch shipped, and open-pr additionally injected `Closes #50`
# into the PR body while the claim preflight reported nothing to enforce.
make_case_branch feat/linear-github-trailer "Closes-issue: #50"
OUT="$TEST_DIR/linear-github-trailer.out"
RC=0
: >"$TEST_DIR/gh-calls.log"
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_CALL_LOG="$TEST_DIR/gh-calls.log" \
    bash "$SCRIPT_DIR/open-pr.sh"
) >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] \
  && grep -q "commits on this branch close GitHub issues, but this project's issues live in linear" "$OUT" \
  && grep -q '^         #50$' "$OUT" \
  && grep -q 'Fixes CON-123' "$OUT" \
  && ! grep -q '^Closes #50$' "$OUT" \
  && ! grep -q '^pr create' "$TEST_DIR/gh-calls.log"; then
  echo "    PASS"
else
  echo "    FAIL: expected a wrong-tracker commit trailer to block before gh pr create" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  cat "$TEST_DIR/gh-calls.log" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 22: the documented bypass ships without injecting GitHub syntax"
# The bypass proves the injection itself is gone rather than merely unreached:
# the body still carries the author's own `Closes-issue: #50` line from the
# commit message, and must NOT carry the `Closes #50` line open-pr synthesizes
# for GitHub projects — the line GitHub would act on.
make_case_branch feat/linear-github-trailer-bypass "Closes-issue: #50

[skip-claim-check]"
OUT="$TEST_DIR/linear-github-trailer-bypass.out"
RC=0
: >"$TEST_DIR/gh-calls.log"
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_CALL_LOG="$TEST_DIR/gh-calls.log" \
    bash "$SCRIPT_DIR/open-pr.sh"
) >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q '^pr create' "$TEST_DIR/gh-calls.log" \
  && grep -q '^Closes-issue: #50$' "$OUT" \
  && ! grep -q '^Closes #50$' "$OUT" \
  && ! grep -q '^## Linked Issues$' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected the bypass to ship a body free of injected GitHub closing syntax" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  cat "$TEST_DIR/gh-calls.log" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 23: a wrong-tracker commit trailer blocks an UPDATE to an open PR"
# Regression for the #743 review, round 3. Scanning commit messages only where
# a PR is CREATED left the update path unguarded: the existing-PR branch runs
# the body checker and exits before the create path is ever reached, so a
# later push could add `Closes-issue: #50` to a commit while the unchanged PR
# body still passed, and the squash merge would close GitHub #50 anyway. The
# scan now runs from run_issue_claim_preflight, which BOTH paths call.
make_case_branch feat/linear-existing-pr-trailer "Closes-issue: #50"
OUT="$TEST_DIR/linear-existing-pr-trailer.out"
RC=0
: >"$TEST_DIR/gh-calls.log"
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_CALL_LOG="$TEST_DIR/gh-calls.log" \
    GH_HAS_EXISTING_PR=1 \
    bash "$SCRIPT_DIR/open-pr.sh"
) >"$OUT" 2>&1 || RC=$?

# The first two assertions are what makes this a test of the UPDATE path and
# not a second copy of Case 21: open-pr announced the already-open PR, and the
# scan ran under the existing-PR label. `pr create` never being called is the
# third: nothing here went through the create path.
if [ "$RC" != "0" ] \
  && grep -q '^==> PR already open for feat/linear-existing-pr-trailer' "$OUT" \
  && grep -q '^==> Checking commit messages for GitHub closing references (existing PR #4242) \.\.\.$' "$OUT" \
  && grep -q "commits on this branch close GitHub issues, but this project's issues live in linear" "$OUT" \
  && grep -q '^         #50$' "$OUT" \
  && ! grep -q '^pr create' "$TEST_DIR/gh-calls.log" \
  && ! grep -q 'statuses/' "$TEST_DIR/gh-calls.log"; then
  echo "    PASS"
else
  echo "    FAIL: expected an existing-PR update to be refused before the review request" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  cat "$TEST_DIR/gh-calls.log" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 24: the open PR's own body carries the bypass for that update"
# The bypass has to be readable where it is actually written. On the update
# path the PR body lives on GitHub, not in the commit that carries the
# reference — here the commit message has no token at all and the open PR's
# body has it, which is the only combination that proves the fetch happened.
PR_BODY_WITH_TOKEN="$TEST_DIR/existing-pr-body-bypass.md"
printf 'Deliberate cross-tracker close.\n\n[skip-claim-check]\n' >"$PR_BODY_WITH_TOKEN"
make_case_branch feat/linear-existing-pr-bypass "Closes-issue: #50"
OUT="$TEST_DIR/linear-existing-pr-bypass.out"
RC=0
: >"$TEST_DIR/gh-calls.log"
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_CALL_LOG="$TEST_DIR/gh-calls.log" \
    GH_HAS_EXISTING_PR=1 \
    FAKE_PR_BODY_FILE="$PR_BODY_WITH_TOKEN" \
    bash "$SCRIPT_DIR/open-pr.sh"
) >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q '^==> PR already open for feat/linear-existing-pr-bypass' "$OUT" \
  && grep -q "\[skip-claim-check\] found in PR #4242's body" "$OUT" \
  && ! grep -q "commits on this branch close GitHub issues" "$OUT" \
  && ! grep -q '^pr create' "$TEST_DIR/gh-calls.log"; then
  echo "    PASS"
else
  echo "    FAIL: expected the open PR's body to supply the documented bypass" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  cat "$TEST_DIR/gh-calls.log" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" = "0" ]; then
  echo "==> PASS: open-pr.sh injects issue-closing keywords and preflights claim ownership"
  exit 0
fi
echo "==> FAIL: $ERRORS case(s) regressed" >&2
exit 1
