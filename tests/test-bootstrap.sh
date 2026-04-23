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
  if ! grep -q -e "$2" "$1" 2>/dev/null; then
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
PROJECT_CI_OFF="$TEST_DIR/test-project-ci-off"
PROJECT_CI_GITHUB="$TEST_DIR/test-project-ci-github"
PROJECT_SCAFFOLD_OFF="$TEST_DIR/test-project-scaffold-off"
PROJECT_SCAFFOLD_PY="$TEST_DIR/test-project-scaffold-python"
PROJECT_SCAFFOLD_NODE="$TEST_DIR/test-project-scaffold-node"
PROJECT_SCAFFOLD_GO="$TEST_DIR/test-project-scaffold-go"
PROJECT_SCAFFOLD_GENERIC="$TEST_DIR/test-project-scaffold-generic"
PROJECT_SCAFFOLD_EXISTING="$TEST_DIR/test-project-scaffold-existing"
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
# Cortex append-only exclusions: trailing-whitespace and end-of-file-fixer
# must skip .cortex/journal/ and .cortex/doctrine/ per Cortex Protocol §4.
# Two assertions — one per hook — to catch accidental one-sided fixes.
assert_contains "$PROJECT/.pre-commit-config.yaml" 'cortex/(journal|doctrine)'
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

# Fresh bootstrap must leave the project with exactly one initial commit that
# says "initial touchstone scaffold", so the user's first branch+commit cycle
# isn't blocked by the no-commit-to-branch guard on the freshly-installed hooks.
COMMIT_COUNT="$(git -C "$PROJECT" rev-list --count HEAD 2>/dev/null || echo 0)"
if [ "$COMMIT_COUNT" -ne 1 ]; then
  echo "FAIL: expected exactly 1 commit after fresh bootstrap, got $COMMIT_COUNT" >&2
  ERRORS=$((ERRORS + 1))
fi
LAST_COMMIT_MSG="$(git -C "$PROJECT" log -1 --pretty=%B 2>/dev/null || true)"
case "$LAST_COMMIT_MSG" in
  *"initial touchstone scaffold"*) ;;
  *)
    echo "FAIL: initial commit message missing 'initial touchstone scaffold', got: $LAST_COMMIT_MSG" >&2
    ERRORS=$((ERRORS + 1))
    ;;
esac

# Default branch must be 'main' (not 'master'), respecting init.defaultBranch
# and falling back to main when the config is empty.
DEFAULT_BRANCH="$(git -C "$PROJECT" branch --show-current 2>/dev/null || true)"
if [ "$DEFAULT_BRANCH" != "main" ]; then
  echo "FAIL: expected default branch 'main', got '$DEFAULT_BRANCH'" >&2
  ERRORS=$((ERRORS + 1))
fi

# {{PROJECT_NAME}} must be substituted to the basename even on non-TTY bootstraps,
# so agents and CI runs don't inherit a template with unresolved placeholders.
if grep -q '{{PROJECT_NAME}}' "$PROJECT/CLAUDE.md" 2>/dev/null; then
  echo "FAIL: {{PROJECT_NAME}} must be substituted in CLAUDE.md after fresh non-TTY bootstrap" >&2
  ERRORS=$((ERRORS + 1))
fi
if grep -q '{{PROJECT_NAME}}' "$PROJECT/AGENTS.md" 2>/dev/null; then
  echo "FAIL: {{PROJECT_NAME}} must be substituted in AGENTS.md after fresh non-TTY bootstrap" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$PROJECT/CLAUDE.md" "test-project"
assert_contains "$PROJECT/AGENTS.md" "test-project"

