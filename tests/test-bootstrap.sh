#!/usr/bin/env bash
#
# tests/test-bootstrap.sh — verify new-project.sh creates the expected structure.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-bootstrap.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "==> Test: bootstrap a new project"
echo "    Test dir: $TEST_DIR/test-project"

# Run bootstrap.
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$TEST_DIR/test-project" --no-register

# Verify structure.
ERRORS=0

assert_exists() {
  if [ ! -e "$1" ]; then
    echo "FAIL: expected $1 to exist" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

assert_not_exists() {
  if [ -e "$1" ]; then
    echo "FAIL: expected $1 to NOT exist" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

assert_executable() {
  if [ ! -x "$1" ]; then
    echo "FAIL: expected $1 to be executable" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

assert_contains() {
  if ! grep -q "$2" "$1" 2>/dev/null; then
    echo "FAIL: expected $1 to contain '$2'" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

assert_not_contains() {
  if grep -q "$2" "$1" 2>/dev/null; then
    echo "FAIL: expected $1 to NOT contain '$2'" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

PROJECT="$TEST_DIR/test-project"
PROJECT_WITH_UNSAFE="$TEST_DIR/test-project-unsafe"
PROJECT_EXISTING="$TEST_DIR/test-project-existing"
PROJECT_EXISTING_CONFIG="$TEST_DIR/test-project-existing-config"
PROJECT_INIT_EXISTING_SETUP="$TEST_DIR/test-project-init-existing-setup"
PROJECT_NODE="$TEST_DIR/test-project-node"
PROJECT_PYTHON="$TEST_DIR/test-project-python"
PROJECT_REVIEW_NONE="$TEST_DIR/test-project-review-none"
PROJECT_REVIEW_LOCAL="$TEST_DIR/test-project-review-local"
PROJECT_REVIEW_HYBRID="$TEST_DIR/test-project-review-hybrid"
PROJECT_GITBUTLER="$TEST_DIR/test-project-gitbutler"
PROJECT_HOOKS_WITH="$TEST_DIR/test-project-hooks-with"
PROJECT_HOOKS_WITHOUT="$TEST_DIR/test-project-hooks-without"
PROJECT_PYTEST_EMPTY="$TEST_DIR/test-project-pytest-empty"
PROJECT_REINIT="$TEST_DIR/test-project-reinit"
PROJECT_DOCTOR="$TEST_DIR/test-project-doctor"
PROJECT_OUTDATED="$TEST_DIR/test-project-outdated"
PROJECT_DOCTOR_FRESH="$TEST_DIR/test-project-doctor-fresh"
PROJECT_DOCTOR_LEGACY="$TEST_DIR/test-project-doctor-legacy"

# Git repo
assert_exists "$PROJECT/.git"

# Templates (project-owned)
assert_exists "$PROJECT/CLAUDE.md"
assert_exists "$PROJECT/AGENTS.md"
assert_exists "$PROJECT/.pre-commit-config.yaml"
assert_exists "$PROJECT/.gitignore"
assert_exists "$PROJECT/.github/pull_request_template.md"
assert_exists "$PROJECT/.codex-review.toml"

# Principles
assert_exists "$PROJECT/principles/engineering-principles.md"
assert_exists "$PROJECT/principles/pre-implementation-checklist.md"
assert_exists "$PROJECT/principles/audit-weak-points.md"
assert_exists "$PROJECT/principles/documentation-ownership.md"
assert_exists "$PROJECT/principles/git-workflow.md"
assert_exists "$PROJECT/principles/README.md"

# Scripts
assert_exists "$PROJECT/scripts/codex-review.sh"
assert_exists "$PROJECT/scripts/touchstone-run.sh"
assert_exists "$PROJECT/scripts/open-pr.sh"
assert_exists "$PROJECT/scripts/merge-pr.sh"
assert_exists "$PROJECT/scripts/cleanup-branches.sh"
assert_not_exists "$PROJECT/scripts/run-pytest-in-venv.sh"
assert_executable "$PROJECT/scripts/codex-review.sh"
assert_executable "$PROJECT/scripts/touchstone-run.sh"
assert_executable "$PROJECT/scripts/open-pr.sh"
assert_executable "$PROJECT/scripts/merge-pr.sh"
assert_executable "$PROJECT/scripts/cleanup-branches.sh"
assert_contains "$PROJECT/.pre-commit-config.yaml" 'codex-review.sh'
assert_contains "$PROJECT/.pre-commit-config.yaml" 'touchstone-run.sh validate'
assert_contains "$PROJECT/.touchstone-config" '^project_type=generic$'
assert_contains "$PROJECT/.touchstone-config" '^lint_command=$'
assert_contains "$PROJECT/.touchstone-config" '^git_workflow=git$'
assert_contains "$PROJECT/.touchstone-config" '^gitbutler_mcp=false$'
assert_exists "$PROJECT/.touchstone-manifest"
assert_contains "$PROJECT/.touchstone-manifest" '^\.touchstone-version$'
assert_contains "$PROJECT/.touchstone-manifest" '^scripts/open-pr.sh$'
if grep -q '^\.touchstone-config$' "$PROJECT/.gitignore"; then
  echo "FAIL: expected .touchstone-config to be commit-friendly, not ignored" >&2
  ERRORS=$((ERRORS + 1))
fi
if grep -q '^\.touchstone-version$' "$PROJECT/.gitignore"; then
  echo "FAIL: expected .touchstone-version to be commit-friendly, not ignored" >&2
  ERRORS=$((ERRORS + 1))
fi

# Touchstone version
assert_exists "$PROJECT/.touchstone-version"
assert_contains "$PROJECT/.touchstone-version" "[a-f0-9]"

# Verify CLAUDE.md has principle imports
assert_contains "$PROJECT/CLAUDE.md" "@principles/"

# Help flags should print usage instead of bootstrapping a project named --help.
if (cd "$TEST_DIR" && bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" --help) >"$TEST_DIR/new-project-help.txt" 2>&1; then
  assert_contains "$TEST_DIR/new-project-help.txt" 'unsafe-paths'
  assert_contains "$TEST_DIR/new-project-help.txt" 'reviewer codex|claude|gemini|local|auto|none'
  assert_contains "$TEST_DIR/new-project-help.txt" 'review-routing all-hosted|all-local|small-local'
  assert_contains "$TEST_DIR/new-project-help.txt" 'gitbutler'
  assert_contains "$TEST_DIR/new-project-help.txt" 'node|python|swift|rust|go|generic|auto'
else
  echo "FAIL: expected new-project.sh --help to succeed" >&2
  ERRORS=$((ERRORS + 1))
fi
if [ -d "$TEST_DIR/--help" ]; then
  echo "FAIL: new-project.sh --help created a project directory" >&2
  ERRORS=$((ERRORS + 1))
fi

if TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" init --help >"$TEST_DIR/touchstone-init-help.txt" 2>&1; then
  assert_contains "$TEST_DIR/touchstone-init-help.txt" 'Usage: touchstone init'
  assert_contains "$TEST_DIR/touchstone-init-help.txt" 'reviewer codex|claude|gemini|local|auto|none'
  assert_contains "$TEST_DIR/touchstone-init-help.txt" 'review-routing all-hosted|all-local|small-local'
  assert_contains "$TEST_DIR/touchstone-init-help.txt" 'gitbutler'
  assert_contains "$TEST_DIR/touchstone-init-help.txt" 'node|python|swift|rust|go|generic|auto'
else
  echo "FAIL: expected touchstone init --help to succeed" >&2
  ERRORS=$((ERRORS + 1))
fi

# Bootstrap with explicit unsafe paths.
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_WITH_UNSAFE" --no-register --unsafe-paths "src/auth/,migrations/"
assert_exists "$PROJECT_WITH_UNSAFE/.codex-review.toml"
assert_contains "$PROJECT_WITH_UNSAFE/.codex-review.toml" '"src/auth/",'
assert_contains "$PROJECT_WITH_UNSAFE/.codex-review.toml" '"migrations/",'
assert_contains "$PROJECT_WITH_UNSAFE/.codex-review.toml" '^unsafe_paths = \[$'

# Ecosystem profiles should configure shared runner behavior without making
# Python the default for every project.
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_NODE" --no-register --type node
assert_exists "$PROJECT_NODE/scripts/touchstone-run.sh"
assert_not_exists "$PROJECT_NODE/scripts/run-pytest-in-venv.sh"
assert_contains "$PROJECT_NODE/.touchstone-config" '^project_type=node$'

bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_PYTHON" --no-register --type python
assert_exists "$PROJECT_PYTHON/scripts/touchstone-run.sh"
assert_exists "$PROJECT_PYTHON/scripts/run-pytest-in-venv.sh"
assert_contains "$PROJECT_PYTHON/.touchstone-config" '^project_type=python$'
assert_contains "$PROJECT_PYTHON/.touchstone-manifest" '^scripts/run-pytest-in-venv.sh$'

# Bootstrap into an existing directory should back up touchstone-owned files before replacing them.
mkdir -p "$PROJECT_EXISTING/principles" "$PROJECT_EXISTING/scripts"
printf 'custom principle\n' > "$PROJECT_EXISTING/principles/engineering-principles.md"
printf 'custom script\n' > "$PROJECT_EXISTING/scripts/open-pr.sh"
printf 'custom manifest\n' > "$PROJECT_EXISTING/.touchstone-manifest"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_EXISTING" --no-register
assert_exists "$PROJECT_EXISTING/principles/engineering-principles.md.bak"
assert_exists "$PROJECT_EXISTING/scripts/open-pr.sh.bak"
assert_exists "$PROJECT_EXISTING/.touchstone-manifest.bak"
assert_contains "$PROJECT_EXISTING/principles/engineering-principles.md.bak" 'custom principle'
assert_contains "$PROJECT_EXISTING/scripts/open-pr.sh.bak" 'custom script'
assert_contains "$PROJECT_EXISTING/.touchstone-manifest.bak" 'custom manifest'

# Existing project-owned Codex config must not be rewritten by --unsafe-paths.
mkdir -p "$PROJECT_EXISTING_CONFIG"
{
  printf '[codex_review]\n'
  printf 'max_iterations = 9\n'
  printf 'unsafe_paths = []\n'
  printf 'safe_by_default = true\n'
} > "$PROJECT_EXISTING_CONFIG/.codex-review.toml"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_EXISTING_CONFIG" --no-register --unsafe-paths "src/auth/"
assert_contains "$PROJECT_EXISTING_CONFIG/.codex-review.toml" '^unsafe_paths = \[\]$'
assert_contains "$PROJECT_EXISTING_CONFIG/.codex-review.toml" '^safe_by_default = true$'
if grep -q 'src/auth' "$PROJECT_EXISTING_CONFIG/.codex-review.toml"; then
  echo "FAIL: expected existing .codex-review.toml unsafe_paths to remain unchanged" >&2
  ERRORS=$((ERRORS + 1))
fi

# Bootstrap should let users opt out of AI review explicitly.
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_REVIEW_NONE" --no-register --no-ai-review
assert_contains "$PROJECT_REVIEW_NONE/.codex-review.toml" '^mode = "review-only"$'
assert_contains "$PROJECT_REVIEW_NONE/.codex-review.toml" '^safe_by_default = false$'
assert_contains "$PROJECT_REVIEW_NONE/.codex-review.toml" '^enabled = false$'
assert_contains "$PROJECT_REVIEW_NONE/.codex-review.toml" '^reviewers = \[\]$'

# Bootstrap should support local model reviewer commands.
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_REVIEW_LOCAL" --no-register --reviewer local --local-review-command "local-reviewer --model demo" --review-assist --review-autofix --unsafe-paths "src/auth/"
assert_contains "$PROJECT_REVIEW_LOCAL/.codex-review.toml" '^mode = "fix"$'
assert_contains "$PROJECT_REVIEW_LOCAL/.codex-review.toml" '^safe_by_default = true$'
assert_contains "$PROJECT_REVIEW_LOCAL/.codex-review.toml" '^enabled = true$'
assert_contains "$PROJECT_REVIEW_LOCAL/.codex-review.toml" '^reviewers = \["local"\]$'
assert_contains "$PROJECT_REVIEW_LOCAL/.codex-review.toml" '^\[review.local\]$'
assert_contains "$PROJECT_REVIEW_LOCAL/.codex-review.toml" '^command = "local-reviewer --model demo"$'
assert_contains "$PROJECT_REVIEW_LOCAL/.codex-review.toml" '"src/auth/",'

# Bootstrap should support routing small reviews to local and larger reviews to hosted models.
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_REVIEW_HYBRID" --no-register --review-routing small-local --small-review-lines 123 --reviewer codex --local-review-command "local-reviewer --model demo"
assert_contains "$PROJECT_REVIEW_HYBRID/.codex-review.toml" '^\[review.routing\]$'
assert_contains "$PROJECT_REVIEW_HYBRID/.codex-review.toml" '^enabled = true$'
assert_contains "$PROJECT_REVIEW_HYBRID/.codex-review.toml" '^small_max_diff_lines = 123$'
assert_contains "$PROJECT_REVIEW_HYBRID/.codex-review.toml" '^small_reviewers = \["local", "codex"\]$'
assert_contains "$PROJECT_REVIEW_HYBRID/.codex-review.toml" '^large_reviewers = \["codex"\]$'
assert_contains "$PROJECT_REVIEW_HYBRID/.codex-review.toml" '^command = "local-reviewer --model demo"$'

# Bootstrap should record the optional GitButler workflow choice without making it the default.
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_GITBUTLER" --no-register --gitbutler --gitbutler-mcp
assert_contains "$PROJECT_GITBUTLER/.touchstone-config" '^git_workflow=gitbutler$'
assert_contains "$PROJECT_GITBUTLER/.touchstone-config" '^gitbutler_mcp=true$'

# touchstone init must not run a pre-existing project setup.sh after preserving it.
mkdir -p "$PROJECT_INIT_EXISTING_SETUP"
git -C "$PROJECT_INIT_EXISTING_SETUP" init >/dev/null
{
  printf '#!/usr/bin/env bash\n'
  printf 'echo PROJECT_SETUP_RAN\n'
  printf 'exit 42\n'
} > "$PROJECT_INIT_EXISTING_SETUP/setup.sh"
chmod +x "$PROJECT_INIT_EXISTING_SETUP/setup.sh"
if (cd "$PROJECT_INIT_EXISTING_SETUP" && TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" init --no-register) >"$TEST_DIR/touchstone-init-existing-setup.txt" 2>&1; then
  assert_contains "$TEST_DIR/touchstone-init-existing-setup.txt" 'setup.sh already existed'
else
  echo "FAIL: touchstone init should not fail because an existing setup.sh exits non-zero" >&2
  ERRORS=$((ERRORS + 1))
fi
if grep -q 'PROJECT_SETUP_RAN' "$TEST_DIR/touchstone-init-existing-setup.txt"; then
  echo "FAIL: touchstone init ran a pre-existing setup.sh" >&2
  ERRORS=$((ERRORS + 1))
fi

# Pytest wrapper should use project virtualenvs instead of system python.
PYTEST_WRAPPER_PROJECT="$TEST_DIR/pytest-wrapper"
mkdir -p "$PYTEST_WRAPPER_PROJECT"
if (cd "$PYTEST_WRAPPER_PROJECT" && "$TOUCHSTONE_ROOT/scripts/run-pytest-in-venv.sh" tests) >"$TEST_DIR/pytest-missing-venv.txt" 2>&1; then
  echo "FAIL: expected run-pytest-in-venv.sh to fail without a venv" >&2
  ERRORS=$((ERRORS + 1))
else
  assert_contains "$TEST_DIR/pytest-missing-venv.txt" 'Run: bash setup.sh'
fi

mkdir -p "$PYTEST_WRAPPER_PROJECT/.venv/bin"
cat > "$PYTEST_WRAPPER_PROJECT/.venv/bin/python" <<'FAKEPYTHON'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$PWD/pytest-args.txt"
if [ "$1" = "-m" ] && [ "$2" = "pytest" ]; then
  exit 0
fi
exit 1
FAKEPYTHON
chmod +x "$PYTEST_WRAPPER_PROJECT/.venv/bin/python"

(cd "$PYTEST_WRAPPER_PROJECT" && "$TOUCHSTONE_ROOT/scripts/run-pytest-in-venv.sh" tests/unit -x)
assert_contains "$PYTEST_WRAPPER_PROJECT/pytest-args.txt" '^-m$'
assert_contains "$PYTEST_WRAPPER_PROJECT/pytest-args.txt" '^pytest$'
assert_contains "$PYTEST_WRAPPER_PROJECT/pytest-args.txt" '^tests/unit$'
assert_contains "$PYTEST_WRAPPER_PROJECT/pytest-args.txt" '^-x$'

# setup.sh --deps-only should support uv projects at the repo root and in agent/.
FAKE_BIN="$TEST_DIR/fake-bin"
UV_LOG="$TEST_DIR/uv.log"
mkdir -p "$FAKE_BIN" "$PROJECT/agent"
cat > "$FAKE_BIN/uv" <<'FAKEUV'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$UV_LOG"
mkdir -p .venv/bin
cat > .venv/bin/python <<'FAKEPY'
#!/usr/bin/env bash
exit 0
FAKEPY
chmod +x .venv/bin/python
printf 'uv synced\n'
FAKEUV
chmod +x "$FAKE_BIN/uv"

printf '[project]\nname = "root-project"\nversion = "0.0.0"\n' > "$PROJECT/pyproject.toml"
touch "$PROJECT/uv.lock"
printf '[project]\nname = "agent-project"\nversion = "0.0.0"\n' > "$PROJECT/agent/pyproject.toml"
printf '3.11\n' > "$PROJECT/agent/.python-version"

(cd "$PROJECT" && PATH="$FAKE_BIN:$PATH" UV_LOG="$UV_LOG" bash setup.sh --deps-only) >/dev/null
assert_exists "$PROJECT/.venv/bin/python"
assert_exists "$PROJECT/agent/.venv/bin/python"
UV_SYNC_COUNT="$(grep -c '|sync$' "$UV_LOG" 2>/dev/null || true)"
if [ "$UV_SYNC_COUNT" -ne 2 ]; then
  echo "FAIL: expected setup.sh --deps-only to run uv sync twice, got $UV_SYNC_COUNT" >&2
  ERRORS=$((ERRORS + 1))
fi

# setup.sh should display the Touchstone version even though touchstone version output
# starts with a blank header line.
SETUP_VERSION_PROJECT="$TEST_DIR/setup-version-project"
SETUP_VERSION_FAKE_BIN="$TEST_DIR/setup-version-fake-bin"
mkdir -p "$SETUP_VERSION_FAKE_BIN"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$SETUP_VERSION_PROJECT" --no-register >/dev/null
{
  printf '\n[review]\n'
  printf 'enabled = true\n'
  printf 'reviewers = ["local"]\n'
  printf '\n[review.routing]\n'
  printf 'enabled = true\n'
  printf 'small_max_diff_lines = 123\n'
  printf 'small_reviewers = ["local", "codex"]\n'
  printf 'large_reviewers = ["codex"]\n'
  printf '\n[review.local]\n'
  printf 'command = "local-reviewer --model demo"\n'
} >> "$SETUP_VERSION_PROJECT/.codex-review.toml"
{
  printf 'git_workflow=gitbutler\n'
  printf 'gitbutler_mcp=false\n'
} >> "$SETUP_VERSION_PROJECT/.touchstone-config"
cat > "$SETUP_VERSION_FAKE_BIN/touchstone" <<'FAKETOUCHSTONE'
#!/usr/bin/env bash
case "$1" in
  version)
    printf '\n'
    printf 'touchstone v9.9.9\n'
    i=1
    while [ "$i" -le 3000 ]; do
      printf 'extra version detail %s\n' "$i"
      i=$((i + 1))
    done
    exit 0
    ;;
  update)
    printf '==> Already up to date.\n'
    exit 0
    ;;
esac
printf 'fake touchstone %s\n' "$*"
FAKETOUCHSTONE
cat > "$SETUP_VERSION_FAKE_BIN/brew" <<'FAKEBREW'
#!/usr/bin/env bash
exit 0
FAKEBREW
cat > "$SETUP_VERSION_FAKE_BIN/pre-commit" <<'FAKEPRECOMMIT'
#!/usr/bin/env bash
printf 'pre-commit installed\n'
FAKEPRECOMMIT
cat > "$SETUP_VERSION_FAKE_BIN/gh" <<'FAKEGH'
#!/usr/bin/env bash
printf 'Logged in to github.com\n'
FAKEGH
cat > "$SETUP_VERSION_FAKE_BIN/codex" <<'FAKECODEX'
#!/usr/bin/env bash
exit 0
FAKECODEX
cat > "$SETUP_VERSION_FAKE_BIN/but" <<'FAKEBUT'
#!/usr/bin/env bash
exit 0
FAKEBUT
chmod +x "$SETUP_VERSION_FAKE_BIN/"*
(cd "$SETUP_VERSION_PROJECT" && PATH="$SETUP_VERSION_FAKE_BIN:$PATH" bash setup.sh) >"$TEST_DIR/setup-version-output.txt"
assert_contains "$TEST_DIR/setup-version-output.txt" 'touchstone v9.9.9'
assert_contains "$TEST_DIR/setup-version-output.txt" 'review routing enabled'
assert_contains "$TEST_DIR/setup-version-output.txt" 'local reviewer configured: local-reviewer --model demo'
assert_contains "$TEST_DIR/setup-version-output.txt" 'GitButler selected'
assert_contains "$TEST_DIR/setup-version-output.txt" 'but installed'
assert_not_contains "$TEST_DIR/setup-version-output.txt" "unknown AI reviewer"

# touchstone-run.sh should provide ecosystem-neutral task dispatch.
RUNNER_FAKE_BIN="$TEST_DIR/runner-fake-bin"
RUNNER_LOG="$TEST_DIR/runner.log"
mkdir -p "$RUNNER_FAKE_BIN"

cat > "$RUNNER_FAKE_BIN/pnpm" <<'FAKEPNPM'
#!/usr/bin/env bash
printf 'pnpm|%s|%s\n' "$PWD" "$*" >> "$RUNNER_LOG"
FAKEPNPM
cat > "$RUNNER_FAKE_BIN/npm" <<'FAKENPM'
#!/usr/bin/env bash
printf 'npm|%s|%s\n' "$PWD" "$*" >> "$RUNNER_LOG"
FAKENPM
cat > "$RUNNER_FAKE_BIN/swift" <<'FAKESWIFT'
#!/usr/bin/env bash
printf 'swift|%s|%s\n' "$PWD" "$*" >> "$RUNNER_LOG"
FAKESWIFT
cat > "$RUNNER_FAKE_BIN/cargo" <<'FAKECARGO'
#!/usr/bin/env bash
printf 'cargo|%s|%s\n' "$PWD" "$*" >> "$RUNNER_LOG"
FAKECARGO
chmod +x "$RUNNER_FAKE_BIN/"*

printf '{"packageManager":"pnpm@9.0.0","scripts":{"lint":"echo lint","typecheck":"echo typecheck","test":"echo test"}}\n' > "$PROJECT_NODE/package.json"
: > "$RUNNER_LOG"
(cd "$PROJECT_NODE" && PATH="$RUNNER_FAKE_BIN:$PATH" RUNNER_LOG="$RUNNER_LOG" bash scripts/touchstone-run.sh validate) >/dev/null
assert_contains "$RUNNER_LOG" 'pnpm|.*/test-project-node|lint'
assert_contains "$RUNNER_LOG" 'pnpm|.*/test-project-node|typecheck'
assert_contains "$RUNNER_LOG" 'pnpm|.*/test-project-node|test'

SWIFT_PROJECT="$TEST_DIR/swift-runner"
mkdir -p "$SWIFT_PROJECT/scripts"
cp "$TOUCHSTONE_ROOT/scripts/touchstone-run.sh" "$SWIFT_PROJECT/scripts/touchstone-run.sh"
printf 'project_type=swift\n' > "$SWIFT_PROJECT/.touchstone-config"
printf '// swift package\n' > "$SWIFT_PROJECT/Package.swift"
: > "$RUNNER_LOG"
(cd "$SWIFT_PROJECT" && PATH="$RUNNER_FAKE_BIN:$PATH" RUNNER_LOG="$RUNNER_LOG" bash scripts/touchstone-run.sh validate) >/dev/null
assert_contains "$RUNNER_LOG" 'swift|.*/swift-runner|build'
assert_contains "$RUNNER_LOG" 'swift|.*/swift-runner|test'

RUST_PROJECT="$TEST_DIR/rust-runner"
mkdir -p "$RUST_PROJECT/scripts"
cp "$TOUCHSTONE_ROOT/scripts/touchstone-run.sh" "$RUST_PROJECT/scripts/touchstone-run.sh"
printf 'project_type=rust\n' > "$RUST_PROJECT/.touchstone-config"
printf '[package]\nname = "demo"\nversion = "0.0.0"\n' > "$RUST_PROJECT/Cargo.toml"
: > "$RUNNER_LOG"
(cd "$RUST_PROJECT" && PATH="$RUNNER_FAKE_BIN:$PATH" RUNNER_LOG="$RUNNER_LOG" bash scripts/touchstone-run.sh validate) >/dev/null
assert_contains "$RUNNER_LOG" 'cargo|.*/rust-runner|fmt -- --check'
assert_contains "$RUNNER_LOG" 'cargo|.*/rust-runner|clippy --all-targets --all-features -- -D warnings'
assert_contains "$RUNNER_LOG" 'cargo|.*/rust-runner|check --all-targets --all-features'
assert_contains "$RUNNER_LOG" 'cargo|.*/rust-runner|test --all'

MONOREPO_PROJECT="$TEST_DIR/monorepo-runner"
mkdir -p "$MONOREPO_PROJECT/scripts" "$MONOREPO_PROJECT/apps/web" "$MONOREPO_PROJECT/services/api"
cp "$TOUCHSTONE_ROOT/scripts/touchstone-run.sh" "$MONOREPO_PROJECT/scripts/touchstone-run.sh"
{
  printf 'project_type=generic\n'
  printf 'targets=web:apps/web:node,api:services/api:rust\n'
} > "$MONOREPO_PROJECT/.touchstone-config"
printf '{"scripts":{"test":"echo test"}}\n' > "$MONOREPO_PROJECT/apps/web/package.json"
printf '[package]\nname = "api"\nversion = "0.0.0"\n' > "$MONOREPO_PROJECT/services/api/Cargo.toml"
: > "$RUNNER_LOG"
(cd "$MONOREPO_PROJECT" && PATH="$RUNNER_FAKE_BIN:$PATH" RUNNER_LOG="$RUNNER_LOG" bash scripts/touchstone-run.sh test) >/dev/null
assert_contains "$RUNNER_LOG" 'npm|.*/monorepo-runner/apps/web|run test'
assert_contains "$RUNNER_LOG" 'cargo|.*/monorepo-runner/services/api|test --all'

# setup.sh --deps-only should also use the project profile layer for non-Python ecosystems.
: > "$RUNNER_LOG"
(cd "$PROJECT_NODE" && PATH="$RUNNER_FAKE_BIN:$PATH" RUNNER_LOG="$RUNNER_LOG" bash setup.sh --deps-only) >/dev/null
assert_contains "$RUNNER_LOG" 'pnpm|.*/test-project-node|install'

cp "$TOUCHSTONE_ROOT/templates/setup.sh" "$SWIFT_PROJECT/setup.sh"
: > "$RUNNER_LOG"
(cd "$SWIFT_PROJECT" && PATH="$RUNNER_FAKE_BIN:$PATH" RUNNER_LOG="$RUNNER_LOG" bash setup.sh --deps-only) >/dev/null
assert_contains "$RUNNER_LOG" 'swift|.*/swift-runner|package resolve'

cp "$TOUCHSTONE_ROOT/templates/setup.sh" "$RUST_PROJECT/setup.sh"
: > "$RUNNER_LOG"
(cd "$RUST_PROJECT" && PATH="$RUNNER_FAKE_BIN:$PATH" RUNNER_LOG="$RUNNER_LOG" bash setup.sh --deps-only) >/dev/null
assert_contains "$RUNNER_LOG" 'cargo|.*/rust-runner|fetch'

# Bootstrap should install git hooks via pre-commit when pre-commit is available,
# so a fresh repo is actually gated — not just configured.
HOOKS_FAKE_BIN="$TEST_DIR/hooks-fake-bin"
HOOKS_LOG="$TEST_DIR/hooks.log"
mkdir -p "$HOOKS_FAKE_BIN"
cat > "$HOOKS_FAKE_BIN/pre-commit" <<FAKEPRECOMMIT
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$HOOKS_LOG"
# Write the pre-commit-framework marker and chmod +x so touchstone doctor
# --project can verify both the shim content and its executability — Git
# silently skips non-executable hooks, which would ungate the repo.
case "\$*" in
  "install --hook-type pre-commit")
    mkdir -p .git/hooks
    printf '#!/usr/bin/env bash\n# File generated by pre-commit: https://pre-commit.com\n' > .git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit
    printf 'pre-commit installed at .git/hooks/pre-commit\n'
    ;;
  "install --hook-type pre-push")
    mkdir -p .git/hooks
    printf '#!/usr/bin/env bash\n# File generated by pre-commit: https://pre-commit.com\n' > .git/hooks/pre-push
    chmod +x .git/hooks/pre-push
    printf 'pre-commit installed at .git/hooks/pre-push\n'
    ;;
  *)
    exit 0
    ;;
esac
FAKEPRECOMMIT
chmod +x "$HOOKS_FAKE_BIN/pre-commit"

: > "$HOOKS_LOG"
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_HOOKS_WITH" --no-register >/dev/null
assert_contains "$HOOKS_LOG" '^install --hook-type pre-commit$'
assert_contains "$HOOKS_LOG" '^install --hook-type pre-push$'
# commit-msg install is intentionally NOT performed — no commit-msg hooks are configured.
if grep -q '^install --hook-type commit-msg$' "$HOOKS_LOG"; then
  echo "FAIL: commit-msg hook should not be installed — no commit-msg hooks are configured" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_exists "$PROJECT_HOOKS_WITH/.git/hooks/pre-commit"
assert_exists "$PROJECT_HOOKS_WITH/.git/hooks/pre-push"
assert_not_exists "$PROJECT_HOOKS_WITH/.git/hooks/commit-msg"

# Bootstrap without pre-commit on PATH must print the gap, succeed (no fatal error),
# and leave hooks uninstalled — rather than silently "succeed" with an ungated repo.
if PATH="/usr/bin:/bin" command -v pre-commit >/dev/null 2>&1; then
  echo "SKIP: pre-commit is in /usr/bin:/bin; cannot test gap path on this machine" >&2
else
  if PATH="/usr/bin:/bin" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_HOOKS_WITHOUT" --no-register >"$TEST_DIR/hooks-without-output.txt" 2>&1; then
    assert_contains "$TEST_DIR/hooks-without-output.txt" 'pre-commit CLI is not installed'
    assert_not_exists "$PROJECT_HOOKS_WITHOUT/.git/hooks/pre-push"
  else
    echo "FAIL: bootstrap without pre-commit must not exit nonzero — it should print the gap and continue" >&2
    ERRORS=$((ERRORS + 1))
  fi
fi

# touchstone-run.sh test must treat pytest exit 5 (no tests collected) as graceful skip,
# so pre-code repos and new scaffolds don't fail validate.
PYTEST_FAKE_BIN="$TEST_DIR/pytest-fake-bin"
mkdir -p "$PYTEST_FAKE_BIN"
cat > "$PYTEST_FAKE_BIN/python3" <<'FAKEPY'
#!/usr/bin/env bash
if [ "$1" = "-m" ] && [ "$2" = "pytest" ]; then
  printf 'collected 0 items\n'
  exit 5
fi
exit 0
FAKEPY
chmod +x "$PYTEST_FAKE_BIN/python3"

mkdir -p "$PROJECT_PYTEST_EMPTY/scripts"
cp "$TOUCHSTONE_ROOT/scripts/touchstone-run.sh" "$PROJECT_PYTEST_EMPTY/scripts/touchstone-run.sh"
printf 'project_type=python\n' > "$PROJECT_PYTEST_EMPTY/.touchstone-config"
if (cd "$PROJECT_PYTEST_EMPTY" && PATH="$PYTEST_FAKE_BIN:$PATH" bash scripts/touchstone-run.sh test) >"$TEST_DIR/pytest-empty-output.txt" 2>&1; then
  assert_contains "$TEST_DIR/pytest-empty-output.txt" 'pytest found no tests; skipped'
else
  echo "FAIL: pytest exit 5 must be a graceful skip, not a failure" >&2
  ERRORS=$((ERRORS + 1))
fi

# Re-running init on an already-touchstoned repo must reconcile (install missing hooks,
# backfill deleted touchstone-owned files, re-register) without re-prompting — not silently
# do nothing and not clobber project-owned content.
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_REINIT" --no-register >/dev/null
# Simulate drift: delete an installed hook shim, a synced principle file, and the
# project-owned CLAUDE.md (worst case — reconcile must backfill it but MUST NOT prompt).
rm -f "$PROJECT_REINIT/.git/hooks/pre-push"
rm -f "$PROJECT_REINIT/principles/engineering-principles.md"
rm -f "$PROJECT_REINIT/CLAUDE.md"
# Run from a non-TTY so interactive prompts would hang if the gating is wrong.
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_REINIT" --no-register </dev/null >"$TEST_DIR/reinit-output.txt" 2>&1
assert_exists "$PROJECT_REINIT/.git/hooks/pre-push"
assert_exists "$PROJECT_REINIT/principles/engineering-principles.md"
assert_exists "$PROJECT_REINIT/CLAUDE.md"
assert_contains "$TEST_DIR/reinit-output.txt" 'Reconciling touchstone files'
assert_contains "$TEST_DIR/reinit-output.txt" 'touchstone reconciled:'
assert_not_contains "$TEST_DIR/reinit-output.txt" 'Fill in project details'

# Reconcile in a repo where setup.sh was deleted must NOT re-run setup (no dev-tool installs
# during a repair). Bootstrap, delete setup.sh, rerun init — verify backfill without invocation.
PROJECT_REINIT_SETUP="$TEST_DIR/test-project-reinit-setup"
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_REINIT_SETUP" --no-register >/dev/null
rm -f "$PROJECT_REINIT_SETUP/setup.sh"
cat > "$PROJECT_REINIT_SETUP/setup.sh.marker" <<'MARKER'
# Touchstone should never run setup.sh during reconcile; if it does, this test catches it.
MARKER
# Replace the template setup.sh with a marker-logging version via a wrapper PATH.
REINIT_SETUP_LOG="$TEST_DIR/reinit-setup.log"
: > "$REINIT_SETUP_LOG"
REINIT_SETUP_FAKE_BIN="$TEST_DIR/reinit-setup-fake-bin"
mkdir -p "$REINIT_SETUP_FAKE_BIN"
cp "$HOOKS_FAKE_BIN/pre-commit" "$REINIT_SETUP_FAKE_BIN/pre-commit"
(cd "$PROJECT_REINIT_SETUP" && PATH="$REINIT_SETUP_FAKE_BIN:$PATH" TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" init --no-register) </dev/null >"$TEST_DIR/reinit-setup-output.txt" 2>&1
assert_exists "$PROJECT_REINIT_SETUP/setup.sh"
# Setup.sh itself would print 'Setting up' if it ran — we assert it did NOT.
if grep -q 'Setting up' "$TEST_DIR/reinit-setup-output.txt" 2>/dev/null; then
  echo "FAIL: init reconcile must not run setup.sh even if the file was backfilled" >&2
  ERRORS=$((ERRORS + 1))
fi

# touchstone doctor --project must exit clean on a fully-armed repo.
# Use the fake pre-commit so hooks install regardless of what's on the tester's real PATH.
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_DOCTOR" --no-register >/dev/null
if (cd "$PROJECT_DOCTOR" && TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-clean.txt" 2>&1; then
  assert_contains "$TEST_DIR/doctor-clean.txt" 'Project is fully armed'
else
  echo "FAIL: doctor --project should exit 0 on a fresh bootstrap" >&2
  ERRORS=$((ERRORS + 1))
fi

# Break hooks and rerun doctor — it must exit nonzero and flag the gap.
rm -f "$PROJECT_DOCTOR/.git/hooks/pre-push"
if (cd "$PROJECT_DOCTOR" && TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-broken.txt" 2>&1; then
  echo "FAIL: doctor --project should exit nonzero when hooks are missing" >&2
  ERRORS=$((ERRORS + 1))
else
  assert_contains "$TEST_DIR/doctor-broken.txt" 'git hooks NOT installed'
fi

# doctor must flag a pre-push hook whose content isn't the pre-commit-framework
# shim — another framework silently replacing the file is the same class of
# failure as hook files being absent outright. The replacement here is executable,
# so the content check (not the executability check) is the one exercised.
PROJECT_DOCTOR_HOOK_DRIFT="$TEST_DIR/test-project-doctor-hook-drift"
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_DOCTOR_HOOK_DRIFT" --no-register >/dev/null
printf '#!/usr/bin/env bash\necho some other framework\n' > "$PROJECT_DOCTOR_HOOK_DRIFT/.git/hooks/pre-push"
chmod +x "$PROJECT_DOCTOR_HOOK_DRIFT/.git/hooks/pre-push"
if (cd "$PROJECT_DOCTOR_HOOK_DRIFT" && TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-hook-drift.txt" 2>&1; then
  echo "FAIL: doctor --project should exit nonzero when pre-push is not the pre-commit-framework shim" >&2
  ERRORS=$((ERRORS + 1))
else
  assert_contains "$TEST_DIR/doctor-hook-drift.txt" "aren't the pre-commit-framework shim"
fi

# doctor must flag a pre-push hook that exists with the right content but is
# not executable — Git silently skips such hooks, so the repo is effectively
# ungated. Same failure class as "hook missing", different failure mode.
PROJECT_DOCTOR_HOOK_UNEXEC="$TEST_DIR/test-project-doctor-hook-unexec"
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_DOCTOR_HOOK_UNEXEC" --no-register >/dev/null
chmod -x "$PROJECT_DOCTOR_HOOK_UNEXEC/.git/hooks/pre-push"
if (cd "$PROJECT_DOCTOR_HOOK_UNEXEC" && TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-hook-unexec.txt" 2>&1; then
  echo "FAIL: doctor --project should exit nonzero when a hook file is not executable" >&2
  ERRORS=$((ERRORS + 1))
else
  assert_contains "$TEST_DIR/doctor-hook-unexec.txt" 'not executable'
fi

# Python profile: tests folder and ruff availability must both be reported by doctor.
PROJECT_DOCTOR_PY_WITH="$TEST_DIR/test-project-doctor-python-with"
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_DOCTOR_PY_WITH" --no-register --type python >/dev/null
mkdir -p "$PROJECT_DOCTOR_PY_WITH/tests"
printf 'def test_smoke():\n    assert True\n' > "$PROJECT_DOCTOR_PY_WITH/tests/test_smoke.py"
RUFF_STUB_BIN="$TEST_DIR/ruff-stub-bin"
mkdir -p "$RUFF_STUB_BIN"
cat > "$RUFF_STUB_BIN/ruff" <<'RUFFSTUB'
#!/usr/bin/env bash
exit 0
RUFFSTUB
chmod +x "$RUFF_STUB_BIN/ruff"
if (cd "$PROJECT_DOCTOR_PY_WITH" && PATH="$RUFF_STUB_BIN:$PATH" TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-py-with.txt" 2>&1; then
  assert_contains "$TEST_DIR/doctor-py-with.txt" "tests: found for profile 'python'"
  assert_contains "$TEST_DIR/doctor-py-with.txt" 'ruff: on PATH'
else
  echo "FAIL: doctor --project on a Python project with tests and ruff should exit 0" >&2
  ERRORS=$((ERRORS + 1))
fi

# Python profile with no tests directory and no ruff on PATH — doctor must
# nudge on tests (informational, no issue++) and warn+count on ruff.
PROJECT_DOCTOR_PY_WITHOUT="$TEST_DIR/test-project-doctor-python-without"
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_DOCTOR_PY_WITHOUT" --no-register --type python >/dev/null
if PATH="/usr/bin:/bin" command -v ruff >/dev/null 2>&1; then
  echo "SKIP: ruff on minimal PATH; cannot test ruff-absent doctor case on this machine" >&2
else
  # Keep touchstone reachable by its absolute path; drop ruff from PATH.
  if (cd "$PROJECT_DOCTOR_PY_WITHOUT" && PATH="/usr/bin:/bin" TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-py-without.txt" 2>&1; then
    echo "FAIL: doctor --project on a Python project with no ruff should exit nonzero" >&2
    ERRORS=$((ERRORS + 1))
  else
    assert_contains "$TEST_DIR/doctor-py-without.txt" "tests: not found for profile 'python'"
    assert_contains "$TEST_DIR/doctor-py-without.txt" 'ruff not on PATH'
  fi
fi

# Monorepo projects where targets drive validate: doctor must run test/lint
# checks per target, not on the root profile. The root profile check would
# miss gaps inside apps/services/packages that the runner actually dispatches
# to at pre-push time. Also exercise profile aliases (ts -> node, py -> python)
# and empty/auto profiles that must be resolved by manifest detection so each
# target hits the same dispatcher branch touchstone-run.sh would use.
PROJECT_DOCTOR_MONO="$TEST_DIR/test-project-doctor-monorepo"
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_DOCTOR_MONO" --no-register >/dev/null
mkdir -p "$PROJECT_DOCTOR_MONO/apps/web" "$PROJECT_DOCTOR_MONO/services/api" "$PROJECT_DOCTOR_MONO/apps/tsapp" "$PROJECT_DOCTOR_MONO/packages/autodetect"
printf '[package]\nname = "api"\nversion = "0.0.0"\n' > "$PROJECT_DOCTOR_MONO/services/api/Cargo.toml"
printf '{"scripts":{"lint":"echo lint","test":"echo test"}}\n' > "$PROJECT_DOCTOR_MONO/apps/web/package.json"
# tsapp declares "typescript" profile (alias for node) but has no lint script.
printf '{}\n' > "$PROJECT_DOCTOR_MONO/apps/tsapp/package.json"
# autodetect declares no explicit profile — must be detected from manifest (Cargo.toml).
printf '[package]\nname = "autodetected"\nversion = "0.0.0"\n' > "$PROJECT_DOCTOR_MONO/packages/autodetect/Cargo.toml"
sed -i '' 's|^targets=.*|targets=web:apps/web:node,api:services/api:rust,tsapp:apps/tsapp:typescript,autodetect:packages/autodetect|' "$PROJECT_DOCTOR_MONO/.touchstone-config"
if (cd "$PROJECT_DOCTOR_MONO" && TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-monorepo.txt" 2>&1; then
  assert_contains "$TEST_DIR/doctor-monorepo.txt" "target web:"
  assert_contains "$TEST_DIR/doctor-monorepo.txt" "target api:"
  assert_contains "$TEST_DIR/doctor-monorepo.txt" 'target web: package.json: lint script configured'
  assert_contains "$TEST_DIR/doctor-monorepo.txt" "target web: tests: not found for profile 'node'"
  assert_contains "$TEST_DIR/doctor-monorepo.txt" "target api: tests: not found for profile 'rust'"
  # 'typescript' alias must resolve to node — the lint-script check is the
  # node-profile branch, and tsapp has no lint script so the dim-line fires.
  assert_contains "$TEST_DIR/doctor-monorepo.txt" "target tsapp: package.json has no 'lint' script"
  # Auto-detected profile from Cargo.toml must be rust.
  assert_contains "$TEST_DIR/doctor-monorepo.txt" "target autodetect: tests: not found for profile 'rust'"
else
  # Per-target lines must appear even if doctor exits nonzero for other reasons.
  assert_contains "$TEST_DIR/doctor-monorepo.txt" "target web:"
  assert_contains "$TEST_DIR/doctor-monorepo.txt" "target api:"
  assert_contains "$TEST_DIR/doctor-monorepo.txt" "target tsapp: package.json has no 'lint' script"
  assert_contains "$TEST_DIR/doctor-monorepo.txt" "target autodetect: tests: not found for profile 'rust'"
fi

# Python project that overrides lint_command in .touchstone-config must NOT
# have a missing ruff counted as an issue — the project's custom lint never
# invokes ruff, so ruff's absence isn't a gap.
PROJECT_DOCTOR_PY_OVERRIDE="$TEST_DIR/test-project-doctor-python-override"
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_DOCTOR_PY_OVERRIDE" --no-register --type python >/dev/null
# Set lint_command and test_command to custom values to suppress profile-default checks.
sed -i '' 's|^lint_command=.*|lint_command=echo "custom lint"|' "$PROJECT_DOCTOR_PY_OVERRIDE/.touchstone-config"
sed -i '' 's|^test_command=.*|test_command=echo "custom test"|' "$PROJECT_DOCTOR_PY_OVERRIDE/.touchstone-config"
if PATH="/usr/bin:/bin" command -v ruff >/dev/null 2>&1; then
  echo "SKIP: ruff on minimal PATH; cannot test override-suppresses-ruff-check on this machine" >&2
else
  if (cd "$PROJECT_DOCTOR_PY_OVERRIDE" && PATH="/usr/bin:/bin" TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-py-override.txt" 2>&1; then
    assert_contains "$TEST_DIR/doctor-py-override.txt" 'Project is fully armed'
    assert_contains "$TEST_DIR/doctor-py-override.txt" 'lint: overridden via .touchstone-config'
    assert_contains "$TEST_DIR/doctor-py-override.txt" 'tests: overridden via .touchstone-config'
    if grep -q 'ruff not on PATH' "$TEST_DIR/doctor-py-override.txt"; then
      echo "FAIL: doctor should not count missing ruff as an issue when lint_command is overridden" >&2
      ERRORS=$((ERRORS + 1))
    fi
  else
    echo "FAIL: doctor --project on a Python project with lint override should exit 0" >&2
    ERRORS=$((ERRORS + 1))
  fi
fi

# Generic profile doctor must NOT count missing tests as an issue — a fresh
# generic project with no test_command configured stays fully armed.
# (Reuses the PROJECT_DOCTOR repo which was bootstrapped clean above.)
if (cd "$PROJECT_DOCTOR_HOOK_DRIFT" && printf '#!/usr/bin/env bash\n# File generated by pre-commit: https://pre-commit.com\n' > .git/hooks/pre-push) ; then : ; fi
if (cd "$PROJECT_DOCTOR_HOOK_DRIFT" && TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-generic.txt" 2>&1; then
  assert_contains "$TEST_DIR/doctor-generic.txt" 'Project is fully armed'
  assert_contains "$TEST_DIR/doctor-generic.txt" "tests: profile is 'generic'"
else
  echo "FAIL: doctor --project should exit 0 on a clean generic project even without tests" >&2
  ERRORS=$((ERRORS + 1))
fi

# doctor --project outside a touchstoned repo must flag it, not claim health.
mkdir -p "$PROJECT_DOCTOR_FRESH"
if (cd "$PROJECT_DOCTOR_FRESH" && TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-fresh.txt" 2>&1; then
  echo "FAIL: doctor --project should exit nonzero outside a touchstoned project" >&2
  ERRORS=$((ERRORS + 1))
else
  assert_contains "$TEST_DIR/doctor-fresh.txt" 'Not a touchstone project'
fi

# doctor --project on a legacy .toolkit-version repo must point to the migration command.
mkdir -p "$PROJECT_DOCTOR_LEGACY"
echo "legacy-sha" > "$PROJECT_DOCTOR_LEGACY/.toolkit-version"
if (cd "$PROJECT_DOCTOR_LEGACY" && TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-legacy.txt" 2>&1; then
  echo "FAIL: doctor --project should exit nonzero on a legacy .toolkit-version repo" >&2
  ERRORS=$((ERRORS + 1))
else
  assert_contains "$TEST_DIR/doctor-legacy.txt" 'touchstone migrate-from-toolkit'
fi

# Both .toolkit-version and .touchstone-version is an in-flight migration conflict —
# neither doctor nor init may report healthy in that state.
PROJECT_MIGRATION_CONFLICT="$TEST_DIR/test-project-migration-conflict"
mkdir -p "$PROJECT_MIGRATION_CONFLICT"
echo "legacy-sha" > "$PROJECT_MIGRATION_CONFLICT/.toolkit-version"
echo "touchstone-sha" > "$PROJECT_MIGRATION_CONFLICT/.touchstone-version"
if (cd "$PROJECT_MIGRATION_CONFLICT" && TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-conflict.txt" 2>&1; then
  echo "FAIL: doctor --project should exit nonzero when both .toolkit-version and .touchstone-version exist" >&2
  ERRORS=$((ERRORS + 1))
else
  assert_contains "$TEST_DIR/doctor-conflict.txt" 'Migration conflict'
fi
if (cd "$PROJECT_MIGRATION_CONFLICT" && TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" init --no-setup --no-register) >"$TEST_DIR/init-conflict.txt" 2>&1; then
  echo "FAIL: touchstone init should exit nonzero in the migration-conflict state" >&2
  ERRORS=$((ERRORS + 1))
else
  assert_contains "$TEST_DIR/init-conflict.txt" 'Migration conflict'
fi

# touchstone init on an outdated project must delegate to the update flow (branch + commit),
# not silently backup-and-replace files in place.
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_OUTDATED" --no-register >/dev/null
# Configure the committer identity locally so the delegated update-project.sh commit
# works on CI machines without a global Git identity.
git -C "$PROJECT_OUTDATED" config user.email test@touchstone
git -C "$PROJECT_OUTDATED" config user.name test-committer
(cd "$PROJECT_OUTDATED" && git add -A && git commit --no-verify -m "initial" >/dev/null)
echo "0000000000000000000000000000000000000001" > "$PROJECT_OUTDATED/.touchstone-version"
(cd "$PROJECT_OUTDATED" && git commit --no-verify -am "pin to old touchstone" >/dev/null)
if (cd "$PROJECT_OUTDATED" && TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" init --no-setup --no-ship) >"$TEST_DIR/init-outdated.txt" 2>&1; then
  assert_contains "$TEST_DIR/init-outdated.txt" 'upgrading'
  UPDATE_BRANCH="$(git -C "$PROJECT_OUTDATED" branch --show-current)"
  case "$UPDATE_BRANCH" in
    chore/touchstone-*) ;;
    *)
      echo "FAIL: init on outdated project should land on a chore/touchstone-* branch, got '$UPDATE_BRANCH'" >&2
      ERRORS=$((ERRORS + 1))
      ;;
  esac
else
  echo "FAIL: init on outdated project should not exit nonzero (stdout: $(cat "$TEST_DIR/init-outdated.txt"))" >&2
  ERRORS=$((ERRORS + 1))
fi

# touchstone init on an outdated project defaults to --ship. With no reachable remote
# the ship attempt must fail soft: branch preserved, exit 0, clear message.
PROJECT_OUTDATED_SHIP="$TEST_DIR/outdated-ship-project"
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_OUTDATED_SHIP" --no-register >/dev/null
git -C "$PROJECT_OUTDATED_SHIP" config user.email test@touchstone
git -C "$PROJECT_OUTDATED_SHIP" config user.name test-committer
(cd "$PROJECT_OUTDATED_SHIP" && git add -A && git commit --no-verify -m "initial" >/dev/null)
echo "0000000000000000000000000000000000000001" > "$PROJECT_OUTDATED_SHIP/.touchstone-version"
(cd "$PROJECT_OUTDATED_SHIP" && git commit --no-verify -am "pin to old touchstone" >/dev/null)
# Stub gh so open-pr.sh fails fast without real network.
GH_STUB_BIN="$TEST_DIR/gh-stub-bin"
mkdir -p "$GH_STUB_BIN"
cat > "$GH_STUB_BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
echo "gh: stubbed failure" >&2
exit 1
GHSTUB
chmod +x "$GH_STUB_BIN/gh"
if (cd "$PROJECT_OUTDATED_SHIP" && PATH="$GH_STUB_BIN:$HOOKS_FAKE_BIN:$PATH" TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" init --no-setup) >"$TEST_DIR/init-outdated-ship.txt" 2>&1; then
  assert_contains "$TEST_DIR/init-outdated-ship.txt" 'Shipping update via scripts/open-pr.sh'
  assert_contains "$TEST_DIR/init-outdated-ship.txt" 'Ship failed'
  SHIP_BRANCH="$(git -C "$PROJECT_OUTDATED_SHIP" branch --show-current)"
  case "$SHIP_BRANCH" in
    chore/touchstone-*) ;;
    *)
      echo "FAIL: ship-failure path should preserve the chore/touchstone-* branch, got '$SHIP_BRANCH'" >&2
      ERRORS=$((ERRORS + 1))
      ;;
  esac
else
  echo "FAIL: init --ship with failing gh should still exit 0 (branch preserved); stdout: $(cat "$TEST_DIR/init-outdated-ship.txt")" >&2
  ERRORS=$((ERRORS + 1))
fi

# Any non-5 pytest failure must still propagate — we haven't accidentally swallowed real errors.
cat > "$PYTEST_FAKE_BIN/python3" <<'FAKEPY'
#!/usr/bin/env bash
if [ "$1" = "-m" ] && [ "$2" = "pytest" ]; then
  printf 'E   assert False\n'
  exit 1
fi
exit 0
FAKEPY
chmod +x "$PYTEST_FAKE_BIN/python3"
if (cd "$PROJECT_PYTEST_EMPTY" && PATH="$PYTEST_FAKE_BIN:$PATH" bash scripts/touchstone-run.sh test) >"$TEST_DIR/pytest-fail-output.txt" 2>&1; then
  echo "FAIL: pytest exit 1 (real failure) must still propagate as nonzero" >&2
  ERRORS=$((ERRORS + 1))
fi

echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: all assertions passed"
  exit 0
else
  echo "==> FAIL: $ERRORS assertion(s) failed"
  exit 1
fi
