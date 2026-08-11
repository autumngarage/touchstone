#!/usr/bin/env bash
#
# tests/test-update.sh — verify update-project.sh handles updates correctly.
#
set -euo pipefail

# Doctrine 0002: ensure all bootstrap/update calls run non-interactively.
exec </dev/null

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-update.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

# Hermeticity: redirect HOME so user-scoped skill install (lib/install-skills.sh)
# writes to the test sandbox, not the developer's real ~/.claude/skills/.
TEST_FAKE_HOME="$TEST_DIR/fake-home"
mkdir -p "$TEST_FAKE_HOME"
export HOME="$TEST_FAKE_HOME"

echo "==> Test: update an existing project"
echo "    Test dir: $TEST_DIR/test-project"

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

configure_git() {
  local repo="$1"
  git -C "$repo" config user.email "touchstone-test@example.com"
  git -C "$repo" config user.name "Touchstone Test"
}

commit_all() {
  local repo="$1"
  local message="$2"
  git -C "$repo" add -A
  # Skip the commit when there's nothing staged — new-project.sh now creates an
  # initial commit during bootstrap, so the test helper must not error out when
  # the tree is already clean.
  if [ -n "$(git -C "$repo" status --porcelain)" ] \
    || ! git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "$repo" commit --no-verify -m "$message" >/dev/null
  fi
}

# Fast-forward the base branch over the chore/touchstone-* branch a
# branch-creating update left checked out. Updates refuse non-default
# checkouts (#772), so multi-update flows must return to base between runs.
return_to_base_branch() {
  local repo="$1"
  local base="$2"
  local update_branch
  update_branch="$(git -C "$repo" branch --show-current)"
  git -C "$repo" checkout -q "$base"
  git -C "$repo" merge -q --ff-only "$update_branch"
}

PROJECT="$TEST_DIR/test-project"

# --------------------------------------------------------------------------
# Setup: bootstrap a project and commit the initial state.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 1: Bootstrap ---"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT" --no-register
configure_git "$PROJECT"
printf '#!/usr/bin/env bash\nexit 0\n' >"$PROJECT/scripts/project-owned.sh"
chmod 644 "$PROJECT/scripts/project-owned.sh"
commit_all "$PROJECT" "initial touchstone project"

BASE_BRANCH="$(git -C "$PROJECT" rev-parse --abbrev-ref HEAD)"
INITIAL_SHA="$(cat "$PROJECT/.touchstone-version" | tr -d '[:space:]')"
echo "    Initial .touchstone-version: $INITIAL_SHA"

# --------------------------------------------------------------------------
# Test 1: update with no touchstone changes -> "already up to date"
# --------------------------------------------------------------------------
echo ""
echo "--- Step 2: Update with no changes (should report up to date) ---"
(cd "$PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") 2>&1 | tee "$TEST_DIR/update-output-1.txt"

if grep -q "Already up to date" "$TEST_DIR/update-output-1.txt"; then
  echo "    PASS: correctly reported up to date"
else
  echo "    FAIL: did not report up to date" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$(git -C "$PROJECT" rev-parse --abbrev-ref HEAD)" != "$BASE_BRANCH" ]; then
  echo "FAIL: up-to-date update should not create or switch branches" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 1b: retired review shims require one explicit project-owned migration.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 2b: Remove retired managed review helpers ---"

RETIREMENT_PROJECT="$TEST_DIR/retirement-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$RETIREMENT_PROJECT" --no-register >/dev/null
configure_git "$RETIREMENT_PROJECT"
printf '#!/usr/bin/env bash\necho legacy local router\n' >"$RETIREMENT_PROJECT/scripts/conductor-review.sh"
printf '#!/usr/bin/env bash\necho legacy local router\n' >"$RETIREMENT_PROJECT/scripts/codex-review.sh"
chmod +x \
  "$RETIREMENT_PROJECT/scripts/conductor-review.sh" \
  "$RETIREMENT_PROJECT/scripts/codex-review.sh"
printf '# retired helper\n' >"$RETIREMENT_PROJECT/lib/review-comment.sh"
# Journal hook retired with the Cortex pause (issue #730): a project that
# still carries the previously managed copy must have it removed, and its
# manifest entry dropped, by a single update run.
printf '# retired journal hook\n' >"$RETIREMENT_PROJECT/scripts/cortex-pr-merged-hook.sh"
printf 'scripts/conductor-review.sh\r\nscripts/codex-review.sh\r\nlib/review-comment.sh\nscripts/cortex-pr-merged-hook.sh\n' >>"$RETIREMENT_PROJECT/.touchstone-manifest"
awk 'BEGIN { for (i = 0; i < 10000; i++) printf "legacy/extra/%d\n", i }' \
  >>"$RETIREMENT_PROJECT/.touchstone-manifest"
cat >"$RETIREMENT_PROJECT/.pre-commit-config.yaml" <<'EOF_RETIRED_REVIEW_HOOKS'
repos:
  - repo: local
    hooks:
      - id: conductor-review
        entry: bash scripts/conductor-review.sh
        language: system
EOF_RETIRED_REVIEW_HOOKS
mkdir -p "$HOME/.claude/skills/conductor-delegation"
printf 'retired skill\n' >"$HOME/.claude/skills/conductor-delegation/SKILL.md"
PREVIOUS_TOUCHSTONE_SHA="$(git -C "$TOUCHSTONE_ROOT" rev-parse HEAD^)"
printf '%s\n' "$PREVIOUS_TOUCHSTONE_SHA" >"$RETIREMENT_PROJECT/.touchstone-version"
commit_all "$RETIREMENT_PROJECT" "simulate project with retired review helpers"

(cd "$RETIREMENT_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --in-place) \
  >"$TEST_DIR/update-retirement-blocked.txt" 2>&1 \
  && {
    echo "FAIL: update should block until project-owned review hooks and shims are removed" >&2
    exit 1
  }

assert_exists "$RETIREMENT_PROJECT/scripts/conductor-review.sh"
assert_exists "$RETIREMENT_PROJECT/scripts/codex-review.sh"
assert_contains "$RETIREMENT_PROJECT/scripts/conductor-review.sh" 'legacy local router'
assert_contains "$RETIREMENT_PROJECT/scripts/codex-review.sh" 'legacy local router'
assert_contains "$TEST_DIR/update-retirement-blocked.txt" 'Retired local review shims require a project-owned migration'
assert_contains "$TEST_DIR/update-retirement-blocked.txt" 'remove the same entries'
assert_contains "$TEST_DIR/update-retirement-blocked.txt" 'from .touchstone-manifest'

