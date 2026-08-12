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

# Same, but the caller seeds the child environment through RUNNER_ENV (an array
# of KEY=VALUE assignments) — that is how ambient-vs-config precedence is
# exercised without leaking the variable into the rest of the suite.
RUNNER_ENV=()
run_runner_with_env() {
  local project="$1" out="$2"
  shift 2
  RUNNER_EXIT=0
  (
    cd "$project"
    PATH="$RUNNER_FAKE_BIN:$PATH" env ${RUNNER_ENV[@]+"${RUNNER_ENV[@]}"} bash "$RUNNER" "$@"
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

# A cargo whose version probes succeed — so the runner dispatches both halves
# of the Rust lint body — and whose `fmt` run fails while `clippy` passes.
cat >"$RUNNER_FAKE_BIN/cargo" <<'FAKE_CARGO'
#!/usr/bin/env bash
case "${2:-}" in
  --version) exit 0 ;;
esac
case "${1:-}" in
  fmt) exit 1 ;;
esac
exit 0
FAKE_CARGO
chmod +x "$RUNNER_FAKE_BIN/cargo"

# A PATH holding exactly the utilities the runner itself needs and nothing
# else, so "this project's toolchain is absent" is a fact of the fixture rather
# than a fact about the machine running the suite. Wrapper scripts rather than
# symlinks: Git Bash on Windows does not create real symlinks by default.
MINIMAL_BIN="$TEST_DIR/minimal-bin"
mkdir -p "$MINIMAL_BIN"
MINIMAL_BASH="$(command -v bash)"
for tool in bash env tr sed grep head basename dirname mktemp rm; do
  TOOL_PATH="$(command -v "$tool" || true)"
  if [ -z "$TOOL_PATH" ]; then
    echo "FAIL: cannot build a minimal PATH: '$tool' is not on PATH" >&2
    ERRORS=$((ERRORS + 1))
    continue
  fi
  printf '#!%s\nexec "%s" "$@"\n' "$MINIMAL_BASH" "$TOOL_PATH" >"$MINIMAL_BIN/$tool"
  chmod +x "$MINIMAL_BIN/$tool"
done
for tool in ruff pyright mypy cargo swift swift-format go npm pnpm yarn bun; do
  if PATH="$MINIMAL_BIN" command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: the minimal PATH still resolves '$tool'; absent-toolchain fixtures are not hermetic" >&2
    ERRORS=$((ERRORS + 1))
  fi
done

run_runner_minimal() {
  local project="$1" out="$2"
  shift 2
  RUNNER_EXIT=0
  (
    cd "$project"
    PATH="$MINIMAL_BIN" "$MINIMAL_BASH" "$RUNNER" "$@"
  ) >"$out" 2>&1 || RUNNER_EXIT=$?
}

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

echo "==> Test: a failing lint step is not masked by a later passing one"

# The regression for the bug this runner exists to stop, in its subtlest form:
# `run_profile_action ... || status=$?` makes bash ignore set -e for the whole
# profile body, so `cargo fmt -- --check` failing was swallowed and `cargo
# clippy` passing became the answer. Rust lint is the body with two steps.
RUST_MASK_PROJECT="$TEST_DIR/rust-lint-mask"
mkdir -p "$RUST_MASK_PROJECT"
git -C "$RUST_MASK_PROJECT" init -q
printf '[package]\nname = "mask"\n' >"$RUST_MASK_PROJECT/Cargo.toml"
printf 'project_type=rust\n' >"$RUST_MASK_PROJECT/.touchstone-config"
RUST_MASK_OUT="$TEST_DIR/rust-lint-mask.out"
run_runner "$RUST_MASK_PROJECT" "$RUST_MASK_OUT" lint
if [ "$RUNNER_EXIT" -eq 0 ]; then
  echo "FAIL: a failing cargo fmt must fail lint even though cargo clippy passes" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$RUST_MASK_OUT" '==> cargo fmt -- --check'
assert_not_contains "$RUST_MASK_OUT" 'cargo clippy --all-targets'
assert_contains "$RUST_MASK_OUT" 'lint verdict: ran=1 skipped=0 failed=1'

