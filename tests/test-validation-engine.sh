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

echo "==> legacy adoption preserves defaults, targets, and auto typecheck"
LEGACY_COMPILER="$TMP_DIR/legacy-compiler"
mkdir -p "$LEGACY_COMPILER/packages/api" "$LEGACY_COMPILER/packages/web"
(
  PROJECT_ROOT="$(cd "$LEGACY_COMPILER" && pwd -P)"
  TARGETS_FILE="$TMP_DIR/legacy-targets"
  TASKS_FILE="$TMP_DIR/legacy-tasks"
  SETUPS_FILE="$TMP_DIR/legacy-setups"
  TAB="$(printf '\t')"
  CR="$(printf '\r')"
  LF="$(printf '\nX')"
  LF="${LF%X}"
  export TAB CR LF
  : >"$TARGETS_FILE"
  : >"$TASKS_FILE"
  : >"$SETUPS_FILE"
  trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
  }
  valid_identifier() { case "$1" in "" | *[!A-Za-z0-9._-]*) return 1 ;; esac }
  valid_relative_path() { case "$1" in /* | ../* | */../* | */..) return 1 ;; *) return 0 ;; esac }
  contract_refusal() {
    printf 'refused: %s\n' "$*" >&2
    exit 2
  }
  detect_profile() { case "$1" in *api) printf 'python\n' ;; *) printf 'node\n' ;; esac }
  tasks_for_node() {
    record_task "lint$3" "$2" "node-lint"
    record_task "typecheck$3" "$2" "node-typecheck"
    record_task "test$3" "$2" "node-test"
    record_task "build$3" "$2" "node-build"
  }
  tasks_for_python() {
    record_task "lint$3" "$2" "python-lint"
    record_task "typecheck$3" "$2" "python -m mypy ."
    record_task "test$3" "$2" "python-test"
  }
  # shellcheck source=scripts/lib/touchstone-adopt-compiler.sh
  source "$ROOT/scripts/lib/touchstone-adopt-compiler.sh"

  printf '%s\n' 'project_type=node' 'test_command=custom-test' >"$PROJECT_ROOT/.touchstone-config"
  compile_legacy
  grep -Fq $'lint\troot\ttrue\tnode-lint' "$TASKS_FILE" || exit 11
  grep -Fq $'typecheck\troot\ttrue\tnode-typecheck' "$TASKS_FILE" || exit 12
  grep -Fq $'build\troot\ttrue\tnode-build' "$TASKS_FILE" || exit 13
  grep -Fq $'test\troot\ttrue\tcustom-test' "$TASKS_FILE" || exit 14
  ! grep -Fq $'test\troot\ttrue\tnode-test' "$TASKS_FILE" || exit 15

  : >"$TARGETS_FILE"
  : >"$TASKS_FILE"
  printf '%s\n' 'targets=api:packages/api:python,web:packages/web:node' >"$PROJECT_ROOT/.touchstone-config"
  compile_legacy
  grep -Fq $'api\tpackages/api\tpython' "$TARGETS_FILE" || exit 16
  grep -Fq $'web\tpackages/web\tnode' "$TARGETS_FILE" || exit 17
  grep -Fq $'typecheck-api\tapi\ttrue\tpython -m mypy .' "$TASKS_FILE" || exit 18
  grep -Fq $'test-web\tweb\ttrue\tnode-test' "$TASKS_FILE" || exit 19

  : >"$TARGETS_FILE"
  : >"$TASKS_FILE"
  printf '%s\n' 'project_type=python' 'typecheck_command=auto' >"$PROJECT_ROOT/.touchstone-config"
  compile_legacy
  grep -Fq $'typecheck\troot\ttrue\tpython -m mypy .' "$TASKS_FILE" || exit 20
  ! grep -Fq $'\tauto' "$TASKS_FILE" || exit 21

  : >"$TARGETS_FILE"
  : >"$TASKS_FILE"
  printf '%s\n' 'targets=root:packages/api:python' 'test_command=custom-test' >"$PROJECT_ROOT/.touchstone-config"
  set +e
  (compile_legacy) >/dev/null 2>&1
  collision_status=$?
  set -e
  [ "$collision_status" -eq 2 ] || exit 22
) || fail "legacy adoption compiler changed validation coverage"

