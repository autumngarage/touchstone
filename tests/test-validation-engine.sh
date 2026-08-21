#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/scripts/touchstone-run.sh"
COMPAT="$ROOT/scripts/check-legacy-ci.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
assert_contains() { grep -Fq "$2" "$1" || fail "$1 does not contain: $2"; }
assert_not_contains() { ! grep -Fq "$2" "$1" || fail "$1 unexpectedly contains: $2"; }

echo "==> Git-native worktree transactions exclude checkout and fail closed on stale state"
# shellcheck disable=SC1091 # the transaction primitive is the unit under test.
source "$ROOT/scripts/lib/touchstone-worktree-lock.sh"
LOCK_REPO="$TMP_DIR/worktree-lock"
mkdir -p "$LOCK_REPO"
git -C "$LOCK_REPO" init -q -b main
git -C "$LOCK_REPO" config user.name worktree-lock-test
git -C "$LOCK_REPO" config user.email worktree-lock@example.invalid
printf 'base\n' >"$LOCK_REPO/tracked"
git -C "$LOCK_REPO" add tracked
git -C "$LOCK_REPO" commit -qm base
git -C "$LOCK_REPO" switch -qc feat/locked
LOCK_GIT_DIR="$(git -C "$LOCK_REPO" rev-parse --absolute-git-dir)"
LOCK_PATCH="$TMP_DIR/worktree-lock.patch"
printf '%s\n' 'diff --git a/generated b/generated' 'new file mode 100644' \
  '--- /dev/null' '+++ b/generated' '@@ -0,0 +1 @@' '+generated' >"$LOCK_PATCH"

for git_override in GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE; do
  export "$git_override=$TMP_DIR/ambient-git-override"
  lock_status=0
  touchstone_worktree_lock_acquire "$LOCK_REPO" || lock_status=$?
  unset "$git_override"
  [ "$lock_status" -eq "$TOUCHSTONE_WORKTREE_LOCK_REFUSED" ] \
    || fail "$git_override did not refuse the worktree transaction"
  case "$TOUCHSTONE_WORKTREE_LOCK_ERROR" in
    *'ambient Git repository overrides are not supported'*) ;;
    *) fail "$git_override refusal omitted its recovery boundary" ;;
  esac
  [ ! -e "$LOCK_GIT_DIR/index.lock" ] \
    || fail "$git_override refusal created a native index lock"
  [ ! -e "$LOCK_GIT_DIR/touchstone-worktree.lock" ] \
    || fail "$git_override refusal created owner state"
done

touchstone_worktree_lock_acquire "$LOCK_REPO" || fail "$TOUCHSTONE_WORKTREE_LOCK_ERROR"
[ "$LOCK_GIT_DIR/index.lock" -ef "$LOCK_GIT_DIR/touchstone-worktree.lock/token" ] \
  || fail "native index lock is not the owned hard-linked token"
if git -C "$LOCK_REPO" switch main >"$TMP_DIR/locked-switch.out" 2>&1; then
  fail "Git checkout ignored the native worktree transaction lock"
fi
assert_contains "$TMP_DIR/locked-switch.out" 'index.lock'
git -C "$LOCK_REPO" apply "$LOCK_PATCH" || fail "worktree-only apply could not run under the native lock"
[ -f "$LOCK_REPO/generated" ] || fail "worktree-only apply did not write its planned file"
(
  inherited_release_status=0
  touchstone_worktree_lock_release || inherited_release_status=$?
  [ "$inherited_release_status" -eq "$TOUCHSTONE_WORKTREE_LOCK_FAILED" ] \
    || exit 1
) || fail "an inherited subshell could release its parent's native lock"
[ "$LOCK_GIT_DIR/index.lock" -ef "$LOCK_GIT_DIR/touchstone-worktree.lock/token" ] \
  || fail "inherited-subshell release changed the parent's native lock"
touchstone_worktree_lock_release || fail "$TOUCHSTONE_WORKTREE_LOCK_ERROR"
[ ! -e "$LOCK_GIT_DIR/index.lock" ] || fail "release retained the native index lock"
[ ! -e "$LOCK_GIT_DIR/touchstone-worktree.lock" ] || fail "release retained the owner lock"

touchstone_worktree_lock_acquire "$LOCK_REPO" || fail "$TOUCHSTONE_WORKTREE_LOCK_ERROR"
rm -f "$LOCK_GIT_DIR/index.lock"
printf 'foreign replacement\n' >"$LOCK_GIT_DIR/index.lock"
lock_status=0
touchstone_worktree_lock_release || lock_status=$?
[ "$lock_status" -eq "$TOUCHSTONE_WORKTREE_LOCK_FAILED" ] \
  || fail "changed ownership did not fail release"
[ "$(cat "$LOCK_GIT_DIR/index.lock")" = 'foreign replacement' ] \
  || fail "release removed a foreign replacement index lock"
rm -f "$LOCK_GIT_DIR/index.lock" "$LOCK_GIT_DIR/touchstone-worktree.lock/pid" \
  "$LOCK_GIT_DIR/touchstone-worktree.lock/token"
rmdir "$LOCK_GIT_DIR/touchstone-worktree.lock"

mkdir "$LOCK_GIT_DIR/touchstone-worktree.lock"
printf '%s\n' "$$" >"$LOCK_GIT_DIR/touchstone-worktree.lock/pid"
printf 'live\n' >"$LOCK_GIT_DIR/touchstone-worktree.lock/token"
ln "$LOCK_GIT_DIR/touchstone-worktree.lock/token" "$LOCK_GIT_DIR/index.lock"
lock_status=0
touchstone_worktree_lock_acquire "$LOCK_REPO" || lock_status=$?
[ "$lock_status" -eq "$TOUCHSTONE_WORKTREE_LOCK_REFUSED" ] \
  || fail "live-owner refusal used the wrong status"
case "$TOUCHSTONE_WORKTREE_LOCK_ERROR" in
  *"records pid $$"*'may be active or stale'*'verifying no Touchstone mutation is active'*'/pid'*'/token'*'then remove '*) ;;
  *) fail "pre-existing owner refusal omitted the active-or-stale recovery boundary" ;;
esac
rm -f "$LOCK_GIT_DIR/index.lock" "$LOCK_GIT_DIR/touchstone-worktree.lock/pid" \
  "$LOCK_GIT_DIR/touchstone-worktree.lock/token"
rmdir "$LOCK_GIT_DIR/touchstone-worktree.lock"

(
  # Bash 3.2 preserves $$ in a subshell; the primitive must record the actual acquirer.
  touchstone_worktree_lock_acquire "$LOCK_REPO" || exit 1
)
SUBSHELL_OWNER_PID="$(cat "$LOCK_GIT_DIR/touchstone-worktree.lock/pid")"
[ "$SUBSHELL_OWNER_PID" != "$$" ] \
  || fail "subshell acquisition recorded the live parent PID"
if kill -0 "$SUBSHELL_OWNER_PID" 2>/dev/null; then
  fail "subshell acquisition did not record the exited acquiring process"
fi
lock_status=0
touchstone_worktree_lock_acquire "$LOCK_REPO" || lock_status=$?
[ "$lock_status" -eq "$TOUCHSTONE_WORKTREE_LOCK_REFUSED" ] \
  || fail "exited-subshell owner refusal used the wrong status"
case "$TOUCHSTONE_WORKTREE_LOCK_ERROR" in
  *"records pid $SUBSHELL_OWNER_PID"*'may be active or stale'*'verifying no Touchstone mutation is active'*) ;;
  *) fail "exited-subshell refusal omitted bounded recovery guidance" ;;
esac
[ "$LOCK_GIT_DIR/index.lock" -ef "$LOCK_GIT_DIR/touchstone-worktree.lock/token" ] \
  || fail "exited-subshell refusal changed the native lock"
rm -f "$LOCK_GIT_DIR/index.lock" "$LOCK_GIT_DIR/touchstone-worktree.lock/pid" \
  "$LOCK_GIT_DIR/touchstone-worktree.lock/token"
rmdir "$LOCK_GIT_DIR/touchstone-worktree.lock"
touchstone_worktree_lock_acquire "$LOCK_REPO" || fail "$TOUCHSTONE_WORKTREE_LOCK_ERROR"
touchstone_worktree_lock_release || fail "$TOUCHSTONE_WORKTREE_LOCK_ERROR"

printf 'foreign\n' >"$LOCK_GIT_DIR/index.lock"
lock_status=0
touchstone_worktree_lock_acquire "$LOCK_REPO" || lock_status=$?
[ "$lock_status" -eq "$TOUCHSTONE_WORKTREE_LOCK_REFUSED" ] \
  || fail "foreign-lock refusal used the wrong status"
[ "$(cat "$LOCK_GIT_DIR/index.lock")" = foreign ] || fail "foreign Git index lock was changed"
[ ! -e "$LOCK_GIT_DIR/touchstone-worktree.lock" ] || fail "foreign-lock refusal retained owner state"
rm -f "$LOCK_GIT_DIR/index.lock"

mkdir "$LOCK_GIT_DIR/touchstone-worktree.lock"
printf 'residual owner token\n' >"$LOCK_GIT_DIR/touchstone-worktree.lock/token"
lock_status=0
touchstone_worktree_lock_acquire "$LOCK_REPO" || lock_status=$?
[ "$lock_status" -eq "$TOUCHSTONE_WORKTREE_LOCK_REFUSED" ] \
  || fail "ownerless refusal used the wrong status"
case "$TOUCHSTONE_WORKTREE_LOCK_ERROR" in
  *'no verifiable owner'*'preserving any foreign '*'index.lock'*'/pid'*'/token'*'then remove '*) ;;
  *) fail "ownerless refusal omitted residual-file recovery guidance" ;;
esac
rm -f "$LOCK_GIT_DIR/touchstone-worktree.lock/token"
rmdir "$LOCK_GIT_DIR/touchstone-worktree.lock"

write_contract() {
  local dir="$1" command="$2" required="${3:-true}"
  mkdir -p "$dir"
  cat >"$dir/.touchstone.toml" <<EOF
schema = 1
[validation]
runtime = "bash"
[[validation.targets]]
name = "root"
path = "."
[[validation.tasks]]
name = "test"
target = "root"
command = "$command"
required = $required
EOF
}

run_capture() {
  local dir="$1" output="$2"
  shift 2
  set +e
  bash "$RUNNER" validate --project "$dir" "$@" >"$output" 2>"$output.err"
  RUN_STATUS=$?
  set -e
}

echo "==> small declaration runs exactly"
SMALL="$TMP_DIR/small"
write_contract "$SMALL" "printf ran > marker"
run_capture "$SMALL" "$TMP_DIR/small.out"
[ "$RUN_STATUS" -eq 0 ] || fail "small declaration failed"
[ "$(cat "$SMALL/marker")" = ran ] || fail "declared command did not run"
assert_contains "$TMP_DIR/small.out" "ran=1 skipped=0 failed=0"

echo "==> contract-only validation never executes project commands"
CONTRACT_ONLY="$TMP_DIR/contract-only"
write_contract "$CONTRACT_ONLY" "touch command-ran"
awk '{ print; if ($0 == "runtime = \"bash\"") print "setup = \"touch setup-ran\"" }' \
  "$CONTRACT_ONLY/.touchstone.toml" >"$CONTRACT_ONLY/with-setup"
mv "$CONTRACT_ONLY/with-setup" "$CONTRACT_ONLY/.touchstone.toml"
run_capture "$CONTRACT_ONLY" "$TMP_DIR/contract-only.out" --check-contract
[ "$RUN_STATUS" -eq 0 ] || fail "contract-only validation failed"
assert_contains "$TMP_DIR/contract-only.out" "schema-v1 contract is valid"
[ ! -e "$CONTRACT_ONLY/setup-ran" ] || fail "contract check executed setup"
[ ! -e "$CONTRACT_ONLY/command-ran" ] || fail "contract check executed a task"
run_capture "$CONTRACT_ONLY" "$TMP_DIR/contract-only-json.out" --check-contract --json
[ "$RUN_STATUS" -eq 0 ] || fail "JSON contract-only validation failed"
[ "$(cat "$TMP_DIR/contract-only-json.out")" = '{"schema":1,"verdict":"valid","runner":"ubuntu-latest"}' ] \
  || fail "contract-only JSON payload changed"
[ ! -e "$CONTRACT_ONLY/setup-ran" ] || fail "JSON contract check executed setup"
[ ! -e "$CONTRACT_ONLY/command-ran" ] || fail "JSON contract check executed a task"

echo "==> contract-only JSON reports the declared schema number"
V2_REPORT="$TMP_DIR/v2-report"
write_contract "$V2_REPORT" "true"
sed 's/^schema = 1$/schema = 2/' "$V2_REPORT/.touchstone.toml" >"$V2_REPORT/v2" && mv "$V2_REPORT/v2" "$V2_REPORT/.touchstone.toml"
run_capture "$V2_REPORT" "$TMP_DIR/v2-report.out" --check-contract --json
[ "$RUN_STATUS" -eq 0 ] || fail "schema-2 contract-only validation failed"
[ "$(cat "$TMP_DIR/v2-report.out")" = '{"schema":2,"verdict":"valid","runner":"ubuntu-latest"}' ] \
  || fail "schema-2 contract-only JSON did not report schema 2: $(cat "$TMP_DIR/v2-report.out")"

echo "==> a declared runner is reported for the central workflow to schedule on"
RUNNER_DECL="$TMP_DIR/runner-decl"
write_contract "$RUNNER_DECL" "true"
awk '{ print; if ($0 == "runtime = \"bash\"") print "runner = \"macos-15\"" }' \
  "$RUNNER_DECL/.touchstone.toml" >"$RUNNER_DECL/with-runner"
mv "$RUNNER_DECL/with-runner" "$RUNNER_DECL/.touchstone.toml"
run_capture "$RUNNER_DECL" "$TMP_DIR/runner-decl.out" --check-contract --json
[ "$RUN_STATUS" -eq 0 ] || fail "a declared runner was refused"
[ "$(cat "$TMP_DIR/runner-decl.out")" = '{"schema":1,"verdict":"valid","runner":"macos-15"}' ] \
  || fail "declared runner not reported: $(cat "$TMP_DIR/runner-decl.out")"
run_capture "$RUNNER_DECL" "$TMP_DIR/runner-decl-run.out" --json
[ "$RUN_STATUS" -eq 0 ] || fail "validation with a declared runner failed locally"
sed 's/^runner = .*/runner = "not a label!"/' "$RUNNER_DECL/.touchstone.toml" >"$RUNNER_DECL/bad"
mv "$RUNNER_DECL/bad" "$RUNNER_DECL/.touchstone.toml"
run_capture "$RUNNER_DECL" "$TMP_DIR/runner-bad.out" --check-contract
[ "$RUN_STATUS" -ne 0 ] || fail "a malformed runner label was accepted"
assert_contains "$TMP_DIR/runner-bad.out.err" "runner must be a GitHub-hosted runner label"
for label in self-hosted "" "linux-large" "ubuntu" "ubuntu-not a label!" "macos-15;id" "windows-" "ubuntu-Latest" "ubuntu-latest/../x"; do
  sed "s|^runner = .*|runner = \"$label\"|" "$RUNNER_DECL/.touchstone.toml" >"$RUNNER_DECL/bad"
  mv "$RUNNER_DECL/bad" "$RUNNER_DECL/.touchstone.toml"
  run_capture "$RUNNER_DECL" "$TMP_DIR/runner-bad2.out" --check-contract
  [ "$RUN_STATUS" -ne 0 ] || fail "runner label '$label' outside the hosted families was accepted"
done

