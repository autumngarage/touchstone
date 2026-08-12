#!/usr/bin/env bash
#
# tests/test-run-script.sh — prototype pinned-shim dispatcher contract.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOUCHSTONE_BIN="$TOUCHSTONE_ROOT/bin/touchstone"
TEST_DIR="$(mktemp -d -t touchstone-test-run-script.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

assert_contains() {
  local file="$1" needle="$2"
  if ! grep -q -- "$needle" "$file" 2>/dev/null; then
    echo "FAIL: expected '$file' to contain '$needle'" >&2
    echo "  ---- file content ----" >&2
    sed 's/^/    /' "$file" >&2 || true
    echo "  ----------------------" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

assert_not_contains() {
  local file="$1" needle="$2"
  if grep -q -- "$needle" "$file" 2>/dev/null; then
    echo "FAIL: expected '$file' to NOT contain '$needle'" >&2
    echo "  ---- file content ----" >&2
    sed 's/^/    /' "$file" >&2 || true
    echo "  ----------------------" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

run_touchstone() {
  HOME="$TEST_DIR/home" \
    NO_COLOR=1 \
    TOUCHSTONE_NO_AUTO_UPDATE=1 \
    bash "$TOUCHSTONE_BIN" "$@"
}

RUNNER="$TOUCHSTONE_ROOT/scripts/touchstone-run.sh"

# Run the task runner inside $1 and record its exit code in RUNNER_EXIT.
RUNNER_EXIT=0
run_runner() {
  local project="$1" out="$2"
  shift 2
  RUNNER_EXIT=0
  (
    cd "$project"
    PATH="$RUNNER_FAKE_BIN:$PATH" bash "$RUNNER" "$@"
  ) >"$out" 2>&1 || RUNNER_EXIT=$?
}

# A project that declares node scripts, with a package manager whose behavior
# the test controls: it fails inside any directory named *-fail or */alpha.
RUNNER_FAKE_BIN="$TEST_DIR/declaration-fake-bin"
mkdir -p "$RUNNER_FAKE_BIN"
cat >"$RUNNER_FAKE_BIN/pnpm" <<'FAKE_PNPM'
#!/usr/bin/env bash
case "$PWD" in
  *-fail | */alpha) exit 3 ;;
esac
exit 0
FAKE_PNPM
chmod +x "$RUNNER_FAKE_BIN/pnpm"

make_node_project() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '{"packageManager":"pnpm@9.0.0","scripts":{"lint":"exit 3"}}\n' >"$dir/package.json"
  printf 'project_type=node\n' >"$dir/.touchstone-config"
}

mkdir -p "$TEST_DIR/home"
PROJECT="$TEST_DIR/project"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q

CURRENT_ID="$(git -C "$TOUCHSTONE_ROOT" rev-parse HEAD)"
CURRENT_VERSION="$(tr -d '[:space:]' <"$TOUCHSTONE_ROOT/VERSION")"
printf '%s\n' "$CURRENT_ID" >"$PROJECT/.touchstone-version"

echo "==> Test: run-script accepts the reviewed current id"

SUCCESS_OUT="$TEST_DIR/success.out"
(cd "$PROJECT" && run_touchstone run-script touchstone-run --project-version "$CURRENT_ID" -- detect) >"$SUCCESS_OUT" 2>&1
assert_contains "$SUCCESS_OUT" '^project_type=generic$'
assert_contains "$SUCCESS_OUT" '^monorepo=false$'

echo "==> Test: run-script accepts the installed VERSION string"

VERSION_OUT="$TEST_DIR/version.out"
(cd "$PROJECT" && run_touchstone run-script touchstone-run --project-version "$CURRENT_VERSION" -- detect) >"$VERSION_OUT" 2>&1
assert_contains "$VERSION_OUT" '^project_type=generic$'

echo "==> Test: run-script accepts an older release-version contract"

OLDER_VERSION="v0.0.0"
OLDER_VERSION_OUT="$TEST_DIR/older-version.out"
(cd "$PROJECT" && run_touchstone run-script touchstone-run --project-version "$OLDER_VERSION" -- detect) >"$OLDER_VERSION_OUT" 2>&1
assert_contains "$OLDER_VERSION_OUT" '^project_type=generic$'

echo "==> Test: run-script rejects a newer release-version contract"

