#!/usr/bin/env bash
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-issue-claim-rest.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

FAKE_BIN="$TEST_DIR/bin"
BODY_FILE="$TEST_DIR/body.md"
GH_LOG="$TEST_DIR/gh.log"
mkdir -p "$FAKE_BIN"
printf 'Closes #465\n' >"$BODY_FILE"

cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
if [ "${1:-}" = "api" ] && [ "${2:-}" = "--hostname" ]; then
  shift 3
  set -- api "$@"
fi
case "$*" in
  "repo view --json nameWithOwner --jq .nameWithOwner // empty")
    printf 'autumngarage/touchstone\n'
    ;;
  "repo view --json url --jq .url // empty")
    printf '%s\n' "${FAKE_REPO_URL:-https://github.com/autumngarage/touchstone}"
    ;;
  "api repos/autumngarage/touchstone/pulls/77 --jq .body // \"\"")
    cat "$FAKE_PR_BODY_FILE"
    ;;
  "api repos/autumngarage/touchstone/pulls/77 --jq .user.login // empty")
    printf 'henrymodisett\n'
    ;;
  "api repos/autumngarage/touchstone/issues/465 --jq .state")
    printf 'open\n'
    ;;
  "api repos/autumngarage/touchstone/issues/465 --jq .assignees | map(.login) | join(\"\\n\")")
    printf 'henrymodisett\n'
    ;;
  "pr view"* | "issue view"*)
    echo "higher-level gh reads are not Actions-token-safe" >&2
    exit 90
    ;;
  *)
    echo "unexpected gh invocation: $*" >&2
    exit 91
    ;;
esac
EOF
chmod +x "$FAKE_BIN/gh"

GH_REPO="" GH_HOST="" GITHUB_SERVER_URL="" \
  PATH="$FAKE_BIN:/usr/bin:/bin" GH_LOG="$GH_LOG" FAKE_PR_BODY_FILE="$BODY_FILE" \
  bash "$TOUCHSTONE_ROOT/scripts/issue-claim-check.sh" --pr-number 77 \
  >"$TEST_DIR/output"

if ! grep -q 'All referenced issues are claimed by the PR author.' "$TEST_DIR/output"; then
  echo "FAIL: issue claim check did not accept the REST fixture." >&2
  cat "$TEST_DIR/output" >&2
  cat "$GH_LOG" >&2
  exit 1
fi
grep -q '^api repos/autumngarage/touchstone/pulls/77 ' "$GH_LOG"
grep -q '^api repos/autumngarage/touchstone/issues/465 ' "$GH_LOG"
if grep -Eq '^(pr|issue) view ' "$GH_LOG"; then
  echo "FAIL: PR mode used a higher-level gh read instead of REST." >&2
  exit 1
fi

printf '[skip-claim-check]\n' >"$TEST_DIR/bypass.md"
PATH="$FAKE_BIN:/usr/bin:/bin" GH_LOG="$GH_LOG" GH_REPO="" GH_HOST="" GITHUB_SERVER_URL="" \
  bash "$TOUCHSTONE_ROOT/scripts/issue-claim-check.sh" \
  --body-file "$TEST_DIR/bypass.md" --author alice >"$TEST_DIR/bypass-output"
grep -q 'bypassing issue claim check' "$TEST_DIR/bypass-output"

: >"$GH_LOG"
GH_REPO="github.example.com/autumngarage/touchstone" GH_HOST="" GITHUB_SERVER_URL="" \
  PATH="$FAKE_BIN:/usr/bin:/bin" GH_LOG="$GH_LOG" FAKE_PR_BODY_FILE="$BODY_FILE" \
  bash "$TOUCHSTONE_ROOT/scripts/issue-claim-check.sh" --pr-number 77 \
  >"$TEST_DIR/enterprise-output"
grep -q '^api --hostname github.example.com repos/autumngarage/touchstone/pulls/77 ' "$GH_LOG"
if grep -q 'repos/github.example.com/' "$GH_LOG"; then
  echo "FAIL: host-qualified GH_REPO leaked its hostname into the REST endpoint." >&2
  exit 1
fi

: >"$GH_LOG"
GH_REPO="autumngarage/touchstone" GH_HOST="" GITHUB_SERVER_URL="https://github.example.com" \
  PATH="$FAKE_BIN:/usr/bin:/bin" GH_LOG="$GH_LOG" FAKE_PR_BODY_FILE="$BODY_FILE" \
  bash "$TOUCHSTONE_ROOT/scripts/issue-claim-check.sh" --pr-number 77 \
  >"$TEST_DIR/enterprise-actions-output"
grep -q '^api --hostname github.example.com repos/autumngarage/touchstone/pulls/77 ' "$GH_LOG"

: >"$GH_LOG"
GH_REPO="" GH_HOST="" GITHUB_SERVER_URL="" \
  FAKE_REPO_URL="https://github.example.com/autumngarage/touchstone" \
  PATH="$FAKE_BIN:/usr/bin:/bin" GH_LOG="$GH_LOG" FAKE_PR_BODY_FILE="$BODY_FILE" \
  bash "$TOUCHSTONE_ROOT/scripts/issue-claim-check.sh" --pr-number 77 \
  >"$TEST_DIR/enterprise-checkout-output"
grep -q '^api --hostname github.example.com repos/autumngarage/touchstone/pulls/77 ' "$GH_LOG"

echo "==> PASS: issue claim PR mode uses Actions-token-compatible REST reads"
