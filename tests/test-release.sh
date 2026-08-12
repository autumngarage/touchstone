#!/usr/bin/env bash
#
# tests/test-release.sh — release workflow guardrails.
#
# Scenarios:
#   1. gh auth preflight fails closed before any repo mutation.
#   2. The version bump ships via a release PR (scripts/open-pr.sh
#      --auto-merge), and the tag targets the squash-merged main commit —
#      not the release-branch head, and never a direct push to main.
#   3. A stalled release PR fails closed: no tag, no release, resume
#      commands named.
#   4. --finalize run from a worktree that cannot check out main still
#      succeeds: detach fallback, no post-publication failure.
#   5. An existing draft GitHub release is published (drafts never emit
#      release.published), not reported as already complete.
#   6. An already-published release makes a rerun a no-op.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-release.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"

# Fake gh: behavior is driven by FAKE_GH_* env vars so each scenario can
# steer auth and merge outcomes without rewriting the stub.
cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_GH_LOG:?}"
case "${1:-} ${2:-}" in
  "auth status") exit "${FAKE_GH_AUTH_STATUS_RC:-0}" ;;
  "pr view")
    if [ -n "${FAKE_MERGE_SHA_FILE:-}" ] && [ -s "$FAKE_MERGE_SHA_FILE" ]; then
      printf 'MERGED %s\n' "$(cat "$FAKE_MERGE_SHA_FILE")"
      exit 0
    fi
    exit 1
    ;;
  "release view")
    case "${FAKE_GH_RELEASE_STATE:-absent}" in
      draft) printf 'true\n' && exit 0 ;;
      published) printf 'false\n' && exit 0 ;;
    esac
    exit 1
    ;;
  "release edit") exit 0 ;;
  "release create") exit 0 ;;
esac
exit 1
EOF
chmod +x "$FAKE_BIN/gh"

# Build an isolated project repo (VERSION 1.2.3 on main) with a bare origin
# and a fake scripts/open-pr.sh that simulates GitHub's squash-merge: a NEW
# commit lands on origin/main whose sha differs from the branch head.
setup_project() {
  local dir="$1"
  PROJECT="$dir/project"
  ORIGIN="$dir/origin.git"
  OUT="$dir/release.out"
  FAKE_GH_LOG="$dir/gh.log"
  FAKE_OPENPR_LOG="$dir/open-pr.log"
  FAKE_MERGE_SHA_FILE="$dir/merge-sha"
  FAKE_BRANCH_HEAD_FILE="$dir/branch-head"
  export FAKE_GH_LOG FAKE_OPENPR_LOG FAKE_MERGE_SHA_FILE FAKE_BRANCH_HEAD_FILE

  mkdir -p "$PROJECT/lib" "$PROJECT/scripts"
  cp "$REPO_ROOT/lib/colors.sh" "$PROJECT/lib/colors.sh"
  printf '1.2.3\n' >"$PROJECT/VERSION"
  printf '1.2.3\n' >"$PROJECT/.touchstone-version"
  write_fake_open_pr "$PROJECT/scripts/open-pr.sh"

  git -C "$PROJECT" init -q
  git -C "$PROJECT" checkout -q -b main
  git -C "$PROJECT" config user.email test@example.test
  git -C "$PROJECT" config user.name "Touchstone Test"
  git -C "$PROJECT" add VERSION .touchstone-version lib/colors.sh scripts/open-pr.sh
  git -C "$PROJECT" commit -q -m "initial"
  INITIAL_HEAD="$(git -C "$PROJECT" rev-parse HEAD)"

  git init --bare -q "$ORIGIN"
  git -C "$PROJECT" remote add origin "$ORIGIN"
  git -C "$PROJECT" push -q -u origin main
}

write_fake_open_pr() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
branch="$(git branch --show-current)"
printf 'open-pr %s branch=%s\n' "$*" "$branch" >>"${FAKE_OPENPR_LOG:?}"
if [ "${FAKE_OPENPR_MODE:-merge}" = "fail" ]; then
  exit 1
fi
git rev-parse HEAD >"${FAKE_BRANCH_HEAD_FILE:?}"
git push -q -u origin "$branch"
git fetch -q origin main
merge_sha="$(git commit-tree "$(git rev-parse 'HEAD^{tree}')" \
  -p "$(git rev-parse origin/main)" -m "${branch#release/} (#1)")"
git push -q origin "${merge_sha}:refs/heads/main"
printf '%s\n' "$merge_sha" >"${FAKE_MERGE_SHA_FILE:?}"
EOF
  chmod +x "$1"
}