FUTURE_VERSION="$(printf '%s\n' "$CURRENT_VERSION" | awk -F. '{ printf "%d.0.0\n", $1 + 1 }')"
FUTURE_VERSION_OUT="$TEST_DIR/future-version.out"
set +e
(cd "$PROJECT" && run_touchstone run-script touchstone-run --project-version "$FUTURE_VERSION" -- detect) >"$FUTURE_VERSION_OUT" 2>&1
FUTURE_VERSION_EXIT=$?
set -e

if [ "$FUTURE_VERSION_EXIT" -eq 0 ]; then
  echo "FAIL: run-script should reject a newer release-version contract" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$FUTURE_VERSION_OUT" 'installed Touchstone does not satisfy the project script contract'
assert_contains "$FUTURE_VERSION_OUT" "project requires: $FUTURE_VERSION"

echo "==> Test: capability preflight does not pollute delegated stdout"

CAPABILITY_STDOUT="$TEST_DIR/capability.stdout"
CAPABILITY_STDERR="$TEST_DIR/capability.stderr"
(
  cd "$PROJECT"
  run_touchstone run-script touchstone-run \
    --project-version "$CURRENT_ID" \
    --require-capability worktree-lifecycle \
    -- detect
) >"$CAPABILITY_STDOUT" 2>"$CAPABILITY_STDERR"
assert_contains "$CAPABILITY_STDOUT" '^project_type=generic$'
assert_contains "$CAPABILITY_STDOUT" '^monorepo=false$'
if grep -q "Capability 'worktree-lifecycle'" "$CAPABILITY_STDOUT"; then
  echo "FAIL: capability preflight wrote human status to delegated stdout" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$CAPABILITY_STDERR" "Capability 'worktree-lifecycle' is available"

echo "==> Test: --project controls the delegated script working directory"

NODE_PROJECT="$TEST_DIR/node-project"
mkdir -p "$NODE_PROJECT"
git -C "$NODE_PROJECT" init -q
printf '%s\n' "$CURRENT_ID" >"$NODE_PROJECT/.touchstone-version"
printf '{"scripts":{},"packageManager":"pnpm@9.0.0"}\n' >"$NODE_PROJECT/package.json"
PROJECT_CONTEXT_OUT="$TEST_DIR/project-context.out"
(
  cd "$PROJECT"
  run_touchstone run-script touchstone-run --project "$NODE_PROJECT" -- detect
) >"$PROJECT_CONTEXT_OUT" 2>&1
assert_contains "$PROJECT_CONTEXT_OUT" '^project_type=node$'
assert_contains "$PROJECT_CONTEXT_OUT" '^package_manager=pnpm$'

echo "==> Test: configured validate commands do not inherit hook Git env"

VALIDATE_PROJECT="$TEST_DIR/validate-project"
mkdir -p "$VALIDATE_PROJECT"
git -C "$VALIDATE_PROJECT" init -q
cat >"$VALIDATE_PROJECT/.touchstone-config" <<EOF_CONFIG
validate_command=bash validate.sh
EOF_CONFIG
cat >"$VALIDATE_PROJECT/validate.sh" <<'EOF_VALIDATE'
set -e
git init nested >/dev/null
test -d nested/.git
test "$(git -C nested rev-parse --is-bare-repository)" = "false"
EOF_VALIDATE
VALIDATE_ENV_OUT="$TEST_DIR/validate-env.out"
(
  cd "$VALIDATE_PROJECT"
  GIT_DIR="$VALIDATE_PROJECT/.git" \
    GIT_WORK_TREE="$VALIDATE_PROJECT" \
    PRE_COMMIT=1 \
    PRE_COMMIT_REMOTE_BRANCH=refs/heads/feature/test \
    bash "$TOUCHSTONE_ROOT/scripts/touchstone-run.sh" validate
) >"$VALIDATE_ENV_OUT" 2>&1
assert_contains "$VALIDATE_ENV_OUT" 'validate.sh'

echo "==> Test: feature-branch pre-push validate is cheap"

