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
  # Mirror the real CLI: an explicit --pr wins; otherwise infer from HEAD's
  # subject. The drafted entry records which source PR it described so tests
  # can assert transport metadata and durable content agree (issue #513).
  pr_value=""
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "--pr" ]; then
      pr_value="$arg"
    fi
    prev="$arg"
  done
  if [ -z "$pr_value" ]; then
    pr_value="inferred-from-head:$(git log -1 --format=%s | { grep -oE '#[0-9]+' || true; } | head -1 | tr -d '#')"
  fi
  mkdir -p .cortex/journal
  entry="$(pwd)/.cortex/journal/pr-merged.md"
  printf 'drafted journal for source-pr=%s\n' "$pr_value" > "$entry"
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
  printf '%s\n' 'autumngarage/example'
  exit 0
fi
if [ "${1:-}" = "api" ] && [ "${2:-}" = "repos/autumngarage/example" ]; then
  printf '%s\n' "${FAKE_GH_ALLOW_AUTO_MERGE:-true}"
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "create" ]; then
  printf 'https://example.test/cortex-journal-pr/777\n'
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  if [ -f "$FAKE_GH_LOG.merged" ]; then
    printf 'MERGED\tCLEAN\tMERGEABLE\t0\t%s\n' "${FAKE_GH_MERGED_HEAD:-$(git rev-parse HEAD)}"
  else
    printf '%b\t%s\n' "${FAKE_GH_PR_VIEW_OUTPUT:-OPEN\tCLEAN\tMERGEABLE\t0}" \
      "${FAKE_GH_PR_HEAD:-$(git rev-parse HEAD)}"
  fi
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "merge" ]; then
  case " $* " in
    *" --auto "*)
      exit "${FAKE_GH_AUTO_MERGE_STATUS:-0}"
      ;;
  esac
  sync_status="${FAKE_GH_SYNC_MERGE_STATUS:-0}"
  if [ "$sync_status" = "0" ] || [ "${FAKE_GH_SYNC_REMOTE_MERGED:-false}" = "true" ]; then
    touch "$FAKE_GH_LOG.merged"
  fi
  exit "$sync_status"
fi
if [ "${1:-}" = "label" ] && [ "${2:-}" = "list" ]; then
  exit 0
fi
printf 'unexpected fake gh invocation: %s\n' "$*" >&2
exit 2
EOF
chmod +x "$FAKEBIN/gh"
cat >"$FAKEBIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKEBIN/sleep"

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
# Issue #513 coherence: the branch name, commit message, and the DURABLE
# journal artifact must all describe the same source PR. The fixture's HEAD
# subject carries no PR reference, so only an explicitly forwarded --pr can
# make the drafted entry say 131 — inference would corrupt the record.
if ! git -C "$H" show HEAD:.cortex/journal/pr-merged.md | grep -q 'source-pr=131'; then
  echo "FAIL [H]: drafted journal does not describe the explicit source PR 131" >&2
  git -C "$H" show HEAD:.cortex/journal/pr-merged.md >&2
  exit 1
fi
if ! git -C "$H" log -1 --format=%s | grep -q '#131'; then
  echo "FAIL [H]: hook commit subject does not name source PR 131" >&2
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
Q_JOURNAL_HEAD="$(git -C "$Q" rev-parse "$Q_BRANCH")"
if grep -q -- "--auto" "$Q_GH_LOG" \
  || ! grep -q "pr merge 777 --squash --delete-branch --match-head-commit $Q_JOURNAL_HEAD" "$Q_GH_LOG"; then
  echo "FAIL [Q]: hook did not synchronously merge the exact journal head" >&2
  cat "$Q_GH_LOG" >&2
  exit 1
fi

mk_cortex_publish_fixture() {
  local fixture="$1"
  local dir remote
  dir="$(mk_fixture "$fixture")"
  remote="$TMPROOT/${fixture}-remote.git"
  git init -q --bare "$remote"
  git -C "$dir" remote add origin "$remote"
  git -C "$dir" push -q -u origin main
  mkdir -p "$dir/.cortex"
  printf '0.5.0\n' >"$dir/.cortex/SPEC_VERSION"
  printf 'tracked state\n' >"$dir/.cortex/state.md"
  (
    cd "$dir"
    git add .cortex/SPEC_VERSION .cortex/state.md
    git commit -q -m "add cortex state"
    git push -q origin main
  )
  printf '%s' "$dir"
}