run_release() {
  set +e
  (
    export TOUCHSTONE_ROOT="$PROJECT"
    export PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
    # shellcheck source=../lib/release.sh
    source "$REPO_ROOT/lib/release.sh"
    touchstone_release patch
  ) >"$OUT" 2>&1
  RELEASE_STATUS=$?
  set -e
}

run_finalize() {
  local root="$1" version="$2"
  set +e
  (
    export TOUCHSTONE_ROOT="$root"
    export PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
    # shellcheck source=../lib/release.sh
    source "$REPO_ROOT/lib/release.sh"
    touchstone_release_finalize "$version"
  ) >"$OUT" 2>&1
  RELEASE_STATUS=$?
  set -e
}

# --- Scenario 1: auth preflight fails closed before any mutation ------------

setup_project "$TEST_DIR/auth"
export FAKE_GH_AUTH_STATUS_RC=1
run_release

if [ "$RELEASE_STATUS" -eq 0 ]; then
  echo "FAIL: release should fail when gh is unauthenticated" >&2
  cat "$OUT" >&2
  exit 1
fi

if [ "$(tr -d '[:space:]' <"$PROJECT/VERSION")" != "1.2.3" ] \
  || [ "$(tr -d '[:space:]' <"$PROJECT/.touchstone-version")" != "1.2.3" ]; then
  echo "FAIL: release auth preflight mutated version files" >&2
  cat "$OUT" >&2
  exit 1
fi

if [ "$(git -C "$PROJECT" rev-parse HEAD)" != "$INITIAL_HEAD" ]; then
  echo "FAIL: release auth preflight created a commit" >&2
  cat "$OUT" >&2
  exit 1
fi

if git -C "$PROJECT" rev-parse -q --verify refs/tags/v1.2.4 >/dev/null; then
  echo "FAIL: release auth preflight created a tag" >&2
  cat "$OUT" >&2
  exit 1
fi

if git -C "$PROJECT" show-ref --verify --quiet refs/heads/release/v1.2.4; then
  echo "FAIL: release auth preflight created a release branch" >&2
  cat "$OUT" >&2
  exit 1
fi

if ! grep -q '^auth status --hostname github.com$' "$FAKE_GH_LOG"; then
  echo "FAIL: release did not check gh auth status" >&2
  cat "$OUT" >&2
  exit 1
fi

if grep -q '^release create ' "$FAKE_GH_LOG"; then
  echo "FAIL: release tried to create GitHub release after failed auth preflight" >&2
  cat "$OUT" >&2
  exit 1
fi

if ! grep -q 'gh auth login' "$OUT"; then
  echo "FAIL: release auth failure should print actionable login guidance" >&2
  cat "$OUT" >&2
  exit 1
fi

echo "PASS: release auth preflight fails before VERSION, commit, branch, or tag mutation"

# --- Scenario 2: bump ships via a release PR; tag targets the merged commit -

setup_project "$TEST_DIR/pr-flow"
export FAKE_GH_AUTH_STATUS_RC=0
export FAKE_OPENPR_MODE=merge
run_release

if [ "$RELEASE_STATUS" -ne 0 ]; then
  echo "FAIL: PR-based release should succeed" >&2
  cat "$OUT" >&2
  exit 1
fi

if [ ! -f "$FAKE_OPENPR_LOG" ] \
  || ! grep -q -- '--auto-merge' "$FAKE_OPENPR_LOG" \
  || ! grep -q 'branch=release/v1.2.4' "$FAKE_OPENPR_LOG"; then
  echo "FAIL: version bump must ship via scripts/open-pr.sh --auto-merge from release/v1.2.4" >&2
  cat "$OUT" >&2
  exit 1
fi

MERGE_SHA="$(cat "$FAKE_MERGE_SHA_FILE")"
BRANCH_HEAD="$(cat "$FAKE_BRANCH_HEAD_FILE")"

if [ "$MERGE_SHA" = "$BRANCH_HEAD" ]; then
  echo "FAIL: test fixture invalid — squash-merge sha must differ from branch head" >&2
  exit 1
fi

# origin/main advanced ONLY via the simulated squash-merge: a direct push
# from the release helper would leave a different head here.
if [ "$(git --git-dir="$ORIGIN" rev-parse refs/heads/main)" != "$MERGE_SHA" ]; then
  echo "FAIL: origin main must advance only via the PR squash-merge, not a direct push" >&2
  cat "$OUT" >&2
  exit 1
