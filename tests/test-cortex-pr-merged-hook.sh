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
    : >.keep
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
echo "cortex_pr_merged_hook=off" >"$B/.touchstone-config"
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
echo "cortex_pr_merged_hook=on" >"$E/.touchstone-config"
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
echo "cortex_pr_merged_hook=maybe" >"$F/.touchstone-config"
F_HEAD_BEFORE="$(git -C "$F" rev-parse HEAD)"
F_STDERR="$TMPROOT/F-stderr"
(cd "$F" && TOUCHSTONE_DEFAULT_BRANCH=main bash "$HOOK") 2>"$F_STDERR"
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

# Scenarios H/I use a fake cortex CLI so we can exercise the activated
# path without depending on a developer machine's installed Cortex
# version or writing real journal entries.
FAKEBIN="$TMPROOT/fakebin"
mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/cortex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${FAKE_CORTEX_LOG:-}" ]; then
  printf '%s\n' "$*" >>"$FAKE_CORTEX_LOG"
fi

if [ "${FAKE_CORTEX_FAIL_ALL:-0}" = "1" ]; then
  printf 'fake cortex must not have been invoked: %s\n' "$*" >&2
  exit 99
fi

if [ "${1:-}" = "--no-auto-sync" ]; then
  shift
fi

if [ "${1:-}" = "check-triggers" ]; then
  if [ "${FAKE_CORTEX_CHECK_TRIGGERS_STATUS:-0}" != "0" ]; then
    if [ -n "${FAKE_CORTEX_CHECK_TRIGGERS_STDERR:-}" ]; then
      printf '%s' "$FAKE_CORTEX_CHECK_TRIGGERS_STDERR" >&2
    fi
    exit "$FAKE_CORTEX_CHECK_TRIGGERS_STATUS"
  fi
  if [ "${FAKE_CORTEX_CHECK_TRIGGERS_EMPTY:-0}" = "1" ]; then
    exit 0
  fi
  if [ -n "${FAKE_CORTEX_CHECK_TRIGGERS_NDJSON:-}" ]; then
    printf '%s\n' "$FAKE_CORTEX_CHECK_TRIGGERS_NDJSON"
  else
    printf '%s\n' '{"trigger":"T1.9","reason":"pull request merged","files":["src/example.py"]}'
  fi
  exit 0
fi

if [ "${1:-}" = "journal" ] && [ "${2:-}" = "draft" ] && [ "${3:-}" = "pr-merged" ]; then
  mkdir -p .cortex/journal
  entry="$(pwd)/.cortex/journal/pr-merged.md"
  printf 'drafted journal\n' > "$entry"
  printf '%s\n' "$entry"
  exit 0
fi

if [ "${1:-}" = "refresh-state" ]; then
  if [ "${FAKE_CORTEX_REFRESH_FAIL:-0}" = "1" ]; then
    printf 'refresh-state unavailable in fake cortex\n' >&2
    exit 64
  fi
  project_dir="$(pwd)"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --path)
        shift
        project_dir="$1"
        ;;
    esac
    shift || true
  done
  mkdir -p "$project_dir/.cortex"
  printf 'refreshed state\n' > "$project_dir/.cortex/state.md"
  exit 0
fi

printf 'unexpected fake cortex invocation: %s\n' "$*" >&2
exit 2
EOF
chmod +x "$FAKEBIN/cortex"
cat >"$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"

if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
  if [ "${3:-}" = "--json" ] && [ "${4:-}" = "defaultBranchRef" ]; then
    printf 'main\n'
    exit 0
  fi
  if [ "${3:-}" = "--json" ] && [ "${4:-}" = "nameWithOwner" ]; then
    printf '%s\n' "${FAKE_GH_REPO_SLUG:-autumngarage/touchstone}"
    exit 0
  fi
fi

if [ "${1:-}" = "api" ] && [ "${2:-}" = "repos/${FAKE_GH_REPO_SLUG:-autumngarage/touchstone}" ]; then
  allow_auto_merge="${FAKE_ALLOW_AUTO_MERGE:-true}"
  case "$allow_auto_merge" in
    true | false) printf '%s\n' "$allow_auto_merge" ;;
    *) printf 'null\n' ;;
  esac
  exit 0
fi

