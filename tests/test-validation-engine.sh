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

ASSIGNMENT_COMMAND="$TMP_DIR/assignment-command"
write_contract "$ASSIGNMENT_COMMAND" "FIRST=one SECOND=two missing-touchstone-command"
run_capture "$ASSIGNMENT_COMMAND" "$TMP_DIR/assignment-command.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "assignment-prefixed unavailable command did not retain 127"
assert_contains "$TMP_DIR/assignment-command.out" '"ran":0'
assert_contains "$TMP_DIR/assignment-command.out" '"reason":"command-not-started"'

QUOTED_ASSIGNMENT="$TMP_DIR/quoted-assignment"
write_contract "$QUOTED_ASSIGNMENT" "LABEL=\\\"two words\\\" missing-touchstone-command"
run_capture "$QUOTED_ASSIGNMENT" "$TMP_DIR/quoted-assignment.out" --json
[ "$RUN_STATUS" -eq 127 ] || fail "quoted-assignment unavailable command did not retain 127"
assert_contains "$TMP_DIR/quoted-assignment.out" '"ran":0'
assert_contains "$TMP_DIR/quoted-assignment.out" '"reason":"command-not-started"'

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
SETUP_FAIL="$TMP_DIR/setup-fail"
write_contract "$SETUP_FAIL" "printf should-not-run > marker"
awk '{ print; if ($0 == "runtime = \"bash\"") print "setup = \"exit 7\"" }' \
  "$SETUP_FAIL/.touchstone.toml" >"$SETUP_FAIL/with-setup"
mv "$SETUP_FAIL/with-setup" "$SETUP_FAIL/.touchstone.toml"
run_capture "$SETUP_FAIL" "$TMP_DIR/setup-fail.out" --json
[ "$RUN_STATUS" -eq 7 ] || fail "setup failure status was lost"
[ ! -e "$SETUP_FAIL/marker" ] || fail "task ran after setup failure"
assert_contains "$TMP_DIR/setup-fail.out" '"task":"setup"'

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

echo "==> local authoring guard remains installed"
assert_contains "$ROOT/.pre-commit-config.yaml" "id: no-commit-to-branch"
assert_contains "$ROOT/.pre-commit-config.yaml" "stages: [pre-commit]"

echo "validation engine tests passed"
