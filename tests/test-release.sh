#!/usr/bin/env bash
#
# tests/test-release.sh — release workflow guardrails.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-release.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
REAL_GIT="$(command -v git)"

FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_GH_LOG:?}"
case "${1:-} ${2:-}" in
  "auth status") exit "${FAKE_GH_AUTH_EXIT:-0}" ;;
  "release view")
    if [ "${FAKE_GH_RELEASE_VIEW_EXIT:-1}" -ne 0 ]; then
      exit "${FAKE_GH_RELEASE_VIEW_EXIT:-1}"
    fi
    printf '%s\n' "${FAKE_GH_RELEASE_STATE:-unknown}"
    ;;
  "release create") exit "${FAKE_GH_RELEASE_EXIT:-0}" ;;
  "release edit") exit "${FAKE_GH_RELEASE_EDIT_EXIT:-0}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE_BIN/gh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1" expected="$2"
  if ! grep -qF -- "$expected" "$file"; then
    echo "FAIL: expected $file to contain: $expected" >&2
    cat "$file" >&2
    exit 1
  fi
}

new_release_fixture() {
  local name="$1"

  PROJECT="$TEST_DIR/$name/project"
  REMOTE="$TEST_DIR/$name/origin.git"
  GH_LOG="$TEST_DIR/$name/gh.log"
  mkdir -p "$PROJECT/lib"
  : >"$GH_LOG"

  cp "$REPO_ROOT/lib/colors.sh" "$PROJECT/lib/colors.sh"
  printf '1.2.3\n' >"$PROJECT/VERSION"
  printf '1.2.3\n' >"$PROJECT/.touchstone-version"

  git init -q --bare "$REMOTE"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" checkout -q -b main
  git -C "$PROJECT" config user.email test@example.test
  git -C "$PROJECT" config user.name "Touchstone Test"
  git -C "$PROJECT" add VERSION .touchstone-version lib/colors.sh
  git -C "$PROJECT" commit -q -m "initial"
  git -C "$PROJECT" remote add origin "$REMOTE"
  git -C "$PROJECT" push -q -u origin main
  INITIAL_HEAD="$(git -C "$PROJECT" rev-parse HEAD)"
}

run_release() {
  local output_file="$1"
  local auth_exit="${2:-0}"
  local github_release_exit="${3:-0}"
  local github_release_state="${4:-missing}"
  local github_release_edit_exit="${5:-0}"
  local github_release_view_exit=0

  [ "$github_release_state" != "missing" ] || github_release_view_exit=1

  set +e
  (
    export TOUCHSTONE_ROOT="$PROJECT"
    export PATH="${RELEASE_EXTRA_BIN:+$RELEASE_EXTRA_BIN:}$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
    export FAKE_GH_LOG="$GH_LOG"
    export FAKE_GH_AUTH_EXIT="$auth_exit"
    export FAKE_GH_RELEASE_EXIT="$github_release_exit"
    export FAKE_GH_RELEASE_STATE="$github_release_state"
    export FAKE_GH_RELEASE_VIEW_EXIT="$github_release_view_exit"
    export FAKE_GH_RELEASE_EDIT_EXIT="$github_release_edit_exit"
    # shellcheck source=../lib/release.sh
    source "$REPO_ROOT/lib/release.sh"
    touchstone_release patch
  ) >"$output_file" 2>&1
  RELEASE_RESULT=$?
  set -e
}

assert_unmutated_release() {
  local output_file="$1"

  [ "$(tr -d '[:space:]' <"$PROJECT/VERSION")" = "1.2.3" ] \
    || fail "release preflight mutated VERSION"
  [ "$(tr -d '[:space:]' <"$PROJECT/.touchstone-version")" = "1.2.3" ] \
    || fail "release preflight mutated .touchstone-version"
  [ "$(git -C "$PROJECT" rev-parse HEAD)" = "$INITIAL_HEAD" ] \
    || fail "release preflight created a commit"
  if git -C "$PROJECT" rev-parse -q --verify refs/tags/v1.2.4 >/dev/null; then
    fail "release preflight created the target tag"
  fi
  [ -s "$output_file" ] || fail "release failure produced no diagnostic output"
}