if [ "${1:-}" = "label" ] && [ "${2:-}" = "list" ]; then
  exit 0
fi

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "create" ]; then
  printf '%s\n' "${FAKE_GH_PR_URL:-https://example.test/cortex-journal-pr/777}"
  exit 0
fi

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ] && [ "${4:-}" = "--json" ] && [ "${5:-}" = "mergeStateStatus,mergeable" ]; then
  printf '%s\n' "${FAKE_GH_MERGE_STATE:-CLEAN MERGEABLE}"
  exit 0
fi

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ] && [ "${4:-}" = "--json" ] && [ "${5:-}" = "state" ]; then
  printf '%s\n' "${FAKE_GH_PR_STATE:-MERGED}"
  exit 0
fi

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "checks" ]; then
  if [ -n "${FAKE_GH_FAILED_CHECKS:-}" ]; then
    printf '%s\n' "${FAKE_GH_FAILED_CHECKS}"
  fi
  exit 0
fi

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "merge" ]; then
  if [ "${FAKE_GH_PR_MERGE_FAIL:-0}" = "1" ]; then
    exit "${FAKE_GH_PR_MERGE_EXIT_CODE:-1}"
  fi
  exit 0
fi

printf 'unexpected fake gh invocation: %s\n' "$*" >&2
exit 2
EOF
chmod +x "$FAKEBIN/gh"

# Scenario H: activated hook drafts a journal entry, refreshes state.md,
# and includes both files in the same local hook commit.
H="$(mk_fixture H)"
mkdir -p "$H/.cortex"
printf '0.5.0\n' >"$H/.cortex/SPEC_VERSION"
printf 'stale state\n' >"$H/.cortex/state.md"
(cd "$H" && git add .cortex/SPEC_VERSION .cortex/state.md && git commit -q -m "add cortex state")
H_MAIN_BEFORE="$(git -C "$H" rev-parse main)"
(
  cd "$H"
  PATH="$FAKEBIN:$PATH" \
    TOUCHSTONE_DEFAULT_BRANCH=main \
    TOUCHSTONE_CORTEX_HOOK_SKIP_PUSH=1 \
    TOUCHSTONE_MERGED_PR=131 \
    bash "$HOOK"
)
if [ "$(git -C "$H" rev-parse main)" != "$H_MAIN_BEFORE" ]; then
  echo "FAIL [H]: SKIP_PUSH moved default branch instead of isolating the journal commit" >&2
  git -C "$H" log --oneline --decorate -3 >&2
  exit 1
fi
if [ "$(git -C "$H" branch --show-current)" != "docs/journal-pr-131" ]; then
  echo "FAIL [H]: SKIP_PUSH did not leave worktree on docs/journal-pr-131" >&2
  git -C "$H" branch --show-current >&2
  exit 1
fi
H_CHANGED="$(git -C "$H" show --name-only --format= HEAD)"
if ! printf '%s\n' "$H_CHANGED" | grep -qx '.cortex/journal/pr-merged.md'; then
  echo "FAIL [H]: hook commit did not include drafted journal entry" >&2
  printf '%s\n' "$H_CHANGED" >&2
  exit 1
fi
if ! printf '%s\n' "$H_CHANGED" | grep -qx '.cortex/state.md'; then
  echo "FAIL [H]: hook commit did not include refreshed Cortex state" >&2
  printf '%s\n' "$H_CHANGED" >&2
  exit 1
fi
if [ "$(cat "$H/.cortex/state.md")" != "refreshed state" ]; then
  echo "FAIL [H]: state.md content was not refreshed" >&2
  cat "$H/.cortex/state.md" >&2
  exit 1
fi
if [ "$(git -C "$H" status --porcelain)" != "" ]; then
  echo "FAIL [H]: hook left working tree dirty after state refresh commit" >&2
  git -C "$H" status --short >&2
  exit 1
fi