if ! (cd "$RETIREMENT_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --dry-run) \
  >"$TEST_DIR/update-retirement-dry-run.txt" 2>&1; then
  echo "FAIL: dry-run should report the migration blocker without failing" >&2
  exit 1
fi
assert_contains "$TEST_DIR/update-retirement-dry-run.txt" '^WARNING: Retired local review shims'
assert_not_contains "$TEST_DIR/update-retirement-dry-run.txt" '^ERROR:'
assert_contains "$TEST_DIR/update-retirement-dry-run.txt" '^==> Updating touchstone-owned files:'
assert_contains "$TEST_DIR/update-retirement-dry-run.txt" '^==> Summary:'

if (cd "$RETIREMENT_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --check) \
  >"$TEST_DIR/update-retirement-check.txt" 2>&1; then
  echo "FAIL: check mode should fail while review shim migration blocks synchronization" >&2
  exit 1
fi
assert_contains "$TEST_DIR/update-retirement-check.txt" '^ERROR: Retired local review shims'

rm "$RETIREMENT_PROJECT/scripts/conductor-review.sh" "$RETIREMENT_PROJECT/scripts/codex-review.sh"
cat >"$RETIREMENT_PROJECT/.pre-commit-config.yaml" <<'EOF_RETIRED_REVIEW_HOOKS_REMOVED'
repos: []
EOF_RETIRED_REVIEW_HOOKS_REMOVED
tr -d '\r' <"$RETIREMENT_PROJECT/.touchstone-manifest" \
  | sed '/^scripts\/conductor-review\.sh$/d; /^scripts\/codex-review\.sh$/d' \
    >"$RETIREMENT_PROJECT/.touchstone-manifest.tmp"
mv "$RETIREMENT_PROJECT/.touchstone-manifest.tmp" "$RETIREMENT_PROJECT/.touchstone-manifest"
commit_all "$RETIREMENT_PROJECT" "remove project-owned review hooks and shims"

(cd "$RETIREMENT_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --in-place) \
  >"$TEST_DIR/update-retirement-output.txt" 2>&1

assert_not_exists "$RETIREMENT_PROJECT/scripts/conductor-review.sh"
assert_not_exists "$RETIREMENT_PROJECT/scripts/codex-review.sh"
assert_not_contains "$RETIREMENT_PROJECT/.touchstone-manifest" '^scripts/conductor-review\.sh$'
assert_not_contains "$RETIREMENT_PROJECT/.touchstone-manifest" '^scripts/codex-review\.sh$'
assert_not_exists "$RETIREMENT_PROJECT/lib/review-comment.sh"
assert_not_exists "$RETIREMENT_PROJECT/scripts/cortex-pr-merged-hook.sh"
assert_not_contains "$RETIREMENT_PROJECT/.touchstone-manifest" '^scripts/cortex-pr-merged-hook\.sh$'
assert_not_exists "$HOME/.claude/skills/conductor-delegation"
assert_exists "$HOME/.claude/skills/.touchstone-retired/conductor-delegation/SKILL.md"
assert_contains "$HOME/.claude/skills/.touchstone-retired/conductor-delegation/SKILL.md" 'retired skill'
assert_contains "$TEST_DIR/update-retirement-output.txt" 'removed retired managed file'
if ! git -C "$RETIREMENT_PROJECT" diff --quiet \
  || ! git -C "$RETIREMENT_PROJECT" diff --cached --quiet; then
  echo "FAIL: retired helper migration left unstaged or staged changes after commit" >&2
  git -C "$RETIREMENT_PROJECT" status --short >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 2: committed local touchstone-owned changes update on a review branch.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 3: Modify a Touchstone-owned file, then update ---"

echo "# locally modified" >>"$PROJECT/principles/engineering-principles.md"
rm "$PROJECT/TOUCHSTONE.md"
rm "$PROJECT/.github/workflows/issue-claim-check.yml"
rm "$PROJECT/.markdownlint.json"
rm "$PROJECT/scripts/touchstone-run.sh"
rm "$PROJECT/scripts/claim-issue.sh"
rm "$PROJECT/scripts/issue-claim-check.sh"
printf '{"custom": true}\n' >"$PROJECT/.claude/settings.json"
echo "0000000000000000000000000000000000000000" >"$PROJECT/.touchstone-version"
commit_all "$PROJECT" "simulate old touchstone state"

(cd "$PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") 2>&1 | tee "$TEST_DIR/update-output-2.txt"

UPDATE_BRANCH="$(git -C "$PROJECT" rev-parse --abbrev-ref HEAD)"
if [ "$UPDATE_BRANCH" = "$BASE_BRANCH" ]; then
  echo "FAIL: update did not switch to a chore/touchstone branch" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$TEST_DIR/update-output-2.txt" 'Creating update branch: chore/touchstone-'
assert_contains "$TEST_DIR/update-output-2.txt" 'Committed: chore: update touchstone to'
assert_contains "$TEST_DIR/update-output-2.txt" 'bash scripts/open-pr.sh'
assert_exists "$PROJECT/TOUCHSTONE.md"
assert_exists "$PROJECT/.github/workflows/issue-claim-check.yml"
assert_contains "$PROJECT/.github/workflows/issue-claim-check.yml" 'claim-check-${{ github.event.pull_request.number || github.ref }}'
assert_contains "$PROJECT/.github/workflows/issue-claim-check.yml" 'cancel-in-progress: true'
assert_exists "$PROJECT/.markdownlint.json"
assert_contains "$TEST_DIR/update-output-2.txt" 'added (project-owned).*\.markdownlint\.json'
assert_exists "$PROJECT/scripts/touchstone-run.sh"
assert_exists "$PROJECT/scripts/claim-issue.sh"
assert_exists "$PROJECT/scripts/issue-claim-check.sh"
assert_exists "$PROJECT/scripts/spawn-worktree.sh"
assert_exists "$PROJECT/scripts/cleanup-worktrees.sh"
assert_exists "$PROJECT/lib/toml.sh"
assert_exists "$PROJECT/lib/events.sh"
assert_exists "$PROJECT/lib/codex-auth.sh"
assert_exists "$PROJECT/lib/script-sync-guard.sh"
assert_exists "$PROJECT/lib/sha256.sh"
assert_exists "$PROJECT/lib/preflight.sh"
assert_not_exists "$PROJECT/lib/review-comment.sh"
assert_not_exists "$PROJECT/scripts/cortex-pr-merged-hook.sh"
assert_exists "$PROJECT/.touchstone-manifest"
assert_contains "$PROJECT/.touchstone-manifest" '^TOUCHSTONE.md$'
assert_contains "$PROJECT/.touchstone-manifest" '^\.github/workflows/issue-claim-check\.yml$'
assert_contains "$PROJECT/.touchstone-manifest" '^scripts/touchstone-run.sh$'
assert_contains "$PROJECT/.touchstone-manifest" '^scripts/claim-issue.sh$'
assert_contains "$PROJECT/.touchstone-manifest" '^scripts/issue-claim-check.sh$'
assert_contains "$PROJECT/.touchstone-manifest" '^scripts/spawn-worktree.sh$'
assert_contains "$PROJECT/.touchstone-manifest" '^scripts/cleanup-worktrees.sh$'
assert_contains "$PROJECT/.touchstone-manifest" '^lib/toml\.sh$'
assert_contains "$PROJECT/.touchstone-manifest" '^lib/events\.sh$'
assert_contains "$PROJECT/.touchstone-manifest" '^lib/codex-auth\.sh$'
assert_contains "$PROJECT/.touchstone-manifest" '^lib/script-sync-guard\.sh$'
assert_contains "$PROJECT/.touchstone-manifest" '^lib/sha256\.sh$'
assert_contains "$PROJECT/.touchstone-manifest" '^lib/preflight\.sh$'
assert_not_contains "$PROJECT/.touchstone-manifest" '^lib/review-comment\.sh$'
assert_not_contains "$PROJECT/.touchstone-manifest" '^scripts/cortex-pr-merged-hook\.sh$'
if grep -qxF '.markdownlint.json' "$PROJECT/.touchstone-manifest"; then
  echo "FAIL: .markdownlint.json must remain project-owned" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_not_exists "$PROJECT/principles/engineering-principles.md.bak"
assert_not_exists "$PROJECT/.claude/settings.json.touchstone-pre-update.bak"

if find "$PROJECT" -name '*.bak' -print | grep -q .; then
  echo "FAIL: update should not create .bak files" >&2
  ERRORS=$((ERRORS + 1))
else
  echo "    PASS: update did not create .bak files"
fi

if diff -q "$TOUCHSTONE_ROOT/principles/engineering-principles.md" "$PROJECT/principles/engineering-principles.md" >/dev/null 2>&1; then
  echo "    PASS: file was updated to touchstone version"
else
  echo "    FAIL: file does not match touchstone version" >&2
  ERRORS=$((ERRORS + 1))
fi

if git -C "$PROJECT" show HEAD^:principles/engineering-principles.md | grep -q "locally modified"; then
  echo "    PASS: previous committed state remains available via git"
else
  echo "    FAIL: previous state was not reviewable in git history" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ -n "$(git -C "$PROJECT" status --porcelain)" ]; then
  echo "FAIL: update should leave a clean worktree after committing" >&2
  git -C "$PROJECT" status --short >&2
  ERRORS=$((ERRORS + 1))
fi

if git -C "$PROJECT" ls-files --error-unmatch .touchstone-version >/dev/null 2>&1; then
  echo "    PASS: .touchstone-version is tracked in the update commit"
else
  echo "FAIL: expected .touchstone-version to be tracked" >&2
  ERRORS=$((ERRORS + 1))
fi

if git -C "$PROJECT" ls-files --error-unmatch TOUCHSTONE.md >/dev/null 2>&1; then
  echo "    PASS: TOUCHSTONE.md is tracked in the update commit"
else
  echo "FAIL: expected TOUCHSTONE.md to be tracked" >&2
  ERRORS=$((ERRORS + 1))
fi

if git -C "$PROJECT" ls-files --error-unmatch .github/workflows/issue-claim-check.yml >/dev/null 2>&1; then
  echo "    PASS: issue-claim workflow is tracked in the update commit"
else
  echo "FAIL: expected .github/workflows/issue-claim-check.yml to be tracked" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ -x "$PROJECT/scripts/project-owned.sh" ]; then
  echo "FAIL: update changed executable mode on a project-owned script" >&2
  ERRORS=$((ERRORS + 1))
else
  echo "    PASS: project-owned script mode was preserved"
fi

return_to_base_branch "$PROJECT" "$BASE_BRANCH"

# --------------------------------------------------------------------------
# Test 2b: --in-place updates the current feature branch without creating a
# chore/touchstone-* branch. This is the explicit escape hatch for drivers that
# already created a task branch.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 3b: In-place update stays on the current branch ---"

IN_PLACE_PROJECT="$TEST_DIR/in-place-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$IN_PLACE_PROJECT" --no-register >/dev/null
configure_git "$IN_PLACE_PROJECT"
commit_all "$IN_PLACE_PROJECT" "initial in-place test project"
git -C "$IN_PLACE_PROJECT" checkout -q -b feature/in-place-update
rm "$IN_PLACE_PROJECT/.github/workflows/issue-claim-check.yml"
rm "$IN_PLACE_PROJECT/scripts/touchstone-run.sh"
rm "$IN_PLACE_PROJECT/scripts/claim-issue.sh"
rm "$IN_PLACE_PROJECT/scripts/issue-claim-check.sh"
printf '{"custom": true}\n' >"$IN_PLACE_PROJECT/.claude/settings.json"
echo "0000000000000000000000000000000000000004" >"$IN_PLACE_PROJECT/.touchstone-version"
commit_all "$IN_PLACE_PROJECT" "simulate old in-place touchstone state"
IN_PLACE_BASE="$(git -C "$IN_PLACE_PROJECT" rev-parse HEAD)"

(cd "$IN_PLACE_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --in-place) 2>&1 | tee "$TEST_DIR/update-in-place-output.txt"

if [ "$(git -C "$IN_PLACE_PROJECT" branch --show-current)" != "feature/in-place-update" ]; then
  echo "FAIL: --in-place update should stay on the current feature branch" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$TEST_DIR/update-in-place-output.txt" 'Applying update on current branch: feature/in-place-update'
assert_contains "$TEST_DIR/update-in-place-output.txt" 'Committed: chore: update touchstone to'
assert_not_contains "$TEST_DIR/update-in-place-output.txt" 'Creating update branch: chore/touchstone-'
assert_exists "$IN_PLACE_PROJECT/.github/workflows/issue-claim-check.yml"
assert_exists "$IN_PLACE_PROJECT/scripts/touchstone-run.sh"
assert_exists "$IN_PLACE_PROJECT/scripts/claim-issue.sh"
assert_exists "$IN_PLACE_PROJECT/scripts/issue-claim-check.sh"
assert_exists "$IN_PLACE_PROJECT/lib/script-sync-guard.sh"
assert_not_exists "$IN_PLACE_PROJECT/.claude/settings.json.touchstone-pre-update.bak"

if git -C "$IN_PLACE_PROJECT" branch --list 'chore/touchstone-*' | grep -q .; then
  echo "FAIL: --in-place update should not create a chore/touchstone-* branch" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$(git -C "$IN_PLACE_PROJECT" rev-parse HEAD^)" != "$IN_PLACE_BASE" ]; then
  echo "FAIL: --in-place update commit should be based on the pre-update feature branch HEAD" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ -n "$(git -C "$IN_PLACE_PROJECT" status --porcelain)" ]; then
  echo "FAIL: --in-place update should leave a clean worktree after committing" >&2
  git -C "$IN_PLACE_PROJECT" status --short >&2
  ERRORS=$((ERRORS + 1))
fi

if (cd "$IN_PLACE_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --in-place --branch chore/custom) >"$TEST_DIR/update-in-place-branch-output.txt" 2>&1; then
  echo "FAIL: --in-place and --branch should be rejected together" >&2
  ERRORS=$((ERRORS + 1))
else
  assert_contains "$TEST_DIR/update-in-place-branch-output.txt" 'cannot be combined'
fi

# --------------------------------------------------------------------------
# Test 2c: project .gitignore rules must not prevent Touchstone-owned files
# from being staged. Downstream repos may legitimately ignore generic names
# like lib/ for their own build artifacts; managed Touchstone files still need
# to ship as exact manifest entries.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 3b2: Retired worker files are reported, never deleted ---"

RETIRED_WORKER_PROJECT="$TEST_DIR/retired-worker-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$RETIRED_WORKER_PROJECT" --no-register >/dev/null
configure_git "$RETIRED_WORKER_PROJECT"
# A project still carrying the engine Touchstone retired in 2.13.0. Managed
# content must be genuinely stale: a stamp-only difference no longer triggers
# an update (#773).
printf '#!/usr/bin/env bash\necho worker\n' >"$RETIRED_WORKER_PROJECT/scripts/worker.sh"
chmod +x "$RETIRED_WORKER_PROJECT/scripts/worker.sh"
printf '# stale managed drift\n' >>"$RETIRED_WORKER_PROJECT/lib/toml.sh"
echo "0000000000000000000000000000000000000005" >"$RETIRED_WORKER_PROJECT/.touchstone-version"
commit_all "$RETIRED_WORKER_PROJECT" "simulate project carrying the retired worker engine"

if ! (cd "$RETIRED_WORKER_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --in-place) \
  >"$TEST_DIR/update-retired-worker.txt" 2>&1; then
  echo "FAIL: update of a project carrying the retired worker engine should succeed" >&2
  cat "$TEST_DIR/update-retired-worker.txt" >&2
  exit 1
fi

# Touchstone stops managing these files; it never deletes the project's.
assert_exists "$RETIRED_WORKER_PROJECT/scripts/worker.sh"
assert_contains "$TEST_DIR/update-retired-worker.txt" 'no longer managed'
assert_contains "$TEST_DIR/update-retired-worker.txt" 'scripts/worker.sh'

# --------------------------------------------------------------------------
echo ""
echo "--- Step 3c: Ignored Touchstone-owned paths are force-staged ---"

IGNORED_MANAGED_PROJECT="$TEST_DIR/ignored-managed-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$IGNORED_MANAGED_PROJECT" --no-register >/dev/null
configure_git "$IGNORED_MANAGED_PROJECT"
commit_all "$IGNORED_MANAGED_PROJECT" "initial ignored-managed test project"
printf '\nlib/\n' >>"$IGNORED_MANAGED_PROJECT/.gitignore"
git -C "$IGNORED_MANAGED_PROJECT" rm --cached -r lib >/dev/null
echo "0000000000000000000000000000000000000005" >"$IGNORED_MANAGED_PROJECT/.touchstone-version"
commit_all "$IGNORED_MANAGED_PROJECT" "simulate repo ignoring Touchstone lib files"
# Genuine managed drift in the now-ignored lib copy (#773: stamp-only
# differences no longer trigger an update). Ignored files are invisible to
# the dirty check, so the update must still overwrite and force-stage this.
printf '# stale managed drift\n' >>"$IGNORED_MANAGED_PROJECT/lib/preflight.sh"

(cd "$IGNORED_MANAGED_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >"$TEST_DIR/update-ignored-managed-output.txt" 2>&1

assert_contains "$TEST_DIR/update-ignored-managed-output.txt" 'Committed: chore: update touchstone to'
if git -C "$IGNORED_MANAGED_PROJECT" ls-files --error-unmatch lib/preflight.sh >/dev/null 2>&1; then
  echo "    PASS: ignored managed lib/preflight.sh was force-staged"
else
  echo "FAIL: ignored managed lib/preflight.sh was not tracked by update commit" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ -n "$(git -C "$IGNORED_MANAGED_PROJECT" status --porcelain)" ]; then
  echo "FAIL: ignored managed update should leave a clean worktree after committing" >&2
  git -C "$IGNORED_MANAGED_PROJECT" status --short >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 2d: direct project-local PR scripts refuse feature-branch auto-update.
# This covers the raw `bash scripts/merge-pr.sh` path, which bypasses the
# touchstone CLI's normal auto-project-sync hook.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 3d: Direct workflow scripts refuse feature-branch Touchstone churn ---"

SCRIPT_SYNC_PROJECT="$TEST_DIR/script-sync-project"
SCRIPT_SYNC_BIN="$TEST_DIR/script-sync-bin"
mkdir -p "$SCRIPT_SYNC_BIN"
cat >"$SCRIPT_SYNC_BIN/touchstone" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TOUCHSTONE_SCRIPT_SYNC_FAKE_LOG"
TOUCHSTONE_NO_AUTO_UPDATE=1 exec "$TOUCHSTONE_BIN" "$@"
EOF
chmod +x "$SCRIPT_SYNC_BIN/touchstone"

bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$SCRIPT_SYNC_PROJECT" --no-register >/dev/null
configure_git "$SCRIPT_SYNC_PROJECT"
commit_all "$SCRIPT_SYNC_PROJECT" "initial script sync test project"
git -C "$SCRIPT_SYNC_PROJECT" checkout -q -b feature/script-sync-guard
printf '# stale managed drift\n' >>"$SCRIPT_SYNC_PROJECT/lib/toml.sh"
echo "0000000000000000000000000000000000000014" >"$SCRIPT_SYNC_PROJECT/.touchstone-version"
commit_all "$SCRIPT_SYNC_PROJECT" "simulate stale script sync touchstone state"

SCRIPT_SYNC_OUT="$TEST_DIR/script-sync-output.txt"
SCRIPT_SYNC_LOG="$TEST_DIR/script-sync-touchstone.log"
SCRIPT_SYNC_RC=0
(
  cd "$SCRIPT_SYNC_PROJECT"
  PATH="$SCRIPT_SYNC_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    TOUCHSTONE_BIN="$TOUCHSTONE_ROOT/bin/touchstone" \
    TOUCHSTONE_SCRIPT_SYNC_FAKE_LOG="$SCRIPT_SYNC_LOG" \
    bash scripts/merge-pr.sh not-a-pr
) >"$SCRIPT_SYNC_OUT" 2>&1 || SCRIPT_SYNC_RC=$?

if [ "$SCRIPT_SYNC_RC" != "2" ]; then
  echo "FAIL: guarded merge-pr run should exit 2 when feature-branch script sync is refused" >&2
  echo "    rc=$SCRIPT_SYNC_RC" >&2
  cat "$SCRIPT_SYNC_OUT" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$SCRIPT_SYNC_OUT" 'Touchstone script sync: project-local workflow files are stale'
assert_contains "$SCRIPT_SYNC_OUT" "Refusing to auto-commit Touchstone updates onto in-flight branch work"
assert_contains "$SCRIPT_SYNC_OUT" "TOUCHSTONE_SCRIPT_SYNC_ALLOW_FEATURE_UPDATE=1"
assert_contains "$SCRIPT_SYNC_LOG" '^update --check$'
assert_not_contains "$SCRIPT_SYNC_LOG" '^update --in-place$'

if [ "$(cat "$SCRIPT_SYNC_PROJECT/.touchstone-version" | tr -d '[:space:]')" = "0000000000000000000000000000000000000014" ]; then
  echo "    PASS: direct script sync left stale feature branch untouched"
else
  echo "FAIL: direct script sync should not refresh .touchstone-version without opt-in" >&2
  ERRORS=$((ERRORS + 1))
fi

if git -C "$SCRIPT_SYNC_PROJECT" log -1 --format=%s | grep -q '^simulate stale script sync touchstone state$'; then
  echo "    PASS: direct script sync did not commit an update on the feature branch"
else
  echo "FAIL: direct script sync should not create a Touchstone update commit without opt-in" >&2
  git -C "$SCRIPT_SYNC_PROJECT" log -1 --format=%s >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$(git -C "$SCRIPT_SYNC_PROJECT" branch --show-current)" != "feature/script-sync-guard" ]; then
  echo "FAIL: direct script sync should stay on the current feature branch" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ -n "$(git -C "$SCRIPT_SYNC_PROJECT" status --porcelain)" ]; then
  echo "FAIL: direct script sync refusal should leave a clean worktree" >&2
  git -C "$SCRIPT_SYNC_PROJECT" status --short >&2
  ERRORS=$((ERRORS + 1))
fi

rm -f "$SCRIPT_SYNC_LOG"
SCRIPT_SYNC_OPT_IN_OUT="$TEST_DIR/script-sync-opt-in-output.txt"
SCRIPT_SYNC_OPT_IN_RC=0
(
  cd "$SCRIPT_SYNC_PROJECT"
  PATH="$SCRIPT_SYNC_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    TOUCHSTONE_BIN="$TOUCHSTONE_ROOT/bin/touchstone" \
    TOUCHSTONE_SCRIPT_SYNC_FAKE_LOG="$SCRIPT_SYNC_LOG" \
    TOUCHSTONE_SCRIPT_SYNC_ALLOW_FEATURE_UPDATE=1 \
    bash scripts/merge-pr.sh not-a-pr
) >"$SCRIPT_SYNC_OPT_IN_OUT" 2>&1 || SCRIPT_SYNC_OPT_IN_RC=$?

if [ "$SCRIPT_SYNC_OPT_IN_RC" != "2" ]; then
  echo "FAIL: opted-in guarded merge-pr invalid-argument run should exit 2 after sync" >&2
  echo "    rc=$SCRIPT_SYNC_OPT_IN_RC" >&2
  cat "$SCRIPT_SYNC_OPT_IN_OUT" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$SCRIPT_SYNC_OPT_IN_OUT" 'Touchstone script sync: project-local workflow files are stale'
assert_contains "$SCRIPT_SYNC_OPT_IN_OUT" 'Touchstone script sync: restarting'
assert_contains "$SCRIPT_SYNC_OPT_IN_OUT" 'Usage: bash scripts/merge-pr.sh <pr-number>'
assert_contains "$SCRIPT_SYNC_LOG" '^update --check$'
assert_contains "$SCRIPT_SYNC_LOG" '^update --in-place$'

if [ "$(cat "$SCRIPT_SYNC_PROJECT/.touchstone-version" | tr -d '[:space:]')" = "$INITIAL_SHA" ]; then
  echo "    PASS: opted-in direct script sync refreshed .touchstone-version"
else
  echo "FAIL: opted-in direct script sync did not refresh .touchstone-version" >&2
  ERRORS=$((ERRORS + 1))
fi

if git -C "$SCRIPT_SYNC_PROJECT" log -1 --format=%s | grep -q '^chore: update touchstone to '; then
  echo "    PASS: opted-in direct script sync committed the update on the feature branch"
else
  echo "FAIL: opted-in direct script sync did not create a Touchstone update commit" >&2
  git -C "$SCRIPT_SYNC_PROJECT" log -1 --format=%s >&2
  ERRORS=$((ERRORS + 1))
fi

SCRIPT_SYNC_DONE_PROJECT="$TEST_DIR/script-sync-done-project"
SCRIPT_SYNC_DONE_BIN="$TEST_DIR/script-sync-done-bin"
SCRIPT_SYNC_DONE_LOG="$TEST_DIR/script-sync-done-touchstone.log"
mkdir -p "$SCRIPT_SYNC_DONE_BIN"
cat >"$SCRIPT_SYNC_DONE_BIN/touchstone" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TOUCHSTONE_SCRIPT_SYNC_FAKE_LOG"
case "$*" in
  "update --check")
    echo "Already up to date."
    exit 0
    ;;
esac
echo "unexpected touchstone command: $*" >&2
exit 9
EOF
chmod +x "$SCRIPT_SYNC_DONE_BIN/touchstone"

bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$SCRIPT_SYNC_DONE_PROJECT" --no-register >/dev/null
configure_git "$SCRIPT_SYNC_DONE_PROJECT"
commit_all "$SCRIPT_SYNC_DONE_PROJECT" "initial script sync done project"

(
  cd "$SCRIPT_SYNC_DONE_PROJECT"
  PATH="$SCRIPT_SYNC_DONE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    TOUCHSTONE_SCRIPT_SYNC_FAKE_LOG="$SCRIPT_SYNC_DONE_LOG" \
    TOUCHSTONE_SCRIPT_SYNC_GUARD_DONE=1 \
    bash -c '. ./lib/script-sync-guard.sh
      touchstone_script_sync_guard scripts/open-pr.sh --auto-merge
      touchstone_script_sync_guard scripts/merge-pr.sh 123'
)

if [ "$(grep -c '^update --check$' "$SCRIPT_SYNC_DONE_LOG")" = "1" ]; then
  echo "    PASS: script sync guard reuses checked marker in one execution chain"
else
  echo "FAIL: script sync guard should not repeat update --check after a verified check" >&2
  cat "$SCRIPT_SYNC_DONE_LOG" >&2
  ERRORS=$((ERRORS + 1))
fi

SCRIPT_SYNC_SOURCE_PROJECT="$TEST_DIR/script-sync-source-project"
SCRIPT_SYNC_SOURCE_BIN="$TEST_DIR/script-sync-source-bin"
SCRIPT_SYNC_SOURCE_LOG="$TEST_DIR/script-sync-source-touchstone.log"
mkdir -p "$SCRIPT_SYNC_SOURCE_PROJECT/scripts" \
  "$SCRIPT_SYNC_SOURCE_PROJECT/lib" \
  "$SCRIPT_SYNC_SOURCE_PROJECT/bootstrap" \
  "$SCRIPT_SYNC_SOURCE_PROJECT/bin" \
  "$SCRIPT_SYNC_SOURCE_BIN"
cp "$TOUCHSTONE_ROOT/lib/script-sync-guard.sh" "$SCRIPT_SYNC_SOURCE_PROJECT/lib/script-sync-guard.sh"
touch "$SCRIPT_SYNC_SOURCE_PROJECT/scripts/open-pr.sh"
touch "$SCRIPT_SYNC_SOURCE_PROJECT/bootstrap/update-project.sh"
touch "$SCRIPT_SYNC_SOURCE_PROJECT/bin/touchstone"
printf '2.11.31\n' >"$SCRIPT_SYNC_SOURCE_PROJECT/VERSION"
printf 'source-checkout\n' >"$SCRIPT_SYNC_SOURCE_PROJECT/.touchstone-version"
cat >"$SCRIPT_SYNC_SOURCE_BIN/touchstone" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TOUCHSTONE_SCRIPT_SYNC_FAKE_LOG"
echo "source checkout should not call installed touchstone" >&2
exit 9
EOF
chmod +x "$SCRIPT_SYNC_SOURCE_BIN/touchstone"

(
  cd "$SCRIPT_SYNC_SOURCE_PROJECT"
  PATH="$SCRIPT_SYNC_SOURCE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    TOUCHSTONE_SCRIPT_SYNC_FAKE_LOG="$SCRIPT_SYNC_SOURCE_LOG" \
    bash -c '. ./lib/script-sync-guard.sh
      touchstone_script_sync_guard scripts/open-pr.sh --auto-merge'
)

if [ ! -e "$SCRIPT_SYNC_SOURCE_LOG" ]; then
  echo "    PASS: source checkout skipped installed touchstone script sync"
else
  echo "FAIL: source checkout should not run touchstone update --check from installed package" >&2
  cat "$SCRIPT_SYNC_SOURCE_LOG" >&2
  ERRORS=$((ERRORS + 1))
fi

SCRIPT_SYNC_HELP_PROJECT="$TEST_DIR/script-sync-help-project"
SCRIPT_SYNC_HELP_BIN="$TEST_DIR/script-sync-help-bin"
SCRIPT_SYNC_HELP_LOG="$TEST_DIR/script-sync-help-touchstone.log"
SCRIPT_SYNC_HELP_OUT="$TEST_DIR/script-sync-help-output.txt"
mkdir -p "$SCRIPT_SYNC_HELP_BIN"
cat >"$SCRIPT_SYNC_HELP_BIN/touchstone" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TOUCHSTONE_SCRIPT_SYNC_FAKE_LOG"
case "$*" in
  "update --check")
    echo "==> Needs update."
    exit 0
    ;;
