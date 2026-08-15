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

echo "==> adoption core compiles manual tasks and refuses unavailable adapters"
ADOPT_MANUAL="$TMP_DIR/adopt-manual"
mkdir -p "$ADOPT_MANUAL"
git -C "$ADOPT_MANUAL" init -q
git -C "$ADOPT_MANUAL" config user.name fixture
git -C "$ADOPT_MANUAL" config user.email fixture@example.com
printf '%s\n' '# fixture' >"$ADOPT_MANUAL/README.md"
git -C "$ADOPT_MANUAL" add README.md
git -C "$ADOPT_MANUAL" commit -qm fixture
git -C "$ADOPT_MANUAL" update-ref refs/remotes/origin/main HEAD
git -C "$ADOPT_MANUAL" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$ADOPT_MANUAL" switch -q -c feat/adopt

bash "$ROOT/bin/touchstone" adopt --dry-run --json --project "$ADOPT_MANUAL" \
  --task 'verify=bash scripts/check.sh --all' >"$TMP_DIR/adopt-manual-plan.json"
assert_contains "$TMP_DIR/adopt-manual-plan.json" '"profile":"manual"'
assert_contains "$TMP_DIR/adopt-manual-plan.json" '"path":".touchstone.toml","action":"create"'
assert_contains "$TMP_DIR/adopt-manual-plan.json" \
  'command = \"bash scripts/check.sh --all\"'
[ ! -e "$ADOPT_MANUAL/.touchstone.toml" ] || fail "adoption dry-run mutated the project"

GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=color.ui GIT_CONFIG_VALUE_0=always \
  GIT_CONFIG_KEY_1=diff.context GIT_CONFIG_VALUE_1=0 \
  bash "$ROOT/bin/touchstone" adopt --dry-run --json --project "$ADOPT_MANUAL" \
  --task 'verify=bash scripts/check.sh --all' >"$TMP_DIR/adopt-manual-color.json"
assert_not_contains "$TMP_DIR/adopt-manual-color.json" $'\033'
cmp -s "$TMP_DIR/adopt-manual-plan.json" "$TMP_DIR/adopt-manual-color.json" \
  || fail "Git diff configuration changed the versioned adoption plan"

bash "$ROOT/bin/touchstone" adopt --project "$ADOPT_MANUAL" \
  --task 'verify=bash scripts/check.sh --all' >"$TMP_DIR/adopt-manual-apply.out"
assert_contains "$ADOPT_MANUAL/.touchstone.toml" \
  'command = "bash scripts/check.sh --all"'
assert_contains "$ADOPT_MANUAL/AGENTS.md" '<!-- touchstone:steering:start -->'
bash "$ROOT/bin/touchstone" adopt --project "$ADOPT_MANUAL" \
  >"$TMP_DIR/adopt-manual-repeat.out"
assert_contains "$TMP_DIR/adopt-manual-repeat.out" 'adopt: current; no files changed'

printf '%s\n' '{"scripts":{"test":"node --test"}}' >"$ADOPT_MANUAL/package.json"
bash "$ROOT/bin/touchstone" adopt --dry-run --project "$ADOPT_MANUAL" \
  >"$TMP_DIR/adopt-manual-unread-manifest.out"
assert_contains "$TMP_DIR/adopt-manual-unread-manifest.out" 'adopt: 0 file change(s) proposed'

printf '%s\n' '# Preserved steering' 'OLD COMPATIBLE STEERING' \
  >"$ADOPT_MANUAL/.touchstone/TOUCHSTONE.md"
rm "$ADOPT_MANUAL/AGENTS.md"
bash "$ROOT/bin/touchstone" adopt --dry-run --json --project "$ADOPT_MANUAL" \
  >"$TMP_DIR/adopt-manual-preserved.json"
assert_contains "$TMP_DIR/adopt-manual-preserved.json" 'OLD COMPATIBLE STEERING'
assert_not_contains "$TMP_DIR/adopt-manual-preserved.json" \
  'Humans approve plans. Agents write and ship code. GitHub reviews code.'