# Scenario H2: .cortex/ without SPEC_VERSION is not initialized for
# writer paths. The hook must skip before invoking cortex.
H2="$(mk_fixture H2)"
mkdir -p "$H2/.cortex"
H2_LOG="$TMPROOT/H2-cortex.log"
H2_STDERR="$TMPROOT/H2-stderr"
H2_HEAD_BEFORE="$(git -C "$H2" rev-parse HEAD)"
(
  cd "$H2"
  PATH="$FAKEBIN:$PATH" \
    FAKE_CORTEX_LOG="$H2_LOG" \
    FAKE_CORTEX_FAIL_ALL=1 \
    TOUCHSTONE_DEFAULT_BRANCH=main \
    bash "$HOOK"
) 2>"$H2_STDERR"
if [ "$(git -C "$H2" rev-parse HEAD)" != "$H2_HEAD_BEFORE" ]; then
  echo "FAIL [H2]: missing SPEC_VERSION hook path changed HEAD" >&2
  exit 1
fi
if ! grep -q "SPEC_VERSION missing" "$H2_STDERR"; then
  echo "FAIL [H2]: missing SPEC_VERSION skip did not explain itself" >&2
  cat "$H2_STDERR" >&2
  exit 1
fi
if [ -s "$H2_LOG" ]; then
  echo "FAIL [H2]: cortex was invoked before SPEC_VERSION gate" >&2
  cat "$H2_LOG" >&2
  exit 1
fi

# Scenario I: if refresh-state is unavailable/fails without changing
# state.md, the hook remains fail-open for the optional refresh, commits
# the journal entry, and emits an actionable recovery command.
I="$(mk_fixture I)"
mkdir -p "$I/.cortex"
printf '0.5.0\n' >"$I/.cortex/SPEC_VERSION"
printf 'stale state\n' >"$I/.cortex/state.md"
(cd "$I" && git add .cortex/SPEC_VERSION .cortex/state.md && git commit -q -m "add cortex state")
I_STDERR="$TMPROOT/I-stderr"
(
  cd "$I"
  PATH="$FAKEBIN:$PATH" \
    FAKE_CORTEX_REFRESH_FAIL=1 \
    TOUCHSTONE_DEFAULT_BRANCH=main \
    TOUCHSTONE_CORTEX_HOOK_SKIP_PUSH=1 \
    bash "$HOOK"
) 2>"$I_STDERR"
I_CHANGED="$(git -C "$I" show --name-only --format= HEAD)"
if ! printf '%s\n' "$I_CHANGED" | grep -qx '.cortex/journal/pr-merged.md'; then
  echo "FAIL [I]: hook did not commit journal entry when refresh-state failed cleanly" >&2
  printf '%s\n' "$I_CHANGED" >&2
  exit 1
fi
if printf '%s\n' "$I_CHANGED" | grep -qx '.cortex/state.md'; then
  echo "FAIL [I]: hook committed state.md after refresh-state failed" >&2
  printf '%s\n' "$I_CHANGED" >&2
  exit 1
fi
if [ "$(cat "$I/.cortex/state.md")" != "stale state" ]; then
  echo "FAIL [I]: failed refresh-state unexpectedly changed state.md" >&2
  cat "$I/.cortex/state.md" >&2
  exit 1
fi
if ! grep -q "cortex refresh-state --path" "$I_STDERR" || ! grep -q "git commit -m 'docs(cortex): refresh state'" "$I_STDERR"; then
  echo "FAIL [I]: refresh-state failure did not include actionable recovery instructions" >&2
  cat "$I_STDERR" >&2
  exit 1
fi

# Scenario J: no fired triggers → silent skip, no journal draft, no commit.
J="$(mk_fixture J)"
mkdir -p "$J/.cortex"
printf '0.5.0\n' >"$J/.cortex/SPEC_VERSION"
printf 'tracked state\n' >"$J/.cortex/state.md"
(cd "$J" && git add .cortex/SPEC_VERSION .cortex/state.md && git commit -q -m "add cortex state")
J_HEAD_BEFORE="$(git -C "$J" rev-parse HEAD)"
J_LOG="$TMPROOT/J-cortex.log"
(
  cd "$J"
  PATH="$FAKEBIN:$PATH" \
    FAKE_CORTEX_LOG="$J_LOG" \
    FAKE_CORTEX_CHECK_TRIGGERS_EMPTY=1 \
    TOUCHSTONE_DEFAULT_BRANCH=main \
    TOUCHSTONE_CORTEX_HOOK_SKIP_PUSH=1 \
    bash "$HOOK"
)
J_HEAD_AFTER="$(git -C "$J" rev-parse HEAD)"
if [ "$J_HEAD_BEFORE" != "$J_HEAD_AFTER" ]; then
  echo "FAIL [J]: hook created a commit when check-triggers returned empty" >&2
  exit 1