echo "==> Test: no dispatch function is called in a conditional context"

# The shape above is invisible at review time and reintroduces the bug in
# silence, so it is checked structurally rather than trusted. bash ignores
# set -e inside a function invoked as `f || x`, `if f`, `f && x` or `! f`, and
# hands that suppression down to everything the function calls — including a
# subshell that sets -e itself.
DISPATCH_FNS='run_action|run_validate|run_targets_action|run_target_profile|run_profile_action|run_declared_command|run_isolated'
CONDITIONAL_HITS="$(
  grep -nE "((^|[[:space:]])(if|while|until|!)[[:space:]]+($DISPATCH_FNS)[[:space:]]|($DISPATCH_FNS)[^#]*(\|\||&&))" "$RUNNER" \
    | grep -vE '^[0-9]+:[[:space:]]*#' || true
)"
if [ -n "$CONDITIONAL_HITS" ]; then
  echo "FAIL: a dispatch function is called in a conditional context, where set -e is ignored:" >&2
  printf '%s\n' "$CONDITIONAL_HITS" | sed 's/^/    /' >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: a declared target whose path is gone fails the run"

# Deliberate, and the reason it is not a warn-and-continue: a target entry is a
# declaration, and a declaration naming a directory that is not there is broken
# in exactly the way a declared command that cannot run is broken. Only
# explicitly declared targets reach this path — detect_targets output feeds
# `detect`, never dispatch — so nothing auto-discovered can trip it.
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

echo "==> Test: an undeclared generic project still runs, and says nothing ran"

# What changes for a project that declares nothing is only that the run reports
# what it did — SKIP per task, a verdict line, and a warning that a green
# result here proves nothing. The exit code does not change. This case pins the
# reporting; the profile sweep below is what carries the compatibility claim.
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

echo "==> Test: every shipped profile keeps exiting 0 when it declares nothing"

# The compatibility claim is about the shipped boundary, so it is exercised
# across the shipped profiles, not one of them. Each fixture declares nothing
# and has none of its toolchain available (see MINIMAL_BIN), which is the state
# every project bootstrapped before declaration-first is in on the next
# `touchstone update`.
COMPAT_CASES="generic::SKIP generic project has no default 'lint' command
node:package.json:SKIP no package.json 'lint' script
python:pyproject.toml:SKIP ruff not installed
rust:Cargo.toml:SKIP cargo not installed
swift:Package.swift:SKIP swift not installed
go:go.mod:SKIP go not installed"

while IFS=: read -r COMPAT_PROFILE COMPAT_MARKER COMPAT_NEEDLE; do
  [ -n "$COMPAT_PROFILE" ] || continue
  COMPAT_DIR="$TEST_DIR/compat-$COMPAT_PROFILE"
  mkdir -p "$COMPAT_DIR"
  if [ -n "$COMPAT_MARKER" ]; then
    : >"$COMPAT_DIR/$COMPAT_MARKER"
  fi
  COMPAT_OUT="$TEST_DIR/compat-$COMPAT_PROFILE.out"
  run_runner_minimal "$COMPAT_DIR" "$COMPAT_OUT" validate
  if [ "$RUNNER_EXIT" -ne 0 ]; then
    echo "FAIL: an undeclared $COMPAT_PROFILE project must keep exiting 0 (got $RUNNER_EXIT)" >&2
    ERRORS=$((ERRORS + 1))
  fi
  assert_contains "$COMPAT_OUT" "$COMPAT_NEEDLE"
  assert_contains "$COMPAT_OUT" 'validate verdict: ran=0'
  assert_contains "$COMPAT_OUT" "NOTHING RAN: 'validate' executed no command"
done <<EOF_COMPAT
$COMPAT_CASES
EOF_COMPAT

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
assert_contains "$STRICT_OUT" 'require_declared=true, but no declared command ran for: lint typecheck test'

printf 'require_declared=true\nvalidate_command=true\n' >"$STRICT_PROJECT/.touchstone-config"
STRICT_OK_OUT="$TEST_DIR/require-declared-ok.out"
run_runner "$STRICT_PROJECT" "$STRICT_OK_OUT" validate
if [ "$RUNNER_EXIT" -ne 0 ]; then
  echo "FAIL: require_declared=true must pass once a declared command runs" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$STRICT_OK_OUT" 'validate verdict: ran=1 skipped=0 failed=0'