ADOPT_IGNORED_OUTPUT="$TMP_DIR/adopt-ignored-output"
mkdir -p "$ADOPT_IGNORED_OUTPUT"
git -C "$ADOPT_IGNORED_OUTPUT" init -q
git -C "$ADOPT_IGNORED_OUTPUT" config user.name fixture
git -C "$ADOPT_IGNORED_OUTPUT" config user.email fixture@example.com
printf '%s\n' '.touchstone.toml' >"$ADOPT_IGNORED_OUTPUT/.gitignore"
git -C "$ADOPT_IGNORED_OUTPUT" add .gitignore
git -C "$ADOPT_IGNORED_OUTPUT" commit -qm fixture
write_contract "$ADOPT_IGNORED_OUTPUT" true
git -C "$ADOPT_IGNORED_OUTPUT" switch -q -c feat/adopt
set +e
bash "$ROOT/bin/touchstone" adopt --dry-run --project "$ADOPT_IGNORED_OUTPUT" \
  >"$TMP_DIR/adopt-ignored-output.out" 2>"$TMP_DIR/adopt-ignored-output.err"
ADOPTION_STATUS=$?
set -e
[ "$ADOPTION_STATUS" -eq 4 ] || fail "ignored adoption output was accepted"
assert_contains "$TMP_DIR/adopt-ignored-output.err" \
  "compiler input '.touchstone.toml' is not tracked"

ADOPT_SYMLINKED_OUTPUT="$TMP_DIR/adopt-symlinked-output"
ADOPT_SYMLINKED_OUTSIDE="$TMP_DIR/adopt-symlinked-outside"
mkdir -p "$ADOPT_SYMLINKED_OUTPUT" "$ADOPT_SYMLINKED_OUTSIDE"
git -C "$ADOPT_SYMLINKED_OUTPUT" init -q
git -C "$ADOPT_SYMLINKED_OUTPUT" config user.name fixture
git -C "$ADOPT_SYMLINKED_OUTPUT" config user.email fixture@example.com
printf '%s\n' '# fixture' >"$ADOPT_SYMLINKED_OUTPUT/README.md"
ln -s "$ADOPT_SYMLINKED_OUTSIDE" "$ADOPT_SYMLINKED_OUTPUT/.touchstone"
git -C "$ADOPT_SYMLINKED_OUTPUT" add README.md .touchstone
git -C "$ADOPT_SYMLINKED_OUTPUT" commit -qm fixture
git -C "$ADOPT_SYMLINKED_OUTPUT" update-ref refs/remotes/origin/main HEAD
git -C "$ADOPT_SYMLINKED_OUTPUT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$ADOPT_SYMLINKED_OUTPUT" switch -q -c feat/adopt
set +e
bash "$ROOT/bin/touchstone" adopt --dry-run --project "$ADOPT_SYMLINKED_OUTPUT" \
  --task 'verify=true' >"$TMP_DIR/adopt-symlinked-output.out" \
  2>"$TMP_DIR/adopt-symlinked-output.err"
ADOPTION_STATUS=$?
set -e
[ "$ADOPTION_STATUS" -eq 4 ] || fail "symlinked adoption output ancestor did not refuse"
assert_contains "$TMP_DIR/adopt-symlinked-output.err" \
  'managed path traverses a symlink: .touchstone'

echo "==> Node adapter derives scripts and rejects project-controlled execution"
init_node_adoption_repo() {
  local directory="$1"
  mkdir -p "$directory"
  git -C "$directory" init -q
  git -C "$directory" config user.name fixture
  git -C "$directory" config user.email fixture@example.com
}

commit_node_adoption_repo() {
  local directory="$1"
  git -C "$directory" add -A
  git -C "$directory" commit -qm fixture
  git -C "$directory" switch -q -c feat/adopt
}

ADOPT_NODE="$TMP_DIR/adopt-node"
init_node_adoption_repo "$ADOPT_NODE"
printf '%s\n' \
  '{"name":"fixture","version":"1.0.0","scripts":{"lint":"eslint .","test":"node --test","postinstall":"curl https://example.invalid"}}' \
  >"$ADOPT_NODE/package.json"