fi
if [ -f "$J/.cortex/journal/pr-merged.md" ]; then
  echo "FAIL [J]: hook drafted a journal entry when no triggers fired" >&2
  exit 1
fi
if ! grep -q "check-triggers --since HEAD~1" "$J_LOG" || grep -q "journal draft" "$J_LOG"; then
  echo "FAIL [J]: expected only check-triggers before silent skip" >&2
  cat "$J_LOG" >&2
  exit 1
fi

# Scenario K: T1.4 fired → journal entry includes trigger context.
K="$(mk_fixture K)"
mkdir -p "$K/.cortex"
printf '0.5.0\n' >"$K/.cortex/SPEC_VERSION"
printf 'tracked state\n' >"$K/.cortex/state.md"
(cd "$K" && git add .cortex/SPEC_VERSION .cortex/state.md && git commit -q -m "add cortex state")
K_NDJSON='{"trigger":"T1.4","reason":"file deletion exceeds 100 lines (deleted 142 from src/foo.py)","files":["src/foo.py"]}'
(
  cd "$K"
  PATH="$FAKEBIN:$PATH" \
    FAKE_CORTEX_CHECK_TRIGGERS_NDJSON="$K_NDJSON" \
    TOUCHSTONE_DEFAULT_BRANCH=main \
    TOUCHSTONE_CORTEX_HOOK_SKIP_PUSH=1 \
    TOUCHSTONE_MERGED_PR=300 \
    bash "$HOOK"
)
K_BODY="$(git -C "$K" show HEAD:.cortex/journal/pr-merged.md)"
if ! printf '%s\n' "$K_BODY" | grep -q "## Triggers fired" \
  || ! printf '%s\n' "$K_BODY" | grep -q "T1.4" \
  || ! printf '%s\n' "$K_BODY" | grep -q "src/foo.py"; then
  echo "FAIL [K]: T1.4 trigger context missing from journal entry" >&2
  printf '%s\n' "$K_BODY" >&2
  exit 1
fi

# Scenario L: T1.1 fired → journal entry includes trigger context.
L="$(mk_fixture L)"
mkdir -p "$L/.cortex"
printf '0.5.0\n' >"$L/.cortex/SPEC_VERSION"
printf 'tracked state\n' >"$L/.cortex/state.md"
(cd "$L" && git add .cortex/SPEC_VERSION .cortex/state.md && git commit -q -m "add cortex state")
L_NDJSON='{"trigger":"T1.1","reason":"diff touches principles/","files":["principles/foo.md"]}'
(
  cd "$L"
  PATH="$FAKEBIN:$PATH" \
    FAKE_CORTEX_CHECK_TRIGGERS_NDJSON="$L_NDJSON" \
    TOUCHSTONE_DEFAULT_BRANCH=main \
    TOUCHSTONE_CORTEX_HOOK_SKIP_PUSH=1 \
    TOUCHSTONE_MERGED_PR=301 \
    bash "$HOOK"
)
L_BODY="$(git -C "$L" show HEAD:.cortex/journal/pr-merged.md)"
if ! printf '%s\n' "$L_BODY" | grep -q "## Triggers fired" \
  || ! printf '%s\n' "$L_BODY" | grep -q "T1.1" \
  || ! printf '%s\n' "$L_BODY" | grep -q "principles/foo.md"; then
  echo "FAIL [L]: T1.1 trigger context missing from journal entry" >&2
  printf '%s\n' "$L_BODY" >&2
  exit 1
fi

# Scenario M: env force bypasses the gate and avoids check-triggers entirely.
M="$(mk_fixture M)"
mkdir -p "$M/.cortex"
printf '0.5.0\n' >"$M/.cortex/SPEC_VERSION"
printf 'tracked state\n' >"$M/.cortex/state.md"
(cd "$M" && git add .cortex/SPEC_VERSION .cortex/state.md && git commit -q -m "add cortex state")
M_LOG="$TMPROOT/M-cortex.log"
(
  cd "$M"
  PATH="$FAKEBIN:$PATH" \
    FAKE_CORTEX_LOG="$M_LOG" \
    FAKE_CORTEX_CHECK_TRIGGERS_EMPTY=1 \
    TOUCHSTONE_DEFAULT_BRANCH=main \
    TOUCHSTONE_CORTEX_HOOK_FORCE=1 \
    TOUCHSTONE_CORTEX_HOOK_SKIP_PUSH=1 \
    TOUCHSTONE_MERGED_PR=400 \
    bash "$HOOK"
)
if ! git -C "$M" show --name-only --format= HEAD | grep -qx '.cortex/journal/pr-merged.md'; then
  echo "FAIL [M]: force env did not produce a journal entry" >&2
  exit 1