echo "==> optional undeclared task skips visibly"
cat >>"$SMALL/.touchstone.toml" <<'EOF'
[[validation.tasks]]
name = "build"
target = "root"
required = false
EOF
run_capture "$SMALL" "$TMP_DIR/optional.out"
[ "$RUN_STATUS" -eq 0 ] || fail "optional skip failed validation"
assert_contains "$TMP_DIR/optional.out" "SKIP build (root)"
assert_contains "$TMP_DIR/optional.out" "ran=1 skipped=1 failed=0"

echo "==> required missing commands and nothing-ran fail closed"
REQUIRED="$TMP_DIR/required"
mkdir -p "$REQUIRED"
sed '/command =/d' "$SMALL/.touchstone.toml" >"$REQUIRED/.touchstone.toml"
run_capture "$REQUIRED" "$TMP_DIR/required.out"
[ "$RUN_STATUS" -eq 2 ] || fail "required missing command did not exit 2"
assert_contains "$TMP_DIR/required.out.err" "required task 'test' has no command"

WHITESPACE_REQUIRED="$TMP_DIR/whitespace-required"
write_contract "$WHITESPACE_REQUIRED" "   "
run_capture "$WHITESPACE_REQUIRED" "$TMP_DIR/whitespace-required.out" --json
[ "$RUN_STATUS" -eq 2 ] || fail "whitespace-only required command did not exit 2"
assert_contains "$TMP_DIR/whitespace-required.out.err" "required task 'test' has no command"
assert_contains "$TMP_DIR/whitespace-required.out" '"ran":0'

WHITESPACE_OPTIONAL="$TMP_DIR/whitespace-optional"
write_contract "$WHITESPACE_OPTIONAL" "printf ran > marker"
cat >>"$WHITESPACE_OPTIONAL/.touchstone.toml" <<'EOF'
[[validation.tasks]]
name = "whitespace"
target = "root"
required = false
command = "   "
EOF
run_capture "$WHITESPACE_OPTIONAL" "$TMP_DIR/whitespace-optional.out"
[ "$RUN_STATUS" -eq 0 ] || fail "whitespace-only optional command failed validation"
assert_contains "$TMP_DIR/whitespace-optional.out" "SKIP whitespace (root)"
assert_contains "$TMP_DIR/whitespace-optional.out" "ran=1 skipped=1 failed=0"

OPTIONAL_ONLY="$TMP_DIR/optional-only"
mkdir -p "$OPTIONAL_ONLY"
cat >"$OPTIONAL_ONLY/.touchstone.toml" <<'EOF'
schema = 1
[validation]
runtime = "bash"
[[validation.targets]]
name = "root"
path = "."
[[validation.tasks]]
name = "build"
target = "root"
required = false
EOF
run_capture "$OPTIONAL_ONLY" "$TMP_DIR/nothing.out"
[ "$RUN_STATUS" -eq 1 ] || fail "nothing-ran validation did not fail"
assert_contains "$TMP_DIR/nothing.out.err" "NOTHING RAN"

echo "==> an unstartable command keeps the shell's 126/127 and is labelled as such"
for code in 126 127; do
  UNAVAILABLE="$TMP_DIR/unavailable-$code"
  if [ "$code" -eq 126 ]; then
    write_contract "$UNAVAILABLE" "./not-executable"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$UNAVAILABLE/not-executable"
  else
    write_contract "$UNAVAILABLE" "missing-touchstone-command"
  fi
  run_capture "$UNAVAILABLE" "$TMP_DIR/unavailable-$code.out" --json
  [ "$RUN_STATUS" -eq "$code" ] || fail "unavailable command did not retain $code"
  assert_contains "$TMP_DIR/unavailable-$code.out" '"ran":0'
  assert_contains "$TMP_DIR/unavailable-$code.out" '"reason":"command-not-started"'
  assert_contains "$TMP_DIR/unavailable-$code.out" '"verdict":"failed"'
done

MISSING_INTERPRETER="$TMP_DIR/missing-interpreter"
write_contract "$MISSING_INTERPRETER" "needs-missing-runtime"
printf '#!/missing-touchstone-runtime\nexit 0\n' >"$MISSING_INTERPRETER/needs-missing-runtime"
chmod +x "$MISSING_INTERPRETER/needs-missing-runtime"
PATH="$MISSING_INTERPRETER:$PATH" run_capture \
  "$MISSING_INTERPRETER" "$TMP_DIR/missing-interpreter.out" --json
case "$RUN_STATUS" in 126 | 127) ;; *) fail "missing shebang interpreter did not retain the shell status" ;; esac
assert_contains "$TMP_DIR/missing-interpreter.out" '"reason":"command-not-started"'
assert_contains "$TMP_DIR/missing-interpreter.out" '"verdict":"failed"'

echo "==> any other non-zero exit is command-failed and counts as ran"
OWNED="$TMP_DIR/owned-exit"
write_contract "$OWNED" "bash -c \\\"exit 3\\\""
run_capture "$OWNED" "$TMP_DIR/owned-exit.out" --json
[ "$RUN_STATUS" -eq 3 ] || fail "command-owned exit did not retain 3"
assert_contains "$TMP_DIR/owned-exit.out" '"ran":1'
assert_contains "$TMP_DIR/owned-exit.out" '"reason":"command-failed"'

echo "==> the engine executes the declaration exactly and never predicts startability"
# What a declared command does with its own exit status is the project's
# promise: the engine runs it and reports what the shell returned.
SWALLOWED="$TMP_DIR/swallowed"
write_contract "$SWALLOWED" "missing-touchstone-command || true"
run_capture "$SWALLOWED" "$TMP_DIR/swallowed.out" --json
[ "$RUN_STATUS" -eq 0 ] || fail "a declaration that swallows its own status was second-guessed"
assert_contains "$TMP_DIR/swallowed.out" '"ran":1'
assert_contains "$TMP_DIR/swallowed.out" '"verdict":"passed"'

echo "==> a later passing target cannot launder an earlier failure"
MONOREPO="$TMP_DIR/monorepo"
mkdir -p "$MONOREPO/services/api" "$MONOREPO/services/worker"
cat >"$MONOREPO/.touchstone.toml" <<'EOF'
schema = 1
[validation]
runtime = "bash"
[[validation.targets]]
name = "api"
path = "services/api"
[[validation.targets]]
name = "worker"
path = "services/worker"
[[validation.tasks]]
name = "api-test"
target = "api"
command = "exit 9"
required = true
[[validation.tasks]]
name = "worker-test"
target = "worker"
command = "printf pass > passed"
required = true
EOF
run_capture "$MONOREPO" "$TMP_DIR/monorepo.out" --json
[ "$RUN_STATUS" -eq 9 ] || fail "later target laundered exit 9"
[ -f "$MONOREPO/services/worker/passed" ] || fail "later target did not run"
assert_contains "$TMP_DIR/monorepo.out" '"ran":2'
assert_contains "$TMP_DIR/monorepo.out" '"task":"api-test","target":"api","status":9'

echo "==> large explicit target set remains deterministic"
LARGE="$TMP_DIR/large"
mkdir -p "$LARGE"
cat >"$LARGE/.touchstone.toml" <<'EOF'
schema = 1
[validation]
runtime = "bash"
EOF
for index in $(awk 'BEGIN { for (i=1; i<=40; i++) print i }'); do
  mkdir -p "$LARGE/packages/p$index"
  cat >>"$LARGE/.touchstone.toml" <<EOF
[[validation.targets]]
name = "p$index"
path = "packages/p$index"
[[validation.tasks]]
name = "test-p$index"
target = "p$index"
command = "printf $index > result"
required = true
EOF
done
run_capture "$LARGE" "$TMP_DIR/large.out" --json
[ "$RUN_STATUS" -eq 0 ] || fail "large fixture failed"
assert_contains "$TMP_DIR/large.out" '"ran":40'
[ "$(cat "$LARGE/packages/p40/result")" = 40 ] || fail "large fixture missed last target"

echo "==> setup is explicit and stops tasks after failure"
SETUP="$TMP_DIR/setup"
write_contract "$SETUP" 'test -f prepared'
awk '{ print; if ($0 == "runtime = \"bash\"") print "setup = \"printf ready > prepared\"" }' \
  "$SETUP/.touchstone.toml" >"$SETUP/with-setup"
mv "$SETUP/with-setup" "$SETUP/.touchstone.toml"
run_capture "$SETUP" "$TMP_DIR/setup.out"
[ "$RUN_STATUS" -eq 0 ] || fail "setup contract failed"

SETUP_WHITESPACE="$TMP_DIR/setup-whitespace"
write_contract "$SETUP_WHITESPACE" "printf task-ran > marker"
awk '{ print; if ($0 == "runtime = \"bash\"") print "setup = \"   \"" }' \
  "$SETUP_WHITESPACE/.touchstone.toml" >"$SETUP_WHITESPACE/with-setup"
mv "$SETUP_WHITESPACE/with-setup" "$SETUP_WHITESPACE/.touchstone.toml"
run_capture "$SETUP_WHITESPACE" "$TMP_DIR/setup-whitespace.out" --json
[ "$RUN_STATUS" -eq 2 ] || fail "whitespace-only setup did not exit 2"
assert_contains "$TMP_DIR/setup-whitespace.out.err" "setup cannot be empty when declared"
[ ! -e "$SETUP_WHITESPACE/marker" ] || fail "task ran after malformed setup"

SETUP_FAIL="$TMP_DIR/setup-fail"
write_contract "$SETUP_FAIL" "printf should-not-run > marker"
awk '{ print; if ($0 == "runtime = \"bash\"") print "setup = \"exit 7\"" }' \
  "$SETUP_FAIL/.touchstone.toml" >"$SETUP_FAIL/with-setup"
mv "$SETUP_FAIL/with-setup" "$SETUP_FAIL/.touchstone.toml"
run_capture "$SETUP_FAIL" "$TMP_DIR/setup-fail.out" --json
[ "$RUN_STATUS" -eq 7 ] || fail "setup failure status was lost"
[ ! -e "$SETUP_FAIL/marker" ] || fail "task ran after setup failure"
assert_contains "$TMP_DIR/setup-fail.out" '"task":"setup"'

SETUP_ESCAPE="$TMP_DIR/setup-escape"
SETUP_OUTSIDE="$TMP_DIR/setup-outside"
mkdir -p "$SETUP_ESCAPE/target" "$SETUP_OUTSIDE"
cat >"$SETUP_ESCAPE/.touchstone.toml" <<'EOF'
schema = 1
[validation]
runtime = "bash"
setup = "mv target original-target && ln -s ../setup-outside target"
[[validation.targets]]
name = "target"
path = "target"
[[validation.tasks]]
name = "escape"
target = "target"
command = "printf escaped > marker"
required = true
EOF
run_capture "$SETUP_ESCAPE" "$TMP_DIR/setup-escape.out" --json
[ "$RUN_STATUS" -eq 2 ] || fail "setup-created target escape was not rejected"
assert_contains "$TMP_DIR/setup-escape.out" '"reason":"escaped-target"'
[ ! -e "$SETUP_OUTSIDE/marker" ] || fail "task ran outside project after setup"

echo "==> malformed, repeated, escaping, missing, legacy, and newer states fail"
for fixture in unsupported duplicate escape unknown; do
  dir="$TMP_DIR/$fixture"
  write_contract "$dir" "true"
  case "$fixture" in
    unsupported) sed 's/schema = 1/schema = 3/' "$dir/.touchstone.toml" >"$dir/new" ;;
    duplicate)
      awk '{ print; if ($0 == "path = \".\"") print "name = \"root-again\"" }' \
        "$dir/.touchstone.toml" >"$dir/new"
      ;;
    escape) sed 's#path = "."#path = "../outside"#' "$dir/.touchstone.toml" >"$dir/new" ;;
    unknown)
      awk '{ print; if ($0 == "runtime = \"bash\"") print "project_type = \"node\"" }' \
        "$dir/.touchstone.toml" >"$dir/new"
      ;;
  esac
  mv "$dir/new" "$dir/.touchstone.toml"
  run_capture "$dir" "$TMP_DIR/$fixture.out" --json
  [ "$RUN_STATUS" -eq 2 ] || fail "$fixture contract did not fail closed"
  assert_contains "$TMP_DIR/$fixture.out" '"reason":"malformed-config"'
done

SYMLINK_ESCAPE="$TMP_DIR/symlink-escape"
write_contract "$SYMLINK_ESCAPE" "true"
ln -s "$TMP_DIR" "$SYMLINK_ESCAPE/outside"
sed 's#path = "."#path = "outside"#' "$SYMLINK_ESCAPE/.touchstone.toml" >"$SYMLINK_ESCAPE/new"
mv "$SYMLINK_ESCAPE/new" "$SYMLINK_ESCAPE/.touchstone.toml"
run_capture "$SYMLINK_ESCAPE" "$TMP_DIR/symlink-escape.out" --json
[ "$RUN_STATUS" -eq 2 ] || fail "symlink target escape did not fail closed"
assert_contains "$TMP_DIR/symlink-escape.out" '"reason":"escaped-target"'

MISSING="$TMP_DIR/missing"
mkdir -p "$MISSING"
run_capture "$MISSING" "$TMP_DIR/missing.out"
[ "$RUN_STATUS" -eq 2 ] || fail "missing contract did not fail"
touch "$MISSING/.touchstone-config"
run_capture "$MISSING" "$TMP_DIR/legacy.out"
[ "$RUN_STATUS" -eq 2 ] || fail "legacy contract did not fail"
assert_contains "$TMP_DIR/legacy.out.err" "legacy .touchstone-config"

echo "==> repeated validation does not mutate the project contract"
REPEAT="$TMP_DIR/repeat"
write_contract "$REPEAT" "true"
before="$(shasum -a 256 "$REPEAT/.touchstone.toml" | awk '{print $1}')"
run_capture "$REPEAT" "$TMP_DIR/repeat-1.out"
run_capture "$REPEAT" "$TMP_DIR/repeat-2.out"
after="$(shasum -a 256 "$REPEAT/.touchstone.toml" | awk '{print $1}')"
[ "$before" = "$after" ] || fail "validation mutated its declaration"

echo "==> ambient variables cannot replace declarations"
AMBIENT="$TMP_DIR/ambient"
AMBIENT_OTHER="$TMP_DIR/ambient-other"
write_contract "$AMBIENT" "printf declared > marker"
write_contract "$AMBIENT_OTHER" "exit 44"
set +e
TOUCHSTONE_PROJECT_ROOT="$AMBIENT_OTHER" \
  TOUCHSTONE_CONFIG_FILE="$AMBIENT_OTHER/.touchstone.toml" \
  bash "$RUNNER" validate --project "$AMBIENT" \
  >"$TMP_DIR/ambient.out" 2>"$TMP_DIR/ambient.err"
ambient_status=$?
set -e
[ "$ambient_status" -eq 0 ] || fail "ambient variables replaced the explicit contract"
[ "$(cat "$AMBIENT/marker")" = declared ] || fail "declared contract did not own the run"

echo "==> runtime contains no project-type or package-manager detection"
assert_not_contains "$RUNNER" "project_type"
assert_not_contains "$RUNNER" "package_manager"
assert_not_contains "$RUNNER" "package.json"
assert_not_contains "$RUNNER" "pyproject.toml"

echo "==> legacy CI compatibility detector names only the unsafe pairing"
LEGACY="$TMP_DIR/legacy-ci"
mkdir -p "$LEGACY/.github/workflows"
cat >"$LEGACY/.pre-commit-config.yaml" <<'EOF'
- id: no-commit-to-branch
  stages: [pre-commit]
EOF
cat >"$LEGACY/.github/workflows/validate.yml" <<'EOF'
on:
  push:
    branches: [main]
