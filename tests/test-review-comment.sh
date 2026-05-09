#!/usr/bin/env bash
#
# tests/test-review-comment.sh — clean-review PR comment helper and merge wiring.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-review-comment.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "==> Test: format_clean_review_comment produces one-line audit text"
# shellcheck source=../lib/review-comment.sh
source "$TOUCHSTONE_ROOT/lib/review-comment.sh"
COMMENT="$(format_clean_review_comment '{"reviewer":"Conductor","provider":"gemini","model":"gemini-2.5-pro","peer_provider":"none","iterations":1,"mode":"review-only","findings":0}')"
EXPECTED='Conductor review clean - provider: gemini, model: gemini-2.5-pro, peer: none, iterations: 1, mode: review-only, findings: 0'
if [ "$COMMENT" = "$EXPECTED" ]; then
  echo "==> PASS: formatter output matches"
else
  echo "FAIL: formatter output mismatch" >&2
  printf 'expected: %s\nactual:   %s\n' "$EXPECTED" "$COMMENT" >&2
  exit 1
fi

MERGE_DIR="$TEST_DIR/merge"
FAKE_BIN="$MERGE_DIR/bin"
mkdir -p "$MERGE_DIR/scripts" "$MERGE_DIR/lib" "$MERGE_DIR/repo" "$FAKE_BIN"
cp "$TOUCHSTONE_ROOT/scripts/merge-pr.sh" "$MERGE_DIR/scripts/merge-pr.sh"
cp "$TOUCHSTONE_ROOT/lib/preflight.sh" "$MERGE_DIR/lib/preflight.sh"
cp "$TOUCHSTONE_ROOT/lib/review-comment.sh" "$MERGE_DIR/lib/review-comment.sh"
cp "$TOUCHSTONE_ROOT/lib/toml.sh" "$MERGE_DIR/lib/toml.sh"
cat >"$MERGE_DIR/scripts/codex-review.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '{"reviewer":"Conductor","provider":"claude","model":"claude-opus-4-1","peer_provider":"none","iterations":1,"mode":"%s","findings":0,"exit_reason":"clean"}\n' "${CODEX_REVIEW_MODE:-unknown}" > "$CODEX_REVIEW_SUMMARY_FILE"
printf 'review invoked\n' > "$CODEX_REVIEW_LOG"
exit 0
EOF
chmod +x "$MERGE_DIR/scripts/merge-pr.sh" "$MERGE_DIR/scripts/codex-review.sh"

cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "repo view")
    echo "main"
    ;;
  "pr view")
    case "${5:-}" in
      state)
        if [ -f "${GH_MERGED_MARKER:-/dev/null/never}" ]; then echo "MERGED"; else echo "OPEN"; fi
        ;;
      headRefName) echo "feature/test" ;;
      headRefOid) echo "pr-head-oid" ;;
      mergeStateStatus,mergeable) echo "CLEAN MERGEABLE" ;;
      mergedAt) echo "2026-05-07T15:00:00Z" ;;
      mergeCommit) echo "squash-oid" ;;
      *) echo "unexpected gh pr view args: $*" >&2; exit 1 ;;
    esac
    ;;
  "pr checkout")
    echo checked-out > "$GH_CHECKOUT_FILE"
    ;;
  "pr comment")
    if [ "${4:-}" != "--body" ]; then
      echo "unexpected gh pr comment args: $*" >&2
      exit 1
    fi
    printf '%s\n' "${5:-}" >> "$GH_COMMENT_FILE"
    ;;
  "pr merge")
    echo "$7" > "$GH_MERGE_HEAD_FILE"
    [ -n "${GH_MERGED_MARKER:-}" ] && touch "$GH_MERGED_MARKER"
    if [ "${8:-}" = "--body" ]; then
      printf '%s\n' "${9:-}" > "$GH_MERGE_BODY_FILE"
    fi
    ;;
  *) echo "unexpected gh args: $*" >&2; exit 1 ;;
esac
EOF

cat >"$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "rev-parse --show-toplevel") printf '%s\n' "$TEST_REPO_ROOT" ;;
  "rev-parse --abbrev-ref HEAD")
    if [ -f "$GH_CHECKOUT_FILE" ]; then echo "HEAD"; else echo "feature/test"; fi
    ;;
  "rev-parse HEAD")
    if [ -f "$GH_CHECKOUT_FILE" ]; then echo "pr-head-oid"; else echo "stale-local-oid"; fi
    ;;
  "rev-parse feature/test") echo "pr-head-oid" ;;
  "rev-parse --verify --quiet origin/main^{commit}") echo "base-oid" ;;
  "rev-parse --git-path touchstone/reviewer-clean") printf '%s\n' "$TEST_REPO_ROOT/.git/touchstone/reviewer-clean" ;;
  "rev-parse --git-path touchstone/reviewer-findings-history") printf '%s\n' "$TEST_REPO_ROOT/.git/touchstone/reviewer-findings-history" ;;
  "rev-parse --git-path touchstone/squash-map.jsonl") printf '%s\n' "$TEST_REPO_ROOT/.git/touchstone/squash-map.jsonl" ;;
  rev-parse\ --git-path\ touchstone/review-summary-pr-123.json) printf '%s\n' "$TEST_REPO_ROOT/.git/touchstone/review-summary-pr-123.json" ;;
  "fetch origin +refs/heads/main:refs/remotes/origin/main") echo fetched ;;
  "cat-file -e pr-head-oid^{commit}") ;;
  "merge-base origin/main pr-head-oid") echo "base-oid" ;;
  "status --porcelain") ;;
  "diff --name-only origin/main...HEAD") ;;
  "diff --name-only --cached") ;;
  "diff --name-only") ;;
  "ls-files") ;;
  "worktree list --porcelain") ;;
  "checkout main") echo main > "$GIT_CHECKOUT_MAIN_FILE" ;;
  "pull --rebase") ;;
  "show-ref --verify --quiet refs/heads/feature/test") ;;
  "branch -D feature/test") ;;
  *) echo "unexpected git args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/git"