# Help flags should print usage instead of bootstrapping a project named --help.
if (cd "$TEST_DIR" && bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" --help) >"$TEST_DIR/new-project-help.txt" 2>&1; then
  assert_contains "$TEST_DIR/new-project-help.txt" 'unsafe-paths'
  assert_contains "$TEST_DIR/new-project-help.txt" 'reviewer conductor|none'
  assert_contains "$TEST_DIR/new-project-help.txt" 'legacy: codex|claude|gemini|local|auto'
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
  assert_contains "$TEST_DIR/touchstone-init-help.txt" 'reviewer conductor|none'
  assert_contains "$TEST_DIR/touchstone-init-help.txt" 'legacy: codex|claude|gemini|local|auto'
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

# Swift profile on fresh bootstrap must scaffold a complete SPM package so
# `swift build` / `swift test` work immediately without the user hand-writing
# Package.swift. Test with a hyphenated name to exercise to_pascal_case.
PROJECT_SWIFT="$TEST_DIR/autumn-mail-demo"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SWIFT" --no-register --type swift >/dev/null
assert_contains "$PROJECT_SWIFT/.touchstone-config" '^project_type=swift$'
assert_exists "$PROJECT_SWIFT/Package.swift"
assert_exists "$PROJECT_SWIFT/Sources/AutumnMailDemo/AutumnMailDemoApp.swift"
assert_exists "$PROJECT_SWIFT/Tests/AutumnMailDemoTests/SmokeTests.swift"
assert_contains "$PROJECT_SWIFT/Package.swift" 'swift-tools-version: 5.10'
assert_contains "$PROJECT_SWIFT/Package.swift" 'name: "AutumnMailDemo"'
assert_contains "$PROJECT_SWIFT/Package.swift" '.macOS(.v14)'
assert_contains "$PROJECT_SWIFT/Sources/AutumnMailDemo/AutumnMailDemoApp.swift" '@main'
assert_contains "$PROJECT_SWIFT/Sources/AutumnMailDemo/AutumnMailDemoApp.swift" 'struct AutumnMailDemoApp: App'
assert_contains "$PROJECT_SWIFT/Tests/AutumnMailDemoTests/SmokeTests.swift" 'final class SmokeTests: XCTestCase'
# Swift-specific .gitignore entries must be appended on fresh --type swift.
assert_contains "$PROJECT_SWIFT/.gitignore" '^\.build/$'
assert_contains "$PROJECT_SWIFT/.gitignore" '^\.swiftpm/$'
assert_contains "$PROJECT_SWIFT/.gitignore" '^Package\.resolved$'
assert_contains "$PROJECT_SWIFT/.gitignore" '^DerivedData/$'
assert_contains "$PROJECT_SWIFT/.gitignore" '^\*\.xcodeproj/$'

# Swift fresh bootstrap ships .swiftlint.yml with build-artifact excludes so
# `swiftlint --strict` can run against a freshly-built project without choking
# on SwiftPM-generated files in .build/. Project-owned: copied via copy_file,
# preserved on re-init / update if the user has hand-edited it.
assert_exists "$PROJECT_SWIFT/.swiftlint.yml"
assert_contains "$PROJECT_SWIFT/.swiftlint.yml" '^  - \.build$'
assert_contains "$PROJECT_SWIFT/.swiftlint.yml" '^  - \.swiftpm$'
assert_contains "$PROJECT_SWIFT/.swiftlint.yml" '^  - DerivedData$'

# The swift scaffold must skip on a fresh bootstrap when Swift content already
# exists — _has_any_swift_sources guards against overwriting user code. Simulate
# the case: a pre-existing Swift project that has never been touchstoned.
PROJECT_SWIFT_EXISTING="$TEST_DIR/existing-swift-repo"
mkdir -p "$PROJECT_SWIFT_EXISTING"
printf 'SENTINEL_PACKAGE\n' > "$PROJECT_SWIFT_EXISTING/Package.swift"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SWIFT_EXISTING" --no-register --type swift >/dev/null
assert_contains "$PROJECT_SWIFT_EXISTING/Package.swift" '^SENTINEL_PACKAGE$'
assert_not_exists "$PROJECT_SWIFT_EXISTING/Sources/ExistingSwiftRepo/ExistingSwiftRepoApp.swift"
# Existing Swift project still gets the .swiftlint.yml when missing — the
# template is project-owned and added when absent.
assert_exists "$PROJECT_SWIFT_EXISTING/.swiftlint.yml"

# A pre-existing hand-edited .swiftlint.yml must NOT be clobbered by --type swift
# bootstrap. copy_file is the project-owned semantic: skip if exists.
PROJECT_SWIFT_HAND_EDITED="$TEST_DIR/swift-hand-edited-config"
mkdir -p "$PROJECT_SWIFT_HAND_EDITED"
printf 'SENTINEL_HAND_EDITED_CONFIG\n' > "$PROJECT_SWIFT_HAND_EDITED/.swiftlint.yml"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SWIFT_HAND_EDITED" --no-register --type swift >/dev/null
assert_contains "$PROJECT_SWIFT_HAND_EDITED/.swiftlint.yml" '^SENTINEL_HAND_EDITED_CONFIG$'

# Non-swift profiles must NOT pick up the Swift-specific .gitignore entries —
# the append is per-profile and must not bleed across profiles.
if grep -q '^\.swiftpm/$' "$PROJECT_NODE/.gitignore" 2>/dev/null; then
  echo "FAIL: node profile .gitignore must not contain Swift entries" >&2
  ERRORS=$((ERRORS + 1))
fi
if grep -q '^Package\.resolved$' "$PROJECT_PYTHON/.gitignore" 2>/dev/null; then
  echo "FAIL: python profile .gitignore must not contain Swift entries" >&2
  ERRORS=$((ERRORS + 1))
fi

# Non-swift profiles must NOT receive .swiftlint.yml — copy_profile_templates
# is per-profile gated.
assert_not_exists "$PROJECT_NODE/.swiftlint.yml"
assert_not_exists "$PROJECT_PYTHON/.swiftlint.yml"

# Swift-specific .gitignore append must be idempotent — even if the entries
# are already present, a fresh bootstrap must not duplicate them.
PROJECT_SWIFT_IDEMPOTENT="$TEST_DIR/swift-gitignore-idempotent"
mkdir -p "$PROJECT_SWIFT_IDEMPOTENT"
{
  printf '.build/\n'
  printf '.swiftpm/\n'
  printf '*.xcodeproj/\n'
  printf 'DerivedData/\n'
  printf 'Package.resolved\n'
} > "$PROJECT_SWIFT_IDEMPOTENT/.gitignore"
# Also give it existing Swift content so the boilerplate scaffold no-ops.
printf 'SENTINEL_PACKAGE\n' > "$PROJECT_SWIFT_IDEMPOTENT/Package.swift"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SWIFT_IDEMPOTENT" --no-register --type swift >/dev/null
SWIFT_BUILD_DUPES="$(grep -c '^\.build/$' "$PROJECT_SWIFT_IDEMPOTENT/.gitignore" 2>/dev/null || echo 0)"
if [ "$SWIFT_BUILD_DUPES" -ne 1 ]; then
  echo "FAIL: Swift .gitignore append must be idempotent (expected 1 '.build/', got $SWIFT_BUILD_DUPES)" >&2
  ERRORS=$((ERRORS + 1))
fi

# setup.sh must install per-profile dev tools so sentinel's verifier and
# touchstone-run's lint path find the tools they expect. Each profile's install
# block is gated on project_type so non-matching profiles are no-ops, and each
# check-before-install is idempotent.
#
# We grep the scaffolded setup.sh rather than executing it: running the install
# block would invoke brew/go/rustup, which would fail in CI and on any
# non-macOS dev machine. Grepping confirms the branches exist and the flag
# plumbing is wired; the actual brew call is a thin wrapper that's hard to
# break once the branch is reached.
assert_exists "$PROJECT_SWIFT/setup.sh"
assert_contains "$PROJECT_SWIFT/setup.sh" '\-\-skip-devtools'
assert_contains "$PROJECT_SWIFT/setup.sh" 'TOUCHSTONE_SKIP_DEVTOOLS'
assert_contains "$PROJECT_SWIFT/setup.sh" 'install_swift_devtools'
assert_contains "$PROJECT_SWIFT/setup.sh" 'brew install swiftlint'
# swift-format (Apple's tool, not Nick Lockwood's swiftformat) — must match
# what scripts/touchstone-run.sh and `touchstone doctor --project` invoke.
assert_contains "$PROJECT_SWIFT/setup.sh" 'brew install swift-format'
assert_not_contains "$PROJECT_SWIFT/setup.sh" 'brew install swiftformat'
assert_contains "$PROJECT_SWIFT/setup.sh" 'install_go_devtools'
assert_contains "$PROJECT_SWIFT/setup.sh" 'golang.org/x/lint/golint@latest'
assert_contains "$PROJECT_SWIFT/setup.sh" 'install_rust_devtools'
assert_contains "$PROJECT_SWIFT/setup.sh" 'rustup component add clippy'
assert_contains "$PROJECT_SWIFT/setup.sh" 'rustup component add rustfmt'
# Brew guard — the swift install block must degrade gracefully when brew is
# missing instead of exiting the whole setup.
assert_contains "$PROJECT_SWIFT/setup.sh" 'Homebrew not available'
# Go/Rust guards — same graceful degrade.
assert_contains "$PROJECT_SWIFT/setup.sh" 'go not installed'
assert_contains "$PROJECT_SWIFT/setup.sh" 'cargo not installed'
# Syntax check the scaffolded setup.sh so malformed heredoc substitutions
# don't ship silently.
if ! bash -n "$PROJECT_SWIFT/setup.sh" 2>"$TEST_DIR/setup-syntax.txt"; then
  echo "FAIL: scaffolded setup.sh has a syntax error:" >&2
  cat "$TEST_DIR/setup-syntax.txt" >&2
  ERRORS=$((ERRORS + 1))
fi

# --skip-devtools / TOUCHSTONE_SKIP_DEVTOOLS=1 must wire into the gate so
# the install block short-circuits in CI / offline environments. We grep for
# the gate text rather than invoking setup.sh — running it would call real
# brew/go/rustup, which is out of scope for a hermetic test.
assert_contains "$PROJECT_SWIFT/setup.sh" 'Skipping per-profile dev tools'
assert_contains "$PROJECT_SWIFT/setup.sh" 'SKIP_DEVTOOLS=true'
# Monorepo targets must also get their dev tools installed — a generic root
# with Swift/Go/Rust targets would otherwise re-create the same silent-skip
# gap this block closes.
assert_contains "$PROJECT_SWIFT/setup.sh" 'install_configured_target_devtools'
assert_contains "$PROJECT_SWIFT/setup.sh" 'install_profile_devtools'

# Non-swift profile setup.sh must carry the same template (setup.sh is one
# file per project, branch chosen at runtime by project_type). Sanity-check
# that the node/python templates also include all branches so switching
# project_type later works without re-bootstrap.
assert_contains "$PROJECT_NODE/setup.sh" 'install_swift_devtools'
assert_contains "$PROJECT_NODE/setup.sh" 'install_go_devtools'
assert_contains "$PROJECT_NODE/setup.sh" 'install_rust_devtools'
assert_contains "$PROJECT_PYTHON/setup.sh" 'install_swift_devtools'

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
# 2.0 shape: `reviewer = "conductor"` is always the reviewer (the field is
# single-valued in 2.0); `enabled = false` is how opt-out is recorded.
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_REVIEW_NONE" --no-register --no-ai-review
assert_contains "$PROJECT_REVIEW_NONE/.codex-review.toml" '^mode = "review-only"$'
assert_contains "$PROJECT_REVIEW_NONE/.codex-review.toml" '^safe_by_default = false$'
assert_contains "$PROJECT_REVIEW_NONE/.codex-review.toml" '^enabled = false$'
assert_contains "$PROJECT_REVIEW_NONE/.codex-review.toml" '^reviewer = "conductor"$'

# Bootstrap should support local model reviewer commands. In 2.0 the
# `[review.local]` block is retired; local maps to ollama with a comment
# preserving the user's --local-review-command for later custom-provider
# registration (Conductor v0.3).
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_REVIEW_LOCAL" --no-register --reviewer local --local-review-command "local-reviewer --model demo" --review-assist --review-autofix --unsafe-paths "src/auth/"
assert_contains "$PROJECT_REVIEW_LOCAL/.codex-review.toml" '^mode = "fix"$'
assert_contains "$PROJECT_REVIEW_LOCAL/.codex-review.toml" '^safe_by_default = true$'
assert_contains "$PROJECT_REVIEW_LOCAL/.codex-review.toml" '^enabled = true$'
assert_contains "$PROJECT_REVIEW_LOCAL/.codex-review.toml" '^reviewer = "conductor"$'
assert_contains "$PROJECT_REVIEW_LOCAL/.codex-review.toml" '^with = "ollama"$'
assert_contains "$PROJECT_REVIEW_LOCAL/.codex-review.toml" 'local-reviewer --model demo'
assert_contains "$PROJECT_REVIEW_LOCAL/.codex-review.toml" '"src/auth/",'

# Bootstrap should support routing small reviews to local and larger reviews to hosted models.
# 2.0 shape: [review.routing] uses per-bucket CONDUCTOR_* overrides (small_with,
# large_with, etc.) — the 1.x reviewer-cascade arrays are gone.
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_REVIEW_HYBRID" --no-register --review-routing small-local --small-review-lines 123 --reviewer codex --local-review-command "local-reviewer --model demo"
assert_contains "$PROJECT_REVIEW_HYBRID/.codex-review.toml" '^\[review.routing\]$'
assert_contains "$PROJECT_REVIEW_HYBRID/.codex-review.toml" '^enabled = true$'
assert_contains "$PROJECT_REVIEW_HYBRID/.codex-review.toml" '^small_max_diff_lines = 123$'
assert_contains "$PROJECT_REVIEW_HYBRID/.codex-review.toml" '^small_with = "ollama"'
assert_contains "$PROJECT_REVIEW_HYBRID/.codex-review.toml" '^large_with = "codex"$'

# Bootstrap should record the optional GitButler workflow choice without making it the default.
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_GITBUTLER" --no-register --gitbutler --gitbutler-mcp
assert_contains "$PROJECT_GITBUTLER/.touchstone-config" '^git_workflow=gitbutler$'
assert_contains "$PROJECT_GITBUTLER/.touchstone-config" '^gitbutler_mcp=true$'

# CI workflow is opt-in. Default bootstrap must NOT ship .github/workflows/validate.yml
# — not every project uses GitHub Actions and silently adding a workflow would force
# that opinion on GitLab/Bitbucket/self-hosted users.
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_CI_OFF" --no-register >/dev/null
assert_not_exists "$PROJECT_CI_OFF/.github/workflows/validate.yml"

# --ci (github) adds the validate workflow and keeps it project-owned.
# The workflow must call scripts/touchstone-run.sh validate so CI exercises
# the same dispatch path local pre-push does.
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_CI_GITHUB" --no-register --ci github >/dev/null
assert_exists "$PROJECT_CI_GITHUB/.github/workflows/validate.yml"
assert_contains "$PROJECT_CI_GITHUB/.github/workflows/validate.yml" 'scripts/touchstone-run.sh validate'
# The workflow is project-owned — absent from the manifest so touchstone update
# leaves the user's CI customizations alone.
if grep -q '^.github/workflows/validate\.yml$' "$PROJECT_CI_GITHUB/.touchstone-manifest"; then
  echo "FAIL: .github/workflows/validate.yml must be project-owned, not tracked in the manifest" >&2
  ERRORS=$((ERRORS + 1))
fi

# Test scaffolding is opt-in. Default bootstrap must NOT create any test file —
# project owners pick their test framework, and silently seeding tests would
# force that opinion.
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_OFF" --no-register --type python >/dev/null
assert_not_exists "$PROJECT_SCAFFOLD_OFF/tests/test_smoke.py"
assert_not_exists "$PROJECT_SCAFFOLD_OFF/tests/smoke.test.ts"
assert_not_exists "$PROJECT_SCAFFOLD_OFF/smoke_test.go"

# --scaffold-tests + Python: writes tests/test_smoke.py with a pytest-discoverable
# function, plus tests/__init__.py. The smoke test must actually assert and pass.
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_PY" --no-register --type python --scaffold-tests >/dev/null
assert_exists "$PROJECT_SCAFFOLD_PY/tests/test_smoke.py"
assert_exists "$PROJECT_SCAFFOLD_PY/tests/__init__.py"
assert_contains "$PROJECT_SCAFFOLD_PY/tests/test_smoke.py" 'def test_smoke'
assert_contains "$PROJECT_SCAFFOLD_PY/tests/test_smoke.py" 'assert True'

# --scaffold-tests + Node: writes tests/smoke.test.ts in a framework-agnostic
# format (vitest/jest/bun test all accept it).
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_NODE" --no-register --type node --scaffold-tests >/dev/null
assert_exists "$PROJECT_SCAFFOLD_NODE/tests/smoke.test.ts"
assert_contains "$PROJECT_SCAFFOLD_NODE/tests/smoke.test.ts" 'describe("smoke"'
assert_contains "$PROJECT_SCAFFOLD_NODE/tests/smoke.test.ts" 'expect(true).toBe(true)'

# --scaffold-tests + Go: writes smoke_test.go so go test ./... finds it.
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_GO" --no-register --type go --scaffold-tests >/dev/null
assert_exists "$PROJECT_SCAFFOLD_GO/smoke_test.go"
assert_contains "$PROJECT_SCAFFOLD_GO/smoke_test.go" 'func TestSmoke(t \*testing.T)'
# Default package declaration must be a valid Go identifier — `main` for a
# repo with no existing .go files.
assert_contains "$PROJECT_SCAFFOLD_GO/smoke_test.go" '^package main$'

# Go project with a real module path (e.g. module github.com/acme/widget)
# must not let the module path leak into the package declaration — Go package
# names are restricted identifiers, not domain paths. Regression guard for
# "package github.com" which is invalid and breaks go test ./....
PROJECT_SCAFFOLD_GO_MOD="$TEST_DIR/test-project-scaffold-go-mod"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_GO_MOD" --no-register --type go >/dev/null
printf 'module github.com/acme/widget\n\ngo 1.22\n' > "$PROJECT_SCAFFOLD_GO_MOD/go.mod"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_GO_MOD" --no-register --scaffold-tests >/dev/null
assert_exists "$PROJECT_SCAFFOLD_GO_MOD/smoke_test.go"
if grep -q '^package github' "$PROJECT_SCAFFOLD_GO_MOD/smoke_test.go"; then
  echo "FAIL: Go scaffold must not use the module path as the package name" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$PROJECT_SCAFFOLD_GO_MOD/smoke_test.go" '^package main$'

# When the repo already has .go files with a custom package, the scaffold must
# match that package so go test ./... compiles (all files in a dir share one pkg).
PROJECT_SCAFFOLD_GO_PKG="$TEST_DIR/test-project-scaffold-go-pkg"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_GO_PKG" --no-register --type go >/dev/null
printf 'module github.com/acme/widget\n\ngo 1.22\n' > "$PROJECT_SCAFFOLD_GO_PKG/go.mod"
printf 'package widget\n\nfunc Hello() string { return "hi" }\n' > "$PROJECT_SCAFFOLD_GO_PKG/widget.go"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_GO_PKG" --no-register --scaffold-tests >/dev/null
assert_exists "$PROJECT_SCAFFOLD_GO_PKG/smoke_test.go"
assert_contains "$PROJECT_SCAFFOLD_GO_PKG/smoke_test.go" '^package widget$'

# --scaffold-tests + generic: no test file written, but the output must tell the
# user why so they know to set test_command= in .touchstone-config.
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_GENERIC" --no-register --type generic --scaffold-tests >"$TEST_DIR/scaffold-generic.txt" 2>&1
if find "$PROJECT_SCAFFOLD_GENERIC" -maxdepth 3 -type f \( -name 'test_*.py' -o -name '*_test.go' -o -name 'smoke.test.*' \) | grep -q .; then
  echo "FAIL: --scaffold-tests must not create a test file for generic profile" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$TEST_DIR/scaffold-generic.txt" "profile is 'generic'"

# --scaffold-tests must not overwrite existing test files — re-running on a
# project that already has tests is a no-op.
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_EXISTING" --no-register --type python >/dev/null
mkdir -p "$PROJECT_SCAFFOLD_EXISTING/tests"
printf 'def test_real():\n    assert 1 + 1 == 2\n' > "$PROJECT_SCAFFOLD_EXISTING/tests/test_real.py"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_EXISTING" --no-register --scaffold-tests >/dev/null
assert_not_exists "$PROJECT_SCAFFOLD_EXISTING/tests/test_smoke.py"
assert_contains "$PROJECT_SCAFFOLD_EXISTING/tests/test_real.py" 'def test_real'

# Directory-exists != tests-exist. A tests/ dir containing only __init__.py
# or helpers must still trigger scaffolding — otherwise --scaffold-tests
# silently no-ops on the exact setups it's meant to help.
PROJECT_SCAFFOLD_EMPTY_PY="$TEST_DIR/test-project-scaffold-empty-python"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_EMPTY_PY" --no-register --type python >/dev/null
mkdir -p "$PROJECT_SCAFFOLD_EMPTY_PY/tests"
: > "$PROJECT_SCAFFOLD_EMPTY_PY/tests/__init__.py"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_EMPTY_PY" --no-register --scaffold-tests >/dev/null
assert_exists "$PROJECT_SCAFFOLD_EMPTY_PY/tests/test_smoke.py"

# Same class bug for Node — an empty __tests__/tests/test directory must
# not fool the scaffolder into thinking tests exist.
PROJECT_SCAFFOLD_EMPTY_NODE="$TEST_DIR/test-project-scaffold-empty-node"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_EMPTY_NODE" --no-register --type node >/dev/null
mkdir -p "$PROJECT_SCAFFOLD_EMPTY_NODE/__tests__" "$PROJECT_SCAFFOLD_EMPTY_NODE/tests"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_EMPTY_NODE" --no-register --type node --scaffold-tests >/dev/null
assert_exists "$PROJECT_SCAFFOLD_EMPTY_NODE/tests/smoke.test.ts"

# Re-init: when .touchstone-config already has project_type=X, flags like
# --scaffold-tests that dispatch per profile must use that X, not fall back to
# manifest detection. Manifest detection returns "generic" when no toolchain
# files are present, which would silently drop --scaffold-tests behavior.
PROJECT_SCAFFOLD_REINIT_PY="$TEST_DIR/test-project-scaffold-reinit-python"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_REINIT_PY" --no-register --type python >/dev/null
# No --type on the second call — must be resolved from .touchstone-config.
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_REINIT_PY" --no-register --scaffold-tests >/dev/null
assert_exists "$PROJECT_SCAFFOLD_REINIT_PY/tests/test_smoke.py"

# React/TS projects commonly name tests Component.spec.tsx — the node test
# predicate must include .spec.tsx / .spec.jsx, otherwise --scaffold-tests
# incorrectly ADDS a placeholder next to real tests.
PROJECT_SCAFFOLD_SPEC_TSX="$TEST_DIR/test-project-scaffold-spec-tsx"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_SPEC_TSX" --no-register --type node >/dev/null
mkdir -p "$PROJECT_SCAFFOLD_SPEC_TSX/src"
printf 'describe("Button", () => { it("renders", () => {}); });\n' > "$PROJECT_SCAFFOLD_SPEC_TSX/src/Button.spec.tsx"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_SPEC_TSX" --no-register --scaffold-tests >/dev/null
assert_not_exists "$PROJECT_SCAFFOLD_SPEC_TSX/tests/smoke.test.ts"

# Re-init profile resolution must match touchstone-run.sh:load_config semantics.
# Two regression cases: (1) last-write-wins across project_type/profile aliases,
# (2) generic promoted to the detected manifest profile.
# (1) project_type=generic then profile=python ->  scaffolder runs python.
PROJECT_SCAFFOLD_ALIAS="$TEST_DIR/test-project-scaffold-alias-lastwins"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_ALIAS" --no-register --type generic >/dev/null
printf 'profile=python\n' >> "$PROJECT_SCAFFOLD_ALIAS/.touchstone-config"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_ALIAS" --no-register --scaffold-tests >/dev/null
assert_exists "$PROJECT_SCAFFOLD_ALIAS/tests/test_smoke.py"

# (2) project_type=generic but pyproject.toml exists -> detect upgrades to python.
PROJECT_SCAFFOLD_PROMOTE="$TEST_DIR/test-project-scaffold-generic-promoted"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_PROMOTE" --no-register --type generic >/dev/null
printf '[project]\nname = "demo"\nversion = "0.0.0"\n' > "$PROJECT_SCAFFOLD_PROMOTE/pyproject.toml"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SCAFFOLD_PROMOTE" --no-register --scaffold-tests >/dev/null
assert_exists "$PROJECT_SCAFFOLD_PROMOTE/tests/test_smoke.py"

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
# No "build" script declared — build_if_distinct must skip to avoid running a
# nonexistent script. Regression guard for "validate runs build unconditionally".
if grep -q 'pnpm|.*/test-project-node|build' "$RUNNER_LOG"; then
  echo "FAIL: touchstone-run.sh validate must not run build when no build script is declared" >&2
  ERRORS=$((ERRORS + 1))
fi

# Node project with BOTH typecheck and build scripts — validate must run build
# so bundler-level errors (import paths, env, CSS modules) get caught before a
# default-branch push, in addition to typecheck.
PROJECT_NODE_BUILD="$TEST_DIR/test-project-node-build"
mkdir -p "$PROJECT_NODE_BUILD/scripts"
cp "$TOUCHSTONE_ROOT/scripts/touchstone-run.sh" "$PROJECT_NODE_BUILD/scripts/touchstone-run.sh"
printf 'project_type=node\n' > "$PROJECT_NODE_BUILD/.touchstone-config"
printf '{"packageManager":"pnpm@9.0.0","scripts":{"lint":"echo lint","typecheck":"echo typecheck","build":"echo build","test":"echo test"}}\n' > "$PROJECT_NODE_BUILD/package.json"
: > "$RUNNER_LOG"
(cd "$PROJECT_NODE_BUILD" && PATH="$RUNNER_FAKE_BIN:$PATH" RUNNER_LOG="$RUNNER_LOG" bash scripts/touchstone-run.sh validate) >/dev/null
assert_contains "$RUNNER_LOG" 'pnpm|.*/test-project-node-build|typecheck'
assert_contains "$RUNNER_LOG" 'pnpm|.*/test-project-node-build|build'
assert_contains "$RUNNER_LOG" 'pnpm|.*/test-project-node-build|test'

# Node project with only build, no typecheck — "build: tsc" style where build
# IS typecheck. validate must not double-run the same command.
PROJECT_NODE_BUILD_ONLY="$TEST_DIR/test-project-node-build-only"
mkdir -p "$PROJECT_NODE_BUILD_ONLY/scripts"
cp "$TOUCHSTONE_ROOT/scripts/touchstone-run.sh" "$PROJECT_NODE_BUILD_ONLY/scripts/touchstone-run.sh"
printf 'project_type=node\n' > "$PROJECT_NODE_BUILD_ONLY/.touchstone-config"
printf '{"packageManager":"pnpm@9.0.0","scripts":{"lint":"echo lint","build":"tsc","test":"echo test"}}\n' > "$PROJECT_NODE_BUILD_ONLY/package.json"
: > "$RUNNER_LOG"
(cd "$PROJECT_NODE_BUILD_ONLY" && PATH="$RUNNER_FAKE_BIN:$PATH" RUNNER_LOG="$RUNNER_LOG" bash scripts/touchstone-run.sh validate) >/dev/null
if grep -q 'pnpm|.*/test-project-node-build-only|build' "$RUNNER_LOG"; then
  echo "FAIL: build should not run during validate when typecheck is absent (build IS typecheck)" >&2
  ERRORS=$((ERRORS + 1))
fi

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
# TOUCHSTONE_SKIP_DEVTOOLS=1 keeps these tests hermetic — we're exercising the
# dependency dispatch, not the per-profile dev-tool install (which would call
# real brew/go/rustup on macOS dev machines that have those binaries on PATH).
: > "$RUNNER_LOG"
(cd "$PROJECT_NODE" && PATH="$RUNNER_FAKE_BIN:$PATH" RUNNER_LOG="$RUNNER_LOG" TOUCHSTONE_SKIP_DEVTOOLS=1 bash setup.sh --deps-only) >/dev/null
assert_contains "$RUNNER_LOG" 'pnpm|.*/test-project-node|install'

cp "$TOUCHSTONE_ROOT/templates/setup.sh" "$SWIFT_PROJECT/setup.sh"
: > "$RUNNER_LOG"
(cd "$SWIFT_PROJECT" && PATH="$RUNNER_FAKE_BIN:$PATH" RUNNER_LOG="$RUNNER_LOG" TOUCHSTONE_SKIP_DEVTOOLS=1 bash setup.sh --deps-only) >/dev/null
assert_contains "$RUNNER_LOG" 'swift|.*/swift-runner|package resolve'

cp "$TOUCHSTONE_ROOT/templates/setup.sh" "$RUST_PROJECT/setup.sh"
: > "$RUNNER_LOG"
(cd "$RUST_PROJECT" && PATH="$RUNNER_FAKE_BIN:$PATH" RUNNER_LOG="$RUNNER_LOG" TOUCHSTONE_SKIP_DEVTOOLS=1 bash setup.sh --deps-only) >/dev/null
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

# Autumn Garage siblings block must appear in doctor --project output on every
# project, regardless of whether cortex/sentinel are installed. Absence is the
# normal case for most users; missing-block would be an orientation regression.
# Skip asserting exact version strings — those are machine-dependent. The
# section header alone proves the code path ran.
assert_contains "$TEST_DIR/doctor-clean.txt" 'Autumn Garage siblings'

# Sibling detection must not error, warn-exit, or block when cortex/sentinel
# are absent from PATH. Simulate a clean machine by pinning PATH to the
# system dirs plus the fake pre-commit hook installer. Use an absolute path
# to touchstone so the CLI is still reachable with the trimmed PATH.
PROJECT_DOCTOR_NO_SIBLINGS="$TEST_DIR/test-project-doctor-no-siblings"
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_DOCTOR_NO_SIBLINGS" --no-register >/dev/null
if (cd "$PROJECT_DOCTOR_NO_SIBLINGS" && PATH="/usr/bin:/bin" TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-no-siblings.txt" 2>&1; then
  assert_contains "$TEST_DIR/doctor-no-siblings.txt" 'Autumn Garage siblings'
  assert_contains "$TEST_DIR/doctor-no-siblings.txt" 'cortex not installed'
  assert_contains "$TEST_DIR/doctor-no-siblings.txt" 'sentinel not installed'
else
  echo "FAIL: doctor --project should exit 0 when Autumn Garage siblings are absent — absence is not a bug" >&2
  ERRORS=$((ERRORS + 1))
fi

# Mixed state — CLI absent but marker directory present — is unusual enough
# that doctor warns and points at the install hint, but still never errors.
# This is the class of failure where a user deleted a brew-installed CLI but
# left its project state behind; a silent pass would hide the drift.
PROJECT_DOCTOR_MARKER_ONLY="$TEST_DIR/test-project-doctor-marker-only"
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_DOCTOR_MARKER_ONLY" --no-register >/dev/null
mkdir -p "$PROJECT_DOCTOR_MARKER_ONLY/.cortex"
if (cd "$PROJECT_DOCTOR_MARKER_ONLY" && PATH="/usr/bin:/bin" TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-marker-only.txt" 2>&1; then
  assert_contains "$TEST_DIR/doctor-marker-only.txt" 'cortex CLI missing but .cortex/ present'
else
  echo "FAIL: doctor --project should exit 0 when a sibling CLI is missing but its marker dir is present — still non-blocking" >&2
  ERRORS=$((ERRORS + 1))
fi

# Installed case — a sibling CLI on PATH must be reported as "(installed)".
# Use a stub script so the test is deterministic across machines. The stub
# responds to both `version` and `--version` so the probe-fallback branch
# doesn't accidentally pass on the wrong probe — either convention is valid.
SIBLING_STUB_BIN="$TEST_DIR/sibling-stub-bin"
mkdir -p "$SIBLING_STUB_BIN"
cat > "$SIBLING_STUB_BIN/cortex" <<'CORTEXSTUB'
#!/usr/bin/env bash
case "${1:-}" in
  version|--version) echo "cortex 9.9.9"; exit 0 ;;
  *) echo "stub cortex"; exit 0 ;;
esac
CORTEXSTUB
chmod +x "$SIBLING_STUB_BIN/cortex"
cat > "$SIBLING_STUB_BIN/sentinel" <<'SENTINELSTUB'
#!/usr/bin/env bash
case "${1:-}" in
  version) echo "Error: no such command" >&2; exit 2 ;;
  --version) echo "sentinel, version 8.8.8"; exit 0 ;;
  *) echo "stub sentinel"; exit 0 ;;