echo "==> Test: GitHub auth fails before repository mutation"
new_release_fixture auth
AUTH_OUT="$TEST_DIR/auth/release.out"
run_release "$AUTH_OUT" 1 0
[ "$RELEASE_RESULT" -ne 0 ] || fail "unauthenticated release unexpectedly passed"
assert_unmutated_release "$AUTH_OUT"
assert_contains "$GH_LOG" "auth status --hostname github.com"
if grep -q '^release create ' "$GH_LOG"; then
  fail "release tried to create a GitHub release after failed auth preflight"
fi
assert_contains "$AUTH_OUT" "gh auth login"
echo "==> PASS: authentication is checked before mutation"

echo "==> Test: stale local main fails after refreshing origin"
new_release_fixture stale-main
WRITER="$TEST_DIR/stale-main/writer"
git init -q "$WRITER"
git -C "$WRITER" config user.email writer@example.test
git -C "$WRITER" config user.name "Remote Writer"
git -C "$WRITER" remote add origin "$REMOTE"
git -C "$WRITER" fetch -q origin main
git -C "$WRITER" checkout -q -b main origin/main
printf 'remote advance\n' >"$WRITER/REMOTE.md"
git -C "$WRITER" add REMOTE.md
git -C "$WRITER" commit -q -m "advance remote main"
git -C "$WRITER" push -q origin main
STALE_OUT="$TEST_DIR/stale-main/release.out"
run_release "$STALE_OUT" 0 0
[ "$RELEASE_RESULT" -ne 0 ] || fail "stale main release unexpectedly passed"
assert_unmutated_release "$STALE_OUT"
assert_contains "$STALE_OUT" "Local main is not the exact origin/main revision"
echo "==> PASS: stale main is rejected before version mutation"

echo "==> Test: an existing remote tag blocks release before mutation"
new_release_fixture existing-tag
git -C "$PROJECT" tag v1.2.4
git -C "$PROJECT" push -q origin refs/tags/v1.2.4:refs/tags/v1.2.4
git -C "$PROJECT" tag -d v1.2.4 >/dev/null
TAG_OUT="$TEST_DIR/existing-tag/release.out"
run_release "$TAG_OUT" 0 0
[ "$RELEASE_RESULT" -ne 0 ] || fail "existing-tag release unexpectedly passed"
[ "$(tr -d '[:space:]' <"$PROJECT/VERSION")" = "1.2.3" ] \
  || fail "existing remote tag mutated VERSION"
[ "$(git -C "$PROJECT" rev-parse HEAD)" = "$INITIAL_HEAD" ] \
  || fail "existing remote tag created a release commit"
if git -C "$PROJECT" show-ref --verify --quiet refs/tags/v1.2.4; then
  fail "remote tag preflight imported the rejected tag into local state"
fi
assert_contains "$TAG_OUT" "Release tag already exists"
echo "==> PASS: fetched remote tags block duplicate publication"

echo "==> Test: atomic push prevents a partial branch/tag publication"
new_release_fixture atomic-reject
cat >"$REMOTE/hooks/pre-receive" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while read -r _old_oid _new_oid ref_name; do
  if [ "$ref_name" = "refs/heads/main" ]; then
    echo "rejecting main for atomic publication fixture" >&2
    exit 1
  fi
done
EOF
chmod +x "$REMOTE/hooks/pre-receive"
ATOMIC_OUT="$TEST_DIR/atomic-reject/release.out"
run_release "$ATOMIC_OUT" 0 0
[ "$RELEASE_RESULT" -ne 0 ] || fail "rejected atomic publication unexpectedly passed"
[ "$(git --git-dir="$REMOTE" rev-parse refs/heads/main)" = "$INITIAL_HEAD" ] \
  || fail "atomic failure advanced remote main"
if git --git-dir="$REMOTE" show-ref --verify --quiet refs/tags/v1.2.4; then
  fail "atomic failure partially published the tag"
fi
[ "$(tr -d '[:space:]' <"$PROJECT/VERSION")" = "1.2.4" ] \
  || fail "atomic failure did not preserve the local release state for diagnosis"
git -C "$PROJECT" show-ref --verify --quiet refs/tags/v1.2.4 \
  || fail "atomic failure did not preserve the local tag for diagnosis"