fi
if grep -q "check-triggers" "$M_LOG"; then
  echo "FAIL [M]: force env should bypass check-triggers" >&2
  cat "$M_LOG" >&2
  exit 1
fi

# Scenario N: config force has the same bypass behavior as the env knob.
N="$(mk_fixture N)"
mkdir -p "$N/.cortex"
printf '0.5.0\n' >"$N/.cortex/SPEC_VERSION"
printf 'tracked state\n' >"$N/.cortex/state.md"
printf 'cortex_pr_merged_hook=force\n' >"$N/.touchstone-config"
(cd "$N" && git add .cortex/SPEC_VERSION .cortex/state.md .touchstone-config && git commit -q -m "add cortex state with force config")
N_LOG="$TMPROOT/N-cortex.log"
(
  cd "$N"
  PATH="$FAKEBIN:$PATH" \
    FAKE_CORTEX_LOG="$N_LOG" \
    FAKE_CORTEX_CHECK_TRIGGERS_EMPTY=1 \
    TOUCHSTONE_DEFAULT_BRANCH=main \
    TOUCHSTONE_CORTEX_HOOK_SKIP_PUSH=1 \
    TOUCHSTONE_MERGED_PR=401 \
    bash "$HOOK"
)
if ! git -C "$N" show --name-only --format= HEAD | grep -qx '.cortex/journal/pr-merged.md'; then
  echo "FAIL [N]: force config did not produce a journal entry" >&2
  exit 1
fi
if grep -q "check-triggers" "$N_LOG"; then
  echo "FAIL [N]: force config should bypass check-triggers" >&2
  cat "$N_LOG" >&2
  exit 1
fi

# Scenario O: missing/unavailable check-triggers logs and falls back.
O="$(mk_fixture O)"
mkdir -p "$O/.cortex"
printf '0.5.0\n' >"$O/.cortex/SPEC_VERSION"
printf 'tracked state\n' >"$O/.cortex/state.md"
(cd "$O" && git add .cortex/SPEC_VERSION .cortex/state.md && git commit -q -m "add cortex state")
O_STDERR="$TMPROOT/O-stderr"
(
  cd "$O"
  PATH="$FAKEBIN:$PATH" \
    FAKE_CORTEX_CHECK_TRIGGERS_STATUS=2 \
    FAKE_CORTEX_CHECK_TRIGGERS_STDERR="Error: No such command 'check-triggers'.\n" \
    TOUCHSTONE_DEFAULT_BRANCH=main \
    TOUCHSTONE_CORTEX_HOOK_SKIP_PUSH=1 \
    TOUCHSTONE_MERGED_PR=500 \
    bash "$HOOK"
) 2>"$O_STDERR"
if ! git -C "$O" show --name-only --format= HEAD | grep -qx '.cortex/journal/pr-merged.md'; then
  echo "FAIL [O]: check-triggers fallback did not produce a journal entry" >&2
  exit 1
fi
if ! grep -q "cortex check-triggers unavailable; falling back to journal-every-merge" "$O_STDERR" \
  || ! grep -q "No such command 'check-triggers'" "$O_STDERR"; then
  echo "FAIL [O]: check-triggers fallback did not surface stderr context" >&2
  cat "$O_STDERR" >&2
  exit 1
fi

