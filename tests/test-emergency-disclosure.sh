#!/usr/bin/env bash
#
# tests/test-emergency-disclosure.sh — focused contract for the
# emergency-disclosure PreToolUse guard.
#
# The broad differential corpus lives in tests/test-emergency-corpus.sh,
# which runs every fixture under real Bash to decide what the answer should
# be. This file pins the parts of the contract that are about the guard's
# *conversation with the caller* rather than its verdict:
#
#   - benign commands stay allowed, including the classes that once crashed
#     or misclassified (git -C on sibling worktrees, cd-compounds, heredoc
#     commit messages carrying multibyte punctuation)
#   - every protected-push form stays blocked without TOUCHSTONE_EMERGENCY=1
#   - a refusal names what the guard actually read, and never reports a push
#     the command does not contain (issue #507)
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

# The refusal has to be actionable: it must quote the text the guard read.
assert_message_contains() {
  local label="$1" cmd="$2" needle="$3" rc=0
  run_guard "$cmd" || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "expected a refusal to assert its wording ($label): $cmd"
    return
  fi
  if ! grep -qF -- "$needle" "$TEST_DIR/guard-err.txt"; then
    fail "refusal does not name what it saw ($label): expected to find '$needle' in: $(tr '\n' ' ' <"$TEST_DIR/guard-err.txt")"
  fi
}

assert_message_lacks() {
  local label="$1" cmd="$2" needle="$3" rc=0
  run_guard "$cmd" || rc=$?
  if grep -qF -- "$needle" "$TEST_DIR/guard-err.txt"; then
    fail "refusal claims '$needle' about a command that does not contain one ($label): $(tr '\n' ' ' <"$TEST_DIR/guard-err.txt")"
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
# Issue #776: git's builtin list is derived from git, not curated, so a
# read-only builtin behind a cd is not mistaken for a possible push alias.
assert_allowed "cd then git check-ignore" "cd $REPO && git check-ignore -v file.txt"

echo "==> Protected corpus must stay blocked without TOUCHSTONE_EMERGENCY"
# A configured alias means the raw text of "git p --no-verify" contains no
# literal "push" — the early allow must still route git invocations to the
# classifier (PR #665 P1).
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

echo "==> A refusal names what the guard actually read"
# Issue #507: the guard it replaces answered a batch of issue comments with
# "multiple protected push segments require separate audited tool calls",
# naming a category the command never contained. A refusal now has to quote
# the command word and the flag it read, and the multiple-push wording is
# reserved for a command that really runs more than one.
#
# Each needle below is satisfiable by exactly one branch of the guard —
# verified with `grep -cF` against scripts/emergency-disclosure.sh — so an
# assertion cannot be satisfied by a message that happens to look similar.
assert_message_contains "wrapper refusal uses the wrapper wording" \
  "nice -n 5 git push --no-verify origin main" \
  'is not a git invocation, but this call carries'
assert_message_contains "wrapper names itself" \
  "nice -n 5 git push --no-verify origin main" '`nice`'
assert_message_contains "wrapper names the flag" \
  "nice -n 5 git push --no-verify origin main" '`--no-verify`'
assert_message_contains "direct push names the push" \
  "git push --no-verify" 'git push … --no-verify'
assert_message_contains "two pushes are counted honestly" \
  "git push --no-verify origin one; git push --no-verify origin two" \
  'protected pushes; run them as separate audited calls'
assert_message_contains "dynamic push argument names the risk" \
  'git push origin "$branch"' 'is given an argument assembled at runtime'
# A single protected push must never be reported as several.
assert_message_lacks "one push is not several" \
  "git push --no-verify" '2 protected pushes'

echo "==> Quoted data is data: hostile text as an argument is not an invocation"
# Both of these were refused by the guard this replaces, the first with
# "multiple protected push segments" (issue #507, 2026-08-12). Neither
# command invokes git at all.
assert_allowed "issue comments fed from quoted heredocs" "gh issue comment 507 --body \"\$(cat <<'EOF'
The hook refused this call saying it saw multiple protected push segments.
Nothing here invokes git push --no-verify; it is prose about the guard.
EOF
)\"
gh issue comment 634 --body \"\$(cat <<'EOF'
Second finding: the same shape, describing git push --no-verify in prose.
EOF
)\""
assert_allowed "hostile strings as one quoted multi-line argument" "printf '%s\\n' 'git push --no-verify
cd /tmp && git push --no-verify
sudo git push --no-verify'"

echo "==> Composed executables are decoded, not assumed to be git"
# Treating EVERY composed word as git meant a benign \$'cp' "\$src" "\$dst"
# inferred its two variables as the push subcommand and the bypass flag
# (PR #725 review). These run WITHOUT a cwd field, the condition that makes
# the bug reachable.
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

assert_allowed_no_cwd "composed cp, two variables" "\$'cp' \"\$src\" \"\$dst\""
assert_allowed_no_cwd "composed diff, two variables" "\$'diff' \"\$OLD\" \"\$NEW\""
# Both directions pinned: a future narrowing must not fix the false positive by
# dropping the true positive.
assert_blocked_no_cwd "composed git bypass push" "\$'git' push --no-verify"
assert_blocked_no_cwd "plain git bypass push, no cwd" "git push --no-verify"

echo "==> The emergency path authorizes only a push it can attribute"
assert_authorized() {
  local label="$1" cmd="$2" rc=0
  printf '{"tool_input":{"command":%s},"cwd":%s}' \
    "$(printf '%s' "$cmd" | jq -Rs .)" \
    "$(printf '%s' "$REPO" | jq -Rs .)" \
    | (cd "$REPO" && TOUCHSTONE_EMERGENCY=1 bash "$GUARD") \
      >"$TEST_DIR/guard-out.txt" 2>"$TEST_DIR/guard-err.txt" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "authorized push refused ($label, rc=$rc): $(tr '\n' ' ' <"$TEST_DIR/guard-err.txt")"
    return
  fi
  if [ ! -f "$REPO/.touchstone/emergency-bypass.log" ]; then
    fail "authorized push left no audit record ($label)"
  fi
}

assert_authorization_refused() {
  local label="$1" cmd="$2" rc=0
  rm -rf "$REPO/.touchstone"
  printf '{"tool_input":{"command":%s},"cwd":%s}' \
    "$(printf '%s' "$cmd" | jq -Rs .)" \
    "$(printf '%s' "$REPO" | jq -Rs .)" \
    | (cd "$REPO" && TOUCHSTONE_EMERGENCY=1 bash "$GUARD") \
      >"$TEST_DIR/guard-out.txt" 2>"$TEST_DIR/guard-err.txt" || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "authorization granted for an unattributable push ($label): $cmd"
  fi
  if [ -f "$REPO/.touchstone/emergency-bypass.log" ]; then
    fail "refused authorization still wrote an audit record ($label)"
  fi
}

rm -rf "$REPO/.touchstone"
assert_authorized "plain bypass push in this working directory" "git push --no-verify"
# The audit names a repository. A call that changes directory first, or wraps
# the push in another execution context, cannot be attributed — so it is
# refused rather than audited against the wrong repository.
assert_authorization_refused "cd before the push" "cd $REPO && git push --no-verify"
assert_authorization_refused "git -C elsewhere" "git -C $REPO push --no-verify"
assert_authorization_refused "push inside a substitution" "printf '%s' \"\$(git push --no-verify)\""

if [ "$ERRORS" != 0 ]; then
  echo "==> FAIL: $ERRORS emergency-disclosure contract case(s) regressed" >&2
  exit 1
fi
echo "==> PASS: emergency-disclosure allows benign commands, blocks every protected form, and names what it refuses"
