#!/usr/bin/env bash
#
# tests/test-emergency-disclosure.sh — the whole contract for the
# emergency-disclosure PreToolUse guard, in two halves.
#
# PART 1, the differential corpus, decides verdicts by EXECUTION. Every
# fixture in tests/fixtures/emergency-corpus.txt is evaluated twice:
#
#   1. Real Bash executes it with a fake `git` first on PATH. The fake
#      records protected pushes (subcommand resolving to push, plus a
#      bypass flag) and the repository they would target. It never contacts
#      a remote and never runs a real push.
#   2. The guard inspects the same command through the PreToolUse hook
#      protocol.
#
# The oracle is execution, not a parser's opinion. That matters because the
# guard this corpus was built for is known to be wrong on some shapes: a
# fixture whose corpus verdict is `allow` but which really executes a
# protected push is a corpus bug and fails hard, so the corpus cannot drift
# into blessing a false negative.
#
# PART 2, the focused contract, pins the guard's *conversation with the
# caller* rather than its verdict:
#
#   - benign commands stay allowed, including the classes that once crashed
#     or misclassified (git -C on sibling worktrees, cd-compounds, heredoc
#     commit messages carrying multibyte punctuation)
#   - every protected-push form stays blocked without TOUCHSTONE_EMERGENCY=1
#   - a refusal names what the guard actually read, and never reports a push
#     the command does not contain (issue #507)
#
# The two halves live in one file on purpose. They assert against the same
# guard, the same fixture shapes and the same authorization expectations, and
# when they were separate files those three things were free to drift apart
# (PR #810 review).
#
# Modes:
#   (no args)   run both halves and assert
#   --report    print the corpus TSV table (label, oracle pushes, oracle repo,
#               unauthorized exit, authorized exit, verdict) and exit 0. Used
#               to record a baseline before changing the guard.
#   --guard P   evaluate an alternative guard implementation at path P, which
#               is how a change is shown to be no weaker than its predecessor
#
# shellcheck disable=SC2016
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$TOUCHSTONE_ROOT/scripts/emergency-disclosure.sh"
HOOK_MIRROR="$TOUCHSTONE_ROOT/hooks/emergency-disclosure.sh"
CORPUS="$TOUCHSTONE_ROOT/tests/fixtures/emergency-corpus.txt"
REPORT_ONLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --report)
      REPORT_ONLY=1
      shift
      ;;
    --guard)
      GUARD="$2"
      shift 2
      ;;
    *)
      echo "usage: $0 [--report] [--guard PATH]" >&2
      exit 64
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "==> SKIP: jq not installed"
  exit 0
fi

TEST_DIR="$(mktemp -d -t touchstone-test-emergency.XXXXXX)"
TEST_ROOT="$(mktemp -d -t touchstone-emergency-corpus.XXXXXX)"
# One trap: a second `trap … EXIT` would replace this one and leak the first
# directory.
trap 'rm -rf "$TEST_DIR" "$TEST_ROOT"' EXIT

ERRORS=0
fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

# =========================================================== PART 1: the corpus
REAL_GIT="$(command -v git)"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"

REPO_A="$TEST_ROOT/repo-a"
REPO_B="$TEST_ROOT/repo b"
FAKE_BIN="$TEST_ROOT/fake-bin"
ORACLE_LOG="$TEST_ROOT/oracle.log"
mkdir -p "$REPO_A" "$REPO_B" "$FAKE_BIN"

init_corpus_repo() {
  local repo="$1"
  "$REAL_GIT" -C "$repo" init --quiet --initial-branch=main
  "$REAL_GIT" -C "$repo" config user.email "test@touchstone.test"
  "$REAL_GIT" -C "$repo" config user.name "Touchstone Test"
  "$REAL_GIT" -C "$repo" config alias.p push
  # Git dequotes an alias value with its own quoting rules before matching it
  # against a command, so this one resolves to `push` even though no whitespace
  # split of the raw value ever produces that word.
  "$REAL_GIT" -C "$repo" config alias.quoted-push "pu'sh'"
  # A `!shell` alias runs a shell, which inherits the invocation's stdin.
  "$REAL_GIT" -C "$repo" config alias.shell-git '!bash'
  : >"$repo/file.txt"
  "$REAL_GIT" -C "$repo" add file.txt
  "$REAL_GIT" -C "$repo" commit --quiet -m init
}
init_corpus_repo "$REPO_A"
init_corpus_repo "$REPO_B"
# Pathname expansion fixture: `git push --no-*` must glob to a real file.
touch "$REPO_A/--no-verify"
# Config-include fixture: a file that contributes an alias when it is pulled in
# by `git -c include.path=<file>` during alias resolution.
printf '%s\n' '[alias]' '	included-push = push' >"$TEST_ROOT/include-alias.cfg"

