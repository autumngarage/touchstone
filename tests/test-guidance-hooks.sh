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
ASSIGNMENT_WT_JSON="$(jq -nc \
  --arg cmd "FOO=1 git -C $WORKTREE commit -m 'wip'" \
  --arg cwd "$TMPDIR" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: $cwd}')"
assert "preserves '-C <worktree>' after an assignment prefix" "0" \
  "$(run_hook "$BRANCH_GUARD" "$ASSIGNMENT_WT_JSON")"
ENV_WT_JSON="$(jq -nc \
  --arg cmd "env FOO=1 git -C $WORKTREE commit -m 'wip'" \
  --arg cwd "$TMPDIR" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: $cwd}')"
assert "preserves '-C <worktree>' after an env prefix" "0" \
  "$(run_hook "$BRANCH_GUARD" "$ENV_WT_JSON")"
GIT_DIR_WT_JSON="$(jq -nc \
  --arg cmd "GIT_DIR=$TMPDIR/.git git -C $WORKTREE commit -m 'wip'" \
  --arg cwd "$TMPDIR" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: $cwd}')"
assert "blocks assignment-overridden Git context despite feature '-C'" "2" \
  "$(run_hook "$BRANCH_GUARD" "$GIT_DIR_WT_JSON")"
ENV_GIT_DIR_WT_JSON="$(jq -nc \
  --arg cmd "env GIT_DIR=$TMPDIR/.git git -C $WORKTREE commit -m 'wip'" \
  --arg cwd "$TMPDIR" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: $cwd}')"
assert "blocks env-overridden Git context despite feature '-C'" "2" \
  "$(run_hook "$BRANCH_GUARD" "$ENV_GIT_DIR_WT_JSON")"
FEATURE_GIT_DIR_JSON="$(jq -nc \
  --arg cmd "GIT_DIR=$TMPDIR/.git git commit -m 'wip'" \
  --arg cwd "$WORKTREE" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: $cwd}')"
assert "blocks Git context override from a feature worktree" "2" \
  "$(run_hook "$BRANCH_GUARD" "$FEATURE_GIT_DIR_JSON")"

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
assert "blocks branch-first && compound before git commit on main" "2" \
  "$(run_hook "$BRANCH_GUARD" "$BRANCH_FIRST_COMMIT_JSON")"

BRANCH_FIRST_OR_COMMIT_JSON="$(mkjson "git checkout -b fix/branch-first-or-commit || git commit -m 'wip'")"
assert "blocks branch-first || compound before git commit on main" "2" \
  "$(run_hook "$BRANCH_GUARD" "$BRANCH_FIRST_OR_COMMIT_JSON")"

BRANCH_FIRST_SEMICOLON_COMMIT_JSON="$(mkjson "git checkout -b fix/branch-first-semicolon-commit ; git commit -m 'wip'")"
assert "blocks branch-first semicolon compound before git commit on main" "2" \
  "$(run_hook "$BRANCH_GUARD" "$BRANCH_FIRST_SEMICOLON_COMMIT_JSON")"

BRANCH_ONLY_JSON="$(mkjson "git checkout -b fix/branch-first-split")"
assert "allows branch creation as a separate command on main" "0" \
  "$(run_hook "$BRANCH_GUARD" "$BRANCH_ONLY_JSON")"
git -C "$TMPDIR" checkout --quiet -b fix/branch-first-split
assert "allows a later separate commit command on the feature branch" "0" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson "git commit -m 'wip'")")"
git -C "$TMPDIR" checkout --quiet main

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
# Fast-path encoding bypasses (issue #634)
#
# The fast path runs against the RAW JSON payload, where shell text is
# encoded: a newline is \ + n, a tab is \ + t, and an embedded quote is
# \ + ". A regex that matches the `git ... commit` SHAPE against that text
# false-negatives every spelling below — each exited 0 on main before the
# fix. Fail-closed is the whole contract here: over-blocking is a nuisance,
# under-blocking is the product not working.
#
# Each case must block on main. On a feature branch the same command is
# allowed, which is asserted once at the end so the cases prove the branch
# check still governs rather than a blanket refusal.
# ----------------------------------------------------------------------
git -C "$TMPDIR" checkout --quiet main

assert "blocks a commit that starts on line 2" "2" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson "$(printf 'x=1\ngit commit -m wip')")")"

assert "blocks a commit after a leading newline" "2" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson "$(printf '\ngit commit -m wip')")")"

assert "blocks a commit preceded by a tab" "2" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson "$(printf '\tgit commit -m wip')")")"

assert "blocks a commit split by a line continuation" "2" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson "$(printf 'git \\\n  commit -m wip')")")"

assert "blocks a commit on line 2 of an && compound" "2" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson "$(printf 'echo hi &&\ngit commit -m wip')")")"

assert "blocks a commit carried by eval with embedded quotes" "2" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson 'eval "git commit -m wip"')")"

assert "blocks a commit carried by sh -c with embedded quotes" "2" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson 'sh -c "git commit -m wip"')")"

assert "blocks a commit carried by bash -lc" "2" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson "bash -lc 'git commit -m wip'")")"

assert "blocks a commit wrapped in 'command'" "2" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson 'command git commit -m wip')")"

# A \u escape hides the literal substring while still decoding to `commit`,
# so the fast path must fall through on any \u rather than trusting the
# substring test. The escape has to be a REAL one in the payload — an earlier
# version of this case shipped literal `git commit` text, so it exercised the
# ordinary substring path and would have passed with the \u fallback deleted
# (PR #706 review).
UNICODE_COMMIT_JSON='{"tool_name":"Bash","tool_input":{"command":"git comm\u0069t -m wip"},"cwd":"'"$TMPDIR"'"}'
case "$UNICODE_COMMIT_JSON" in
  *commit*)
    echo "  FAIL: \\u fixture still contains a literal 'commit' — it tests nothing" >&2
    FAIL=$((FAIL + 1))
    ;;
esac
assert "blocks a commit hidden behind a \\u escape" "2" \
  "$(run_hook "$BRANCH_GUARD" "$UNICODE_COMMIT_JSON")"

# Line continuations can split ANY token, so neither `commit` nor `\u` is
# present. Bash removes the backslash-newline entirely, so `git com\<nl>mit`
# and `g\<nl>it commit` both execute as `git commit` (PR #706 review).
assert "blocks a commit whose subcommand is split by a continuation" "2" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson "$(printf 'git com\\\nmit -m wip')")")"

assert "blocks a commit whose 'git' token is split by a continuation" "2" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson "$(printf 'g\\\nit commit -m wip')")")"

# Continuation removal runs before the segment walk, so a QUOTED heredoc whose
# body carries a split `cd` -- text bash passes through untouched -- would
# otherwise be rewritten into a real `cd` line, and the walker would adopt that
# worktree for a commit that actually runs on main (PR #706 review).
# Redirection is the only thing that can WEAKEN this guard, so a heredoc
# anywhere in the command disables it.
HEREDOC_FABRICATED_CD="$(printf 'echo git commit -m prose\ncat <<'"'"'EOF'"'"'\nc\\\nd %s\nEOF\ngit commit -m real' "$WORKTREE")"
assert "heredoc-fabricated cd cannot redirect the guard off main" "2" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson "$HEREDOC_FABRICATED_CD")")"