fi

if [ "$(git --git-dir="$ORIGIN" rev-parse 'refs/tags/v1.2.4^{commit}' 2>/dev/null)" != "$MERGE_SHA" ]; then
  echo "FAIL: pushed tag v1.2.4 must target the squash-merged main commit" >&2
  cat "$OUT" >&2
  exit 1
fi

if [ "$(git -C "$PROJECT" rev-parse 'refs/tags/v1.2.4^{commit}')" != "$MERGE_SHA" ]; then
  echo "FAIL: local tag v1.2.4 must target the squash-merged main commit, not the branch head" >&2
  cat "$OUT" >&2
  exit 1
fi

if ! grep -q '^pr view release/v1.2.4 ' "$FAKE_GH_LOG"; then
  echo "FAIL: release must resolve the merged commit from the PR record" >&2
  cat "$FAKE_GH_LOG" >&2
  exit 1
fi

if ! grep -q '^release create v1.2.4 ' "$FAKE_GH_LOG"; then
  echo "FAIL: release must create the GitHub release for v1.2.4" >&2
  cat "$FAKE_GH_LOG" >&2
  exit 1
fi

if [ "$(git -C "$PROJECT" branch --show-current)" != "main" ] \
  || [ "$(git -C "$PROJECT" rev-parse HEAD)" != "$MERGE_SHA" ]; then
  echo "FAIL: release must end on main synced to the merged commit" >&2
  cat "$OUT" >&2
  exit 1
fi

if [ "$(git -C "$PROJECT" show main:VERSION | tr -d '[:space:]')" != "1.2.4" ]; then
  echo "FAIL: merged main must carry VERSION 1.2.4" >&2
  cat "$OUT" >&2
  exit 1
fi

if git -C "$PROJECT" show-ref --verify --quiet refs/heads/release/v1.2.4; then
  echo "FAIL: local release branch should be deleted after the release completes" >&2
  cat "$OUT" >&2
  exit 1
fi

echo "PASS: version bump lands via a release PR and the tag targets the squash-merged main commit"

# --- Scenario 3: stalled release PR fails closed with resume commands -------

setup_project "$TEST_DIR/stall"
export FAKE_GH_AUTH_STATUS_RC=0
export FAKE_OPENPR_MODE=fail
run_release
unset FAKE_OPENPR_MODE

if [ "$RELEASE_STATUS" -eq 0 ]; then
  echo "FAIL: release must fail closed when the release PR does not merge" >&2
  cat "$OUT" >&2
  exit 1
fi

if git -C "$PROJECT" rev-parse -q --verify refs/tags/v1.2.4 >/dev/null \
  || git --git-dir="$ORIGIN" rev-parse -q --verify refs/tags/v1.2.4 >/dev/null; then
  echo "FAIL: an unmerged release PR must not produce a tag" >&2
  cat "$OUT" >&2
  exit 1
fi

if [ "$(git --git-dir="$ORIGIN" rev-parse refs/heads/main)" != "$INITIAL_HEAD" ]; then
  echo "FAIL: an unmerged release PR must not move origin main" >&2
  cat "$OUT" >&2
  exit 1
fi

if grep -q '^release create ' "$FAKE_GH_LOG"; then
  echo "FAIL: an unmerged release PR must not create a GitHub release" >&2
  cat "$FAKE_GH_LOG" >&2
  exit 1
fi

if ! grep -q -- '--round-budget-override' "$OUT" \
  || ! grep -q -- 'release --finalize v1.2.4' "$OUT" \
  || ! grep -q -- 'open-pr.sh --auto-merge' "$OUT"; then
  echo "FAIL: stall message must name the exact resume commands" >&2
  cat "$OUT" >&2
  exit 1
fi

if [ "$(git -C "$PROJECT" branch --show-current)" != "release/v1.2.4" ]; then
  echo "FAIL: a stalled release should leave the release branch in place for resume" >&2
  cat "$OUT" >&2
  exit 1
fi

echo "PASS: stalled release PR fails closed — no tag, no release, resume commands named"

# --- Scenario 4: --finalize from a worktree that cannot own main ------------
# main stays checked out in the primary working copy; finalize runs from a
# linked worktree on the release branch. The tag and GitHub release are
# published before the local-main cleanup, so an impossible
# `git checkout main` here must not turn a completed release into a failure.