FEATURE_PUSH_OUT="$TEST_DIR/feature-push-validate.out"
FEATURE_PUSH_SENTINEL="$VALIDATE_PROJECT/nested"
rm -rf "$FEATURE_PUSH_SENTINEL"
git -C "$VALIDATE_PROJECT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
(
  cd "$VALIDATE_PROJECT"
  TOUCHSTONE_VALIDATE_SKIP_FEATURE_PUSH=1 \
    PRE_COMMIT=1 \
    PRE_COMMIT_REMOTE_NAME=origin \
    PRE_COMMIT_REMOTE_BRANCH=refs/heads/feature/test \
    bash "$TOUCHSTONE_ROOT/scripts/touchstone-run.sh" validate
) >"$FEATURE_PUSH_OUT" 2>&1
assert_contains "$FEATURE_PUSH_OUT" 'SKIP feature-branch pre-push validate'
if [ -d "$FEATURE_PUSH_SENTINEL" ]; then
  echo "FAIL: feature-branch pre-push validate should not run configured validate command" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: default-branch pre-push validate still runs"

DEFAULT_PUSH_OUT="$TEST_DIR/default-push-validate.out"
(
  cd "$VALIDATE_PROJECT"
  TOUCHSTONE_VALIDATE_SKIP_FEATURE_PUSH=1 \
    PRE_COMMIT=1 \
    PRE_COMMIT_REMOTE_NAME=origin \
    PRE_COMMIT_REMOTE_BRANCH=refs/heads/main \
    bash "$TOUCHSTONE_ROOT/scripts/touchstone-run.sh" validate
) >"$DEFAULT_PUSH_OUT" 2>&1
assert_contains "$DEFAULT_PUSH_OUT" 'validate.sh'

echo "==> Test: unknown remote default keeps validation conservative"

UNKNOWN_DEFAULT_OUT="$TEST_DIR/unknown-default-validate.out"
rm -rf "$FEATURE_PUSH_SENTINEL"
git -C "$VALIDATE_PROJECT" symbolic-ref --delete refs/remotes/origin/HEAD 2>/dev/null || true
(
  cd "$VALIDATE_PROJECT"
  TOUCHSTONE_VALIDATE_SKIP_FEATURE_PUSH=1 \
    PRE_COMMIT=1 \
    PRE_COMMIT_REMOTE_NAME=origin \
    PRE_COMMIT_REMOTE_BRANCH=refs/heads/trunk \
    bash "$TOUCHSTONE_ROOT/scripts/touchstone-run.sh" validate
) >"$UNKNOWN_DEFAULT_OUT" 2>&1
assert_contains "$UNKNOWN_DEFAULT_OUT" 'validate.sh'

echo "==> Test: run-script rejects projects without a version contract"

UNVERSIONED_PROJECT="$TEST_DIR/unversioned-project"
mkdir -p "$UNVERSIONED_PROJECT"
git -C "$UNVERSIONED_PROJECT" init -q
UNVERSIONED_OUT="$TEST_DIR/unversioned.out"
set +e
run_touchstone run-script touchstone-run --project "$UNVERSIONED_PROJECT" -- detect >"$UNVERSIONED_OUT" 2>&1
UNVERSIONED_EXIT=$?
set -e

if [ "$UNVERSIONED_EXIT" -eq 0 ]; then
  echo "FAIL: run-script should reject projects without .touchstone-version" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$UNVERSIONED_OUT" 'run-script requires a project version contract'
assert_contains "$UNVERSIONED_OUT" "project: $UNVERSIONED_PROJECT"
assert_contains "$UNVERSIONED_OUT" 'Fix: pass --project-version'

echo "==> Test: run-script rejects a project version contract the CLI cannot satisfy"

MISMATCH_OUT="$TEST_DIR/mismatch.out"
set +e
(cd "$PROJECT" && run_touchstone run-script touchstone-run --project-version 0000000000000000000000000000000000000000 -- detect) >"$MISMATCH_OUT" 2>&1
MISMATCH_EXIT=$?
set -e

if [ "$MISMATCH_EXIT" -eq 0 ]; then
  echo "FAIL: run-script should reject an unsatisfied project version" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$MISMATCH_OUT" 'installed Touchstone does not satisfy the project script contract'
assert_contains "$MISMATCH_OUT" 'project requires: 000000000000'
assert_contains "$MISMATCH_OUT" 'Fix: touchstone update'

echo "==> Test: prototype shim fails before running implementation on version mismatch"

SHIM_OUT="$TEST_DIR/shim.out"
set +e
(
  cd "$PROJECT"
  PATH="$TOUCHSTONE_ROOT/bin:$PATH" \
    HOME="$TEST_DIR/home" \
    NO_COLOR=1 \
    TOUCHSTONE_NO_AUTO_UPDATE=1 \
    PROJECT_TOUCHSTONE_ID=0000000000000000000000000000000000000000 \
    bash "$TOUCHSTONE_ROOT/prototypes/pinned-shim/cleanup-worktrees.sh" --dry-run
) >"$SHIM_OUT" 2>&1
SHIM_EXIT=$?
set -e

