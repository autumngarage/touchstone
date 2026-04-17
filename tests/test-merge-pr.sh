#!/usr/bin/env bash
#
# tests/test-merge-pr.sh — verify merge-pr.sh does not depend on local jq.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-merge-pr.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "==> Test: merge script works without jq in PATH"

FAKE_BIN="$TEST_DIR/bin"
MERGE_SCRIPT_DIR="$TEST_DIR/scripts"
mkdir -p "$FAKE_BIN" "$MERGE_SCRIPT_DIR"
cp "$TOUCHSTONE_ROOT/scripts/merge-pr.sh" "$MERGE_SCRIPT_DIR/merge-pr.sh"
cat > "$MERGE_SCRIPT_DIR/codex-review.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'CODEX_REVIEW_BASE=%s\n' "${CODEX_REVIEW_BASE:-}"
  printf 'CODEX_REVIEW_FORCE=%s\n' "${CODEX_REVIEW_FORCE:-}"
  printf 'CODEX_REVIEW_MODE=%s\n' "${CODEX_REVIEW_MODE:-}"
} > "$CODEX_REVIEW_LOG"
EOF
chmod +x "$MERGE_SCRIPT_DIR/merge-pr.sh" "$MERGE_SCRIPT_DIR/codex-review.sh"

cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1 $2" in
  "repo view")
    echo "main"
    ;;
  "pr view")
    if [ "$5" = "state" ]; then
      echo "OPEN"
    elif [ "$5" = "headRefName" ]; then
      echo "feature/test"
    elif [ "$5" = "headRefOid" ]; then
      echo "pr-head-oid"
    elif [ "$5" = "mergeStateStatus,mergeable" ]; then
      echo "CLEAN MERGEABLE"
    else
      echo "unexpected gh pr view args: $*" >&2
      exit 1
    fi
    ;;
  "pr checkout")
    if [ "${4:-}" != "--detach" ]; then
      echo "unexpected gh pr checkout args: $*" >&2
      exit 1
    fi
    echo "checked-out" > "$GH_CHECKOUT_FILE"
    echo "checked out PR $3"
    ;;
  "pr merge")
    if [ "$4 $5 $6 $7" != "--squash --delete-branch --match-head-commit pr-head-oid" ]; then
      echo "unexpected gh pr merge args: $*" >&2
      exit 1
    fi
    echo "$7" > "$GH_MERGE_HEAD_FILE"
    echo "merged"
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
EOF

cat > "$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  "rev-parse --abbrev-ref HEAD")
    if [ -f "$GH_CHECKOUT_FILE" ]; then
      echo "HEAD"
    else
      echo "feature/test"
    fi
    ;;
  "rev-parse HEAD")
    if [ -f "$GH_CHECKOUT_FILE" ]; then
      echo "pr-head-oid"
    else
      echo "stale-local-oid"
    fi
    ;;
  "fetch origin +refs/heads/main:refs/remotes/origin/main")
    echo "fetched main"
    ;;
  "rev-parse --verify --quiet origin/main^{commit}")
    echo "base-oid"
    ;;
  "status --porcelain")
    ;;
  "checkout main")
    echo "Switched to branch 'main'"
    ;;
  "pull --rebase")
    echo "Already up to date."
    ;;
  *)
    echo "unexpected git args: $*" >&2
    exit 1
    ;;
esac
EOF

chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/git"

OUTPUT_FILE="$TEST_DIR/output.txt"
CODEX_REVIEW_LOG="$TEST_DIR/codex-review.log"
GH_CHECKOUT_FILE="$TEST_DIR/gh-checkout"
GH_MERGE_HEAD_FILE="$TEST_DIR/gh-merge-head"
PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  CODEX_REVIEW_LOG="$CODEX_REVIEW_LOG" \
  GH_CHECKOUT_FILE="$GH_CHECKOUT_FILE" \
  GH_MERGE_HEAD_FILE="$GH_MERGE_HEAD_FILE" \
  bash "$MERGE_SCRIPT_DIR/merge-pr.sh" 123 >"$OUTPUT_FILE" 2>&1

if grep -q 'attempt 1: mergeStateStatus=CLEAN mergeable=MERGEABLE' "$OUTPUT_FILE" \
  && grep -q '==> Refreshing origin/main for merge review' "$OUTPUT_FILE" \
  && grep -q '==> Checking out PR #123 head (feature/test) for merge review' "$OUTPUT_FILE" \
  && grep -q '==> Running merge review' "$OUTPUT_FILE" \
  && grep -q '==> Done\.' "$OUTPUT_FILE" \
  && grep -q '^checked-out$' "$GH_CHECKOUT_FILE" \
  && grep -q '^pr-head-oid$' "$GH_MERGE_HEAD_FILE" \
  && grep -q '^CODEX_REVIEW_BASE=origin/main$' "$CODEX_REVIEW_LOG" \
  && grep -q '^CODEX_REVIEW_FORCE=1$' "$CODEX_REVIEW_LOG" \
  && grep -q '^CODEX_REVIEW_MODE=review-only$' "$CODEX_REVIEW_LOG"; then
  echo "==> PASS: merge-pr.sh completed without jq"
  exit 0
fi

echo "FAIL: merge-pr.sh output did not show a successful jq-free merge path" >&2
cat "$OUTPUT_FILE" >&2
exit 1