# Scenario P: recursion guard runs before check-triggers or any cortex call.
P="$(mk_fixture P)"
mkdir -p "$P/.cortex/journal"
printf 'auto-draft\n' >"$P/.cortex/journal/auto-draft.md"
(
  cd "$P"
  git add .cortex/journal/auto-draft.md
  git commit -q -m "docs(journal): auto-draft pr-merged entry for #99"
)
P_HEAD_BEFORE="$(git -C "$P" rev-parse HEAD)"
P_LOG="$TMPROOT/P-cortex.log"
(
  cd "$P"
  PATH="$FAKEBIN:$PATH" \
    FAKE_CORTEX_LOG="$P_LOG" \
    FAKE_CORTEX_FAIL_ALL=1 \
    TOUCHSTONE_DEFAULT_BRANCH=main \
    TOUCHSTONE_CORTEX_HOOK_SKIP_PUSH=1 \
    bash "$HOOK"
)
P_HEAD_AFTER="$(git -C "$P" rev-parse HEAD)"
if [ "$P_HEAD_BEFORE" != "$P_HEAD_AFTER" ]; then
  echo "FAIL [P]: recursion guard changed HEAD" >&2
  exit 1
fi
if [ -s "$P_LOG" ]; then
  echo "FAIL [P]: recursion guard must run before any cortex invocation" >&2
  cat "$P_LOG" >&2
  exit 1
fi

# Scenario Q: default publish mode keeps local main clean by committing on
# a follow-up branch, pushing it, and opening a PR instead of pushing main.
Q="$(mk_fixture Q)"
Q_REMOTE="$TMPROOT/Q-remote.git"
Q_BRANCH="docs/cortex-pr-merged-test"
Q_GH_LOG="$TMPROOT/Q-gh.log"
git init -q --bare "$Q_REMOTE"
git -C "$Q" remote add origin "$Q_REMOTE"
git -C "$Q" push -q -u origin main
mkdir -p "$Q/.cortex"
printf '0.5.0\n' >"$Q/.cortex/SPEC_VERSION"
printf 'tracked state\n' >"$Q/.cortex/state.md"
(cd "$Q" && git add .cortex/SPEC_VERSION .cortex/state.md && git commit -q -m "add cortex state" && git push -q origin main)
Q_HEAD_BEFORE="$(git -C "$Q" rev-parse HEAD)"
(
  cd "$Q"
  PATH="$FAKEBIN:$PATH" \
    FAKE_GH_LOG="$Q_GH_LOG" \
    TOUCHSTONE_DEFAULT_BRANCH=main \
    TOUCHSTONE_CORTEX_HOOK_BRANCH="$Q_BRANCH" \
    TOUCHSTONE_MERGED_PR=777 \
    bash "$HOOK"
)
Q_HEAD_AFTER="$(git -C "$Q" rev-parse HEAD)"
if [ "$Q_HEAD_BEFORE" != "$Q_HEAD_AFTER" ]; then
  echo "FAIL [Q]: default branch moved after journal PR publish" >&2
  git -C "$Q" log --oneline --decorate -3 >&2
  exit 1
fi
if [ "$(git -C "$Q" branch --show-current)" != "main" ]; then
  echo "FAIL [Q]: hook did not restore local main after journal PR publish" >&2
  git -C "$Q" branch --show-current >&2
  exit 1
fi
if [ -n "$(git -C "$Q" status --porcelain)" ]; then
  echo "FAIL [Q]: hook left local main dirty" >&2
  git -C "$Q" status --short >&2
  exit 1
fi
if ! git -C "$Q" show-ref --verify --quiet "refs/heads/$Q_BRANCH"; then
  echo "FAIL [Q]: local journal branch should be preserved as a recovery branch" >&2
  git -C "$Q" branch >&2
  exit 1
fi
if ! git -C "$Q" ls-remote --exit-code --heads origin "$Q_BRANCH" >/dev/null 2>&1; then
  echo "FAIL [Q]: journal branch was not pushed to origin" >&2
  exit 1
fi
git -C "$Q" fetch -q origin "$Q_BRANCH:$Q_BRANCH-check"
if ! git -C "$Q" show "$Q_BRANCH-check:.cortex/journal/pr-merged.md" >/dev/null 2>&1 \
  || ! git -C "$Q" show "$Q_BRANCH-check:.cortex/state.md" >/dev/null 2>&1; then
  echo "FAIL [Q]: pushed journal branch missing Cortex artifacts" >&2
  git -C "$Q" show --name-only --format= "$Q_BRANCH-check" >&2
  exit 1
