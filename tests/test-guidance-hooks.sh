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
assert "blocks the shortest accepted --no-verify abbreviation" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git push --no-veri origin feat/test")")"
assert "blocks the longer accepted --no-verify abbreviation" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git push --no-verif origin feat/test")")"
assert "blocks ANSI-C quoted --no-verify" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git push \$'--no-verify' origin feat/test")")"
assert "blocks ANSI-C escaped --no-verify" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git push \$'--no-\\x76erify' origin feat/test")")"
git -C "$TMPDIR" config alias.p push
assert "blocks push alias with --no-verify" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git p --no-verify origin feat/test")")"
git -C "$TMPDIR" config alias.ci commit
assert "allows non-push alias with --no-verify" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git ci --no-verify -m wip")")"
assert "keeps scanning after a non-push no-verify command" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git commit --no-verify -m wip; git push --no-verify origin feat/test")")"
assert "finds a confirmed push alias after a non-push no-verify command" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git commit --no-verify -m wip; git p --no-verify origin feat/test")")"
assert "allows multiple confirmed non-push no-verify commands" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git commit --no-verify -m one; git ci --no-verify -m two")")"

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

before_conditional_lines="$(wc -l <"$TMPDIR/.touchstone/emergency-bypass.log" | tr -d ' ')"
EXIT_CONDITIONAL_ALLOWED=0
printf '%s' "$(mkjson "if git push --no-verify origin feat/test; then printf ok; fi")" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_CONDITIONAL_ALLOWED=$?
after_conditional_lines="$(wc -l <"$TMPDIR/.touchstone/emergency-bypass.log" | tr -d ' ')"
if [ "$EXIT_CONDITIONAL_ALLOWED" -eq 0 ] \
  && [ "$after_conditional_lines" -eq $((before_conditional_lines + 1)) ]; then
  echo "  OK: authorized conditional push preserves selected segment context"
  PASS=$((PASS + 1))
else
  echo "  FAIL: authorized conditional push lost selected segment context" >&2
  FAIL=$((FAIL + 1))
fi

# 9. ordinary push (no --no-verify) → allowed
assert "allows ordinary 'git push origin main'" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git push origin main")")"

# 10. unrelated command containing '--no-verify' substring without 'git push'
#     → allowed (the hook should be specific to push)
assert "ignores --no-verify on non-push commands" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "echo --no-verify is a flag")")"
assert "allows ordinary push after unrelated --no-verify argument" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "echo --no-verify; git push origin main")")"
assert "ignores a bypass push inside an unquoted shell comment" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "echo ok # git push --no-verify origin main")")"
COMMENT_THEN_PUSH_COMMAND="$(printf '%s\n' "echo ok # git push --no-verify origin stale" "git push --no-verify origin main")"
assert "still blocks a bypass push after a comment newline" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$COMMENT_THEN_PUSH_COMMAND")")"
assert "preserves a hash inside an ordinary shell word" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "echo value#tag; git push --no-verify origin main")")"

# 11. Documentation and issue bodies may quote the protected command. Text
# inside another command's argument is not an executable push segment.
assert "allows quoted bypass text in another command's argument" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "gh issue create --body 'Run git push --no-verify only in an emergency'")")"

