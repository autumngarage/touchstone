#!/usr/bin/env bash
#
# tests/test-guidance-hooks.sh — deterministic unit tests for the Claude
# Code guidance hooks (branch-guard, emergency-disclosure).
#
# These tests are the verification primitive for Phase 2 of the guidance-
# effectiveness plan: hooks fire deterministically, so unlike the
# probabilistic principle probes in test-guidance-probes.sh, every
# assertion here either passes or fails the same way every run. The tests
# cover (a) trigger-blocks, (b) non-trigger-passes, (c) emergency-override
# behavior, and (d) a latency budget — hooks add roughly fixed overhead
# to every Bash tool call, so we cap p95 wall time at 100ms over 20
# invocations on a non-matching command (target: 50ms once measured).
#
# Skip with TOUCHSTONE_SKIP_HOOK_TESTS=1 during local iteration. The
# test creates a throwaway git repo under $(mktemp -d) so it never
# touches the working tree it runs from.
#
set -euo pipefail

if [ "${TOUCHSTONE_SKIP_HOOK_TESTS:-0}" = "1" ]; then
  echo "==> SKIP: TOUCHSTONE_SKIP_HOOK_TESTS=1"
  exit 0
fi

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRANCH_GUARD="$TOUCHSTONE_ROOT/hooks/branch-guard.sh"
EMERGENCY="$TOUCHSTONE_ROOT/hooks/emergency-disclosure.sh"

if [ ! -x "$BRANCH_GUARD" ]; then
  echo "FAIL: $BRANCH_GUARD not found or not executable" >&2
  exit 1
fi
if [ ! -x "$EMERGENCY" ]; then
  echo "FAIL: $EMERGENCY not found or not executable" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  # The hooks themselves no-op gracefully without jq, so they remain safe
  # to ship; but tests that exercise the parsed-command path can't
  # distinguish "hook bypassed because no jq" from "hook ran and decided
  # to allow." Skip with a visible message instead of pretending to test.
  echo "==> SKIP: jq not installed (install with 'brew install jq')"
  exit 0
fi

# Throwaway git repo for branch-state assertions. Cleanup on any exit.
TMPDIR="$(mktemp -d -t touchstone-hook-test.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

git -C "$TMPDIR" init --quiet --initial-branch=main
git -C "$TMPDIR" config user.email "test@touchstone.test"
git -C "$TMPDIR" config user.name "Touchstone Test"
echo "seed" >"$TMPDIR/seed.txt"
git -C "$TMPDIR" add seed.txt
git -C "$TMPDIR" commit --quiet -m "seed"

PASS=0
FAIL=0

run_hook() {
  local hook="$1" json="$2"
  local exit_code=0
  printf '%s' "$json" | bash "$hook" >/dev/null 2>&1 || exit_code=$?
  printf '%s' "$exit_code"
}

assert() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  OK: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (expected exit $expected, got $actual)" >&2
    FAIL=$((FAIL + 1))
  fi
}

mkjson() {
  # Build a hook-protocol JSON payload for a Bash tool call.
  local command="$1" cwd="${2:-$TMPDIR}"
  printf '{"tool_name":"Bash","tool_input":{"command":%s},"cwd":%s}' \
    "$(printf '%s' "$command" | jq -Rs .)" \
    "$(printf '%s' "$cwd" | jq -Rs .)"
}

# ----------------------------------------------------------------------
# branch-guard
# ----------------------------------------------------------------------
echo "==> branch-guard"

# 1. git commit on main → blocked
assert "blocks 'git commit' on main" "2" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson "git commit -m 'wip'")")"

# 2. git commit on a feature branch → allowed
git -C "$TMPDIR" checkout --quiet -b feat/test
assert "allows 'git commit' on feature branch" "0" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson "git commit -m 'wip'")")"

# 3. non-matching command → fast-pass (no jq parsing involved)
assert "fast-passes non-git-commit ('ls -la')" "0" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson "ls -la")")"

# 4. master also blocked
git -C "$TMPDIR" checkout --quiet main
git -C "$TMPDIR" branch --quiet master
git -C "$TMPDIR" checkout --quiet master
assert "blocks 'git commit' on master" "2" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson "git commit -m 'wip'")")"