steps:
  - id: unrelated
    env:
      SKIP: no-commit-to-branch
    run: printf unrelated
  - run: pre-commit run --all-files --hook-stage pre-commit
EOF
cat >"$LEGACY/.github/workflows/comment-only.yml" <<'EOF'
on:
  push:
    branches: [main]
steps:
  # pre-commit run --all-files --hook-stage pre-commit
  - run: printf safe
EOF
cat >"$LEGACY/.github/workflows/mixed-trigger.yml" <<'EOF'
on:
  push:
    branches: [release]
  pull_request:
    branches: [main]
steps:
  - run: pre-commit run --all-files --hook-stage pre-commit
EOF
cat >"$LEGACY/.github/workflows/substring-branch.yml" <<'EOF'
on:
  push:
    branches: [maintenance]
steps:
  - run: pre-commit run --all-files --hook-stage pre-commit
EOF
cat >"$LEGACY/.github/workflows/quoted-default.yml" <<'EOF'
on:
  push:
    branches:
      - 'main'
steps:
  - run: pre-commit run --all-files --hook-stage pre-commit
EOF
cat >"$LEGACY/.github/workflows/glob-default.yml" <<'EOF'
on:
  push:
    branches: ['**']
steps:
  - run: pre-commit run --all-files --hook-stage pre-commit
EOF
cat >"$LEGACY/.github/workflows/excluded-defaults.yml" <<'EOF'
on:
  push:
    branches: ['**', '!main', '!master']
steps:
  - run: pre-commit run --all-files --hook-stage pre-commit
EOF
cat >"$LEGACY/.github/workflows/class-default.yml" <<'EOF'
on:
  push:
    branches: ['m[ai]in']
steps:
  - run: pre-commit run --all-files --hook-stage pre-commit
EOF
cat >"$LEGACY/.github/workflows/flow-trigger.yml" <<'EOF'
on: {pull_request: {}, push: {branches: [main]}}
steps:
  - run: pre-commit run --all-files --hook-stage pre-commit
EOF
cat >"$LEGACY/.github/workflows/flow-filtered.yml" <<'EOF'
on: {pull_request: {}, push: {branches: [release]}}
steps:
  - run: pre-commit run --all-files --hook-stage pre-commit
EOF
cat >"$LEGACY/.github/workflows/flow-neighbor-filter.yml" <<'EOF'
on: {push: {}, pull_request: {branches: [release]}}
steps:
  - run: pre-commit run --all-files --hook-stage pre-commit
EOF
cat >"$LEGACY/.github/workflows/flow-multiline.yml" <<'EOF'
on: {pull_request: {},
  push: {}}
steps:
  - run: pre-commit run --all-files --hook-stage pre-commit
EOF
cat >"$LEGACY/.github/workflows/flow-quoted-key.yml" <<'EOF'
on: {"push": {}}
steps:
  - run: pre-commit run --all-files --hook-stage pre-commit
EOF
cat >"$LEGACY/.github/workflows/block-quoted-key.yml" <<'EOF'
"on":
  "push":
    branches: [main]
steps:
  - run: pre-commit run --all-files --hook-stage pre-commit
EOF
cat >"$LEGACY/.github/workflows/non-executing-text.yml" <<'EOF'
on:
  push:
    branches: [main]
steps:
  - run: printf '%s\n' 'pre-commit run --all-files --hook-stage pre-commit'
EOF
set +e
bash "$COMPAT" "$LEGACY" >"$TMP_DIR/compat.out" 2>"$TMP_DIR/compat.err"
status=$?
set -e
[ "$status" -eq 3 ] || fail "legacy CI pairing was not detected"
assert_contains "$TMP_DIR/compat.out" "LEGACY-CI-BRANCH-GUARD .github/workflows/validate.yml"
assert_not_contains "$TMP_DIR/compat.out" "comment-only.yml"
assert_not_contains "$TMP_DIR/compat.out" "mixed-trigger.yml"
assert_not_contains "$TMP_DIR/compat.out" "substring-branch.yml"
assert_contains "$TMP_DIR/compat.out" "quoted-default.yml"
assert_contains "$TMP_DIR/compat.out" "glob-default.yml"
assert_not_contains "$TMP_DIR/compat.out" "excluded-defaults.yml"
assert_contains "$TMP_DIR/compat.out" "class-default.yml"
assert_contains "$TMP_DIR/compat.out" "flow-trigger.yml"
assert_not_contains "$TMP_DIR/compat.out" "flow-filtered.yml"
assert_contains "$TMP_DIR/compat.out" "flow-neighbor-filter.yml"
assert_contains "$TMP_DIR/compat.out" "flow-multiline.yml"
assert_contains "$TMP_DIR/compat.out" "flow-quoted-key.yml"
assert_contains "$TMP_DIR/compat.out" "block-quoted-key.yml"
assert_not_contains "$TMP_DIR/compat.out" "non-executing-text.yml"
assert_contains "$TMP_DIR/compat.err" "SKIP=no-commit-to-branch"
printf '\n# SKIP=no-commit-to-branch is not a repair\n' >>"$LEGACY/.github/workflows/validate.yml"
set +e
bash "$COMPAT" "$LEGACY" >"$TMP_DIR/comment-skip.out" 2>"$TMP_DIR/comment-skip.err"
status=$?
set -e
[ "$status" -eq 3 ] || fail "comment SKIP incorrectly repaired legacy CI"
cat >"$LEGACY/.github/workflows/bare-assignment.yml" <<'EOF'
on:
  push:
    branches: [main]
steps:
  - run: |
      SKIP=no-commit-to-branch
      pre-commit run --all-files --hook-stage pre-commit
EOF
sed 's#run: pre-commit run#env: {SKIP: no-commit-to-branch}\n    run: pre-commit run#' \
  "$LEGACY/.github/workflows/validate.yml" >"$LEGACY/.github/workflows/fixed.yml"
rm "$LEGACY/.github/workflows/validate.yml"
rm "$LEGACY/.github/workflows/quoted-default.yml"
rm "$LEGACY/.github/workflows/glob-default.yml"
rm "$LEGACY/.github/workflows/class-default.yml"
rm "$LEGACY/.github/workflows/flow-trigger.yml"
rm "$LEGACY/.github/workflows/flow-neighbor-filter.yml"
rm "$LEGACY/.github/workflows/flow-multiline.yml"
rm "$LEGACY/.github/workflows/flow-quoted-key.yml"
rm "$LEGACY/.github/workflows/block-quoted-key.yml"
set +e
bash "$COMPAT" "$LEGACY" >"$TMP_DIR/bare-assignment.out" 2>"$TMP_DIR/bare-assignment.err"
status=$?
set -e
[ "$status" -eq 3 ] || fail "unexported SKIP assignment incorrectly repaired legacy CI"
assert_contains "$TMP_DIR/bare-assignment.out" "bare-assignment.yml"
rm "$LEGACY/.github/workflows/bare-assignment.yml"
cat >"$LEGACY/.github/workflows/exported.yml" <<'EOF'
on:
  push:
    branches: [main]
steps:
  - run: |
      export SKIP=no-commit-to-branch
      pre-commit run --all-files --hook-stage pre-commit
EOF
cat >"$LEGACY/.github/workflows/direct.yml" <<'EOF'
on:
  push:
    branches: [main]
steps:
  - run: SKIP=no-commit-to-branch pre-commit run --all-files --hook-stage pre-commit
EOF
bash "$COMPAT" "$LEGACY" || fail "repaired CI pairing still detected"

STAGE_COLLISION="$TMP_DIR/stage-collision"
mkdir -p "$STAGE_COLLISION/.github/workflows"
cat >"$STAGE_COLLISION/.pre-commit-config.yaml" <<'EOF'
repos:
  - repo: local
    hooks:
      - id: no-commit-to-branch
        stages: [pre-push]
      - id: content-check
        stages:
          - pre-commit
EOF
cat >"$STAGE_COLLISION/.github/workflows/validate.yml" <<'EOF'
on:
  push:
    branches: [main]
steps:
  - run: pre-commit run --all-files --hook-stage pre-commit
EOF
bash "$COMPAT" "$STAGE_COLLISION" || fail "unrelated pre-commit stage was attributed to branch guard"

DEFAULT_STAGE="$TMP_DIR/default-stage"
mkdir -p "$DEFAULT_STAGE/.github/workflows"
cat >"$DEFAULT_STAGE/.pre-commit-config.yaml" <<'EOF'
default_stages:
  - pre-push
repos:
  - repo: local
    hooks:
      - id: no-commit-to-branch
EOF
cp "$STAGE_COLLISION/.github/workflows/validate.yml" "$DEFAULT_STAGE/.github/workflows/validate.yml"
bash "$COMPAT" "$DEFAULT_STAGE" || fail "global default stage was ignored for branch guard"

echo "==> local authoring guard remains installed"
assert_contains "$ROOT/.pre-commit-config.yaml" "id: no-commit-to-branch"
assert_contains "$ROOT/.pre-commit-config.yaml" "stages: [pre-commit]"

echo "==> legacy adoption config preserves precedence and quoting"
LEGACY_CONFIG="$TMP_DIR/legacy-config"
(
  operational_failure() {
    printf 'failed: %s\n' "$*" >&2
    exit 6
  }
  contract_refusal() {
    printf 'refused: %s\n' "$*" >&2
    exit 4
  }
  # shellcheck source=scripts/lib/touchstone-legacy-config.sh
  source "$ROOT/scripts/lib/touchstone-legacy-config.sh"

  [ ! -e "$LEGACY_CONFIG" ] || exit 11
  set +e
  legacy_config_value "$LEGACY_CONFIG" validate_command >/dev/null 2>&1
  missing_status=$?
  set -e
  [ "$missing_status" -eq 1 ] || exit 12

  printf '%s\n' \
    '# ignored' \
    'project_type=node' \
    'profile=python' \
    'validate_command=npm test' \
    'validate_full_command="npm run test:all"' \
    'full_validate_command=ignored lower-priority alias' \
    >"$LEGACY_CONFIG"
  [ "$(legacy_profile_value "$LEGACY_CONFIG")" = python ] || exit 13
  [ "$(legacy_full_validation_command "$LEGACY_CONFIG")" = 'npm run test:all' ] || exit 14

  printf '%s\n' \
    'profile=python' \
    'project_type=node' \
    "full_validate_command='python -m pytest'" \
    'validate_command_full=ignored lower-priority alias' \
    'validate_command=python -m pytest tests/unit' \
    >"$LEGACY_CONFIG"
  [ "$(legacy_profile_value "$LEGACY_CONFIG")" = node ] || exit 15
  [ "$(legacy_full_validation_command "$LEGACY_CONFIG")" = 'python -m pytest' ] || exit 16

  printf '%s\n' \
    'validate_command_full=go test ./...' \
    'validate_command=go test ./pkg/...' \
    >"$LEGACY_CONFIG"
  [ "$(legacy_full_validation_command "$LEGACY_CONFIG")" = 'go test ./...' ] || exit 17

  printf '%s\n' \
    'validate_command=first' \
    'malformed line' \
    'validate_command=last' \
    >"$LEGACY_CONFIG"
  [ "$(legacy_full_validation_command "$LEGACY_CONFIG")" = last ] || exit 18

  printf '%s' 'validate_command="unterminated' >"$LEGACY_CONFIG"
  [ "$(legacy_full_validation_command "$LEGACY_CONFIG")" = '"unterminated' ] || exit 19

  : >"$LEGACY_CONFIG"
  line=1
  while [ "$line" -le 5000 ]; do
    printf '# padding %s\n' "$line" >>"$LEGACY_CONFIG"
    line=$((line + 1))
  done
  printf 'validate_full_command=large-final-command\n' >>"$LEGACY_CONFIG"
  [ "$(legacy_full_validation_command "$LEGACY_CONFIG")" = large-final-command ] || exit 20

  command rm -f "$LEGACY_CONFIG"
  printf 'validate_command=outside\n' >"$TMP_DIR/legacy-outside"
  ln -s "$TMP_DIR/legacy-outside" "$LEGACY_CONFIG"
  set +e
  (legacy_full_validation_command "$LEGACY_CONFIG") >"$TMP_DIR/legacy-symlink.out" 2>&1
  symlink_status=$?
  set -e
  [ "$symlink_status" -eq 4 ] || exit 21
  grep -Fq 'must not be a symbolic link' "$TMP_DIR/legacy-symlink.out" || exit 22

  command rm -f "$LEGACY_CONFIG"
  command mkdir "$LEGACY_CONFIG"
  set +e
  (legacy_full_validation_command "$LEGACY_CONFIG") >"$TMP_DIR/legacy-directory.out" 2>&1
  directory_status=$?
  set -e
  [ "$directory_status" -eq 4 ] || exit 23
  grep -Fq 'legacy configuration is not a regular file' "$TMP_DIR/legacy-directory.out" || exit 24
) || fail "legacy adoption config changed frozen precedence or quoting"

