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

run_touchstone() {
  HOME="$TEST_DIR/home" \
    NO_COLOR=1 \
    TOUCHSTONE_NO_AUTO_UPDATE=1 \
    bash "$TOUCHSTONE_BIN" "$@"
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

echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: run-script prototype contract holds"
  exit 0
else
  echo "==> FAIL: $ERRORS assertion(s) failed"
  exit 1
fi