esac
echo "unexpected touchstone command: $*" >&2
exit 9
EOF
chmod +x "$SCRIPT_SYNC_HELP_BIN/touchstone"

bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$SCRIPT_SYNC_HELP_PROJECT" --no-register >/dev/null
configure_git "$SCRIPT_SYNC_HELP_PROJECT"
commit_all "$SCRIPT_SYNC_HELP_PROJECT" "initial script sync help project"
echo "0000000000000000000000000000000000000016" >"$SCRIPT_SYNC_HELP_PROJECT/.touchstone-version"
commit_all "$SCRIPT_SYNC_HELP_PROJECT" "simulate stale help script sync state"

SCRIPT_SYNC_HELP_RC=0
(
  cd "$SCRIPT_SYNC_HELP_PROJECT"
  PATH="$SCRIPT_SYNC_HELP_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    TOUCHSTONE_SCRIPT_SYNC_FAKE_LOG="$SCRIPT_SYNC_HELP_LOG" \
    bash scripts/open-pr.sh --help
) >"$SCRIPT_SYNC_HELP_OUT" 2>&1 || SCRIPT_SYNC_HELP_RC=$?

if [ "$SCRIPT_SYNC_HELP_RC" = "0" ] \
  && grep -q 'Usage: bash scripts/open-pr.sh' "$SCRIPT_SYNC_HELP_OUT" \
  && [ ! -e "$SCRIPT_SYNC_HELP_LOG" ]; then
  echo "    PASS: open-pr --help skipped script sync and printed usage"