echo "==> adoption plan records stay consistent and fail closed"
PLAN_RECORDS="$TMP_DIR/plan-records"
mkdir -p "$PLAN_RECORDS/project/packages/web"
(
  PROJECT_ROOT="$PLAN_RECORDS/project"
  TARGETS_FILE="$PLAN_RECORDS/targets"
  TASKS_FILE="$PLAN_RECORDS/tasks"
  SETUPS_FILE="$PLAN_RECORDS/setups"
  # shellcheck disable=SC2034 # sourced record functions consume these delimiters.
  TAB="$(printf '\t')"
  # shellcheck disable=SC2034 # sourced record functions consume these delimiters.
  CR="$(printf '\r')"
  LF="$(printf '\nX')"
  LF="${LF%X}"
  : >"$TARGETS_FILE"
  : >"$TASKS_FILE"
  : >"$SETUPS_FILE"
  contract_refusal() {
    printf 'refused: %s\n' "$*" >&2
    exit 4
  }
  operational_failure() {
    printf 'failed: %s\n' "$*" >&2
    exit 6
  }
  MANUAL_TASK_ARGS=('verify=true' 'lint=printf lint')
  # shellcheck source=scripts/lib/touchstone-plan-records.sh
  source "$ROOT/scripts/lib/touchstone-plan-records.sh"

  compile_manual_plan "${MANUAL_TASK_ARGS[@]}"
  [ "$PROFILE" = manual ] || exit 11
  grep -Fqx $'root\t.\tmanual' "$TARGETS_FILE" || exit 12
  grep -Fqx $'verify\troot\ttrue\ttrue' "$TASKS_FILE" || exit 13
  grep -Fqx $'lint\troot\ttrue\tprintf lint' "$TASKS_FILE" || exit 14
  record_plan_setup "$PROJECT_ROOT/packages/web" 'npm install --offline'
  record_plan_setup "$PROJECT_ROOT/packages/web" 'npm install --offline'
  grep -Fqx $'packages/web\tnpm install --offline' "$SETUPS_FILE" || exit 15
  [ "$(wc -l <"$SETUPS_FILE" | tr -d '[:space:]')" -eq 1 ] || exit 16

  set +e
  (record_plan_task orphan missing true) >"$PLAN_RECORDS/orphan.out" 2>&1
  orphan_status=$?
  (record_plan_task verify root true) >"$PLAN_RECORDS/duplicate.out" 2>&1
  duplicate_status=$?
  (record_plan_setup "$PROJECT_ROOT/packages/web" 'npm ci') >"$PLAN_RECORDS/conflict.out" 2>&1
  conflict_status=$?
  (record_plan_task control root "printf $(printf '\033')") >"$PLAN_RECORDS/control.out" 2>&1
  control_status=$?
  (record_plan_target newline "packages${LF}web" manual) >"$PLAN_RECORDS/delimiter.out" 2>&1
  delimiter_status=$?
  set -e
  [ "$orphan_status" -eq 4 ] || exit 17
  [ "$duplicate_status" -eq 4 ] || exit 18
  [ "$conflict_status" -eq 4 ] || exit 19
  [ "$control_status" -eq 4 ] || exit 20
  [ "$delimiter_status" -eq 4 ] || exit 21

  mkdir -p "$PROJECT_ROOT/packages/back\\slash"
  set +e
  (record_plan_setup "$PROJECT_ROOT/packages/back\\slash" true) >"$PLAN_RECORDS/backslash.out" 2>&1
  backslash_status=$?
  set -e
  [ "$backslash_status" -eq 4 ] || exit 31
  grep -Fq "setup has invalid path 'packages/back\\slash'" "$PLAN_RECORDS/backslash.out" || exit 32

  EMPTY_TARGETS="$PLAN_RECORDS/empty-manual-targets"
  EMPTY_TASKS="$PLAN_RECORDS/empty-manual-tasks"
  TARGETS_FILE="$EMPTY_TARGETS"
  TASKS_FILE="$EMPTY_TASKS"
  : >"$TARGETS_FILE"
  : >"$TASKS_FILE"
  set +e
  (compile_manual_plan) >"$PLAN_RECORDS/empty-manual.out" 2>&1
  empty_manual_status=$?
  set -e
  [ "$empty_manual_status" -eq 4 ] || exit 33
  [ ! -s "$TARGETS_FILE" ] || exit 34
  compile_manual_plan 'count-is-not-source=true'
  grep -Fqx $'count-is-not-source\troot\ttrue\ttrue' "$TASKS_FILE" || exit 35
  assert_not_contains "$ROOT/scripts/lib/touchstone-plan-records.sh" 'MANUAL_TASK_COUNT'
  assert_not_contains "$ROOT/scripts/lib/touchstone-plan-records.sh" 'MANUAL_TASK_ARGS'

  LARGE_TARGETS="$PLAN_RECORDS/large-targets"
  LARGE_TASKS="$PLAN_RECORDS/large-tasks"
  TARGETS_FILE="$LARGE_TARGETS"
  TASKS_FILE="$LARGE_TASKS"
  : >"$TARGETS_FILE"
  : >"$TASKS_FILE"
  record_plan_target root . manual
  index=1
  while [ "$index" -le 500 ]; do
    record_plan_task "task-$index" root true
    index=$((index + 1))
  done
  [ "$(wc -l <"$TASKS_FILE" | tr -d '[:space:]')" -eq 500 ] || exit 22

  force_append_failure_after_lookup() {
    local record_file="$1" output="$2"
    shift 2
    awk() {
      local last status
      command awk "$@"
      status=$?
      for last in "$@"; do :; done
      if [ "$last" = "$record_file" ]; then
        command rm -f "$record_file"
        command mkdir "$record_file"
      fi
      return "$status"
    }
    set +e
    ("$@") >"$output" 2>&1
    append_status=$?
    set -e
    unset -f awk
    [ "$append_status" -eq 6 ] || return 1
  }

  TARGETS_FILE="$PLAN_RECORDS/append-targets"
  : >"$TARGETS_FILE"
  force_append_failure_after_lookup "$TARGETS_FILE" "$PLAN_RECORDS/append-target.out" \
    record_plan_target append-target . manual || exit 23
  grep -Fq "could not record adoption target 'append-target'" "$PLAN_RECORDS/append-target.out" || exit 24

  TARGETS_FILE="$PLAN_RECORDS/task-targets"
  TASKS_FILE="$PLAN_RECORDS/append-tasks"
  printf 'root\t.\tmanual\n' >"$TARGETS_FILE"
  : >"$TASKS_FILE"
  force_append_failure_after_lookup "$TASKS_FILE" "$PLAN_RECORDS/append-task.out" \
    record_plan_task append-task root true || exit 25
  grep -Fq "could not record adoption task 'append-task'" "$PLAN_RECORDS/append-task.out" || exit 26

  SETUPS_FILE="$PLAN_RECORDS/append-setups"
  : >"$SETUPS_FILE"
  force_append_failure_after_lookup "$SETUPS_FILE" "$PLAN_RECORDS/append-setup.out" \
    record_plan_setup "$PROJECT_ROOT/packages/web" true || exit 27
  grep -Fq "could not record adoption setup for 'packages/web'" "$PLAN_RECORDS/append-setup.out" || exit 28

  TARGETS_FILE="$PLAN_RECORDS/lookup-targets"
  mkdir "$TARGETS_FILE"
  set +e
  (record_plan_target lookup-failure . manual) >"$PLAN_RECORDS/lookup.out" 2>&1
  lookup_status=$?
  set -e
  [ "$lookup_status" -eq 6 ] || exit 29
  grep -Fq "could not inspect adoption targets" "$PLAN_RECORDS/lookup.out" || {
    cat "$PLAN_RECORDS/lookup.out" >&2
    exit 30
  }
) || fail "adoption plan-record invariant failed"

echo "==> portable package.json parsing validates the full document and top-level scripts"
PACKAGE_JSON_CASES="$TMP_DIR/package-json-cases"
mkdir -p "$PACKAGE_JSON_CASES"
cat >"$PACKAGE_JSON_CASES/valid.json" <<'EOF'
{
  "nested": {"scripts": {"validate": "must-not-count"}},
  "scripts": {
    "build": "npm run compile",
    "test": "\t",
    "\u0076erify": "npm run lint && npm test",
    "lint": false,
    "typecheck": " npm run types ",
    "\u00e9": "unrelated",
    "\u00df": "also unrelated"
  },
  "number": -12.5e+2,
  "array": [true, false, null, {"quote": "\\\""}]
}
EOF
parsed_scripts="$(awk -f "$ROOT/scripts/lib/touchstone-package-json.awk" "$PACKAGE_JSON_CASES/valid.json")" \
  || fail "portable package.json parser refused valid JSON"
[ "$parsed_scripts" = "$(printf '%s\n' verify typecheck build)" ] \
  || fail "portable package.json parser did not emit supported scripts in preference order"

printf '{"metadata":"\177","scripts":{"test":"true"}}\n' >"$PACKAGE_JSON_CASES/del.json"
[ "$(awk -f "$ROOT/scripts/lib/touchstone-package-json.awk" "$PACKAGE_JSON_CASES/del.json")" = test ] \
  || fail "portable package.json parser rejected JSON-valid DEL content"
printf '{"metadata":"\037","scripts":{"test":"true"}}\n' >"$PACKAGE_JSON_CASES/raw-control.json"
set +e
awk -f "$ROOT/scripts/lib/touchstone-package-json.awk" \
  "$PACKAGE_JSON_CASES/raw-control.json" >"$PACKAGE_JSON_CASES/raw-control.out" 2>&1
raw_control_status=$?
set -e
[ "$raw_control_status" -ne 0 ] || fail "portable package.json parser accepted a forbidden raw control"

for malformed_case in nested-only duplicate-root duplicate-script non-object trailing bad-surrogate; do
  case "$malformed_case" in
    nested-only) printf '%s\n' '{"nested":{"scripts":{"test":"true"}}}' ;;
    duplicate-root) printf '%s\n' '{"scripts":{"test":"true"},"scripts":{"build":"true"}}' ;;
    duplicate-script) printf '%s\n' '{"scripts":{"test":"true","test":"false"}}' ;;
    non-object) printf '%s\n' '{"scripts":["test"]}' ;;
    trailing) printf '%s\n' '{"scripts":{"test":"true"}} false' ;;
    bad-surrogate) printf '%s\n' '{"scripts":{"\uD800":"true"}}' ;;
  esac >"$PACKAGE_JSON_CASES/$malformed_case.json"
  set +e
  awk -f "$ROOT/scripts/lib/touchstone-package-json.awk" \
    "$PACKAGE_JSON_CASES/$malformed_case.json" >"$PACKAGE_JSON_CASES/$malformed_case.out" 2>&1
  package_status=$?
  set -e
  [ "$package_status" -ne 0 ] || fail "portable package.json parser accepted $malformed_case input"
done

echo "==> adoption plans once without writes and compiles only portfolio evidence"
ADOPTION="$TMP_DIR/adoption"
mkdir -p "$ADOPTION"

new_adoption_repo() {
  local directory="$1"
  mkdir -p "$directory"
  git -C "$directory" init -q -b main
  git -C "$directory" config user.name test
  git -C "$directory" config user.email test@example.com
  printf '# Consumer\n\nProject-owned guidance.\n' >"$directory/AGENTS.md"
  git -C "$directory" add AGENTS.md
  git -C "$directory" commit -qm fixture
}

run_adoption() {
  local output="$1"
  shift
  set +e
  bash "$ROOT/bin/touchstone" "$@" >"$output" 2>"$output.err"
  ADOPTION_STATUS=$?
  set -e
}

MANUAL="$ADOPTION/manual"
new_adoption_repo "$MANUAL"
git -C "$MANUAL" switch -qc feat/adopt
run_adoption "$ADOPTION/empty-project.json" adopt --dry-run --json \
  --project '' --project "$MANUAL" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 2 ] || fail "explicitly empty adoption project was accepted"
assert_contains "$ADOPTION/empty-project.json" '"status":"invalid-invocation"'
assert_contains "$ADOPTION/empty-project.json" 'missing value for --project'
control_argument="invalid$(printf '\b\f')argument"
run_adoption "$ADOPTION/control-argument.json" adopt --json "$control_argument"
[ "$ADOPTION_STATUS" -eq 2 ] || fail "control-character argument did not fail as invalid input"
jq -e '.status == "invalid-invocation"' "$ADOPTION/control-argument.json" >/dev/null \
  || fail "control-character failure was not valid JSON"

SUBDIRECTORY_PROJECT="$ADOPTION/subdirectory-project"
new_adoption_repo "$SUBDIRECTORY_PROJECT"
mkdir -p "$SUBDIRECTORY_PROJECT/sub"
printf 'tracked\n' >"$SUBDIRECTORY_PROJECT/sub/input"
git -C "$SUBDIRECTORY_PROJECT" add sub/input
git -C "$SUBDIRECTORY_PROJECT" commit -qm subdirectory
git -C "$SUBDIRECTORY_PROJECT" switch -qc feat/adopt
run_adoption "$ADOPTION/subdirectory-project.json" adopt --dry-run --json \
  --project "$SUBDIRECTORY_PROJECT/sub" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 0 ] || fail "explicit project subdirectory did not normalize to the repository root"
run_adoption "$ADOPTION/root-project.json" adopt --dry-run --json \
  --project "$SUBDIRECTORY_PROJECT" --task 'verify=true'
cmp -s "$ADOPTION/subdirectory-project.json" "$ADOPTION/root-project.json" \
  || fail "root and subdirectory planning selected different repository roots"
[ ! -e "$SUBDIRECTORY_PROJECT/.touchstone.toml" ] || fail "subdirectory planning mutated the repository root"

chmod +x "$MANUAL/AGENTS.md"
git -C "$MANUAL" add AGENTS.md
git -C "$MANUAL" commit -qm executable-instructions
run_adoption "$ADOPTION/manual-one.json" adopt --dry-run --json --project "$MANUAL" \
  --tracker linear --tracker-prefix AUT --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 0 ] || fail "manual adoption dry-run failed"
assert_contains "$ADOPTION/manual-one.json" '"schema":"touchstone.adoption/v1"'
assert_contains "$ADOPTION/manual-one.json" '"profile":"manual"'
assert_contains "$ADOPTION/manual-one.json" '"path":".touchstone.toml"'
assert_contains "$ADOPTION/manual-one.json" '"path":".touchstone-tracker.toml"'
assert_contains "$ADOPTION/manual-one.json" '"remotePolicy":{"status":"separate-operation","inspect":"touchstone policy status"}'
assert_contains "$ADOPTION/manual-one.json" 'type = \"linear\"'
assert_contains "$ADOPTION/manual-one.json" 'key_prefix = \"AUT\"'
assert_not_contains "$ADOPTION/manual-one.json" 'old mode'
assert_not_contains "$ADOPTION/manual-one.json" 'new mode'
[ ! -e "$MANUAL/.touchstone.toml" ] || fail "adoption dry-run mutated the repository"
run_adoption "$ADOPTION/manual-two.json" adopt --dry-run --json --project "$MANUAL" \
  --tracker linear --tracker-prefix AUT --task 'verify=true'
cmp -s "$ADOPTION/manual-one.json" "$ADOPTION/manual-two.json" \
  || fail "unchanged adoption inputs produced a different JSON plan"

TRACKER_ONLY="$ADOPTION/tracker-only"
new_adoption_repo "$TRACKER_ONLY"
printf '%s\n' 'schema = 1' 'type = "linear"' 'key_prefix = "AUT"' >"$TRACKER_ONLY/.touchstone-tracker.toml"
git -C "$TRACKER_ONLY" add .touchstone-tracker.toml
git -C "$TRACKER_ONLY" commit -qm tracker-only
git -C "$TRACKER_ONLY" switch -qc feat/adopt
tracker_only_hash="$(git -C "$TRACKER_ONLY" hash-object .touchstone-tracker.toml)"
run_adoption "$ADOPTION/tracker-only-replacement.json" adopt --dry-run --json --project "$TRACKER_ONLY" \
  --tracker github --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 2 ] || fail "tracker-only adoption accepted replacement tracker options"
run_adoption "$ADOPTION/tracker-only-plan.json" adopt --dry-run --json \
  --project "$TRACKER_ONLY" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 0 ] || fail "tracker-only adoption did not plan"
assert_contains "$ADOPTION/tracker-only-plan.json" '"path":".touchstone.toml"'
assert_not_contains "$ADOPTION/tracker-only-plan.json" '"path":".touchstone-tracker.toml"'
[ "$tracker_only_hash" = "$(git -C "$TRACKER_ONLY" hash-object .touchstone-tracker.toml)" ] \
  || fail "tracker-only planning rewrote the project-owned tracker declaration"

run_adoption "$ADOPTION/manual-check.json" adopt --check --json --project "$MANUAL" \
  --tracker linear --tracker-prefix AUT --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 3 ] || fail "adoption check did not report required changes"
[ ! -e "$MANUAL/.touchstone.toml" ] || fail "adoption check mutated the repository"

run_adoption "$ADOPTION/conflicting-modes.json" adopt --json --check --dry-run \
  --project "$MANUAL" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 2 ] || fail "planner accepted conflicting read-only modes"
assert_contains "$ADOPTION/conflicting-modes.json" 'choose only one planning mode'
# The plan carries declarations only; steering content in the plan JSON
# would mean adoption is writing repository copies again (AUT-317).
assert_not_contains "$ADOPTION/manual-one.json" 'touchstone:steering'
assert_not_contains "$ADOPTION/manual-one.json" 'Shared Agent Steering'

OLDER_V1="$ADOPTION/older-v1"
new_adoption_repo "$OLDER_V1"
cat >"$OLDER_V1/.touchstone.toml" <<'EOF'
schema = 1

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "verify"
target = "root"
command = "true"
required = true
EOF
git -C "$OLDER_V1" add .touchstone.toml
git -C "$OLDER_V1" commit -qm older-v1
git -C "$OLDER_V1" switch -qc feat/adopt
older_contract_hash="$(git -C "$OLDER_V1" hash-object .touchstone.toml)"
run_adoption "$ADOPTION/older-v1.json" adopt --dry-run --json --project "$OLDER_V1"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "new planner refused an older valid v1 contract"
[ "$older_contract_hash" = "$(git -C "$OLDER_V1" hash-object .touchstone.toml)" ] \
  || fail "adoption planning rewrote an older valid v1 contract"
