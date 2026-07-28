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
TEST_DIR="$(mktemp -d -t touchstone-test-open-pr-linked.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

SCRIPT_DIR="$TEST_DIR/scripts"
FAKE_BIN="$TEST_DIR/bin"
REMOTE_DIR="$TEST_DIR/remote.git"
REPO_DIR="$TEST_DIR/repo"
mkdir -p "$SCRIPT_DIR" "$FAKE_BIN"

cp "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$SCRIPT_DIR/open-pr.sh"
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
        '.body // ""') cat "$FAKE_PR_BODY_FILE" ;;
        '.user.login // empty') echo "alice" ;;
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
    echo ""
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
    echo ""
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

if [ "$ERRORS" = "0" ]; then
  echo "==> PASS: open-pr.sh injects issue-closing keywords and preflights claim ownership"
  exit 0
fi
echo "==> FAIL: $ERRORS case(s) regressed" >&2
exit 1