# ...while an ordinary redirect carrying no heredoc still works.
assert "plain cd redirect to a feature worktree stays allowed" "0" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson "cd $WORKTREE && git commit -m wip")")"

# Single quotes hide a continuation exactly as a heredoc does, so the same
# fabrication works without any `<<` (PR #706 review). The trust rule is now
# about the continuation itself, not the construct carrying it.
SQ_FABRICATED_CD="$(printf "echo '\nc\\\nd %s\n'; git commit -m real" "$WORKTREE")"
assert "single-quoted continuation cannot fabricate a cd redirect" "2" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson "$SQ_FABRICATED_CD")")"

# An explicit -C is read off the commit segment bash will actually run, so it
# is never forged and must survive a heredoc elsewhere in the command.
# Discarding it let a commit explicitly targeting main pass from a feature
# worktree (PR #706 review).
EXPLICIT_C_WITH_HEREDOC="$(printf 'git -C %s commit -m real\ncat <<'"'"'EOF'"'"'\nnote\nEOF' "$TMPDIR")"
# Rounds 4 and 5 pulled -C in opposite directions -- one needed it honoured,
# the other needed it ignored because a heredoc supplied it. Neither fallback
# is right, so an untrustworthy redirect is now refused outright: the target
# cannot be determined, and a guard that cannot tell must not guess.
assert "ambiguous -C plus heredoc is refused, not guessed" "2" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson "$EXPLICIT_C_WITH_HEREDOC" "$WORKTREE")")"

# The encoded spellings must still be ALLOWED off the default branch —
# otherwise the cases above would pass under a guard that blocks everything.
git -C "$TMPDIR" checkout --quiet feat/test
assert "allows a line-2 commit on a feature branch" "0" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson "$(printf 'x=1\ngit commit -m wip')")")"
assert "allows an eval-carried commit on a feature branch" "0" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson 'eval "git commit -m wip"')")"
git -C "$TMPDIR" checkout --quiet main

# `git commit-tree` is plumbing, not a commit to the checked-out branch, and
# must stay allowed even though its text contains the `commit` substring the
# fast path now keys on.
assert "still allows 'git commit-tree' plumbing on main" "0" \
  "$(run_hook "$BRANCH_GUARD" "$(mkjson 'git commit-tree abc123')")"

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
assert "blocks backslash-escaped --no-verify" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git push --no\\-verify origin feat/test")")"
assert "blocks bypass option before an attached redirection" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git push --no-verify>/dev/null")")"
assert "blocks push subcommand before an attached redirection" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git push>/dev/null --no-verify")")"
assert "blocks a protected push after an fd redirection" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git 2>/dev/null push --no-verify")")"
git -C "$TMPDIR" config alias.p push
assert "blocks push alias with --no-verify" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git p --no-verify origin feat/test")")"
git -C "$TMPDIR" config alias.hard-bypass 'push --no-verify'
assert "blocks a Git alias whose expansion contains the bypass flag" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git hard-bypass origin feat/test")")"
git -C "$TMPDIR" config alias.ci commit
assert "allows non-push alias with --no-verify" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git ci --no-verify -m wip")")"
assert "keeps scanning after a non-push no-verify command" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git commit --no-verify -m wip; git push --no-verify origin feat/test")")"
assert "finds a confirmed push alias after a non-push no-verify command" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git commit --no-verify -m wip; git p --no-verify origin feat/test")")"
assert "allows multiple confirmed non-push no-verify commands" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git commit --no-verify -m one; git ci --no-verify -m two")")"
PROTECTED_PUSH_PROSE="mention git push --no""-verify"
assert "treats protected push text in a commit message as data" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git commit -m '$PROTECTED_PUSH_PROSE'")")"
SUBSTITUTION_COMMIT="git commit -m \"\$(git push --no""-verify)\""
assert "blocks protected push substitution in a commit message" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$SUBSTITUTION_COMMIT")")"
BACKTICK_COMMIT="git commit -m \"\`git push --no""-verify\`\""
assert "blocks protected push backticks in a commit message" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$BACKTICK_COMMIT")")"
INPUT_PROCESS_COMMIT="git commit -m <(git push --no""-verify)"
assert "blocks protected input process substitution in a commit argument" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$INPUT_PROCESS_COMMIT")")"
OUTPUT_PROCESS_COMMIT="git commit -m >(git push --no""-verify)"
assert "blocks protected output process substitution in a commit argument" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$OUTPUT_PROCESS_COMMIT")")"
EVEN_BACKSLASH_COMMIT='git commit -m "\\$(git push --no''-verify)"'
assert "blocks protected substitution after an even backslash run" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$EVEN_BACKSLASH_COMMIT")")"

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
assert "blocks a dynamic bypass push after a compound assignment" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'x=gi; x+=t; "$x" push --no-verify origin feat/test')")"
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
assert "blocks Git alias lookup after sudo changes identity and HOME" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "sudo -u deploy -H git ship --no-verify origin feat/test")")"
assert "blocks Git alias lookup under an alternate git-dir" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git --git-dir=/tmp/alternate.git ship --no-verify origin feat/test")")"
assert "blocks Git alias dispatch through an alternate exec-path" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git --exec-path=/tmp ship --no-verify origin feat/test")")"
assert "blocks Git alias lookup through a remote execution wrapper" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "ssh deploy@example.test git ship --no-verify origin feat/test")")"
assert "blocks Git alias lookup through an identity wrapper" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "su deploy -c 'git ship --no-verify origin feat/test'")")"
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
assert "allows a known safe branch supplied through variable expansion" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'branch=feat/test; git push origin "$branch"')")"
assert "blocks a bypass flag formed by brace expansion" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'git push --no-{veri,verify} origin feat/test')")"
assert "blocks a bypass flag formed by pathname expansion" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'git push --no-* origin feat/test')")"
assert "allows a quoted pathname pattern that the shell cannot expand" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git push '--no-*' origin feat/test")")"
assert "blocks a protected push stored in an assigned command string" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "cmd='git push --no-verify'; \$cmd")")"
assert "blocks git command supplied through variable expansion" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'cmd=git; $cmd push --no-verify origin feat/test')")"
assert "blocks quoted Git executable supplied through environment expansion" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson '"$GIT" push --no-verify origin feat/test')")"
assert "blocks ANSI-C-quoted Git executable" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "\$'git' push --no-verify origin feat/test")")"
assert "blocks ANSI-C-quoted Git push subcommand" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git \$'\\x70ush' --no-verify origin feat/test")")"
assert "blocks a defined Git push alias invoked with the bypass flag" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "shopt -s expand_aliases; alias gp='git push'; gp --no-verify origin feat/test")")"
assert "allows a Git push alias definition that is not invoked" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "alias gp='git push'; echo --no-verify")")"
assert "blocks push subcommand supplied through variable expansion" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'sub=push; git $sub --no-verify origin feat/test')")"
assert "blocks Git executable supplied through a positional parameter" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'set -- git; "$1" push --no-verify origin feat/test')")"
assert "blocks push subcommand supplied through a positional parameter" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'set -- push; git "$1" --no-verify origin feat/test')")"
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
assert "blocks subcommand and bypass option emitted by one expansion" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "args='push --no-verify'; git \$args origin feat/test")")"
assert "blocks a full protected invocation split by shell expansions" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'x=; git${IFS}pu${x}sh${IFS}--no-veri${x}fy origin feat/test')")"
EXIT_SPLIT_INVOCATION_OVERRIDE=0
printf '%s' "$(mkjson 'x=; git${IFS}pu${x}sh${IFS}--no-veri${x}fy origin feat/test')" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_SPLIT_INVOCATION_OVERRIDE=$?
assert "emergency override rejects expansion-split protected invocation" "2" \
  "$EXIT_SPLIT_INVOCATION_OVERRIDE"