assert_contains "$ADOPTION/older-v1.json" '"path":".touchstone-tracker.toml"'

NPM="$ADOPTION/npm"
new_adoption_repo "$NPM"
cp "$ROOT/tests/fixtures/adoption-v1/repositories/anima/package.json" "$NPM/package.json"
cp "$ROOT/tests/fixtures/adoption-v1/repositories/anima/package-lock.json" "$NPM/package-lock.json"
git -C "$NPM" add package.json package-lock.json
git -C "$NPM" commit -qm npm
run_adoption "$ADOPTION/npm.json" adopt --dry-run --json --project "$NPM"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "captured npm profile did not compile without a project runtime"
assert_contains "$ADOPTION/npm.json" '"profile":"npm"'
assert_contains "$ADOPTION/npm.json" 'npm ci --ignore-scripts'
assert_contains "$ADOPTION/npm.json" 'npm run verify'
assert_not_contains "$ROOT/scripts/touchstone-adopt.sh" 'command -v node'

LOCK_ONLY="$ADOPTION/lock-only"
new_adoption_repo "$LOCK_ONLY"
cp "$ROOT/tests/fixtures/adoption-v1/repositories/anima/package-lock.json" "$LOCK_ONLY/package-lock.json"
git -C "$LOCK_ONLY" add package-lock.json
git -C "$LOCK_ONLY" commit -qm lock-only
run_adoption "$ADOPTION/lock-only.out" adopt --dry-run --project "$LOCK_ONLY"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "npm profile accepted a package lock without package.json"
assert_contains "$ADOPTION/lock-only.out.err" 'requires both package.json and package-lock.json'

PYTHON="$ADOPTION/python"
new_adoption_repo "$PYTHON"
cp "$ROOT/tests/fixtures/adoption-v1/repositories/arpeggio/pyproject.toml" "$PYTHON/pyproject.toml"
cp "$ROOT/tests/fixtures/adoption-v1/repositories/arpeggio/uv.lock" "$PYTHON/uv.lock"
git -C "$PYTHON" add pyproject.toml uv.lock
git -C "$PYTHON" commit -qm python
run_adoption "$ADOPTION/python.json" adopt --dry-run --json --project "$PYTHON"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "captured Python profile did not compile"
assert_contains "$ADOPTION/python.json" '"profile":"python"'
assert_contains "$ADOPTION/python.json" 'uv sync --frozen'
assert_contains "$ADOPTION/python.json" 'uv run --frozen pytest'

SWIFT="$ADOPTION/swift"
new_adoption_repo "$SWIFT"
cp "$ROOT/tests/fixtures/adoption-v1/repositories/autumn-mail/Package.swift" "$SWIFT/Package.swift"
git -C "$SWIFT" add Package.swift
git -C "$SWIFT" commit -qm swift
run_adoption "$ADOPTION/swift.json" adopt --dry-run --json --project "$SWIFT"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "captured Swift profile did not compile"
assert_contains "$ADOPTION/swift.json" '"profile":"swift"'
assert_contains "$ADOPTION/swift.json" 'swift test --disable-automatic-resolution'

LEGACY="$ADOPTION/legacy"
new_adoption_repo "$LEGACY"
cp "$ROOT/tests/fixtures/adoption-v1/repositories/sentinel/pyproject.toml" "$LEGACY/pyproject.toml"
cp "$ROOT/tests/fixtures/adoption-v1/repositories/sentinel/.touchstone-config" "$LEGACY/.touchstone-config"
git -C "$LEGACY" add pyproject.toml .touchstone-config
git -C "$LEGACY" commit -qm legacy
run_adoption "$ADOPTION/legacy.json" adopt --dry-run --json --project "$LEGACY"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "captured legacy profile did not compile"
assert_contains "$ADOPTION/legacy.json" '"profile":"legacy"'
assert_contains "$ADOPTION/legacy.json" 'uv run ruff check src/ tests/'
assert_contains "$ADOPTION/legacy.json" 'uv run pytest'

AMBIGUOUS="$ADOPTION/ambiguous"
new_adoption_repo "$AMBIGUOUS"
cp "$ROOT/tests/fixtures/adoption-v1/repositories/anima/package.json" "$AMBIGUOUS/package.json"
cp "$ROOT/tests/fixtures/adoption-v1/repositories/anima/package-lock.json" "$AMBIGUOUS/package-lock.json"
cp "$ROOT/tests/fixtures/adoption-v1/repositories/arpeggio/pyproject.toml" "$AMBIGUOUS/pyproject.toml"
git -C "$AMBIGUOUS" add package.json package-lock.json pyproject.toml
git -C "$AMBIGUOUS" commit -qm ambiguous
run_adoption "$ADOPTION/ambiguous.out" adopt --dry-run --project "$AMBIGUOUS"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "competing profile evidence did not fail closed"
assert_contains "$ADOPTION/ambiguous.out.err" 'competing project evidence found: npm,python'
run_adoption "$ADOPTION/ambiguous.json" adopt --dry-run --json --project "$AMBIGUOUS"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "JSON competing profile evidence did not fail closed"
assert_contains "$ADOPTION/ambiguous.json" '"schema":"touchstone.adoption/v1"'
assert_contains "$ADOPTION/ambiguous.json" '"status":"contract-refusal"'
assert_contains "$ADOPTION/ambiguous.json" 'competing project evidence found: npm,python'

UNSUPPORTED="$ADOPTION/unsupported"
new_adoption_repo "$UNSUPPORTED"
printf 'schema = 3\n' >"$UNSUPPORTED/.touchstone.toml"
git -C "$UNSUPPORTED" add .touchstone.toml
git -C "$UNSUPPORTED" commit -qm unsupported
run_adoption "$ADOPTION/unsupported.out" adopt --dry-run --project "$UNSUPPORTED"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "unsupported schema did not fail closed"

UNSUPPORTED_TRACKER="$ADOPTION/unsupported-tracker"
new_adoption_repo "$UNSUPPORTED_TRACKER"
cp "$OLDER_V1/.touchstone.toml" "$UNSUPPORTED_TRACKER/.touchstone.toml"
printf '%s\n' 'schema = 2' 'type = "github"' >"$UNSUPPORTED_TRACKER/.touchstone-tracker.toml"
git -C "$UNSUPPORTED_TRACKER" add .touchstone.toml .touchstone-tracker.toml
git -C "$UNSUPPORTED_TRACKER" commit -qm unsupported-tracker
run_adoption "$ADOPTION/unsupported-tracker.out" adopt --dry-run --json --project "$UNSUPPORTED_TRACKER"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "unsupported tracker schema did not fail closed"
assert_contains "$ADOPTION/unsupported-tracker.out" 'unsupported-tracker-schema'

DANGLING_TRACKER="$ADOPTION/dangling-tracker"
new_adoption_repo "$DANGLING_TRACKER"
cp "$OLDER_V1/.touchstone.toml" "$DANGLING_TRACKER/.touchstone.toml"
ln -s missing-tracker "$DANGLING_TRACKER/.touchstone-tracker.toml"
git -C "$DANGLING_TRACKER" add .touchstone.toml .touchstone-tracker.toml
git -C "$DANGLING_TRACKER" commit -qm dangling-tracker
run_adoption "$ADOPTION/dangling-tracker.out" adopt --dry-run --project "$DANGLING_TRACKER"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "adopt accepted a dangling tracker declaration symlink"
assert_contains "$ADOPTION/dangling-tracker.out.err" 'compiler input is a symlink: .touchstone-tracker.toml'

DANGLING_LEGACY="$ADOPTION/dangling-legacy"
new_adoption_repo "$DANGLING_LEGACY"
ln -s missing-config "$DANGLING_LEGACY/.touchstone-config"
git -C "$DANGLING_LEGACY" add .touchstone-config
git -C "$DANGLING_LEGACY" commit -qm dangling-legacy
run_adoption "$ADOPTION/dangling-legacy.out" adopt --dry-run --project "$DANGLING_LEGACY"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "adoption accepted a dangling legacy declaration symlink"
assert_contains "$ADOPTION/dangling-legacy.out.err" 'compiler input is a symlink: .touchstone-config'

SYMLINKED="$ADOPTION/symlinked"
OUTSIDE="$ADOPTION/outside"
new_adoption_repo "$SYMLINKED"
mkdir -p "$OUTSIDE"
ln -s "$OUTSIDE" "$SYMLINKED/.touchstone"
git -C "$SYMLINKED" add .touchstone
git -C "$SYMLINKED" commit -qm symlink
# Adoption writes nothing under .touchstone/ anymore, so a symlink there is
# the operator's arrangement, not a hazard. Exercised through APPLY, not a
# read-only mode: a dry run cannot catch an apply-only write through the link.
git -C "$SYMLINKED" switch -qc feat/adopt
run_adoption "$ADOPTION/symlinked.out" adopt --project "$SYMLINKED" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 0 ] || fail "a symlinked .touchstone blocked adoption that no longer writes there"
[ -z "$(ls -A "$OUTSIDE" 2>/dev/null)" ] || fail "adoption wrote through the operator's .touchstone symlink"
[ -z "$(find "$OUTSIDE" -mindepth 1 -print -quit)" ] || fail "adoption wrote through a symlinked ancestor"

DRIFTED="$ADOPTION/drifted"
new_adoption_repo "$DRIFTED"
cp "$ROOT/tests/fixtures/adoption-v1/repositories/autumn-mail/Package.swift" "$DRIFTED/Package.swift"
git -C "$DRIFTED" add Package.swift
git -C "$DRIFTED" commit -qm swift
printf '\n// uncommitted detector input\n' >>"$DRIFTED/Package.swift"
run_adoption "$ADOPTION/drifted.out" adopt --dry-run --project "$DRIFTED"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "detector accepted input that differed from HEAD"
[ ! -e "$DRIFTED/.touchstone.toml" ] || fail "drift refusal left a partial write"

MALFORMED="$ADOPTION/malformed-markers"
new_adoption_repo "$MALFORMED"
cat >>"$MALFORMED/AGENTS.md" <<'EOF'
<!-- touchstone:steering:start -->
first
<!-- touchstone:steering:start -->
second
<!-- touchstone:steering:end -->
EOF
git -C "$MALFORMED" add AGENTS.md
git -C "$MALFORMED" commit -qm malformed
# Adoption no longer writes or parses steering, so an instruction file's
# contents -- malformed markers included -- are none of its business.
run_adoption "$ADOPTION/malformed.out" adopt --dry-run --project "$MALFORMED" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 0 ] || fail "adoption inspected instruction files it no longer owns"

IGNORED="$ADOPTION/ignored-output"
new_adoption_repo "$IGNORED"
printf '.touchstone.toml\n' >"$IGNORED/.gitignore"
git -C "$IGNORED" add .gitignore
git -C "$IGNORED" commit -qm ignored
run_adoption "$ADOPTION/ignored.out" adopt --dry-run --project "$IGNORED" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 4 ] || fail "ignored managed output did not fail closed"

# CLAUDE.md is not a managed output anymore: adoption neither reads nor
# writes instruction files. An untracked one still trips the clean-worktree
# gate -- apply's own safety, unrelated to steering -- so the apply-path
# fixture commits the operator's file and proves it comes through untouched.
UNTRACKED="$ADOPTION/untracked-output"
new_adoption_repo "$UNTRACKED"
printf '# local untracked instructions\n' >"$UNTRACKED/CLAUDE.md"
run_adoption "$ADOPTION/untracked.out" adopt --dry-run --project "$UNTRACKED" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 0 ] || fail "an untracked instruction file blocked a read-only plan"
git -C "$UNTRACKED" add CLAUDE.md
git -C "$UNTRACKED" commit -qm "operator instructions"
git -C "$UNTRACKED" switch -qc feat/adopt
run_adoption "$ADOPTION/untracked-apply.out" adopt --project "$UNTRACKED" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 0 ] || fail "an operator instruction file blocked apply"
[ "$(cat "$UNTRACKED/CLAUDE.md")" = "# local untracked instructions" ] \
  || fail "apply modified an operator instruction file"

echo "==> adoption applies atomically only from a clean non-default branch"
APPLY_REPO="$ADOPTION/apply"
new_adoption_repo "$APPLY_REPO"
chmod +x "$APPLY_REPO/AGENTS.md"
git -C "$APPLY_REPO" add AGENTS.md
git -C "$APPLY_REPO" commit -qm executable-guidance
git -C "$APPLY_REPO" switch -qc feat/adopt
run_adoption "$ADOPTION/apply.json" adopt --json --project "$APPLY_REPO" \
  --tracker linear --tracker-prefix AUT --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 0 ] || fail "clean feature-branch adoption did not apply"
assert_contains "$ADOPTION/apply.json" '"status":"applied"'
assert_contains "$APPLY_REPO/AGENTS.md" 'Project-owned guidance.'
[ -x "$APPLY_REPO/AGENTS.md" ] || fail "apply changed project-owned file mode"
[ -f "$APPLY_REPO/.touchstone.toml" ] || fail "apply omitted project contract"
[ -f "$APPLY_REPO/.touchstone-tracker.toml" ] || fail "apply omitted tracker contract"
git -C "$APPLY_REPO" add .touchstone.toml .touchstone-tracker.toml
git -C "$APPLY_REPO" commit -qm adopted
run_adoption "$ADOPTION/apply-twice.json" adopt --json --project "$APPLY_REPO"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "second adoption did not converge"
assert_contains "$ADOPTION/apply-twice.json" '"status":"current"'
assert_contains "$ADOPTION/apply-twice.json" '"changes":[]'

# A leftover pre-AUT-317 repository copy is the operator's to remove; a
# re-run of adopt must neither refresh nor delete it, and must not touch the
# project-owned declaration.
contract_hash="$(git -C "$APPLY_REPO" hash-object .touchstone.toml)"
tracker_hash="$(git -C "$APPLY_REPO" hash-object .touchstone-tracker.toml)"
mkdir -p "$APPLY_REPO/.touchstone"
printf 'stale managed steering\n' >"$APPLY_REPO/.touchstone/TOUCHSTONE.md"
git -C "$APPLY_REPO" add .touchstone/TOUCHSTONE.md
git -C "$APPLY_REPO" commit -qm stale-steering
run_adoption "$ADOPTION/readopt.json" adopt --json --project "$APPLY_REPO"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "re-running adopt on an adopted repository failed"
assert_contains "$ADOPTION/readopt.json" '"status":"current"'
assert_contains "$APPLY_REPO/.touchstone/TOUCHSTONE.md" 'stale managed steering'
[ "$contract_hash" = "$(git -C "$APPLY_REPO" hash-object .touchstone.toml)" ] \
  || fail "re-running adopt touched the project-owned validation declaration"
[ "$tracker_hash" = "$(git -C "$APPLY_REPO" hash-object .touchstone-tracker.toml)" ] \
  || fail "re-running adopt touched the project-owned tracker declaration"

DEFAULT_REPO="$ADOPTION/default-branch"
new_adoption_repo "$DEFAULT_REPO"
run_adoption "$ADOPTION/default-branch.out" adopt --project "$DEFAULT_REPO" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 5 ] || fail "apply wrote on the default branch"
assert_contains "$ADOPTION/default-branch.out.err" "cannot apply on the default branch 'main'"
[ ! -e "$DEFAULT_REPO/.touchstone.toml" ] || fail "default-branch refusal mutated the repository"

