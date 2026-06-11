#!/usr/bin/env bash
#
# tests/test-fixloop-findings-comment.sh — persisted fix-loop findings history.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-fixloop-history.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

echo "==> Case 1: codex-review.sh records FIXED and CLEAN iterations"
REVIEW_REPO="$TEST_DIR/review-repo"
FAKE_BIN="$TEST_DIR/bin-review"
mkdir -p "$REVIEW_REPO/lib" "$FAKE_BIN"
cp "$TOUCHSTONE_ROOT/lib/toml.sh" "$REVIEW_REPO/lib/toml.sh"
git -C "$REVIEW_REPO" init -b main >/dev/null 2>&1
git -C "$REVIEW_REPO" config user.name "Touchstone Test"
git -C "$REVIEW_REPO" config user.email "touchstone@example.com"
printf 'base\n' >"$REVIEW_REPO/file.txt"
git -C "$REVIEW_REPO" add file.txt lib/toml.sh
git -C "$REVIEW_REPO" commit -m "base commit" >/dev/null 2>&1
git -C "$REVIEW_REPO" checkout -b feat/fixloop >/dev/null 2>&1
printf 'change\n' >>"$REVIEW_REPO/file.txt"
git -C "$REVIEW_REPO" add file.txt
git -C "$REVIEW_REPO" commit -m "feature change" >/dev/null 2>&1

cat >"$REVIEW_REPO/.codex-review.toml" <<'EOF'
[codex_review]
safe_by_default = true
cache_clean_reviews = false
max_iterations = 2
on_error = "fail-closed"
EOF
git -C "$REVIEW_REPO" add .codex-review.toml
git -C "$REVIEW_REPO" commit -m "configure review hook" >/dev/null 2>&1

cat >"$FAKE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  doctor)
    printf '{"configured":true}\n'
    ;;
  review)
    cat >/dev/null
    printf '[conductor] auto (prefer=best, effort=max) -> codex (tier: frontier)\n' >&2
    if grep -q 'auto-fixed missing review artifact' file.txt; then
      printf 'CODEX_REVIEW_CLEAN\n'
    else
      printf -- '- missing review artifact for auto-fixed finding\n'
      printf 'CODEX_REVIEW_BLOCKED\n'
    fi
    ;;
  exec)
    cat >/dev/null
    count_file="$CONDUCTOR_COUNT_FILE"
    count=0
    [ -f "$count_file" ] && count="$(cat "$count_file")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    if [ "$count" -eq 1 ]; then
      printf 'auto-fixed missing review artifact\n' >> file.txt
      printf -- '- missing review artifact for auto-fixed finding\n'
      printf 'CODEX_REVIEW_FIXED\n'
    else
      printf 'CODEX_REVIEW_CLEAN\n'
    fi
    ;;
  *)
    echo "unexpected conductor args: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/conductor"

OUT="$TEST_DIR/review.out"
(
  cd "$REVIEW_REPO"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CONDUCTOR_COUNT_FILE="$TEST_DIR/conductor-count" \
    TOUCHSTONE_REVIEW_LOG=/dev/null \
    CODEX_REVIEW_FORCE=1 \
    CODEX_REVIEW_BASE=main \
    CODEX_REVIEW_MODE=fix \
    bash "$TOUCHSTONE_ROOT/scripts/codex-review.sh"
) >"$OUT" 2>&1 || {
  echo "    FAIL: codex-review.sh fixture failed" >&2
  cat "$OUT" >&2
  exit 1
}

HISTORY_FILE="$REVIEW_REPO/.git/touchstone/reviewer-findings-history/feat_fixloop.jsonl"
if [ -f "$HISTORY_FILE" ] \
  && grep -q '"result":"CODEX_REVIEW_FIXED"' "$HISTORY_FILE" \
  && grep -q '"result":"CODEX_REVIEW_CLEAN"' "$HISTORY_FILE" \
  && grep -q '"findings":"- missing review artifact for auto-fixed finding"' "$HISTORY_FILE"; then
  echo "    PASS"