assert "blocks a Git push alias configured earlier in the command" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git config alias.runtime-push push; git runtime-push --no-verify origin feat/test")")"
assert "blocks a push-forwarding shell function invoked with the bypass" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'git() { command git push "$@"; }; git --no-verify origin feat/test')")"

git -C "$TMPDIR" config alias.chain-start chain-finish
git -C "$TMPDIR" config alias.chain-finish 'push --no-verify'
assert "blocks bypass embedded downstream in a chained Git alias" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git chain-start origin feat/test")")"
git -C "$TMPDIR" config alias.global-chain-start '--no-pager global-chain-finish'
git -C "$TMPDIR" config alias.global-chain-finish 'push --no-verify'
assert "resolves harmless Git global options across an alias chain" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git global-chain-start origin feat/test")")"
git -C "$TMPDIR" config alias.cycle-start cycle-finish
git -C "$TMPDIR" config alias.cycle-finish cycle-start
assert "fails closed on a cyclic Git alias carrying a bypass option" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git cycle-start --no-verify origin feat/test")")"
git -C "$TMPDIR" config alias.shell-echo '!echo "$@"'
assert "allows a non-push shell Git alias with an unrelated bypass argument" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git shell-echo --no-verify")")"
alias_depth=1
while [ "$alias_depth" -lt 17 ]; do
  git -C "$TMPDIR" config "alias.depth-$alias_depth" "depth-$((alias_depth + 1))"
  alias_depth=$((alias_depth + 1))
done
git -C "$TMPDIR" config alias.depth-17 'push --no-verify'
assert "fails closed when a Git alias chain exceeds the resolution bound" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "git depth-1 origin feat/test")")"

# Nested executable contexts must not turn literal-looking text into a bypass.
assert "blocks bypass push in command substitution" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'echo "$(git push --no-verify origin feat/test)"')")"
assert "blocks command substitution after an apostrophe in double quotes" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson $'echo "it\'s $(git push --no-verify origin feat/test)"')")"
assert "blocks bypass push after a nested command substitution" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'echo "$(echo $(date); git push --no-verify origin feat/test)"')")"
assert "blocks bypass push in a shell -c payload" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "sh -c 'git push --no-verify origin feat/test'")")"
assert "allows static bypass prose printed by a shell -c payload" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "bash -c 'echo \"git push --no-verify\"'")")"
assert "blocks a protected xargs pipeline nested in a shell payload" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "bash -c \"printf '%s\\n' --no-verify | xargs git push\"")")"
assert "blocks bypass push in a sudo-wrapped shell payload" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "sudo sh -c 'git push --no-verify origin feat/test'")")"
assert "blocks bypass push in a nice-wrapped shell payload" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "nice -n 5 bash -lc 'git push --no-verify origin feat/test'")")"
assert "blocks bypass push in a nohup-wrapped shell payload" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "nohup zsh -c 'git push --no-verify origin feat/test'")")"
assert "blocks bypass push in an eval payload" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "eval 'git push --no-verify origin feat/test'")")"
assert "blocks bypass push in a trap action" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "trap 'git push --no-verify origin feat/test' EXIT; true")")"
assert "blocks bypass push supplied to shell stdin by a here-string" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "bash <<< 'git push --no-verify origin feat/test'")")"
assert "allows literal bypass prose passed to cat by a here-string" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "cat <<< 'git push --no-verify origin feat/test'")")"
assert "blocks command substitution passed to cat by a here-string" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson 'cat <<< "$(git push --no-verify origin feat/test)"')")"
assert "blocks literal protected prose piped from cat into a shell" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "cat <<< 'git push --no-verify origin feat/test' | bash")")"
SHELL_STDIN_HEREDOC_COMMAND="$(
  printf '%s\n' "bash <<'EOF'" "git push --no-verify origin feat/test" "EOF"
)"
assert "blocks bypass push supplied to shell stdin by a heredoc" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$SHELL_STDIN_HEREDOC_COMMAND")")"
WRAPPED_SHELL_HEADERS=("env bash" "command bash" "sudo bash" "nice -n 5 bash" "nohup bash" "FOO=1 bash")
for wrapped_shell_header in "${WRAPPED_SHELL_HEADERS[@]}"; do
  WRAPPED_SHELL_HEREDOC_COMMAND="$(
    printf '%s\n' "$wrapped_shell_header <<'EOF'" "git push --no-verify origin feat/test" "EOF"
  )"
  assert "blocks bypass heredoc through $wrapped_shell_header" "2" \
    "$(run_hook "$EMERGENCY" "$(mkjson "$WRAPPED_SHELL_HEREDOC_COMMAND")")"
done
IF_SHELL_HEREDOC_COMMAND="$(
  printf '%s\n' "if bash <<'EOF'" "git push --no-verify origin feat/test" "EOF" "then" ":" "fi"
)"
assert "blocks bypass heredoc through an if shell prefix" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$IF_SHELL_HEREDOC_COMMAND")")"
COMPOSED_SHELL_HEREDOC_HEADERS=("b'a'sh" 'ba\sh' "\$'\\x62ash'" '$(printf bash)')
for composed_shell_header in "${COMPOSED_SHELL_HEREDOC_HEADERS[@]}"; do
  COMPOSED_SHELL_HEREDOC_COMMAND="$(
    printf '%s\n' "$composed_shell_header <<'EOF'" "git push --no-verify origin feat/test" "EOF"
  )"
  assert "blocks bypass heredoc through composed consumer $composed_shell_header" "2" \
    "$(run_hook "$EMERGENCY" "$(mkjson "$COMPOSED_SHELL_HEREDOC_COMMAND")")"
