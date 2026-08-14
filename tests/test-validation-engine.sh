#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/scripts/touchstone-run.sh"
COMPAT="$ROOT/scripts/check-legacy-ci.sh"
CLI="$ROOT/bin/touchstone"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
assert_contains() { grep -Fq "$2" "$1" || fail "$1 does not contain: $2"; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "$1 unexpectedly contains: $2"; }

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

echo "==> unavailable and command-owned 126/127 stay distinct"
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

  OWNED="$TMP_DIR/owned-$code"
  write_contract "$OWNED" "bash -c \\\"exit $code\\\""
  run_capture "$OWNED" "$TMP_DIR/owned-$code.out" --json
  [ "$RUN_STATUS" -eq "$code" ] || fail "command-owned exit did not retain $code"
  assert_contains "$TMP_DIR/owned-$code.out" '"ran":1'
  assert_contains "$TMP_DIR/owned-$code.out" '"reason":"command-failed"'
done

MISSING_INTERPRETER="$TMP_DIR/missing-interpreter"
write_contract "$MISSING_INTERPRETER" "needs-missing-runtime"
printf '#!/missing-touchstone-runtime\nexit 0\n' >"$MISSING_INTERPRETER/needs-missing-runtime"
chmod +x "$MISSING_INTERPRETER/needs-missing-runtime"
PATH="$MISSING_INTERPRETER:$PATH" run_capture \
  "$MISSING_INTERPRETER" "$TMP_DIR/missing-interpreter.out" --json
case "$RUN_STATUS" in 126 | 127) ;; *) fail "missing shebang interpreter did not retain the shell status" ;; esac
assert_contains "$TMP_DIR/missing-interpreter.out" '"ran":0'
assert_contains "$TMP_DIR/missing-interpreter.out" '"reason":"command-not-started"'

RELATIVE_INTERPRETER="$TMP_DIR/relative-interpreter"
write_contract "$RELATIVE_INTERPRETER" "./relative-interpreter-script || true"
printf '#!bash\nbody must not run\n' >"$RELATIVE_INTERPRETER/relative-interpreter-script"
chmod +x "$RELATIVE_INTERPRETER/relative-interpreter-script"
run_capture "$RELATIVE_INTERPRETER" "$TMP_DIR/relative-interpreter.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "non-path shebang interpreter was resolved through PATH"
assert_contains "$TMP_DIR/relative-interpreter.out" '"ran":0'
assert_contains "$TMP_DIR/relative-interpreter.out" '"reason":"command-not-started"'

DIRECTORY_INTERPRETER="$TMP_DIR/directory-interpreter"
mkdir -p "$DIRECTORY_INTERPRETER/interpreter-dir"
write_contract "$DIRECTORY_INTERPRETER" "./directory-interpreter-script || true"
printf '#!%s\nbody must not run\n' "$DIRECTORY_INTERPRETER/interpreter-dir" >"$DIRECTORY_INTERPRETER/directory-interpreter-script"
chmod +x "$DIRECTORY_INTERPRETER/directory-interpreter-script"
run_capture "$DIRECTORY_INTERPRETER" "$TMP_DIR/directory-interpreter.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "directory shebang interpreter was treated as executable"
assert_contains "$TMP_DIR/directory-interpreter.out" '"ran":0'
assert_contains "$TMP_DIR/directory-interpreter.out" '"reason":"command-not-started"'

CRLF_INTERPRETER="$TMP_DIR/crlf-interpreter"
write_contract "$CRLF_INTERPRETER" "./crlf-interpreter-script || true"
printf '#!/bin/bash\r\nbody must not run\n' >"$CRLF_INTERPRETER/crlf-interpreter-script"
chmod +x "$CRLF_INTERPRETER/crlf-interpreter-script"
run_capture "$CRLF_INTERPRETER" "$TMP_DIR/crlf-interpreter.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "CRLF shebang interpreter was normalized into a valid path"
assert_contains "$TMP_DIR/crlf-interpreter.out" '"ran":0'
assert_contains "$TMP_DIR/crlf-interpreter.out" '"reason":"command-not-started"'

CRLF_ARGUMENT="$TMP_DIR/crlf-argument"
write_contract "$CRLF_ARGUMENT" "./crlf-argument-script || true"
printf '#!/bin/bash -e\r\nprintf body-may-not-run\n' >"$CRLF_ARGUMENT/crlf-argument-script"
chmod +x "$CRLF_ARGUMENT/crlf-argument-script"
run_capture "$CRLF_ARGUMENT" "$TMP_DIR/crlf-argument.out" --json
[ "$RUN_STATUS" -eq 0 ] || fail "CR in a shebang argument was treated as part of the interpreter path"
assert_contains "$TMP_DIR/crlf-argument.out" '"ran":1'
assert_contains "$TMP_DIR/crlf-argument.out" '"verdict":"passed"'

ENV_OPTIONS="$TMP_DIR/env-options"
write_contract "$ENV_OPTIONS" "./env-options-script"
printf '#!/usr/bin/env -S -u FOO bash\nprintf env-ran > marker\n' >"$ENV_OPTIONS/env-options-script"
chmod +x "$ENV_OPTIONS/env-options-script"
FOO=present run_capture "$ENV_OPTIONS" "$TMP_DIR/env-options.out" --json
[ "$RUN_STATUS" -eq 0 ] || fail "env option arguments were mistaken for the interpreter"
[ "$(cat "$ENV_OPTIONS/marker")" = env-ran ] || fail "env shebang script did not run"

CUSTOM_ENV="$TMP_DIR/custom-env"
write_contract "$CUSTOM_ENV" "./custom-env-script"
cat >"$CUSTOM_ENV/env" <<'EOF'
#!/bin/bash
exec /bin/bash "$@"
EOF
printf '#!%s/env\nprintf custom-env-ran > marker\n' "$CUSTOM_ENV" >"$CUSTOM_ENV/custom-env-script"
chmod +x "$CUSTOM_ENV/env" "$CUSTOM_ENV/custom-env-script"
run_capture "$CUSTOM_ENV" "$TMP_DIR/custom-env.out" --json
[ "$RUN_STATUS" -eq 0 ] || fail "custom interpreter named env was parsed as the env utility"
[ "$(cat "$CUSTOM_ENV/marker")" = custom-env-ran ] || fail "custom env-named interpreter did not run"

for env_header in '-S -i bash' '-S -u PATH bash' '-S PATH=/bin bash'; do
  case "$env_header" in
    *'-i'*) env_case=clean ;;
    *'-u'*) env_case="unset" ;;
    *) env_case=assignment ;;
  esac
  ENV_CHANGED="$TMP_DIR/env-$env_case"
  write_contract "$ENV_CHANGED" "PATH= ./env-changed-script"
  printf '#!/usr/bin/env %s\nprintf env-changed > marker\n' "$env_header" >"$ENV_CHANGED/env-changed-script"
  chmod +x "$ENV_CHANGED/env-changed-script"
  run_capture "$ENV_CHANGED" "$TMP_DIR/env-$env_case.out" --json
  [ "$RUN_STATUS" -eq 0 ] || fail "env $env_case PATH semantics rejected a runnable interpreter"
  [ "$(cat "$ENV_CHANGED/marker")" = env-changed ] || fail "env $env_case script did not run"
done

for env_header in '-S -v missing-touchstone-command' '-S - missing-touchstone-command'; do
  case "$env_header" in
    *'-v'*) env_case=debug ;;
    *) env_case=bare-clean ;;
  esac
  ENV_MISSING="$TMP_DIR/env-missing-$env_case"
  write_contract "$ENV_MISSING" "./env-missing-script"
  printf '#!/usr/bin/env %s\nbody must not run\n' "$env_header" >"$ENV_MISSING/env-missing-script"
  chmod +x "$ENV_MISSING/env-missing-script"
  run_capture "$ENV_MISSING" "$TMP_DIR/env-missing-$env_case.out" --json
  [ "$RUN_STATUS" -eq 127 ] || fail "env $env_case missing interpreter did not retain 127"
  assert_contains "$TMP_DIR/env-missing-$env_case.out" '"ran":0'
  assert_contains "$TMP_DIR/env-missing-$env_case.out" '"reason":"command-not-started"'
done

ENV_CLUSTERED="$TMP_DIR/env-clustered"
write_contract "$ENV_CLUSTERED" "./env-clustered-script || true"
printf '#!/usr/bin/env -S -iv missing-touchstone-command\nbody must not run\n' >"$ENV_CLUSTERED/env-clustered-script"
chmod +x "$ENV_CLUSTERED/env-clustered-script"
run_capture "$ENV_CLUSTERED" "$TMP_DIR/env-clustered.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "clustered env flags laundered a missing interpreter"
assert_contains "$TMP_DIR/env-clustered.out" '"ran":0'
assert_contains "$TMP_DIR/env-clustered.out" '"reason":"command-not-started"'

ENV_CLUSTERED_ARGUMENT="$TMP_DIR/env-clustered-argument"
write_contract "$ENV_CLUSTERED_ARGUMENT" "./env-clustered-argument-script || true"
printf '#!/usr/bin/env -S -iu PATH missing-touchstone-command\nbody must not run\n' >"$ENV_CLUSTERED_ARGUMENT/env-clustered-argument-script"
chmod +x "$ENV_CLUSTERED_ARGUMENT/env-clustered-argument-script"
run_capture "$ENV_CLUSTERED_ARGUMENT" "$TMP_DIR/env-clustered-argument.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "clustered env argument option laundered a missing interpreter"
assert_contains "$TMP_DIR/env-clustered-argument.out" '"ran":0'
assert_contains "$TMP_DIR/env-clustered-argument.out" '"reason":"command-not-started"'

ENV_SPLIT_ATTACHED="$TMP_DIR/env-split-attached"
write_contract "$ENV_SPLIT_ATTACHED" "./env-split-attached-script || true"
printf '#!/usr/bin/env -Siv bash\nbody must not run\n' >"$ENV_SPLIT_ATTACHED/env-split-attached-script"
chmod +x "$ENV_SPLIT_ATTACHED/env-split-attached-script"
run_capture "$ENV_SPLIT_ATTACHED" "$TMP_DIR/env-split-attached.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "attached env split-string argument was parsed as flags"
assert_contains "$TMP_DIR/env-split-attached.out" '"ran":0'
assert_contains "$TMP_DIR/env-split-attached.out" '"reason":"command-not-started"'

ENV_SPLIT_QUOTED="$TMP_DIR/env-split-quoted"
write_contract "$ENV_SPLIT_QUOTED" "./env-split-quoted-script"
printf '#!/usr/bin/env -S"bash"\nprintf split-quoted-ran > marker\n' >"$ENV_SPLIT_QUOTED/env-split-quoted-script"
chmod +x "$ENV_SPLIT_QUOTED/env-split-quoted-script"
run_capture "$ENV_SPLIT_QUOTED" "$TMP_DIR/env-split-quoted.out" --json
[ "$RUN_STATUS" -eq 0 ] || fail "quoted attached env split-string command was not decoded"
[ "$(cat "$ENV_SPLIT_QUOTED/marker")" = split-quoted-ran ] || fail "quoted attached env split-string command did not run"

ENV_SPLIT_DETACHED="$TMP_DIR/env-split-detached"
write_contract "$ENV_SPLIT_DETACHED" "./env-split-detached-script"
printf '#!/usr/bin/env -S "bash"\nprintf split-detached-ran > marker\n' >"$ENV_SPLIT_DETACHED/env-split-detached-script"
chmod +x "$ENV_SPLIT_DETACHED/env-split-detached-script"
run_capture "$ENV_SPLIT_DETACHED" "$TMP_DIR/env-split-detached.out" --json
[ "$RUN_STATUS" -eq 0 ] || fail "quoted detached env split-string command was not decoded"
[ "$(cat "$ENV_SPLIT_DETACHED/marker")" = split-detached-ran ] || fail "quoted detached env split-string command did not run"

ENV_LITERAL_QUOTES="$TMP_DIR/env-literal-quotes"
write_contract "$ENV_LITERAL_QUOTES" "./env-literal-quotes-script || true"
printf '#!/usr/bin/env "bash"\nprintf body-must-not-run > marker\n' >"$ENV_LITERAL_QUOTES/env-literal-quotes-script"
chmod +x "$ENV_LITERAL_QUOTES/env-literal-quotes-script"
run_capture "$ENV_LITERAL_QUOTES" "$TMP_DIR/env-literal-quotes.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "ordinary env arguments were decoded without -S"
assert_contains "$TMP_DIR/env-literal-quotes.out" '"ran":0'
assert_contains "$TMP_DIR/env-literal-quotes.out" '"reason":"command-not-started"'
[ ! -e "$ENV_LITERAL_QUOTES/marker" ] || fail "literal-quote env body unexpectedly ran"