# Scenario Q2: repositories with auto-merge disabled wait for the PR to
# become clean, then synchronously merge the exact journal head.
Q2="$(mk_cortex_publish_fixture Q2)"
Q2_BRANCH="docs/cortex-pr-merged-sync-test"
Q2_GH_LOG="$TMPROOT/Q2-gh.log"
(
  cd "$Q2"
  PATH="$FAKEBIN:$PATH" \
    FAKE_GH_LOG="$Q2_GH_LOG" \
    FAKE_GH_ALLOW_AUTO_MERGE=false \
    TOUCHSTONE_DEFAULT_BRANCH=main \
    TOUCHSTONE_CORTEX_HOOK_BRANCH="$Q2_BRANCH" \
    TOUCHSTONE_MERGED_PR=779 \
    bash "$HOOK"
)
Q2_JOURNAL_HEAD="$(git -C "$Q2" rev-parse "$Q2_BRANCH")"
if grep -q -- "--auto" "$Q2_GH_LOG"; then
  echo "FAIL [Q2]: auto-merge-disabled repository still used --auto" >&2
  cat "$Q2_GH_LOG" >&2
  exit 1
fi
if ! grep -q "pr view 777 --json state,headRefOid,mergeStateStatus,mergeable,statusCheckRollup" "$Q2_GH_LOG" \
  || ! grep -q "pr merge 777 --squash --delete-branch --match-head-commit $Q2_JOURNAL_HEAD" "$Q2_GH_LOG"; then
  echo "FAIL [Q2]: synchronous fallback did not poll and merge the exact journal head" >&2
  cat "$Q2_GH_LOG" >&2
  exit 1
fi

# Scenario Q3b: a nonzero merge command is accepted when GitHub confirms
# that the exact expected head merged despite local cleanup failure.
Q3B="$(mk_cortex_publish_fixture Q3B)"
Q3B_BRANCH="docs/cortex-pr-merged-local-cleanup-test"
Q3B_GH_LOG="$TMPROOT/Q3B-gh.log"
(
  cd "$Q3B"
  PATH="$FAKEBIN:$PATH" \
    FAKE_GH_LOG="$Q3B_GH_LOG" \
    FAKE_GH_ALLOW_AUTO_MERGE=false \
    FAKE_GH_SYNC_MERGE_STATUS=1 \
    FAKE_GH_SYNC_REMOTE_MERGED=true \
    TOUCHSTONE_DEFAULT_BRANCH=main \
    TOUCHSTONE_CORTEX_HOOK_BRANCH="$Q3B_BRANCH" \
    TOUCHSTONE_MERGED_PR=780 \
    bash "$HOOK"
)
if [ "$(grep -c '^pr view 777 ' "$Q3B_GH_LOG")" -lt 2 ]; then
  echo "FAIL [Q3B]: nonzero merge command did not recheck remote state" >&2
  cat "$Q3B_GH_LOG" >&2
  exit 1
fi

# Scenario Q3: auto-merge capability does not bypass the bounded exact-head path.
Q3="$(mk_cortex_publish_fixture Q3)"
Q3_BRANCH="docs/cortex-pr-merged-auto-fallback-test"
Q3_GH_LOG="$TMPROOT/Q3-gh.log"
Q3_STDERR="$TMPROOT/Q3-stderr"
(
  cd "$Q3"
  PATH="$FAKEBIN:$PATH" \
    FAKE_GH_LOG="$Q3_GH_LOG" \
    FAKE_GH_AUTO_MERGE_STATUS=1 \
    TOUCHSTONE_DEFAULT_BRANCH=main \
    TOUCHSTONE_CORTEX_HOOK_BRANCH="$Q3_BRANCH" \
    TOUCHSTONE_MERGED_PR=780 \
    bash "$HOOK"
) 2>"$Q3_STDERR"
if grep -q -- "--auto" "$Q3_GH_LOG" \
  || ! grep -q -- "--match-head-commit" "$Q3_GH_LOG"; then
  echo "FAIL [Q3]: auto-merge capability bypassed the synchronous exact-head path" >&2
  cat "$Q3_GH_LOG" >&2
  cat "$Q3_STDERR" >&2
  exit 1
fi

assert_sync_landing_failure() {
  local fixture="$1" view_output="$2" expected_message="$3" expected_views="$4"
  local dir branch gh_log stderr_file hook_status=0 actual_views fake_head=""
  dir="$(mk_cortex_publish_fixture "$fixture")"
  branch="docs/cortex-pr-merged-${fixture}-test"
  gh_log="$TMPROOT/${fixture}-gh.log"
  stderr_file="$TMPROOT/${fixture}-stderr"
  if [ "$fixture" = "Q7" ]; then
    fake_head="unexpected-head"
  fi
  (
    cd "$dir"
    PATH="$FAKEBIN:$PATH" \
      FAKE_GH_LOG="$gh_log" \
      FAKE_GH_ALLOW_AUTO_MERGE=false \
      FAKE_GH_PR_VIEW_OUTPUT="$view_output" \
      FAKE_GH_PR_HEAD="$fake_head" \
      TOUCHSTONE_DEFAULT_BRANCH=main \
      TOUCHSTONE_CORTEX_HOOK_BRANCH="$branch" \
      TOUCHSTONE_MERGED_PR=781 \
      bash "$HOOK"
  ) 2>"$stderr_file" || hook_status=$?
  actual_views="$(grep -c '^pr view 777 ' "$gh_log" || true)"
  if [ "$hook_status" -eq 0 ] || ! grep -q "$expected_message" "$stderr_file" \
    || [ "$actual_views" -ne "$expected_views" ]; then
    echo "FAIL [$fixture]: synchronous journal landing failure was not bounded and actionable" >&2
    cat "$stderr_file" >&2
    grep '^pr view 777 ' "$gh_log" >&2 || true
    exit 1
  fi
}