# 12. A real push later in a compound command must still be detected.
assert "blocks executable bypass segment after another command" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "printf 'ready' && git push --no-verify origin feat/test")")"
ARITHMETIC_SHIFT_THEN_PUSH_COMMAND="$(printf '%s\n' 'echo $((1 << 2))' 'git push --no-verify origin feat/test')"
assert "does not treat arithmetic left shift as a heredoc opener" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$ARITHMETIC_SHIFT_THEN_PUSH_COMMAND")")"
ARITHMETIC_COMMAND_THEN_PUSH="$(printf '%s\n' '((value = 1 << 2))' 'git push --no-verify origin feat/test')"
assert "does not treat arithmetic command shift as a heredoc opener" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$ARITHMETIC_COMMAND_THEN_PUSH")")"

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
assert "blocks bypass push in a parenthesized command" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "(git push --no-verify origin feat/test)")")"
assert "blocks sudo-wrapped bypass push" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "sudo git push --no-verify origin feat/test")")"
assert "blocks nice-wrapped bypass push" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "nice -n 5 git push --no-verify origin feat/test")")"
assert "blocks nohup-wrapped bypass push" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "nohup git push --no-verify origin feat/test")")"
assert "blocks bypass push after Git global options" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git --no-pager push --no-verify origin feat/test")")"
assert "blocks a command-scoped Git push alias" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git -c alias.x=push x --no-verify origin feat/test")")"
assert "blocks a Git push alias supplied through --config-env" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "ALIAS=push git --config-env=alias.x=ALIAS x --no-verify origin feat/test")")"
assert "blocks a Git push alias supplied through GIT_CONFIG_COUNT" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.x GIT_CONFIG_VALUE_0=push git x --no-verify origin feat/test")")"
assert "blocks a Git alias lookup under command-scoped HOME" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "HOME=/tmp/alternate-git-home git x --no-verify origin feat/test")")"
assert "blocks bypass push with a quoted git -C path" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'git -C "/tmp/repo with spaces" push --no-verify origin feat/test')")"
assert "blocks emergency push after pushd changes directory" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "pushd /tmp && git push --no-verify origin feat/test")")"
assert "blocks emergency push through env --chdir" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "env --chdir=/tmp git push --no-verify origin feat/test")")"
assert "blocks emergency push through sudo --chdir" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "sudo --chdir=/tmp git push --no-verify origin feat/test")")"
assert "blocks emergency push through chroot" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "chroot /tmp git push --no-verify origin feat/test")")"
EXIT_PUSHD_CONTEXT=0
printf '%s' "$(mkjson "pushd /tmp && git push --no-verify origin feat/test")" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_PUSHD_CONTEXT=$?
assert "emergency override still rejects pushd repository ambiguity" "2" "$EXIT_PUSHD_CONTEXT"
EXIT_ENV_CHDIR_CONTEXT=0
printf '%s' "$(mkjson "env --chdir=/tmp git push --no-verify origin feat/test")" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_ENV_CHDIR_CONTEXT=$?
assert "emergency override still rejects env --chdir ambiguity" "2" "$EXIT_ENV_CHDIR_CONTEXT"
LINE_CONTINUATION_COMMAND="git \\"
LINE_CONTINUATION_COMMAND+=$'\n'
LINE_CONTINUATION_COMMAND+="push --no-verify origin feat/test"
assert "blocks bypass push across a line continuation" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$LINE_CONTINUATION_COMMAND")")"
assert "blocks bypass flag supplied through variable expansion" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'flag=--no-verify; git push "$flag" origin feat/test')")"
assert "blocks git command supplied through variable expansion" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'cmd=git; $cmd push --no-verify origin feat/test')")"
assert "blocks quoted Git executable supplied through environment expansion" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson '"$GIT" push --no-verify origin feat/test')")"
assert "blocks ANSI-C-quoted Git executable" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "\$'git' push --no-verify origin feat/test")")"
assert "blocks a defined Git push alias invoked with the bypass flag" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "shopt -s expand_aliases; alias gp='git push'; gp --no-verify origin feat/test")")"
assert "allows a Git push alias definition that is not invoked" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "alias gp='git push'; echo --no-verify")")"
assert "blocks push subcommand supplied through variable expansion" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'sub=push; git $sub --no-verify origin feat/test')")"
assert "blocks Git executable composed through an expansion" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'g${x}it push --no-verify origin feat/test')")"
assert "blocks path-qualified Git executable composed through an expansion" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson '/usr/bin/g${x}it push --no-verify origin feat/test')")"
assert "blocks push subcommand composed through an expansion" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'git p${x}ush --no-verify origin feat/test')")"
assert "blocks bypass flag composed through command substitution" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'git push --no-$(printf ver)ify origin feat/test')")"
assert "blocks a bypass flag assembled across variable expansions" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'p=--no; q=-verify; git push "$p$q" origin feat/test')")"