ENV_UNSPLIT_ARGUMENT="$TMP_DIR/env-unsplit-argument"
write_contract "$ENV_UNSPLIT_ARGUMENT" "./env-unsplit-argument-script || true"
printf '#!/usr/bin/env bash -e\nprintf body-must-not-run > marker\n' >"$ENV_UNSPLIT_ARGUMENT/env-unsplit-argument-script"
chmod +x "$ENV_UNSPLIT_ARGUMENT/env-unsplit-argument-script"
run_capture "$ENV_UNSPLIT_ARGUMENT" "$TMP_DIR/env-unsplit-argument.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "ordinary env optional argument was split without -S"
assert_contains "$TMP_DIR/env-unsplit-argument.out" '"ran":0'
assert_contains "$TMP_DIR/env-unsplit-argument.out" '"reason":"command-not-started"'
[ ! -e "$ENV_UNSPLIT_ARGUMENT/marker" ] || fail "unsplit env argument body unexpectedly ran"

ENV_DASH_COMMAND="$TMP_DIR/env-dash-command"
mkdir -p "$ENV_DASH_COMMAND/bin"
write_contract "$ENV_DASH_COMMAND" "PATH=$ENV_DASH_COMMAND/bin ./env-dash-script"
printf '#!/bin/bash\nprintf dash-ran > marker\n' >"$ENV_DASH_COMMAND/bin/-i"
printf '#!/usr/bin/env -S -- -i\nbody must not run\n' >"$ENV_DASH_COMMAND/env-dash-script"
chmod +x "$ENV_DASH_COMMAND/bin/-i" "$ENV_DASH_COMMAND/env-dash-script"
run_capture "$ENV_DASH_COMMAND" "$TMP_DIR/env-dash-command.out" --json
[ "$RUN_STATUS" -eq 0 ] || fail "env option terminator rejected a dash-prefixed command"
[ "$(cat "$ENV_DASH_COMMAND/marker")" = dash-ran ] || fail "dash-prefixed env command did not run"

ENV_BUILTIN="$TMP_DIR/env-builtin"
mkdir -p "$ENV_BUILTIN/empty"
write_contract "$ENV_BUILTIN" "PATH=$ENV_BUILTIN/empty ./env-builtin-script"
printf '#!/usr/bin/env echo\nbody must not run\n' >"$ENV_BUILTIN/env-builtin-script"
chmod +x "$ENV_BUILTIN/env-builtin-script"
run_capture "$ENV_BUILTIN" "$TMP_DIR/env-builtin.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "builtin-only env interpreter did not retain 127"
assert_contains "$TMP_DIR/env-builtin.out" '"ran":0'
assert_contains "$TMP_DIR/env-builtin.out" '"reason":"command-not-started"'

ASSIGNMENT_COMMAND="$TMP_DIR/assignment-command"
write_contract "$ASSIGNMENT_COMMAND" "FIRST=one SECOND=two missing-touchstone-command"
run_capture "$ASSIGNMENT_COMMAND" "$TMP_DIR/assignment-command.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "assignment-prefixed unavailable command did not retain 127"
assert_contains "$TMP_DIR/assignment-command.out" '"ran":0'
assert_contains "$TMP_DIR/assignment-command.out" '"reason":"command-not-started"'

FALLBACK_COMMAND="$TMP_DIR/fallback-command"
write_contract "$FALLBACK_COMMAND" "missing-touchstone-command || true"
run_capture "$FALLBACK_COMMAND" "$TMP_DIR/fallback-command.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "fallback laundered an unavailable command"
assert_contains "$TMP_DIR/fallback-command.out" '"ran":0'
assert_contains "$TMP_DIR/fallback-command.out" '"reason":"command-not-started"'

COMMAND_BUILTIN="$TMP_DIR/command-builtin"
write_contract "$COMMAND_BUILTIN" "command missing-touchstone-command || true"
run_capture "$COMMAND_BUILTIN" "$TMP_DIR/command-builtin.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "command builtin laundered an unavailable command"
assert_contains "$TMP_DIR/command-builtin.out" '"ran":0'
assert_contains "$TMP_DIR/command-builtin.out" '"reason":"command-not-started"'

for command_form in 'command -p missing-touchstone-command || true' \
  'command -- missing-touchstone-command || true' \
  'FIRST=one command missing-touchstone-command || true'; do
  write_contract "$COMMAND_BUILTIN" "$command_form"
  run_capture "$COMMAND_BUILTIN" "$TMP_DIR/command-builtin.out" --json
  [ "$RUN_STATUS" -eq 127 ] || fail "command builtin option/assignment form laundered an unavailable command"
  assert_contains "$TMP_DIR/command-builtin.out" '"ran":0'
done

write_contract "$COMMAND_BUILTIN" "command -v missing-touchstone-command || true"
run_capture "$COMMAND_BUILTIN" "$TMP_DIR/command-query.out" --json
[ "$RUN_STATUS" -eq 0 ] || fail "command query form was mistaken for an executable launch"
assert_contains "$TMP_DIR/command-query.out" '"ran":1'

COMMAND_DEFAULT_PATH="$TMP_DIR/command-default-path"
write_contract "$COMMAND_DEFAULT_PATH" "PATH= command -p sh -c 'printf default-path-ran > marker'"
run_capture "$COMMAND_DEFAULT_PATH" "$TMP_DIR/command-default-path.out" --json
[ "$RUN_STATUS" -eq 0 ] || fail "command -p did not use the default utility path"
[ "$(cat "$COMMAND_DEFAULT_PATH/marker")" = default-path-ran ] || fail "command -p task did not run"

write_contract "$COMMAND_DEFAULT_PATH" "PATH= command -p command sh -c 'printf nested-default-path-ran > marker'"
run_capture "$COMMAND_DEFAULT_PATH" "$TMP_DIR/command-nested-default-path.out" --json
[ "$RUN_STATUS" -eq 0 ] || fail "command -p default path did not reach a nested command builtin"
[ "$(cat "$COMMAND_DEFAULT_PATH/marker")" = nested-default-path-ran ] || fail "nested command -p task did not run"

COMMAND_CHILD_PATH="$TMP_DIR/command-child-path"
write_contract "$COMMAND_CHILD_PATH" "PATH= command -p ./command-child-path-script || true"
printf '#!/usr/bin/env sh\nprintf child-path-ran > marker\n' >"$COMMAND_CHILD_PATH/command-child-path-script"
chmod +x "$COMMAND_CHILD_PATH/command-child-path-script"
run_capture "$COMMAND_CHILD_PATH" "$TMP_DIR/command-child-path.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "command -p replaced the child environment PATH"
assert_contains "$TMP_DIR/command-child-path.out" '"ran":0'
assert_contains "$TMP_DIR/command-child-path.out" '"reason":"command-not-started"'
[ ! -e "$COMMAND_CHILD_PATH/marker" ] || fail "command -p env-shebang body unexpectedly ran"

NEGATED_COMMAND="$TMP_DIR/negated-command"
write_contract "$NEGATED_COMMAND" "! missing-touchstone-command"
run_capture "$NEGATED_COMMAND" "$TMP_DIR/negated-command.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "negation laundered an unavailable command"
assert_contains "$TMP_DIR/negated-command.out" '"ran":0'
assert_contains "$TMP_DIR/negated-command.out" '"reason":"command-not-started"'

TIMED_COMMAND="$TMP_DIR/timed-command"
write_contract "$TIMED_COMMAND" "time -p missing-touchstone-command || true"
run_capture "$TIMED_COMMAND" "$TMP_DIR/timed-command.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "time prefix laundered an unavailable command"
assert_contains "$TMP_DIR/timed-command.out" '"ran":0'
assert_contains "$TMP_DIR/timed-command.out" '"reason":"command-not-started"'

ASSIGNMENT_TIMED="$TMP_DIR/assignment-timed"
write_contract "$ASSIGNMENT_TIMED" "PATH= time true || true"
run_capture "$ASSIGNMENT_TIMED" "$TMP_DIR/assignment-timed.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "assignment-prefixed external time was mistaken for a keyword"
assert_contains "$TMP_DIR/assignment-timed.out" '"ran":0'
assert_contains "$TMP_DIR/assignment-timed.out" '"reason":"command-not-started"'

QUOTED_ASSIGNMENT="$TMP_DIR/quoted-assignment"
write_contract "$QUOTED_ASSIGNMENT" "LABEL=\\\"two words\\\" missing-touchstone-command"
run_capture "$QUOTED_ASSIGNMENT" "$TMP_DIR/quoted-assignment.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "quoted-assignment unavailable command did not retain 127"
assert_contains "$TMP_DIR/quoted-assignment.out" '"ran":0'
assert_contains "$TMP_DIR/quoted-assignment.out" '"reason":"command-not-started"'

PATH_ASSIGNMENT="$TMP_DIR/path-assignment"
mkdir -p "$PATH_ASSIGNMENT/bin"
printf '#!/bin/bash\nprintf path-ran > marker\n' >"$PATH_ASSIGNMENT/bin/declared-tool"
chmod +x "$PATH_ASSIGNMENT/bin/declared-tool"
write_contract "$PATH_ASSIGNMENT" "PATH=bin declared-tool"
run_capture "$PATH_ASSIGNMENT" "$TMP_DIR/path-assignment.out" --json
[ "$RUN_STATUS" -eq 0 ] || fail "literal PATH assignment was ignored during preflight"
[ "$(cat "$PATH_ASSIGNMENT/marker")" = path-ran ] || fail "PATH-resolved tool did not run"

PATH_APPEND="$TMP_DIR/path-append"
write_contract "$PATH_APPEND" "PATH= PATH+=/bin sh -c 'printf path-append-ran > marker'"
run_capture "$PATH_APPEND" "$TMP_DIR/path-append.out" --json
[ "$RUN_STATUS" -eq 0 ] || fail "PATH append assignment was not modeled during preflight"
[ "$(cat "$PATH_APPEND/marker")" = path-append-ran ] || fail "PATH append assignment task did not run"

QUOTED_EQUALS_HEAD="$TMP_DIR/quoted-equals-head"
write_contract "$QUOTED_EQUALS_HEAD" "\\\"FAKE=assignment\\\" ignored-argument"
printf '#!/usr/bin/env bash\nexit 127\n' >"$QUOTED_EQUALS_HEAD/FAKE=assignment"
chmod +x "$QUOTED_EQUALS_HEAD/FAKE=assignment"
PATH="$QUOTED_EQUALS_HEAD:$PATH" run_capture \
  "$QUOTED_EQUALS_HEAD" "$TMP_DIR/quoted-equals-head.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "quoted equals command did not retain its exit"
assert_contains "$TMP_DIR/quoted-equals-head.out" '"ran":1'
assert_contains "$TMP_DIR/quoted-equals-head.out" '"reason":"command-failed"'

QUOTED_MISSING_HEAD="$TMP_DIR/quoted-missing-head"
write_contract "$QUOTED_MISSING_HEAD" "\\\"missing tool\\\""
run_capture "$QUOTED_MISSING_HEAD" "$TMP_DIR/quoted-missing-head.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "quoted missing command did not retain 127"
assert_contains "$TMP_DIR/quoted-missing-head.out" '"ran":0'
assert_contains "$TMP_DIR/quoted-missing-head.out" '"reason":"command-not-started"'

QUOTED_KEYWORD="$TMP_DIR/quoted-keyword"
write_contract "$QUOTED_KEYWORD" "\\\"if\\\""
run_capture "$QUOTED_KEYWORD" "$TMP_DIR/quoted-keyword.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "quoted keyword command did not retain 127"
assert_contains "$TMP_DIR/quoted-keyword.out" '"ran":0'
assert_contains "$TMP_DIR/quoted-keyword.out" '"reason":"command-not-started"'

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
    unsupported) sed 's/schema = 1/schema = 2/' "$dir/.touchstone.toml" >"$dir/new" ;;
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

init_adoption_repo() {
  local directory="$1"
  mkdir -p "$directory"
  git -C "$directory" init -q -b main
  git -C "$directory" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$directory" config user.name "Touchstone Test"
  git -C "$directory" config user.email "touchstone@example.invalid"
}

commit_adoption_repo() {
  local directory="$1" message="$2"
  git -C "$directory" add -A
  git -C "$directory" commit -q -m "$message"
}