else
  echo "FAIL: open-pr --help should not run touchstone update --check or mutate generated files" >&2
  echo "    rc=$SCRIPT_SYNC_HELP_RC" >&2
  cat "$SCRIPT_SYNC_HELP_OUT" >&2
  [ ! -f "$SCRIPT_SYNC_HELP_LOG" ] || cat "$SCRIPT_SYNC_HELP_LOG" >&2
  ERRORS=$((ERRORS + 1))
fi

SCRIPT_SYNC_SHIP_PROJECT="$TEST_DIR/script-sync-ship-project"
SCRIPT_SYNC_SHIP_BIN="$TEST_DIR/script-sync-ship-bin"
SCRIPT_SYNC_SHIP_LOG="$TEST_DIR/script-sync-ship-touchstone.log"
mkdir -p "$SCRIPT_SYNC_SHIP_BIN"
cat >"$SCRIPT_SYNC_SHIP_BIN/touchstone" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TOUCHSTONE_SCRIPT_SYNC_FAKE_LOG"
case "$*" in
  "update --check")
    echo "==> Needs update."
    exit 0
    ;;
  "update --ship")
    echo "fake update shipped"
    exit 0
    ;;
esac
echo "unexpected touchstone command: $*" >&2
exit 9
EOF
chmod +x "$SCRIPT_SYNC_SHIP_BIN/touchstone"

bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$SCRIPT_SYNC_SHIP_PROJECT" --no-register >/dev/null
configure_git "$SCRIPT_SYNC_SHIP_PROJECT"
commit_all "$SCRIPT_SYNC_SHIP_PROJECT" "initial script sync ship project"
echo "0000000000000000000000000000000000000015" >"$SCRIPT_SYNC_SHIP_PROJECT/.touchstone-version"
commit_all "$SCRIPT_SYNC_SHIP_PROJECT" "simulate stale default-branch script sync state"

SCRIPT_SYNC_SHIP_OUT="$TEST_DIR/script-sync-ship-output.txt"
SCRIPT_SYNC_SHIP_RC=0
(
  cd "$SCRIPT_SYNC_SHIP_PROJECT"
  PATH="$SCRIPT_SYNC_SHIP_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    TOUCHSTONE_SCRIPT_SYNC_FAKE_LOG="$SCRIPT_SYNC_SHIP_LOG" \
    bash scripts/merge-pr.sh not-a-pr
) >"$SCRIPT_SYNC_SHIP_OUT" 2>&1 || SCRIPT_SYNC_SHIP_RC=$?

if [ "$SCRIPT_SYNC_SHIP_RC" != "2" ]; then
  echo "FAIL: guarded default-branch merge-pr invalid-argument run should exit 2 after ship" >&2
  echo "    rc=$SCRIPT_SYNC_SHIP_RC" >&2
  cat "$SCRIPT_SYNC_SHIP_OUT" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$SCRIPT_SYNC_SHIP_OUT" 'shipping a Touchstone update PR before continuing'
assert_contains "$SCRIPT_SYNC_SHIP_OUT" 'Touchstone script sync: restarting'
assert_contains "$SCRIPT_SYNC_SHIP_OUT" 'Usage: bash scripts/merge-pr.sh <pr-number>'
assert_contains "$SCRIPT_SYNC_SHIP_LOG" '^update --check$'
assert_contains "$SCRIPT_SYNC_SHIP_LOG" '^update --ship$'
assert_not_contains "$SCRIPT_SYNC_SHIP_LOG" '^update --in-place$'

# --------------------------------------------------------------------------
# Test 3: project-owned files are NOT touched.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 4: Verify project-owned files are untouched ---"

echo "# my project context" >>"$PROJECT/CLAUDE.md"
printf '{"custom": true}\n' >"$PROJECT/.markdownlint.json"
# Managed drift so the update actually runs (#773: stamp-only differences no
# longer trigger one) — the point is that it must not touch project-owned files.
rm "$PROJECT/scripts/touchstone-run.sh"
echo "0000000000000000000000000000000000000001" >"$PROJECT/.touchstone-version"
commit_all "$PROJECT" "simulate project-owned customization"
CLAUDE_CHECKSUM="$(md5 -q "$PROJECT/CLAUDE.md" 2>/dev/null || md5sum "$PROJECT/CLAUDE.md" | awk '{print $1}')"
MARKDOWNLINT_CHECKSUM="$(md5 -q "$PROJECT/.markdownlint.json" 2>/dev/null || md5sum "$PROJECT/.markdownlint.json" | awk '{print $1}')"