# Nested executable contexts must not turn literal-looking text into a bypass.
assert "blocks bypass push in command substitution" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'echo "$(git push --no-verify origin feat/test)"')")"
assert "blocks command substitution after an apostrophe in double quotes" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson $'echo "it\'s $(git push --no-verify origin feat/test)"')")"
assert "blocks bypass push after a nested command substitution" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'echo "$(echo $(date); git push --no-verify origin feat/test)"')")"
assert "blocks bypass push in a shell -c payload" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "sh -c 'git push --no-verify origin feat/test'")")"
assert "blocks bypass push in a sudo-wrapped shell payload" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "sudo sh -c 'git push --no-verify origin feat/test'")")"
assert "blocks bypass push in a nice-wrapped shell payload" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "nice -n 5 bash -lc 'git push --no-verify origin feat/test'")")"
assert "blocks bypass push in a nohup-wrapped shell payload" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "nohup zsh -c 'git push --no-verify origin feat/test'")")"
assert "blocks bypass push in an eval payload" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "eval 'git push --no-verify origin feat/test'")")"
assert "conservatively blocks bypass push in a function body" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "push_later() { git push --no-verify origin feat/test; }; push_later")")"
# Unquoted shell words are conservatively treated as executable text. Literal
# prose remains supported through ordinary single- or double-quoted arguments.
assert "conservatively blocks unquoted bypass words" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "echo if git push --no-verify origin feat/test")")"
assert "allows double-quoted bypass prose" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'gh issue create --body "Run git push --no-verify only in an emergency"')")"
assert "allows literal command-substitution prose in single quotes" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "gh issue create --body 'Example: \$(git push --no-verify)'")")"
HEREDOC_PROSE_COMMAND="$(printf '%s\n' "cat > instructions.md <<'EOF'" "git push --no-verify origin main" "EOF")"
assert "allows bypass prose in a heredoc body" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$HEREDOC_PROSE_COMMAND")")"
UNQUOTED_HEREDOC_PROSE_COMMAND="$(printf '%s\n' "cat > instructions.md <<EOF" "git push --no-verify origin main" "EOF")"
assert "allows literal bypass prose in an unquoted heredoc body" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$UNQUOTED_HEREDOC_PROSE_COMMAND")")"
UNQUOTED_HEREDOC_SUBSTITUTION_COMMAND="$(printf '%s\n' "cat <<EOF" '$(git push --no-verify origin main)' "EOF")"
assert "blocks bypass push in an unquoted heredoc substitution" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$UNQUOTED_HEREDOC_SUBSTITUTION_COMMAND")")"
UNQUOTED_HEREDOC_BACKTICK_COMMAND="$(printf '%s\n' "cat <<EOF" '`git push --no-verify origin main`' "EOF")"
assert "blocks bypass push in an unquoted heredoc backtick substitution" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$UNQUOTED_HEREDOC_BACKTICK_COMMAND")")"
UNQUOTED_HEREDOC_ESCAPED_COMMAND="$(printf '%s\n' "cat <<EOF" '\$(git push --no-verify origin main)' "EOF")"
assert "allows escaped substitution prose in an unquoted heredoc body" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$UNQUOTED_HEREDOC_ESCAPED_COMMAND")")"
UNQUOTED_HEREDOC_UNRELATED_SUBSTITUTION_COMMAND="$(
  printf '%s\n' "cat <<EOF" 'Generated $(date): git push --no-verify origin main' "EOF"
)"
assert "allows literal bypass prose outside an unquoted heredoc substitution" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$UNQUOTED_HEREDOC_UNRELATED_SUBSTITUTION_COMMAND")")"
BACKSLASH_QUOTED_HEREDOC_COMMAND="$(printf '%s\n' 'cat <<\EOF' '$(git push --no-verify origin main)' "EOF")"
assert "allows substitution prose with a backslash-quoted heredoc delimiter" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$BACKSLASH_QUOTED_HEREDOC_COMMAND")")"
PARTIALLY_QUOTED_HEREDOC_COMMAND="$(printf '%s\n' 'cat <<E"OF"' '$(git push --no-verify origin main)' "EOF")"
assert "allows substitution prose with a partially quoted heredoc delimiter" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$PARTIALLY_QUOTED_HEREDOC_COMMAND")")"
HEREDOC_CONTINUED_SUBSTITUTION_COMMAND="$(printf '%s\n' "cat <<EOF" '\' '$(git push --no-verify origin main)' "EOF")"
assert "blocks heredoc substitution after a continued physical line" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$HEREDOC_CONTINUED_SUBSTITUTION_COMMAND")")"
MULTILINE_HEREDOC_SUBSTITUTION_COMMAND="$(
  printf '%s\n' "cat <<EOF" '$(' "git push --no-verify origin main" ')' "EOF"
)"
assert "blocks multiline substitution in an unquoted heredoc" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$MULTILINE_HEREDOC_SUBSTITUTION_COMMAND")")"
HEREDOC_THEN_PUSH_COMMAND="$(printf '%s\n' "cat > instructions.md <<'EOF'" "ordinary prose" "EOF" "git push --no-verify origin main")"
assert "blocks executable bypass push after a heredoc" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$HEREDOC_THEN_PUSH_COMMAND")")"
COMMENTED_HEREDOC_THEN_PUSH_COMMAND="$(printf '%s\n' "# example <<EOF" "git push --no-verify origin main")"
assert "ignores a commented heredoc lookalike before a bypass push" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$COMMENTED_HEREDOC_THEN_PUSH_COMMAND")")"
QUOTED_HEREDOC_THEN_PUSH_COMMAND="$(printf '%s\n' "printf '%s\n' '<<EOF'" "git push --no-verify origin main")"
assert "ignores a quoted heredoc lookalike before a bypass push" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$QUOTED_HEREDOC_THEN_PUSH_COMMAND")")"

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