run_adoption() {
  local output="$1"
  shift
  set +e
  "$CLI" "$@" >"$output" 2>"$output.err"
  ADOPTION_STATUS=$?
  set -e
}

ADOPT_NON_REPO="$TMP_DIR/adopt-non-repo"
mkdir -p "$ADOPT_NON_REPO"
run_adoption "$TMP_DIR/adopt-non-repo.out" adopt --dry-run --json --project "$ADOPT_NON_REPO"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "non-repository adoption did not refuse"
assert_contains "$TMP_DIR/adopt-non-repo.out" '"status":"contract-refused"'
assert_contains "$TMP_DIR/adopt-non-repo.out" "adoption requires a git repository"

echo "==> adoption compiles a deterministic Node contract and marked steering"
ADOPT_NODE="$TMP_DIR/adopt-node"
init_adoption_repo "$ADOPT_NODE"
cat >"$ADOPT_NODE/package.json" <<'EOF'
{
  "name": "fixture",
  "scripts": {
    "lint": "eslint .",
    "test": "vitest run"
  }
}
EOF
printf '{}\n' >"$ADOPT_NODE/package-lock.json"
printf '# Project-owned instructions\n\nKEEP a/old/ b/new/ PROSE\f\n' >"$ADOPT_NODE/AGENTS.md"
chmod +x "$ADOPT_NODE/AGENTS.md"
commit_adoption_repo "$ADOPT_NODE" "fixture"
git -C "$ADOPT_NODE" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-node-plan.json" adopt --dry-run --json --project "$ADOPT_NODE"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "Node adoption dry-run failed"
assert_contains "$TMP_DIR/adopt-node-plan.json" '"schema":1'
assert_contains "$TMP_DIR/adopt-node-plan.json" '"status":"changes-required"'
assert_contains "$TMP_DIR/adopt-node-plan.json" '"profile":"node"'
assert_contains "$TMP_DIR/adopt-node-plan.json" '"path":".touchstone.toml","action":"create"'
assert_contains "$TMP_DIR/adopt-node-plan.json" '"status":"separate-operation","required":true,"mutated":false'
assert_contains "$TMP_DIR/adopt-node-plan.json" 'new file mode 100644'
assert_contains "$TMP_DIR/adopt-node-plan.json" '\f'
assert_not_contains "$TMP_DIR/adopt-node-plan.json" 'old mode 100755'
assert_not_contains "$TMP_DIR/adopt-node-plan.json" 'new mode 100644'
[ ! -e "$ADOPT_NODE/.touchstone.toml" ] || fail "dry-run mutated the repository"
run_adoption "$TMP_DIR/adopt-node-plan-repeat.json" adopt --dry-run --json --project "$ADOPT_NODE"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "repeated Node adoption dry-run failed"
cmp -s "$TMP_DIR/adopt-node-plan.json" "$TMP_DIR/adopt-node-plan-repeat.json" \
  || fail "identical repository facts produced different plans"
run_adoption "$TMP_DIR/adopt-node-apply.out" adopt --project "$ADOPT_NODE"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "Node adoption apply failed"
assert_contains "$ADOPT_NODE/.touchstone.toml" 'command = "npm run lint"'
assert_contains "$ADOPT_NODE/.touchstone.toml" 'command = "npm run test"'
assert_contains "$ADOPT_NODE/.touchstone.toml" 'setup = "npm ci --offline"'
assert_contains "$ADOPT_NODE/AGENTS.md" "KEEP a/old/ b/new/ PROSE"
[ -x "$ADOPT_NODE/AGENTS.md" ] || fail "adoption changed a project-owned steering file mode"
assert_contains "$ADOPT_NODE/AGENTS.md" '<!-- touchstone:steering:start -->'
assert_contains "$ADOPT_NODE/CLAUDE.md" '@.touchstone/TOUCHSTONE.md'
assert_contains "$ADOPT_NODE/.touchstone/TOUCHSTONE.md" '.touchstone/principles/git-workflow.md'
assert_not_contains "$ADOPT_NODE/.touchstone/TOUCHSTONE.md" 'scripts/claim-issue.sh'
assert_not_contains "$ADOPT_NODE/.touchstone/TOUCHSTONE.md" 'scripts/respond-review.sh'
assert_not_contains "$ADOPT_NODE/.touchstone/principles/git-workflow.md" 'bash scripts/'
assert_not_contains "$ADOPT_NODE/.touchstone/principles/git-workflow.md" 'hooks/branch-guard.sh'
assert_not_contains "$ADOPT_NODE/.touchstone/principles/git-workflow.md" '.github/workflows/issue-claim-check.yml'
assert_not_contains "$ADOPT_NODE/.touchstone/principles/git-workflow.md" '--all-resolved-check'
assert_not_contains "$ADOPT_NODE/.touchstone/principles/agent-swarms.md" 'scripts/respond-review.sh'
[ ! -e "$ADOPT_NODE/.touchstone/principles/README.md" ] \
  || fail "adoption copied the repository-only principles index"
bash "$RUNNER" validate --check-contract --project "$ADOPT_NODE" >/dev/null
commit_adoption_repo "$ADOPT_NODE" "adopt"
run_adoption "$TMP_DIR/adopt-node-repeat.out" adopt --check --project "$ADOPT_NODE"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "second adoption was not idempotent"
assert_contains "$TMP_DIR/adopt-node-repeat.out" "adopt: current"
run_adoption "$TMP_DIR/adopt-node-upgrade.out" upgrade --check --json --project "$ADOPT_NODE"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "current schema-v1 upgrade was not a no-op"
assert_contains "$TMP_DIR/adopt-node-upgrade.out" '"status":"current"'
printf '\nold compatible steering\n' >>"$ADOPT_NODE/.touchstone/TOUCHSTONE.md"
commit_adoption_repo "$ADOPT_NODE" "older steering"
run_adoption "$TMP_DIR/adopt-node-preserved.out" adopt --check --project "$ADOPT_NODE"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "adopt required an implicit compatible steering upgrade"
run_adoption "$TMP_DIR/adopt-node-upgrade-needed.out" upgrade --check --json --project "$ADOPT_NODE"
[ "$ADOPTION_STATUS" -eq 3 ] || fail "explicit upgrade did not detect stale managed steering"
assert_contains "$TMP_DIR/adopt-node-upgrade-needed.out" '"status":"changes-required"'
run_adoption "$TMP_DIR/adopt-node-upgrade-apply.out" upgrade --project "$ADOPT_NODE"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "explicit steering upgrade failed"
assert_not_contains "$ADOPT_NODE/.touchstone/TOUCHSTONE.md" "old compatible steering"
commit_adoption_repo "$ADOPT_NODE" "upgrade"
awk '{ printf "%s\r\n", $0 }' "$ADOPT_NODE/AGENTS.md" >"$ADOPT_NODE/AGENTS.crlf"
mv "$ADOPT_NODE/AGENTS.crlf" "$ADOPT_NODE/AGENTS.md"
sed 's/Humans approve plans/Humans approve stale plans/' "$ADOPT_NODE/AGENTS.md" \
  >"$ADOPT_NODE/AGENTS.stale"
mv "$ADOPT_NODE/AGENTS.stale" "$ADOPT_NODE/AGENTS.md"
commit_adoption_repo "$ADOPT_NODE" "crlf steering"
run_adoption "$TMP_DIR/adopt-node-crlf-upgrade.out" upgrade --project "$ADOPT_NODE"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "CRLF steering upgrade failed"
[ "$(grep -cF '<!-- touchstone:steering:start -->' "$ADOPT_NODE/AGENTS.md")" -eq 1 ] \
  || fail "CRLF upgrade duplicated the managed block"
awk '/Project-owned instructions/ { found=1; exit substr($0, length($0), 1) != "\r" } END { if (!found) exit 1 }' \
  "$ADOPT_NODE/AGENTS.md" \
  || fail "CRLF upgrade changed project-owned line endings"
assert_contains "$ADOPT_NODE/AGENTS.md" "KEEP a/old/ b/new/ PROSE"
commit_adoption_repo "$ADOPT_NODE" "crlf upgrade"
awk '{ sub(/\r$/, ""); printf "%s\r\n", $0 }' "$ADOPT_NODE/AGENTS.md" \
  >"$ADOPT_NODE/AGENTS.all-crlf"
mv "$ADOPT_NODE/AGENTS.all-crlf" "$ADOPT_NODE/AGENTS.md"
commit_adoption_repo "$ADOPT_NODE" "crlf markers"
run_adoption "$TMP_DIR/adopt-node-crlf-check.out" adopt --check --json --project "$ADOPT_NODE"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "ordinary adopt rewrote CRLF managed markers"
assert_contains "$TMP_DIR/adopt-node-crlf-check.out" '"status":"current"'
printf 'PROJECT-SUFFIX' >>"$ADOPT_NODE/AGENTS.md"
commit_adoption_repo "$ADOPT_NODE" "unterminated project suffix"
run_adoption "$TMP_DIR/adopt-node-suffix-upgrade.out" upgrade --project "$ADOPT_NODE"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "unterminated suffix upgrade failed"
[ "$(tail -c 1 "$ADOPT_NODE/AGENTS.md")" = X ] \
  || fail "upgrade added a newline to project-owned suffix"

ADOPT_FRESH_EOF="$TMP_DIR/adopt-fresh-eof"
init_adoption_repo "$ADOPT_FRESH_EOF"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_FRESH_EOF/package.json"
printf '{}\n' >"$ADOPT_FRESH_EOF/package-lock.json"
printf 'PROJECT-EOF' >"$ADOPT_FRESH_EOF/AGENTS.md"
commit_adoption_repo "$ADOPT_FRESH_EOF" "fixture"
git -C "$ADOPT_FRESH_EOF" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-fresh-eof.out" adopt --project "$ADOPT_FRESH_EOF"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "marker-free unterminated steering adoption failed"
[ "$(tail -c 11 "$ADOPT_FRESH_EOF/AGENTS.md")" = PROJECT-EOF ] \
  || fail "initial adoption changed bytes in unterminated project-owned steering"
[ "$(tail -c 1 "$ADOPT_FRESH_EOF/AGENTS.md")" = F ] \
  || fail "initial adoption terminated an unterminated project-owned line"

echo "==> adoption preserves accepted schema-v1 declarations"
ADOPT_EXISTING="$TMP_DIR/adopt-existing"
init_adoption_repo "$ADOPT_EXISTING"
write_contract "$ADOPT_EXISTING" "printf should-not-run > adoption-marker"
cp "$ADOPT_EXISTING/.touchstone.toml" "$TMP_DIR/accepted-contract.toml"
commit_adoption_repo "$ADOPT_EXISTING" "fixture"
git -C "$ADOPT_EXISTING" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-existing.out" adopt --project "$ADOPT_EXISTING"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "existing schema-v1 adoption failed"
[ ! -e "$ADOPT_EXISTING/adoption-marker" ] || fail "adoption executed the validation contract while planning"
cmp -s "$ADOPT_EXISTING/.touchstone.toml" "$TMP_DIR/accepted-contract.toml" \
  || fail "adoption rewrote an accepted schema-v1 contract"

echo "==> adoption ports explicit legacy commands without deleting legacy state"
ADOPT_LEGACY="$TMP_DIR/adopt-legacy"
init_adoption_repo "$ADOPT_LEGACY"
cat >"$ADOPT_LEGACY/.touchstone-config" <<'EOF'
project_type=generic
validate_command=bash scripts/validate-project.sh --exact
EOF
mkdir -p "$ADOPT_LEGACY/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' >"$ADOPT_LEGACY/scripts/validate-project.sh"
chmod +x "$ADOPT_LEGACY/scripts/validate-project.sh"
commit_adoption_repo "$ADOPT_LEGACY" "fixture"
git -C "$ADOPT_LEGACY" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-legacy.out" adopt --project "$ADOPT_LEGACY"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "legacy adoption failed"
assert_contains "$ADOPT_LEGACY/.touchstone.toml" 'command = "bash scripts/validate-project.sh --exact"'
[ -f "$ADOPT_LEGACY/.touchstone-config" ] || fail "adoption deleted legacy config without authorization"

echo "==> adoption supports explicit manual declarations"
ADOPT_MANUAL="$TMP_DIR/adopt-manual"
init_adoption_repo "$ADOPT_MANUAL"
printf 'manual fixture\n' >"$ADOPT_MANUAL/README.md"
commit_adoption_repo "$ADOPT_MANUAL" "fixture"
git -C "$ADOPT_MANUAL" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-manual.out" adopt --project "$ADOPT_MANUAL" \
  --task 'verify=bash scripts/check.sh --all'