# 5. emergency override allows on main
git -C "$TMPDIR" checkout --quiet main
EXIT_OVERRIDE=0
# NOTE: env var must scope the bash invocation (the consumer), not printf.
printf '%s' "$(mkjson "git commit -m 'wip'")" \
  | TOUCHSTONE_EMERGENCY=1 bash "$BRANCH_GUARD" >/dev/null 2>&1 || EXIT_OVERRIDE=$?
assert "TOUCHSTONE_EMERGENCY=1 allows commit on main" "0" "$EXIT_OVERRIDE"

# 6. lookalike subcommands not blocked (e.g. 'git commit-tree' is plumbing,
#    not a normal-flow commit; we explicitly only match 'git commit\b')
assert "does not match 'git commit-tree' (plumbing)" "0" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson "git commit-tree -p HEAD")")"

# 7. worktree-aware: `git -C <worktree> commit` while the parent agent's
#    cwd is on main but the worktree is on a feature branch — should be
#    allowed. The previous version checked the parent cwd's branch and
#    blocked, forcing operators to use `git -C <path>` as an exploit (the
#    earlier regex didn't match `-C path` between `git` and `commit`,
#    silently bypassing the guard). This test verifies the legitimate
#    parse: the hook follows `-C <path>` to the right repo.
WORKTREE="$(mktemp -d -t touchstone-hook-test-wt.XXXXXX)"
trap 'rm -rf "$TMPDIR" "$WORKTREE"' EXIT
git -C "$TMPDIR" branch --quiet feat/wt-test 2>/dev/null || true
git -C "$TMPDIR" worktree add --quiet "$WORKTREE" feat/wt-test
# Parent cwd is on main; commit targets the feat/wt-test worktree.
git -C "$TMPDIR" checkout --quiet main
WT_JSON="$(jq -nc \
  --arg cmd "git -C $WORKTREE commit -m 'wip'" \
  --arg cwd "$TMPDIR" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: $cwd}')"
assert "allows 'git -C <worktree>' commit when worktree is on a feature branch" "0" \
  "$(run_hook "$BRANCH_GUARD" "$WT_JSON")"

# The command runner's explicit workdir is the execution context. It must
# override the driver session cwd in both directions so the guard neither
# blocks a feature-branch commit nor permits a default-branch commit.
TOOL_WORKDIR_FEATURE_JSON="$(jq -nc \
  --arg cmd "git commit -m 'wip'" \
  --arg workdir "$WORKTREE" \
  --arg cwd "$TMPDIR" \
  '{tool_name: "Bash", tool_input: {command: $cmd, workdir: $workdir}, cwd: $cwd}')"
assert "allows tool workdir commit on feature branch when session cwd is on main" "0" \
  "$(run_hook "$BRANCH_GUARD" "$TOOL_WORKDIR_FEATURE_JSON")"

TOOL_WORKDIR_MAIN_JSON="$(jq -nc \
  --arg cmd "git commit -m 'wip'" \
  --arg workdir "$TMPDIR" \
  --arg cwd "$WORKTREE" \
  '{tool_name: "Bash", tool_input: {command: $cmd, workdir: $workdir}, cwd: $cwd}')"
assert "blocks tool workdir commit on main when session cwd is on feature branch" "2" \
  "$(run_hook "$BRANCH_GUARD" "$TOOL_WORKDIR_MAIN_JSON")"

TOOL_WORKDIR_RELATIVE_JSON="$(jq -nc \
  --arg cmd "git commit -m 'wip'" \
  --arg workdir "$(basename "$WORKTREE")" \
  --arg cwd "$(dirname "$WORKTREE")" \
  '{tool_name: "Bash", tool_input: {command: $cmd, workdir: $workdir}, cwd: $cwd}')"
assert "resolves relative tool workdir from the session cwd" "0" \
  "$(run_hook "$BRANCH_GUARD" "$TOOL_WORKDIR_RELATIVE_JSON")"