printf '%s\n' \
  '{"name":"fixture","version":"1.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"fixture","version":"1.0.0"}}}' \
  >"$ADOPT_NODE/package-lock.json"
commit_node_adoption_repo "$ADOPT_NODE"
bash "$ROOT/bin/touchstone" adopt --dry-run --json --project "$ADOPT_NODE" \
  >"$TMP_DIR/adopt-node-plan.json"
assert_contains "$TMP_DIR/adopt-node-plan.json" '"profile":"node"'
assert_contains "$TMP_DIR/adopt-node-plan.json" 'command = \"npm run lint\"'
assert_contains "$TMP_DIR/adopt-node-plan.json" 'command = \"npm run test\"'
assert_contains "$TMP_DIR/adopt-node-plan.json" \
  'setup = \"npm ci --offline --ignore-scripts\"'
assert_not_contains "$TMP_DIR/adopt-node-plan.json" 'postinstall'

ADOPT_PNPM_GENERATED="$TMP_DIR/adopt-pnpm-generated"
init_node_adoption_repo "$ADOPT_PNPM_GENERATED"
printf '%s\n' '{"packageManager":"pnpm@10.28.1","scripts":{"test":"node --test"}}' \
  >"$ADOPT_PNPM_GENERATED/package.json"
printf '%s\n' "lockfileVersion: '9.0'" 'settings:' \
  '  autoInstallPeers: true' '  excludeLinksFromLockfile: false' \
  'importers:' '  .: {}' >"$ADOPT_PNPM_GENERATED/pnpm-lock.yaml"
commit_node_adoption_repo "$ADOPT_PNPM_GENERATED"
bash "$ROOT/bin/touchstone" adopt --dry-run --json --project "$ADOPT_PNPM_GENERATED" \
  >"$TMP_DIR/adopt-pnpm-generated.json"
assert_contains "$TMP_DIR/adopt-pnpm-generated.json" \
  'setup = \"COREPACK_ENABLE_NETWORK=0 pnpm install --offline --frozen-lockfile --ignore-scripts --ignore-pnpmfile\"'

ADOPT_YARN_GENERATED="$TMP_DIR/adopt-yarn-generated"
init_node_adoption_repo "$ADOPT_YARN_GENERATED"
printf '%s\n' '{"name":"fixture","packageManager":"yarn@4.14.1","scripts":{"test":"node --test"}}' \
  >"$ADOPT_YARN_GENERATED/package.json"
printf '%s\n' '__metadata:' '  version: 8' '  cacheKey: 10c0' \
  '"fixture@workspace:.":' '  version: 0.0.0-use.local' \
  '  resolution: "fixture@workspace:."' '  languageName: unknown' \
  '  linkType: soft' >"$ADOPT_YARN_GENERATED/yarn.lock"
commit_node_adoption_repo "$ADOPT_YARN_GENERATED"
bash "$ROOT/bin/touchstone" adopt --dry-run --json --project "$ADOPT_YARN_GENERATED" \
  >"$TMP_DIR/adopt-yarn-generated.json"
assert_contains "$TMP_DIR/adopt-yarn-generated.json" \
  'setup = \"COREPACK_ENABLE_NETWORK=0 yarn install --immutable --immutable-cache --mode=skip-build\"'

ADOPT_SCOPED_MANAGER="$TMP_DIR/adopt-scoped-manager"
init_node_adoption_repo "$ADOPT_SCOPED_MANAGER"
printf '%s\n' '{"packageManager":"@evil/pm@1.0.0","scripts":{"test":"node --test"}}' \
  >"$ADOPT_SCOPED_MANAGER/package.json"
commit_node_adoption_repo "$ADOPT_SCOPED_MANAGER"
set +e
bash "$ROOT/bin/touchstone" adopt --dry-run --project "$ADOPT_SCOPED_MANAGER" \
  >"$TMP_DIR/adopt-scoped-manager.out" 2>"$TMP_DIR/adopt-scoped-manager.err"