TRUNK_DEFAULT="$ADOPTION/trunk-default"
new_adoption_repo "$TRUNK_DEFAULT"
git -C "$TRUNK_DEFAULT" branch trunk
git -C "$TRUNK_DEFAULT" remote add upstream https://example.invalid/touchstone-consumer.git
git -C "$TRUNK_DEFAULT" update-ref refs/remotes/upstream/trunk HEAD
git -C "$TRUNK_DEFAULT" symbolic-ref refs/remotes/upstream/HEAD refs/remotes/upstream/trunk
run_adoption "$ADOPTION/trunk-default.out" adopt --project "$TRUNK_DEFAULT" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 0 ] || fail "renamed-remote trunk default incorrectly made local main a default branch"
[ -f "$TRUNK_DEFAULT/.touchstone.toml" ] || fail "renamed remote default metadata did not authorize feature apply"

MULTIPLE_REMOTE_DEFAULTS="$ADOPTION/multiple-remote-defaults"
new_adoption_repo "$MULTIPLE_REMOTE_DEFAULTS"
git -C "$MULTIPLE_REMOTE_DEFAULTS" switch -qc feat/adopt
git -C "$MULTIPLE_REMOTE_DEFAULTS" remote add origin https://example.invalid/origin.git
git -C "$MULTIPLE_REMOTE_DEFAULTS" remote add upstream https://example.invalid/upstream.git
git -C "$MULTIPLE_REMOTE_DEFAULTS" update-ref refs/remotes/origin/main HEAD
git -C "$MULTIPLE_REMOTE_DEFAULTS" update-ref refs/remotes/upstream/trunk HEAD
git -C "$MULTIPLE_REMOTE_DEFAULTS" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$MULTIPLE_REMOTE_DEFAULTS" symbolic-ref refs/remotes/upstream/HEAD refs/remotes/upstream/trunk
run_adoption "$ADOPTION/multiple-remote-defaults.out" adopt \
  --project "$MULTIPLE_REMOTE_DEFAULTS" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 5 ] || fail "apply guessed between multiple remote default branches"
assert_contains "$ADOPTION/multiple-remote-defaults.out.err" 'multiple remote default branches are configured'
[ ! -e "$MULTIPLE_REMOTE_DEFAULTS/.touchstone.toml" ] \
  || fail "multiple remote defaults mutated the repository"

MISSING_DEFAULT="$ADOPTION/missing-default"
new_adoption_repo "$MISSING_DEFAULT"
git -C "$MISSING_DEFAULT" switch -qc feat/adopt
git -C "$MISSING_DEFAULT" branch -D main >/dev/null
run_adoption "$ADOPTION/missing-default.out" adopt --project "$MISSING_DEFAULT" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 5 ] || fail "apply guessed a default branch without metadata"
assert_contains "$ADOPTION/missing-default.out.err" 'could not identify the repository default branch'

DANGLING_DEFAULT="$ADOPTION/dangling-default"
new_adoption_repo "$DANGLING_DEFAULT"
git -C "$DANGLING_DEFAULT" switch -qc feat/adopt
git -C "$DANGLING_DEFAULT" remote add origin https://example.invalid/dangling.git
git -C "$DANGLING_DEFAULT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
run_adoption "$ADOPTION/dangling-default.out" adopt --project "$DANGLING_DEFAULT" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 5 ] || fail "apply trusted a dangling remote default-branch ref"
assert_contains "$ADOPTION/dangling-default.out.err" 'could not identify the repository default branch'

HIDDEN_INPUT="$ADOPTION/hidden-input"
new_adoption_repo "$HIDDEN_INPUT"
cp "$ROOT/tests/fixtures/adoption-v1/repositories/anima/package.json" "$HIDDEN_INPUT/package.json"
cp "$ROOT/tests/fixtures/adoption-v1/repositories/anima/package-lock.json" "$HIDDEN_INPUT/package-lock.json"
git -C "$HIDDEN_INPUT" add package.json package-lock.json
git -C "$HIDDEN_INPUT" commit -qm npm
git -C "$HIDDEN_INPUT" update-index --assume-unchanged package.json
printf '{"scripts":{"test":"hidden command"}}\n' >"$HIDDEN_INPUT/package.json"
run_adoption "$ADOPTION/hidden-input.out" adopt --dry-run --project "$HIDDEN_INPUT"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "hidden compiler-input changes were accepted"
assert_contains "$ADOPTION/hidden-input.out.err" 'compiler input differs from HEAD: package.json'
git -C "$HIDDEN_INPUT" update-index --no-assume-unchanged package.json

AMBIGUOUS_DEFAULT="$ADOPTION/ambiguous-default"
new_adoption_repo "$AMBIGUOUS_DEFAULT"
git -C "$AMBIGUOUS_DEFAULT" branch master
git -C "$AMBIGUOUS_DEFAULT" switch -qc feat/adopt
run_adoption "$ADOPTION/ambiguous-default.out" adopt --project "$AMBIGUOUS_DEFAULT" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 5 ] || fail "apply guessed between local main and master"
assert_contains "$ADOPTION/ambiguous-default.out.err" 'could not identify the repository default branch'

DETACHED_REPO="$ADOPTION/detached"
new_adoption_repo "$DETACHED_REPO"
git -C "$DETACHED_REPO" checkout -q --detach
run_adoption "$ADOPTION/detached.out" adopt --project "$DETACHED_REPO" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 5 ] || fail "detached HEAD applied adoption"
assert_contains "$ADOPTION/detached.out.err" 'detached HEAD cannot apply adoption'

DIRTY_REPO="$ADOPTION/dirty"
new_adoption_repo "$DIRTY_REPO"
printf 'clean\n' >"$DIRTY_REPO/project.txt"
git -C "$DIRTY_REPO" add project.txt
git -C "$DIRTY_REPO" commit -qm project-file
git -C "$DIRTY_REPO" switch -qc feat/adopt
printf 'dirty\n' >>"$DIRTY_REPO/project.txt"
run_adoption "$ADOPTION/dirty.out" adopt --project "$DIRTY_REPO" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 5 ] || fail "dirty worktree applied adoption"
assert_contains "$ADOPTION/dirty.out.err" 'apply requires a clean worktree'
[ ! -e "$DIRTY_REPO/.touchstone.toml" ] || fail "dirty-worktree refusal mutated the repository"

HIDDEN_TRACKED_REPO="$ADOPTION/hidden-tracked"
new_adoption_repo "$HIDDEN_TRACKED_REPO"
git -C "$HIDDEN_TRACKED_REPO" switch -qc feat/adopt
git -C "$HIDDEN_TRACKED_REPO" update-index --assume-unchanged AGENTS.md
run_adoption "$ADOPTION/hidden-tracked.out" adopt --project "$HIDDEN_TRACKED_REPO" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 5 ] || fail "apply accepted a hidden tracked-file flag"
assert_contains "$ADOPTION/hidden-tracked.out.err" 'apply does not accept assume-unchanged or skip-worktree files'
[ ! -e "$HIDDEN_TRACKED_REPO/.touchstone.toml" ] || fail "hidden tracked-file refusal mutated the repository"
git -C "$HIDDEN_TRACKED_REPO" update-index --no-assume-unchanged AGENTS.md

FOREIGN_LOCK_REPO="$ADOPTION/foreign-index-lock"
new_adoption_repo "$FOREIGN_LOCK_REPO"
git -C "$FOREIGN_LOCK_REPO" switch -qc feat/adopt
FOREIGN_GIT_DIR="$(git -C "$FOREIGN_LOCK_REPO" rev-parse --absolute-git-dir)"
printf 'foreign index lock\n' >"$FOREIGN_GIT_DIR/index.lock"
run_adoption "$ADOPTION/foreign-index-lock.out" adopt --project "$FOREIGN_LOCK_REPO" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 5 ] || fail "apply accepted a foreign Git index lock"
assert_contains "$ADOPTION/foreign-index-lock.out.err" 'Git index lock already exists and was preserved'
[ "$(cat "$FOREIGN_GIT_DIR/index.lock")" = 'foreign index lock' ] \
  || fail "apply changed a foreign Git index lock"
[ ! -e "$FOREIGN_LOCK_REPO/.touchstone.toml" ] || fail "foreign-lock refusal mutated the repository"
rm -f "$FOREIGN_GIT_DIR/index.lock"

CMP_RACE_BIN="$ADOPTION/cmp-race-bin"
mkdir -p "$CMP_RACE_BIN"
cat >"$CMP_RACE_BIN/cmp" <<'EOF'
#!/usr/bin/env bash
if [ -e "$TOUCHSTONE_RACE_GIT_DIR/index.lock" ] && [ ! -e "$TOUCHSTONE_RACE_RECORD" ]; then
  if git -C "$TOUCHSTONE_RACE_REPO" switch -q main >/dev/null 2>&1; then
    printf 'switched\n' >"$TOUCHSTONE_RACE_RECORD"
  else
    printf 'blocked\n' >"$TOUCHSTONE_RACE_RECORD"
  fi
fi
exec "$TOUCHSTONE_REAL_CMP" "$@"
EOF
chmod +x "$CMP_RACE_BIN/cmp"
VERIFY_RACE_REPO="$ADOPTION/verification-branch-race"
VERIFY_RACE_RECORD="$ADOPTION/verification-branch-race.result"
new_adoption_repo "$VERIFY_RACE_REPO"
git -C "$VERIFY_RACE_REPO" switch -qc feat/adopt
VERIFY_RACE_GIT_DIR="$(git -C "$VERIFY_RACE_REPO" rev-parse --absolute-git-dir)"
VERIFY_RACE_REAL_CMP="$(command -v cmp)"
[ "$VERIFY_RACE_REAL_CMP" != "$CMP_RACE_BIN/cmp" ] \
  || fail "verification-race fixture resolved its cmp wrapper recursively"
PATH="$CMP_RACE_BIN:$PATH" TOUCHSTONE_REAL_CMP="$VERIFY_RACE_REAL_CMP" \
  TOUCHSTONE_RACE_GIT_DIR="$VERIFY_RACE_GIT_DIR" TOUCHSTONE_RACE_REPO="$VERIFY_RACE_REPO" \
  TOUCHSTONE_RACE_RECORD="$VERIFY_RACE_RECORD" \
  run_adoption "$ADOPTION/verification-branch-race.out" adopt \
  --project "$VERIFY_RACE_REPO" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 0 ] || fail "Git-native apply transaction failed during verification race"
[ "$(cat "$VERIFY_RACE_RECORD")" = blocked ] || fail "checkout moved the branch during final verification"
[ "$(git -C "$VERIFY_RACE_REPO" branch --show-current)" = feat/adopt ] \
  || fail "verification race moved adoption onto the default branch"
[ -f "$VERIFY_RACE_REPO/.touchstone.toml" ] || fail "verification-race apply omitted the project contract"

FAIL_GIT_BIN="$ADOPTION/fail-git-bin"
mkdir -p "$FAIL_GIT_BIN"
cat >"$FAIL_GIT_BIN/git" <<'EOF'
#!/usr/bin/env bash
arguments=("$@")
project=""
if [ "${1:-}" = -C ]; then
  project="$2"
  shift 2
fi
if [ "${1:-}" = status ] && [ "${TOUCHSTONE_STATUS_FAILURE:-false}" = true ]; then
  exit 92
fi
if [ "${1:-}" = symbolic-ref ] && [ "${TOUCHSTONE_SYMBOLIC_REF_FAILURE:-false}" = true ]; then
  exit 92
fi
if [ "${1:-}" = apply ] && [ "${2:-}" != --check ]; then
  "$TOUCHSTONE_REAL_GIT" "${arguments[@]}" || exit $?
  if [ -n "${TOUCHSTONE_SIGNAL_TARGET:-}" ]; then
    kill -TERM "$TOUCHSTONE_SIGNAL_TARGET"
    exit 143
  fi
  if [ "${TOUCHSTONE_CONCURRENT_WRITE:-false}" = true ]; then
    printf 'concurrent content\n' >"$project/.touchstone.toml"
  fi
  if [ -n "${TOUCHSTONE_SYMLINK_TARGET:-}" ]; then
    cp "$project/.touchstone.toml" "$TOUCHSTONE_SYMLINK_TARGET"
    rm "$project/.touchstone.toml"
    ln -s "$TOUCHSTONE_SYMLINK_TARGET" "$project/.touchstone.toml"
  fi
  exit 91
fi
exec "$TOUCHSTONE_REAL_GIT" "${arguments[@]}"
EOF
chmod +x "$FAIL_GIT_BIN/git"
REAL_GIT="$(command -v git)"

SIGNAL_REPO="$ADOPTION/signal-interrupted-apply"
new_adoption_repo "$SIGNAL_REPO"
git -C "$SIGNAL_REPO" switch -qc feat/adopt
SIGNAL_GIT_DIR="$(git -C "$SIGNAL_REPO" rev-parse --absolute-git-dir)"
set +e
PATH="$FAIL_GIT_BIN:$PATH" TOUCHSTONE_REAL_GIT="$REAL_GIT" \
  bash -c '
    export TOUCHSTONE_SIGNAL_TARGET=$$
    exec bash "$1" adopt --project "$2" --task "verify=true"
  ' _ "$ROOT/bin/touchstone" "$SIGNAL_REPO" \
  >"$ADOPTION/signal-interrupted-apply.out" 2>"$ADOPTION/signal-interrupted-apply.out.err"
SIGNAL_STATUS=$?
set -e
[ "$SIGNAL_STATUS" -eq 143 ] || fail "signal-interrupted apply returned $SIGNAL_STATUS instead of 143"
assert_contains "$ADOPTION/signal-interrupted-apply.out.err" \
  'interrupted adoption apply restored the original repository bytes'
[ "$(cat "$SIGNAL_REPO/AGENTS.md")" = "# Consumer

Project-owned guidance." ] || fail "signal-interrupted apply did not restore project guidance"
[ ! -e "$SIGNAL_REPO/.touchstone.toml" ] \
  || fail "signal-interrupted apply retained a partial project contract"
[ ! -e "$SIGNAL_GIT_DIR/index.lock" ] \
  || fail "signal-interrupted apply retained the native index lock"
[ ! -e "$SIGNAL_GIT_DIR/touchstone-worktree.lock" ] \
  || fail "signal-interrupted apply retained worktree-lock ownership"

STATUS_FAILURE_REPO="$ADOPTION/status-failure"
new_adoption_repo "$STATUS_FAILURE_REPO"
git -C "$STATUS_FAILURE_REPO" switch -qc feat/adopt
PATH="$FAIL_GIT_BIN:$PATH" TOUCHSTONE_REAL_GIT="$REAL_GIT" TOUCHSTONE_STATUS_FAILURE=true \
  run_adoption "$ADOPTION/status-failure.out" adopt --project "$STATUS_FAILURE_REPO" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 6 ] || fail "failed cleanliness probe did not fail closed"
assert_contains "$ADOPTION/status-failure.out.err" 'could not verify that the worktree is clean'
[ ! -e "$STATUS_FAILURE_REPO/.touchstone.toml" ] \
  || fail "failed cleanliness probe mutated the repository"

DEFAULT_REF_FAILURE_REPO="$ADOPTION/default-ref-failure"
new_adoption_repo "$DEFAULT_REF_FAILURE_REPO"
git -C "$DEFAULT_REF_FAILURE_REPO" switch -qc feat/adopt
git -C "$DEFAULT_REF_FAILURE_REPO" remote add origin https://example.invalid/default-ref-failure.git
git -C "$DEFAULT_REF_FAILURE_REPO" update-ref refs/remotes/origin/main HEAD
git -C "$DEFAULT_REF_FAILURE_REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
PATH="$FAIL_GIT_BIN:$PATH" TOUCHSTONE_REAL_GIT="$REAL_GIT" TOUCHSTONE_SYMBOLIC_REF_FAILURE=true \
  run_adoption "$ADOPTION/default-ref-failure.out" adopt --project "$DEFAULT_REF_FAILURE_REPO" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 6 ] || fail "default-ref inspection failure did not fail closed"