[ "$ADOPTION_STATUS" -eq 0 ] || fail "manual adoption failed"
assert_contains "$ADOPT_MANUAL/.touchstone.toml" 'name = "verify"'
assert_contains "$ADOPT_MANUAL/.touchstone.toml" 'command = "bash scripts/check.sh --all"'

echo "==> adoption presets cover the supported portfolio runtimes"
for profile in python swift rust go; do
  ADOPT_PROFILE="$TMP_DIR/adopt-$profile"
  init_adoption_repo "$ADOPT_PROFILE"
  case "$profile" in
    python)
      printf '%s\n' '[project]' 'name = "fixture"' 'dependencies = ["pytest"]' \
        '[tool.pytest.ini_options]' >"$ADOPT_PROFILE/pyproject.toml"
      printf 'version = 1\n' >"$ADOPT_PROFILE/uv.lock"
      expected_command='command = "uv run --no-sync pytest"'
      expected_setup='setup = "uv sync --offline --frozen"'
      ;;
    swift)
      printf '%s\n' '// swift-tools-version:6.2' >"$ADOPT_PROFILE/Package.swift"
      expected_command='command = "swift test --disable-automatic-resolution --skip-update"'
      expected_setup=''
      ;;
    rust)
      printf '%s\n' '[package]' 'name = "fixture"' >"$ADOPT_PROFILE/Cargo.toml"
      printf '%s\n' 'version = 4' >"$ADOPT_PROFILE/Cargo.lock"
      expected_command='command = "cargo test --frozen"'
      expected_setup=''
      ;;
    go)
      printf '%s\n' 'module example.invalid/fixture' >"$ADOPT_PROFILE/go.mod"
      expected_command='command = "GOPROXY=off GOSUMDB=off go test ./..."'
      expected_setup=''
      ;;
  esac
  commit_adoption_repo "$ADOPT_PROFILE" "fixture"
  git -C "$ADOPT_PROFILE" switch -q -c feat/adopt
  run_adoption "$TMP_DIR/adopt-$profile.out" adopt --project "$ADOPT_PROFILE"
  [ "$ADOPTION_STATUS" -eq 0 ] || fail "$profile adoption failed"
  assert_contains "$ADOPT_PROFILE/.touchstone.toml" "$expected_command"
  if [ -n "$expected_setup" ]; then assert_contains "$ADOPT_PROFILE/.touchstone.toml" "$expected_setup"; fi
done

ADOPT_RUST_NO_LOCK="$TMP_DIR/adopt-rust-no-lock"
init_adoption_repo "$ADOPT_RUST_NO_LOCK"
printf '%s\n' '[package]' 'name = "fixture"' >"$ADOPT_RUST_NO_LOCK/Cargo.toml"
commit_adoption_repo "$ADOPT_RUST_NO_LOCK" "fixture"
git -C "$ADOPT_RUST_NO_LOCK" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-rust-no-lock.out" adopt --dry-run --project "$ADOPT_RUST_NO_LOCK"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "Rust adoption without a lockfile was accepted"
assert_contains "$TMP_DIR/adopt-rust-no-lock.out.err" "has no Cargo.lock"
[ ! -e "$ADOPT_RUST_NO_LOCK/.touchstone.toml" ] || fail "Rust lockfile refusal mutated the repository"

ADOPT_RUST_IGNORED_LOCK="$TMP_DIR/adopt-rust-ignored-lock"
init_adoption_repo "$ADOPT_RUST_IGNORED_LOCK"
printf '%s\n' '[package]' 'name = "fixture"' >"$ADOPT_RUST_IGNORED_LOCK/Cargo.toml"
printf '%s\n' 'Cargo.lock' >"$ADOPT_RUST_IGNORED_LOCK/.gitignore"
commit_adoption_repo "$ADOPT_RUST_IGNORED_LOCK" "fixture"
printf '%s\n' 'version = 4' >"$ADOPT_RUST_IGNORED_LOCK/Cargo.lock"
git -C "$ADOPT_RUST_IGNORED_LOCK" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-rust-ignored-lock.out" adopt --dry-run --project "$ADOPT_RUST_IGNORED_LOCK"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "Rust adoption accepted a locally present ignored lockfile"
assert_contains "$TMP_DIR/adopt-rust-ignored-lock.out.err" "compiler input 'Cargo.lock' is not tracked"
[ -z "$(git -C "$ADOPT_RUST_IGNORED_LOCK" status --porcelain=v1)" ] \
  || fail "ignored-lock refusal changed the clean checkout"

ADOPT_NODE_IGNORED_LOCK="$TMP_DIR/adopt-node-ignored-lock"
init_adoption_repo "$ADOPT_NODE_IGNORED_LOCK"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_NODE_IGNORED_LOCK/package.json"
printf '%s\n' 'package-lock.json' >"$ADOPT_NODE_IGNORED_LOCK/.gitignore"
commit_adoption_repo "$ADOPT_NODE_IGNORED_LOCK" "fixture"
printf '%s\n' '{}' >"$ADOPT_NODE_IGNORED_LOCK/package-lock.json"
git -C "$ADOPT_NODE_IGNORED_LOCK" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-node-ignored-lock.out" adopt --dry-run --project "$ADOPT_NODE_IGNORED_LOCK"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "Node adoption accepted a locally present ignored lockfile"
assert_contains "$TMP_DIR/adopt-node-ignored-lock.out.err" "compiler input 'package-lock.json' is not tracked"

ADOPT_IGNORED_CONTRACT="$TMP_DIR/adopt-ignored-contract"
init_adoption_repo "$ADOPT_IGNORED_CONTRACT"
printf '%s\n' '.touchstone.toml' >"$ADOPT_IGNORED_CONTRACT/.gitignore"
commit_adoption_repo "$ADOPT_IGNORED_CONTRACT" "fixture"
write_contract "$ADOPT_IGNORED_CONTRACT" 'true'
git -C "$ADOPT_IGNORED_CONTRACT" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-ignored-contract.out" adopt --dry-run --project "$ADOPT_IGNORED_CONTRACT"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "adoption preserved an ignored existing contract"
assert_contains "$TMP_DIR/adopt-ignored-contract.out.err" "compiler input '.touchstone.toml' is not tracked"

ADOPT_INPUT_SYMLINK="$TMP_DIR/adopt-input-symlink"
ADOPT_INPUT_OUTSIDE="$TMP_DIR/adopt-input-outside.json"
init_adoption_repo "$ADOPT_INPUT_SYMLINK"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_INPUT_OUTSIDE"
ln -s "$ADOPT_INPUT_OUTSIDE" "$ADOPT_INPUT_SYMLINK/package.json"
commit_adoption_repo "$ADOPT_INPUT_SYMLINK" "fixture"
git -C "$ADOPT_INPUT_SYMLINK" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-input-symlink.out" adopt --dry-run --project "$ADOPT_INPUT_SYMLINK"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "adoption read a compiler input through a symlink"
assert_contains "$TMP_DIR/adopt-input-symlink.out.err" "compiler input 'package.json' must be a regular file"

ADOPT_SWIFT_REMOTE_NO_LOCK="$TMP_DIR/adopt-swift-remote-no-lock"
init_adoption_repo "$ADOPT_SWIFT_REMOTE_NO_LOCK"
printf '%s\n' '// swift-tools-version:6.2' 'import PackageDescription' \
  'let package = Package(name: "Fixture", dependencies: [.package(url: "https://example.invalid/dependency", from: "1.0.0")])' \
  >"$ADOPT_SWIFT_REMOTE_NO_LOCK/Package.swift"
commit_adoption_repo "$ADOPT_SWIFT_REMOTE_NO_LOCK" "fixture"
git -C "$ADOPT_SWIFT_REMOTE_NO_LOCK" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-swift-remote-no-lock.out" adopt --dry-run --project "$ADOPT_SWIFT_REMOTE_NO_LOCK"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "Swift remote dependency without Package.resolved was accepted"
assert_contains "$TMP_DIR/adopt-swift-remote-no-lock.out.err" 'remote dependencies but no Package.resolved'

ADOPT_DIFF_RENDER_FAIL="$TMP_DIR/adopt-diff-render-fail"
init_adoption_repo "$ADOPT_DIFF_RENDER_FAIL"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_DIFF_RENDER_FAIL/package.json"
commit_adoption_repo "$ADOPT_DIFF_RENDER_FAIL" "fixture"
git -C "$ADOPT_DIFF_RENDER_FAIL" switch -q -c feat/adopt
mkdir -p "$TMP_DIR/failing-sed"
REAL_SED="$(command -v sed)"
export REAL_SED
cat >"$TMP_DIR/failing-sed/sed" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'diff --git'*) exit 9 ;;
  *) exec "$REAL_SED" "$@" ;;
esac
EOF
chmod +x "$TMP_DIR/failing-sed/sed"
PATH="$TMP_DIR/failing-sed:$PATH" run_adoption "$TMP_DIR/adopt-diff-render-fail.out" adopt --dry-run --project "$ADOPT_DIFF_RENDER_FAIL"
[ "$ADOPTION_STATUS" -eq 6 ] || fail "failed diff renderer did not stop adoption planning"
assert_contains "$TMP_DIR/adopt-diff-render-fail.out.err" 'could not render proposed diff'
[ ! -e "$ADOPT_DIFF_RENDER_FAIL/.touchstone.toml" ] || fail "failed diff rendering mutated the repository"

ADOPT_APPLY_ROLLBACK="$TMP_DIR/adopt-apply-rollback"
init_adoption_repo "$ADOPT_APPLY_ROLLBACK"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_APPLY_ROLLBACK/package.json"
commit_adoption_repo "$ADOPT_APPLY_ROLLBACK" "fixture"
git -C "$ADOPT_APPLY_ROLLBACK" switch -q -c feat/adopt
mkdir -p "$TMP_DIR/failing-mv"
REAL_MV="$(command -v mv)"
MV_COUNT_FILE="$TMP_DIR/failing-mv/count"
export REAL_MV MV_COUNT_FILE
cat >"$TMP_DIR/failing-mv/mv" <<'EOF'
#!/usr/bin/env bash
count=0
if [ -f "$MV_COUNT_FILE" ]; then count="$(cat "$MV_COUNT_FILE")"; fi
count=$((count + 1))
printf '%s\n' "$count" >"$MV_COUNT_FILE"
if [ "$count" -eq 2 ]; then exit 9; fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$TMP_DIR/failing-mv/mv"
PATH="$TMP_DIR/failing-mv:$PATH" run_adoption "$TMP_DIR/adopt-apply-rollback.out" adopt --project "$ADOPT_APPLY_ROLLBACK"
[ "$ADOPTION_STATUS" -eq 6 ] || fail "partial apply failure did not report an operational error"
assert_contains "$TMP_DIR/adopt-apply-rollback.out.err" 'all earlier writes were rolled back'
[ ! -e "$ADOPT_APPLY_ROLLBACK/.touchstone.toml" ] || fail "failed apply retained an earlier contract write"
[ ! -e "$ADOPT_APPLY_ROLLBACK/.touchstone" ] || fail "failed apply retained a managed directory"
[ -z "$(git -C "$ADOPT_APPLY_ROLLBACK" status --porcelain=v1)" ] \
  || fail "failed apply did not restore the clean checkout"

ADOPT_SIGNAL_ROLLBACK="$TMP_DIR/adopt-signal-rollback"
init_adoption_repo "$ADOPT_SIGNAL_ROLLBACK"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_SIGNAL_ROLLBACK/package.json"
commit_adoption_repo "$ADOPT_SIGNAL_ROLLBACK" "fixture"
git -C "$ADOPT_SIGNAL_ROLLBACK" switch -q -c feat/adopt
mkdir -p "$TMP_DIR/terminating-mv"
SIGNAL_MV_COUNT_FILE="$TMP_DIR/terminating-mv/count"
export SIGNAL_MV_COUNT_FILE
cat >"$TMP_DIR/terminating-mv/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
if [ -f "$SIGNAL_MV_COUNT_FILE" ]; then count="$(cat "$SIGNAL_MV_COUNT_FILE")"; fi
count=$((count + 1))
printf '%s\n' "$count" >"$SIGNAL_MV_COUNT_FILE"
"$REAL_MV" "$@"
if [ "$count" -eq 1 ]; then kill -TERM "$PPID"; fi
EOF
chmod +x "$TMP_DIR/terminating-mv/mv"
PATH="$TMP_DIR/terminating-mv:$PATH" run_adoption "$TMP_DIR/adopt-signal-rollback.out" adopt --project "$ADOPT_SIGNAL_ROLLBACK"
[ "$ADOPTION_STATUS" -eq 143 ] || fail "terminated apply did not preserve the signal exit status"
[ ! -e "$ADOPT_SIGNAL_ROLLBACK/.touchstone.toml" ] || fail "terminated apply retained its contract write"
[ ! -e "$ADOPT_SIGNAL_ROLLBACK/.touchstone" ] || fail "terminated apply retained a managed directory"
[ -z "$(find "$ADOPT_SIGNAL_ROLLBACK" \( -name '.touchstone-write.*' -o -name '.touchstone-backup.*' \) -print -quit)" ] \
  || fail "terminated apply retained transaction artifacts"