# Scenarios Q4-Q6: conflicts and failed checks stop on the first poll;
# a PR that stays blocked stops at the bounded timeout.
assert_sync_landing_failure Q4 $'OPEN\tDIRTY\tCONFLICTING\t0' "has merge conflicts" 1
assert_sync_landing_failure Q5 $'OPEN\tBLOCKED\tMERGEABLE\t1' "has 1 failed check(s)" 1
assert_sync_landing_failure Q6 $'OPEN\tBLOCKED\tMERGEABLE\t0' "timed out waiting" 60

# Scenario Q7: an externally merged journal PR must still match the
# generated exact head.
assert_sync_landing_failure Q7 $'MERGED\tCLEAN\tMERGEABLE\t0' "head changed unexpectedly" 1

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

# Scenarios S/T/U: sibling-worktree targeting (issue #613). Shipping from a
# feature worktree while main lives in a sibling worktree must still journal:
# merge-pr.sh passes the resolved default-branch worktree explicitly via
# TOUCHSTONE_CORTEX_HOOK_PROJECT_DIR, and the hook journals against it.
S="$(mk_fixture S)"
mkdir -p "$S/.cortex"
printf '0.5.0\n' >"$S/.cortex/SPEC_VERSION"
printf 'stale state\n' >"$S/.cortex/state.md"
(cd "$S" && git add .cortex/SPEC_VERSION .cortex/state.md && git commit -q -m "add cortex state")
S_FEATURE="$TMPROOT/S-feature"
git -C "$S" worktree add -q -b feature/sibling "$S_FEATURE"
S_MAIN_BEFORE="$(git -C "$S" rev-parse main)"

# Scenario T: without the explicit project dir, invoking from the feature
# worktree silently skips (the pre-#613 behavior the caller must compensate
# for). Guards against the hook growing implicit cwd-crawling behavior.
(
  cd "$S_FEATURE"
  PATH="$FAKEBIN:$PATH" \
    TOUCHSTONE_DEFAULT_BRANCH=main \
    TOUCHSTONE_CORTEX_HOOK_SKIP_PUSH=1 \
    bash "$HOOK"
)
if [ "$(git -C "$S" rev-parse main)" != "$S_MAIN_BEFORE" ] \
  || [ "$(git -C "$S" branch --show-current)" != "main" ]; then
  echo "FAIL [T]: hook fired from a feature worktree without an explicit project dir" >&2
  exit 1
fi

# Scenario S: with TOUCHSTONE_CORTEX_HOOK_PROJECT_DIR pointing at the sibling
# default-branch worktree, the hook journals there and leaves the feature
# worktree untouched.
S_FEATURE_HEAD_BEFORE="$(git -C "$S_FEATURE" rev-parse HEAD)"
(
  cd "$S_FEATURE"
  PATH="$FAKEBIN:$PATH" \
    TOUCHSTONE_DEFAULT_BRANCH=main \
    TOUCHSTONE_CORTEX_HOOK_SKIP_PUSH=1 \
    TOUCHSTONE_MERGED_PR=613 \
    TOUCHSTONE_CORTEX_HOOK_PROJECT_DIR="$S" \
    bash "$HOOK"
)
if [ "$(git -C "$S" rev-parse main)" != "$S_MAIN_BEFORE" ]; then
  echo "FAIL [S]: sibling-worktree journal moved the default branch ref" >&2
  git -C "$S" log --oneline --decorate -3 >&2
  exit 1
fi
if [ "$(git -C "$S" branch --show-current)" != "docs/journal-pr-613" ]; then
  echo "FAIL [S]: hook did not journal in the targeted default-branch worktree" >&2
  git -C "$S" branch --show-current >&2
  exit 1
fi
S_CHANGED="$(git -C "$S" show --name-only --format= HEAD)"
if ! printf '%s\n' "$S_CHANGED" | grep -qx '.cortex/journal/pr-merged.md'; then
  echo "FAIL [S]: sibling-worktree hook commit missing drafted journal entry" >&2
  printf '%s\n' "$S_CHANGED" >&2
  exit 1
