#!/usr/bin/env bash
#
# tests/test-review-trusted-base-config.sh — regression guard for the merge-gate
# trust boundary. Under the merge gate the working tree is the attacker's PR
# head, so the review hook must read its control files (.touchstone-review.toml,
# .codex-review-context.md) from the trusted base ref, not the working tree.
# Otherwise a PR could weaken/disable its own guardrails or inject "trusted"
# project context into the fix-loop prompt.
#
# We extract resolve_trusted_review_file() from the real hook and exercise it
# directly so the test pins the shipped behavior without spending model quota.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$TOUCHSTONE_ROOT/hooks/codex-review.sh"
TEST_DIR="$(mktemp -d -t touchstone-test-trusted-base.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0
fail() {
  echo "FAIL: $1" >&2
  ERRORS=$((ERRORS + 1))
}

extract_fn() {
  awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{f=1} f{print} f&&/^}/{exit}' "$SRC"
}

# --- Build a repo: strict config on base, weakened config + injected context on HEAD.
REPO="$TEST_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email "t@example.com"
git -C "$REPO" config user.name "T"
git -C "$REPO" checkout -q -b main
printf 'safe_by_default = false\n# BASE_STRICT_CONFIG\n' >"$REPO/.touchstone-review.toml"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "base: strict review config"
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"

git -C "$REPO" checkout -q -b attacker
printf 'safe_by_default = true\n# HEAD_WEAK_CONFIG\n' >"$REPO/.touchstone-review.toml"
printf 'HEAD_INJECTED_CONTEXT\n' >"$REPO/.codex-review-context.md"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "attacker: weaken config + inject context"

# --- Harness around the extracted function.
run_resolver() {
  # shellcheck disable=SC2034
  (
    cd "$REPO"
    REPO_ROOT="$REPO"
    TRUSTED_REVIEW_TMP_FILES=()
    RESOLVED_REVIEW_FILE_LABEL=""
    eval "$(extract_fn resolve_trusted_review_file)"
    resolved="$(resolve_trusted_review_file "$@")"
    printf 'LABEL=%s\n' "$RESOLVED_REVIEW_FILE_LABEL"
    if [ -n "$resolved" ]; then
      printf 'CONTENT<<<\n'
      cat "$resolved"
      printf '>>>\n'
    else
      printf 'CONTENT=<none>\n'
    fi
  )
}

# === Case A: merge gate (PR context) -> config comes from trusted base ===
out="$(CODEX_REVIEW_PR_NUMBER=7 CODEX_REVIEW_BASE="$BASE_SHA" \
  run_resolver .touchstone-review.toml .codex-review.toml)"
echo "$out" | grep -q "BASE_STRICT_CONFIG" \
  || fail "merge gate must read review config from base ref (expected BASE_STRICT_CONFIG)"
if echo "$out" | grep -q "HEAD_WEAK_CONFIG"; then
  fail "merge gate must NOT read review config from attacker PR head (saw HEAD_WEAK_CONFIG)"
fi

# Context file absent on base -> must resolve to nothing (no injection).
out_ctx="$(CODEX_REVIEW_PR_NUMBER=7 CODEX_REVIEW_BASE="$BASE_SHA" \
  run_resolver .codex-review-context.md .github/codex-review-context.md)"
echo "$out_ctx" | grep -q "CONTENT=<none>" \
  || fail "merge gate must not pick up a prompt-context file absent from base"
if echo "$out_ctx" | grep -q "HEAD_INJECTED_CONTEXT"; then
  fail "merge gate must NOT inject a PR-supplied review-context file"
fi

# === Case B: local pre-push (no PR context) -> working tree is source of truth ===
out_local="$(run_resolver .touchstone-review.toml .codex-review.toml)"
echo "$out_local" | grep -q "HEAD_WEAK_CONFIG" \
  || fail "local review must read config from the working tree"

out_local_ctx="$(run_resolver .codex-review-context.md .github/codex-review-context.md)"
echo "$out_local_ctx" | grep -q "HEAD_INJECTED_CONTEXT" \
  || fail "local review must read the working-tree context file"

if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: review hook reads control files from the trusted base ref under the merge gate"
else
  echo "==> FAILED with $ERRORS error(s)" >&2
  exit 1
fi