rm -f "$TMPDIR/.touchstone/emergency-bypass.log" "$EMERGENCY_TARGET/.touchstone/emergency-bypass.log"
MULTIPLE_PUSH_JSON="$(mkjson \
  "git -C $TMPDIR push --no-verify origin one; git -C $EMERGENCY_TARGET push --no-verify origin two" \
  "$TMPDIR")"
EXIT_MULTIPLE_PUSH=0
printf '%s' "$MULTIPLE_PUSH_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_MULTIPLE_PUSH=$?
assert "blocks multiple bypass pushes in one tool call" "2" "$EXIT_MULTIPLE_PUSH"
if [ ! -f "$TMPDIR/.touchstone/emergency-bypass.log" ] \
  && [ ! -f "$EMERGENCY_TARGET/.touchstone/emergency-bypass.log" ]; then
  echo "  OK: rejected multi-push command wrote no partial audit evidence"
  PASS=$((PASS + 1))
else
  echo "  FAIL: rejected multi-push command wrote partial audit evidence" >&2
  FAIL=$((FAIL + 1))
fi
# The relative-workdir fixture below measures an increment from an existing
# audit file. Restore its empty baseline after proving the rejected compound
# command wrote no evidence.
mkdir -p "$EMERGENCY_TARGET/.touchstone"
: >"$EMERGENCY_TARGET/.touchstone/emergency-bypass.log"

GIT_DIR_JSON="$(mkjson \
  "GIT_DIR=$EMERGENCY_TARGET/.git git push --no-verify origin redirected" \
  "$TMPDIR")"
EXIT_GIT_DIR=0
printf '%s' "$GIT_DIR_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_GIT_DIR=$?
assert "blocks emergency push with command-scoped GIT_DIR" "2" "$EXIT_GIT_DIR"
EXIT_INHERITED_GIT_DIR=0
printf '%s' "$(mkjson "git push --no-verify origin redirected" "$TMPDIR")" \
  | GIT_DIR="$EMERGENCY_TARGET/.git" TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" \
    >/dev/null 2>&1 || EXIT_INHERITED_GIT_DIR=$?