done
FUNCTION_SHELL_HEREDOC_COMMAND="$(
  printf '%s\n' 'run_shell(){ bash "$@"; }; run_shell <<'\''EOF'\''' \
    "git push --no-verify origin feat/test" "EOF"
)"
assert "blocks bypass heredoc through a shell function" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$FUNCTION_SHELL_HEREDOC_COMMAND")")"
ALIAS_SHELL_HEREDOC_COMMAND="$(
  printf '%s\n' "shopt -s expand_aliases; alias run_shell=bash; run_shell <<'EOF'" \
    "git push --no-verify origin feat/test" "EOF"
)"
assert "blocks bypass heredoc through a shell alias" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$ALIAS_SHELL_HEREDOC_COMMAND")")"
CAT_SHELL_NAMED_PATH_HEREDOC="$(
  printf '%s\n' "cat > /tmp/bash <<'EOF'" "git push --no-verify origin feat/test" "EOF"
)"
assert "allows protected heredoc prose written to a shell-named path" "0" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$CAT_SHELL_NAMED_PATH_HEREDOC")")"
SOURCE_STDIN_HEREDOC_COMMAND="$(
  printf '%s\n' "source /dev/stdin <<'EOF'" "git push --no-verify origin feat/test" "EOF"
)"
assert "blocks bypass push sourced from a stdin heredoc" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "$SOURCE_STDIN_HEREDOC_COMMAND")")"
assert "blocks protected atoms composed through an xargs pipeline" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "printf '%s\n' --no-verify | xargs git push")")"
assert "blocks a protected script written and executed in one command" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "printf '%s\n' 'git push --no-verify origin feat/test' > /tmp/touchstone-generated.sh; bash /tmp/touchstone-generated.sh")")"
assert "blocks protected code delegated to another interpreter" "2" \
  "$(run_hook "$EMERGENCY" "$(mkjson "awk 'BEGIN { system(\"git push --no-verify origin feat/test\") }'")")"
EXIT_DYNAMIC_OVERRIDE=0
printf '%s' "$(mkjson "trap 'git push --no-verify origin feat/test' EXIT; true")" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_DYNAMIC_OVERRIDE=$?
assert "emergency override rejects a dynamically executed protected push" "2" "$EXIT_DYNAMIC_OVERRIDE"
EXIT_EVAL_DIRECTORY_CONTEXT=0
printf '%s' "$(mkjson "eval 'cd /tmp'; git push --no-verify origin feat/test")" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_EVAL_DIRECTORY_CONTEXT=$?
assert "emergency override rejects repository context after eval" "2" "$EXIT_EVAL_DIRECTORY_CONTEXT"
EXIT_SOURCE_DIRECTORY_CONTEXT=0
printf '%s' "$(mkjson "source /tmp/context.sh; git push --no-verify origin feat/test")" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_SOURCE_DIRECTORY_CONTEXT=$?
assert "emergency override rejects repository context after source" "2" "$EXIT_SOURCE_DIRECTORY_CONTEXT"
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
SELECTED_PUSH_SNAPSHOT_JSON="$(mkjson \
  "git push --no-verify origin protected; cd $EMERGENCY_TARGET; git push origin ordinary" \
  "$TMPDIR")"
EXIT_SELECTED_PUSH_SNAPSHOT=0
printf '%s' "$SELECTED_PUSH_SNAPSHOT_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_SELECTED_PUSH_SNAPSHOT=$?
if [ "$EXIT_SELECTED_PUSH_SNAPSHOT" -eq 0 ] \
  && [ -f "$TMPDIR/.touchstone/emergency-bypass.log" ] \
  && [ ! -f "$EMERGENCY_TARGET/.touchstone/emergency-bypass.log" ]; then
  echo "  OK: selected protected push snapshots its repository context"
  PASS=$((PASS + 1))
else
  echo "  FAIL: later directory context changed the selected push audit repository" >&2
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

for cd_option in -P --; do
  rm -f "$EMERGENCY_TARGET/.touchstone/emergency-bypass.log"
  OPTION_CD_JSON="$(mkjson "cd $cd_option $EMERGENCY_TARGET && git push --no-verify origin feat/test" "$TMPDIR")"
  printf '%s' "$OPTION_CD_JSON" \
    | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1
  if [ -f "$EMERGENCY_TARGET/.touchstone/emergency-bypass.log" ]; then
    echo "  OK: emergency log follows cd $cd_option target"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: emergency log did not follow cd $cd_option target" >&2
    FAIL=$((FAIL + 1))
  fi
done

DASH_CD_TARGET="$TMPDIR/-P"
mkdir -p "$DASH_CD_TARGET"
git -C "$DASH_CD_TARGET" init --quiet --initial-branch=main
DASH_CD_JSON="$(mkjson "cd -- -P && git push --no-verify origin feat/test" "$TMPDIR")"
printf '%s' "$DASH_CD_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1
if [ -f "$DASH_CD_TARGET/.touchstone/emergency-bypass.log" ]; then
  echo "  OK: emergency log follows a dash-prefixed cd target after --"
  PASS=$((PASS + 1))
else
  echo "  FAIL: emergency log did not follow a dash-prefixed cd target after --" >&2
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

LOGICAL_REPO="$TMPDIR/logical-cwd-repo"
PHYSICAL_REPO="$TMPDIR/physical-cwd-repo"
mkdir -p "$LOGICAL_REPO" "$PHYSICAL_REPO/deep"
git -C "$LOGICAL_REPO" init --quiet --initial-branch=main
git -C "$PHYSICAL_REPO" init --quiet --initial-branch=main
ln -s "$PHYSICAL_REPO/deep" "$LOGICAL_REPO/link"
SYMLINK_CD_JSON="$(mkjson "cd .. && git push --no-verify origin feat/test" "$LOGICAL_REPO/link")"
EXIT_SYMLINK_CD=0
printf '%s' "$SYMLINK_CD_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_SYMLINK_CD=$?
assert "blocks relative cd when logical and physical cwd resolution diverge" "2" "$EXIT_SYMLINK_CD"
if [ ! -f "$LOGICAL_REPO/.touchstone/emergency-bypass.log" ] \
  && [ ! -f "$PHYSICAL_REPO/.touchstone/emergency-bypass.log" ]; then
  echo "  OK: ambiguous symlink cd wrote no audit evidence"
  PASS=$((PASS + 1))
else
  echo "  FAIL: ambiguous symlink cd wrote audit evidence to the wrong repository" >&2
  FAIL=$((FAIL + 1))
fi

ABSOLUTE_SYMLINK_CD_JSON="$(
  mkjson "cd $LOGICAL_REPO/link/.. && git push --no-verify origin feat/test" "$TMPDIR"
)"
EXIT_ABSOLUTE_SYMLINK_CD=0
printf '%s' "$ABSOLUTE_SYMLINK_CD_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_ABSOLUTE_SYMLINK_CD=$?
assert "blocks absolute cd when logical and physical resolution diverge" "2" "$EXIT_ABSOLUTE_SYMLINK_CD"