ADOPTION_STATUS=$?
set -e
[ "$ADOPTION_STATUS" -eq 4 ] || fail "scoped packageManager declaration was accepted"
assert_contains "$TMP_DIR/adopt-scoped-manager.err" "unsupported Node packageManager '@evil/pm'"

ADOPT_DEV_ENGINES="$TMP_DIR/adopt-dev-engines"
init_node_adoption_repo "$ADOPT_DEV_ENGINES"
printf '%s\n' \
  '{"devEngines":{"packageManager":{"name":"pnpm","version":"10.28.1","onFail":"error"}},"scripts":{"test":"node --test"}}' \
  >"$ADOPT_DEV_ENGINES/package.json"
commit_node_adoption_repo "$ADOPT_DEV_ENGINES"
set +e
bash "$ROOT/bin/touchstone" adopt --dry-run --project "$ADOPT_DEV_ENGINES" \
  >"$TMP_DIR/adopt-dev-engines.out" 2>"$TMP_DIR/adopt-dev-engines.err"
ADOPTION_STATUS=$?
set -e
[ "$ADOPTION_STATUS" -eq 4 ] || fail "devEngines package-manager policy was ignored"
assert_contains "$TMP_DIR/adopt-dev-engines.err" 'declares devEngines runtime policy'

for node_config in npmrc pnpmfile pnpmfile-unlocked; do
  ADOPT_NODE_CONFIG="$TMP_DIR/adopt-node-config-$node_config"
  init_node_adoption_repo "$ADOPT_NODE_CONFIG"
  if [ "$node_config" = npmrc ]; then
    printf '%s\n' '{"scripts":{"test":"node --test"}}' \
      >"$ADOPT_NODE_CONFIG/package.json"
    printf '%s\n' 'script-shell=./custom-shell.sh' >"$ADOPT_NODE_CONFIG/.npmrc"
  else
    printf '%s\n' '{"packageManager":"pnpm@10.0.0","scripts":{"test":"node --test"}}' \
      >"$ADOPT_NODE_CONFIG/package.json"
    printf '%s\n' 'module.exports = { hooks: {} }' >"$ADOPT_NODE_CONFIG/.pnpmfile.cjs"
    if [ "$node_config" = pnpmfile ]; then
      printf '%s\n' "lockfileVersion: '9.0'" >"$ADOPT_NODE_CONFIG/pnpm-lock.yaml"
    fi
  fi
  commit_node_adoption_repo "$ADOPT_NODE_CONFIG"
  set +e
  bash "$ROOT/bin/touchstone" adopt --dry-run --project "$ADOPT_NODE_CONFIG" \
    >"$TMP_DIR/adopt-node-config-$node_config.out" \
    2>"$TMP_DIR/adopt-node-config-$node_config.err"
  ADOPTION_STATUS=$?
  set -e
  [ "$ADOPTION_STATUS" -eq 4 ] || fail "$node_config execution config was accepted"
done
assert_contains "$TMP_DIR/adopt-node-config-npmrc.err" 'project-controlled config'
assert_contains "$TMP_DIR/adopt-node-config-pnpmfile.err" \
  'project-controlled pnpm hook or config'
assert_contains "$TMP_DIR/adopt-node-config-pnpmfile-unlocked.err" \
  'project-controlled pnpm hook or config'

ADOPT_NPM_PRECEDENCE="$TMP_DIR/adopt-npm-precedence"
init_node_adoption_repo "$ADOPT_NPM_PRECEDENCE"
printf '%s\n' '{"scripts":{"test":"node --test"}}' \
  >"$ADOPT_NPM_PRECEDENCE/package.json"
printf '%s\n' '{"lockfileVersion":3,"requires":true,"packages":{"":{}}}' \
  >"$ADOPT_NPM_PRECEDENCE/package-lock.json"