PRE_COMMIT_C_JSON="$(jq -nc \
  --arg cmd "git -C $WORKTREE status && git commit -m 'wip'" \
  --arg cwd "$TMPDIR" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: $cwd}')"
assert "blocks 'git -C <feature> status && git commit' on main" "2" \
  "$(run_hook "$BRANCH_GUARD" "$PRE_COMMIT_C_JSON")"

POST_COMMIT_C_JSON="$(jq -nc \
  --arg cmd "git commit -m 'wip' ; git -C $WORKTREE status" \
  --arg cwd "$TMPDIR" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: $cwd}')"
assert "blocks 'git commit; git -C <feature> status' on main" "2" \
  "$(run_hook "$BRANCH_GUARD" "$POST_COMMIT_C_JSON")"

# 8. lowercase -c (config override, not change-directory) must NOT bypass
#    the guard. Regression-guard for case-sensitivity of the -C parsing —
#    if someone writes the regex with [Cc] it will treat
#    `git -c core.editor=foo commit` as "directed at a different repo"
#    and silently allow on main.
assert "lowercase -c (config flag) does not bypass the guard on main" "2" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson "git -c core.editor=foo commit -m 'wip'")")"

# 9. cd <worktree> && git commit — same worktree-aware idea as case 7, but
#    using `cd` instead of `git -C`. Operators and agents both write this
#    shape more naturally. The hook should follow the cd target to the
#    feature-branch worktree and allow the commit.
CD_JSON="$(jq -nc \
  --arg cmd "cd $WORKTREE && git commit -m 'wip'" \
  --arg cwd "$TMPDIR" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: $cwd}')"
assert "allows 'cd <worktree> && git commit' when worktree is on a feature branch" "0" \
  "$(run_hook "$BRANCH_GUARD" "$CD_JSON")"

# 10. cd AFTER the commit must NOT bypass the guard. `git commit; cd
#     <feature-worktree>` is a commit on main followed by an unrelated
#     cd; the cd doesn't affect the commit's cwd, so the guard must
#     still block.
POST_CD_JSON="$(jq -nc \
  --arg cmd "git commit -m 'wip' ; cd $WORKTREE" \
  --arg cwd "$TMPDIR" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: $cwd}')"
assert "blocks 'git commit; cd <feature>' on main (cd after commit is ignored)" "2" \
  "$(run_hook "$BRANCH_GUARD" "$POST_CD_JSON")"

# 11. chained cd — last one before git commit wins (matches `-C` semantics).
#     `cd /tmp && cd <worktree> && git commit` should resolve to the
#     worktree's branch, not /tmp's.
CHAIN_JSON="$(jq -nc \
  --arg cmd "cd /tmp && cd $WORKTREE && git commit -m 'wip'" \
  --arg cwd "$TMPDIR" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: $cwd}')"
assert "chained cd: last cd before commit wins (allows feature-branch commit)" "0" \
  "$(run_hook "$BRANCH_GUARD" "$CHAIN_JSON")"

BRANCH_FIRST_COMMIT_JSON="$(mkjson "git checkout -b fix/branch-first-commit && git commit -m 'wip'")"
assert "allows branch-first compound before git commit on main" "0" \
  "$(run_hook "$BRANCH_GUARD" "$BRANCH_FIRST_COMMIT_JSON")"

BRANCH_FIRST_SWITCH_BACK_JSON="$(mkjson "git checkout -b fix/branch-first-switch-back && git switch main && git commit --no-verify -m 'wip'")"
assert "blocks branch-first compound when later switch returns to main" "2" \
  "$(run_hook "$BRANCH_GUARD" "$BRANCH_FIRST_SWITCH_BACK_JSON")"

BRANCH_FIRST_C_SWITCH_BACK_JSON="$(mkjson "git checkout -b fix/branch-first-c-switch-back && git -C . switch main && git commit --no-verify -m 'wip'")"
assert "blocks branch-first compound when later git -C switch returns to main" "2" \
  "$(run_hook "$BRANCH_GUARD" "$BRANCH_FIRST_C_SWITCH_BACK_JSON")"