[ -z "$(git -C "$ADOPT_SIGNAL_ROLLBACK" status --porcelain=v1)" ] \
  || fail "terminated apply did not restore the clean checkout"

ADOPT_PYPROJECT="$TMP_DIR/adopt-pyproject"
init_adoption_repo "$ADOPT_PYPROJECT"
printf '%s\n' '[project]' 'name = "\u0066ixture"' 'dependencies = [' '  "pytest",' ']' \
  'authors = [{ name = "Touchstone", email = "test@example.invalid" }]' \
  '[project.urls]' 'Homepage = "https://example.invalid/project"' \
  >"$ADOPT_PYPROJECT/pyproject.toml"
commit_adoption_repo "$ADOPT_PYPROJECT" "fixture"
git -C "$ADOPT_PYPROJECT" switch -q -c feat/adopt
mkdir -p "$TMP_DIR/no-python"
cat >"$TMP_DIR/no-python/python3" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
chmod +x "$TMP_DIR/no-python/python3"
PATH="$TMP_DIR/no-python:$PATH" run_adoption "$TMP_DIR/adopt-pyproject.out" adopt --project "$ADOPT_PYPROJECT"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "installable pyproject adoption failed"
assert_contains "$ADOPT_PYPROJECT/.touchstone.toml" 'setup = "python -m pip install --no-index --no-build-isolation -e ."'
assert_contains "$ADOPT_PYPROJECT/.touchstone.toml" 'command = "python -m pytest"'

ADOPT_REQUIREMENTS="$TMP_DIR/adopt-requirements"
init_adoption_repo "$ADOPT_REQUIREMENTS"
mkdir -p "$ADOPT_REQUIREMENTS/tests"
printf '%s\n' 'pytest==9.0.0' >"$ADOPT_REQUIREMENTS/requirements.txt"
commit_adoption_repo "$ADOPT_REQUIREMENTS" "fixture"
git -C "$ADOPT_REQUIREMENTS" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-requirements.out" adopt --project "$ADOPT_REQUIREMENTS"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "requirements-backed adoption failed"
assert_contains "$ADOPT_REQUIREMENTS/.touchstone.toml" 'setup = "python -m pip install --no-index -r requirements.txt"'

ADOPT_REMOTE_REQUIREMENT="$TMP_DIR/adopt-remote-requirement"
init_adoption_repo "$ADOPT_REMOTE_REQUIREMENT"
mkdir -p "$ADOPT_REMOTE_REQUIREMENT/tests"
printf '%s\n' 'pytest @ https://example.invalid/pytest.whl' >"$ADOPT_REMOTE_REQUIREMENT/requirements.txt"
commit_adoption_repo "$ADOPT_REMOTE_REQUIREMENT" "fixture"
git -C "$ADOPT_REMOTE_REQUIREMENT" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-remote-requirement.out" adopt --dry-run --project "$ADOPT_REMOTE_REQUIREMENT"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "remote requirements reference produced an offline adoption plan"
assert_contains "$TMP_DIR/adopt-remote-requirement.out.err" 'remote direct dependency reference'

ADOPT_FILE_REQUIREMENT="$TMP_DIR/adopt-file-requirement"
init_adoption_repo "$ADOPT_FILE_REQUIREMENT"
mkdir -p "$ADOPT_FILE_REQUIREMENT/tests"
printf '%s\n' '--find-links file:///tmp/wheels' 'pytest==9.0.0' >"$ADOPT_FILE_REQUIREMENT/requirements.txt"
commit_adoption_repo "$ADOPT_FILE_REQUIREMENT" "fixture"
git -C "$ADOPT_FILE_REQUIREMENT" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-file-requirement.out" adopt --dry-run --project "$ADOPT_FILE_REQUIREMENT"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "checkout-external requirements source produced an adoption plan"
assert_contains "$TMP_DIR/adopt-file-requirement.out.err" 'checkout-external source'

ADOPT_FILE_PYPROJECT="$TMP_DIR/adopt-file-pyproject"
init_adoption_repo "$ADOPT_FILE_PYPROJECT"
mkdir -p "$ADOPT_FILE_PYPROJECT/tests"
printf '%s\n' '[project]' 'name = "fixture"' \
  'dependencies = ["pytest @ file:///tmp/pytest.whl"]' >"$ADOPT_FILE_PYPROJECT/pyproject.toml"
commit_adoption_repo "$ADOPT_FILE_PYPROJECT" "fixture"
git -C "$ADOPT_FILE_PYPROJECT" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-file-pyproject.out" adopt --dry-run --project "$ADOPT_FILE_PYPROJECT"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "checkout-external pyproject source produced an adoption plan"
assert_contains "$TMP_DIR/adopt-file-pyproject.out.err" 'checkout-external source'

ADOPT_MARKED_REQUIREMENT="$TMP_DIR/adopt-marked-requirement"
init_adoption_repo "$ADOPT_MARKED_REQUIREMENT"
mkdir -p "$ADOPT_MARKED_REQUIREMENT/tests"
printf '%s\n' 'pytest[testing]; python_version < "0"' >"$ADOPT_MARKED_REQUIREMENT/requirements.txt"
commit_adoption_repo "$ADOPT_MARKED_REQUIREMENT" "fixture"
git -C "$ADOPT_MARKED_REQUIREMENT" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-marked-requirement.out" adopt --dry-run --project "$ADOPT_MARKED_REQUIREMENT"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "environment-marked requirement produced a non-reproducible plan"
assert_contains "$TMP_DIR/adopt-marked-requirement.out.err" 'environment-marked dependency'

ADOPT_MARKED_PYPROJECT="$TMP_DIR/adopt-marked-pyproject"
init_adoption_repo "$ADOPT_MARKED_PYPROJECT"
mkdir -p "$ADOPT_MARKED_PYPROJECT/tests"
printf '%s\n' '[project]' 'name = "fixture"' \
  'dependencies = ["pytest; python_version < '\''0'\''"]' >"$ADOPT_MARKED_PYPROJECT/pyproject.toml"
commit_adoption_repo "$ADOPT_MARKED_PYPROJECT" "fixture"
git -C "$ADOPT_MARKED_PYPROJECT" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-marked-pyproject.out" adopt --dry-run --project "$ADOPT_MARKED_PYPROJECT"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "environment-marked pyproject dependency produced a plan"
assert_contains "$TMP_DIR/adopt-marked-pyproject.out.err" 'environment-marked dependency'

ADOPT_REMOTE_PYPROJECT="$TMP_DIR/adopt-remote-pyproject"
init_adoption_repo "$ADOPT_REMOTE_PYPROJECT"
mkdir -p "$ADOPT_REMOTE_PYPROJECT/tests"
printf '%s\n' '[project]' 'name = "fixture"' \
  'dependencies = ["pytest @ https://example.invalid/pytest.whl"]' \
  >"$ADOPT_REMOTE_PYPROJECT/pyproject.toml"
commit_adoption_repo "$ADOPT_REMOTE_PYPROJECT" "fixture"
git -C "$ADOPT_REMOTE_PYPROJECT" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-remote-pyproject.out" adopt --dry-run --project "$ADOPT_REMOTE_PYPROJECT"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "remote pyproject reference produced an offline adoption plan"
assert_contains "$TMP_DIR/adopt-remote-pyproject.out.err" 'remote direct dependency reference'

ADOPT_MALFORMED_PYPROJECT="$TMP_DIR/adopt-malformed-pyproject"
init_adoption_repo "$ADOPT_MALFORMED_PYPROJECT"
mkdir -p "$ADOPT_MALFORMED_PYPROJECT/tests"
printf '%s\n' '[project]' 'name = "fixture"' 'dependencies = ["pytest" "ruff"]' \
  >"$ADOPT_MALFORMED_PYPROJECT/pyproject.toml"
commit_adoption_repo "$ADOPT_MALFORMED_PYPROJECT" "fixture"
git -C "$ADOPT_MALFORMED_PYPROJECT" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-malformed-pyproject.out" adopt --dry-run --project "$ADOPT_MALFORMED_PYPROJECT"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "malformed pyproject.toml produced an adoption plan"
assert_contains "$TMP_DIR/adopt-malformed-pyproject.out.err" 'pyproject.toml is malformed'

ADOPT_MALFORMED_INLINE="$TMP_DIR/adopt-malformed-inline-pyproject"
init_adoption_repo "$ADOPT_MALFORMED_INLINE"
mkdir -p "$ADOPT_MALFORMED_INLINE/tests"
printf '%s\n' '[project]' 'name = "fixture"' 'dependencies = ["pytest"]' \
  'authors = [{ name = "Touchstone" email = "test@example.invalid" }]' \
  >"$ADOPT_MALFORMED_INLINE/pyproject.toml"
commit_adoption_repo "$ADOPT_MALFORMED_INLINE" "fixture"
git -C "$ADOPT_MALFORMED_INLINE" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-malformed-inline.out" adopt --dry-run --project "$ADOPT_MALFORMED_INLINE"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "malformed inline TOML table produced an adoption plan"
assert_contains "$TMP_DIR/adopt-malformed-inline.out.err" 'pyproject.toml is malformed'

ADOPT_DUPLICATE_PYPROJECT="$TMP_DIR/adopt-duplicate-pyproject"
init_adoption_repo "$ADOPT_DUPLICATE_PYPROJECT"
mkdir -p "$ADOPT_DUPLICATE_PYPROJECT/tests"
printf '%s\n' '[project]' 'name = "fixture"' 'dependencies = ["pytest"]' \
  'dependencies = []' >"$ADOPT_DUPLICATE_PYPROJECT/pyproject.toml"
commit_adoption_repo "$ADOPT_DUPLICATE_PYPROJECT" "fixture"
git -C "$ADOPT_DUPLICATE_PYPROJECT" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-duplicate-pyproject.out" adopt --dry-run --project "$ADOPT_DUPLICATE_PYPROJECT"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "duplicate pyproject.toml key produced an adoption plan"
assert_contains "$TMP_DIR/adopt-duplicate-pyproject.out.err" 'pyproject.toml is malformed'
printf '%s\n' '[project]' 'name = "fixture"' '[project]' 'dependencies = ["pytest"]' \
  >"$ADOPT_DUPLICATE_PYPROJECT/pyproject.toml"
run_adoption "$TMP_DIR/adopt-duplicate-table.out" adopt --dry-run --project "$ADOPT_DUPLICATE_PYPROJECT"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "duplicate pyproject.toml table produced an adoption plan"
printf '%s\n' '[project]' 'name = "fixture"' \
  'authors = [{ name = "first", name = "second" }]' \
  >"$ADOPT_DUPLICATE_PYPROJECT/pyproject.toml"
run_adoption "$TMP_DIR/adopt-duplicate-inline-key.out" adopt --dry-run --project "$ADOPT_DUPLICATE_PYPROJECT"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "duplicate inline TOML key produced an adoption plan"
printf '%s\n' '[project]' 'name = "fixture"' 'dependencies = ["pytest"]' \
  'metadata = { x = 1, x.y = 2 }' \
  >"$ADOPT_DUPLICATE_PYPROJECT/pyproject.toml"
run_adoption "$TMP_DIR/adopt-inline-prefix-collision.out" adopt --dry-run --project "$ADOPT_DUPLICATE_PYPROJECT"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "inline TOML scalar/prefix collision produced an adoption plan"
assert_contains "$TMP_DIR/adopt-inline-prefix-collision.out.err" 'pyproject.toml is malformed'
printf '%s\n' '[project]' 'name = "bad\qescape"' 'dependencies = ["pytest"]' \
  >"$ADOPT_DUPLICATE_PYPROJECT/pyproject.toml"
run_adoption "$TMP_DIR/adopt-invalid-string-escape.out" adopt --dry-run --project "$ADOPT_DUPLICATE_PYPROJECT"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "invalid TOML string escape produced an adoption plan"
printf '%s\n' '[project]' 'name = "bad\uD800scalar"' 'dependencies = ["pytest"]' \
  >"$ADOPT_DUPLICATE_PYPROJECT/pyproject.toml"