assert "blocks emergency push with inherited GIT_DIR" "2" "$EXIT_INHERITED_GIT_DIR"

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

QUOTED_C_TARGET="$TMPDIR/repo with spaces"
mkdir -p "$QUOTED_C_TARGET"
git -C "$QUOTED_C_TARGET" init --quiet --initial-branch=main
QUOTED_GIT_C_JSON="$(mkjson "git -C \"$QUOTED_C_TARGET\" push --no-verify origin feat/test" "$TMPDIR")"
printf '%s' "$QUOTED_GIT_C_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1
if [ -f "$QUOTED_C_TARGET/.touchstone/emergency-bypass.log" ]; then
  echo "  OK: emergency log follows quoted git -C target"
  PASS=$((PASS + 1))
else
  echo "  FAIL: emergency log did not follow quoted git -C target" >&2
  FAIL=$((FAIL + 1))
fi

rm -f "$QUOTED_C_TARGET/.touchstone/emergency-bypass.log"
QUOTED_CD_JSON="$(mkjson "cd \"$QUOTED_C_TARGET\" && git push --no-verify origin feat/test" "$TMPDIR")"
printf '%s' "$QUOTED_CD_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1
if [ -f "$QUOTED_C_TARGET/.touchstone/emergency-bypass.log" ]; then
  echo "  OK: emergency log follows quoted cd target"
  PASS=$((PASS + 1))
else
  echo "  FAIL: emergency log did not follow quoted cd target" >&2
  FAIL=$((FAIL + 1))
fi

rm -f "$EMERGENCY_TARGET/.touchstone/emergency-bypass.log"
COMMAND_CD_JSON="$(mkjson "command cd $EMERGENCY_TARGET && git push --no-verify origin feat/test" "$TMPDIR")"
printf '%s' "$COMMAND_CD_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1
if [ -f "$EMERGENCY_TARGET/.touchstone/emergency-bypass.log" ]; then
  echo "  OK: emergency log follows command-wrapped cd"
  PASS=$((PASS + 1))
else
  echo "  FAIL: emergency log did not follow command-wrapped cd" >&2
  FAIL=$((FAIL + 1))
fi

rm -f "$EMERGENCY_TARGET/.touchstone/emergency-bypass.log"
ASSIGNMENT_CD_JSON="$(mkjson "X=1 cd $EMERGENCY_TARGET && git push --no-verify origin feat/test" "$TMPDIR")"
printf '%s' "$ASSIGNMENT_CD_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1
if [ -f "$EMERGENCY_TARGET/.touchstone/emergency-bypass.log" ]; then
  echo "  OK: emergency log follows assignment-prefixed cd"
  PASS=$((PASS + 1))
else
  echo "  FAIL: emergency log did not follow assignment-prefixed cd" >&2
  FAIL=$((FAIL + 1))
fi

rm -f "$EMERGENCY_TARGET/.touchstone/emergency-bypass.log"
BUILTIN_CD_JSON="$(mkjson "builtin cd $EMERGENCY_TARGET && git push --no-verify origin feat/test" "$TMPDIR")"
printf '%s' "$BUILTIN_CD_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1
if [ -f "$EMERGENCY_TARGET/.touchstone/emergency-bypass.log" ]; then
  echo "  OK: emergency log follows builtin-wrapped cd"
  PASS=$((PASS + 1))
else
  echo "  FAIL: emergency log did not follow builtin-wrapped cd" >&2
  FAIL=$((FAIL + 1))
fi

rm -f "$EMERGENCY_TARGET/.touchstone/emergency-bypass.log"
HOME_CD_JSON="$(mkjson "cd && git push --no-verify origin feat/test" "$TMPDIR")"
printf '%s' "$HOME_CD_JSON" \
  | HOME="$EMERGENCY_TARGET" TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1
if [ -f "$EMERGENCY_TARGET/.touchstone/emergency-bypass.log" ]; then
  echo "  OK: emergency log follows argument-less cd to HOME"
  PASS=$((PASS + 1))