esac
SENTINELSTUB
chmod +x "$SIBLING_STUB_BIN/sentinel"

PROJECT_DOCTOR_SIBLINGS="$TEST_DIR/test-project-doctor-with-siblings"
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_DOCTOR_SIBLINGS" --no-register >/dev/null
if (cd "$PROJECT_DOCTOR_SIBLINGS" && PATH="$SIBLING_STUB_BIN:/usr/bin:/bin" TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-with-siblings.txt" 2>&1; then
  assert_contains "$TEST_DIR/doctor-with-siblings.txt" 'cortex 9.9.9 (installed)'
  # Sentinel only responds to --version — asserts the probe-fallback works.
  assert_contains "$TEST_DIR/doctor-with-siblings.txt" 'sentinel 8.8.8 (installed)'
else
  echo "FAIL: doctor --project should exit 0 when Autumn Garage siblings are installed and reply with a version" >&2
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

# doctor shares the test-presence heuristic with --scaffold-tests — the same
# "dir exists != tests exist" class bug applies. An empty tests/ directory
# (or one with only __init__.py) must not be reported as "tests: found".
PROJECT_DOCTOR_EMPTY_PY="$TEST_DIR/test-project-doctor-empty-python"
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_DOCTOR_EMPTY_PY" --no-register --type python >/dev/null
mkdir -p "$PROJECT_DOCTOR_EMPTY_PY/tests"
: > "$PROJECT_DOCTOR_EMPTY_PY/tests/__init__.py"
RUFF_STUB_EMPTY_PY="$TEST_DIR/ruff-stub-empty-py"
mkdir -p "$RUFF_STUB_EMPTY_PY"
cat > "$RUFF_STUB_EMPTY_PY/ruff" <<'RUFFSTUBEMPTYPY'
#!/usr/bin/env bash
exit 0
RUFFSTUBEMPTYPY
chmod +x "$RUFF_STUB_EMPTY_PY/ruff"
(cd "$PROJECT_DOCTOR_EMPTY_PY" && PATH="$RUFF_STUB_EMPTY_PY:$PATH" TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-empty-py.txt" 2>&1 || true
if grep -q "tests: found for profile 'python'" "$TEST_DIR/doctor-empty-py.txt"; then
  echo "FAIL: doctor must not report 'tests: found' when only tests/__init__.py exists" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$TEST_DIR/doctor-empty-py.txt" "tests: not found for profile 'python'"

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

# touchstone-run.sh's load_config treats project_type and profile as the same
# slot with last-write-wins semantics. Doctor must select the same profile
# the runner would, so a config with both keys must resolve to the final one.
PROJECT_DOCTOR_ALIAS_KEY="$TEST_DIR/test-project-doctor-alias-key"
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_DOCTOR_ALIAS_KEY" --no-register --type python >/dev/null
# Prepend a stale project_type=generic and keep the real profile=python after it
# to exercise the last-write-wins tie-breaker.
sed -i '' 's|^project_type=.*|project_type=generic|' "$PROJECT_DOCTOR_ALIAS_KEY/.touchstone-config"
printf 'profile=python\n' >> "$PROJECT_DOCTOR_ALIAS_KEY/.touchstone-config"
if PATH="/usr/bin:/bin" command -v ruff >/dev/null 2>&1; then
  echo "SKIP: ruff on minimal PATH; cannot test project_type/profile last-wins doctor case on this machine" >&2
else
  if (cd "$PROJECT_DOCTOR_ALIAS_KEY" && PATH="/usr/bin:/bin" TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-alias-key.txt" 2>&1; then
    echo "FAIL: doctor --project on a Python-via-profile= project with no ruff should exit nonzero" >&2
    ERRORS=$((ERRORS + 1))
  else
    # The later "profile=python" must win over "project_type=generic"; missing
    # ruff should fire, not a generic-profile no-op.
    assert_contains "$TEST_DIR/doctor-alias-key.txt" 'ruff not on PATH'
    if grep -q "profile 'generic'" "$TEST_DIR/doctor-alias-key.txt"; then
      echo "FAIL: doctor selected generic when last-write-wins should have selected python" >&2
      ERRORS=$((ERRORS + 1))
    fi
  fi
fi

# Unknown root profile: touchstone-run.sh returns an error for project_type
# values outside the dispatcher's accepted set. doctor must flag the same —
# otherwise a typo like project_type=kotlin would silently pass doctor while
# pre-push failed for every dev on the team.
PROJECT_DOCTOR_BAD_PROFILE="$TEST_DIR/test-project-doctor-bad-profile"
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_DOCTOR_BAD_PROFILE" --no-register >/dev/null
sed -i '' 's|^project_type=.*|project_type=kotlin|' "$PROJECT_DOCTOR_BAD_PROFILE/.touchstone-config"
if (cd "$PROJECT_DOCTOR_BAD_PROFILE" && TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-bad-profile.txt" 2>&1; then
  echo "FAIL: doctor --project should exit nonzero when project_type is not a dispatcher-accepted profile" >&2
  ERRORS=$((ERRORS + 1))
else
  assert_contains "$TEST_DIR/doctor-bad-profile.txt" "unknown project_type 'kotlin'"
fi

# Unknown target profile: same rule at the target level. touchstone-run.sh's
# run_profile_action returns 1 on an unknown target profile, so doctor flags it.
PROJECT_DOCTOR_BAD_TARGET="$TEST_DIR/test-project-doctor-bad-target"
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_DOCTOR_BAD_TARGET" --no-register >/dev/null
mkdir -p "$PROJECT_DOCTOR_BAD_TARGET/apps/mobile"
sed -i '' 's|^targets=.*|targets=mobile:apps/mobile:kotlin|' "$PROJECT_DOCTOR_BAD_TARGET/.touchstone-config"
if (cd "$PROJECT_DOCTOR_BAD_TARGET" && TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-bad-target.txt" 2>&1; then
  echo "FAIL: doctor --project should exit nonzero when a target profile is unknown" >&2
  ERRORS=$((ERRORS + 1))
else
  assert_contains "$TEST_DIR/doctor-bad-target.txt" "target 'mobile': unknown profile 'kotlin'"
fi

# Auto-detected targets (apps/packages/services exist on disk but .touchstone-config
# targets= is empty) must NOT cause per-target doctor checks — touchstone-run.sh's
# run_targets_action requires config-loaded TARGETS to dispatch, so anything
# doctor checks beyond the root profile would be gaps validate never exercises.
PROJECT_DOCTOR_AUTO_TARGETS="$TEST_DIR/test-project-doctor-auto-targets"
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_DOCTOR_AUTO_TARGETS" --no-register >/dev/null
mkdir -p "$PROJECT_DOCTOR_AUTO_TARGETS/apps/web" "$PROJECT_DOCTOR_AUTO_TARGETS/services/api"
printf '{}\n' > "$PROJECT_DOCTOR_AUTO_TARGETS/apps/web/package.json"
printf '[package]\nname = "api"\nversion = "0.0.0"\n' > "$PROJECT_DOCTOR_AUTO_TARGETS/services/api/Cargo.toml"
# Leave targets= empty in .touchstone-config — new-project.sh only fills it when
# the apps/services dirs exist at bootstrap time.
if (cd "$PROJECT_DOCTOR_AUTO_TARGETS" && TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-auto-targets.txt" 2>&1; then
  if grep -q 'target web:\|target api:' "$TEST_DIR/doctor-auto-targets.txt"; then
    echo "FAIL: doctor must not emit per-target lines when .touchstone-config targets= is empty — runner won't dispatch those" >&2
    ERRORS=$((ERRORS + 1))
  fi
else
  echo "FAIL: doctor --project should exit 0 on a clean project even with auto-detected target dirs" >&2
  ERRORS=$((ERRORS + 1))
fi

# Root profile aliases: touchstone-run.sh accepts project_type=typescript / ts
# as equivalent to node, so doctor must normalize the same way — otherwise a
# root config using the alias would silently skip the lint-script check.
PROJECT_DOCTOR_ALIAS="$TEST_DIR/test-project-doctor-alias"
PATH="$HOOKS_FAKE_BIN:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_DOCTOR_ALIAS" --no-register >/dev/null
printf '{}\n' > "$PROJECT_DOCTOR_ALIAS/package.json"
sed -i '' 's|^project_type=.*|project_type=typescript|' "$PROJECT_DOCTOR_ALIAS/.touchstone-config"
if (cd "$PROJECT_DOCTOR_ALIAS" && TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" doctor --project) >"$TEST_DIR/doctor-alias.txt" 2>&1; then
  # No lint script in package.json — the node-profile lint-script check must fire,
  # not a literal 'typescript' profile branch that would no-op.
  assert_contains "$TEST_DIR/doctor-alias.txt" "package.json has no 'lint' script"
  if grep -q "profile 'typescript'" "$TEST_DIR/doctor-alias.txt"; then
    echo "FAIL: doctor should normalize 'typescript' to 'node' before profile checks" >&2
    ERRORS=$((ERRORS + 1))
  fi
else
  assert_contains "$TEST_DIR/doctor-alias.txt" "package.json has no 'lint' script"
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
# works on CI machines without a global Git identity. Bootstrap already creates an
# initial touchstone commit, so we don't need to seed one here.
git -C "$PROJECT_OUTDATED" config user.email test@touchstone
git -C "$PROJECT_OUTDATED" config user.name test-committer
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

# ---------------------------------------------------------------------------
# Doctrine 0002 — interactive wizard for `touchstone new`.
# The wizard is additive: non-TTY invocations behave exactly as pre-R2 (modulo
# new flags being available if passed). `--yes` accepts all defaults without
# prompting. The "Equivalent to rerun:" block prints the flag-form so the user
# can copy-paste to scaffold exactly the same project again.
# ---------------------------------------------------------------------------

PROJECT_WIZARD_YES="$TEST_DIR/test-project-wizard-yes"
# Force cortex/sentinel off so the test doesn't depend on whether the sibling
# CLIs are on PATH (they default to yes when detected).
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_WIZARD_YES" \
  --yes --no-register --no-with-cortex --no-with-sentinel --no-github \
  >"$TEST_DIR/wizard-yes.txt" 2>&1 || {
    echo "FAIL: --yes bootstrap exited nonzero" >&2
    ERRORS=$((ERRORS + 1))
  }

# --yes must print the "Equivalent to rerun" block so scripters learn flags.
assert_contains "$TEST_DIR/wizard-yes.txt" 'Equivalent to rerun:'
assert_contains "$TEST_DIR/wizard-yes.txt" '--no-register'
assert_contains "$TEST_DIR/wizard-yes.txt" '--no-with-cortex'
assert_contains "$TEST_DIR/wizard-yes.txt" '--no-with-sentinel'
assert_contains "$TEST_DIR/wizard-yes.txt" '--initial-commit'
assert_contains "$TEST_DIR/wizard-yes.txt" '--no-github'

# --yes with --with-cortex / --with-sentinel / --github-public must be reflected
# in the equivalent-to-rerun printout even when the underlying tool isn't present.
PROJECT_WIZARD_YES_FLAGS="$TEST_DIR/test-project-wizard-yes-flags"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_WIZARD_YES_FLAGS" --yes --no-register \
  --with-cortex --with-sentinel --github-public \
  >"$TEST_DIR/wizard-yes-flags.txt" 2>&1 || true
assert_contains "$TEST_DIR/wizard-yes-flags.txt" '--with-cortex'
assert_contains "$TEST_DIR/wizard-yes-flags.txt" '--with-sentinel'
assert_contains "$TEST_DIR/wizard-yes-flags.txt" '--github-public'

# Non-TTY run (no --yes, no TTY) must not print the wizard block. Structure
# must match pre-R2 behavior: .touchstone-version exists, registry skipped, etc.
PROJECT_WIZARD_NON_TTY="$TEST_DIR/test-project-wizard-non-tty"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_WIZARD_NON_TTY" --no-register \
  </dev/null >"$TEST_DIR/wizard-non-tty.txt" 2>&1 || {
    echo "FAIL: non-TTY bootstrap exited nonzero" >&2
    ERRORS=$((ERRORS + 1))
  }
if grep -q 'Equivalent to rerun:' "$TEST_DIR/wizard-non-tty.txt" 2>/dev/null; then
  echo "FAIL: non-TTY bootstrap must not print the wizard 'Equivalent to rerun' block" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_exists "$PROJECT_WIZARD_NON_TTY/.touchstone-version"
assert_exists "$PROJECT_WIZARD_NON_TTY/CLAUDE.md"
# Non-TTY must still substitute {{PROJECT_NAME}} (pre-R2 invariant).
if grep -q '{{PROJECT_NAME}}' "$PROJECT_WIZARD_NON_TTY/CLAUDE.md" 2>/dev/null; then
  echo "FAIL: non-TTY wizard must still substitute {{PROJECT_NAME}}" >&2
  ERRORS=$((ERRORS + 1))
fi

# --yes with all defaults must produce the same filesystem shape as a
# flag-driven invocation with the same choices (baseline parity check). We
# force cortex/sentinel/github off in both runs so the test is deterministic
# regardless of whether those sibling CLIs happen to be installed on the
# host — presence of `cortex` or `sentinel` on PATH would otherwise side-effect
# the tree and make the diff flap by environment.
PROJECT_YES_BASELINE="$TEST_DIR/test-project-yes-baseline"
PROJECT_FLAGS_BASELINE="$TEST_DIR/test-project-flags-baseline"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_YES_BASELINE" \
  --yes --no-register --no-with-cortex --no-with-sentinel --no-github \
  >"$TEST_DIR/yes-baseline.txt" 2>&1
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_FLAGS_BASELINE" \
  --no-register --no-with-cortex --no-with-sentinel --no-github --initial-commit \
  </dev/null >"$TEST_DIR/flags-baseline.txt" 2>&1
# Diff the tree listings (filenames only, .git excluded) — same structure
# expected. We compare sorted relative paths, which is stable across runs.
( cd "$PROJECT_YES_BASELINE" && find . -type f -not -path './.git/*' | sort ) >"$TEST_DIR/yes-tree.txt"
( cd "$PROJECT_FLAGS_BASELINE" && find . -type f -not -path './.git/*' | sort ) >"$TEST_DIR/flags-tree.txt"
if ! diff -q "$TEST_DIR/yes-tree.txt" "$TEST_DIR/flags-tree.txt" >/dev/null 2>&1; then
  echo "FAIL: --yes tree differs from equivalent flag-driven tree" >&2
  diff "$TEST_DIR/yes-tree.txt" "$TEST_DIR/flags-tree.txt" >&2 || true
  ERRORS=$((ERRORS + 1))
fi

# --no-initial-commit must skip the initial commit so no HEAD exists.
PROJECT_NO_COMMIT="$TEST_DIR/test-project-no-commit"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_NO_COMMIT" --no-register --no-initial-commit \
  </dev/null >"$TEST_DIR/no-commit.txt" 2>&1
if git -C "$PROJECT_NO_COMMIT" rev-parse --verify HEAD >/dev/null 2>&1; then
  echo "FAIL: --no-initial-commit must skip the initial commit" >&2
  ERRORS=$((ERRORS + 1))
fi

# --skip-language-scaffold with --type swift must not write Package.swift.
PROJECT_SKIP_LANG="$TEST_DIR/test-project-skip-lang"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SKIP_LANG" --no-register \
  --type swift --skip-language-scaffold \
  </dev/null >"$TEST_DIR/skip-lang.txt" 2>&1
assert_not_exists "$PROJECT_SKIP_LANG/Package.swift"
assert_not_exists "$PROJECT_SKIP_LANG/Sources"

# Existing --type swift without the flag still scaffolds Package.swift (regression guard).
PROJECT_SWIFT_DEFAULT="$TEST_DIR/test-project-swift-default"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_SWIFT_DEFAULT" --no-register \
  --type swift \
  </dev/null >"$TEST_DIR/swift-default.txt" 2>&1
assert_exists "$PROJECT_SWIFT_DEFAULT/Package.swift"

# --register (explicit opt-in) must also be accepted and set up registry entry.
PROJECT_REGISTER="$TEST_DIR/test-project-register-explicit"
REGISTRY_TMP="$(mktemp -d -t touchstone-registry.XXXXXX)"
HOME="$REGISTRY_TMP" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_REGISTER" --register \
  </dev/null >"$TEST_DIR/register.txt" 2>&1
assert_exists "$REGISTRY_TMP/.touchstone-projects"
assert_contains "$REGISTRY_TMP/.touchstone-projects" "$PROJECT_REGISTER"
# Registry write must be visible: a silent append to ~/.touchstone-projects
# loses the audit trail that motivates opt-in being the default. The line must
# also name the opt-out flag so the next run doesn't need to grep docs for it.
assert_contains "$TEST_DIR/register.txt" '==> Registered in .*\.touchstone-projects'
assert_contains "$TEST_DIR/register.txt" '--no-register'
rm -rf "$REGISTRY_TMP"

# --no-register must print the visible skip line so the opt-out is auditable.
# The scaffold summary already includes "registry: skipped (--no-register)" in
# its trailing block; this assertion pins the dedicated log line that fires at
# the moment the registry decision is made.
PROJECT_REGISTER_SKIP="$TEST_DIR/test-project-register-skip"
REGISTRY_SKIP_TMP="$(mktemp -d -t touchstone-registry-skip.XXXXXX)"
HOME="$REGISTRY_SKIP_TMP" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_REGISTER_SKIP" --no-register \
  </dev/null >"$TEST_DIR/register-skip.txt" 2>&1
assert_not_exists "$REGISTRY_SKIP_TMP/.touchstone-projects"
assert_contains "$TEST_DIR/register-skip.txt" '==> Registry skipped (--no-register)'
rm -rf "$REGISTRY_SKIP_TMP"

# --------------------------------------------------------------------------
# R5.1 — `--with-cortex --with-sentinel` must fold integration artifacts
# into the same initial commit as the base scaffold. Before R5.1, cortex
# and sentinel init ran AFTER the initial commit, leaving .cortex/ and
# .sentinel/ uncommitted and the user forced to make a second commit on
# main (which `no-commit-to-branch` then blocks). This test stubs both
# CLIs with deterministic behavior and asserts the resulting repo has
# exactly ONE commit that captures every integration-authored file.
#
# R5.2 — the touchstone-shipped .gitignore must NOT blanket-ignore
# .sentinel/ at the project root. Sentinel's own .sentinel/.gitignore
# (written by `sentinel init`) handles the ephemeral state/ exclusion;
# blanket-ignoring defeats that design. The test asserts `.claude/` is
# still ignored (it's Claude Code's per-user cache).
# --------------------------------------------------------------------------

echo ""
echo "==> R5.1/R5.2: --with-cortex --with-sentinel ordering + gitignore scope"

PROJECT_R5="$TEST_DIR/test-project-r5"
R5_STUBDIR="$(mktemp -d -t touchstone-r5-stubs.XXXXXX)"

# Fake cortex CLI: creates `.cortex/` with a tracked marker file, exactly the
# shape the R5.1 fix needs captured in the initial commit.
cat > "$R5_STUBDIR/cortex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  init)
    mkdir -p .cortex/doctrine .cortex/plans .cortex/journal
    : > .cortex/state.md
    : > .cortex/README.md
    echo "cortex init (stub): created .cortex/"
    ;;
  *)
    echo "cortex stub: unrecognized arg '${1:-}'" >&2; exit 2 ;;
esac
STUB
chmod +x "$R5_STUBDIR/cortex"

# Fake sentinel CLI: creates `.sentinel/` with a config + its own gitignore,
# appends a `.claude/` entry to the project's root .gitignore (NOT `.sentinel/`
# — that's R5.2), AND attempts its own `git commit -- .gitignore` when inside
# a git repo. The real sentinel init does this to survive `sentinel work`'s
# between-item `git reset --hard`; the stub mirrors it so the R5.1
# atomicity assertion below properly exercises the "sentinel committed
# first" code path in bootstrap/new-project.sh.
cat > "$R5_STUBDIR/sentinel" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  init)
    mkdir -p .sentinel
    : > .sentinel/config.toml
    printf 'state/\n' > .sentinel/.gitignore
    # Note: we intentionally do NOT append `.sentinel/` to the root
    # .gitignore here — R5.2 says touchstone must not blanket-ignore
    # .sentinel/ at the root. Touchstone itself never writes that block
    # (sentinel does, in its own init), so the stub mirrors that split.
    if [ -f .gitignore ] && ! grep -q '^\.claude/$' .gitignore 2>/dev/null; then
      printf '\n# sentinel artifacts — generated per-run, not source\n.claude/\n' >> .gitignore
      # Mirror real sentinel's `_commit_gitignore_if_in_repo` so the
      # touchstone bootstrap is tested against the "integration already
      # made a commit" shape, not just the "integration dirtied the
      # working tree" shape.
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git add -- .gitignore >/dev/null 2>&1 || true
        git -c user.email=sentinel@test -c user.name=sentinel \
          commit -m "chore: gitignore sentinel artifacts (.claude/)" \
          -- .gitignore >/dev/null 2>&1 || true
      fi
    fi
    echo "sentinel init (stub): created .sentinel/"
    ;;
  *)
    echo "sentinel stub: unrecognized arg '${1:-}'" >&2; exit 2 ;;
esac
STUB
chmod +x "$R5_STUBDIR/sentinel"

PATH="$R5_STUBDIR:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" \
  "$PROJECT_R5" --no-register --with-cortex --with-sentinel \
  </dev/null >"$TEST_DIR/r5-bootstrap.txt" 2>&1 \
  || { echo "FAIL: bootstrap with --with-cortex --with-sentinel exited non-zero"; cat "$TEST_DIR/r5-bootstrap.txt"; ERRORS=$((ERRORS+1)); }

# R5.1 assertions: the integration outputs and the scaffold land in one commit.
assert_exists "$PROJECT_R5/.cortex"
assert_exists "$PROJECT_R5/.sentinel"

if [ -d "$PROJECT_R5/.git" ]; then
  # Exactly one commit on the branch — no "half-committed" follow-up.
  commit_count="$(git -C "$PROJECT_R5" rev-list --count HEAD 2>/dev/null || echo 0)"
  if [ "$commit_count" != "1" ]; then
    echo "FAIL: expected 1 commit after --with-cortex --with-sentinel scaffold, got $commit_count" >&2
    git -C "$PROJECT_R5" log --oneline >&2 || true
    ERRORS=$((ERRORS+1))
  fi

  # Every integration-authored file must be in the initial commit's tree.
  # `git log --all --raw` on a one-commit repo shows every path touched.
  tracked="$(git -C "$PROJECT_R5" log --all --name-only --pretty=format: 2>/dev/null | sort -u)"
  for path in .cortex/state.md .cortex/README.md .sentinel/config.toml .sentinel/.gitignore .gitignore; do
    if ! printf '%s\n' "$tracked" | grep -qxF "$path"; then
      echo "FAIL: expected $path to be tracked in the initial commit; got:" >&2
      printf '%s\n' "$tracked" >&2
      ERRORS=$((ERRORS+1))
    fi
  done

  # Working tree must be clean — no leftover untracked artifacts.
  if [ -n "$(git -C "$PROJECT_R5" status --porcelain 2>/dev/null)" ]; then
    echo "FAIL: working tree dirty after scaffold:" >&2
    git -C "$PROJECT_R5" status --porcelain >&2
    ERRORS=$((ERRORS+1))
  fi
fi

# R5.1 regression guard: running the scaffold against a directory that
# ALREADY has a git repo + user-authored commit must never rewrite that
# commit, never sweep unrelated pending changes into a touchstone commit,
# and never create a "chore: initial touchstone scaffold" commit at all.
# The initial-commit path is scoped to fresh scaffolds — the
# PRE_INTEGRATION_HEAD capture gates it, so an existing repo gets no
# auto-commit from touchstone (same as pre-R5 behavior).
PROJECT_R5_EXISTING="$TEST_DIR/test-project-r5-existing-history"
mkdir -p "$PROJECT_R5_EXISTING"
( cd "$PROJECT_R5_EXISTING" \
  && git init -q -b main \
  && git config user.email "u@test" \
  && git config user.name "User" \
  && echo "# prior work" > README.md \
  && git add README.md \
  && git commit -q -m "feat: user's own initial commit" \
  && echo "dirty-unrelated" > WIP.txt ) \
  >/dev/null 2>&1
USER_HEAD_BEFORE="$(git -C "$PROJECT_R5_EXISTING" rev-parse HEAD 2>/dev/null || echo missing)"
USER_SUBJECT_BEFORE="$(git -C "$PROJECT_R5_EXISTING" log -1 --pretty=%s HEAD 2>/dev/null || echo missing)"

PATH="$R5_STUBDIR:$PATH" bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" \
  "$PROJECT_R5_EXISTING" --no-register --with-cortex --with-sentinel \
  </dev/null >"$TEST_DIR/r5-existing-bootstrap.txt" 2>&1 \
  || { echo "FAIL: bootstrap into existing git repo exited non-zero"; cat "$TEST_DIR/r5-existing-bootstrap.txt"; ERRORS=$((ERRORS+1)); }

# The user's commit SHA must still be reachable (not rewritten).
if ! git -C "$PROJECT_R5_EXISTING" cat-file -e "$USER_HEAD_BEFORE" 2>/dev/null; then
  echo "FAIL: touchstone scaffold rewrote user's pre-existing commit $USER_HEAD_BEFORE" >&2
  ERRORS=$((ERRORS+1))
fi

# The user's commit must still be the first commit on the branch.
first_subject="$(git -C "$PROJECT_R5_EXISTING" log --reverse --pretty=%s 2>/dev/null | head -1)"
if [ "$first_subject" != "$USER_SUBJECT_BEFORE" ]; then
  echo "FAIL: first commit subject changed from '$USER_SUBJECT_BEFORE' to '$first_subject'" >&2
  ERRORS=$((ERRORS+1))
fi

# No "chore: initial touchstone scaffold" commit should exist — that message
# is reserved for fresh scaffolds. Touchstone files are simply added to the
# worktree; the user commits them when they're ready.
if git -C "$PROJECT_R5_EXISTING" log --pretty=%s 2>/dev/null | grep -qxF 'chore: initial touchstone scaffold'; then
  echo "FAIL: touchstone created an initial-scaffold commit on a pre-existing repo" >&2
  git -C "$PROJECT_R5_EXISTING" log --oneline >&2 || true
  ERRORS=$((ERRORS+1))
fi

# The user's pre-existing WIP file must still be untracked-and-unstaged —
# i.e., touchstone must not have silently `git add -A`'d it into any index.
# (Cortex/sentinel stubs may have made their own commits; that's their
# contract. What touchstone itself must not do is sweep the user's tree.)
wip_status="$(git -C "$PROJECT_R5_EXISTING" status --porcelain WIP.txt 2>/dev/null || true)"
case "$wip_status" in
  '?? WIP.txt') : ;;                         # correct — still untracked
  *)
    echo "FAIL: touchstone staged/committed user's WIP.txt (status: '$wip_status')" >&2
    ERRORS=$((ERRORS+1))
    ;;
esac

# R5.2 assertions: the root .gitignore must NOT blanket-ignore .sentinel/.
# `.claude/` should still be present (the stub mirrors sentinel's real write).
if [ -f "$PROJECT_R5/.gitignore" ]; then
  if grep -qxF '.sentinel/' "$PROJECT_R5/.gitignore"; then
    echo "FAIL: root .gitignore contains '.sentinel/' — R5.2 regression" >&2
    ERRORS=$((ERRORS+1))
  fi
  assert_contains "$PROJECT_R5/.gitignore" '^\.claude/$'
fi

rm -rf "$R5_STUBDIR"

echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: all assertions passed"
  exit 0
else
  echo "==> FAIL: $ERRORS assertion(s) failed"
  exit 1
fi