assert_contains "$ATOMIC_OUT" "Atomic publication failed"
assert_contains "$ATOMIC_OUT" "Retry: git push --atomic"
EXPECTED_ABORT_COMMAND="$(printf 'bash %q --abort-local %q %q' \
  "$PROJECT/scripts/release.sh" v1.2.4 "$INITIAL_HEAD")"
assert_contains "$ATOMIC_OUT" "Abort after revalidating remote refs: $EXPECTED_ABORT_COMMAND"
LOCAL_RELEASE_HEAD="$(git -C "$PROJECT" rev-parse HEAD)"
ABORT_OUT="$TEST_DIR/atomic-reject/abort.out"
(
  export TOUCHSTONE_ROOT="$PROJECT"
  source "$REPO_ROOT/lib/release.sh"
  touchstone_release_abort_local v1.2.4 "$INITIAL_HEAD"
) >"$ABORT_OUT" 2>&1
[ "$(git -C "$PROJECT" rev-parse HEAD)" = "$INITIAL_HEAD" ] \
  || fail "verified local abort did not restore the release base"
if git -C "$PROJECT" show-ref --verify --quiet refs/tags/v1.2.4; then
  fail "verified local abort retained the release tag"
fi
[ "$(git -C "$PROJECT" rev-parse refs/touchstone/release-aborts/v1.2.4)" = "$LOCAL_RELEASE_HEAD" ] \
  || fail "verified local abort did not retain a recovery ref"
assert_contains "$ABORT_OUT" "Recovery ref retained"
echo "==> PASS: remote branch and tag remain all-or-nothing"

echo "==> Test: expected-old-value lease blocks a deleted or reset main"
new_release_fixture lease-race
LEASE_BIN="$TEST_DIR/lease-race/bin"
LEASE_MARKER="$TEST_DIR/lease-race/push-mutated"
mkdir -p "$LEASE_BIN"
cat >"$LEASE_BIN/git" <<EOF_LEASE_GIT
#!/usr/bin/env bash
set -euo pipefail
is_push=false
for arg in "\$@"; do
  [ "\$arg" = "push" ] && is_push=true
done
if [ "\$is_push" = true ] && [ ! -f "$LEASE_MARKER" ]; then
  : >"$LEASE_MARKER"
  "$REAL_GIT" --git-dir="$REMOTE" update-ref -d refs/heads/main
fi
exec "$REAL_GIT" "\$@"
EOF_LEASE_GIT
chmod +x "$LEASE_BIN/git"
LEASE_OUT="$TEST_DIR/lease-race/release.out"
RELEASE_EXTRA_BIN="$LEASE_BIN" run_release "$LEASE_OUT" 0 0
[ "$RELEASE_RESULT" -ne 0 ] || fail "release recreated a concurrently deleted main"
if git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/main; then
  fail "expected-old-value lease did not preserve the concurrent main deletion"
fi
if git --git-dir="$REMOTE" show-ref --verify --quiet refs/tags/v1.2.4; then
  fail "lease rejection partially published the release tag"
fi
assert_contains "$LEASE_OUT" "remote state changed concurrently"
if grep -qF -- '--abort-local' "$LEASE_OUT"; then
  fail "concurrent remote state offered a destructive local abort"
fi
echo "==> PASS: atomic publication is bound to the preflighted main revision"

echo "==> Test: failed push response reconciles a committed remote transaction"
new_release_fixture ambiguous-push-response
AMBIGUOUS_BIN="$TEST_DIR/ambiguous-push-response/bin"
AMBIGUOUS_MARKER="$TEST_DIR/ambiguous-push-response/push-returned-error"
mkdir -p "$AMBIGUOUS_BIN"
cat >"$AMBIGUOUS_BIN/git" <<EOF_AMBIGUOUS_GIT
#!/usr/bin/env bash
set -euo pipefail
is_push=false
for arg in "\$@"; do
  [ "\$arg" = "push" ] && is_push=true
done
if [ "\$is_push" = true ] && [ ! -f "$AMBIGUOUS_MARKER" ]; then
  : >"$AMBIGUOUS_MARKER"
  "$REAL_GIT" "\$@"
  exit 42