printf '%s\n' '{"lockfileVersion":3,"requires":true,"packages":{"":{"dependencies":{"evil":"1.0.0"}}}}' \
  >"$ADOPT_NPM_PRECEDENCE/npm-shrinkwrap.json"
commit_node_adoption_repo "$ADOPT_NPM_PRECEDENCE"
set +e
bash "$ROOT/bin/touchstone" adopt --dry-run --project "$ADOPT_NPM_PRECEDENCE" \
  >"$TMP_DIR/adopt-npm-precedence.out" 2>"$TMP_DIR/adopt-npm-precedence.err"
ADOPTION_STATUS=$?
set -e
[ "$ADOPTION_STATUS" -eq 4 ] || fail "package lock hid the effective npm shrinkwrap"
assert_contains "$TMP_DIR/adopt-npm-precedence.err" \
  'npm lockfile outside the dependency-free portable subset'

ADOPT_YARN_STANDALONE="$TMP_DIR/adopt-yarn-standalone"
init_node_adoption_repo "$ADOPT_YARN_STANDALONE"
mkdir -p "$ADOPT_YARN_STANDALONE/apps/api"
printf '%s\n' \
  '{"name":"fixture","packageManager":"yarn@4.14.1","workspaces":["packages/*"]}' \
  >"$ADOPT_YARN_STANDALONE/package.json"
printf '%s\n' '__metadata:' '  version: 8' '  cacheKey: 10c0' \
  '"fixture@workspace:.":' '  version: 0.0.0-use.local' \
  '  resolution: "fixture@workspace:."' '  languageName: unknown' \
  '  linkType: soft' \
  >"$ADOPT_YARN_STANDALONE/yarn.lock"
printf '%s\n' '{"scripts":{"test":"node --test"}}' \
  >"$ADOPT_YARN_STANDALONE/apps/api/package.json"
commit_node_adoption_repo "$ADOPT_YARN_STANDALONE"
bash "$ROOT/bin/touchstone" adopt --dry-run --json --project "$ADOPT_YARN_STANDALONE" \
  >"$TMP_DIR/adopt-yarn-standalone.json"
assert_contains "$TMP_DIR/adopt-yarn-standalone.json" \
  'command = \"npm run test\"'
assert_not_contains "$TMP_DIR/adopt-yarn-standalone.json" \
  'command = \"COREPACK_ENABLE_NETWORK=0 yarn test\"'

echo "==> Python adapter binds tasks to tracked executable evidence"
PYTHON_TOOL_BIN="$TMP_DIR/python-tools"
mkdir -p "$PYTHON_TOOL_BIN"
cat >"$PYTHON_TOOL_BIN/uv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$*" = "--version" ]; then
  printf '%s\n' 'uv 0.8.14'
  exit 0
fi
[ "$*" = "lock --check --offline --no-config" ] || exit 8
[ "${UV_NO_PROGRESS:-}" = 1 ] || exit 8
[ "${UV_PYTHON_DOWNLOADS:-}" = never ] || exit 8
EOF
chmod +x "$PYTHON_TOOL_BIN/uv"
PATH="$PYTHON_TOOL_BIN:$PATH"
export PATH
ADOPT_PYTHON="$TMP_DIR/adopt-python"
init_node_adoption_repo "$ADOPT_PYTHON"
mkdir -p "$ADOPT_PYTHON/tests"
printf '%s\n' '[project]' 'name = "fixture"' 'version = "0.1.0"' \
  'requires-python = ">=3.11"' 'dependencies = ["pytest"]' \
  >"$ADOPT_PYTHON/pyproject.toml"
printf '%s\n' 'version = 1' 'revision = 3' 'requires-python = ">=3.11"' '' \
  '[[package]]' 'name = "fixture"' 'version = "0.1.0"' \
  'source = { virtual = "." }' '' '[[package]]' 'name = "pytest"' \
  'version = "9.0.0"' 'source = { registry = "https://pypi.org/simple" }' \
  >"$ADOPT_PYTHON/uv.lock"