fi
if ! grep -q "pr create" "$Q_GH_LOG" \
  || ! grep -q -- "--head $Q_BRANCH" "$Q_GH_LOG" \
  || ! grep -q -- "--base main" "$Q_GH_LOG" \
  || ! grep -q -- "--title docs(journal): auto-draft pr-merged entry for #777" "$Q_GH_LOG"; then
  echo "FAIL [Q]: hook did not open a PR for the journal branch" >&2
  cat "$Q_GH_LOG" >&2
  exit 1
fi
if ! grep -q "pr merge 777 --squash --delete-branch --auto" "$Q_GH_LOG"; then
  echo "FAIL [Q]: hook did not queue journal PR auto-merge" >&2
  cat "$Q_GH_LOG" >&2
  exit 1
fi

# Scenario R: explicit legacy direct-push mode bypasses pre-push hooks for
# the deterministic auto-journal commit. This preserves the compatibility
# path without letting local default-branch guards block post-merge cleanup.
R="$(mk_fixture R)"
R_REMOTE="$TMPROOT/R-remote.git"
R_PRE_PUSH_LOG="$TMPROOT/R-pre-push.log"
git init -q --bare "$R_REMOTE"
git -C "$R" remote add origin "$R_REMOTE"
git -C "$R" push -q -u origin main
mkdir -p "$R/.cortex"
printf '0.5.0\n' >"$R/.cortex/SPEC_VERSION"
printf 'tracked state\n' >"$R/.cortex/state.md"
(cd "$R" && git add .cortex/SPEC_VERSION .cortex/state.md && git commit -q -m "add cortex state" && git push -q origin main)
cat >"$R/.git/hooks/pre-push" <<EOF
#!/usr/bin/env bash
printf 'pre-push hook unexpectedly ran\n' >"$R_PRE_PUSH_LOG"
exit 79
EOF
chmod +x "$R/.git/hooks/pre-push"
(
  cd "$R"
  PATH="$FAKEBIN:$PATH" \
    TOUCHSTONE_DEFAULT_BRANCH=main \
    TOUCHSTONE_CORTEX_HOOK_DIRECT_PUSH=1 \
    TOUCHSTONE_MERGED_PR=778 \
    bash "$HOOK"
)
if [ -f "$R_PRE_PUSH_LOG" ]; then
  echo "FAIL [R]: direct-push mode invoked pre-push hooks" >&2
  cat "$R_PRE_PUSH_LOG" >&2
  exit 1
fi
if [ "$(git -C "$R" rev-parse HEAD)" != "$(git -C "$R" rev-parse origin/main)" ]; then
  echo "FAIL [R]: direct-push mode did not publish the generated commit to origin/main" >&2
  git -C "$R" log --oneline --decorate -3 >&2
  exit 1
fi
if ! git -C "$R" show --name-only --format= HEAD | grep -qx '.cortex/journal/pr-merged.md'; then
  echo "FAIL [R]: direct-push commit missing drafted journal entry" >&2
  git -C "$R" show --name-only --format= HEAD >&2
  exit 1
fi

# Scenario S: when repo allow_auto_merge=false, hook waits for CLEAN and
# merges synchronously (no --auto queue request).
S="$(mk_fixture S)"
S_REMOTE="$TMPROOT/S-remote.git"
S_BRANCH="docs/cortex-pr-merged-sync-merge"
S_GH_LOG="$TMPROOT/S-gh.log"
git init -q --bare "$S_REMOTE"
git -C "$S" remote add origin "$S_REMOTE"
git -C "$S" push -q -u origin main
mkdir -p "$S/.cortex"
printf '0.5.0\n' >"$S/.cortex/SPEC_VERSION"
printf 'tracked state\n' >"$S/.cortex/state.md"
(cd "$S" && git add .cortex/SPEC_VERSION .cortex/state.md && git commit -q -m "add cortex state" && git push -q origin main)
S_HEAD_BEFORE="$(git -C "$S" rev-parse HEAD)"
(
  cd "$S"
  PATH="$FAKEBIN:$PATH" \
    FAKE_GH_LOG="$S_GH_LOG" \
    FAKE_ALLOW_AUTO_MERGE=false \
    TOUCHSTONE_DEFAULT_BRANCH=main \
    TOUCHSTONE_CORTEX_HOOK_BRANCH="$S_BRANCH" \
    TOUCHSTONE_MERGED_PR=779 \
    bash "$HOOK"
)
S_HEAD_AFTER="$(git -C "$S" rev-parse HEAD)"
if [ "$S_HEAD_BEFORE" != "$S_HEAD_AFTER" ]; then
  echo "FAIL [S]: default branch moved during synchronous journal PR merge path" >&2
  git -C "$S" log --oneline --decorate -3 >&2
  exit 1