fi
if [ "$(git -C "$S_FEATURE" rev-parse HEAD)" != "$S_FEATURE_HEAD_BEFORE" ] \
  || [ "$(git -C "$S_FEATURE" branch --show-current)" != "feature/sibling" ] \
  || [ -n "$(git -C "$S_FEATURE" status --porcelain)" ]; then
  echo "FAIL [S]: sibling-worktree journal disturbed the feature worktree" >&2
  exit 1
fi

# Scenario U: an invalid explicit project dir is caller input, so it must be
# a visible exit-1 error, never a silent skip.
U_STDERR="$TMPROOT/U-stderr"
U_RC=0
(
  cd "$S_FEATURE"
  TOUCHSTONE_DEFAULT_BRANCH=main \
    TOUCHSTONE_CORTEX_HOOK_PROJECT_DIR="$TMPROOT/does-not-exist" \
    bash "$HOOK"
) 2>"$U_STDERR" || U_RC=$?
if [ "$U_RC" != "1" ] || ! grep -q 'not a directory' "$U_STDERR"; then
  echo "FAIL [U]: invalid explicit project dir must fail visibly (rc=$U_RC)" >&2
  cat "$U_STDERR" >&2
  exit 1
fi

# merge-pr.sh must actually wire the resolved default-branch worktree through
# to the hook; without this, the T1.9 journal silently skips in the
# isolated-worktree shipping flow.
if ! grep -q 'TOUCHSTONE_CORTEX_HOOK_PROJECT_DIR' "$TOUCHSTONE_ROOT/scripts/merge-pr.sh"; then
  echo "FAIL [S]: scripts/merge-pr.sh does not pass TOUCHSTONE_CORTEX_HOOK_PROJECT_DIR" >&2
  exit 1
fi

# Scenario V: default-branch resolution is anchored to the TARGET worktree.
# The target repo's default branch is `trunk` (via origin/HEAD symbolic-ref);
# the invocation cwd is a different repo whose default is `main`. A cwd-based
# lookup resolves `main`, mismatches the target's `trunk`, and silently skips
# the journal — the P3 regression from PR #636 review.
V="$TMPROOT/V-target"
mkdir -p "$V"
(
  cd "$V"
  git init -q -b trunk
  git config user.email t@e.co
  git config user.name Test
  : >.keep
  git add .keep
  git commit -q -m "init"
  mkdir -p .cortex
  printf '0.5.0\n' >.cortex/SPEC_VERSION
  printf 'stale state\n' >.cortex/state.md
  git add .cortex/SPEC_VERSION .cortex/state.md
  git commit -q -m "add cortex state"
  git remote add origin "$V"
  git update-ref refs/remotes/origin/trunk trunk
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
)
V_CWD="$(mk_fixture V-elsewhere)"
git -C "$V_CWD" remote add origin "$V_CWD"
git -C "$V_CWD" update-ref refs/remotes/origin/main main
git -C "$V_CWD" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
V_BIN="$TMPROOT/V-bin"
mkdir -p "$V_BIN"
cp "$FAKEBIN/cortex" "$V_BIN/cortex"
cp "$FAKEBIN/sleep" "$V_BIN/sleep"
V_TRUNK_BEFORE="$(git -C "$V" rev-parse trunk)"
(
  cd "$V_CWD"
  # No TOUCHSTONE_DEFAULT_BRANCH override and no gh on PATH: resolution must
  # come from the TARGET's origin/HEAD symbolic-ref, not the cwd repo's.
  PATH="$V_BIN:/usr/bin:/bin" \
    TOUCHSTONE_CORTEX_HOOK_SKIP_PUSH=1 \
    TOUCHSTONE_MERGED_PR=636 \
    TOUCHSTONE_CORTEX_HOOK_PROJECT_DIR="$V" \
    bash "$HOOK"
)
if [ "$(git -C "$V" rev-parse trunk)" != "$V_TRUNK_BEFORE" ]; then
  echo "FAIL [V]: journal moved the target default branch ref" >&2
  exit 1
fi
if [ "$(git -C "$V" branch --show-current)" != "docs/journal-pr-636" ]; then
  echo "FAIL [V]: hook did not resolve the target repo's default branch (trunk)" >&2
  git -C "$V" branch --show-current >&2
  exit 1
fi
if ! git -C "$V" show --name-only --format= HEAD | grep -qx '.cortex/journal/pr-merged.md'; then
  echo "FAIL [V]: journal commit missing in cross-repo target" >&2
  exit 1
fi
if [ "$(git -C "$V_CWD" branch --show-current)" != "main" ]; then
  echo "FAIL [V]: hook disturbed the invocation cwd repo" >&2
  exit 1
fi

echo "==> PASS: cortex-pr-merged-hook activation gates + journal PR landing paths verified (A-V)"