printf '%s\n' 'def test_passes():' '    assert True' >"$ADOPT_PYTHON/tests/test_fixture.py"
commit_node_adoption_repo "$ADOPT_PYTHON"
bash "$ROOT/bin/touchstone" adopt --dry-run --json --project "$ADOPT_PYTHON" \
  >"$TMP_DIR/adopt-python-plan.json"
assert_contains "$TMP_DIR/adopt-python-plan.json" '"profile":"python"'
assert_contains "$TMP_DIR/adopt-python-plan.json" \
  'uv 0.8.14'
assert_contains "$TMP_DIR/adopt-python-plan.json" 'uv sync --no-config --offline --frozen'
assert_contains "$TMP_DIR/adopt-python-plan.json" 'uv run --no-sync --no-config pytest'

for python_evidence in ignored-test missing-source malformed-toml; do
  ADOPT_PYTHON_EVIDENCE="$TMP_DIR/adopt-python-$python_evidence"
  init_node_adoption_repo "$ADOPT_PYTHON_EVIDENCE"
  case "$python_evidence" in
    ignored-test)
      mkdir -p "$ADOPT_PYTHON_EVIDENCE/.venv"
      printf '%s\n' '[project]' 'name = "fixture"' 'requires-python = ">=3.11"' \
        'dependencies = ["pytest"]' >"$ADOPT_PYTHON_EVIDENCE/pyproject.toml"
      printf '%s\n' 'version = 1' 'revision = 3' 'requires-python = ">=3.11"' '' \
        '[[package]]' 'name = "fixture"' 'version = "0.1.0"' \
        'source = { virtual = "." }' '' '[[package]]' 'name = "pytest"' \
        'version = "9.0.0"' 'source = { registry = "https://pypi.org/simple" }' \
        >"$ADOPT_PYTHON_EVIDENCE/uv.lock"
      printf '%s\n' 'def test_hidden():' '    assert True' \
        >"$ADOPT_PYTHON_EVIDENCE/.venv/test_hidden.py"
      ;;
    missing-source)
      printf '%s\n' '[project]' 'name = "fixture"' 'requires-python = ">=3.11"' \
        'dependencies = ["mypy"]' >"$ADOPT_PYTHON_EVIDENCE/pyproject.toml"
      printf '%s\n' 'version = 1' 'revision = 3' 'requires-python = ">=3.11"' '' \
        '[[package]]' 'name = "fixture"' 'version = "0.1.0"' \
        'source = { virtual = "." }' '' '[[package]]' 'name = "mypy"' \
        'version = "1.20.2"' 'source = { registry = "https://pypi.org/simple" }' \
        >"$ADOPT_PYTHON_EVIDENCE/uv.lock"
      ;;
    malformed-toml)
      printf '%s\n' '[project' 'name = "broken"' >"$ADOPT_PYTHON_EVIDENCE/pyproject.toml"
      ;;
  esac
  commit_node_adoption_repo "$ADOPT_PYTHON_EVIDENCE"
  set +e
  bash "$ROOT/bin/touchstone" adopt --dry-run --project "$ADOPT_PYTHON_EVIDENCE" \
    >"$TMP_DIR/adopt-python-$python_evidence.out" \
    2>"$TMP_DIR/adopt-python-$python_evidence.err"
  ADOPTION_STATUS=$?
  set -e
  [ "$ADOPTION_STATUS" -eq 4 ] || fail "$python_evidence produced an unsafe Python task"
done
assert_contains "$TMP_DIR/adopt-python-ignored-test.err" \
  'no declared ruff, mypy, or pytest evidence'
assert_contains "$TMP_DIR/adopt-python-missing-source.err" \
  'mypy evidence but no tracked regular Python source'
assert_contains "$TMP_DIR/adopt-python-malformed-toml.err" 'pyproject.toml is malformed'

