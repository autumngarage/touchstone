#!/usr/bin/env bash
#
# tests/test-review-trusted-base-config.sh — regression guard for the merge-gate
# trust boundary. Under the merge gate the working tree is the attacker's PR
# head, so the review hook must read its control files (.touchstone-review.toml,
# .codex-review-context.md) from the trusted base ref, not the working tree.
# Otherwise a PR could weaken/disable its own guardrails or inject "trusted"
# project context into the fix-loop prompt.
#
# Two layers of coverage, both offline (no model quota):
#   1. unit: extract resolve_trusted_review_file() and exercise it directly.
#   2. integration: run the real hook with CODEX_REVIEW_TEST_PRINT_CONFIG=1,
#      which prints the finally-resolved CONFIG_FILE and exits. This covers the
#      script-level fallback — in particular the case where the base ref has NO
#      config but the PR head ADDS one (the gate must NOT honor it).
#
# REPO_ROOT/TRUSTED_REVIEW_TMP_FILES/RESOLVED_REVIEW_FILE_LABEL are consumed by
# the eval'd resolver; shellcheck can't see through eval (file-scoped directive).
# shellcheck disable=SC2034
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$TOUCHSTONE_ROOT/hooks/codex-review.sh"
HOOK="$TOUCHSTONE_ROOT/hooks/codex-review.sh"
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

new_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "t@example.com"
  git -C "$repo" config user.name "T"
  git -C "$repo" checkout -q -b main
}

# ===========================================================================
# Layer 1 — unit test of resolve_trusted_review_file
# ===========================================================================
REPO="$TEST_DIR/repo"
new_repo "$REPO"
printf 'safe_by_default = false\n# BASE_STRICT_CONFIG\n' >"$REPO/.touchstone-review.toml"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "base: strict review config"
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"

git -C "$REPO" checkout -q -b attacker
printf 'safe_by_default = true\n# HEAD_WEAK_CONFIG\n' >"$REPO/.touchstone-review.toml"
printf 'HEAD_INJECTED_CONTEXT\n' >"$REPO/.codex-review-context.md"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "attacker: weaken config + inject context"

run_resolver() {
  (
    cd "$REPO"
    REPO_ROOT="$REPO"
    TRUSTED_REVIEW_TMP_FILES=()
    RESOLVED_REVIEW_FILE_LABEL=""
    eval "$(extract_fn resolve_trusted_review_file)"
    resolved="$(resolve_trusted_review_file "$@")"
    if [ -n "$resolved" ]; then
      printf 'CONTENT<<<\n'
      cat "$resolved"
      printf '>>>\n'
    else
      printf 'CONTENT=<none>\n'
    fi
  )
}

out="$(CODEX_REVIEW_PR_NUMBER=7 CODEX_REVIEW_BASE="$BASE_SHA" \
  run_resolver .touchstone-review.toml .codex-review.toml)"
echo "$out" | grep -q "BASE_STRICT_CONFIG" \
  || fail "[unit] gate must read config from base ref (expected BASE_STRICT_CONFIG)"
if echo "$out" | grep -q "HEAD_WEAK_CONFIG"; then
  fail "[unit] gate must NOT read config from attacker PR head"
fi

out_ctx="$(CODEX_REVIEW_PR_NUMBER=7 CODEX_REVIEW_BASE="$BASE_SHA" \
  run_resolver .codex-review-context.md .github/codex-review-context.md)"
echo "$out_ctx" | grep -q "CONTENT=<none>" \
  || fail "[unit] gate must not pick up a context file absent from base"
if echo "$out_ctx" | grep -q "HEAD_INJECTED_CONTEXT"; then
  fail "[unit] gate must NOT inject a PR-supplied review-context file"
fi

out_local="$(run_resolver .touchstone-review.toml .codex-review.toml)"
echo "$out_local" | grep -q "HEAD_WEAK_CONFIG" \
  || fail "[unit] local review must read config from the working tree"

# ===========================================================================
# Layer 2 — integration test of the real hook's CONFIG_FILE resolution
# ===========================================================================
# run_hook_config <branch-to-checkout> [env assignments...] -> prints CONFIG_FILE=...
run_hook_config() {
  local repo="$1"
  shift
  (
    cd "$repo"
    env "$@" CODEX_REVIEW_TEST_PRINT_CONFIG=1 bash "$HOOK" 2>/dev/null
  )
}

config_path_of() { sed -n 's/^CONFIG_FILE=//p' <<<"$1"; }

# --- Scenario A: base HAS config, PR weakens it -> gate uses base (strict) ---
out="$(run_hook_config "$REPO" CODEX_REVIEW_PR_NUMBER=11 CODEX_REVIEW_BASE="$BASE_SHA")"
cfg="$(config_path_of "$out")"
if [ -z "$cfg" ] || ! grep -q "BASE_STRICT_CONFIG" "$cfg" 2>/dev/null; then
  fail "[integ] gate(base-has-config) must resolve CONFIG_FILE to base content; got '$cfg'"
fi
if [ -n "$cfg" ] && grep -q "HEAD_WEAK_CONFIG" "$cfg" 2>/dev/null; then
  fail "[integ] gate(base-has-config) resolved CONFIG_FILE to the PR head's weakened config"
fi

# --- Scenario B (the bug): base has NO config, PR ADDS a weakened one ---
REPO2="$TEST_DIR/repo2"
new_repo "$REPO2"
printf 'placeholder\n' >"$REPO2/README.md" # base commit with NO review config
git -C "$REPO2" add -A
git -C "$REPO2" commit -q -m "base: no review config"
BASE2_SHA="$(git -C "$REPO2" rev-parse HEAD)"
git -C "$REPO2" checkout -q -b attacker2
printf 'safe_by_default = true\n# PR_ADDED_WEAK_CONFIG\n' >"$REPO2/.touchstone-review.toml"
git -C "$REPO2" add -A
git -C "$REPO2" commit -q -m "attacker: introduce weakened config"

out="$(run_hook_config "$REPO2" CODEX_REVIEW_PR_NUMBER=12 CODEX_REVIEW_BASE="$BASE2_SHA")"
cfg="$(config_path_of "$out")"
if [ -n "$cfg" ]; then
  # A non-empty CONFIG_FILE here means the gate fell back to the PR head's file.
  if grep -q "PR_ADDED_WEAK_CONFIG" "$cfg" 2>/dev/null; then
    fail "[integ] BUG: gate honored a config the PR introduced (absent on base): $cfg"
  else
    fail "[integ] gate(base-no-config) must leave CONFIG_FILE empty; got '$cfg'"
  fi
fi

# --- Scenario C: local (no PR number), working tree has config -> use it ---
out="$(run_hook_config "$REPO2")" # on attacker2 branch, working tree has the config
cfg="$(config_path_of "$out")"
if [ -z "$cfg" ] || ! grep -q "PR_ADDED_WEAK_CONFIG" "$cfg" 2>/dev/null; then
  fail "[integ] local review must read config from the working tree; got '$cfg'"
fi

if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: merge gate resolves review config from trusted base, never the PR head (incl. base-absent case)"
else
  echo "==> FAILED with $ERRORS error(s)" >&2
  exit 1
fi