TILDE_TARGET="$TMPDIR/tilde-target"
TILDE_DECOY="$TMPDIR/~"
mkdir -p "$TILDE_TARGET" "$TILDE_DECOY"
git -C "$TILDE_TARGET" init --quiet --initial-branch=main
git -C "$TILDE_DECOY" init --quiet --initial-branch=main
TILDE_CD_JSON="$(mkjson "cd ~ && git push --no-verify origin feat/test" "$TMPDIR")"
EXIT_TILDE_CD=0
printf '%s' "$TILDE_CD_JSON" \
  | HOME="$TILDE_TARGET" TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_TILDE_CD=$?
assert "blocks an expanded cd target" "2" "$EXIT_TILDE_CD"
if [ ! -f "$TILDE_TARGET/.touchstone/emergency-bypass.log" ] \
  && [ ! -f "$TILDE_DECOY/.touchstone/emergency-bypass.log" ]; then
  echo "  OK: expanded cd target wrote no audit evidence"
  PASS=$((PASS + 1))
else
  echo "  FAIL: expanded cd target wrote audit evidence to the wrong repository" >&2
  FAIL=$((FAIL + 1))
fi

GLOB_TARGET="$TMPDIR/repo-real"
GLOB_DECOY="$TMPDIR/__touchstone_shell_expanded__:repo*"
mkdir -p "$GLOB_TARGET" "$GLOB_DECOY"
git -C "$GLOB_TARGET" init --quiet --initial-branch=main
git -C "$GLOB_DECOY" init --quiet --initial-branch=main
GLOB_GIT_C_JSON="$(mkjson "git -C repo* push --no-verify origin feat/test" "$TMPDIR")"
EXIT_GLOB_GIT_C=0
printf '%s' "$GLOB_GIT_C_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1 || EXIT_GLOB_GIT_C=$?
assert "blocks an expanded git -C target" "2" "$EXIT_GLOB_GIT_C"
if [ ! -f "$GLOB_TARGET/.touchstone/emergency-bypass.log" ] \
  && [ ! -f "$GLOB_DECOY/.touchstone/emergency-bypass.log" ]; then
  echo "  OK: expanded git -C target wrote no audit evidence"
  PASS=$((PASS + 1))
else
  echo "  FAIL: expanded git -C target wrote audit evidence to the wrong repository" >&2
  FAIL=$((FAIL + 1))
fi

ZSH_Q_TARGET="$TMPDIR/zsh-q-target"
ZSH_Q_DECOY="$TMPDIR/-q"
mkdir -p "$ZSH_Q_TARGET" "$ZSH_Q_DECOY"
git -C "$ZSH_Q_TARGET" init --quiet --initial-branch=main
git -C "$ZSH_Q_DECOY" init --quiet --initial-branch=main
ZSH_Q_CD_JSON="$(mkjson "cd -q $ZSH_Q_TARGET && git push --no-verify origin feat/test" "$TMPDIR")"
printf '%s' "$ZSH_Q_CD_JSON" \
  | TOUCHSTONE_EMERGENCY=1 bash "$EMERGENCY" >/dev/null 2>&1
if [ -f "$ZSH_Q_TARGET/.touchstone/emergency-bypass.log" ] \
  && [ ! -f "$ZSH_Q_DECOY/.touchstone/emergency-bypass.log" ]; then
  echo "  OK: emergency log skips zsh cd -q and follows its target"
  PASS=$((PASS + 1))
else
  echo "  FAIL: zsh cd -q audit evidence did not follow its target" >&2
  FAIL=$((FAIL + 1))
fi

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

# branch-guard had no such check, so a fix could land in hooks/ and never
# reach the copy projects actually run (found while fixing issue #634).
if cmp -s "$TOUCHSTONE_ROOT/hooks/branch-guard.sh" \
  "$TOUCHSTONE_ROOT/scripts/branch-guard.sh"; then
  echo "  OK: branch-guard hook mirror is current"
  PASS=$((PASS + 1))
else
  echo "  FAIL: branch-guard hook mirror differs" >&2
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