fi
exec "$REAL_GIT" "\$@"
EOF_AMBIGUOUS_GIT
chmod +x "$AMBIGUOUS_BIN/git"
AMBIGUOUS_OUT="$TEST_DIR/ambiguous-push-response/release.out"
RELEASE_EXTRA_BIN="$AMBIGUOUS_BIN" run_release "$AMBIGUOUS_OUT" 0 0
[ "$RELEASE_RESULT" -eq 0 ] || fail "published remote transaction did not continue after reconciliation"
AMBIGUOUS_HEAD="$(git -C "$PROJECT" rev-parse HEAD)"
[ "$(git --git-dir="$REMOTE" rev-parse refs/heads/main)" = "$AMBIGUOUS_HEAD" ] \
  || fail "ambiguous response did not publish remote main"
[ "$(git --git-dir="$REMOTE" rev-parse refs/tags/v1.2.4)" = "$AMBIGUOUS_HEAD" ] \
  || fail "ambiguous response did not publish the release tag"
assert_contains "$AMBIGUOUS_OUT" "both release refs were published"
assert_contains "$GH_LOG" "release create v1.2.4"
echo "==> PASS: a lost push response cannot strand published refs without a release"

echo "==> Test: GitHub Release failure prints an executable resume command"
new_release_fixture github-release-failure
RELEASE_OUT="$TEST_DIR/github-release-failure/release.out"
run_release "$RELEASE_OUT" 0 99
[ "$RELEASE_RESULT" -eq 99 ] \
  || fail "GitHub Release failure returned $RELEASE_RESULT instead of preserving exit 99"
PUBLISHED_HEAD="$(git -C "$PROJECT" rev-parse HEAD)"
[ "$(git --git-dir="$REMOTE" rev-parse refs/heads/main)" = "$PUBLISHED_HEAD" ] \
  || fail "successful atomic publication did not advance remote main"
[ "$(git --git-dir="$REMOTE" rev-parse refs/tags/v1.2.4)" = "$PUBLISHED_HEAD" ] \
  || fail "successful atomic publication did not publish the matching tag"
assert_contains "$RELEASE_OUT" "Git refs were published, but normal GitHub Release recovery did not complete"
RECOVERY_COMMAND="$(sed -n 's/^.*Resume idempotently: //p' "$RELEASE_OUT")"
EXPECTED_RECOVERY_COMMAND="$(printf 'bash %q --resume %q %q' \
  "$PROJECT/scripts/release.sh" v1.2.4 "$PUBLISHED_HEAD")"
[ "$RECOVERY_COMMAND" = "$EXPECTED_RECOVERY_COMMAND" ] \
  || fail "GitHub Release failure omitted its idempotent resume command"
assert_contains "$GH_LOG" "release view v1.2.4 --repo autumngarage/touchstone"
assert_contains "$GH_LOG" "release create v1.2.4 --repo autumngarage/touchstone --title v1.2.4 --generate-notes --verify-tag"
echo "==> PASS: published Git refs have a deterministic forward-fix path"

echo "==> Test: resume is bound to the intended remote tag commit"
git --git-dir="$REMOTE" update-ref refs/tags/v1.2.4 "$INITIAL_HEAD"
MOVED_TAG_OUT="$TEST_DIR/github-release-failure/resume-moved-tag.out"
GH_CALLS_BEFORE_MOVED_TAG="$(wc -l <"$GH_LOG" | tr -d '[:space:]')"
set +e
(
  export TOUCHSTONE_ROOT="$PROJECT"
  export PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export FAKE_GH_LOG="$GH_LOG"
  export FAKE_GH_AUTH_EXIT=0
  export FAKE_GH_RELEASE_VIEW_EXIT=0
  export FAKE_GH_RELEASE_STATE=published
  source "$REPO_ROOT/lib/release.sh"
  touchstone_release_resume v1.2.4 "$PUBLISHED_HEAD"
) >"$MOVED_TAG_OUT" 2>&1
MOVED_TAG_STATUS=$?
set -e
[ "$MOVED_TAG_STATUS" -ne 0 ] || fail "resume accepted a force-moved remote release tag"
assert_contains "$MOVED_TAG_OUT" "no longer identifies the intended release commit"
[ "$(wc -l <"$GH_LOG" | tr -d '[:space:]')" -eq $((GH_CALLS_BEFORE_MOVED_TAG + 1)) ] \
  || fail "resume queried or mutated a GitHub release after the remote tag identity check failed"