echo "==> adoption planner handles fresh, repeat, and upgrade consumers"
(
  SCRIPT_ROOT="$ROOT"
  PROJECT_ROOT="$TMP_DIR/planner-consumer"
  TOUCHSTONE_BLOCK_BEGIN='<!-- touchstone:steering:start -->'
  TOUCHSTONE_BLOCK_END='<!-- touchstone:steering:end -->'
  CR="$(printf '\r')"
  export SCRIPT_ROOT TOUCHSTONE_BLOCK_BEGIN TOUCHSTONE_BLOCK_END CR
  mkdir -p "$PROJECT_ROOT"
  valid_relative_path() { case "$1" in /* | ../* | */../* | */..) return 1 ;; *) return 0 ;; esac }
  contract_refusal() {
    printf 'refused: %s\n' "$*" >&2
    exit 2
  }
  operational_failure() {
    printf 'operational failure: %s\n' "$*" >&2
    exit 6
  }
  reset_planner_stage() {
    PLAN_ROOT="$TMP_DIR/planner-$1"
    OLD_ROOT="$PLAN_ROOT/old"
    NEW_ROOT="$PLAN_ROOT/new"
    CHANGES_FILE="$PLAN_ROOT/changes"
    DIFF_FILE="$PLAN_ROOT/diff"
    export PLAN_ROOT OLD_ROOT NEW_ROOT CHANGES_FILE DIFF_FILE
    mkdir -p "$OLD_ROOT" "$NEW_ROOT"
    : >"$CHANGES_FILE"
  }
  # shellcheck source=scripts/lib/touchstone-adopt-planner.sh
  source "$ROOT/scripts/lib/touchstone-adopt-planner.sh"

  reset_planner_stage fresh
  plan_steering true
  grep -Fq $'create\t.touchstone/TOUCHSTONE.md\ttouchstone-managed' "$CHANGES_FILE" || exit 51
  grep -Fq $'create\tAGENTS.md\tmarked-block' "$CHANGES_FILE" || exit 52
  if grep -R -Eq 'bash scripts/(claim-issue|respond-review)\.sh' "$NEW_ROOT"; then exit 53; fi
  while IFS=$'\t' read -r _action path _ownership; do
    mkdir -p "$PROJECT_ROOT/$(dirname "$path")"
    cp "$NEW_ROOT/$path" "$PROJECT_ROOT/$path"
  done <"$CHANGES_FILE"

  reset_planner_stage repeat
  plan_steering false
  [ ! -s "$CHANGES_FILE" ] || exit 54

  printf 'stale steering\n' >"$PROJECT_ROOT/.touchstone/TOUCHSTONE.md"
  reset_planner_stage upgrade
  plan_steering true
  grep -Fq $'update\t.touchstone/TOUCHSTONE.md\ttouchstone-managed' "$CHANGES_FILE" || exit 55

  PROJECT_ROOT="$TMP_DIR/planner-blocked-ancestor"
  mkdir -p "$PROJECT_ROOT"
  printf 'not a directory\n' >"$PROJECT_ROOT/.touchstone"
  set +e
  (reset_planner_stage blocked && plan_steering true) >/dev/null 2>&1
  blocked_status=$?
  set -e
  [ "$blocked_status" -eq 2 ] || exit 56
) || fail "adoption planner changed fresh, repeat, or upgrade semantics"

echo "==> repeat adoption validates declarations without executing tasks"
PLANNER_DECLARED="$TMP_DIR/planner-declared"
mkdir -p "$PLANNER_DECLARED"
cat >"$PLANNER_DECLARED/.touchstone.toml" <<'EOF'
schema = 1
[validation]
runtime = "bash"
[[validation.targets]]
name = "root"
path = "."
[[validation.tasks]]
name = "must-not-run"
target = "root"
command = "printf ran > should-not-exist"
required = true
EOF
bash "$RUNNER" validate --check-contract --json --project "$PLANNER_DECLARED" >"$TMP_DIR/planner-contract.json"
assert_contains "$TMP_DIR/planner-contract.json" '"verdict":"valid"'
[ ! -e "$PLANNER_DECLARED/should-not-exist" ] || fail "contract-only validation executed a task"