echo "==> Test: require_declared is answered per action, not once per run"

# One declared constituent used to satisfy the gate for the whole composite, so
# a project could declare lint and still ship a validate that tested nothing —
# the same green-check-proves-nothing hole, one door further in.
PARTIAL_STRICT_PROJECT="$TEST_DIR/require-declared-partial"
mkdir -p "$PARTIAL_STRICT_PROJECT"
git -C "$PARTIAL_STRICT_PROJECT" init -q
printf 'require_declared=true\nlint_command=true\n' >"$PARTIAL_STRICT_PROJECT/.touchstone-config"
PARTIAL_STRICT_OUT="$TEST_DIR/require-declared-partial.out"
run_runner "$PARTIAL_STRICT_PROJECT" "$PARTIAL_STRICT_OUT" validate
if [ "$RUNNER_EXIT" -eq 0 ]; then
  echo "FAIL: a declared lint must not satisfy require_declared for typecheck and test" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$PARTIAL_STRICT_OUT" 'require_declared=true, but no declared command ran for: typecheck test'
assert_contains "$PARTIAL_STRICT_OUT" 'Fix: declare it in .touchstone-config: typecheck_command=<command>'

printf 'require_declared=true\nlint_command=true\ntypecheck_command=true\ntest_command=true\n' \
  >"$PARTIAL_STRICT_PROJECT/.touchstone-config"
FULL_STRICT_OUT="$TEST_DIR/require-declared-full.out"
run_runner "$PARTIAL_STRICT_PROJECT" "$FULL_STRICT_OUT" validate
if [ "$RUNNER_EXIT" -ne 0 ]; then
  echo "FAIL: declaring every constituent must satisfy require_declared for validate" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$FULL_STRICT_OUT" 'validate verdict: ran=3 skipped=0 failed=0'

echo "==> Test: an ambient env var cannot downgrade a declared require_declared"

# Strictness that any exported variable can switch off is not a gate. The
# variable may raise strictness for a project that has not declared it; it may
# never lower it for a project that has.
printf 'require_declared=true\n' >"$STRICT_PROJECT/.touchstone-config"
STRICT_ENV_OUT="$TEST_DIR/require-declared-env-off.out"
RUNNER_ENV=(TOUCHSTONE_RUN_REQUIRE_DECLARED=0)
run_runner_with_env "$STRICT_PROJECT" "$STRICT_ENV_OUT" validate
if [ "$RUNNER_EXIT" -eq 0 ]; then
  echo "FAIL: TOUCHSTONE_RUN_REQUIRE_DECLARED=0 must not disable a config-declared require_declared" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$STRICT_ENV_OUT" 'require_declared=true, but no declared command ran for: lint typecheck test'

ENV_RAISE_PROJECT="$TEST_DIR/require-declared-env-raise"
mkdir -p "$ENV_RAISE_PROJECT"
git -C "$ENV_RAISE_PROJECT" init -q
ENV_RAISE_OUT="$TEST_DIR/require-declared-env-on.out"
RUNNER_ENV=(TOUCHSTONE_RUN_REQUIRE_DECLARED=1)
run_runner_with_env "$ENV_RAISE_PROJECT" "$ENV_RAISE_OUT" validate
if [ "$RUNNER_EXIT" -eq 0 ]; then
  echo "FAIL: TOUCHSTONE_RUN_REQUIRE_DECLARED=1 must raise the gate for a project that declared nothing" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$ENV_RAISE_OUT" 'require_declared=true, but no declared command ran for: lint typecheck test'

echo "==> Test: a targets monorepo can satisfy require_declared per target"