BRANCH_FIRST_HEREDOC_JSON="$(mkjson "git checkout -b docs/pe0-walkthrough && cat > /tmp/touchstone-branch-guard-test <<'EOF'
body
EOF")"
assert "allows branch-first compound with heredoc outside repo on main" "0" \
  "$(run_hook "$BRANCH_GUARD" "$BRANCH_FIRST_HEREDOC_JSON")"

MAIN_TARGET="$(mktemp -d -t touchstone-hook-test-main-target.XXXXXX)"
trap 'rm -rf "$TMPDIR" "$WORKTREE" "$MAIN_TARGET"' EXIT
git -C "$MAIN_TARGET" init --quiet --initial-branch=main
git -C "$MAIN_TARGET" config user.email "test@touchstone.test"
git -C "$MAIN_TARGET" config user.name "Touchstone Test"
echo "seed" >"$MAIN_TARGET/seed.txt"
git -C "$MAIN_TARGET" add seed.txt
git -C "$MAIN_TARGET" commit --quiet -m "seed"
BRANCH_FIRST_OTHER_CWD_JSON="$(jq -nc \
  --arg cmd "git checkout -b fix/local-first && git -C $MAIN_TARGET commit -m 'wip'" \
  --arg cwd "$TMPDIR" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: $cwd}')"
assert "blocks branch-first compound when later commit targets another repo on main" "2" \
  "$(run_hook "$BRANCH_GUARD" "$BRANCH_FIRST_OTHER_CWD_JSON")"

# ----------------------------------------------------------------------
# emergency-disclosure
# ----------------------------------------------------------------------
echo "==> emergency-disclosure"

# 7. git push --no-verify without env → blocked
assert "blocks 'git push --no-verify' without TOUCHSTONE_EMERGENCY" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git push --no-verify origin feat/test")")"

# 8. with env var, allowed (and logged)
EXIT_ALLOWED=0
printf '%s' "$(mkjson "git push --no-verify origin feat/test")" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_ALLOWED=$?
assert "TOUCHSTONE_EMERGENCY=1 allows --no-verify push" "0" "$EXIT_ALLOWED"
if [ -f "$TMPDIR/.touchstone/emergency-bypass.log" ]; then
  echo "  OK: emergency-bypass.log written"
  PASS=$((PASS + 1))
else
  echo "  FAIL: emergency-bypass.log not written under $TMPDIR/.touchstone/" >&2
  FAIL=$((FAIL + 1))
fi

# 9. ordinary push (no --no-verify) → allowed
assert "allows ordinary 'git push origin main'" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git push origin main")")"

# 10. unrelated command containing '--no-verify' substring without 'git push'
#     → allowed (the hook should be specific to push)
assert "ignores --no-verify on non-push commands" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "echo --no-verify is a flag")")"

# 11. Documentation and issue bodies may quote the protected command. Text
# inside another command's argument is not an executable push segment.
assert "allows quoted bypass text in another command's argument" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "gh issue create --body 'Run git push --no-verify only in an emergency'")")"

# 12. A real push later in a compound command must still be detected.
assert "blocks executable bypass segment after another command" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "printf 'ready' && git push --no-verify origin feat/test")")"

# Shell reserved words and execution prefixes remain part of the segment after
# control-operator splitting. They must not hide a push in command position.
assert "blocks bypass push in an if condition" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "if git push --no-verify origin feat/test; then echo ok; fi")")"
assert "blocks time-prefixed bypass push" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "time -p git push --no-verify origin feat/test")")"
assert "blocks bypass push in a grouped command" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "{ git push --no-verify origin feat/test; }")")"
assert "blocks bypass push after nested control prefixes" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "while ! git push --no-verify origin feat/test; do sleep 1; done")")"

# Nested executable contexts must not turn literal-looking text into a bypass.
assert "blocks bypass push in command substitution" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'echo "$(git push --no-verify origin feat/test)"')")"
assert "blocks bypass push in a shell -c payload" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "sh -c 'git push --no-verify origin feat/test'")")"
assert "blocks bypass push in an eval payload" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "eval 'git push --no-verify origin feat/test'")")"
assert "conservatively blocks bypass push in a function body" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "push_later() { git push --no-verify origin feat/test; }; push_later")")"
assert "allows unquoted bypass words passed to another command" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "echo if git push --no-verify origin feat/test")")"
assert "allows literal command-substitution prose in single quotes" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "gh issue create --body 'Example: \$(git push --no-verify)'")")"

