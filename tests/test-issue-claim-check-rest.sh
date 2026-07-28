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
case "$*" in
  "repo view --json nameWithOwner --jq .nameWithOwner // empty")
    printf 'autumngarage/touchstone\n'
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

echo "==> PASS: issue claim PR mode uses Actions-token-compatible REST reads"