# Declaration-first applies at every level, so targets are not permanently
# exempt from the strict gate: the root declares which targets exist, and each
# target declares its own commands.
TARGET_STRICT_PROJECT="$TEST_DIR/targets-declared"
mkdir -p "$TARGET_STRICT_PROJECT/packages/alpha" "$TARGET_STRICT_PROJECT/packages/beta"
git -C "$TARGET_STRICT_PROJECT" init -q
printf 'require_declared=true\nproject_type=generic\ntargets=alpha:packages/alpha:generic,beta:packages/beta:generic\n' \
  >"$TARGET_STRICT_PROJECT/.touchstone-config"
printf 'lint_command=true\n' >"$TARGET_STRICT_PROJECT/packages/alpha/.touchstone-config"
printf 'lint_command=true\n' >"$TARGET_STRICT_PROJECT/packages/beta/.touchstone-config"
TARGET_STRICT_OUT="$TEST_DIR/targets-declared.out"
run_runner "$TARGET_STRICT_PROJECT" "$TARGET_STRICT_OUT" lint
if [ "$RUNNER_EXIT" -ne 0 ]; then
  echo "FAIL: per-target declarations must satisfy require_declared for a monorepo" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$TARGET_STRICT_OUT" 'lint verdict: ran=2 skipped=0 failed=0'

rm -f "$TARGET_STRICT_PROJECT/packages/beta/.touchstone-config"
TARGET_PARTIAL_OUT="$TEST_DIR/targets-declared-partial.out"
run_runner "$TARGET_STRICT_PROJECT" "$TARGET_PARTIAL_OUT" lint
if [ "$RUNNER_EXIT" -eq 0 ]; then
  echo "FAIL: one declaring target must not vouch for an undeclared sibling" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$TARGET_PARTIAL_OUT" 'no declared command ran for: lint$'
assert_contains "$TARGET_PARTIAL_OUT" "DEPRECATED: target 'beta': no lint_command"
assert_contains "$TARGET_PARTIAL_OUT" 'A target declares its own commands in its own .touchstone-config'

echo "==> Test: the detection fallback dispatches each package manager unchanged"

# Declaration-first did not move Node dispatch: run_node_script is byte-for-byte
# the pre-change function, and the only behaviour that changed is that a
# *failing* script now fails instead of being reported as absent. That is a
# shipped boundary for every Node project on the deprecated fallback, so the
# exact command each selector produces is pinned rather than assumed.
PM_FAKE_BIN="$TEST_DIR/package-manager-bin"
mkdir -p "$PM_FAKE_BIN"
for PM in npm pnpm yarn bun; do
  printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >>"$PM_LOG"\nexit 0\n' "$PM" >"$PM_FAKE_BIN/$PM"
  chmod +x "$PM_FAKE_BIN/$PM"
done

PM_CASES="pnpm@9.0.0:pnpm:pnpm lint
yarn@4.0.0:yarn:yarn lint
bun@1.0.0:bun:bun run lint
npm@10.0.0:npm:npm run lint"

while IFS=: read -r PM_SELECTOR PM_NAME PM_EXPECTED; do
  [ -n "$PM_NAME" ] || continue
  PM_DIR="$TEST_DIR/pm-$PM_NAME"
  mkdir -p "$PM_DIR"
  printf '{"packageManager":"%s","scripts":{"lint":"x"}}\n' "$PM_SELECTOR" >"$PM_DIR/package.json"
  PM_LOG="$TEST_DIR/pm-$PM_NAME.log"
  : >"$PM_LOG"
  RUNNER_EXIT=0
  (
    cd "$PM_DIR"
    PATH="$PM_FAKE_BIN:$PATH" PM_LOG="$PM_LOG" bash "$RUNNER" lint
  ) >"$TEST_DIR/pm-$PM_NAME.out" 2>&1 || RUNNER_EXIT=$?
  if [ "$RUNNER_EXIT" -ne 0 ]; then
    echo "FAIL: lint via $PM_NAME must exit 0 when the script passes (got $RUNNER_EXIT)" >&2
    ERRORS=$((ERRORS + 1))
  fi
  assert_contains "$PM_LOG" "^$PM_EXPECTED\$"
done <<EOF_PM
$PM_CASES
EOF_PM

echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: run-script prototype contract holds"
  exit 0
else
  echo "==> FAIL: $ERRORS assertion(s) failed"
  exit 1
fi