# 13. Emergency audit evidence belongs to the command runner's workdir, not
# the driver session cwd. Cover absolute and relative workdir forms.
EMERGENCY_TARGET="$(mktemp -d -t touchstone-emergency-target.XXXXXX)"
trap 'rm -rf "$TMPDIR" "$WORKTREE" "$MAIN_TARGET" "$EMERGENCY_TARGET"' EXIT
git -C "$EMERGENCY_TARGET" init --quiet --initial-branch=main
TOOL_WORKDIR_EMERGENCY_JSON="$(jq -nc \
  --arg cmd "git push --no-verify origin feat/test" \
  --arg workdir "$EMERGENCY_TARGET" \
  --arg cwd "$TMPDIR" \
  '{tool_name: "Bash", tool_input: {command: $cmd, workdir: $workdir}, cwd: $cwd}')"
EXIT_TOOL_WORKDIR=0
printf '%s' "$TOOL_WORKDIR_EMERGENCY_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_TOOL_WORKDIR=$?
assert "allows emergency push with explicit tool workdir" "0" "$EXIT_TOOL_WORKDIR"
if [ -f "$EMERGENCY_TARGET/.touchstone/emergency-bypass.log" ]; then
  echo "  OK: emergency log uses absolute tool workdir"
  PASS=$((PASS + 1))
else
  echo "  FAIL: emergency log missing from absolute tool workdir" >&2
  FAIL=$((FAIL + 1))
fi

RELATIVE_TARGET_PARENT="$(dirname "$EMERGENCY_TARGET")"
RELATIVE_TARGET_NAME="$(basename "$EMERGENCY_TARGET")"
TOOL_WORKDIR_RELATIVE_EMERGENCY_JSON="$(jq -nc \
  --arg cmd "git push --no-verify origin feat/test" \
  --arg workdir "$RELATIVE_TARGET_NAME" \
  --arg cwd "$RELATIVE_TARGET_PARENT" \
  '{tool_name: "Bash", tool_input: {command: $cmd, workdir: $workdir}, cwd: $cwd}')"
before_relative_lines="$(wc -l <"$EMERGENCY_TARGET/.touchstone/emergency-bypass.log" | tr -d ' ')"
printf '%s' "$TOOL_WORKDIR_RELATIVE_EMERGENCY_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1
after_relative_lines="$(wc -l <"$EMERGENCY_TARGET/.touchstone/emergency-bypass.log" | tr -d ' ')"
if [ "$after_relative_lines" -eq $((before_relative_lines + 1)) ]; then
  echo "  OK: emergency log resolves relative tool workdir"
  PASS=$((PASS + 1))
else
  echo "  FAIL: relative tool workdir did not receive emergency log entry" >&2
  FAIL=$((FAIL + 1))
fi

# A command-local cd and git -C both change the repository being pushed. Audit
# evidence must follow that target rather than the caller's tool workdir.
rm -f "$EMERGENCY_TARGET/.touchstone/emergency-bypass.log"
CD_EMERGENCY_JSON="$(mkjson "cd $EMERGENCY_TARGET && git push --no-verify origin feat/test" "$TMPDIR")"
printf '%s' "$CD_EMERGENCY_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1
if [ -f "$EMERGENCY_TARGET/.touchstone/emergency-bypass.log" ]; then
  echo "  OK: emergency log follows preceding cd"
  PASS=$((PASS + 1))
else
  echo "  FAIL: emergency log did not follow preceding cd" >&2
  FAIL=$((FAIL + 1))
fi

rm -f "$EMERGENCY_TARGET/.touchstone/emergency-bypass.log"
GIT_C_EMERGENCY_JSON="$(mkjson "git -C $EMERGENCY_TARGET push --no-verify origin feat/test" "$TMPDIR")"
printf '%s' "$GIT_C_EMERGENCY_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1
if [ -f "$EMERGENCY_TARGET/.touchstone/emergency-bypass.log" ]; then
  echo "  OK: emergency log follows git -C target"
  PASS=$((PASS + 1))