run_adoption "$TMP_DIR/adopt-invalid-unicode-scalar.out" adopt --dry-run --project "$ADOPT_DUPLICATE_PYPROJECT"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "invalid TOML Unicode scalar produced an adoption plan"
printf '%s\n' '[project]' 'name = "fixture"' 'dependencies = ["pytest"]' \
  '[tool.fixture]' 'mode = nope' >"$ADOPT_DUPLICATE_PYPROJECT/pyproject.toml"
run_adoption "$TMP_DIR/adopt-invalid-bare-value.out" adopt --dry-run --project "$ADOPT_DUPLICATE_PYPROJECT"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "invalid TOML bare value produced an adoption plan"

ADOPT_UNDECLARED_CHECKER="$TMP_DIR/adopt-undeclared-checker"
init_adoption_repo "$ADOPT_UNDECLARED_CHECKER"
mkdir -p "$ADOPT_UNDECLARED_CHECKER/tests"
printf '%s\n' '[project]' 'name = "fixture"' 'dependencies = []' \
  >"$ADOPT_UNDECLARED_CHECKER/pyproject.toml"
commit_adoption_repo "$ADOPT_UNDECLARED_CHECKER" "fixture"
git -C "$ADOPT_UNDECLARED_CHECKER" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-undeclared-checker.out" adopt --dry-run --project "$ADOPT_UNDECLARED_CHECKER"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "undeclared Python checker did not refuse"
assert_contains "$TMP_DIR/adopt-undeclared-checker.out.err" "without an installed pytest dependency"

ADOPT_MIXED_PYTHON="$TMP_DIR/adopt-mixed-python"
init_adoption_repo "$ADOPT_MIXED_PYTHON"
mkdir -p "$ADOPT_MIXED_PYTHON/tests"
printf '%s\n' 'requests==2.0.0' >"$ADOPT_MIXED_PYTHON/requirements.txt"
printf '%s\n' '[project]' 'name = "fixture"' 'dependencies = ["pytest"]' \
  >"$ADOPT_MIXED_PYTHON/pyproject.toml"
commit_adoption_repo "$ADOPT_MIXED_PYTHON" "fixture"
git -C "$ADOPT_MIXED_PYTHON" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-mixed-python.out" adopt --dry-run --project "$ADOPT_MIXED_PYTHON"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "mixed Python setup accepted an uninstalled checker"
assert_contains "$TMP_DIR/adopt-mixed-python.out.err" "without an installed pytest dependency"

ADOPT_TOOL_ONLY_PYTHON="$TMP_DIR/adopt-tool-only-python"
init_adoption_repo "$ADOPT_TOOL_ONLY_PYTHON"
printf '%s\n' '[tool.pytest.ini_options]' >"$ADOPT_TOOL_ONLY_PYTHON/pyproject.toml"
commit_adoption_repo "$ADOPT_TOOL_ONLY_PYTHON" "fixture"
git -C "$ADOPT_TOOL_ONLY_PYTHON" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-tool-only-python.out" adopt --dry-run --project "$ADOPT_TOOL_ONLY_PYTHON"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "tool-only Python project did not refuse"
assert_contains "$TMP_DIR/adopt-tool-only-python.out.err" "no installable project or dependency declaration"

ADOPT_UV_DEV="$TMP_DIR/adopt-uv-dev"
init_adoption_repo "$ADOPT_UV_DEV"
mkdir -p "$ADOPT_UV_DEV/tests"
printf '%s\n' '[project]' 'name = "fixture"' 'dependencies = []' \
  '[tool.uv]' 'default-groups = []' '[dependency-groups]' 'dev = ["pytest"]' \
  >"$ADOPT_UV_DEV/pyproject.toml"
printf 'version = 1\n' >"$ADOPT_UV_DEV/uv.lock"
commit_adoption_repo "$ADOPT_UV_DEV" "fixture"
git -C "$ADOPT_UV_DEV" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-uv-dev.out" adopt --project "$ADOPT_UV_DEV"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "uv dev-group adoption failed"
assert_contains "$ADOPT_UV_DEV/.touchstone.toml" 'setup = "uv sync --offline --frozen --group dev"'

echo "==> adoption derives explicit monorepo targets"
ADOPT_MONOREPO="$TMP_DIR/adopt-monorepo"
init_adoption_repo "$ADOPT_MONOREPO"
mkdir -p "$ADOPT_MONOREPO/apps/api" "$ADOPT_MONOREPO/packages/web"
printf '%s\n' '{"packageManager":"pnpm@10.0.0","workspaces":["apps/*","packages/*"],"scripts":{"lint":"eslint ."}}' \
  >"$ADOPT_MONOREPO/package.json"
printf 'lockfileVersion: '\''9.0'\''\n' >"$ADOPT_MONOREPO/pnpm-lock.yaml"
printf '%s\n' 'packages:' '  - apps/*' '  - packages/*' >"$ADOPT_MONOREPO/pnpm-workspace.yaml"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_MONOREPO/apps/api/package.json"
printf '%s\n' '{"scripts":{"build":"node build.js"}}' >"$ADOPT_MONOREPO/packages/web/package.json"
commit_adoption_repo "$ADOPT_MONOREPO" "fixture"
git -C "$ADOPT_MONOREPO" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-monorepo.out" adopt --project "$ADOPT_MONOREPO"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "monorepo adoption failed"
assert_contains "$ADOPT_MONOREPO/.touchstone.toml" 'path = "apps/api"'
assert_contains "$ADOPT_MONOREPO/.touchstone.toml" 'path = "packages/web"'
assert_contains "$ADOPT_MONOREPO/.touchstone.toml" 'name = "test-apps-api"'
assert_contains "$ADOPT_MONOREPO/.touchstone.toml" 'name = "build-packages-web"'
assert_contains "$ADOPT_MONOREPO/.touchstone.toml" 'command = "pnpm run test"'
assert_contains "$ADOPT_MONOREPO/.touchstone.toml" 'command = "pnpm run build"'
assert_contains "$ADOPT_MONOREPO/.touchstone.toml" 'name = "lint"'
assert_contains "$ADOPT_MONOREPO/.touchstone.toml" 'target = "root"'
assert_contains "$ADOPT_MONOREPO/.touchstone.toml" 'command = "pnpm run lint"'
assert_contains "$ADOPT_MONOREPO/.touchstone.toml" 'setup = "pnpm install --offline --frozen-lockfile"'
bash "$RUNNER" validate --check-contract --project "$ADOPT_MONOREPO" >/dev/null

ADOPT_NON_WORKSPACE_CHILD="$TMP_DIR/adopt-non-workspace-child"
init_adoption_repo "$ADOPT_NON_WORKSPACE_CHILD"
mkdir -p "$ADOPT_NON_WORKSPACE_CHILD/apps/api"
printf '%s\n' '{"packageManager":"npm@11.0.0"}' >"$ADOPT_NON_WORKSPACE_CHILD/package.json"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_NON_WORKSPACE_CHILD/apps/api/package.json"
printf '{}\n' >"$ADOPT_NON_WORKSPACE_CHILD/apps/api/package-lock.json"
commit_adoption_repo "$ADOPT_NON_WORKSPACE_CHILD" "fixture"
git -C "$ADOPT_NON_WORKSPACE_CHILD" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-non-workspace-child.out" adopt --project "$ADOPT_NON_WORKSPACE_CHILD"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "non-workspace child adoption failed"
assert_contains "$ADOPT_NON_WORKSPACE_CHILD/.touchstone.toml" 'setup = "(cd apps/api && npm ci --offline)"'

ADOPT_WORKSPACE_CHILD="$TMP_DIR/adopt-workspace-child"
init_adoption_repo "$ADOPT_WORKSPACE_CHILD"
mkdir -p "$ADOPT_WORKSPACE_CHILD/apps/api"
printf '%s\n' '{"packageManager":"npm@11.0.0","workspaces":["apps/*"]}' \
  >"$ADOPT_WORKSPACE_CHILD/package.json"
printf '{}\n' >"$ADOPT_WORKSPACE_CHILD/package-lock.json"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_WORKSPACE_CHILD/apps/api/package.json"
commit_adoption_repo "$ADOPT_WORKSPACE_CHILD" "fixture"
git -C "$ADOPT_WORKSPACE_CHILD" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-workspace-child.out" adopt --project "$ADOPT_WORKSPACE_CHILD"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "declared workspace child adoption failed"
assert_contains "$ADOPT_WORKSPACE_CHILD/.touchstone.toml" 'setup = "npm ci --offline"'
assert_not_contains "$ADOPT_WORKSPACE_CHILD/.touchstone.toml" '(cd apps/api'

ADOPT_PNPM_AUTHORITY="$TMP_DIR/adopt-pnpm-authority"
init_adoption_repo "$ADOPT_PNPM_AUTHORITY"
mkdir -p "$ADOPT_PNPM_AUTHORITY/apps/api"
printf '%s\n' '{"packageManager":"pnpm@10.0.0","workspaces":["apps/*"]}' \
  >"$ADOPT_PNPM_AUTHORITY/package.json"
printf '%s\n' 'packages:' '  - packages/*' >"$ADOPT_PNPM_AUTHORITY/pnpm-workspace.yaml"
printf 'lockfileVersion: '\''9.0'\''\n' >"$ADOPT_PNPM_AUTHORITY/pnpm-lock.yaml"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_PNPM_AUTHORITY/apps/api/package.json"
printf 'lockfileVersion: '\''9.0'\''\n' >"$ADOPT_PNPM_AUTHORITY/apps/api/pnpm-lock.yaml"
commit_adoption_repo "$ADOPT_PNPM_AUTHORITY" "fixture"
git -C "$ADOPT_PNPM_AUTHORITY" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-pnpm-authority.out" adopt --project "$ADOPT_PNPM_AUTHORITY"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "pnpm workspace authority adoption failed"
assert_contains "$ADOPT_PNPM_AUTHORITY/.touchstone.toml" 'setup = "(cd apps/api && pnpm install --offline --frozen-lockfile)"'

ADOPT_CARGO_WORKSPACE="$TMP_DIR/adopt-cargo-workspace"
init_adoption_repo "$ADOPT_CARGO_WORKSPACE"
mkdir -p "$ADOPT_CARGO_WORKSPACE/packages/core"
printf '%s\n' '[workspace]' 'members = ["packages/unused", "packages/*"]' 'resolver = "2"' \
  >"$ADOPT_CARGO_WORKSPACE/Cargo.toml"
printf '%s\n' 'version = 4' >"$ADOPT_CARGO_WORKSPACE/Cargo.lock"
printf '%s\n' '[package]' 'name = "core"' 'version = "0.1.0"' 'edition = "2024"' \
  >"$ADOPT_CARGO_WORKSPACE/packages/core/Cargo.toml"
commit_adoption_repo "$ADOPT_CARGO_WORKSPACE" "fixture"
git -C "$ADOPT_CARGO_WORKSPACE" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-cargo-workspace.out" adopt --project "$ADOPT_CARGO_WORKSPACE"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "Cargo workspace adoption failed"
assert_contains "$ADOPT_CARGO_WORKSPACE/.touchstone.toml" 'path = "packages/core"'
assert_contains "$ADOPT_CARGO_WORKSPACE/.touchstone.toml" 'name = "test-packages-core"'
assert_contains "$ADOPT_CARGO_WORKSPACE/.touchstone.toml" 'command = "cargo test --frozen"'
bash "$RUNNER" validate --check-contract --project "$ADOPT_CARGO_WORKSPACE" >/dev/null

ADOPT_UNSUPPORTED_WORKSPACE_GLOB="$TMP_DIR/adopt-unsupported-workspace-glob"
init_adoption_repo "$ADOPT_UNSUPPORTED_WORKSPACE_GLOB"
mkdir -p "$ADOPT_UNSUPPORTED_WORKSPACE_GLOB/apps/api"
printf '%s\n' '{"packageManager":"npm@11.0.0","workspaces":["{apps,packages}/*"]}' \
  >"$ADOPT_UNSUPPORTED_WORKSPACE_GLOB/package.json"
printf '{}\n' >"$ADOPT_UNSUPPORTED_WORKSPACE_GLOB/package-lock.json"
printf '%s\n' '{"scripts":{"test":"node --test"}}' \
  >"$ADOPT_UNSUPPORTED_WORKSPACE_GLOB/apps/api/package.json"