git --git-dir="$REMOTE" update-ref refs/tags/v1.2.4 "$PUBLISHED_HEAD"
echo "==> PASS: recovery cannot publish a replacement tag commit"

echo "==> Test: remote inspection failures remain visible"
REMOTE_FAIL_BIN="$TEST_DIR/github-release-failure/remote-fail-bin"
mkdir -p "$REMOTE_FAIL_BIN"
cat >"$REMOTE_FAIL_BIN/git" <<EOF_REMOTE_FAIL_GIT
#!/usr/bin/env bash
set -euo pipefail
for arg in "\$@"; do
  if [ "\$arg" = "ls-remote" ]; then
    exit 42
  fi
done
exec "$REAL_GIT" "\$@"
EOF_REMOTE_FAIL_GIT
chmod +x "$REMOTE_FAIL_BIN/git"
REMOTE_FAIL_OUT="$TEST_DIR/github-release-failure/resume-remote-fail.out"
set +e
(
  export TOUCHSTONE_ROOT="$PROJECT"
  export PATH="$REMOTE_FAIL_BIN:$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export FAKE_GH_LOG="$GH_LOG"
  export FAKE_GH_AUTH_EXIT=0
  source "$REPO_ROOT/lib/release.sh"
  touchstone_release_resume v1.2.4 "$PUBLISHED_HEAD"
) >"$REMOTE_FAIL_OUT" 2>&1
REMOTE_FAIL_STATUS=$?
set -e
[ "$REMOTE_FAIL_STATUS" -ne 0 ] || fail "resume ignored a remote inspection failure"
assert_contains "$REMOTE_FAIL_OUT" "Could not inspect remote ref refs/tags/v1.2.4 (git exit 42)"
echo "==> PASS: captured ref lookups preserve actionable diagnostics"

echo "==> Test: resume accepts published releases and publishes safe drafts"
PUBLISHED_RESUME_OUT="$TEST_DIR/github-release-failure/resume-published.out"
set +e
(
  export TOUCHSTONE_ROOT="$PROJECT"
  export PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export FAKE_GH_LOG="$GH_LOG"
  export FAKE_GH_AUTH_EXIT=0
  export FAKE_GH_RELEASE_VIEW_EXIT=0
  export FAKE_GH_RELEASE_STATE=published
  source "$REPO_ROOT/lib/release.sh"
  touchstone_release_resume v1.2.4 "$PUBLISHED_HEAD"
) >"$PUBLISHED_RESUME_OUT" 2>&1
PUBLISHED_RESUME_STATUS=$?
set -e
[ "$PUBLISHED_RESUME_STATUS" -eq 0 ] || fail "published release was not idempotent"
assert_contains "$PUBLISHED_RESUME_OUT" "already published"

DRAFT_RESUME_OUT="$TEST_DIR/github-release-failure/resume-draft.out"
set +e
(
  export TOUCHSTONE_ROOT="$PROJECT"
  export PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export FAKE_GH_LOG="$GH_LOG"
  export FAKE_GH_AUTH_EXIT=0
  export FAKE_GH_RELEASE_VIEW_EXIT=0
  export FAKE_GH_RELEASE_STATE=draft
  export FAKE_GH_RELEASE_EDIT_EXIT=0
  source "$REPO_ROOT/lib/release.sh"
  touchstone_release_resume v1.2.4 "$PUBLISHED_HEAD"
) >"$DRAFT_RESUME_OUT" 2>&1
DRAFT_RESUME_STATUS=$?
set -e
[ "$DRAFT_RESUME_STATUS" -eq 0 ] || fail "draft release was not published by resume"
assert_contains "$GH_LOG" "release edit v1.2.4 --repo autumngarage/touchstone --draft=false"
assert_contains "$DRAFT_RESUME_OUT" "Published existing draft GitHub release"