assert_contains "$ADOPTION/default-ref-failure.out.err" 'could not inspect the repository default branch'
[ ! -e "$DEFAULT_REF_FAILURE_REPO/.touchstone.toml" ] \
  || fail "default-ref inspection failure mutated the repository"

ROLLBACK_REPO="$ADOPTION/rollback"
new_adoption_repo "$ROLLBACK_REPO"
git -C "$ROLLBACK_REPO" switch -qc feat/adopt
PATH="$FAIL_GIT_BIN:$PATH" TOUCHSTONE_REAL_GIT="$REAL_GIT" \
  run_adoption "$ADOPTION/rollback.out" adopt --project "$ROLLBACK_REPO" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 6 ] || fail "injected apply failure did not report an operational failure"
[ "$(cat "$ROLLBACK_REPO/AGENTS.md")" = "# Consumer

Project-owned guidance." ] || fail "failed apply did not restore project guidance"
[ ! -e "$ROLLBACK_REPO/.touchstone.toml" ] || fail "failed apply retained a partial project contract"
[ ! -e "$ROLLBACK_REPO/.touchstone" ] || fail "failed apply retained a partial managed directory"

CONCURRENT_REPO="$ADOPTION/concurrent"
new_adoption_repo "$CONCURRENT_REPO"
git -C "$CONCURRENT_REPO" switch -qc feat/adopt
PATH="$FAIL_GIT_BIN:$PATH" TOUCHSTONE_REAL_GIT="$REAL_GIT" TOUCHSTONE_CONCURRENT_WRITE=true \
  run_adoption "$ADOPTION/concurrent.out" adopt --project "$CONCURRENT_REPO" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 6 ] || fail "concurrent apply did not report an operational failure"
[ "$(cat "$CONCURRENT_REPO/.touchstone.toml")" = 'concurrent content' ] \
  || fail "apply rollback overwrote unexpected concurrent content"
assert_contains "$ADOPTION/concurrent.out.err" 'unexpected concurrent content was preserved'

SYMLINK_ROLLBACK_REPO="$ADOPTION/symlink-rollback"
SYMLINK_ROLLBACK_TARGET="$ADOPTION/symlink-rollback-target"
new_adoption_repo "$SYMLINK_ROLLBACK_REPO"
git -C "$SYMLINK_ROLLBACK_REPO" switch -qc feat/adopt
PATH="$FAIL_GIT_BIN:$PATH" TOUCHSTONE_REAL_GIT="$REAL_GIT" \
  TOUCHSTONE_SYMLINK_TARGET="$SYMLINK_ROLLBACK_TARGET" \
  run_adoption "$ADOPTION/symlink-rollback.out" adopt --project "$SYMLINK_ROLLBACK_REPO" --task 'verify=true'
[ "$ADOPTION_STATUS" -eq 6 ] || fail "symlink-swapped rollback did not report an operational failure"
[ -L "$SYMLINK_ROLLBACK_REPO/.touchstone.toml" ] || fail "rollback replaced unexpected concurrent symlink content"
assert_contains "$ADOPTION/symlink-rollback.out.err" 'unexpected concurrent content was preserved'
assert_contains "$SYMLINK_ROLLBACK_TARGET" 'schema = 1'

echo "validation engine tests passed"

