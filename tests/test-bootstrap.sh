#!/usr/bin/env bash
#
# tests/test-bootstrap.sh — verify new-project.sh creates the expected structure.
#
set -euo pipefail

TOOLKIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t toolkit-test-bootstrap.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "==> Test: bootstrap a new project"
echo "    Test dir: $TEST_DIR/test-project"

# Run bootstrap.
bash "$TOOLKIT_ROOT/bootstrap/new-project.sh" "$TEST_DIR/test-project" --no-register

# Verify structure.
ERRORS=0

assert_exists() {
  if [ ! -e "$1" ]; then
    echo "FAIL: expected $1 to exist" >&2
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

PROJECT="$TEST_DIR/test-project"
PROJECT_WITH_UNSAFE="$TEST_DIR/test-project-unsafe"
PROJECT_EXISTING="$TEST_DIR/test-project-existing"
PROJECT_EXISTING_CONFIG="$TEST_DIR/test-project-existing-config"
PROJECT_INIT_EXISTING_SETUP="$TEST_DIR/test-project-init-existing-setup"

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
assert_exists "$PROJECT/scripts/open-pr.sh"
assert_exists "$PROJECT/scripts/merge-pr.sh"
assert_exists "$PROJECT/scripts/cleanup-branches.sh"
assert_exists "$PROJECT/scripts/run-pytest-in-venv.sh"
assert_executable "$PROJECT/scripts/codex-review.sh"
assert_executable "$PROJECT/scripts/open-pr.sh"
assert_executable "$PROJECT/scripts/merge-pr.sh"
assert_executable "$PROJECT/scripts/cleanup-branches.sh"
assert_executable "$PROJECT/scripts/run-pytest-in-venv.sh"
assert_contains "$PROJECT/.pre-commit-config.yaml" 'run-pytest-in-venv.sh'

# Toolkit version
assert_exists "$PROJECT/.toolkit-version"
assert_contains "$PROJECT/.toolkit-version" "[a-f0-9]"

# Verify CLAUDE.md has principle imports
assert_contains "$PROJECT/CLAUDE.md" "@principles/"

# Help flags should print usage instead of bootstrapping a project named --help.
if (cd "$TEST_DIR" && bash "$TOOLKIT_ROOT/bootstrap/new-project.sh" --help) >"$TEST_DIR/new-project-help.txt" 2>&1; then
  assert_contains "$TEST_DIR/new-project-help.txt" 'unsafe-paths'
else
  echo "FAIL: expected new-project.sh --help to succeed" >&2
  ERRORS=$((ERRORS + 1))
fi
if [ -d "$TEST_DIR/--help" ]; then
  echo "FAIL: new-project.sh --help created a project directory" >&2
  ERRORS=$((ERRORS + 1))
fi

if TOOLKIT_NO_AUTO_UPDATE=1 "$TOOLKIT_ROOT/bin/toolkit" init --help >"$TEST_DIR/toolkit-init-help.txt" 2>&1; then
  assert_contains "$TEST_DIR/toolkit-init-help.txt" 'Usage: toolkit init'
else
  echo "FAIL: expected toolkit init --help to succeed" >&2
  ERRORS=$((ERRORS + 1))
fi

# Bootstrap with explicit unsafe paths.
bash "$TOOLKIT_ROOT/bootstrap/new-project.sh" "$PROJECT_WITH_UNSAFE" --no-register --unsafe-paths "src/auth/,migrations/"
assert_exists "$PROJECT_WITH_UNSAFE/.codex-review.toml"
assert_contains "$PROJECT_WITH_UNSAFE/.codex-review.toml" '"src/auth/",'
assert_contains "$PROJECT_WITH_UNSAFE/.codex-review.toml" '"migrations/",'
assert_contains "$PROJECT_WITH_UNSAFE/.codex-review.toml" '^unsafe_paths = \[$'

# Bootstrap into an existing directory should back up toolkit-owned files before replacing them.
mkdir -p "$PROJECT_EXISTING/principles" "$PROJECT_EXISTING/scripts"
printf 'custom principle\n' > "$PROJECT_EXISTING/principles/engineering-principles.md"
printf 'custom script\n' > "$PROJECT_EXISTING/scripts/open-pr.sh"
bash "$TOOLKIT_ROOT/bootstrap/new-project.sh" "$PROJECT_EXISTING" --no-register
assert_exists "$PROJECT_EXISTING/principles/engineering-principles.md.bak"
assert_exists "$PROJECT_EXISTING/scripts/open-pr.sh.bak"
assert_contains "$PROJECT_EXISTING/principles/engineering-principles.md.bak" 'custom principle'
assert_contains "$PROJECT_EXISTING/scripts/open-pr.sh.bak" 'custom script'

# Existing project-owned Codex config must not be rewritten by --unsafe-paths.
mkdir -p "$PROJECT_EXISTING_CONFIG"
{
  printf '[codex_review]\n'
  printf 'max_iterations = 9\n'
  printf 'unsafe_paths = []\n'
  printf 'safe_by_default = true\n'
} > "$PROJECT_EXISTING_CONFIG/.codex-review.toml"
bash "$TOOLKIT_ROOT/bootstrap/new-project.sh" "$PROJECT_EXISTING_CONFIG" --no-register --unsafe-paths "src/auth/"
assert_contains "$PROJECT_EXISTING_CONFIG/.codex-review.toml" '^unsafe_paths = \[\]$'
assert_contains "$PROJECT_EXISTING_CONFIG/.codex-review.toml" '^safe_by_default = true$'
if grep -q 'src/auth' "$PROJECT_EXISTING_CONFIG/.codex-review.toml"; then
  echo "FAIL: expected existing .codex-review.toml unsafe_paths to remain unchanged" >&2
  ERRORS=$((ERRORS + 1))
fi

# toolkit init must not run a pre-existing project setup.sh after preserving it.
mkdir -p "$PROJECT_INIT_EXISTING_SETUP"
git -C "$PROJECT_INIT_EXISTING_SETUP" init >/dev/null
{
  printf '#!/usr/bin/env bash\n'
  printf 'echo PROJECT_SETUP_RAN\n'
  printf 'exit 42\n'
} > "$PROJECT_INIT_EXISTING_SETUP/setup.sh"
chmod +x "$PROJECT_INIT_EXISTING_SETUP/setup.sh"
if (cd "$PROJECT_INIT_EXISTING_SETUP" && TOOLKIT_NO_AUTO_UPDATE=1 "$TOOLKIT_ROOT/bin/toolkit" init --no-register) >"$TEST_DIR/toolkit-init-existing-setup.txt" 2>&1; then
  assert_contains "$TEST_DIR/toolkit-init-existing-setup.txt" 'setup.sh already existed'
else
  echo "FAIL: toolkit init should not fail because an existing setup.sh exits non-zero" >&2
  ERRORS=$((ERRORS + 1))
fi
if grep -q 'PROJECT_SETUP_RAN' "$TEST_DIR/toolkit-init-existing-setup.txt"; then
  echo "FAIL: toolkit init ran a pre-existing setup.sh" >&2
  ERRORS=$((ERRORS + 1))
fi

# Pytest wrapper should use project virtualenvs instead of system python.
PYTEST_WRAPPER_PROJECT="$TEST_DIR/pytest-wrapper"
mkdir -p "$PYTEST_WRAPPER_PROJECT"
if (cd "$PYTEST_WRAPPER_PROJECT" && "$TOOLKIT_ROOT/scripts/run-pytest-in-venv.sh" tests) >"$TEST_DIR/pytest-missing-venv.txt" 2>&1; then
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

(cd "$PYTEST_WRAPPER_PROJECT" && "$TOOLKIT_ROOT/scripts/run-pytest-in-venv.sh" tests/unit -x)
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

# setup.sh should display the toolkit version even though toolkit version output
# starts with a blank header line.
SETUP_VERSION_PROJECT="$TEST_DIR/setup-version-project"
SETUP_VERSION_FAKE_BIN="$TEST_DIR/setup-version-fake-bin"
mkdir -p "$SETUP_VERSION_FAKE_BIN"
bash "$TOOLKIT_ROOT/bootstrap/new-project.sh" "$SETUP_VERSION_PROJECT" --no-register >/dev/null
cat > "$SETUP_VERSION_FAKE_BIN/toolkit" <<'FAKETOOLKIT'
#!/usr/bin/env bash
case "$1" in
  version)
    printf '\n'
    printf 'toolkit v9.9.9\n'
    exit 0
    ;;
  update)
    printf '==> Already up to date.\n'
    exit 0
    ;;
esac
printf 'fake toolkit %s\n' "$*"
FAKETOOLKIT
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
chmod +x "$SETUP_VERSION_FAKE_BIN/"*
(cd "$SETUP_VERSION_PROJECT" && PATH="$SETUP_VERSION_FAKE_BIN:$PATH" bash setup.sh) >"$TEST_DIR/setup-version-output.txt"
assert_contains "$TEST_DIR/setup-version-output.txt" 'toolkit v9.9.9'

echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: all assertions passed"
  exit 0
else
  echo "==> FAIL: $ERRORS assertion(s) failed"
  exit 1
fi