reset_fixture() {
  rm -f "$TEST_DIR"/comments "$TEST_DIR"/merge-head "$TEST_DIR"/merge-body \
    "$TEST_DIR"/review.log "$TEST_DIR"/merged "$TEST_DIR"/checkout "$TEST_DIR"/git-checkout-main
  rm -rf "$MERGE_DIR/repo/.git"
  mkdir -p "$MERGE_DIR/repo/.git"
}

run_merge() {
  local output_file="$1"
  shift
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    TEST_REPO_ROOT="$MERGE_DIR/repo" \
    GH_COMMENT_FILE="$TEST_DIR/comments" \
    GH_MERGE_HEAD_FILE="$TEST_DIR/merge-head" \
    GH_MERGE_BODY_FILE="$TEST_DIR/merge-body" \
    GH_MERGED_MARKER="$TEST_DIR/merged" \
    GH_CHECKOUT_FILE="$TEST_DIR/checkout" \
    GIT_CHECKOUT_MAIN_FILE="$TEST_DIR/git-checkout-main" \
    CODEX_REVIEW_LOG="$TEST_DIR/review.log" \
    TOUCHSTONE_NO_PREFLIGHT=1 \
    bash "$MERGE_DIR/scripts/merge-pr.sh" "$@" >"$output_file" 2>&1
}

echo "==> Test: clean merge review posts a one-line PR comment"
reset_fixture
printf '[review]\ncomment_on_clean = true\n' >"$MERGE_DIR/repo/.codex-review.toml"
run_merge "$TEST_DIR/merge-clean.txt" 123
if grep -q '^Conductor review clean - provider: claude, model: claude-opus-4-1, peer: none, iterations: 1, mode: fix, findings: 0$' "$TEST_DIR/comments" \
  && grep -q '==> Posted clean-review PR comment\.' "$TEST_DIR/merge-clean.txt"; then
  echo "==> PASS: clean review comment posted"
else
  echo "FAIL: clean review comment was not posted as expected" >&2
  cat "$TEST_DIR/merge-clean.txt" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  exit 1
fi

echo "==> Test: comment_on_clean=false skips clean-review comment"
reset_fixture
printf '[review]\ncomment_on_clean = false\n' >"$MERGE_DIR/repo/.codex-review.toml"
run_merge "$TEST_DIR/merge-disabled.txt" 123
if grep -q 'Clean-review PR comment disabled' "$TEST_DIR/merge-disabled.txt" \
  && [ ! -f "$TEST_DIR/comments" ]; then
  echo "==> PASS: config disables clean-review comment"
else
  echo "FAIL: comment_on_clean=false did not skip comment" >&2
  cat "$TEST_DIR/merge-disabled.txt" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  exit 1
fi

echo "==> Test: bypass path still posts only existing disclosure"
reset_fixture
printf '[review]\ncomment_on_clean = true\n' >"$MERGE_DIR/repo/.codex-review.toml"
mkdir -p "$MERGE_DIR/repo/.git/touchstone/reviewer-clean"
printf 'result=CODEX_REVIEW_CLEAN\nbranch=feature/test\nhead=pr-head-oid\nmerge_base=base-oid\n' >"$MERGE_DIR/repo/.git/touchstone/reviewer-clean/feature_test.clean"
run_merge "$TEST_DIR/merge-bypass.txt" 123 --bypass-with-disclosure="reviewer wedged after clean marker"
if grep -q 'Reviewer bypassed via `--bypass-with-disclosure`. Reason: reviewer wedged after clean marker' "$TEST_DIR/comments" \
  && ! grep -q 'review clean' "$TEST_DIR/comments"; then
  echo "==> PASS: bypass disclosure unchanged and no clean comment posted"
else
  echo "FAIL: bypass disclosure path regressed" >&2
  cat "$TEST_DIR/merge-bypass.txt" >&2
  [ -f "$TEST_DIR/comments" ] && cat "$TEST_DIR/comments" >&2
  exit 1
fi