else
  echo "  FAIL: emergency log did not follow argument-less cd to HOME" >&2
  FAIL=$((FAIL + 1))
fi

SUBSHELL_SCOPE_JSON="$(mkjson "(cd $EMERGENCY_TARGET && git status); git push --no-verify origin feat/test" "$TMPDIR")"
EXIT_SUBSHELL_SCOPE=0
printf '%s' "$SUBSHELL_SCOPE_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_SUBSHELL_SCOPE=$?
assert "blocks ambiguous subshell cd even with emergency override" "2" "$EXIT_SUBSHELL_SCOPE"

SCOPED_CD_JSON="$(mkjson "(echo prep; cd $EMERGENCY_TARGET; echo done); git push --no-verify origin feat/test" "$TMPDIR")"
EXIT_SCOPED_CD=0
printf '%s' "$SCOPED_CD_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_SCOPED_CD=$?
assert "blocks cd whose opening subshell is in an earlier segment" "2" "$EXIT_SCOPED_CD"

SKIPPED_CD_JSON="$(mkjson "false && cd $EMERGENCY_TARGET; git push --no-verify origin feat/test" "$TMPDIR")"
EXIT_SKIPPED_CD=0
printf '%s' "$SKIPPED_CD_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_SKIPPED_CD=$?
assert "blocks conditionally skipped cd before an outer push" "2" "$EXIT_SKIPPED_CD"

MULTIPLE_CD_JSON="$(mkjson \
  "cd $EMERGENCY_TARGET && echo ok; false && cd $MAIN_TARGET; git push --no-verify origin feat/test" \
  "$TMPDIR")"
EXIT_MULTIPLE_CD=0
printf '%s' "$MULTIPLE_CD_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_MULTIPLE_CD=$?
assert "blocks multiple conditional cd chains before an emergency push" "2" "$EXIT_MULTIPLE_CD"

CDPATH_PARENT="$(mktemp -d -t touchstone-cdpath-parent.XXXXXX)"
CDPATH_TARGET="$CDPATH_PARENT/cdpath-target"
mkdir -p "$CDPATH_TARGET"
git -C "$CDPATH_TARGET" init --quiet --initial-branch=main
CDPATH_JSON="$(mkjson "cd cdpath-target && git push --no-verify origin feat/test" "$TMPDIR")"
EXIT_CDPATH=0
printf '%s' "$CDPATH_JSON" \
  | CDPATH="$CDPATH_PARENT" TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_CDPATH=$?
assert "blocks relative cd when inherited CDPATH can redirect it" "2" "$EXIT_CDPATH"
rm -rf "$CDPATH_PARENT"

LOCAL_CDPATH_JSON="$(mkjson "CDPATH=$CDPATH_PARENT; cd cdpath-target && git push --no-verify origin feat/test" "$TMPDIR")"
EXIT_LOCAL_CDPATH=0
printf '%s' "$LOCAL_CDPATH_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_LOCAL_CDPATH=$?
assert "blocks relative cd when command sets CDPATH" "2" "$EXIT_LOCAL_CDPATH"

SUBSTITUTION_SCOPE_JSON="$(mkjson "echo \$(cd $EMERGENCY_TARGET && git push --no-verify origin feat/test)" "$TMPDIR")"
EXIT_SUBSTITUTION_SCOPE=0
printf '%s' "$SUBSTITUTION_SCOPE_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_SUBSTITUTION_SCOPE=$?
assert "blocks unquoted command-substitution push with emergency override" "2" "$EXIT_SUBSTITUTION_SCOPE"

UNRELATED_SUBSTITUTION_JSON="$(mkjson 'echo "$(date)"; git push --no-verify origin feat/test' "$TMPDIR")"
EXIT_UNRELATED_SUBSTITUTION=0
printf '%s' "$UNRELATED_SUBSTITUTION_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_UNRELATED_SUBSTITUTION=$?
assert "allows emergency push after unrelated command substitution" "0" "$EXIT_UNRELATED_SUBSTITUTION"

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