setup_project "$TEST_DIR/wt-finalize"
export FAKE_GH_AUTH_STATUS_RC=0

# Manufacture the merged release PR: bump on the release branch, then let
# the fake open-pr.sh simulate the squash-merge onto origin/main.
git -C "$PROJECT" checkout -q -b release/v1.2.4
printf '1.2.4\n' >"$PROJECT/VERSION"
printf '1.2.4\n' >"$PROJECT/.touchstone-version"
git -C "$PROJECT" add VERSION .touchstone-version
git -C "$PROJECT" commit -q -m "v1.2.4"
(cd "$PROJECT" && FAKE_OPENPR_MODE=merge bash scripts/open-pr.sh --auto-merge) >/dev/null

git -C "$PROJECT" checkout -q main
WT="$TEST_DIR/wt-finalize/wt"
git -C "$PROJECT" worktree add -q "$WT" release/v1.2.4
run_finalize "$WT" v1.2.4

MERGE_SHA="$(cat "$FAKE_MERGE_SHA_FILE")"

if [ "$RELEASE_STATUS" -ne 0 ]; then
  echo "FAIL: finalize must succeed when main is checked out in another worktree" >&2
  cat "$OUT" >&2
  exit 1
fi

if [ "$(git --git-dir="$ORIGIN" rev-parse 'refs/tags/v1.2.4^{commit}' 2>/dev/null)" != "$MERGE_SHA" ]; then
  echo "FAIL: worktree finalize must still push the tag at the squash-merged main commit" >&2
  cat "$OUT" >&2
  exit 1
fi

if ! grep -q '^release create v1.2.4 ' "$FAKE_GH_LOG"; then
  echo "FAIL: worktree finalize must create the GitHub release" >&2
  cat "$FAKE_GH_LOG" >&2
  exit 1
fi

if [ "$(git -C "$PROJECT" branch --show-current)" != "main" ]; then
  echo "FAIL: finalize must not steal main from the worktree that owns it" >&2
  cat "$OUT" >&2
  exit 1
fi

if [ -n "$(git -C "$WT" branch --show-current)" ] \
  || [ "$(git -C "$WT" rev-parse HEAD)" != "$MERGE_SHA" ]; then
  echo "FAIL: the release worktree should end detached at the released commit" >&2
  cat "$OUT" >&2
  exit 1
fi

if git -C "$PROJECT" show-ref --verify --quiet refs/heads/release/v1.2.4; then
  echo "FAIL: local release branch should be deleted after worktree finalize" >&2
  cat "$OUT" >&2
  exit 1
fi

if ! grep -qi 'another worktree' "$OUT"; then
  echo "FAIL: finalize should say why it left this worktree detached" >&2
  cat "$OUT" >&2
  exit 1
fi

echo "PASS: --finalize completes from a worktree that cannot own main (detach fallback)"

# --- Scenario 5: an existing draft release gets published, not skipped ------
# A draft release never emits release.published, so treating mere existence
# as success would leave the Homebrew tap stale.

setup_project "$TEST_DIR/draft-release"
export FAKE_GH_AUTH_STATUS_RC=0
export FAKE_OPENPR_MODE=merge
export FAKE_GH_RELEASE_STATE=draft
run_release
unset FAKE_OPENPR_MODE FAKE_GH_RELEASE_STATE

if [ "$RELEASE_STATUS" -ne 0 ]; then
  echo "FAIL: release with an existing draft must succeed by publishing it" >&2
  cat "$OUT" >&2
  exit 1
fi

if ! grep -Eq '^release edit v1.2.4 .*--draft=false' "$FAKE_GH_LOG"; then
  echo "FAIL: finalize must publish the existing draft (drafts never fire release.published)" >&2
  cat "$FAKE_GH_LOG" >&2
  cat "$OUT" >&2
  exit 1
fi

if grep -q '^release create ' "$FAKE_GH_LOG"; then
  echo "FAIL: finalize must not create a second release when a draft exists" >&2
  cat "$FAKE_GH_LOG" >&2
  exit 1
fi

echo "PASS: an existing draft GitHub release is published so the tap bump workflow fires"

# --- Scenario 6: an already-published release makes a rerun a no-op ---------

setup_project "$TEST_DIR/published-release"
export FAKE_GH_AUTH_STATUS_RC=0
export FAKE_OPENPR_MODE=merge
export FAKE_GH_RELEASE_STATE=published
run_release
unset FAKE_OPENPR_MODE FAKE_GH_RELEASE_STATE

