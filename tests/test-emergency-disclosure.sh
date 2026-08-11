#!/usr/bin/env bash
#
# tests/test-emergency-disclosure.sh — differential contract for the
# emergency-disclosure PreToolUse guard (issue #637).
#
# The guard must (a) allow benign commands — including the classes that
# previously crashed or misclassified: git -C on sibling worktrees,
# cd-compounds, heredoc commit messages carrying multibyte punctuation —
# and (b) keep blocking every protected-push form without
# TOUCHSTONE_EMERGENCY=1, including quote-spliced and env-prefixed
# variants. Detection must never get weaker; classification must never
# crash.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$TOUCHSTONE_ROOT/scripts/emergency-disclosure.sh"
TEST_DIR="$(mktemp -d -t touchstone-test-emergency.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0
fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

# Fixture repo so directory-context resolution has something real to inspect.
REPO="$TEST_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@e.co
git -C "$REPO" config user.name Test
: >"$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -qm init

run_guard() {
  # $1 = command text; stdin JSON mirrors the PreToolUse hook protocol.
  local cmd="$1" rc=0
  printf '{"tool_input":{"command":%s},"cwd":%s}' \
    "$(printf '%s' "$cmd" | jq -Rs .)" \
    "$(printf '%s' "$REPO" | jq -Rs .)" \
    | (cd "$REPO" && env -u TOUCHSTONE_EMERGENCY bash "$GUARD") \
      >"$TEST_DIR/guard-out.txt" 2>"$TEST_DIR/guard-err.txt" || rc=$?
  return "$rc"
}

assert_allowed() {
  local label="$1" cmd="$2" rc=0
  run_guard "$cmd" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "benign command blocked ($label, rc=$rc): $cmd"
    sed 's/^/    /' "$TEST_DIR/guard-err.txt" >&2
  fi
  if grep -q 'unbound variable\|multibyte conversion' "$TEST_DIR/guard-err.txt"; then
    fail "classifier crashed on benign command ($label)"
  fi
}

assert_blocked() {
  local label="$1" cmd="$2" rc=0
  run_guard "$cmd" || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "protected push allowed ($label): $cmd"
  fi
  if grep -q 'unbound variable\|multibyte conversion' "$TEST_DIR/guard-err.txt"; then
    fail "classifier crashed on protected command ($label)"
  fi
}

echo "==> Benign corpus must pass without classification crashes"
assert_allowed "git -C status" "git -C $REPO status --short"
assert_allowed "git -C add" "git -C $REPO add file.txt"
assert_allowed "plain status" "git status --short"
assert_allowed "cd compound non-git" "cd $REPO && for t in a b; do echo \$t; done"
assert_allowed "cd compound git add+commit" "cd $REPO && git add file.txt && git commit -m 'msg'"
assert_allowed "heredoc commit with multibyte" "git commit -m \"\$(cat <<'EOF'
fix: harden the check

The split is safe — local scoping applies. Em dashes — twice.
EOF
)\""
assert_allowed "issue body quoting tokens" "gh issue create --body 'mentions git push --no-verify in prose'"
assert_allowed "plain push (hooks run)" "git push"
assert_allowed "push with lease" "git push --force-with-lease=branch:sha origin sha:refs/heads/branch"
# Locale scoping (PR #665): with a global C locale every byte of a
# multibyte letter is a word boundary, so "égit" would tokenize as
# "git" and the fallback predicates would block this benign command.
assert_allowed "multibyte word containing git+push" "python script.py égit push --no-verify-nothing"

echo "==> Protected corpus must stay blocked without TOUCHSTONE_EMERGENCY"
# A configured alias means the raw text of "git p --no-verify" contains no
# literal "push" — the early allow must still route git invocations to the
# parser (PR #665 P1).
git -C "$REPO" config alias.p push
assert_blocked "literal" "git push --no-verify"
assert_blocked "flag order" "git push origin main --no-verify"
assert_blocked "abbreviated flag" "git push --no-verif origin main"
assert_blocked "quote-spliced subcommand" "git pu''sh --no-verify"
assert_blocked "env prefix" "env SKIP=1 git push --no-verify"
assert_blocked "compound tail" "cd $REPO && git push --no-verify"
assert_blocked "variable-assembled flag" 'FLAG=--no-verify; git push $FLAG'
assert_blocked "alias-defined push" "git -c alias.p='push --no-verify' p"
assert_blocked "repo-configured alias push" "git p --no-verify"
assert_blocked "dash-C with literal push" "git -C $REPO push --no-verify"
assert_blocked "cd compound push" "cd $REPO && git commit -m 'x' && git push --no-verify"

# Composed executables — an ANSI-C-quoted word carries its own decoded text.
#
# Treating EVERY composed word as git meant a benign `$'cp' "$src" "$dst"` both
# set seen_git and set the literal anchor, so its two variables were inferred as
# the push subcommand and the bypass flag. The two-variable false-positive class
# therefore survived for any composed executable (PR #725 review).
#
# Both directions are pinned deliberately: a future narrowing must not fix the
# false positive by dropping the true positive.
# These run WITHOUT a cwd field, which is the condition that makes the bug
# reachable. With a resolvable repository context the classifier never needs to
# infer, so the harness above cannot see this class at all — and the guard's
# real-world false positives all occur exactly when context is ambiguous.
run_guard_no_cwd() {
  local cmd="$1" rc=0
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(printf '%s' "$cmd" | jq -Rs .)" \
    | (env -u TOUCHSTONE_EMERGENCY bash "$GUARD") \
      >"$TEST_DIR/guard-out.txt" 2>"$TEST_DIR/guard-err.txt" || rc=$?
  return "$rc"
}

assert_allowed_no_cwd() {
  local label="$1" cmd="$2" rc=0
  run_guard_no_cwd "$cmd" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "benign command blocked with no cwd ($label, rc=$rc): $cmd"
    sed 's/^/    /' "$TEST_DIR/guard-err.txt" >&2
  fi
}

assert_blocked_no_cwd() {
  local label="$1" cmd="$2" rc=0
  run_guard_no_cwd "$cmd" || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "protected push allowed with no cwd ($label): $cmd"
  fi
}

echo "==> Composed executables are decoded, not assumed to be git"
assert_allowed_no_cwd "composed cp, two variables" "\$'cp' \"\$src\" \"\$dst\""
assert_allowed_no_cwd "composed diff, two variables" "\$'diff' \"\$OLD\" \"\$NEW\""
# Both directions pinned: a future narrowing must not fix the false positive by
# dropping the true positive.
assert_blocked_no_cwd "composed git bypass push" "\$'git' push --no-verify"
assert_blocked_no_cwd "plain git bypass push, no cwd" "git push --no-verify"

if [ "$ERRORS" != 0 ]; then
  echo "==> FAIL: $ERRORS emergency-disclosure contract case(s) regressed" >&2
  exit 1
fi
echo "==> PASS: emergency-disclosure allows benign commands and blocks every protected form"