(
  # tests/test-fresh-consumer.sh — public consumer-boundary compatibility harness.

  set -euo pipefail

  ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
  CLI="$ROOT/bin/touchstone"
  RUNNER="$ROOT/scripts/touchstone-run.sh"
  FIXTURES="$ROOT/evals/fresh-consumer/v1"
  POLICY="$ROOT/policy/github/touchstone-main.json"
  TMP="$(mktemp -d -t touchstone-fresh-consumer.XXXXXX)"
  trap 'rm -rf "$TMP"' EXIT
  ROOT_STATUS_BEFORE="$(git -C "$ROOT" status --porcelain=v1)"
  TOOL_BIN="$TMP/tool-bin"
  mkdir -p "$TOOL_BIN"
  cat >"$TOOL_BIN/tool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$(basename "$0")" "$*" >>"$TOUCHSTONE_TOOL_LOG"
EOF
  chmod +x "$TOOL_BIN/tool"
  for tool in npm uv swift; do ln -s tool "$TOOL_BIN/$tool"; done

  fail() {
    echo "FAIL: $*" >&2
    exit 1
  }

  assert_contains() {
    grep -qF -- "$2" "$1" || fail "$1 does not contain: $2"
  }

  assert_clean() {
    [ -z "$(git -C "$1" status --porcelain=v1)" ] || fail "$2 mutated the consumer"
  }

  assert_boundary_clean() {
    local boundary="$1" actual
    actual="$(find "$boundary" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)"
    [ "$actual" = 'outside
project' ] || fail "$2 wrote an unexpected sibling outside the consumer"
    assert_clean "$boundary/outside" "$2 outside sentinel"
  }

  init_repo() {
    local repo="$1"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.name fresh-consumer
    git -C "$repo" config user.email fresh-consumer@example.invalid
    git -C "$repo" add .
    git -C "$repo" commit -qm fixture
    git -C "$repo" update-ref refs/remotes/origin/main HEAD
    git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  }

  run_cli() {
    local output="$1"
    shift
    RUN_STATUS=0
    set +e
    "$CLI" "$@" >"$output" 2>"$output.err"
    RUN_STATUS=$?
    set -e
  }

  echo "==> data-driven detectors compile reviewable, idempotent consumer contracts"
  for fixture in "$FIXTURES"/*; do
    [ -d "$fixture" ] || continue
    id="$(basename "$fixture")"
    boundary="$TMP/project-$id"
    repo="$boundary/project"
    mkdir -p "$repo" "$boundary/outside"
    printf '%s\n' 'outside ownership sentinel' >"$boundary/outside/sentinel"
    init_repo "$boundary/outside"
    cp -R "$fixture/." "$repo/"
    IFS="$(printf '\t')" read -r outcome profile expected expected_setup <"$repo/expect.tsv"
    printf '%s\n' 'PROJECT AGENT PROSE' >"$repo/AGENTS.md"
    printf '%s\n' 'PROJECT CLAUDE PROSE' >"$repo/CLAUDE.md"
    printf '%s\n' 'PROJECT GEMINI PROSE' >"$repo/GEMINI.md"
    printf '%s\n' 'legacy content must survive' >"$repo/legacy.keep"
    init_repo "$repo"
    git -C "$repo" switch -q -c feat/adopt
    args=(adopt --project "$repo")
    if [ -f "$repo/manual-task" ]; then args+=(--task "$(cat "$repo/manual-task")"); fi

    if [ "$outcome" = refusal ]; then
      run_cli "$TMP/$id-refusal" "${args[@]}" --dry-run --json
      [ "$RUN_STATUS" -eq 4 ] || fail "$id ambiguity did not refuse with exit 4"
      assert_contains "$TMP/$id-refusal" "$expected"
      assert_clean "$repo" "$id refusal"
      assert_boundary_clean "$boundary" "$id refusal"
      continue
    fi

    run_cli "$TMP/$id-check" "${args[@]}" --check --json
    [ "$RUN_STATUS" -eq 3 ] || fail "$id check did not report a required plan"
    assert_contains "$TMP/$id-check" "\"profile\":\"$profile\""
    assert_clean "$repo" "$id check"

    run_cli "$TMP/$id-dry-1" "${args[@]}" --dry-run --json
    [ "$RUN_STATUS" -eq 0 ] || fail "$id dry-run failed"
    run_cli "$TMP/$id-dry-2" "${args[@]}" --dry-run --json
    [ "$RUN_STATUS" -eq 0 ] || fail "$id repeated dry-run failed"
    cmp -s "$TMP/$id-dry-1" "$TMP/$id-dry-2" || fail "$id dry-run was nondeterministic"
    assert_clean "$repo" "$id dry-run"
    run_cli "$TMP/$id-policy-boundary" "${args[@]}" --dry-run
    assert_contains "$TMP/$id-policy-boundary" 'remote policy: not inspected here; run: touchstone policy status'

    run_cli "$TMP/$id-apply" "${args[@]}"
    [ "$RUN_STATUS" -eq 0 ] || fail "$id apply failed"
    # Declarations only: instruction files untouched, no routed directory.
    expected_adoption_status='?? .touchstone-tracker.toml
?? .touchstone.toml'
    [ "$(git -C "$repo" status --porcelain=v1 | LC_ALL=C sort)" = "$expected_adoption_status" ] \
      || fail "$id adoption changed files outside the declared consumer boundary"
    git -C "$repo" add .touchstone.toml .touchstone-tracker.toml
    git -C "$repo" commit -qm "adopt Touchstone"
    assert_clean "$repo" "$id committed adoption"
    run_cli "$TMP/$id-repeat" adopt --project "$repo" --check --json
    if [ "$RUN_STATUS" -ne 0 ]; then
      cat "$TMP/$id-repeat" "$TMP/$id-repeat.err" >&2
      fail "$id second adoption was not current"
    fi
    assert_contains "$repo/.touchstone.toml" "$expected"
    if [ "$expected_setup" = - ]; then
      ! grep -q '^setup = ' "$repo/.touchstone.toml" || fail "$id generated an unexpected setup command"
    else
      assert_contains "$repo/.touchstone.toml" "$expected_setup"
    fi
    bash "$RUNNER" validate --check-contract --project "$repo" >/dev/null

    tool_log="$TMP/$id-tool.log"
    : >"$tool_log"
    if ! TOUCHSTONE_TOOL_LOG="$tool_log" PATH="$TOOL_BIN:$PATH" \
      "$CLI" validate --project "$repo" >"$TMP/$id-validation" 2>"$TMP/$id-validation.err"; then
      cat "$TMP/$id-validation" "$TMP/$id-validation.err" >&2
      fail "$id generated command did not execute"
    fi
    expected_command="${expected#command = \"}"
    expected_command="${expected_command%\"}"
    case "$expected_command" in
      npm\ * | uv\ * | swift\ *) assert_contains "$tool_log" "$expected_command" ;;
    esac
    if [ "$expected_setup" != - ]; then
      setup_command="${expected_setup#setup = \"}"
      setup_command="${setup_command%\"}"
      assert_contains "$tool_log" "$setup_command"
    fi

    while IFS= read -r target_path; do
      [ -d "$repo/$target_path" ] || fail "$id generated missing target path: $target_path"
    done < <(awk -F '"' '/^path = / { print $2 }' "$repo/.touchstone.toml")
    awk -F '"' '/^command = / { if ($2 == "") exit 1; found=1 } END { exit !found }' \
      "$repo/.touchstone.toml" || fail "$id generated an empty or missing command"
    # Steering reaches agents through the installed tool, never through the
    # repository: adoption must leave instruction files untouched and write
    # no routed copies (AUT-317).
    for steering in AGENTS.md CLAUDE.md GEMINI.md; do
      case "$steering" in AGENTS.md) project_prose='PROJECT AGENT PROSE' ;; *) project_prose="PROJECT ${steering%%.*} PROSE" ;; esac
      assert_contains "$repo/$steering" "$project_prose"
      if grep -qF 'touchstone:steering' "$repo/$steering"; then
        fail "$id installed a repository steering block in $steering"
      fi
    done
    [ -d "$repo/.touchstone" ] && fail "$id wrote routed steering copies into the repository"
    [ -f "$repo/legacy.keep" ] || fail "$id adoption deleted project-owned legacy content"
    if find "$repo" -type f \( -name 'touchstone-run.sh' -o -name 'touchstone-pr.sh' \
      -o -name 'update-project.sh' -o -name '*registry*' -o -name '*sync*' \) -print -quit | grep -q .; then
      fail "$id adoption vendored implementation or background machinery"
    fi
    assert_boundary_clean "$boundary" "$id adoption"
  done

  echo "==> old schema-v1 consumers validate and adopt through one explicit transition"
  upgrade_repo="$TMP/upgrade-consumer"
  mkdir -p "$upgrade_repo/tests"
  cp "$FIXTURES/manual/tests/pass.sh" "$upgrade_repo/tests/pass.sh"
  chmod +x "$upgrade_repo/tests/pass.sh"
  cat >"$upgrade_repo/.touchstone.toml" <<'EOF'
schema = 1

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "validate"
target = "root"
command = "bash tests/pass.sh"
required = true
EOF
  printf '%s\n' 'PROJECT AGENT PROSE' >"$upgrade_repo/AGENTS.md"
  printf '%s\n' 'PROJECT CLAUDE PROSE' >"$upgrade_repo/CLAUDE.md"
  printf '%s\n' 'PROJECT GEMINI PROSE' >"$upgrade_repo/GEMINI.md"
  init_repo "$upgrade_repo"
  git -C "$upgrade_repo" switch -q -c feat/upgrade
  run_cli "$TMP/old-v1-runtime" validate --project "$upgrade_repo" --json
  [ "$RUN_STATUS" -eq 0 ] || fail "newer runtime rejected an older valid v1 contract"
  command_before="$(grep '^command = ' "$upgrade_repo/.touchstone.toml")"
  run_cli "$TMP/upgrade-check" adopt --check --json --project "$upgrade_repo" \
    --tracker linear --tracker-prefix AUT
  [ "$RUN_STATUS" -eq 3 ] || fail "adoption check did not expose the supported v1 transition"
  assert_clean "$upgrade_repo" "adoption check"
  run_cli "$TMP/upgrade-dry" adopt --dry-run --json --project "$upgrade_repo" \
    --tracker linear --tracker-prefix AUT
  [ "$RUN_STATUS" -eq 0 ] || fail "adoption dry-run failed"
  assert_clean "$upgrade_repo" "adoption dry-run"
  run_cli "$TMP/upgrade-apply" adopt --project "$upgrade_repo" \
    --tracker linear --tracker-prefix AUT
  [ "$RUN_STATUS" -eq 0 ] || fail "adoption apply failed"
  [ "$(grep '^command = ' "$upgrade_repo/.touchstone.toml")" = "$command_before" ] \
    || fail "adoption rewrote a project-owned validation command"
  assert_contains "$upgrade_repo/.touchstone-tracker.toml" 'type = "linear"'
  assert_contains "$upgrade_repo/.touchstone-tracker.toml" 'key_prefix = "AUT"'
  git -C "$upgrade_repo" add .touchstone-tracker.toml
  git -C "$upgrade_repo" commit -qm "declare tracker"
  run_cli "$TMP/upgrade-repeat" adopt --check --json --project "$upgrade_repo"
  if [ "$RUN_STATUS" -ne 0 ]; then
    cat "$TMP/upgrade-repeat" "$TMP/upgrade-repeat.err" >&2
    fail "repeated adoption was not current"
  fi
  # Steering ships with the tool now. `upgrade` upgrades the *tool* (Homebrew
  # or an install.sh prefix); the 2.x invocation that refreshed repository
  # copies is refused from a source checkout and writes nothing.
  run_cli "$TMP/upgrade-gone" upgrade --check --json --project "$upgrade_repo" || true
  [ "$RUN_STATUS" -ne 0 ] || fail "the 2.x repository-refresh invocation of upgrade must be refused, got exit 0"
  grep -q "neither a Homebrew install nor an install.sh prefix" "$TMP/upgrade-gone.err" \
    || fail "upgrade did not explain the install kinds it serves: $(cat "$TMP/upgrade-gone.err")"

  echo "==> local and pinned-workflow adapters share validation semantics"
  policy_repo="$TMP/policy-consumer"
  mkdir -p "$policy_repo/tests" "$policy_repo/.github/workflows"
  cp "$FIXTURES/manual/tests/pass.sh" "$policy_repo/tests/pass.sh"
  chmod +x "$policy_repo/tests/pass.sh"
  cp "$upgrade_repo/.touchstone.toml" "$policy_repo/.touchstone.toml"
  printf '%s\n' 'name: consumer-local-bypass' >"$policy_repo/.github/workflows/validate.yml"
  init_repo "$policy_repo"
  git -C "$policy_repo" switch -q -c feat/policy
  run_cli "$TMP/local-validation" validate --project "$policy_repo" --json
  [ "$RUN_STATUS" -eq 0 ] || fail "local validation adapter failed"
  bash "$RUNNER" validate --project "$policy_repo" --json >"$TMP/workflow-validation"
  cmp -s "$TMP/local-validation" "$TMP/workflow-validation" \
    || fail "local and required-workflow adapters disagreed"
  rm "$policy_repo/.github/workflows/validate.yml"
  bash "$RUNNER" validate --project "$policy_repo" --json >"$TMP/workflow-after-delete"
  cmp -s "$TMP/workflow-validation" "$TMP/workflow-after-delete" \
    || fail "consumer workflow deletion changed the central validation verdict"

  jq -e '
  .workflowSource.repository != .repository
  and (.managedRuleset.rules[] | select(.type == "workflows") | .parameters.workflows[]
    | select(.path == ".github/workflows/validate.yml")
    | (.sha | test("^[0-9a-f]{40}$"))
    and .ref == "refs/heads/main")
  and .workflowSource.branchProtection.enforce_admins
  and .workflowSource.branchProtection.required_pull_request_reviews
  and .workflowSource.branchProtection.required_conversation_resolution
' "$POLICY" >/dev/null || fail "required workflow is not pinned to a separately protected source"

  echo "==> ordinary validation, install, and PR observations do not mutate projects"
  status_before="$(git -C "$policy_repo" status --porcelain=v1)"
  bash "$RUNNER" validate --project "$policy_repo" --json >/dev/null
  (cd "$policy_repo" && "$CLI" --help >/dev/null)
  mkdir -p "$TMP/mock-bin"
  cat >"$TMP/mock-bin/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'auth status') exit 0 ;;
  'repo view') printf '%s\n' $'autumngarage/consumer\thttps://github.com/autumngarage/consumer' ;;
  'pr view') printf '%s\n' $'1\tOPEN\thttps://example.invalid/pr/1\t1111111111111111111111111111111111111111\tmain\t2222222222222222222222222222222222222222\tCLEAN\tfalse' ;;
esac
EOF
  chmod +x "$TMP/mock-bin/gh"
  cat >"$TMP/mock-bin/brew" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-} ${2:-}" = 'upgrade touchstone' ] || exit 2
mkdir -p "$TOUCHSTONE_TEST_INSTALL_PREFIX"
printf '%s\n' upgraded >"$TOUCHSTONE_TEST_INSTALL_PREFIX/version"
EOF
  chmod +x "$TMP/mock-bin/brew"
  (
    cd "$policy_repo"
    TOUCHSTONE_TEST_INSTALL_PREFIX="$TMP/install-prefix" PATH="$TMP/mock-bin:$PATH" \
      brew upgrade touchstone
  )
  [ -f "$TMP/install-prefix/version" ] || fail "Homebrew adapter did not update its installation prefix"
  PATH="$TMP/mock-bin:$PATH" TOUCHSTONE_READ_ATTEMPTS=1 "$CLI" pr status 1 \
    --project "$policy_repo" --json >/dev/null
  [ "$(git -C "$policy_repo" status --porcelain=v1)" = "$status_before" ] \
    || fail "ordinary validation, installed-tool, or PR observation mutated the project"

  echo "==> unsafe apply states refuse without partial writes"
  safety_repo="$TMP/safety-consumer"
  mkdir -p "$safety_repo"
  cp -R "$FIXTURES/node/." "$safety_repo/"
  init_repo "$safety_repo"
  default_status_before="$(git -C "$safety_repo" status --porcelain=v1)"
  run_cli "$TMP/default-apply" adopt --project "$safety_repo"
  [ "$RUN_STATUS" -eq 5 ] || fail "default-branch apply did not refuse"
  [ "$(git -C "$safety_repo" status --porcelain=v1)" = "$default_status_before" ] \
    || fail "default-branch refusal partially wrote"
  git -C "$safety_repo" switch -q -c feat/dirty
  printf '%s\n' dirty >"$safety_repo/README.md"
  dirty_status_before="$(git -C "$safety_repo" status --porcelain=v1)"
  run_cli "$TMP/dirty-apply" adopt --project "$safety_repo"
  [ "$RUN_STATUS" -eq 5 ] || fail "dirty apply did not refuse"
  [ "$(git -C "$safety_repo" status --porcelain=v1)" = "$dirty_status_before" ] \
    || fail "dirty refusal partially wrote"

  [ "$(git -C "$ROOT" status --porcelain=v1)" = "$ROOT_STATUS_BEFORE" ] \
    || fail "consumer operations mutated the Touchstone source checkout"

  echo "==> PASS: fresh-consumer adoption, compatibility, policy, and safety contracts hold"
)

# ---------------------------------------------------------------------------
# Schema-2 execution stages (AUT-306). A project invariant that holds per
# commit cannot be enforced by a check that only runs at push -- by then the
# commit exists and the cheap fix is gone. These assertions cover stage
# selection, schema-1 compatibility, and fail-closed handling.
echo ""
echo "==> Schema-2 execution stages"
RUN_ENGINE="$ROOT/scripts/touchstone-run.sh"
STAGE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-stages.XXXXXX")"
# Do not install a second EXIT trap: it would replace the suite's own and
# leak the primary workspace. Extend the existing cleanup instead.
trap 'rm -rf "$TMP_DIR" "$STAGE_TMP"' EXIT
FAILURES=0
fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}
pass() { echo "  ok: $*"; }
make_stage_project() {
  local dir="$1" body="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name Test
  printf '%s\n' "$body" >"$dir/.touchstone.toml"
  git -C "$dir" add -A >/dev/null 2>&1
  git -C "$dir" commit -qm init >/dev/null 2>&1
}

BOTH="$STAGE_TMP/both"
make_stage_project "$BOTH" 'schema = 2

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "suite"
target = "root"
command = "echo ENFORCE_SENTINEL"
required = true

[[validation.tasks]]
name = "guard"
target = "root"
stage = "commit"
command = "echo COMMIT_SENTINEL"
required = true'

echo "==> the enforcement run never executes an authoring guard"
out="$(bash "$RUN_ENGINE" validate --project "$BOTH" 2>&1)"
case "$out" in
  *COMMIT_SENTINEL*) fail "a commit-stage task ran in the enforcement stage" ;;
  *ENFORCE_SENTINEL*) pass "enforce stage ran only its own task" ;;
  *) fail "enforce stage produced no sentinel: $out" ;;
esac

echo "==> the commit stage runs only authoring guards"
out="$(bash "$RUN_ENGINE" validate --stage commit --project "$BOTH" 2>&1)"
case "$out" in
  *ENFORCE_SENTINEL*) fail "an enforce-stage task ran in the commit stage" ;;
  *COMMIT_SENTINEL*) pass "commit stage ran only its own task" ;;
  *) fail "commit stage produced no sentinel: $out" ;;
esac

echo "==> schema 1 means exactly what it meant"
V1="$STAGE_TMP/v1"
make_stage_project "$V1" 'schema = 1

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "suite"
target = "root"
command = "echo V1_SENTINEL"
required = true'
out="$(bash "$RUN_ENGINE" validate --project "$V1" 2>&1)"
case "$out" in
  *V1_SENTINEL*"passed"*) pass "a schema-1 declaration runs unchanged at the default stage" ;;
  *) fail "schema 1 changed behavior: $out" ;;
esac

# A stage key in a schema-1 file is a contract error, not a silent default:
# accepting it would let a v1 consumer believe it declared a guard that never
# runs anywhere.
V1STAGE="$STAGE_TMP/v1stage"
make_stage_project "$V1STAGE" 'schema = 1

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "suite"
target = "root"
stage = "commit"
command = "true"
required = true'
if bash "$RUN_ENGINE" validate --project "$V1STAGE" >/dev/null 2>&1; then
  fail "schema 1 accepted a stage key"
else
  pass "schema 1 rejects a stage key"
fi

echo "==> an empty commit stage passes; an empty enforcement stage fails"
ONLY="$STAGE_TMP/enforce-only"
make_stage_project "$ONLY" 'schema = 2

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "suite"
target = "root"
command = "true"
required = true'
if bash "$RUN_ENGINE" validate --stage commit --project "$ONLY" >/dev/null 2>&1; then
  pass "no authoring guards is a pass at the commit stage"
else
  fail "a project without authoring guards failed its commit stage"
fi

GUARDONLY="$STAGE_TMP/guard-only"
make_stage_project "$GUARDONLY" 'schema = 2

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "guard"
target = "root"
stage = "commit"
command = "true"
required = true'
if bash "$RUN_ENGINE" validate --project "$GUARDONLY" >/dev/null 2>&1; then
  fail "a declaration with no enforcement task passed the gate"
else
  pass "no enforcement task still fails: a gate must run something"
fi

echo "==> unknown stages fail closed"
if bash "$RUN_ENGINE" validate --stage nope --project "$BOTH" >/dev/null 2>&1; then
  fail "an unknown --stage was accepted"
else
  pass "an unknown --stage is rejected"
fi
BADSTAGE="$STAGE_TMP/badstage"
make_stage_project "$BADSTAGE" 'schema = 2

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "suite"
target = "root"
stage = "prepush"
command = "true"
required = true'
if bash "$RUN_ENGINE" validate --project "$BADSTAGE" >/dev/null 2>&1; then
  fail "an unknown declared stage was accepted"
else
  pass "an unknown declared stage is rejected"
fi

echo "==> an unsupported schema still fails closed"
V3="$STAGE_TMP/v3"
make_stage_project "$V3" 'schema = 3

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "suite"
target = "root"
command = "true"
required = true'
if bash "$RUN_ENGINE" validate --project "$V3" >/dev/null 2>&1; then
  fail "schema 3 was accepted"
else
  pass "an unsupported schema is rejected"
fi

echo "==> a commit-only target absent in CI does not fail the enforcement run"
# An authoring guard may point at a directory that exists on a developer's
# machine and not on a runner. Preflighting every declared target regardless
# of stage would fail the gate over a path the enforcement run never touches.
SPLITTARGET="$STAGE_TMP/split-target"
make_stage_project "$SPLITTARGET" 'schema = 2

[validation]
runtime = "bash"

[[validation.targets]]
name = "src"
path = "src"

[[validation.targets]]
name = "devonly"
path = "dev-workspace"

[[validation.tasks]]
name = "suite"
target = "src"
command = "true"
required = true

[[validation.tasks]]
name = "guard"
target = "devonly"
stage = "commit"
command = "true"
required = true'
mkdir -p "$SPLITTARGET/src"
if bash "$RUN_ENGINE" validate --project "$SPLITTARGET" >/dev/null 2>&1; then
  pass "the enforcement run ignores a target only the commit stage uses"
else
  fail "an absent commit-stage target failed the enforcement run"
fi
# The converse must still hold: a target the selected stage uses is checked.
if bash "$RUN_ENGINE" validate --stage commit --project "$SPLITTARGET" >/dev/null 2>&1; then
  fail "the commit stage passed with its own target missing"
else
  pass "a missing target the selected stage uses still fails"
fi
# A contract check validates the whole declaration rather than one stage's
# slice: the adapters call it to ask whether the declaration is valid at all.
if bash "$RUN_ENGINE" validate --check-contract --project "$SPLITTARGET" >/dev/null 2>&1; then
  fail "--check-contract passed a declaration whose commit-stage target is missing"
else
  pass "--check-contract validates every declared target regardless of stage"
fi

echo "==> a target no task references keeps its validation"
# Skipping a target belongs to stage ownership: a target some other stage owns
# is skipped, a target nobody owns is still checked, which is what schema 1
# has always done.
ORPHAN="$STAGE_TMP/orphan-target"
make_stage_project "$ORPHAN" 'schema = 1

[validation]
runtime = "bash"

[[validation.targets]]
name = "src"
path = "src"

[[validation.targets]]
name = "orphan"
path = "nonexistent"

[[validation.tasks]]
name = "suite"
target = "src"
command = "true"
required = true'
mkdir -p "$ORPHAN/src"
if bash "$RUN_ENGINE" validate --project "$ORPHAN" >/dev/null 2>&1; then
  fail "an unreferenced broken target stopped being validated"
else
  pass "an unreferenced broken target still fails validation"
fi

echo "==> contract identity reports the declared schema, not a fixed version"
V2ID="$STAGE_TMP/v2-identity"
make_stage_project "$V2ID" 'schema = 2

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "suite"
target = "root"
command = "true"
required = true'
out="$(bash "$RUN_ENGINE" validate --check-contract --project "$V2ID" 2>&1)"
case "$out" in
  *"schema-v2 contract is valid"*) pass "a schema-2 declaration reports v2 identity" ;;
  *) fail "contract identity did not follow the declaration: $out" ;;
esac
out="$(bash "$RUN_ENGINE" validate --check-contract --project "$V1" 2>&1)"
case "$out" in
  *"schema-v1 contract is valid"*) pass "a schema-1 declaration still reports v1 identity" ;;
  *) fail "schema-1 identity changed: $out" ;;
esac

echo "==> the documented commit-hook wiring is runnable as written"
# The contract shows a pre-commit entry invoking the commit stage. If that
# entry is wrong the feature is undiscoverable in practice, so the exact
# command is exercised against a project with a guard.
WIRED="$STAGE_TMP/wired"
make_stage_project "$WIRED" 'schema = 2

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "suite"
target = "root"
command = "true"
required = true

[[validation.tasks]]
name = "guard"
target = "root"
stage = "commit"
command = "echo WIRED_GUARD"
required = true'
wired_entry="$(grep -o 'touchstone validate --stage commit' "$ROOT/docs/validation-contract.md" | head -1)"
if [ -n "$wired_entry" ]; then
  pass "the contract documents a commit-stage hook entry"
else
  fail "the contract no longer documents how to wire the commit stage"
fi
out="$(cd "$WIRED" && bash "$RUN_ENGINE" validate --stage commit 2>&1)"
case "$out" in
  *WIRED_GUARD*) pass "the documented invocation runs the project's guard" ;;
  *) fail "the documented invocation did not run the guard: $out" ;;
esac

echo "==> setup does not run for a stage with no tasks"
SETUPONLY="$STAGE_TMP/setup-only"
make_stage_project "$SETUPONLY" 'schema = 2

[validation]
runtime = "bash"
setup = "echo SETUP_SENTINEL"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "suite"
target = "root"
command = "true"
required = true'
out="$(bash "$RUN_ENGINE" validate --project "$SETUPONLY" 2>&1)"
case "$out" in
  *SETUP_SENTINEL*) pass "setup runs when the selected stage has tasks" ;;
  *) fail "setup did not run for the enforcement stage" ;;
esac
out="$(bash "$RUN_ENGINE" validate --stage commit --project "$SETUPONLY" 2>&1)"
case "$out" in
  *SETUP_SENTINEL*) fail "setup ran for a stage with no tasks" ;;
  *) pass "setup is skipped when the selected stage has no tasks" ;;
esac

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES stage check(s) failed" >&2
  exit 1
fi
echo "==> PASS: execution stages select tasks and schema 1 is unchanged"