if [ "$RELEASE_STATUS" -ne 0 ]; then
  echo "FAIL: rerun against an already-published release must succeed" >&2
  cat "$OUT" >&2
  exit 1
fi

if grep -Eq '^release (create|edit) ' "$FAKE_GH_LOG"; then
  echo "FAIL: an already-published release must be left untouched on rerun" >&2
  cat "$FAKE_GH_LOG" >&2
  exit 1
fi

echo "PASS: an already-published release is left untouched on rerun"

# --- Static: the direct-push-to-main invocation is gone ---------------------

# --- Scenario 7: dirty local main must not fail a published release --------
# The tag and GitHub release are already out; a dirty worktree that blocks
# the post-publication fast-forward gets guidance, not a nonzero exit
# (PR #784 review).
setup_project "$TEST_DIR/dirty-finalize"
export FAKE_GH_AUTH_STATUS_RC=0
git -C "$PROJECT" checkout -q -b release/v1.2.4
printf '1.2.4\n' >"$PROJECT/VERSION"
printf '1.2.4\n' >"$PROJECT/.touchstone-version"
git -C "$PROJECT" add VERSION .touchstone-version
git -C "$PROJECT" commit -q -m "v1.2.4"
(cd "$PROJECT" && FAKE_OPENPR_MODE=merge bash scripts/open-pr.sh --auto-merge) >/dev/null
git -C "$PROJECT" checkout -q main
printf 'uncommitted\n' >"$PROJECT/local-edit.txt"
git -C "$PROJECT" add local-edit.txt
run_finalize "$PROJECT" v1.2.4

if [ "$RELEASE_STATUS" -ne 0 ]; then
  echo "FAIL: a dirty main worktree must not fail a release that already published" >&2
  cat "$OUT" >&2
  exit 1
fi
if ! grep -q 'Sync it manually' "$OUT"; then
  echo "FAIL: the guarded sync must print manual-recovery guidance" >&2
  cat "$OUT" >&2
  exit 1
fi
echo "PASS: dirty local main gets guidance, not a failed published release"

# --- Scenario 8: a superseded release refuses to finalize -------------------
# A stalled v1.2.4 must not publish after v1.2.5 landed on main: the older
# tag would dispatch to the tap bump and roll new installs back
# (PR #784 review).
setup_project "$TEST_DIR/superseded-finalize"
export FAKE_GH_AUTH_STATUS_RC=0
git -C "$PROJECT" checkout -q -b release/v1.2.4
printf '1.2.4\n' >"$PROJECT/VERSION"
printf '1.2.4\n' >"$PROJECT/.touchstone-version"
git -C "$PROJECT" add VERSION .touchstone-version
git -C "$PROJECT" commit -q -m "v1.2.4"
(cd "$PROJECT" && FAKE_OPENPR_MODE=merge bash scripts/open-pr.sh --auto-merge) >/dev/null
git -C "$PROJECT" checkout -q main
git -C "$PROJECT" pull -q --rebase origin main 2>/dev/null || git -C "$PROJECT" reset -q --hard origin/main
printf '1.2.5\n' >"$PROJECT/VERSION"
git -C "$PROJECT" add VERSION
git -C "$PROJECT" commit -q -m "v1.2.5"
git -C "$PROJECT" push -q origin main
git -C "$PROJECT" fetch -q origin
run_finalize "$PROJECT" v1.2.4

if [ "$RELEASE_STATUS" -eq 0 ]; then
  echo "FAIL: a superseded release must refuse to finalize" >&2
  cat "$OUT" >&2
  exit 1
fi
if ! grep -q 'superseded' "$OUT"; then
  echo "FAIL: the refusal must name supersession" >&2
  cat "$OUT" >&2
  exit 1
fi
if git --git-dir="$ORIGIN" rev-parse 'refs/tags/v1.2.4' >/dev/null 2>&1; then
  echo "FAIL: no tag may be pushed for a superseded release" >&2
  exit 1
fi
echo "PASS: a superseded release refuses to finalize (no tag, no release)"

if grep -En 'push[^#]*origin +main' "$REPO_ROOT/lib/release.sh"; then
  echo "FAIL: lib/release.sh must not push origin main directly (issue #729)" >&2
  exit 1
fi

echo "PASS: lib/release.sh no longer pushes main directly"