(cd "$PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >/dev/null 2>&1

CLAUDE_CHECKSUM_AFTER="$(md5 -q "$PROJECT/CLAUDE.md" 2>/dev/null || md5sum "$PROJECT/CLAUDE.md" | awk '{print $1}')"
MARKDOWNLINT_CHECKSUM_AFTER="$(md5 -q "$PROJECT/.markdownlint.json" 2>/dev/null || md5sum "$PROJECT/.markdownlint.json" | awk '{print $1}')"

if [ "$CLAUDE_CHECKSUM" = "$CLAUDE_CHECKSUM_AFTER" ]; then
  echo "    PASS: CLAUDE.md was not modified by update"
else
  echo "    FAIL: CLAUDE.md was modified by update" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$MARKDOWNLINT_CHECKSUM" = "$MARKDOWNLINT_CHECKSUM_AFTER" ]; then
  echo "    PASS: .markdownlint.json was not modified by update"
else
  echo "    FAIL: .markdownlint.json was modified by update" >&2
  ERRORS=$((ERRORS + 1))
fi

assert_not_exists "$PROJECT/CLAUDE.md.bak"

return_to_base_branch "$PROJECT" "$BASE_BRANCH"

# Existing projects from before Gemini support should receive GEMINI.md once,
# but the file remains project-owned after that.
rm -f "$PROJECT/GEMINI.md"
echo "0000000000000000000000000000000000000001" >"$PROJECT/.touchstone-version"
commit_all "$PROJECT" "simulate pre-gemini project"

(cd "$PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >/dev/null 2>&1

assert_exists "$PROJECT/GEMINI.md"
assert_contains "$PROJECT/GEMINI.md" "Gemini CLI"
assert_not_contains "$PROJECT/GEMINI.md" "{{PROJECT_NAME}}"
assert_contains "$PROJECT/GEMINI.md" "test-project"
if ! git -C "$PROJECT" log -1 --name-only --pretty=format: | grep -qx 'GEMINI.md'; then
  echo "FAIL: update commit must include GEMINI.md when adding the project-owned Gemini instructions" >&2
  ERRORS=$((ERRORS + 1))
fi

return_to_base_branch "$PROJECT" "$BASE_BRANCH"

# --------------------------------------------------------------------------
# An EXISTING GEMINI.md with a stale managed block must be refreshed and
# staged. The case above only covers adding the file for the first time, so it
# passed even with the refresh conditional and its staging flag deleted --
# neither propagation bug had CI coverage (PR #703 review).
#
# The block is also refreshed independently of AGENTS.md: a project can ship
# GEMINI.md without AGENTS.md, update never backfills a missing AGENTS.md, and
# nesting the refresh under that check stranded such projects permanently.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 4a-bis: existing stale GEMINI.md block is refreshed and staged ---"

# awk, not python3: the fast tier is the "is this safe to push" gate and has
# to run on a stock macOS checkout, where python3 is not guaranteed to be
# installed (PR #703 review). Replaces the managed block's contents with a
# stale marker, leaving the markers themselves in place.
awk '
  /<!-- touchstone:steering:start -->/ { print; print "STALE-GEMINI-BLOCK-MARKER"; inblock = 1; next }
  /<!-- touchstone:steering:end -->/   { print; inblock = 0; next }
  !inblock { print }
' "$PROJECT/GEMINI.md" >"$PROJECT/GEMINI.md.stale" \
  && mv "$PROJECT/GEMINI.md.stale" "$PROJECT/GEMINI.md"
rm -f "$PROJECT/AGENTS.md"
echo "0000000000000000000000000000000000000002" >"$PROJECT/.touchstone-version"
commit_all "$PROJECT" "simulate stale gemini block, no AGENTS.md"

(cd "$PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >/dev/null 2>&1

assert_not_contains "$PROJECT/GEMINI.md" "STALE-GEMINI-BLOCK-MARKER"
assert_contains "$PROJECT/GEMINI.md" "Required Delivery Workflow"
if ! git -C "$PROJECT" log -1 --name-only --pretty=format: | grep -qx 'GEMINI.md'; then
  echo "FAIL: refreshed GEMINI.md must be staged into the update commit, not left dirty" >&2
  ERRORS=$((ERRORS + 1))
fi
if ! git -C "$PROJECT" diff --quiet -- GEMINI.md; then
  echo "FAIL: GEMINI.md still has unstaged changes after the update commit" >&2
  ERRORS=$((ERRORS + 1))
fi

return_to_base_branch "$PROJECT" "$BASE_BRANCH"

# --------------------------------------------------------------------------
# A pre-existing gitignored, untracked GEMINI.md must NOT be force-staged.
# The clean-worktree check cannot see ignored files, so the update proceeded
# and `git add -f` published deliberately-ignored private local steering
# content into the update commit (PR #703 review). The block still refreshes
# on disk; the file stays untracked, as its owner chose.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 4a-ter: ignored untracked GEMINI.md stays untracked through update ---"

GEMIGNORE_PROJECT="$TEST_DIR/gemini-ignored-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$GEMIGNORE_PROJECT" --no-register >/dev/null
configure_git "$GEMIGNORE_PROJECT"
commit_all "$GEMIGNORE_PROJECT" "initial gemini-ignored project"
git -C "$GEMIGNORE_PROJECT" rm -q GEMINI.md
printf 'GEMINI.md\n' >>"$GEMIGNORE_PROJECT/.gitignore"
echo "0000000000000000000000000000000000000003" >"$GEMIGNORE_PROJECT/.touchstone-version"
commit_all "$GEMIGNORE_PROJECT" "ignore local gemini instructions"
# Private local file with a STALE managed block, so the refresh must touch it.
cat >"$GEMIGNORE_PROJECT/GEMINI.md" <<'EOF_IGNORED_GEMINI'
# Local Gemini instructions

PRIVATE-LOCAL-GEMINI-NOTE: deliberately ignored, must never be committed.

<!-- touchstone:steering:start -->
STALE-IGNORED-GEMINI-BLOCK
<!-- touchstone:steering:end -->
EOF_IGNORED_GEMINI

if ! (cd "$GEMIGNORE_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") \
  >"$TEST_DIR/gemini-ignored-update.txt" 2>&1; then
  echo "FAIL: update should succeed with an ignored untracked GEMINI.md present" >&2
  cat "$TEST_DIR/gemini-ignored-update.txt" >&2
  ERRORS=$((ERRORS + 1))
fi
if [ -n "$(git -C "$GEMIGNORE_PROJECT" ls-files -- GEMINI.md)" ]; then
  echo "FAIL: ignored untracked GEMINI.md was force-staged by the update (publishes private local content)" >&2
  ERRORS=$((ERRORS + 1))
fi
if git -C "$GEMIGNORE_PROJECT" log -1 --name-only --pretty=format: | grep -qx 'GEMINI.md'; then
  echo "FAIL: the update commit included the deliberately-ignored GEMINI.md" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$GEMIGNORE_PROJECT/GEMINI.md" "PRIVATE-LOCAL-GEMINI-NOTE"
assert_not_contains "$GEMIGNORE_PROJECT/GEMINI.md" "STALE-IGNORED-GEMINI-BLOCK"
assert_contains "$GEMIGNORE_PROJECT/GEMINI.md" "Required Delivery Workflow"
assert_contains "$TEST_DIR/gemini-ignored-update.txt" "left unstaged"

# --------------------------------------------------------------------------
# An EXISTING GEMINI.md must be inside the update's rollback boundary. It was
# in the planned-write set only when initially absent, so when a later update
# step failed, rollback restored everything EXCEPT the refreshed GEMINI.md,
# returning the user to the original branch with a dirty file (PR #703
# review). A read-only .touchstone-manifest forces a deterministic failure
# after the block refresh but before the commit.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 4a-quater: failed update rolls back the refreshed GEMINI.md ---"

GEMROLLBACK_PROJECT="$TEST_DIR/gemini-rollback-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$GEMROLLBACK_PROJECT" --no-register >/dev/null
configure_git "$GEMROLLBACK_PROJECT"
awk '
  /<!-- touchstone:steering:start -->/ { print; print "STALE-GEMINI-ROLLBACK-MARKER"; inblock = 1; next }
  /<!-- touchstone:steering:end -->/   { print; inblock = 0; next }
  !inblock { print }
' "$GEMROLLBACK_PROJECT/GEMINI.md" >"$GEMROLLBACK_PROJECT/GEMINI.md.stale" \
  && mv "$GEMROLLBACK_PROJECT/GEMINI.md.stale" "$GEMROLLBACK_PROJECT/GEMINI.md"
echo "0000000000000000000000000000000000000004" >"$GEMROLLBACK_PROJECT/.touchstone-version"
commit_all "$GEMROLLBACK_PROJECT" "stale gemini block before failing update"
GEMROLLBACK_BRANCH="$(git -C "$GEMROLLBACK_PROJECT" rev-parse --abbrev-ref HEAD)"
chmod 444 "$GEMROLLBACK_PROJECT/.touchstone-manifest"

if (cd "$GEMROLLBACK_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") \
  >"$TEST_DIR/gemini-rollback-update.txt" 2>&1; then
  echo "FAIL: update against a read-only .touchstone-manifest should fail" >&2
  cat "$TEST_DIR/gemini-rollback-update.txt" >&2
  ERRORS=$((ERRORS + 1))
fi
chmod 644 "$GEMROLLBACK_PROJECT/.touchstone-manifest"
assert_contains "$GEMROLLBACK_PROJECT/GEMINI.md" "STALE-GEMINI-ROLLBACK-MARKER"
if [ "$(tr -d '[:space:]' <"$GEMROLLBACK_PROJECT/.touchstone-version")" != "0000000000000000000000000000000000000004" ]; then
  echo "FAIL: failed update advanced .touchstone-version" >&2
  ERRORS=$((ERRORS + 1))
fi
if [ "$(git -C "$GEMROLLBACK_PROJECT" rev-parse --abbrev-ref HEAD)" != "$GEMROLLBACK_BRANCH" ]; then
  echo "FAIL: failed update left the project off its original branch" >&2
  ERRORS=$((ERRORS + 1))
fi
if git -C "$GEMROLLBACK_PROJECT" status --porcelain | grep -q 'GEMINI.md'; then
  echo "FAIL: failed update left GEMINI.md dirty — the refreshed file is outside the rollback boundary" >&2
  git -C "$GEMROLLBACK_PROJECT" status --porcelain >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# A GEMINI.md whose managed block cannot be refreshed (orphaned sentinel)
# must FAIL the update. `|| true` swallowed the failure and the update
# committed the new .touchstone-version anyway, so automated sync treated the
# project as current and never retried while Gemini stayed on a stale or
# malformed contract (PR #703 review).
# --------------------------------------------------------------------------
echo ""
echo "--- Step 4a-quinquies: orphaned GEMINI.md sentinel fails the update, version not advanced ---"

GEMSENTINEL_PROJECT="$TEST_DIR/gemini-sentinel-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$GEMSENTINEL_PROJECT" --no-register >/dev/null
configure_git "$GEMSENTINEL_PROJECT"
grep -v 'touchstone:steering:end' "$GEMSENTINEL_PROJECT/GEMINI.md" \
  >"$GEMSENTINEL_PROJECT/GEMINI.md.orphaned" \
  && mv "$GEMSENTINEL_PROJECT/GEMINI.md.orphaned" "$GEMSENTINEL_PROJECT/GEMINI.md"
echo "0000000000000000000000000000000000000005" >"$GEMSENTINEL_PROJECT/.touchstone-version"
commit_all "$GEMSENTINEL_PROJECT" "orphaned gemini sentinel"
GEMSENTINEL_BRANCH="$(git -C "$GEMSENTINEL_PROJECT" rev-parse --abbrev-ref HEAD)"

if (cd "$GEMSENTINEL_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") \
  >"$TEST_DIR/gemini-sentinel-update.txt" 2>&1; then
  echo "FAIL: update should fail when the GEMINI.md managed block cannot be refreshed" >&2
  cat "$TEST_DIR/gemini-sentinel-update.txt" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$TEST_DIR/gemini-sentinel-update.txt" "orphaned"
assert_contains "$TEST_DIR/gemini-sentinel-update.txt" "could not refresh the touchstone-managed steering block in GEMINI.md"
if [ "$(tr -d '[:space:]' <"$GEMSENTINEL_PROJECT/.touchstone-version")" != "0000000000000000000000000000000000000005" ]; then
  echo "FAIL: block-apply failure still advanced .touchstone-version — automated sync will never retry" >&2
  ERRORS=$((ERRORS + 1))
fi
if [ "$(git -C "$GEMSENTINEL_PROJECT" rev-parse --abbrev-ref HEAD)" != "$GEMSENTINEL_BRANCH" ]; then
  echo "FAIL: failed update left the project off its original branch" >&2
  ERRORS=$((ERRORS + 1))
fi
if [ "$(git -C "$GEMSENTINEL_PROJECT" log -1 --pretty=%s)" != "orphaned gemini sentinel" ]; then
  echo "FAIL: block-apply failure still created an update commit" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# A project with BOTH driver files carrying stale managed blocks must have
# BOTH refreshed by one update run, into one update commit. In the wild
# (autumngarage/arpeggio, 2.12.0 -> 2.13.0) update refreshed AGENTS.md and
# silently left GEMINI.md steering Gemini toward removed `touchstone worker`
# commands — exactly the driver divergence the shared block exists to prevent
# (#762). The GEMINI-only case above (Step 4a-bis) removes AGENTS.md first,
# so it cannot catch a regression that couples GEMINI.md's refresh to
# AGENTS.md's or drops one file when both are present.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 4a-sexies: stale AGENTS.md and GEMINI.md blocks are both refreshed by one update ---"

BOTHDRIVERS_PROJECT="$TEST_DIR/both-drivers-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$BOTHDRIVERS_PROJECT" --no-register >/dev/null
configure_git "$BOTHDRIVERS_PROJECT"
for driver_file in AGENTS.md GEMINI.md; do
  awk '
    /<!-- touchstone:steering:start -->/ { print; print "STALE-BOTH-DRIVERS-MARKER"; inblock = 1; next }
    /<!-- touchstone:steering:end -->/   { print; inblock = 0; next }
    !inblock { print }
  ' "$BOTHDRIVERS_PROJECT/$driver_file" >"$BOTHDRIVERS_PROJECT/$driver_file.stale" \
    && mv "$BOTHDRIVERS_PROJECT/$driver_file.stale" "$BOTHDRIVERS_PROJECT/$driver_file"
done
echo "0000000000000000000000000000000000000006" >"$BOTHDRIVERS_PROJECT/.touchstone-version"
commit_all "$BOTHDRIVERS_PROJECT" "stale blocks in both driver files"

(cd "$BOTHDRIVERS_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >/dev/null 2>&1

for driver_file in AGENTS.md GEMINI.md; do
  assert_not_contains "$BOTHDRIVERS_PROJECT/$driver_file" "STALE-BOTH-DRIVERS-MARKER"
  assert_contains "$BOTHDRIVERS_PROJECT/$driver_file" "Required Delivery Workflow"
  if ! git -C "$BOTHDRIVERS_PROJECT" log -1 --name-only --pretty=format: | grep -qx "$driver_file"; then
    echo "FAIL: refreshed $driver_file must be staged into the same update commit" >&2
    ERRORS=$((ERRORS + 1))
  fi
done
# The refreshed blocks must be IDENTICAL across driver files — a generator
# that leaves them different reintroduces the divergence #762 documents.
BOTHDRIVERS_AGENTS_BLOCK="$(awk '/<!-- touchstone:steering:start -->/,/<!-- touchstone:steering:end -->/' "$BOTHDRIVERS_PROJECT/AGENTS.md")"
BOTHDRIVERS_GEMINI_BLOCK="$(awk '/<!-- touchstone:steering:start -->/,/<!-- touchstone:steering:end -->/' "$BOTHDRIVERS_PROJECT/GEMINI.md")"
if [ "$BOTHDRIVERS_AGENTS_BLOCK" != "$BOTHDRIVERS_GEMINI_BLOCK" ]; then
  echo "FAIL: AGENTS.md and GEMINI.md managed blocks diverge after update" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 3b: pre-existing AGENTS.md without the steering block gets the
# touchstone-managed block injected on update. This is the migration path
# for projects bootstrapped before the block existed — without it, non-
# Claude reviewers (Codex/Gemini) silently miss every engineering principle.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 4b: AGENTS.md without principles block gets backfilled on update ---"

cat >"$PROJECT/AGENTS.md" <<'EOF'
# AGENTS.md — AI Reviewer Guide for Test Project

You are reviewing PRs for Test Project.

## Specific review rules

- Project-specific rule that must survive the update.
EOF
echo "0000000000000000000000000000000000000002" >"$PROJECT/.touchstone-version"
commit_all "$PROJECT" "simulate pre-block AGENTS.md state"

(cd "$PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >/dev/null 2>&1

assert_contains "$PROJECT/AGENTS.md" "touchstone:steering:start"
assert_contains "$PROJECT/AGENTS.md" "touchstone:steering:end"
assert_contains "$PROJECT/AGENTS.md" "No band-aids"
# Project-specific content must survive injection.
assert_contains "$PROJECT/AGENTS.md" "Project-specific rule that must survive the update."
# H1 must remain on line 1.
first_line="$(head -n 1 "$PROJECT/AGENTS.md")"
if [ "$first_line" != "# AGENTS.md — AI Reviewer Guide for Test Project" ]; then
  echo "FAIL: AGENTS.md H1 not preserved on line 1: '$first_line'" >&2
  ERRORS=$((ERRORS + 1))
fi
# The update commit must include AGENTS.md (so the block ships in the same
# review boundary as the rest of the touchstone update).
if ! git -C "$PROJECT" log -1 --name-only --pretty=format: | grep -qx 'AGENTS.md'; then
  echo "FAIL: update commit must include AGENTS.md when the block was refreshed" >&2
  ERRORS=$((ERRORS + 1))
else
  echo "    PASS: AGENTS.md was backfilled with shared principles"
fi

# --------------------------------------------------------------------------
# Test 4: dirty worktrees fail before branching or patching.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 5: Dirty worktree is refused ---"

DIRTY_PROJECT="$TEST_DIR/dirty-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$DIRTY_PROJECT" --no-register >/dev/null
configure_git "$DIRTY_PROJECT"
commit_all "$DIRTY_PROJECT" "initial dirty test project"
echo "0000000000000000000000000000000000000002" >"$DIRTY_PROJECT/.touchstone-version"
commit_all "$DIRTY_PROJECT" "simulate old dirty test project"
DIRTY_BRANCH="$(git -C "$DIRTY_PROJECT" rev-parse --abbrev-ref HEAD)"
echo "# uncommitted change" >>"$DIRTY_PROJECT/scripts/open-pr.sh"
printf 'unrelated dirty work\n' >>"$DIRTY_PROJECT/README.md"
DIRTY_STATUS_BEFORE="$(git -C "$DIRTY_PROJECT" status --porcelain=v1)"
DIRTY_OPEN_PR_BEFORE="$(cat "$DIRTY_PROJECT/scripts/open-pr.sh")"
DIRTY_README_BEFORE="$(cat "$DIRTY_PROJECT/README.md")"

if (cd "$DIRTY_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --in-place) >"$TEST_DIR/dirty-output.txt" 2>&1; then
  echo "FAIL: expected dirty update to fail" >&2
  ERRORS=$((ERRORS + 1))
else
  assert_contains "$TEST_DIR/dirty-output.txt" 'Working tree is dirty'
fi

if [ "$(git -C "$DIRTY_PROJECT" rev-parse --abbrev-ref HEAD)" != "$DIRTY_BRANCH" ]; then
  echo "FAIL: dirty update should not switch branches" >&2
  ERRORS=$((ERRORS + 1))
fi
if [ "$(git -C "$DIRTY_PROJECT" status --porcelain=v1)" != "$DIRTY_STATUS_BEFORE" ] \
  || [ "$(cat "$DIRTY_PROJECT/scripts/open-pr.sh")" != "$DIRTY_OPEN_PR_BEFORE" ] \
  || [ "$(cat "$DIRTY_PROJECT/README.md")" != "$DIRTY_README_BEFORE" ]; then
  echo "FAIL: refused in-place update changed pre-existing dirty work" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_not_contains "$TEST_DIR/dirty-output.txt" 'rolling back in-place changes'

# --------------------------------------------------------------------------
# Test 5: failed updates restore ignored legacy metadata.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 6: Failed update rolls back legacy metadata ---"

ROLLBACK_PROJECT="$TEST_DIR/rollback-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$ROLLBACK_PROJECT" --no-register >/dev/null
configure_git "$ROLLBACK_PROJECT"
commit_all "$ROLLBACK_PROJECT" "initial rollback test project"
printf '\n.touchstone-version\n.touchstone-manifest\n' >>"$ROLLBACK_PROJECT/.gitignore"
git -C "$ROLLBACK_PROJECT" rm --cached .touchstone-version .touchstone-manifest >/dev/null
commit_all "$ROLLBACK_PROJECT" "simulate legacy ignored touchstone metadata"
echo "legacy-old-version" >"$ROLLBACK_PROJECT/.touchstone-version"
rm "$ROLLBACK_PROJECT/.touchstone-manifest"
mkdir "$ROLLBACK_PROJECT/.touchstone-manifest"
ROLLBACK_BRANCH="$(git -C "$ROLLBACK_PROJECT" rev-parse --abbrev-ref HEAD)"
printf 'unrelated rollback sentinel\n' >>"$ROLLBACK_PROJECT/README.md"
git -C "$ROLLBACK_PROJECT" add README.md
ROLLBACK_README_BEFORE="$(cat "$ROLLBACK_PROJECT/README.md")"
ROLLBACK_STATUS_BEFORE="$(git -C "$ROLLBACK_PROJECT" status --porcelain=v1)"

if (cd "$ROLLBACK_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >"$TEST_DIR/rollback-output.txt" 2>&1; then
  echo "FAIL: expected rollback update to fail on legacy manifest directory" >&2
  ERRORS=$((ERRORS + 1))
else
  assert_contains "$TEST_DIR/rollback-output.txt" 'Update failed; rolling back'
fi

if [ "$(git -C "$ROLLBACK_PROJECT" rev-parse --abbrev-ref HEAD)" != "$ROLLBACK_BRANCH" ]; then
  echo "FAIL: rollback should return to the original branch" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$(cat "$ROLLBACK_PROJECT/.touchstone-version")" = "legacy-old-version" ]; then
  echo "    PASS: rollback restored ignored .touchstone-version"
else
  echo "FAIL: rollback did not restore ignored .touchstone-version" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$(cat "$ROLLBACK_PROJECT/README.md")" != "$ROLLBACK_README_BEFORE" ] \
  || [ "$(git -C "$ROLLBACK_PROJECT" status --porcelain=v1)" != "$ROLLBACK_STATUS_BEFORE" ]; then
  echo "FAIL: rollback changed unrelated staged work" >&2
  ERRORS=$((ERRORS + 1))
fi

if git -C "$ROLLBACK_PROJECT" branch --list 'chore/touchstone-*' | grep -q .; then
  echo "FAIL: rollback should delete the failed update branch" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 5b: swift profile gains .swiftlint.yml on update without clobbering
# a hand-edited copy.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 5b: Swift project gains .swiftlint.yml on update ---"

SWIFT_UPDATE_PROJECT="$TEST_DIR/swift-update-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$SWIFT_UPDATE_PROJECT" --no-register --type swift >/dev/null
configure_git "$SWIFT_UPDATE_PROJECT"
commit_all "$SWIFT_UPDATE_PROJECT" "initial swift touchstone project"

# Simulate a stale touchstone version + a project that pre-existed the swiftlint
# template (so .swiftlint.yml was never created at bootstrap time).
rm -f "$SWIFT_UPDATE_PROJECT/.swiftlint.yml"
echo "0000000000000000000000000000000000000010" >"$SWIFT_UPDATE_PROJECT/.touchstone-version"
commit_all "$SWIFT_UPDATE_PROJECT" "simulate pre-swiftlint-template swift project"

(cd "$SWIFT_UPDATE_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >"$TEST_DIR/swift-update-output.txt" 2>&1

assert_contains "$TEST_DIR/swift-update-output.txt" 'added (project-owned).*\.swiftlint\.yml'
assert_exists "$SWIFT_UPDATE_PROJECT/.swiftlint.yml"
assert_contains "$SWIFT_UPDATE_PROJECT/.swiftlint.yml" '^  - \.build$'

# .swiftlint.yml stays out of .touchstone-manifest — it's project-owned, not
# touchstone-owned. Future updates must not include it in the touchstone-owned
# overwrite path.
if grep -qxF '.swiftlint.yml' "$SWIFT_UPDATE_PROJECT/.touchstone-manifest"; then
  echo "FAIL: .swiftlint.yml must NOT be in .touchstone-manifest (project-owned, not touchstone-owned)" >&2
  ERRORS=$((ERRORS + 1))
fi

# The newly added .swiftlint.yml must be staged in the update commit so
# `--ship` does not leave it behind.
if git -C "$SWIFT_UPDATE_PROJECT" log -1 --name-only --format='' | grep -qxF '.swiftlint.yml'; then
  echo "    PASS: .swiftlint.yml committed as part of the update"
else
  echo "FAIL: .swiftlint.yml was not committed in the update commit" >&2
  ERRORS=$((ERRORS + 1))
fi

# Re-run on a swift project that already has a hand-edited .swiftlint.yml —
# update must NOT clobber it. Use a sentinel string to verify the original
# bytes survive.
SWIFT_HAND_EDITED_PROJECT="$TEST_DIR/swift-hand-edited-update"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$SWIFT_HAND_EDITED_PROJECT" --no-register --type swift >/dev/null
configure_git "$SWIFT_HAND_EDITED_PROJECT"
printf 'SENTINEL_HAND_EDITED_SWIFTLINT\n' >"$SWIFT_HAND_EDITED_PROJECT/.swiftlint.yml"
commit_all "$SWIFT_HAND_EDITED_PROJECT" "initial swift project with hand-edited swiftlint"
echo "0000000000000000000000000000000000000011" >"$SWIFT_HAND_EDITED_PROJECT/.touchstone-version"
commit_all "$SWIFT_HAND_EDITED_PROJECT" "simulate stale touchstone state"

(cd "$SWIFT_HAND_EDITED_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >/dev/null 2>&1

assert_contains "$SWIFT_HAND_EDITED_PROJECT/.swiftlint.yml" '^SENTINEL_HAND_EDITED_SWIFTLINT$'

# Non-swift profiles must NOT receive .swiftlint.yml on update — the per-profile
# gate keeps the swift template out of unrelated projects.
NON_SWIFT_UPDATE_PROJECT="$TEST_DIR/non-swift-update-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$NON_SWIFT_UPDATE_PROJECT" --no-register --type python >/dev/null
configure_git "$NON_SWIFT_UPDATE_PROJECT"
commit_all "$NON_SWIFT_UPDATE_PROJECT" "initial python project"
echo "0000000000000000000000000000000000000012" >"$NON_SWIFT_UPDATE_PROJECT/.touchstone-version"
commit_all "$NON_SWIFT_UPDATE_PROJECT" "simulate stale python touchstone state"

(cd "$NON_SWIFT_UPDATE_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >/dev/null 2>&1

assert_not_exists "$NON_SWIFT_UPDATE_PROJECT/.swiftlint.yml"

# --------------------------------------------------------------------------
# Test 5c: --ship failure preserves the update branch but exits nonzero.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 5c: --ship failure exits nonzero ---"

SHIP_FAIL_PROJECT="$TEST_DIR/ship-fail-project"
SHIP_FAIL_BIN="$TEST_DIR/ship-fail-bin"
mkdir -p "$SHIP_FAIL_BIN"
cat >"$SHIP_FAIL_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "fake gh failure" >&2
exit 1
GHEOF
chmod +x "$SHIP_FAIL_BIN/gh"

bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$SHIP_FAIL_PROJECT" --no-register --type generic >/dev/null
configure_git "$SHIP_FAIL_PROJECT"
commit_all "$SHIP_FAIL_PROJECT" "initial ship-fail project"
rm "$SHIP_FAIL_PROJECT/scripts/claim-issue.sh"
echo "0000000000000000000000000000000000000013" >"$SHIP_FAIL_PROJECT/.touchstone-version"
commit_all "$SHIP_FAIL_PROJECT" "simulate stale ship-fail state"

SHIP_FAIL_OUT="$TEST_DIR/ship-fail-output.txt"
SHIP_FAIL_RC=0
(
  cd "$SHIP_FAIL_PROJECT"
  # Prepend rather than replace. This case wants everything working EXCEPT gh,
  # and a hardcoded system PATH drops wherever pre-commit lives — on
  # ubuntu-latest that is not /usr/bin, so the run died on hook readiness before
  # it ever reached the fake gh, and the assertion failed for the wrong reason.
  PATH="$SHIP_FAIL_BIN:$PATH" \
    bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --ship
) >"$SHIP_FAIL_OUT" 2>&1 || SHIP_FAIL_RC=$?

if [ "$SHIP_FAIL_RC" != "0" ] \
  && grep -q 'Ship failed' "$SHIP_FAIL_OUT" \
  && git -C "$SHIP_FAIL_PROJECT" branch --show-current | grep -q '^chore/touchstone-'; then
  echo "    PASS: --ship failure preserved branch and returned nonzero"
else
  echo "FAIL: --ship failure should preserve branch and exit nonzero" >&2
  echo "    rc=$SHIP_FAIL_RC" >&2
  cat "$SHIP_FAIL_OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# Test 6: check mode and ordinary commands do not print the old startup nag.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 7: Check mode and no broad startup nag ---"

CHECK_PROJECT="$TEST_DIR/check-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$CHECK_PROJECT" --no-register >/dev/null
configure_git "$CHECK_PROJECT"
commit_all "$CHECK_PROJECT" "initial check project"
rm "$CHECK_PROJECT/scripts/claim-issue.sh"
echo "0000000000000000000000000000000000000003" >"$CHECK_PROJECT/.touchstone-version"
commit_all "$CHECK_PROJECT" "simulate old check project"
CHECK_BRANCH="$(git -C "$CHECK_PROJECT" rev-parse --abbrev-ref HEAD)"

(cd "$CHECK_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --check) >"$TEST_DIR/check-output.txt" 2>&1
assert_contains "$TEST_DIR/check-output.txt" 'Needs update'
assert_contains "$TEST_DIR/check-output.txt" 'Run: touchstone update'

if [ "$(git -C "$CHECK_PROJECT" rev-parse --abbrev-ref HEAD)" != "$CHECK_BRANCH" ]; then
  echo "FAIL: update --check should not switch branches" >&2
  ERRORS=$((ERRORS + 1))
fi

(cd "$CHECK_PROJECT" && TOUCHSTONE_NO_AUTO_UPDATE=1 "$TOUCHSTONE_ROOT/bin/touchstone" detect) >"$TEST_DIR/detect-output.txt" 2>&1
assert_not_contains "$TEST_DIR/detect-output.txt" 'Needs update'

# --------------------------------------------------------------------------
# --ship must refuse when the effective hooks are not ready: the push would
# bypass deterministic pre-push validation (issue #515 / PR #638 review).
# The fixture's pre-push slot holds a wrong-typed shim (a pre-commit shim
# copy), which presence checks accept but the typed readiness predicate must
# reject before any ship handoff.
# --------------------------------------------------------------------------
echo ""
echo "--- Step: --ship refuses unready hooks ---"
SHIP_REFUSAL_PROJECT="$TEST_DIR/ship-refusal-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$SHIP_REFUSAL_PROJECT" --no-register >/dev/null
configure_git "$SHIP_REFUSAL_PROJECT"
commit_all "$SHIP_REFUSAL_PROJECT" "initial ship refusal project"
mkdir -p "$SHIP_REFUSAL_PROJECT/.git/hooks"
cat >"$SHIP_REFUSAL_PROJECT/.git/hooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
# File generated by pre-commit: https://pre-commit.com
ARGS=(hook-impl --config=.pre-commit-config.yaml --hook-type=pre-commit)
exit 0
EOF
cp "$SHIP_REFUSAL_PROJECT/.git/hooks/pre-commit" "$SHIP_REFUSAL_PROJECT/.git/hooks/pre-push"
chmod +x "$SHIP_REFUSAL_PROJECT/.git/hooks/pre-commit" "$SHIP_REFUSAL_PROJECT/.git/hooks/pre-push"
SHIP_REFUSAL_BRANCH="$(git -C "$SHIP_REFUSAL_PROJECT" branch --show-current)"
rm "$SHIP_REFUSAL_PROJECT/scripts/claim-issue.sh"
printf 'stale-version\n' >"$SHIP_REFUSAL_PROJECT/.touchstone-version"
commit_all "$SHIP_REFUSAL_PROJECT" "force stale version"
SHIP_REFUSAL_OUT="$TEST_DIR/ship-refusal-output.txt"
SHIP_REFUSAL_RC=0
(cd "$SHIP_REFUSAL_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --ship) \
  >"$SHIP_REFUSAL_OUT" 2>&1 || SHIP_REFUSAL_RC=$?
if [ "$SHIP_REFUSAL_RC" = "0" ]; then
  echo "FAIL: update --ship must exit nonzero when effective hooks are not ready" >&2
  cat "$SHIP_REFUSAL_OUT" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$SHIP_REFUSAL_OUT" 'ship refused: effective pre-commit/pre-push hooks are not ready'
assert_not_contains "$SHIP_REFUSAL_OUT" 'Shipping update via scripts/open-pr.sh'

# A project-owned setup.sh carrying the legacy core.hooksPath reset must be
# flagged on update — the fixed template never reaches existing projects, so
# the update warning is the migration surface (PR #638 review). A real
# (non-dry-run) update is required: dry runs and up-to-date projects exit
# before the hook section runs. The refused --ship above left the checkout on
# its chore/touchstone-* branch; return to the default branch first (#772),
# where scripts/claim-issue.sh is still missing, keeping content stale.
git -C "$SHIP_REFUSAL_PROJECT" checkout -q "$SHIP_REFUSAL_BRANCH"
printf '#!/usr/bin/env bash\ngit config --unset-all core.hooksPath 2>/dev/null || true\n' \
  >"$SHIP_REFUSAL_PROJECT/setup.sh"
printf 'stale-version-2\n' >"$SHIP_REFUSAL_PROJECT/.touchstone-version"
commit_all "$SHIP_REFUSAL_PROJECT" "legacy setup fixture"
LEGACY_SETUP_OUT="$TEST_DIR/legacy-setup-output.txt"
(cd "$SHIP_REFUSAL_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") \
  >"$LEGACY_SETUP_OUT" 2>&1 || true
assert_contains "$LEGACY_SETUP_OUT" 'legacy core.hooksPath reset'

# --------------------------------------------------------------------------
# #772: a branch-creating update must fork from the default branch. On a
# feature-branch checkout it refuses with the exact remedy instead of carrying
# the feature's commits into the chore PR (arpeggio#35, convoy#234).
# --------------------------------------------------------------------------
echo ""
echo "--- Step 8: update refuses to branch from a non-default checkout (#772) ---"

OFFDEFAULT_PROJECT="$TEST_DIR/off-default-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$OFFDEFAULT_PROJECT" --no-register >/dev/null
configure_git "$OFFDEFAULT_PROJECT"
commit_all "$OFFDEFAULT_PROJECT" "initial off-default project"
OFFDEFAULT_BASE="$(git -C "$OFFDEFAULT_PROJECT" branch --show-current)"
# Genuine staleness on the default branch, inherited by the feature branch.
rm "$OFFDEFAULT_PROJECT/scripts/claim-issue.sh"
echo "0000000000000000000000000000000000000017" >"$OFFDEFAULT_PROJECT/.touchstone-version"
commit_all "$OFFDEFAULT_PROJECT" "simulate stale state on default branch"
git -C "$OFFDEFAULT_PROJECT" checkout -q -b feature/in-flight
printf 'feature work\n' >"$OFFDEFAULT_PROJECT/feature.txt"
commit_all "$OFFDEFAULT_PROJECT" "feature commit that must not ship in a chore PR"
OFFDEFAULT_FEATURE_HEAD="$(git -C "$OFFDEFAULT_PROJECT" rev-parse HEAD)"

OFFDEFAULT_RC=0
(cd "$OFFDEFAULT_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") \
  >"$TEST_DIR/off-default-output.txt" 2>&1 || OFFDEFAULT_RC=$?

if [ "$OFFDEFAULT_RC" = "0" ]; then
  echo "FAIL: update must refuse to create a chore/touchstone-* branch from a feature-branch checkout (#772)" >&2
  cat "$TEST_DIR/off-default-output.txt" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_contains "$TEST_DIR/off-default-output.txt" "git checkout $OFFDEFAULT_BASE && git pull --rebase"
if git -C "$OFFDEFAULT_PROJECT" branch --list 'chore/touchstone-*' | grep -q .; then
  echo "FAIL: refused off-default update still created a chore/touchstone-* branch" >&2
  ERRORS=$((ERRORS + 1))
fi
if [ "$(git -C "$OFFDEFAULT_PROJECT" branch --show-current)" != "feature/in-flight" ]; then
  echo "FAIL: refused off-default update moved the checkout off the feature branch" >&2
  ERRORS=$((ERRORS + 1))
fi
if [ "$(git -C "$OFFDEFAULT_PROJECT" rev-parse HEAD)" != "$OFFDEFAULT_FEATURE_HEAD" ]; then
  echo "FAIL: refused off-default update changed the feature branch head" >&2
  ERRORS=$((ERRORS + 1))
fi

# Same project from the default branch: the update proceeds, forks from the
# default-branch head, and never contains the feature commit.
git -C "$OFFDEFAULT_PROJECT" checkout -q "$OFFDEFAULT_BASE"
OFFDEFAULT_BASE_HEAD="$(git -C "$OFFDEFAULT_PROJECT" rev-parse HEAD)"
(cd "$OFFDEFAULT_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") \
  >"$TEST_DIR/off-default-ok-output.txt" 2>&1
assert_contains "$TEST_DIR/off-default-ok-output.txt" 'Creating update branch: chore/touchstone-'
assert_contains "$TEST_DIR/off-default-ok-output.txt" 'Committed: chore: update touchstone to'
if [ "$(git -C "$OFFDEFAULT_PROJECT" rev-parse HEAD^)" != "$OFFDEFAULT_BASE_HEAD" ]; then
  echo "FAIL: default-branch update commit should fork from the default-branch head" >&2
  ERRORS=$((ERRORS + 1))
fi
if git -C "$OFFDEFAULT_PROJECT" log --format=%H | grep -q "$OFFDEFAULT_FEATURE_HEAD"; then
  echo "FAIL: chore update branch contains the feature branch's commit (#772)" >&2
  ERRORS=$((ERRORS + 1))
fi

# --------------------------------------------------------------------------
# #773: the arpeggio state — every managed file byte-identical to the
# installed touchstone, but the stamp records a different identity (a build
# SHA). The tree must NOT read as stale: no "Needs update", no update branch,
# no stale-guard refusal. Genuinely stale content must still be refused.
# --------------------------------------------------------------------------
echo ""
echo "--- Step 9: stamp identity differs but content matches -> not stale (#773) ---"

STAMP_PROJECT="$TEST_DIR/stamp-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$STAMP_PROJECT" --no-register >/dev/null
configure_git "$STAMP_PROJECT"
commit_all "$STAMP_PROJECT" "initial stamp project"
STAMP_BRANCH="$(git -C "$STAMP_PROJECT" branch --show-current)"
echo "ffffffffffffffffffffffffffffffffffffffff" >"$STAMP_PROJECT/.touchstone-version"
commit_all "$STAMP_PROJECT" "simulate sha-stamped content-identical tree"

(cd "$STAMP_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --check) \
  >"$TEST_DIR/stamp-check-output.txt" 2>&1
assert_contains "$TEST_DIR/stamp-check-output.txt" 'Already up to date'
assert_not_contains "$TEST_DIR/stamp-check-output.txt" 'Needs update'

(cd "$STAMP_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") \
  >"$TEST_DIR/stamp-update-output.txt" 2>&1
assert_contains "$TEST_DIR/stamp-update-output.txt" 'Already up to date'
if git -C "$STAMP_PROJECT" branch --list 'chore/touchstone-*' | grep -q .; then
  echo "FAIL: content-identical tree must not produce an update branch (#773)" >&2
  ERRORS=$((ERRORS + 1))
fi
if [ "$(tr -d '[:space:]' <"$STAMP_PROJECT/.touchstone-version")" != "ffffffffffffffffffffffffffffffffffffffff" ]; then
  echo "FAIL: content-identical tree must not have its stamp rewritten outside a reviewable update" >&2
  ERRORS=$((ERRORS + 1))
fi

# The stale-guard path that blocked every arpeggio PR: a workflow script on a
# feature branch must NOT refuse when only the stamp identity differs.
# Fork explicitly from the sha-stamped base branch: without this, code that
# creates an update branch above (the pre-#773 behavior) leaves HEAD on the
# chore branch with a rewritten stamp, and this sub-case would pass for the
# wrong reason instead of exercising the identity mismatch.
git -C "$STAMP_PROJECT" checkout -q "$STAMP_BRANCH"
git -C "$STAMP_PROJECT" checkout -q -b feature/stamp-work
STAMP_GUARD_OUT="$TEST_DIR/stamp-guard-output.txt"
# rc is not discriminating here (merge-pr's usage error and a guard refusal
# both exit 2); the output assertions below carry the regression.
(
  cd "$STAMP_PROJECT"
  PATH="$SCRIPT_SYNC_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    TOUCHSTONE_BIN="$TOUCHSTONE_ROOT/bin/touchstone" \
    TOUCHSTONE_SCRIPT_SYNC_FAKE_LOG="$TEST_DIR/stamp-guard.log" \
    bash scripts/merge-pr.sh not-a-pr
) >"$STAMP_GUARD_OUT" 2>&1 || true

assert_not_contains "$STAMP_GUARD_OUT" 'project-local workflow files are stale'
assert_contains "$STAMP_GUARD_OUT" 'Usage: bash scripts/merge-pr.sh <pr-number>'

# Genuinely stale managed content must still read as stale.
git -C "$STAMP_PROJECT" checkout -q "$STAMP_BRANCH"
printf '# genuinely stale managed drift\n' >>"$STAMP_PROJECT/lib/toml.sh"
commit_all "$STAMP_PROJECT" "simulate genuinely stale managed content"

(cd "$STAMP_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --check) \
  >"$TEST_DIR/stamp-stale-check-output.txt" 2>&1
assert_contains "$TEST_DIR/stamp-stale-check-output.txt" 'Needs update'
assert_not_contains "$TEST_DIR/stamp-stale-check-output.txt" 'Already up to date'

echo "--- Step 10: probe hardening — default-branch authority, symlinks, ledger, tracking (PR #780 review) ---"

# (a) P1: init.defaultBranch must not be trusted. A remoteless repo whose
# init.defaultBranch names the checked-out FEATURE branch must still refuse:
# the authoritative-or-unambiguous rule resolves 'main', not the config.
P780_PROJECT="$TEST_DIR/p780-project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$P780_PROJECT" --no-register >/dev/null
configure_git "$P780_PROJECT"
commit_all "$P780_PROJECT" "initial p780 project"
echo "ffffffffffffffffffffffffffffffffffffffff" >"$P780_PROJECT/.touchstone-version"
commit_all "$P780_PROJECT" "sha stamp so identity differs"
git -C "$P780_PROJECT" config init.defaultBranch work
git -C "$P780_PROJECT" checkout -q -b work
printf 'wip\n' >"$P780_PROJECT/feature-note.txt"
git -C "$P780_PROJECT" add feature-note.txt
git -C "$P780_PROJECT" -c user.name=T -c user.email=t@e.invalid commit --no-verify -qm "feature wip"
printf '# drift so the update has work\n' >>"$P780_PROJECT/lib/toml.sh"
git -C "$P780_PROJECT" add lib/toml.sh
git -C "$P780_PROJECT" -c user.name=T -c user.email=t@e.invalid commit --no-verify -qm "stale managed content"
(cd "$P780_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") \
  >"$TEST_DIR/p780-initdefault-output.txt" 2>&1 || true
assert_contains "$TEST_DIR/p780-initdefault-output.txt" "refusing to create an update branch from 'work'"
if git -C "$P780_PROJECT" branch --list 'chore/touchstone-*' | grep -q .; then
  echo "FAIL: init.defaultBranch must not authorize forking from a feature branch (PR #780 P1)" >&2
  ERRORS=$((ERRORS + 1))
fi
git -C "$P780_PROJECT" checkout -q main

# (b) A symlinked managed destination is never "current" — the writer would
# refuse or replace it, so the probe must report Needs update.
SYML_PROJECT="$TEST_DIR/p780-symlink"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$SYML_PROJECT" --no-register >/dev/null
configure_git "$SYML_PROJECT"
commit_all "$SYML_PROJECT" "initial symlink project"
echo "ffffffffffffffffffffffffffffffffffffffff" >"$SYML_PROJECT/.touchstone-version"
mv "$SYML_PROJECT/scripts/open-pr.sh" "$SYML_PROJECT/scripts/open-pr.real.sh"
ln -s "open-pr.real.sh" "$SYML_PROJECT/scripts/open-pr.sh"
commit_all "$SYML_PROJECT" "sha stamp + symlinked managed script"
(cd "$SYML_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --check) \
  >"$TEST_DIR/p780-symlink-output.txt" 2>&1
assert_contains "$TEST_DIR/p780-symlink-output.txt" 'Needs update'
assert_not_contains "$TEST_DIR/p780-symlink-output.txt" 'Already up to date'

# (c) An outdated ledger is stale content even when every file matches.
LEDGER_PROJECT="$TEST_DIR/p780-ledger"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$LEDGER_PROJECT" --no-register >/dev/null
configure_git "$LEDGER_PROJECT"
commit_all "$LEDGER_PROJECT" "initial ledger project"
echo "ffffffffffffffffffffffffffffffffffffffff" >"$LEDGER_PROJECT/.touchstone-version"
grep -v '^scripts/open-pr\.sh$' "$LEDGER_PROJECT/.touchstone-manifest" >"$LEDGER_PROJECT/.touchstone-manifest.tmp"
mv "$LEDGER_PROJECT/.touchstone-manifest.tmp" "$LEDGER_PROJECT/.touchstone-manifest"
commit_all "$LEDGER_PROJECT" "sha stamp + manifest missing an entry"
(cd "$LEDGER_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --check) \
  >"$TEST_DIR/p780-ledger-output.txt" 2>&1
assert_contains "$TEST_DIR/p780-ledger-output.txt" 'Needs update'
assert_not_contains "$TEST_DIR/p780-ledger-output.txt" 'Already up to date'

# (d) Correct bytes but untracked in the index is not current — clean clones
# would miss the file; the update's force-stage is the heal.
UNTRACKED_PROJECT="$TEST_DIR/p780-untracked"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$UNTRACKED_PROJECT" --no-register >/dev/null
configure_git "$UNTRACKED_PROJECT"
commit_all "$UNTRACKED_PROJECT" "initial untracked project"
echo "ffffffffffffffffffffffffffffffffffffffff" >"$UNTRACKED_PROJECT/.touchstone-version"
commit_all "$UNTRACKED_PROJECT" "sha stamp"
# rm --cached stages the removal; a plain commit keeps the file untracked
# (commit_all would re-add it and defeat the fixture).
git -C "$UNTRACKED_PROJECT" rm -q --cached scripts/open-pr.sh
git -C "$UNTRACKED_PROJECT" -c user.name=T -c user.email=t@e.invalid commit --no-verify -qm "untrack managed script"
(cd "$UNTRACKED_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --check) \
  >"$TEST_DIR/p780-untracked-output.txt" 2>&1
assert_contains "$TEST_DIR/p780-untracked-output.txt" 'Needs update'
assert_not_contains "$TEST_DIR/p780-untracked-output.txt" 'Already up to date'

# (e) The content-current early exit still reconciles state OUTSIDE the
# project tree: a deleted effective hook is reinstalled by a plain update run
# that changes nothing in the project.
HOOKS_PROJECT="$TEST_DIR/p780-hooks"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$HOOKS_PROJECT" --no-register >/dev/null
configure_git "$HOOKS_PROJECT"
commit_all "$HOOKS_PROJECT" "initial hooks project"
echo "ffffffffffffffffffffffffffffffffffffffff" >"$HOOKS_PROJECT/.touchstone-version"
commit_all "$HOOKS_PROJECT" "sha stamp only"
HOOKS_PATH="$(git -C "$HOOKS_PROJECT" config core.hooksPath || echo .git/hooks)"
rm -f "$HOOKS_PROJECT/$HOOKS_PATH/pre-commit" "$HOOKS_PROJECT/.git/hooks/pre-commit" 2>/dev/null || true
(cd "$HOOKS_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") \
  >"$TEST_DIR/p780-hooks-output.txt" 2>&1
assert_contains "$TEST_DIR/p780-hooks-output.txt" 'Already up to date'
if [ ! -f "$HOOKS_PROJECT/$HOOKS_PATH/pre-commit" ] && [ ! -f "$HOOKS_PROJECT/.git/hooks/pre-commit" ]; then
  echo "FAIL: content-current early exit must still reinstall missing git hooks (PR #780 review)" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "--- Step 11: probe soundness for metadata paths and the index blob (PR #780 round 2) ---"

# (a) A symlinked .touchstone-manifest is never current.
MSYM_PROJECT="$TEST_DIR/p780b-manifest-symlink"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$MSYM_PROJECT" --no-register >/dev/null
configure_git "$MSYM_PROJECT"
commit_all "$MSYM_PROJECT" "initial"
echo "ffffffffffffffffffffffffffffffffffffffff" >"$MSYM_PROJECT/.touchstone-version"
mv "$MSYM_PROJECT/.touchstone-manifest" "$MSYM_PROJECT/.touchstone-manifest.real"
ln -s ".touchstone-manifest.real" "$MSYM_PROJECT/.touchstone-manifest"
commit_all "$MSYM_PROJECT" "symlinked manifest"
(cd "$MSYM_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --check) \
  >"$TEST_DIR/p780b-msym-output.txt" 2>&1
assert_contains "$TEST_DIR/p780b-msym-output.txt" 'Needs update'
assert_not_contains "$TEST_DIR/p780b-msym-output.txt" 'Already up to date'

# (b) An untracked-but-byte-identical .claude/settings.json is not current.
MTRACK_PROJECT="$TEST_DIR/p780b-settings-untracked"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$MTRACK_PROJECT" --no-register >/dev/null
configure_git "$MTRACK_PROJECT"
commit_all "$MTRACK_PROJECT" "initial"
echo "ffffffffffffffffffffffffffffffffffffffff" >"$MTRACK_PROJECT/.touchstone-version"
commit_all "$MTRACK_PROJECT" "sha stamp"
git -C "$MTRACK_PROJECT" rm -q --cached .claude/settings.json
git -C "$MTRACK_PROJECT" -c user.name=T -c user.email=t@e.invalid commit --no-verify -qm "untrack settings"
(cd "$MTRACK_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --check) \
  >"$TEST_DIR/p780b-mtrack-output.txt" 2>&1
assert_contains "$TEST_DIR/p780b-mtrack-output.txt" 'Needs update'
assert_not_contains "$TEST_DIR/p780b-mtrack-output.txt" 'Already up to date'

# (c) A stale STAGED blob under clean working-tree bytes is not current —
# committing after a green probe would commit the stale blob.
BLOB_PROJECT="$TEST_DIR/p780b-staged-blob"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$BLOB_PROJECT" --no-register >/dev/null
configure_git "$BLOB_PROJECT"
commit_all "$BLOB_PROJECT" "initial"
echo "ffffffffffffffffffffffffffffffffffffffff" >"$BLOB_PROJECT/.touchstone-version"
commit_all "$BLOB_PROJECT" "sha stamp"
cp "$BLOB_PROJECT/lib/toml.sh" "$TEST_DIR/toml-good.sh"
printf '# stale staged content\n' >>"$BLOB_PROJECT/lib/toml.sh"
git -C "$BLOB_PROJECT" add lib/toml.sh
cp "$TEST_DIR/toml-good.sh" "$BLOB_PROJECT/lib/toml.sh"
(cd "$BLOB_PROJECT" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" --check) \
  >"$TEST_DIR/p780b-blob-output.txt" 2>&1
assert_contains "$TEST_DIR/p780b-blob-output.txt" 'Needs update'
assert_not_contains "$TEST_DIR/p780b-blob-output.txt" 'Already up to date'

# --------------------------------------------------------------------------
# Results
# --------------------------------------------------------------------------
echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: all assertions passed"
  exit 0
else
  echo "==> FAIL: $ERRORS assertion(s) failed"
  exit 1
fi
