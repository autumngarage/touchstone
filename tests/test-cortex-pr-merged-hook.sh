#!/usr/bin/env bash
#
# tests/test-cortex-pr-merged-hook.sh — exercise the activation gates +
# graceful-degradation paths for hooks/cortex-pr-merged-hook.sh.
#
# The hook implements Cortex Protocol § 2 Tier-1 trigger T1.9
# (auto-draft a `pr-merged` Journal entry after a PR squash-merges).
# It MUST silently no-op when activation conditions aren't met (so
# projects without Cortex aren't disturbed) and MUST surface visible
# failures past activation (no silent failures).
#
# This is a behavioral test against real fixtures (no mocks). The hook
# exposes test-friendly env knobs (TOUCHSTONE_DEFAULT_BRANCH,
# TOUCHSTONE_CORTEX_HOOK_DISABLE, TOUCHSTONE_CORTEX_HOOK_SKIP_PUSH) so
# we can drive the activation logic end-to-end without needing a real
# GitHub remote or pushing.

set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$TOUCHSTONE_ROOT/hooks/cortex-pr-merged-hook.sh"

if [ ! -f "$HOOK" ]; then
  echo "FAIL: hook source missing: $HOOK" >&2
  exit 1
fi

if [ ! -x "$HOOK" ]; then
  echo "FAIL: hook source must be executable: $HOOK" >&2
  exit 1
fi

# Each scenario builds a fresh git repo fixture in a tmpdir so state
# from one test doesn't leak into the next. The hook resolves the
# default branch via TOUCHSTONE_DEFAULT_BRANCH when set, so we never
# need a configured GitHub remote.
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

mk_fixture() {
  local fixture="$1"
  local dir="$TMPROOT/$fixture"
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q -b main
    git config user.email t@e.co
    git config user.name Test
    : > .keep
    git add .keep
    git commit -q -m "init"
  )
  printf '%s' "$dir"
}

# Scenario A: no .cortex/ → silent skip, exit 0, no commit.
A="$(mk_fixture A)"
A_HEAD_BEFORE="$(git -C "$A" rev-parse HEAD)"
(cd "$A" && TOUCHSTONE_DEFAULT_BRANCH=main bash "$HOOK")
A_HEAD_AFTER="$(git -C "$A" rev-parse HEAD)"
if [ "$A_HEAD_BEFORE" != "$A_HEAD_AFTER" ]; then
  echo "FAIL [A]: hook created a commit when .cortex/ was absent" >&2
  exit 1
fi

# Scenario B: .cortex/ present + config explicitly `off` → silent skip.
B="$(mk_fixture B)"
mkdir -p "$B/.cortex"
echo "cortex_pr_merged_hook=off" > "$B/.touchstone-config"
B_HEAD_BEFORE="$(git -C "$B" rev-parse HEAD)"
(cd "$B" && TOUCHSTONE_DEFAULT_BRANCH=main bash "$HOOK")
B_HEAD_AFTER="$(git -C "$B" rev-parse HEAD)"
if [ "$B_HEAD_BEFORE" != "$B_HEAD_AFTER" ]; then
  echo "FAIL [B]: hook fired with cortex_pr_merged_hook=off" >&2
  exit 1
fi

# Scenario C: .cortex/ present + config absent (default auto) + cortex
# CLI absent → graceful exit 0 (degrade, don't fail merge). We force
# cortex absence by stripping PATH down to nothing that contains it.
C="$(mk_fixture C)"
mkdir -p "$C/.cortex"
C_HEAD_BEFORE="$(git -C "$C" rev-parse HEAD)"
(
  cd "$C"
  PATH="/usr/bin:/bin" \
  TOUCHSTONE_DEFAULT_BRANCH=main \
    bash "$HOOK"
)
C_HEAD_AFTER="$(git -C "$C" rev-parse HEAD)"
if [ "$C_HEAD_BEFORE" != "$C_HEAD_AFTER" ]; then
  echo "FAIL [C]: hook produced a commit when cortex CLI was missing" >&2
  exit 1