else
  echo "  FAIL: emergency log did not follow git -C target" >&2
  FAIL=$((FAIL + 1))
fi

# 14. The bypass must fail closed when required audit evidence cannot be
# persisted. A file at the directory path makes mkdir deterministic.
EMERGENCY_UNWRITABLE="$(mktemp -d -t touchstone-emergency-unwritable.XXXXXX)"
trap 'rm -rf "$TMPDIR" "$WORKTREE" "$MAIN_TARGET" "$EMERGENCY_TARGET" "$EMERGENCY_UNWRITABLE"' EXIT
git -C "$EMERGENCY_UNWRITABLE" init --quiet --initial-branch=main
touch "$EMERGENCY_UNWRITABLE/.touchstone"
UNWRITABLE_JSON="$(mkjson "git push --no-verify origin feat/test" "$EMERGENCY_UNWRITABLE")"
EXIT_UNWRITABLE=0
printf '%s' "$UNWRITABLE_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_UNWRITABLE=$?
assert "blocks emergency bypass when audit log cannot be created" "2" "$EXIT_UNWRITABLE"

# Distributed and project-local hook copies must remain byte-identical.
if cmp -s "$TOUCHSTONE_ROOT/hooks/emergency-disclosure.sh" \
    "$TOUCHSTONE_ROOT/scripts/emergency-disclosure.sh"; then
  echo "  OK: emergency-disclosure hook mirror is current"
  PASS=$((PASS + 1))
else
  echo "  FAIL: emergency-disclosure hook mirror differs" >&2
  FAIL=$((FAIL + 1))
fi

# ----------------------------------------------------------------------
# Latency budget
# ----------------------------------------------------------------------
# Both hooks should add minimal overhead to non-matching Bash calls.
# Steady-state p95 is ~15-25ms (measured idle). The ceiling is 500ms
# because the test runs on pre-push alongside many other pre-commit
# hooks and parallel test suites — hook startup (bash exec + jq parse)
# is sensitive to OS scheduling under load and can spike to 300ms+
# during a heavy pre-push run. 500ms is the regression-detection
# ceiling: a hook that does real work (spawns a subprocess, calls
# network, locks a file) will push p95 well past 1s. 500ms preserves
# the regression-catching value while not flaking under the realistic
# pre-push load profile.
echo "==> latency budget (p95 < 500ms ceiling, 50ms idle target)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP: python3 not available; latency budget not measured"
else
  measure_p95() {
    local hook="$1"
    local json="$2"
    python3 - "$hook" "$json" <<'PY'
import subprocess, sys, time
hook, payload = sys.argv[1], sys.argv[2]
durations = []
for _ in range(20):
    start = time.perf_counter()
    subprocess.run(
        ["bash", hook],
        input=payload.encode(),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    durations.append((time.perf_counter() - start) * 1000)
durations.sort()
p95 = durations[18]                     # 95th of 20 samples (0-indexed 18)
peak = durations[-1]
print(f"p95={p95:.1f}ms peak={peak:.1f}ms")
sys.exit(0 if p95 < 500 else 1)
PY
  }

  NOOP_JSON="$(mkjson "ls")"
  if measure_p95 "$BRANCH_GUARD" "$NOOP_JSON"; then
    echo "  OK: branch-guard p95 within budget"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: branch-guard p95 exceeds 500ms" >&2
    FAIL=$((FAIL + 1))
  fi
  if measure_p95 "$EMERGENCY" "$NOOP_JSON"; then
    echo "  OK: emergency-disclosure p95 within budget"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: emergency-disclosure p95 exceeds 500ms" >&2
    FAIL=$((FAIL + 1))
  fi
fi

# ----------------------------------------------------------------------
echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "==> FAIL: $FAIL of $((PASS + FAIL)) checks failed"
  exit 1
fi
echo "==> OK: all $PASS checks passed"