fi
if [ "$(git -C "$S" branch --show-current)" != "main" ]; then
  echo "FAIL [S]: hook did not restore local main after synchronous merge path" >&2
  git -C "$S" branch --show-current >&2
  exit 1
fi
if ! grep -q "api repos/autumngarage/touchstone --jq .allow_auto_merge" "$S_GH_LOG"; then
  echo "FAIL [S]: hook did not query repo allow_auto_merge capability" >&2
  cat "$S_GH_LOG" >&2
  exit 1
fi
if ! grep -q "pr merge 777 --squash --delete-branch" "$S_GH_LOG"; then
  echo "FAIL [S]: hook did not perform synchronous gh pr merge" >&2
  cat "$S_GH_LOG" >&2
  exit 1
fi
if grep -q "pr merge 777 --squash --delete-branch --auto" "$S_GH_LOG"; then
  echo "FAIL [S]: synchronous path unexpectedly requested --auto" >&2
  cat "$S_GH_LOG" >&2
  exit 1
fi

# Scenario T: allow_auto_merge=false + PR never becomes CLEAN emits
# actionable diagnostics and exits 0 without merging.
T="$(mk_fixture T)"
T_REMOTE="$TMPROOT/T-remote.git"
T_BRANCH="docs/cortex-pr-merged-not-clean"
T_GH_LOG="$TMPROOT/T-gh.log"
T_STDERR="$TMPROOT/T-stderr"
git init -q --bare "$T_REMOTE"
git -C "$T" remote add origin "$T_REMOTE"
git -C "$T" push -q -u origin main
mkdir -p "$T/.cortex"
printf '0.5.0\n' >"$T/.cortex/SPEC_VERSION"
printf 'tracked state\n' >"$T/.cortex/state.md"
(cd "$T" && git add .cortex/SPEC_VERSION .cortex/state.md && git commit -q -m "add cortex state" && git push -q origin main)
(
  cd "$T"
  PATH="$FAKEBIN:$PATH" \
    FAKE_GH_LOG="$T_GH_LOG" \
    FAKE_ALLOW_AUTO_MERGE=false \
    FAKE_GH_MERGE_STATE="UNKNOWN UNKNOWN" \
    MERGE_PR_STATE_MAX_ATTEMPTS=2 \
    MERGE_PR_SLEEP_OVERRIDE=0 \
    TOUCHSTONE_DEFAULT_BRANCH=main \
    TOUCHSTONE_CORTEX_HOOK_BRANCH="$T_BRANCH" \
    TOUCHSTONE_MERGED_PR=780 \
    bash "$HOOK"
) 2>"$T_STDERR"
if grep -q "pr merge 777 --squash --delete-branch" "$T_GH_LOG"; then
  echo "FAIL [T]: hook attempted merge even though PR never became CLEAN" >&2
  cat "$T_GH_LOG" >&2
  exit 1
fi
if ! grep -q "Diagnostic: gh api repos/autumngarage/touchstone --jq '.allow_auto_merge' returned false." "$T_STDERR"; then
  echo "FAIL [T]: missing allow_auto_merge diagnostic when sync path timed out" >&2
  cat "$T_STDERR" >&2
  exit 1
fi
if ! grep -q "Enable auto-merge in repo settings to restore queue-based merging, or merge PR #777 manually once checks pass." "$T_STDERR"; then
  echo "FAIL [T]: missing actionable remediation guidance for timed-out sync path" >&2
  cat "$T_STDERR" >&2
  exit 1
fi
if ! grep -q "did not become cleanly mergeable in time" "$T_STDERR"; then
  echo "FAIL [T]: timed-out sync path did not explain terminal condition" >&2
  cat "$T_STDERR" >&2
  exit 1
fi

echo "==> PASS: cortex-pr-merged-hook activation gates + graceful-degradation paths verified (A-T)"