fi

# Scenario D: not on the default branch → silent skip even with all
# other gates passing. (The hook gates on `git branch --show-current`
# matching the resolved default.)
D="$(mk_fixture D)"
mkdir -p "$D/.cortex"
(cd "$D" && git checkout -q -b feature/x)
D_HEAD_BEFORE="$(git -C "$D" rev-parse HEAD)"
(cd "$D" && TOUCHSTONE_DEFAULT_BRANCH=main bash "$HOOK")
D_HEAD_AFTER="$(git -C "$D" rev-parse HEAD)"
if [ "$D_HEAD_BEFORE" != "$D_HEAD_AFTER" ]; then
  echo "FAIL [D]: hook fired when current branch != default branch" >&2
  exit 1
fi

# Scenario E: TOUCHSTONE_CORTEX_HOOK_DISABLE=1 short-circuits even when
# all other gates would pass. Used by the test fixture above to probe
# without firing the writer.
E="$(mk_fixture E)"
mkdir -p "$E/.cortex"
echo "cortex_pr_merged_hook=on" > "$E/.touchstone-config"
E_HEAD_BEFORE="$(git -C "$E" rev-parse HEAD)"
(
  cd "$E"
  TOUCHSTONE_DEFAULT_BRANCH=main \
  TOUCHSTONE_CORTEX_HOOK_DISABLE=1 \
    bash "$HOOK"
)
E_HEAD_AFTER="$(git -C "$E" rev-parse HEAD)"
if [ "$E_HEAD_BEFORE" != "$E_HEAD_AFTER" ]; then
  echo "FAIL [E]: TOUCHSTONE_CORTEX_HOOK_DISABLE=1 didn't short-circuit" >&2
  exit 1
fi

# Scenario F: unknown config value → log + skip (don't fire with
# surprise behavior). We can't observe the log line directly without
# capturing stderr, but we can confirm exit 0 + no commit.
F="$(mk_fixture F)"
mkdir -p "$F/.cortex"
echo "cortex_pr_merged_hook=maybe" > "$F/.touchstone-config"
F_HEAD_BEFORE="$(git -C "$F" rev-parse HEAD)"
F_STDERR="$TMPROOT/F-stderr"
(cd "$F" && TOUCHSTONE_DEFAULT_BRANCH=main bash "$HOOK") 2> "$F_STDERR"
F_HEAD_AFTER="$(git -C "$F" rev-parse HEAD)"
if [ "$F_HEAD_BEFORE" != "$F_HEAD_AFTER" ]; then
  echo "FAIL [F]: hook fired on unknown config value 'maybe'" >&2
  exit 1
fi
if ! grep -q "unknown" "$F_STDERR"; then
  echo "FAIL [F]: expected stderr to mention the unknown value (no silent failures)" >&2
  cat "$F_STDERR" >&2
  exit 1
fi

# Scenario G: source-vs-bootstrap consistency. update-project.sh writes
# the hook from `hooks/` to projects' `scripts/`, and merge-pr.sh's call
# site looks for `scripts/cortex-pr-merged-hook.sh`. Confirm the
# bootstrap wiring references the correct source path so an update
# doesn't silently fail to install the hook.
if ! grep -q 'hooks/cortex-pr-merged-hook.sh.*scripts/cortex-pr-merged-hook.sh' \
  "$TOUCHSTONE_ROOT/bootstrap/update-project.sh"; then
  echo "FAIL [G]: bootstrap/update-project.sh missing cortex-pr-merged-hook wiring" >&2
  exit 1
fi
if ! grep -q 'cortex-pr-merged-hook' "$TOUCHSTONE_ROOT/scripts/merge-pr.sh"; then
  echo "FAIL [G]: scripts/merge-pr.sh missing cortex-pr-merged-hook invocation" >&2
  exit 1
fi

echo "==> PASS: cortex-pr-merged-hook activation gates + graceful-degradation paths verified (A-G)"