for python_boundary in vcs-url poetry-python poetry-platform spaced-build-hook extras-before-url invalid-requirement uv-source requirements-without-lock; do
  ADOPT_PYTHON_BOUNDARY="$TMP_DIR/adopt-python-$python_boundary"
  init_node_adoption_repo "$ADOPT_PYTHON_BOUNDARY"
  case "$python_boundary" in
    vcs-url)
      printf '%s\n' '[project]' 'name = "fixture"' 'version = "0.1.0"' \
        'dependencies = ["evil @ git+git://example.invalid/repo.git"]' \
        >"$ADOPT_PYTHON_BOUNDARY/pyproject.toml"
      expected_python_boundary='remote direct dependency reference'
      ;;
    poetry-python | poetry-platform)
      marker_key="${python_boundary#poetry-}"
      printf '%s\n' '[tool.poetry]' 'name = "fixture"' 'version = "0.1.0"' \
        '[tool.poetry.dependencies]' \
        "evil = { version = \"^1\", $marker_key = \"blocked\" }" \
        '[build-system]' 'requires = ["poetry-core"]' \
        'build-backend = "poetry.core.masonry.api"' \
        >"$ADOPT_PYTHON_BOUNDARY/pyproject.toml"
      expected_python_boundary='environment-marked dependency'
      ;;
    spaced-build-hook)
      printf '%s\n' '[project]' 'name = "fixture"' 'version = "0.1.0"' \
        'dependencies = ["ruff"]' '[ build-system ]' \
        'requires = ["setuptools"]' 'build-backend = "setuptools.build_meta"' \
        'backend-path = ["."]' >"$ADOPT_PYTHON_BOUNDARY/pyproject.toml"
      expected_python_boundary='project build hook'
      ;;
    extras-before-url)
      printf '%s\n' '[project]' 'name = "fixture"' 'version = "0.1.0"' \
        'dependencies = [' '  "foo[bar]",' \
        '  "evil @ https://example.invalid/package.whl",' ']' \
        >"$ADOPT_PYTHON_BOUNDARY/pyproject.toml"
      expected_python_boundary='remote direct dependency reference'
      ;;
    invalid-requirement)
      printf '%s\n' '[project]' 'name = "fixture"' 'version = "0.1.0"' \
        'dependencies = ["ruff", "not a requirement!"]' \
        >"$ADOPT_PYTHON_BOUNDARY/pyproject.toml"
      expected_python_boundary='outside the supported named-requirement subset'
      ;;
    uv-source)
      printf '%s\n' '[project]' 'name = "fixture"' 'version = "0.1.0"' \
        'requires-python = ">=3.11"' 'dependencies = ["evil"]' \
        '[tool.uv.sources]' 'evil = { path = "../outside" }' \
        >"$ADOPT_PYTHON_BOUNDARY/pyproject.toml"
      printf '%s\n' 'version = 1' 'revision = 3' 'requires-python = ">=3.11"' '' \
        '[[package]]' 'name = "fixture"' 'version = "0.1.0"' \
        'source = { virtual = "." }' '' '[[package]]' 'name = "evil"' \
        'version = "1.0.0"' 'source = { directory = "../outside" }' \
        >"$ADOPT_PYTHON_BOUNDARY/uv.lock"
      expected_python_boundary='declares a uv source mapping'
      ;;
    requirements-without-lock)
      printf '%s\n' 'pytest==0.0.0' >"$ADOPT_PYTHON_BOUNDARY/requirements.txt"
      expected_python_boundary='requires uv.lock and an exact uv runtime'
      ;;
  esac
  commit_node_adoption_repo "$ADOPT_PYTHON_BOUNDARY"
  set +e
  bash "$ROOT/bin/touchstone" adopt --dry-run --project "$ADOPT_PYTHON_BOUNDARY" \
    >"$TMP_DIR/adopt-python-$python_boundary.out" \
    2>"$TMP_DIR/adopt-python-$python_boundary.err"
  ADOPTION_STATUS=$?
  set -e
  [ "$ADOPTION_STATUS" -eq 4 ] || fail "$python_boundary dependency boundary was accepted"
  assert_contains "$TMP_DIR/adopt-python-$python_boundary.err" "$expected_python_boundary"
done

echo "validation engine tests passed"