echo "==> adoption transaction writes atomically and preserves failed-restore backups"
TRANSACTION_MODULE="$ROOT/scripts/lib/touchstone-adopt-transaction.sh"
run_transaction_case() (
  local case_name="$1" failure_mode="$2"
  PROJECT_ROOT="$TMP_DIR/transaction-$case_name"
  NEW_ROOT="$TMP_DIR/transaction-$case_name-new"
  OLD_ROOT="$TMP_DIR/transaction-$case_name-old"
  CHANGES_FILE="$TMP_DIR/transaction-$case_name-changes"
  APPLY_STAGE_FILE="$TMP_DIR/transaction-$case_name-stage"
  APPLY_APPLIED_FILE="$TMP_DIR/transaction-$case_name-applied"
  APPLY_DIRECTORIES_FILE="$TMP_DIR/transaction-$case_name-directories"
  LF="$(printf '\nX')"
  LF="${LF%X}"
  APPLY_ACTIVE=false
  export APPLY_STAGE_FILE APPLY_APPLIED_FILE APPLY_DIRECTORIES_FILE APPLY_ACTIVE
  mkdir -p "$PROJECT_ROOT" "$NEW_ROOT/nested" "$OLD_ROOT"
  git -C "$PROJECT_ROOT" init -q
  git -C "$PROJECT_ROOT" config user.name test
  git -C "$PROJECT_ROOT" config user.email test@example.com
  printf 'old\n' >"$PROJECT_ROOT/existing.txt"
  printf 'old second\n' >"$PROJECT_ROOT/second.txt"
  git -C "$PROJECT_ROOT" add existing.txt second.txt
  git -C "$PROJECT_ROOT" commit -qm initial
  git -C "$PROJECT_ROOT" branch -M main
  git -C "$PROJECT_ROOT" update-ref refs/remotes/origin/main HEAD
  git -C "$PROJECT_ROOT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$PROJECT_ROOT" switch -qc feat/transaction
  printf 'new\n' >"$NEW_ROOT/existing.txt"
  printf 'new second\n' >"$NEW_ROOT/second.txt"
  printf 'created\n' >"$NEW_ROOT/nested/created.txt"
  printf 'old\n' >"$OLD_ROOT/existing.txt"
  printf 'old second\n' >"$OLD_ROOT/second.txt"
  printf 'update\texisting.txt\ttouchstone\nupdate\tsecond.txt\ttouchstone\ncreate\tnested/created.txt\ttouchstone\n' >"$CHANGES_FILE"
  safe_owned_path() { return 0; }
  safety_refusal() {
    printf 'safety refusal: %s\n' "$*" >&2
    exit 5
  }
  operational_failure() {
    printf 'operational failure: %s\n' "$*" >&2
    exit 6
  }
  # shellcheck source=scripts/lib/touchstone-adopt-transaction.sh
  source "$TRANSACTION_MODULE"
  case "$failure_mode" in
    write)
      write_moves=0
      mv() {
        case "$1" in
          *.touchstone-write.*)
            write_moves=$((write_moves + 1))
            [ "$write_moves" -ne 2 ] || return 1
            ;;
        esac
        command mv "$@"
      }
      ;;
    backup)
      backup_removals=0
      rm() {
        case "${2:-$1}" in
          *.touchstone-backup.*)
            backup_removals=$((backup_removals + 1))
            [ "$backup_removals" -ne 2 ] || return 1
            ;;
        esac
        command rm "$@"
      }
      ;;
  esac
  if [ "$failure_mode" != none ]; then
    set +e
    (apply_plan) >/dev/null 2>&1
    apply_status=$?
    set -e
    [ "$apply_status" -eq 6 ] || exit 31
    [ "$(cat "$PROJECT_ROOT/existing.txt")" = old ] || exit 32
    [ "$(cat "$PROJECT_ROOT/second.txt")" = "old second" ] || exit 33
    [ ! -e "$PROJECT_ROOT/nested/created.txt" ] || exit 33
    [ ! -d "$PROJECT_ROOT/nested" ] || exit 34
  else
    apply_plan
    [ "$(cat "$PROJECT_ROOT/existing.txt")" = new ] || exit 35
    [ "$(cat "$PROJECT_ROOT/second.txt")" = "new second" ] || exit 36
    [ "$(cat "$PROJECT_ROOT/nested/created.txt")" = created ] || exit 36
  fi
)
run_transaction_case success none || fail "successful adoption transaction did not write the plan"
run_transaction_case write-rollback write || fail "failed adoption write did not restore files and directories"
run_transaction_case backup-rollback backup || fail "failed backup preparation did not roll back earlier writes"

(
  destination="$TMP_DIR/failed-restore-destination"
  backup="$TMP_DIR/.touchstone-backup.failed-restore"
  applied="$TMP_DIR/failed-restore-applied"
  stage="$TMP_DIR/failed-restore-stage"
  directories="$TMP_DIR/failed-restore-directories"
  printf 'new\n' >"$destination"
  printf 'old\n' >"$backup"
  printf 'update\t%s\t%s\n' "$destination" "$backup" >"$applied"
  : >"$stage"
  : >"$directories"
  mv() {
    [ "$1" != "$backup" ] || return 1
    command mv "$@"
  }
  # shellcheck source=scripts/lib/touchstone-adopt-transaction.sh
  source "$TRANSACTION_MODULE"
  if rollback_apply "$applied" "$stage" "$directories"; then
    exit 41
  fi
  [ "$(cat "$backup")" = old ] || exit 42
  grep -Fq "$backup" "$applied" || exit 43
) || fail "rollback cleanup destroyed the only recoverable original"

echo "validation engine tests passed"
