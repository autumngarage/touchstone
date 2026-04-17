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
case "\$*" in
  "install --hook-type pre-commit")
    mkdir -p .git/hooks && : > .git/hooks/pre-commit
    printf 'pre-commit installed at .git/hooks/pre-commit\n'
    ;;
  "install --hook-type pre-push")
    mkdir -p .git/hooks && : > .git/hooks/pre-push
    printf 'pre-commit installed at .git/hooks/pre-push\n'
    ;;
  "install --hook-type commit-msg")
    mkdir -p .git/hooks && : > .git/hooks/commit-msg
    printf 'pre-commit installed at .git/hooks/commit-msg\n'
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
assert_contains "$HOOKS_LOG" '^install --hook-type commit-msg$'
assert_exists "$PROJECT_HOOKS_WITH/.git/hooks/pre-commit"
assert_exists "$PROJECT_HOOKS_WITH/.git/hooks/pre-push"
assert_exists "$PROJECT_HOOKS_WITH/.git/hooks/commit-msg"

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