# The only `git` visible to oracle commands. It recognizes the protected
# operation and records it; it never contacts a remote.
#
# Alias resolution is DELEGATED to real git. An oracle that emulated aliases
# would be one more parser with an opinion, and it was wrong: it could not see
# `alias.x = pu'sh'` (git dequotes the value), an alias contributed by
# `-c include.path=<file>`, or a `!shell` alias consuming stdin — all three
# resolve to a real push under real git, so a hand-rolled table silently
# reported "no push" for shapes that push. Real git answers three questions
# here: does this word name an alias, what does the alias run, and did the
# resolved command reach the `push` builtin (read back from GIT_TRACE).
#
# Delegation is safe because `push` is the only builtin it can reach, no
# repository in this harness has a remote, and GIT_ALLOW_PROTOCOL is closed:
# the push dies at "No configured push destination" before any transport.
cat >"$FAKE_BIN/git" <<'FAKE_GIT'
#!/usr/bin/env bash
# `set -e` is deliberately absent: real git is expected to fail here.
set -uo pipefail

# Self-referential aliases (`alias.x = !git x`) would otherwise recurse until
# the process table fills.
depth="${ORACLE_GIT_DEPTH:-0}"
[ "$depth" -lt 8 ] || exit 0
export ORACLE_GIT_DEPTH=$((depth + 1))

target="$PWD"
subcommand=""
args=("$@")
index=0
pre=()