if [ "$SHIM_EXIT" -eq 0 ]; then
  echo "FAIL: prototype shim should reject an unsatisfied project version" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$SHIM_OUT" 'script: *cleanup-worktrees'
assert_contains "$SHIM_OUT" 'installed Touchstone does not satisfy the project script contract'

echo "==> Test: run-script rejects unknown script names"

UNKNOWN_OUT="$TEST_DIR/unknown.out"
set +e
(cd "$PROJECT" && run_touchstone run-script not-a-script --project-version "$CURRENT_ID") >"$UNKNOWN_OUT" 2>&1
UNKNOWN_EXIT=$?
set -e

if [ "$UNKNOWN_EXIT" -eq 0 ]; then
  echo "FAIL: run-script should reject unknown script names" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$UNKNOWN_OUT" "unknown Touchstone script 'not-a-script'"
assert_contains "$UNKNOWN_OUT" 'Known scripts: cleanup-branches cleanup-worktrees touchstone-run'

echo "==> Test: run-script keeps high-risk PR scripts out of the prototype allowlist"

HIGH_RISK_OUT="$TEST_DIR/high-risk.out"
set +e
(cd "$PROJECT" && run_touchstone run-script open-pr --project-version "$CURRENT_ID" -- --help) >"$HIGH_RISK_OUT" 2>&1
HIGH_RISK_EXIT=$?
set -e

if [ "$HIGH_RISK_EXIT" -eq 0 ]; then
  echo "FAIL: run-script should reject high-risk PR scripts during the prototype rollout" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$HIGH_RISK_OUT" "unknown Touchstone script 'open-pr'"
assert_contains "$HIGH_RISK_OUT" 'Known scripts: cleanup-branches cleanup-worktrees touchstone-run'

echo "==> Test: a failing package script fails instead of reporting 'no script'"

# Regression for the laundering that made a green required check compatible
# with nothing having run: run_node_action inferred script *presence* from the
# exit code, so `pnpm lint` exiting 3 was reported as an absent script.
NODE_FAIL_PROJECT="$TEST_DIR/node-lint-fail"
make_node_project "$NODE_FAIL_PROJECT"
NODE_FAIL_OUT="$TEST_DIR/node-lint-fail.out"
run_runner "$NODE_FAIL_PROJECT" "$NODE_FAIL_OUT" lint
if [ "$RUNNER_EXIT" -eq 0 ]; then
  echo "FAIL: a failing package.json lint script must fail the run" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_not_contains "$NODE_FAIL_OUT" "no package.json 'lint' script"
assert_contains "$NODE_FAIL_OUT" 'lint verdict: ran=1 skipped=0 failed=1'

echo "==> Test: a failing declared target fails the run"

# Regression for `if run_targets_action`: the conditional disabled set -e for
# the whole target loop, so a failed target was masked by a later target's
# success — and a failure in the last target fell through to the root profile's
# "no default command" skip, which exited 0.
TARGET_FAIL_PROJECT="$TEST_DIR/targets-fail"
mkdir -p "$TARGET_FAIL_PROJECT"
git -C "$TARGET_FAIL_PROJECT" init -q
make_node_project "$TARGET_FAIL_PROJECT/packages/alpha"
make_node_project "$TARGET_FAIL_PROJECT/packages/beta"
printf 'project_type=generic\ntargets=alpha:packages/alpha:node,beta:packages/beta:node\n' \
  >"$TARGET_FAIL_PROJECT/.touchstone-config"
TARGET_FAIL_OUT="$TEST_DIR/targets-fail.out"
run_runner "$TARGET_FAIL_PROJECT" "$TARGET_FAIL_OUT" lint
if [ "$RUNNER_EXIT" -eq 0 ]; then
  echo "FAIL: a failing target must fail the run even when a later target passes" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$TARGET_FAIL_OUT" "target 'alpha' failed 'lint' (exit 3)"
assert_not_contains "$TARGET_FAIL_OUT" "generic project has no default 'lint' command"

echo "==> Test: a declared target whose path is gone fails the run"