# -----------------------------------------------------------------------------
# Consolidated feature coverage: real-Bash emergency parser differential
# -----------------------------------------------------------------------------
(
  #
  # Differential guardrail for emergency-disclosure shell parsing.
  #
  # Each fixture is evaluated twice:
  #   1. Real Bash executes it with a fake `git` first on PATH. The fake records
  #      protected pushes and their resolved repository but never contacts a
  #      remote or invokes `git push`.
  #   2. The emergency-disclosure hook inspects the same command.
  #
  # The invariant is based on execution, not parser expectations: every protected
  # push observed by Bash must be blocked without authorization. Authorized
  # commands either write evidence to the observed repository or, when explicitly
  # classified as structurally ambiguous, fail closed.
  #
  # Shell snippets are intentionally single-quoted so this harness does not
  # expand them before the isolated Bash oracle does.
  # shellcheck disable=SC2016
  set -euo pipefail

  TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  HOOK="$TOUCHSTONE_ROOT/hooks/emergency-disclosure.sh"
  SCRIPT_MIRROR="$TOUCHSTONE_ROOT/scripts/emergency-disclosure.sh"
  REAL_GIT="$(command -v git)"

  if ! command -v jq >/dev/null 2>&1; then
    echo "==> SKIP: jq not installed"
    exit 0
  fi

  TEST_ROOT="$(mktemp -d -t touchstone-emergency-differential.XXXXXX)"
  trap 'rm -rf "$TEST_ROOT"' EXIT

  REPO_A="$TEST_ROOT/repo-a"
  REPO_B="$TEST_ROOT/repo b"
  FAKE_BIN="$TEST_ROOT/fake-bin"
  ORACLE_LOG="$TEST_ROOT/oracle.log"
  mkdir -p "$REPO_A" "$REPO_B" "$FAKE_BIN"
  REPO_A="$(cd "$REPO_A" && pwd -P)"
  REPO_B="$(cd "$REPO_B" && pwd -P)"

  init_repo() {
    local repo="$1"
    "$REAL_GIT" -C "$repo" init --quiet --initial-branch=main
    "$REAL_GIT" -C "$repo" config user.email "test@touchstone.test"
    "$REAL_GIT" -C "$repo" config user.name "Touchstone Test"
    "$REAL_GIT" -C "$repo" config alias.p push
  }
  init_repo "$REPO_A"
  init_repo "$REPO_B"
  touch "$REPO_A/--no-verify"

  # This is the only `git` visible to oracle commands. It emulates enough global
  # option and alias handling to identify the protected operation, then exits.
  cat >"$FAKE_BIN/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -euo pipefail

target="$PWD"
subcommand=""
command_alias=""
bypass=0
args=("$@")
index=0

if [ "${GIT_CONFIG_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  config_index=0
  while [ "$config_index" -lt "$GIT_CONFIG_COUNT" ]; do
    key_name="GIT_CONFIG_KEY_$config_index"
    value_name="GIT_CONFIG_VALUE_$config_index"
    config_key="${!key_name:-}"
    config_value="${!value_name:-}"
    case "$config_key=$config_value" in
      alias.*=push)
        command_alias="${config_key#alias.}"
        ;;
    esac
    config_index=$((config_index + 1))
  done
fi

while [ "$index" -lt "${#args[@]}" ]; do
  word="${args[$index]}"
  case "$word" in
    -C)
      index=$((index + 1))
      [ "$index" -lt "${#args[@]}" ] || exit 0
      candidate="${args[$index]}"
      if [[ "$candidate" = /* ]]; then
        target="$candidate"
      else
        target="$target/$candidate"
      fi
      ;;
    -c)
      index=$((index + 1))
      [ "$index" -lt "${#args[@]}" ] || exit 0
      case "${args[$index]}" in
        alias.*=push)
          command_alias="${args[$index]#alias.}"
          command_alias="${command_alias%=push}"
          ;;
      esac
      ;;
    --config-env=alias.*=*)
      config_spec="${word#--config-env=}"
      config_key="${config_spec%%=*}"
      env_name="${config_spec#*=}"
      if [ "${!env_name:-}" = "push" ]; then
        command_alias="${config_key#alias.}"
      fi
      ;;
    --no-pager|-P|--paginate|-p|--no-replace-objects|--literal-pathspecs|--no-literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs)
      ;;
    --*)
      ;;
    *)
      subcommand="$word"
      index=$((index + 1))
      break
      ;;
  esac
  index=$((index + 1))
done

if [ "$subcommand" = "p" ]; then
  subcommand="push"
fi
if [ -n "$command_alias" ] && [ "$subcommand" = "$command_alias" ]; then
  subcommand="push"
fi

while [ "$index" -lt "${#args[@]}" ]; do
  case "${args[$index]}" in
    --no-veri | --no-verif | --no-verify) bypass=1 ;;
  esac
  index=$((index + 1))
done

if [ "$subcommand" = "push" ] && [ "$bypass" -eq 1 ]; then
  root="$("$REAL_GIT" -C "$target" rev-parse --show-toplevel 2>/dev/null || true)"
  printf '%s\t%s\n' "$PWD" "$root" >>"$ORACLE_LOG"
fi
exit 0
FAKE_GIT
  chmod +x "$FAKE_BIN/git"

  # Wrapper shims keep historical wrapper fixtures deterministic and prevent
  # privilege changes, process detachment, or host-specific option behavior.
  cat >"$FAKE_BIN/sudo" <<'FAKE_SUDO'
#!/usr/bin/env bash
exec "$@"
FAKE_SUDO
  cat >"$FAKE_BIN/nohup" <<'FAKE_NOHUP'
#!/usr/bin/env bash
exec "$@"
FAKE_NOHUP
  cat >"$FAKE_BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
exit 0
FAKE_GH
  cat >"$FAKE_BIN/nice" <<'FAKE_NICE'
#!/usr/bin/env bash
if [ "${1:-}" = "-n" ]; then
  shift 2
fi
exec "$@"
FAKE_NICE
  chmod +x "$FAKE_BIN/sudo" "$FAKE_BIN/nohup" "$FAKE_BIN/gh" "$FAKE_BIN/nice"

  PASS=0
  FAIL=0
  CASE_COUNT=0

  hook_payload() {
    local command="$1"
    jq -nc \
      --arg command "$command" \
      --arg cwd "$REPO_A" \
      '{tool_name: "Bash", tool_input: {command: $command}, cwd: $cwd}'
  }

  run_hook() {
    local command="$1" authorized="$2" fixture_home="${3:-$HOME}" exit_code=0
    if [ "$authorized" = "1" ]; then
      printf '%s' "$(hook_payload "$command")" \
        | HOME="$fixture_home" GIT=git TOUCHSTONE_EMERGENCY=1 bash "$HOOK" >/dev/null 2>&1 \
        || exit_code=$?
    else
      printf '%s' "$(hook_payload "$command")" \
        | HOME="$fixture_home" GIT=git bash "$HOOK" >/dev/null 2>&1 \
        || exit_code=$?
    fi
    printf '%s' "$exit_code"
  }

  run_oracle() {
    local command="$1" fixture_home="${2:-$HOME}" exit_code=0
    : >"$ORACLE_LOG"
    (
      cd "$REPO_A"
      PATH="$FAKE_BIN:/usr/bin:/bin" \
        HOME="$fixture_home" \
        REAL_GIT="$REAL_GIT" \
        ORACLE_LOG="$ORACLE_LOG" \
        GIT=git \
        bash --noprofile --norc -c "$command"
    ) >/dev/null 2>&1 || exit_code=$?
    printf '%s' "$exit_code"
  }

  record_failure() {
    local name="$1" detail="$2" command="$3"
    echo "  FAIL: $name: $detail" >&2
    printf '        command: %q\n' "$command" >&2
    FAIL=$((FAIL + 1))
  }

  assert_case() {
    local name="$1" classification="$2" command="$3" fixture_home="${4:-$HOME}"
    local oracle_exit oracle_count observed_root unauthorized_exit authorized_exit
    local expected_root="" audit_a=0 audit_b=0

    CASE_COUNT=$((CASE_COUNT + 1))
    rm -rf "$REPO_A/.touchstone" "$REPO_B/.touchstone"
    oracle_exit="$(run_oracle "$command" "$fixture_home")"
    oracle_count="$(wc -l <"$ORACLE_LOG" | tr -d ' ')"
    observed_root=""
    if [ "$oracle_count" -eq 1 ]; then
      observed_root="$(cut -f2 "$ORACLE_LOG")"
    fi

    case "$classification" in
      none)
        if [ "$oracle_count" -ne 0 ]; then
          record_failure "$name" "fixture classified non-executing but Bash observed $oracle_count protected push(es)" "$command"
          return
        fi
        ;;
      repo-a)
        expected_root="$REPO_A"
        ;;
      repo-b)
        expected_root="$REPO_B"
        ;;
      ambiguous)
        if [ "$oracle_count" -eq 0 ]; then
          record_failure "$name" "ambiguous fixture did not execute a protected push" "$command"
          return
        fi
        ;;
      *)
        record_failure "$name" "unknown classification '$classification'" "$command"
        return
        ;;
    esac

    if [ -n "$expected_root" ]; then
      if [ "$oracle_count" -ne 1 ] || [ "$observed_root" != "$expected_root" ]; then
        record_failure "$name" "Bash oracle expected one push in '$expected_root', observed count=$oracle_count root='$observed_root' (exit $oracle_exit)" "$command"
        return
      fi
    elif [ "$classification" = "none" ] && [ "$oracle_exit" -ne 0 ]; then
      record_failure "$name" "non-executing fixture failed under Bash with exit $oracle_exit" "$command"
      return
    fi

    unauthorized_exit="$(run_hook "$command" 0 "$fixture_home")"
    if [ "$oracle_count" -gt 0 ]; then
      if [ "$unauthorized_exit" -ne 2 ]; then
        record_failure "$name" "Bash executed a protected push but unauthorized hook exited $unauthorized_exit" "$command"
        return
      fi
    elif [ "$unauthorized_exit" -ne 0 ]; then
      record_failure "$name" "Bash executed no protected push but hook exited $unauthorized_exit" "$command"
      return
    fi

    authorized_exit="$(run_hook "$command" 1 "$fixture_home")"
    [ -f "$REPO_A/.touchstone/emergency-bypass.log" ] && audit_a=1
    [ -f "$REPO_B/.touchstone/emergency-bypass.log" ] && audit_b=1

    if [ "$classification" = "ambiguous" ]; then
      if [ "$authorized_exit" -ne 2 ] || [ "$audit_a" -ne 0 ] || [ "$audit_b" -ne 0 ]; then
        record_failure "$name" "ambiguous authorized push must fail closed without audit (exit=$authorized_exit audit-a=$audit_a audit-b=$audit_b)" "$command"
        return
      fi
    elif [ "$classification" = "none" ]; then
      if [ "$authorized_exit" -ne 0 ] || [ "$audit_a" -ne 0 ] || [ "$audit_b" -ne 0 ]; then
        record_failure "$name" "non-executing fixture must pass without audit (exit=$authorized_exit audit-a=$audit_a audit-b=$audit_b)" "$command"
        return
      fi
    elif [ "$expected_root" = "$REPO_A" ]; then
      if [ "$authorized_exit" -ne 0 ] || [ "$audit_a" -ne 1 ] || [ "$audit_b" -ne 0 ]; then
        record_failure "$name" "authorized push must audit repo-a only (exit=$authorized_exit audit-a=$audit_a audit-b=$audit_b)" "$command"
        return
      fi
    elif [ "$expected_root" = "$REPO_B" ]; then
      if [ "$authorized_exit" -ne 0 ] || [ "$audit_a" -ne 0 ] || [ "$audit_b" -ne 1 ]; then
        record_failure "$name" "authorized push must audit repo-b only (exit=$authorized_exit audit-a=$audit_a audit-b=$audit_b)" "$command"
        return
      fi
    fi

    echo "  OK: $name"
    PASS=$((PASS + 1))
  }

  echo "==> Named PR #492 review reproductions"

  assert_case "compound-if-condition" repo-a \
    "if git push --no-verify origin main; then printf ok; fi"
  assert_case "time-prefix" repo-a \
    "time -p git push --no-verify origin main"
  assert_case "command-substitution" ambiguous \
    'printf "%s" "$(git push --no-verify origin main)"'
  assert_case "shell-c-payload" ambiguous \
    "bash -c 'git push --no-verify origin main'"
  assert_case "invoked-function" ambiguous \
    "push_now() { git push --no-verify origin main; }; push_now"
  assert_case "sudo-wrapper" ambiguous \
    "sudo git push --no-verify origin main"
  assert_case "nice-wrapper" repo-a \
    "nice -n 5 git push --no-verify origin main"
  assert_case "nohup-wrapper" repo-a \
    "nohup git push --no-verify origin main"
  assert_case "git-global-option" repo-a \
    "git --no-pager push --no-verify origin main"
  assert_case "quoted-git-c" repo-b \
    "git -C \"$REPO_B\" push --no-verify origin main"
  assert_case "preceding-direct-cd" repo-b \
    "cd \"$REPO_B\" && git push --no-verify origin main"
  assert_case "subshell-cd-before-outer-push" ambiguous \
    "(cd \"$REPO_B\" && git status); git push --no-verify origin main"
  assert_case "nested-substitution-cd" ambiguous \
    "printf '%s' \$(cd \"$REPO_B\" && git push --no-verify origin main)"
  assert_case "wrapped-shell-payload" ambiguous \
    "sudo bash -c 'git push --no-verify origin main'"
  line_continuation="git \\"
  line_continuation+=$'\n'
  line_continuation+="push --no-verify origin main"
  assert_case "line-continuation" repo-a "$line_continuation"
  assert_case "apostrophe-in-double-quotes" ambiguous \
    'printf "%s" "it'\''s $(git push --no-verify origin main)"'
  assert_case "nested-command-substitutions" ambiguous \
    'printf "%s" "$(printf "%s" "$(date)"; git push --no-verify origin main)"'
  assert_case "scoped-cd-before-outer-push" ambiguous \
    "(printf prep; cd \"$REPO_B\"; printf done); git push --no-verify origin main"
  assert_case "expanded-bypass-flag" ambiguous \
    'flag=--no-verify; git push "$flag" origin main'
  assert_case "command-local-cdpath" ambiguous \
    "CDPATH=\"$TEST_ROOT\"; cd \"repo b\" && git push --no-verify origin main"
  assert_case "expanded-git-command" ambiguous \
    'cmd=git; "$cmd" push --no-verify origin main'
  assert_case "expanded-push-subcommand" ambiguous \
    'sub=push; git "$sub" --no-verify origin main'
  assert_case "dynamic-git-environment" ambiguous \
    '"$GIT" push --no-verify origin main'
  assert_case "skipped-cd-before-push" ambiguous \
    "false && cd \"$REPO_B\"; git push --no-verify origin main"
  assert_case "literal-quoted-heredoc" none \
    "$(printf '%s\n' "cat >/dev/null <<'EOF'" "git push --no-verify origin main" "EOF")"
  assert_case "literal-unquoted-heredoc" none \
    "$(printf '%s\n' "cat >/dev/null <<EOF" "git push --no-verify origin main" "EOF")"
  assert_case "unquoted-heredoc-substitution" ambiguous \
    "$(printf '%s\n' "cat >/dev/null <<EOF" '$(git push --no-verify origin main)' "EOF")"
  assert_case "parenthesized-push" ambiguous \
    "(git push --no-verify origin main)"
  assert_case "commented-heredoc-lookalike" repo-a \
    "$(printf '%s\n' "# example <<EOF" "git push --no-verify origin main")"
  assert_case "quoted-heredoc-lookalike" repo-a \
    "$(printf '%s\n' "printf '%s' '<<EOF'" "git push --no-verify origin main")"
  assert_case "unrelated-substitution-before-push" repo-a \
    'printf "%s" "$(date)"; git push --no-verify origin main'
  assert_case "arithmetic-left-shift-before-push" repo-a \
    "$(printf '%s\n' "printf '%s' \$((1 << 2))" "git push --no-verify origin main")"
  assert_case "multiple-conditional-directory-chains" ambiguous \
    "cd \"$REPO_B\" && printf ok; false && cd \"$REPO_A\"; git push --no-verify origin main"
  assert_case "git-push-alias" repo-a \
    "git p --no-verify origin main"
  assert_case "unquoted-shell-comment" none \
    "printf ok # git push --no-verify origin main"
  assert_case "command-wrapped-cd" repo-b \
    "command cd \"$REPO_B\" && git push --no-verify origin main"
  assert_case "builtin-wrapped-cd" repo-b \
    "builtin cd \"$REPO_B\" && git push --no-verify origin main"
  ansi_git_command="\$'git' push --no-verify origin main"
  assert_case "ansi-c-quoted-git" repo-a "$ansi_git_command"
  assert_case "argument-less-cd" repo-b \
    "cd && git push --no-verify origin main" "$REPO_B"
  runtime_alias_command="$(printf '%s\n' \
    "shopt -s expand_aliases" \
    "alias gp='git push'" \
    "gp --no-verify origin main")"
  assert_case "runtime-shell-alias" ambiguous "$runtime_alias_command"
  assert_case "non-push-before-literal-push" repo-a \
    "git commit --no-verify -m fixture; git push --no-verify origin main"
  assert_case "non-push-before-git-push-alias" repo-a \
    "git commit --no-verify -m fixture; git p --no-verify origin main"
  assert_case "composed-git-executable" repo-a \
    'g${x}it push --no-verify origin main'
  assert_case "composed-push-subcommand" ambiguous \
    'git p${x}ush --no-verify origin main'
  assert_case "composed-bypass-flag" ambiguous \
    'git push --no-$(printf ver)ify origin main'
  assert_case "abbreviated-bypass-flag-shortest" repo-a \
    "git push --no-veri origin main"
  assert_case "abbreviated-bypass-flag-longer" repo-a \
    "git push --no-verif origin main"
  assert_case "ansi-c-quoted-bypass-flag" repo-a \
    "git push \$'--no-verify' origin main"
  assert_case "ansi-c-escaped-bypass-flag" repo-a \
    "git push \$'--no-\\x76erify' origin main"
  assert_case "backslash-escaped-bypass-flag" repo-a \
    "git push --no\\-verify origin main"
  assert_case "bypass-flag-before-redirection" repo-a \
    "git push --no-verify>/dev/null"
  assert_case "push-subcommand-before-redirection" repo-a \
    "git push>/dev/null --no-verify"
  assert_case "fd-redirection-before-push" repo-a \
    "git 2>/dev/null push --no-verify"
  assert_case "positional-git-executable" repo-a \
    'set -- git; "$1" push --no-verify origin main'
  assert_case "positional-push-subcommand" ambiguous \
    'set -- push; git "$1" --no-verify origin main'
  assert_case "assignment-prefixed-cd" repo-b \
    "X=1 cd \"$REPO_B\" && git push --no-verify origin main"
  assert_case "assembled-variable-bypass-flag" repo-a \
    'p=--no; q=-verify; git push "$p$q" origin main'
  assert_case "multiple-protected-pushes" ambiguous \
    "git -C \"$REPO_A\" push --no-verify origin one; git -C \"$REPO_B\" push --no-verify origin two"
  assert_case "command-scoped-push-alias" ambiguous \
    "git -c alias.x=push x --no-verify origin main"
  assert_case "git-dir-repository-redirection" ambiguous \
    "GIT_DIR=\"$REPO_B/.git\" git push --no-verify origin main"
  assert_case "config-env-push-alias" ambiguous \
    "ALIAS=push git --config-env=alias.x=ALIAS x --no-verify origin main"
  assert_case "git-config-count-push-alias" ambiguous \
    "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.x GIT_CONFIG_VALUE_0=push git x --no-verify origin main"
  assert_case "pushd-repository-redirection" ambiguous \
    "pushd \"$REPO_B\" >/dev/null && git push --no-verify origin main"
  assert_case "env-chdir-repository-redirection" ambiguous \
    "env -C \"$REPO_B\" git push --no-verify origin main"
  assert_case "brace-expanded-bypass-flag" repo-a \
    "git push --no-{veri,verify} origin main"
  assert_case "pathname-expanded-bypass-flag" repo-a \
    "git push --no-* origin main"
  assert_case "eval-directory-redirection" ambiguous \
    "eval 'cd \"$REPO_B\"'; git push --no-verify origin main"

  echo "==> Deterministic generated execution matrix"

  matrix_prefixes=(
    ""
    "command "
    "time -p "
    "sudo "
    "nice -n 1 "
    "nohup "
  )
  matrix_index=0
  for prefix in "${matrix_prefixes[@]}"; do
    matrix_index=$((matrix_index + 1))
    expected="repo-a"
    # Identity-changing wrappers cannot inherit the caller's auditable
    # repository context, even when the wrapped command is otherwise static.
    [ "$prefix" = "sudo " ] && expected="ambiguous"
    assert_case "matrix-prefix-$matrix_index" "$expected" \
      "${prefix}git push --no-verify origin matrix-$matrix_index"
  done

  matrix_index=0
  for global_option in "--no-pager" "-c color.ui=false" "-C \"$REPO_B\""; do
    matrix_index=$((matrix_index + 1))
    expected="repo-a"
    # The hook detects `-c` but deliberately fails closed because its audit
    # resolver does not model config-option arity.
    [ "$matrix_index" -eq 2 ] && expected="ambiguous"
    [ "$matrix_index" -eq 3 ] && expected="repo-b"
    assert_case "matrix-global-option-$matrix_index" "$expected" \
      "git $global_option push --no-verify origin matrix-$matrix_index"
  done

  assert_case "matrix-control-and" repo-a \
    "true && git push --no-verify origin matrix-and"
  assert_case "matrix-control-or" repo-a \
    "false || git push --no-verify origin matrix-or"
  assert_case "matrix-control-group" repo-a \
    "{ git push --no-verify origin matrix-group; }"
  assert_case "matrix-control-subshell" ambiguous \
    "(git push --no-verify origin matrix-subshell)"

  echo "==> Deterministic false-positive matrix"

  assert_case "prose-single-quoted" none \
    "printf '%s' 'git push --no-verify origin main'"
  assert_case "prose-double-quoted" none \
    'printf "%s" "git push --no-verify origin main"'
  assert_case "prose-backticks-inside-single-quoted-cli-body" none \
    'gh issue comment 504 --body '\''Example: `git push --no-verify origin main`'\'''
  assert_case "prose-comment-newline" none \
    "$(printf '%s\n' "printf ok # git push --no-verify origin stale" "printf done")"
  assert_case "prose-escaped-substitution-heredoc" none \
    "$(printf '%s\n' "cat >/dev/null <<EOF" '\$(git push --no-verify origin main)' "EOF")"
  assert_case "prose-quoted-substitution-heredoc" none \
    "$(printf '%s\n' "cat >/dev/null <<'EOF'" '$(git push --no-verify origin main)' "EOF")"

  if cmp -s "$HOOK" "$SCRIPT_MIRROR"; then
    echo "  OK: emergency-disclosure hook mirror is byte-identical"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: emergency-disclosure hook mirror differs" >&2
    FAIL=$((FAIL + 1))
  fi

  echo ""
  if [ "$FAIL" -gt 0 ]; then
    echo "==> FAIL: $FAIL of $((PASS + FAIL)) checks failed"
    exit 1
  fi
  echo "==> OK: all $PASS checks passed across $CASE_COUNT differential fixtures"

)