else
  echo "    FAIL: findings history did not capture FIXED + CLEAN iterations" >&2
  cat "$OUT" >&2
  [ -f "$HISTORY_FILE" ] && cat "$HISTORY_FILE" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 2: formatter renders collapsed actionable history"
# shellcheck source=../lib/review-comment.sh
source "$TOUCHSTONE_ROOT/lib/review-comment.sh"
COMMENT="$(format_findings_history_comment "$HISTORY_FILE")"
if printf '%s\n' "$COMMENT" | grep -q '^<details>$' \
  && printf '%s\n' "$COMMENT" | grep -q 'Conductor review findings history' \
  && printf '%s\n' "$COMMENT" | grep -q 'CODEX_REVIEW_FIXED' \
  && printf '%s\n' "$COMMENT" | grep -q 'missing review artifact'; then
  echo "    PASS"
else
  echo "    FAIL: collapsed formatter output missing expected history" >&2
  printf '%s\n' "$COMMENT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 3: merge-pr.sh posts findings-history comment after merge"
MERGE_DIR="$TEST_DIR/merge"
MERGE_FAKE_BIN="$TEST_DIR/bin-merge"
mkdir -p "$MERGE_DIR/scripts" "$MERGE_DIR/lib" "$MERGE_DIR/repo/.git/touchstone/reviewer-findings-history" "$MERGE_FAKE_BIN"
cp "$TOUCHSTONE_ROOT/scripts/merge-pr.sh" "$MERGE_DIR/scripts/merge-pr.sh"
cp "$TOUCHSTONE_ROOT/lib/preflight.sh" "$MERGE_DIR/lib/preflight.sh"
cp "$TOUCHSTONE_ROOT/lib/review-comment.sh" "$MERGE_DIR/lib/review-comment.sh"
cp "$TOUCHSTONE_ROOT/lib/toml.sh" "$MERGE_DIR/lib/toml.sh"
chmod +x "$MERGE_DIR/scripts/merge-pr.sh"
cat >"$MERGE_DIR/scripts/codex-review.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '{"reviewer":"Conductor","provider":"claude","model":"claude-opus-4-1","peer_provider":"none","iterations":1,"mode":"review-only","findings":0,"exit_reason":"clean"}\n' > "$CODEX_REVIEW_SUMMARY_FILE"
exit 0
EOF
chmod +x "$MERGE_DIR/scripts/codex-review.sh"
cp "$HISTORY_FILE" "$MERGE_DIR/repo/.git/touchstone/reviewer-findings-history/feature_test.jsonl"
printf '[review]\ncomment_on_clean = true\ncomment_findings_history = true\n' >"$MERGE_DIR/repo/.codex-review.toml"

cat >"$MERGE_FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "repo view")
    json_fields=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--json" ]; then
        json_fields="$arg"
      fi
      prev="$arg"
    done
    case "$json_fields" in
      defaultBranchRef) echo "main" ;;
      nameWithOwner) echo "example/touchstone" ;;
      *) echo "unexpected gh repo view json: $json_fields" >&2; exit 1 ;;
    esac
    ;;
  "pr view")
    case "${5:-}" in
      state)
        if [ -f "${GH_MERGED_MARKER:-/dev/null/never}" ]; then echo "MERGED"; else echo "OPEN"; fi
        ;;
      headRefName) echo "feature/test" ;;
      headRefOid) echo "pr-head-oid" ;;
      isDraft) echo "false" ;;
      reviewDecision) echo "" ;;
      mergeStateStatus,mergeable) echo "CLEAN MERGEABLE" ;;
      mergedAt) echo "2026-05-07T15:00:00Z" ;;
      mergeCommit) echo "squash-oid" ;;
      *) echo "unexpected gh pr view args: $*" >&2; exit 1 ;;
    esac
    ;;
  "api graphql")
    echo ""
    ;;
  "pr checkout")
    echo checked-out > "$GH_CHECKOUT_FILE"
    ;;
  "pr comment")
    if [ "${4:-}" != "--body" ]; then
      echo "unexpected gh pr comment args: $*" >&2
      exit 1
    fi
    printf '%s\n---COMMENT---\n' "${5:-}" >> "$GH_COMMENT_FILE"
    ;;
  "pr merge")
    [ -n "${GH_MERGED_MARKER:-}" ] && touch "$GH_MERGED_MARKER"
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
EOF