TARGET_GHOST_PROJECT="$TEST_DIR/targets-ghost"
mkdir -p "$TARGET_GHOST_PROJECT"
git -C "$TARGET_GHOST_PROJECT" init -q
printf 'project_type=generic\ntargets=ghost:packages/ghost:node\n' \
  >"$TARGET_GHOST_PROJECT/.touchstone-config"
TARGET_GHOST_OUT="$TEST_DIR/targets-ghost.out"
run_runner "$TARGET_GHOST_PROJECT" "$TARGET_GHOST_OUT" lint
if [ "$RUNNER_EXIT" -eq 0 ]; then
  echo "FAIL: a declared target with a missing path must fail the run" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$TARGET_GHOST_OUT" "declared target 'ghost' path not found: packages/ghost"
assert_contains "$TARGET_GHOST_OUT" "drop 'ghost' from targets= in .touchstone-config"

echo "==> Test: a declared command that is not runnable fails with the remedy"

MISSING_TOOL_PROJECT="$TEST_DIR/declared-missing-tool"
mkdir -p "$MISSING_TOOL_PROJECT"
git -C "$MISSING_TOOL_PROJECT" init -q
printf 'test_command=touchstone-no-such-tool-xyz --run\n' >"$MISSING_TOOL_PROJECT/.touchstone-config"
MISSING_TOOL_OUT="$TEST_DIR/declared-missing-tool.out"
run_runner "$MISSING_TOOL_PROJECT" "$MISSING_TOOL_OUT" test
if [ "$RUNNER_EXIT" -eq 0 ]; then
  echo "FAIL: a declared command whose binary is missing must fail the run" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$MISSING_TOOL_OUT" 'declared test_command is not runnable here (exit 127)'
assert_contains "$MISSING_TOOL_OUT" 'Or declare a runnable command: test_command=<command> in .touchstone-config'
assert_contains "$MISSING_TOOL_OUT" 'test verdict: ran=0 skipped=0 failed=1'

echo "==> Test: an undeclared project still runs, and says nothing ran"

# Backward compatibility at a shipped boundary: projects bootstrapped before
# declaration-first keep exiting 0. What changes is that the run reports what
# it did — SKIP per task, a verdict line, and a warning that a green result
# here proves nothing.
UNDECLARED_PROJECT="$TEST_DIR/undeclared"
mkdir -p "$UNDECLARED_PROJECT"
git -C "$UNDECLARED_PROJECT" init -q
UNDECLARED_OUT="$TEST_DIR/undeclared.out"
run_runner "$UNDECLARED_PROJECT" "$UNDECLARED_OUT" validate
if [ "$RUNNER_EXIT" -ne 0 ]; then
  echo "FAIL: a project that declares nothing must keep working (exit 0)" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$UNDECLARED_OUT" "SKIP generic project has no default 'lint' command"
assert_contains "$UNDECLARED_OUT" 'validate verdict: ran=0 skipped=3 failed=0'
assert_contains "$UNDECLARED_OUT" "NOTHING RAN: 'validate' executed no command"
assert_contains "$UNDECLARED_OUT" "DEPRECATED: no lint_command in .touchstone-config"

echo "==> Test: require_declared turns an unproven validate into a failure"

STRICT_PROJECT="$TEST_DIR/require-declared"
mkdir -p "$STRICT_PROJECT"
git -C "$STRICT_PROJECT" init -q
printf 'require_declared=true\n' >"$STRICT_PROJECT/.touchstone-config"
STRICT_OUT="$TEST_DIR/require-declared.out"
run_runner "$STRICT_PROJECT" "$STRICT_OUT" validate
if [ "$RUNNER_EXIT" -eq 0 ]; then
  echo "FAIL: require_declared=true must fail a validate in which nothing was declared" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$STRICT_OUT" "require_declared=true and no declared command ran for 'validate'"

printf 'require_declared=true\nvalidate_command=true\n' >"$STRICT_PROJECT/.touchstone-config"
STRICT_OK_OUT="$TEST_DIR/require-declared-ok.out"
run_runner "$STRICT_PROJECT" "$STRICT_OK_OUT" validate
if [ "$RUNNER_EXIT" -ne 0 ]; then
  echo "FAIL: require_declared=true must pass once a declared command runs" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$STRICT_OK_OUT" 'validate verdict: ran=1 skipped=0 failed=0'

echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: run-script prototype contract holds"
  exit 0
else
  echo "==> FAIL: $ERRORS assertion(s) failed"
  exit 1
fi