DRAFT_PRERELEASE_OUT="$TEST_DIR/github-release-failure/resume-draft-prerelease.out"
set +e
(
  export TOUCHSTONE_ROOT="$PROJECT"
  export PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export FAKE_GH_LOG="$GH_LOG"
  export FAKE_GH_AUTH_EXIT=0
  export FAKE_GH_RELEASE_VIEW_EXIT=0
  export FAKE_GH_RELEASE_STATE=draft-prerelease
  export FAKE_GH_RELEASE_EDIT_EXIT=0
  source "$REPO_ROOT/lib/release.sh"
  touchstone_release_resume v1.2.4 "$PUBLISHED_HEAD"
) >"$DRAFT_PRERELEASE_OUT" 2>&1
DRAFT_PRERELEASE_STATUS=$?
set -e
[ "$DRAFT_PRERELEASE_STATUS" -eq 0 ] || fail "prerelease draft was not normalized before publication"
assert_contains "$GH_LOG" "release edit v1.2.4 --repo autumngarage/touchstone --prerelease=false --draft=false"

PUBLISHED_PRERELEASE_OUT="$TEST_DIR/github-release-failure/resume-published-prerelease.out"
set +e
(
  export TOUCHSTONE_ROOT="$PROJECT"
  export PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export FAKE_GH_LOG="$GH_LOG"
  export FAKE_GH_AUTH_EXIT=0
  export FAKE_GH_RELEASE_VIEW_EXIT=0
  export FAKE_GH_RELEASE_STATE=published-prerelease
  source "$REPO_ROOT/lib/release.sh"
  touchstone_release_resume v1.2.4 "$PUBLISHED_HEAD"
) >"$PUBLISHED_PRERELEASE_OUT" 2>&1
PUBLISHED_PRERELEASE_STATUS=$?
set -e
[ "$PUBLISHED_PRERELEASE_STATUS" -ne 0 ] || fail "published prerelease incorrectly completed recovery"
assert_contains "$PUBLISHED_PRERELEASE_OUT" "manually dispatch release.yml"
echo "==> PASS: recovery requires a normal published release, not mere existence"

echo "==> Test: rendered recovery commands work outside a checkout"
WRAPPER_ROOT="$TEST_DIR/release wrapper checkout"
WRAPPER_LOG="$TEST_DIR/release-wrapper.log"
mkdir -p "$WRAPPER_ROOT/bin" "$WRAPPER_ROOT/lib" "$WRAPPER_ROOT/scripts"
WRAPPER_ROOT_PHYSICAL="$(cd -P "$WRAPPER_ROOT" && pwd)"
cp "$REPO_ROOT/lib/colors.sh" "$WRAPPER_ROOT/lib/colors.sh"
cp "$REPO_ROOT/scripts/release.sh" "$WRAPPER_ROOT/scripts/release.sh"
cat >"$WRAPPER_ROOT/bin/touchstone" <<'EOF_WRAPPER_TOUCHSTONE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$PWD" >"${WRAPPER_LOG:?}"
printf '%s\n' "$@" >>"$WRAPPER_LOG"
EOF_WRAPPER_TOUCHSTONE
chmod +x "$WRAPPER_ROOT/bin/touchstone"
RENDERED_COMMAND="$({
  export TOUCHSTONE_ROOT="$WRAPPER_ROOT"
  source "$REPO_ROOT/lib/release.sh"
  touchstone_release_command --resume v1.2.4 "$PUBLISHED_HEAD"
})"
(
  cd /
  export WRAPPER_LOG
  bash -c "$RENDERED_COMMAND"
)
[ "$(sed -n '1p' "$WRAPPER_LOG")" = "$WRAPPER_ROOT_PHYSICAL" ] \
  || fail "release wrapper did not derive its checkout independently of the caller cwd"
[ "$(sed -n '2p' "$WRAPPER_LOG")" = "release" ] \
  && [ "$(sed -n '3p' "$WRAPPER_LOG")" = "--resume" ] \
  && [ "$(sed -n '4p' "$WRAPPER_LOG")" = "v1.2.4" ] \
  && [ "$(sed -n '5p' "$WRAPPER_LOG")" = "$PUBLISHED_HEAD" ] \
  || fail "rendered recovery command did not preserve its arguments"
echo "==> PASS: recovery commands are absolute, shell-safe, and cwd-independent"

echo "==> PASS: release publication is exact-base, atomic, and recoverable"