# Global options precede the subcommand. They are collected verbatim so the
# alias lookup below runs under the exact configuration of this invocation —
# that is what makes `-c include.path=…` and `--config-env=…` visible.
while [ "$index" -lt "${#args[@]}" ]; do
  word="${args[$index]}"
  case "$word" in
    -C | -c | --git-dir | --work-tree | --namespace | --exec-path)
      pre[${#pre[@]}]="$word"
      index=$((index + 1))
      [ "$index" -lt "${#args[@]}" ] || exit 0
      pre[${#pre[@]}]="${args[$index]}"
      if [ "$word" = "-C" ]; then
        candidate="${args[$index]}"
        if [[ "$candidate" = /* ]]; then
          target="$candidate"
        else
          target="$target/$candidate"
        fi
      fi
      ;;
    -*)
      pre[${#pre[@]}]="$word"
      ;;
    *)
      subcommand="$word"
      index=$((index + 1))
      break
      ;;
  esac
  index=$((index + 1))
done

record_push() {
  local root
  root="$(GIT_TRACE= "$REAL_GIT" -C "$target" rev-parse --show-toplevel 2>/dev/null || true)"
  printf '%s\t%s\n' "$PWD" "$root" >>"$ORACLE_LOG"
}

[ -n "$subcommand" ] || exit 0

# `push` is a builtin, and git ignores aliases that shadow builtins.
if [ "$subcommand" = "push" ]; then
  bypass=0
  while [ "$index" -lt "${#args[@]}" ]; do
    case "${args[$index]}" in
      --no-veri | --no-verif | --no-verify) bypass=1 ;;
    esac
    index=$((index + 1))
  done
  [ "$bypass" -eq 1 ] && record_push
  exit 0
fi

# `config` is delegated so a fixture that writes an alias really writes one.
if [ "$subcommand" = "config" ]; then
  exec env GIT_TRACE= "$REAL_GIT" "$@"
fi

# Everything else matters only if real git says it is an alias.
alias_value="$(GIT_TRACE= "$REAL_GIT" ${pre[@]+"${pre[@]}"} config --get "alias.$subcommand" 2>/dev/null || true)"
[ -n "$alias_value" ] || exit 0

# Real git expands the alias and runs it. GIT_TRACE reports the builtin it
# reached, with the argv it reached it with. A `!shell` alias instead runs a
# shell, whose own `git` resolves back to this file and records there.
trace="$(mktemp -t oracle-git-trace.XXXXXX)"
GIT_TRACE="$trace" GIT_ALLOW_PROTOCOL=none "$REAL_GIT" "$@" >/dev/null 2>&1
while IFS= read -r line; do
  case "$line" in
    *"built-in: git push"*)
      case "$line" in
        *--no-veri*) record_push ;;
      esac
      ;;
  esac
done <"$trace"
rm -f "$trace"
exit 0
FAKE_GIT

# Wrapper shims keep wrapper fixtures deterministic and prevent privilege
# changes, process detachment, or host-specific option behavior.
printf '%s\n' '#!/usr/bin/env bash' 'exec "$@"' >"$FAKE_BIN/sudo"
printf '%s\n' '#!/usr/bin/env bash' 'exec "$@"' >"$FAKE_BIN/nohup"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$FAKE_BIN/gh"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "${1:-}" = "-n" ]; then shift 2; fi' 'exec "$@"' >"$FAKE_BIN/nice"
chmod +x "$FAKE_BIN/git" "$FAKE_BIN/sudo" "$FAKE_BIN/nohup" "$FAKE_BIN/gh" "$FAKE_BIN/nice"

# ---------------------------------------------------------------- corpus load
labels=()
commands=()
expects=()
homes=()

load_corpus() {
  local line="" label="" home="" expect="" body="" in_case=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '%%CASE '*)
        label="${line#\%\%CASE }"
        home="repo-a"
        expect=""
        body=""
        in_case=1
        continue
        ;;
      '%%HOME '*)
        [ "$in_case" -eq 1 ] || continue
        home="${line#\%\%HOME }"
        continue
        ;;
      '%%EXPECT '*)
        [ "$in_case" -eq 1 ] || continue
        expect="${line#\%\%EXPECT }"
        continue
        ;;
      '%%END')
        [ "$in_case" -eq 1 ] || continue
        labels[${#labels[@]}]="$label"
        commands[${#commands[@]}]="$body"
        expects[${#expects[@]}]="$expect"
        homes[${#homes[@]}]="$home"
        in_case=0
        continue
        ;;
    esac
    if [ "$in_case" -eq 1 ]; then
      if [ -z "$body" ]; then
        body="$line"
      else
        body="$body
$line"
      fi
    fi
  done <"$CORPUS"
}
load_corpus

# 96 KiB of inert filler, comfortably past the 64 KiB pipe buffer. A guard that
# tests its input with `producer | grep -q` returns 141 on a MATCH at this size
# — grep exits first and the producer takes SIGPIPE — so a matched hostile
# pattern reads as unmatched and the guard fails open. Small fixtures finish
# writing before grep exits, which is why the whole class stayed invisible
# (issue #806).
FILLER="$(awk 'BEGIN { s = ""; while (length(s) < 98304) s = s "filler-text-padding "; print s }')"

substitute() {
  # Placeholders are literal in the corpus so the data file never depends on
  # shell expansion order.
  local text="$1"
  text="${text//%REPO_A%/$REPO_A}"
  text="${text//%REPO_B%/$REPO_B}"
  text="${text//%TEST_ROOT%/$TEST_ROOT}"
  text="${text//%FILLER%/$FILLER}"
  printf '%s' "$text"
}

# ------------------------------------------------------------------ execution
hook_payload() {
  jq -nc --arg command "$1" --arg cwd "$REPO_A" \
    '{tool_name: "Bash", tool_input: {command: $command}, cwd: $cwd}'
}

run_corpus_guard() {
  local command="$1" authorized="$2" fixture_home="$3" exit_code=0
  if [ "$authorized" = "1" ]; then
    hook_payload "$command" \
      | HOME="$fixture_home" GIT=git TOUCHSTONE_EMERGENCY=1 bash "$GUARD" \
        >/dev/null 2>"$TEST_ROOT/guard-err.txt" || exit_code=$?
  else
    hook_payload "$command" \
      | HOME="$fixture_home" GIT=git bash "$GUARD" \
        >/dev/null 2>"$TEST_ROOT/guard-err.txt" || exit_code=$?
  fi
  printf '%s' "$exit_code"
}

run_oracle() {
  local command="$1" fixture_home="$2" exit_code=0
  : >"$ORACLE_LOG"
  (
    cd "$REPO_A" || exit 1
    PATH="$FAKE_BIN:/usr/bin:/bin" \
      HOME="$fixture_home" \
      REAL_GIT="$REAL_GIT" \
      ORACLE_LOG="$ORACLE_LOG" \
      GIT=git \
      bash --noprofile --norc -c "$command"
  ) >/dev/null 2>&1 || exit_code=$?
  printf '%s' "$exit_code"
}

CORPUS_PASS=0
fail_case() {
  echo "  FAIL: $1: $2" >&2
  ERRORS=$((ERRORS + 1))
}

if [ "$REPORT_ONLY" -eq 1 ]; then
  printf 'label\toracle_pushes\toracle_repo\tunauth_exit\tauth_exit\tverdict\n'
else
  echo "==> Differential corpus: real Bash decides, the guard is measured against it"
fi

corpus_index=0
while [ "$corpus_index" -lt "${#labels[@]}" ]; do
  label="${labels[$corpus_index]}"
  expect="${expects[$corpus_index]}"
  command="$(substitute "${commands[$corpus_index]}")"
  fixture_home="$REPO_A"
  [ "${homes[$corpus_index]}" = "repo-b" ] && fixture_home="$REPO_B"
  corpus_index=$((corpus_index + 1))

  rm -rf "$REPO_A/.touchstone" "$REPO_B/.touchstone"
  run_oracle "$command" "$fixture_home" >/dev/null
  oracle_pushes="$(wc -l <"$ORACLE_LOG" | tr -d ' ')"
  oracle_repo="-"
  if [ "$oracle_pushes" -eq 1 ]; then
    oracle_repo="$(cut -f2 "$ORACLE_LOG")"
    case "$oracle_repo" in
      "$REPO_A") oracle_repo="repo-a" ;;
      "$REPO_B") oracle_repo="repo-b" ;;
      "") oracle_repo="none" ;;
    esac
  elif [ "$oracle_pushes" -gt 1 ]; then
    oracle_repo="multi"
  fi

  unauth_exit="$(run_corpus_guard "$command" 0 "$fixture_home")"
  auth_exit="$(run_corpus_guard "$command" 1 "$fixture_home")"

  verdict="allow"
  [ "$unauth_exit" -ne 0 ] && verdict="block"

  if [ "$REPORT_ONLY" -eq 1 ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$label" "$oracle_pushes" "$oracle_repo" "$unauth_exit" "$auth_exit" "$verdict"
    continue
  fi

  if [ -z "$expect" ]; then
    fail_case "$label" "corpus record has no %%EXPECT verdict"
    continue
  fi

  # A corpus that claims `allow` for a command Bash really pushes with would
  # bless a false negative. That is a corpus bug, and it fails hard.
  if [ "$expect" = "allow" ] && [ "$oracle_pushes" -gt 0 ]; then
    fail_case "$label" \
      "corpus says allow but Bash executed $oracle_pushes protected push(es)"
    continue
  fi

  if [ "$expect" = "block" ] && [ "$unauth_exit" -ne 2 ]; then
    fail_case "$label" "expected block (exit 2), guard exited $unauth_exit"
    continue
  fi
  if [ "$expect" = "allow" ] && [ "$unauth_exit" -ne 0 ]; then
    fail_case "$label" "expected allow (exit 0), guard exited $unauth_exit"
    sed 's/^/        /' "$TEST_ROOT/guard-err.txt" >&2
    continue
  fi
  if [ "$expect" = "allow" ] && [ "$auth_exit" -ne 0 ]; then
    fail_case "$label" \
      "expected allow under TOUCHSTONE_EMERGENCY=1, guard exited $auth_exit"
    continue
  fi
  CORPUS_PASS=$((CORPUS_PASS + 1))
done

if [ "$REPORT_ONLY" -eq 1 ]; then
  exit 0
fi

# The hook and the synced script are the same guard; a downstream project that
# gets one of them gets the behavior this corpus just measured.
if cmp -s "$GUARD" "$HOOK_MIRROR"; then
  CORPUS_PASS=$((CORPUS_PASS + 1))
else
  fail_case "hook-mirror" "hooks/emergency-disclosure.sh differs from scripts/"
fi
echo "    $CORPUS_PASS corpus checks passed"

# ================================================== PART 2: the focused contract
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
  echo "==> FAIL: $ERRORS emergency-disclosure case(s) regressed" >&2
  exit 1
fi
echo "==> PASS: $CORPUS_PASS corpus checks against real Bash; emergency-disclosure allows benign commands, blocks every protected form, and names what it refuses"