cat >"$MERGE_FAKE_BIN/git" <<'EOF'
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
  "fetch origin +refs/heads/main:refs/remotes/origin/main") ;;
  "cat-file -e pr-head-oid^{commit}") ;;
  "merge-base origin/main pr-head-oid") echo "base-oid" ;;
  "status --porcelain") ;;
  "diff --name-only origin/main...HEAD") ;;
  "diff --name-only --cached") ;;
  "diff --name-only") ;;
  "ls-files") ;;
  "worktree list --porcelain") ;;
  "checkout main") ;;
  "pull --rebase") ;;
  "show-ref --verify --quiet refs/heads/feature/test") ;;
  "branch -D feature/test") ;;
  *) echo "unexpected git args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$MERGE_FAKE_BIN/gh" "$MERGE_FAKE_BIN/git"

MERGE_OUT="$TEST_DIR/merge.out"
PATH="$MERGE_FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  TEST_REPO_ROOT="$MERGE_DIR/repo" \
  GH_COMMENT_FILE="$TEST_DIR/merge-comments" \
  GH_MERGED_MARKER="$TEST_DIR/merged" \
  GH_CHECKOUT_FILE="$TEST_DIR/checkout" \
  TOUCHSTONE_NO_PREFLIGHT=1 \
  bash "$MERGE_DIR/scripts/merge-pr.sh" 123 >"$MERGE_OUT" 2>&1

if grep -q 'Posted findings-history PR comment' "$MERGE_OUT" \
  && grep -q '<details>' "$TEST_DIR/merge-comments" \
  && grep -q 'CODEX_REVIEW_FIXED' "$TEST_DIR/merge-comments"; then
  echo "    PASS"
else
  echo "    FAIL: merge did not post findings-history comment" >&2
  cat "$MERGE_OUT" >&2
  [ -f "$TEST_DIR/merge-comments" ] && cat "$TEST_DIR/merge-comments" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 4: comment_findings_history=false skips post-merge history"
rm -f "$TEST_DIR/merge-comments" "$TEST_DIR/merged" "$TEST_DIR/checkout"
printf '[review]\ncomment_on_clean = true\ncomment_findings_history = false\n' >"$MERGE_DIR/repo/.codex-review.toml"
PATH="$MERGE_FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  TEST_REPO_ROOT="$MERGE_DIR/repo" \
  GH_COMMENT_FILE="$TEST_DIR/merge-comments" \
  GH_MERGED_MARKER="$TEST_DIR/merged" \
  GH_CHECKOUT_FILE="$TEST_DIR/checkout" \
  TOUCHSTONE_NO_PREFLIGHT=1 \
  bash "$MERGE_DIR/scripts/merge-pr.sh" 123 >"$TEST_DIR/merge-disabled.out" 2>&1

if grep -q 'Findings-history PR comment disabled' "$TEST_DIR/merge-disabled.out" \
  && ! grep -q '<details>' "$TEST_DIR/merge-comments"; then
  echo "    PASS"
else
  echo "    FAIL: disabled findings-history comment still posted" >&2
  cat "$TEST_DIR/merge-disabled.out" >&2
  [ -f "$TEST_DIR/merge-comments" ] && cat "$TEST_DIR/merge-comments" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" = "0" ]; then
  echo "==> PASS: fix-loop findings history is persisted and posted"
  exit 0
fi
echo "==> FAIL: $ERRORS case(s) regressed" >&2
exit 1