commit_adoption_repo "$ADOPT_UNSUPPORTED_WORKSPACE_GLOB" "fixture"
git -C "$ADOPT_UNSUPPORTED_WORKSPACE_GLOB" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-unsupported-workspace-glob.out" adopt --dry-run --project "$ADOPT_UNSUPPORTED_WORKSPACE_GLOB"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "unsupported workspace glob produced an incomplete plan"
assert_contains "$TMP_DIR/adopt-unsupported-workspace-glob.out.err" 'uses glob syntax this compiler cannot verify'
[ ! -e "$ADOPT_UNSUPPORTED_WORKSPACE_GLOB/.touchstone.toml" ] \
  || fail "unsupported workspace glob mutated the repository"

ADOPT_PNPM_FLOW_WORKSPACE="$TMP_DIR/adopt-pnpm-flow-workspace"
init_adoption_repo "$ADOPT_PNPM_FLOW_WORKSPACE"
mkdir -p "$ADOPT_PNPM_FLOW_WORKSPACE/apps/api"
printf '%s\n' '{"packageManager":"pnpm@10.0.0"}' >"$ADOPT_PNPM_FLOW_WORKSPACE/package.json"
printf 'lockfileVersion: '\''9.0'\''\n' >"$ADOPT_PNPM_FLOW_WORKSPACE/pnpm-lock.yaml"
printf '%s\n' "packages: ['apps/*']" >"$ADOPT_PNPM_FLOW_WORKSPACE/pnpm-workspace.yaml"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_PNPM_FLOW_WORKSPACE/apps/api/package.json"
commit_adoption_repo "$ADOPT_PNPM_FLOW_WORKSPACE" "fixture"
git -C "$ADOPT_PNPM_FLOW_WORKSPACE" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-pnpm-flow-workspace.out" adopt --project "$ADOPT_PNPM_FLOW_WORKSPACE"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "flow-style pnpm workspace adoption failed"
assert_contains "$ADOPT_PNPM_FLOW_WORKSPACE/.touchstone.toml" 'path = "apps/api"'
assert_contains "$ADOPT_PNPM_FLOW_WORKSPACE/.touchstone.toml" 'setup = "pnpm install --offline --frozen-lockfile"'
assert_not_contains "$ADOPT_PNPM_FLOW_WORKSPACE/.touchstone.toml" '(cd apps/api'

ADOPT_PNPM_NON_STRING="$TMP_DIR/adopt-pnpm-non-string"
init_adoption_repo "$ADOPT_PNPM_NON_STRING"
mkdir -p "$ADOPT_PNPM_NON_STRING/apps/api"
printf '%s\n' '{"packageManager":"pnpm@10.0.0"}' >"$ADOPT_PNPM_NON_STRING/package.json"
printf 'lockfileVersion: '\''9.0'\''\n' >"$ADOPT_PNPM_NON_STRING/pnpm-lock.yaml"
printf '%s\n' 'packages:' '  - apps/*' '  - 1' >"$ADOPT_PNPM_NON_STRING/pnpm-workspace.yaml"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_PNPM_NON_STRING/apps/api/package.json"
commit_adoption_repo "$ADOPT_PNPM_NON_STRING" "fixture"
git -C "$ADOPT_PNPM_NON_STRING" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-pnpm-non-string.out" adopt --dry-run --project "$ADOPT_PNPM_NON_STRING"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "non-string pnpm workspace entry produced a plan"
assert_contains "$TMP_DIR/adopt-pnpm-non-string.out.err" 'malformed, duplicate, or unsupported packages declarations'

ADOPT_DUPLICATE_WORKSPACES="$TMP_DIR/adopt-duplicate-workspaces"
init_adoption_repo "$ADOPT_DUPLICATE_WORKSPACES"
mkdir -p "$ADOPT_DUPLICATE_WORKSPACES/apps/api"
printf '%s\n' '{"workspaces":["apps/*"],"workspaces":[],"scripts":{"test":"node --test"}}' \
  >"$ADOPT_DUPLICATE_WORKSPACES/package.json"
printf '{}\n' >"$ADOPT_DUPLICATE_WORKSPACES/package-lock.json"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_DUPLICATE_WORKSPACES/apps/api/package.json"
commit_adoption_repo "$ADOPT_DUPLICATE_WORKSPACES" "fixture"
git -C "$ADOPT_DUPLICATE_WORKSPACES" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-duplicate-workspaces.out" adopt --dry-run --project "$ADOPT_DUPLICATE_WORKSPACES"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "duplicate root workspaces declaration produced a plan"
assert_contains "$TMP_DIR/adopt-duplicate-workspaces.out.err" "malformed, repeated, or unsupported workspace declaration"

ADOPT_DUPLICATE_WORKSPACE_PACKAGES="$TMP_DIR/adopt-duplicate-workspace-packages"
init_adoption_repo "$ADOPT_DUPLICATE_WORKSPACE_PACKAGES"
mkdir -p "$ADOPT_DUPLICATE_WORKSPACE_PACKAGES/apps/api"
printf '%s\n' '{"workspaces":{"packages":["apps/*"],"packages":[]},"scripts":{"test":"node --test"}}' \
  >"$ADOPT_DUPLICATE_WORKSPACE_PACKAGES/package.json"
printf '{}\n' >"$ADOPT_DUPLICATE_WORKSPACE_PACKAGES/package-lock.json"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_DUPLICATE_WORKSPACE_PACKAGES/apps/api/package.json"
commit_adoption_repo "$ADOPT_DUPLICATE_WORKSPACE_PACKAGES" "fixture"
git -C "$ADOPT_DUPLICATE_WORKSPACE_PACKAGES" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-duplicate-workspace-packages.out" adopt --dry-run --project "$ADOPT_DUPLICATE_WORKSPACE_PACKAGES"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "duplicate workspace packages declaration produced a plan"
assert_contains "$TMP_DIR/adopt-duplicate-workspace-packages.out.err" "malformed, repeated, or unsupported workspace declaration"

ADOPT_NON_STRING_WORKSPACE="$TMP_DIR/adopt-non-string-workspace"
init_adoption_repo "$ADOPT_NON_STRING_WORKSPACE"
mkdir -p "$ADOPT_NON_STRING_WORKSPACE/apps/api"
printf '%s\n' '{"packageManager":"npm@11.0.0","workspaces":["apps/*",1]}' \
  >"$ADOPT_NON_STRING_WORKSPACE/package.json"
printf '{}\n' >"$ADOPT_NON_STRING_WORKSPACE/package-lock.json"
printf '%s\n' '{"scripts":{"test":"node --test"}}' \
  >"$ADOPT_NON_STRING_WORKSPACE/apps/api/package.json"
commit_adoption_repo "$ADOPT_NON_STRING_WORKSPACE" "fixture"
git -C "$ADOPT_NON_STRING_WORKSPACE" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-non-string-workspace.out" adopt --dry-run --project "$ADOPT_NON_STRING_WORKSPACE"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "non-string workspace entry produced a partial plan"
assert_contains "$TMP_DIR/adopt-non-string-workspace.out.err" "malformed, repeated, or unsupported workspace declaration"
[ ! -e "$ADOPT_NON_STRING_WORKSPACE/.touchstone.toml" ] \
  || fail "non-string workspace entry mutated the repository"

ADOPT_LARGE="$TMP_DIR/adopt-large"
init_adoption_repo "$ADOPT_LARGE"
mkdir -p "$ADOPT_LARGE/packages"
printf '{}\n' >"$ADOPT_LARGE/tsconfig.json"
index=1
while [ "$index" -le 24 ]; do
  mkdir -p "$ADOPT_LARGE/packages/unit-$index"
  printf '%s\n' '{"scripts":{"test":"node --test"}}' \
    >"$ADOPT_LARGE/packages/unit-$index/package.json"
  index=$((index + 1))
done
commit_adoption_repo "$ADOPT_LARGE" "fixture"
git -C "$ADOPT_LARGE" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-large.out" adopt --project "$ADOPT_LARGE"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "large monorepo adoption failed"
assert_contains "$ADOPT_LARGE/.touchstone.toml" 'path = "packages/unit-24"'
task_count="$(grep -c '^\[\[validation.tasks\]\]$' "$ADOPT_LARGE/.touchstone.toml")"
[ "$task_count" -eq 24 ] || fail "large monorepo did not derive all explicit tasks"
bash "$RUNNER" validate --check-contract --project "$ADOPT_LARGE" >/dev/null

echo "==> adoption fails closed on ambiguous and unsupported contracts"
ADOPT_AMBIGUOUS="$TMP_DIR/adopt-ambiguous"
init_adoption_repo "$ADOPT_AMBIGUOUS"
mkdir -p "$ADOPT_AMBIGUOUS/packages/child"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_AMBIGUOUS/package.json"
printf '%s\n' '[tool.pytest.ini_options]' >"$ADOPT_AMBIGUOUS/pyproject.toml"
printf '%s\n' '{"scripts":{"test":"node --test"}}' \
  >"$ADOPT_AMBIGUOUS/packages/child/package.json"
commit_adoption_repo "$ADOPT_AMBIGUOUS" "fixture"
git -C "$ADOPT_AMBIGUOUS" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-ambiguous.out" adopt --dry-run --project "$ADOPT_AMBIGUOUS"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "ambiguous adoption did not refuse"
assert_contains "$TMP_DIR/adopt-ambiguous.out.err" "ambiguous project facts"
[ ! -e "$ADOPT_AMBIGUOUS/.touchstone.toml" ] || fail "ambiguous adoption wrote a contract"

ADOPT_MANAGER="$TMP_DIR/adopt-manager"
init_adoption_repo "$ADOPT_MANAGER"
printf '%s\n' '{"packageManager":"pnpm@10.0.0","scripts":{"test":"node --test"}}' \
  >"$ADOPT_MANAGER/package.json"
printf '{}\n' >"$ADOPT_MANAGER/package-lock.json"
commit_adoption_repo "$ADOPT_MANAGER" "fixture"
git -C "$ADOPT_MANAGER" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-manager.out" adopt --dry-run --project "$ADOPT_MANAGER"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "package manager conflict did not refuse"
assert_contains "$TMP_DIR/adopt-manager.out.err" "conflicts with the 'npm' lockfile"
run_adoption "$TMP_DIR/adopt-manager-json.out" adopt --dry-run --json --project "$ADOPT_MANAGER"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "JSON package manager conflict did not refuse"
assert_contains "$TMP_DIR/adopt-manager-json.out" '"status":"contract-refused"'
assert_contains "$TMP_DIR/adopt-manager-json.out" "conflicts with the 'npm' lockfile"

ADOPT_CHILD_MANAGER="$TMP_DIR/adopt-child-manager"
init_adoption_repo "$ADOPT_CHILD_MANAGER"
mkdir -p "$ADOPT_CHILD_MANAGER/packages/child"
printf '%s\n' '{"packageManager":"pnpm@10.0.0"}' >"$ADOPT_CHILD_MANAGER/package.json"
printf 'lockfileVersion: '\''9.0'\''\n' >"$ADOPT_CHILD_MANAGER/pnpm-lock.yaml"
printf '%s\n' '{"packageManager":"npm@11.0.0","scripts":{"test":"node --test"}}' \
  >"$ADOPT_CHILD_MANAGER/packages/child/package.json"
printf '{}\n' >"$ADOPT_CHILD_MANAGER/packages/child/package-lock.json"
commit_adoption_repo "$ADOPT_CHILD_MANAGER" "fixture"
git -C "$ADOPT_CHILD_MANAGER" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-child-manager.out" adopt --dry-run --json --project "$ADOPT_CHILD_MANAGER"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "JSON child manager conflict did not refuse"
assert_contains "$TMP_DIR/adopt-child-manager.out" '"status":"contract-refused"'
assert_contains "$TMP_DIR/adopt-child-manager.out" "conflicts with workspace package manager 'pnpm'"

ADOPT_ESCAPED_JSON="$TMP_DIR/adopt-escaped-json"
init_adoption_repo "$ADOPT_ESCAPED_JSON"
printf '%s\n' '{"packageManager":"p\u006epm@10.0.0","scr\u0069pts":{"te\u0073t":"node --test"}}' \
  >"$ADOPT_ESCAPED_JSON/package.json"
printf 'lockfileVersion: '\''9.0'\''\n' >"$ADOPT_ESCAPED_JSON/pnpm-lock.yaml"
commit_adoption_repo "$ADOPT_ESCAPED_JSON" "fixture"
git -C "$ADOPT_ESCAPED_JSON" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-escaped-json.out" adopt --project "$ADOPT_ESCAPED_JSON"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "escaped JSON adoption failed"
assert_contains "$ADOPT_ESCAPED_JSON/.touchstone.toml" 'command = "pnpm run test"'

ADOPT_EMPTY_AGGREGATE="$TMP_DIR/adopt-empty-aggregate"
init_adoption_repo "$ADOPT_EMPTY_AGGREGATE"
printf '%s\n' '{"scripts":{"validate":"","verify":" \t","test":"node --test"}}' \
  >"$ADOPT_EMPTY_AGGREGATE/package.json"
printf '{}\n' >"$ADOPT_EMPTY_AGGREGATE/package-lock.json"
commit_adoption_repo "$ADOPT_EMPTY_AGGREGATE" "fixture"
git -C "$ADOPT_EMPTY_AGGREGATE" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-empty-aggregate.out" adopt --project "$ADOPT_EMPTY_AGGREGATE"
[ "$ADOPTION_STATUS" -eq 0 ] || fail "empty aggregate adoption failed"
assert_contains "$ADOPT_EMPTY_AGGREGATE/.touchstone.toml" 'command = "npm run test"'
assert_not_contains "$ADOPT_EMPTY_AGGREGATE/.touchstone.toml" 'npm run validate'
assert_not_contains "$ADOPT_EMPTY_AGGREGATE/.touchstone.toml" 'npm run verify'

for yarn_case in unlocked berry classic; do
  ADOPT_YARN="$TMP_DIR/adopt-yarn-$yarn_case"
  init_adoption_repo "$ADOPT_YARN"
  if [ "$yarn_case" = classic ]; then
    printf '%s\n' '{"packageManager":"yarn@1.22.22","scripts":{"test":"node --test"}}' \
      >"$ADOPT_YARN/package.json"
    printf '# yarn lockfile v1\n' >"$ADOPT_YARN/yarn.lock"
  else
    printf '%s\n' '{"packageManager":"yarn@4.14.1","scripts":{"test":"node --test"}}' \
      >"$ADOPT_YARN/package.json"
    if [ "$yarn_case" = berry ]; then printf '__metadata:\n  version: 8\n' >"$ADOPT_YARN/yarn.lock"; fi
  fi
  commit_adoption_repo "$ADOPT_YARN" "fixture"
  git -C "$ADOPT_YARN" switch -q -c feat/adopt
  run_adoption "$TMP_DIR/adopt-yarn-$yarn_case.out" adopt --project "$ADOPT_YARN"
  [ "$ADOPTION_STATUS" -eq 0 ] || fail "$yarn_case Yarn adoption failed"
  if [ "$yarn_case" = berry ]; then
    assert_contains "$ADOPT_YARN/.touchstone.toml" 'setup = "yarn install --immutable --immutable-cache"'
  elif [ "$yarn_case" = classic ]; then
    assert_contains "$ADOPT_YARN/.touchstone.toml" 'setup = "yarn install --offline --frozen-lockfile"'
  else
    assert_not_contains "$ADOPT_YARN/.touchstone.toml" 'setup = '
  fi
done

ADOPT_BAD_JSON="$TMP_DIR/adopt-bad-json"
init_adoption_repo "$ADOPT_BAD_JSON"
printf '%s\n' '{"scripts":null,"dependencies":{"test":"1.0.0"}}' \
  >"$ADOPT_BAD_JSON/package.json"
commit_adoption_repo "$ADOPT_BAD_JSON" "fixture"
git -C "$ADOPT_BAD_JSON" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-bad-json.out" adopt --dry-run --project "$ADOPT_BAD_JSON"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "non-object package scripts did not refuse"
assert_contains "$TMP_DIR/adopt-bad-json.out.err" "scripts is not an object"
printf '%s\n' '{"scripts":{"test":{}}}' >"$ADOPT_BAD_JSON/package.json"
run_adoption "$TMP_DIR/adopt-bad-script.out" adopt --dry-run --project "$ADOPT_BAD_JSON"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "non-string package script did not refuse"
assert_contains "$TMP_DIR/adopt-bad-script.out.err" "package.json is malformed"
printf '%s\n' '{"scripts":{"test":"node --test"} "missingComma":true}' \
  >"$ADOPT_BAD_JSON/package.json"
run_adoption "$TMP_DIR/adopt-invalid-json.out" adopt --dry-run --project "$ADOPT_BAD_JSON"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "syntactically invalid package.json did not refuse"
assert_contains "$TMP_DIR/adopt-invalid-json.out.err" "package.json is malformed"
printf '%s\n' '{"scripts":{"test":"node --test","test":""}}' >"$ADOPT_BAD_JSON/package.json"
run_adoption "$TMP_DIR/adopt-duplicate-script.out" adopt --dry-run --project "$ADOPT_BAD_JSON"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "duplicate package script did not refuse"
assert_contains "$TMP_DIR/adopt-duplicate-script.out.err" "package.json is malformed"

ADOPT_UNSUPPORTED="$TMP_DIR/adopt-unsupported"
init_adoption_repo "$ADOPT_UNSUPPORTED"
printf 'schema = 2\n' >"$ADOPT_UNSUPPORTED/.touchstone.toml"
commit_adoption_repo "$ADOPT_UNSUPPORTED" "fixture"
git -C "$ADOPT_UNSUPPORTED" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-unsupported.out" upgrade --check --json --project "$ADOPT_UNSUPPORTED"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "unsupported schema did not refuse"
assert_contains "$TMP_DIR/adopt-unsupported.out" '"status":"contract-refused"'
assert_contains "$TMP_DIR/adopt-unsupported.out" "accepts schema 1"

ADOPT_MISSING_TARGET="$TMP_DIR/adopt-missing-target"
init_adoption_repo "$ADOPT_MISSING_TARGET"
cat >"$ADOPT_MISSING_TARGET/.touchstone.toml" <<'EOF'
schema = 1

[validation]
runtime = "bash"

[[validation.targets]]
name = "missing"
path = "missing"

[[validation.tasks]]
name = "test"
target = "missing"
command = "true"
required = true
EOF
commit_adoption_repo "$ADOPT_MISSING_TARGET" "fixture"
git -C "$ADOPT_MISSING_TARGET" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-missing-target.out" adopt --dry-run --project "$ADOPT_MISSING_TARGET"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "existing contract with a missing target did not refuse"
assert_contains "$TMP_DIR/adopt-missing-target.out.err" "path not found: missing"

echo "==> adoption refuses default, dirty, and symlink-escaped writes"
ADOPT_SAFETY="$TMP_DIR/adopt-safety"
init_adoption_repo "$ADOPT_SAFETY"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_SAFETY/package.json"
commit_adoption_repo "$ADOPT_SAFETY" "fixture"
run_adoption "$TMP_DIR/adopt-default.out" adopt --project "$ADOPT_SAFETY"
[ "$ADOPTION_STATUS" -eq 5 ] || fail "default-branch apply did not refuse"
assert_contains "$TMP_DIR/adopt-default.out.err" "non-default branch"
[ ! -e "$ADOPT_SAFETY/.touchstone.toml" ] || fail "default-branch refusal partially wrote"
ADOPT_UNKNOWN_DEFAULT="$TMP_DIR/adopt-unknown-default"
init_adoption_repo "$ADOPT_UNKNOWN_DEFAULT"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_UNKNOWN_DEFAULT/package.json"
commit_adoption_repo "$ADOPT_UNKNOWN_DEFAULT" "fixture"
git -C "$ADOPT_UNKNOWN_DEFAULT" switch -q -c trunk
git -C "$ADOPT_UNKNOWN_DEFAULT" symbolic-ref --delete refs/remotes/origin/HEAD
run_adoption "$TMP_DIR/adopt-unknown-default.out" adopt --project "$ADOPT_UNKNOWN_DEFAULT"
[ "$ADOPTION_STATUS" -eq 5 ] || fail "unknown default branch did not refuse"
assert_contains "$TMP_DIR/adopt-unknown-default.out.err" "known default branch"
[ ! -e "$ADOPT_UNKNOWN_DEFAULT/.touchstone.toml" ] || fail "unknown default refusal partially wrote"
git -C "$ADOPT_SAFETY" switch -q -c feat/adopt
printf '\n' >>"$ADOPT_SAFETY/package.json"
run_adoption "$TMP_DIR/adopt-dirty.out" adopt --project "$ADOPT_SAFETY"
[ "$ADOPTION_STATUS" -eq 5 ] || fail "dirty apply did not refuse"
assert_contains "$TMP_DIR/adopt-dirty.out.err" "clean worktree"
[ ! -e "$ADOPT_SAFETY/.touchstone.toml" ] || fail "dirty refusal partially wrote"

ADOPT_SYMLINK="$TMP_DIR/adopt-symlink"
ADOPT_OUTSIDE="$TMP_DIR/adopt-outside"
init_adoption_repo "$ADOPT_SYMLINK"
mkdir -p "$ADOPT_OUTSIDE"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_SYMLINK/package.json"
ln -s "$ADOPT_OUTSIDE" "$ADOPT_SYMLINK/.touchstone"
commit_adoption_repo "$ADOPT_SYMLINK" "fixture"
git -C "$ADOPT_SYMLINK" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-symlink.out" adopt --dry-run --project "$ADOPT_SYMLINK"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "symlinked managed ancestor did not refuse"
assert_contains "$TMP_DIR/adopt-symlink.out.err" "managed path traverses a symlink"
[ -z "$(find "$ADOPT_OUTSIDE" -mindepth 1 -print -quit)" ] || fail "adoption wrote outside its boundary"

ADOPT_TARGET_SYMLINK="$TMP_DIR/adopt-target-symlink"
ADOPT_TARGET_OUTSIDE="$TMP_DIR/adopt-target-outside"
init_adoption_repo "$ADOPT_TARGET_SYMLINK"
mkdir -p "$ADOPT_TARGET_SYMLINK/apps" "$ADOPT_TARGET_OUTSIDE"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_TARGET_OUTSIDE/package.json"
ln -s "$ADOPT_TARGET_OUTSIDE" "$ADOPT_TARGET_SYMLINK/apps/external"
commit_adoption_repo "$ADOPT_TARGET_SYMLINK" "fixture"
git -C "$ADOPT_TARGET_SYMLINK" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-target-symlink.out" adopt --dry-run --project "$ADOPT_TARGET_SYMLINK"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "symlinked monorepo target did not refuse"
assert_contains "$TMP_DIR/adopt-target-symlink.out.err" "resolves outside the repository"

ADOPT_IGNORED_TARGET_SYMLINK="$TMP_DIR/adopt-ignored-target-symlink"
init_adoption_repo "$ADOPT_IGNORED_TARGET_SYMLINK"
mkdir -p "$ADOPT_IGNORED_TARGET_SYMLINK/apps" "$ADOPT_IGNORED_TARGET_SYMLINK/modules/api"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_IGNORED_TARGET_SYMLINK/modules/api/package.json"
printf '%s\n' 'apps/api' >"$ADOPT_IGNORED_TARGET_SYMLINK/.gitignore"
commit_adoption_repo "$ADOPT_IGNORED_TARGET_SYMLINK" "fixture"
ln -s ../modules/api "$ADOPT_IGNORED_TARGET_SYMLINK/apps/api"
git -C "$ADOPT_IGNORED_TARGET_SYMLINK" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-ignored-target-symlink.out" adopt --dry-run --project "$ADOPT_IGNORED_TARGET_SYMLINK"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "ignored monorepo target symlink produced a plan"
assert_contains "$TMP_DIR/adopt-ignored-target-symlink.out.err" "compiler input 'apps/api' is not tracked"

ADOPT_MARKERS="$TMP_DIR/adopt-markers"
init_adoption_repo "$ADOPT_MARKERS"
printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_MARKERS/package.json"
cat >"$ADOPT_MARKERS/AGENTS.md" <<'EOF'
<!-- touchstone:steering:end -->
PROJECT PROSE MUST SURVIVE
<!-- touchstone:steering:start -->
EOF
commit_adoption_repo "$ADOPT_MARKERS" "fixture"
git -C "$ADOPT_MARKERS" switch -q -c feat/adopt
run_adoption "$TMP_DIR/adopt-markers.out" adopt --dry-run --project "$ADOPT_MARKERS"
[ "$ADOPTION_STATUS" -eq 4 ] || fail "out-of-order steering markers did not refuse"
assert_contains "$TMP_DIR/adopt-markers.out.err" "markers are out of order"
assert_contains "$ADOPT_MARKERS/AGENTS.md" "PROJECT PROSE MUST SURVIVE"

echo "validation engine tests passed"
