#!/usr/bin/env bash
#
# tests/test-release.sh — release workflow guardrails.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-release.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_GH_LOG:?}"
case "${1:-} ${2:-}" in
  "auth status") exit "${FAKE_GH_AUTH_EXIT:-0}" ;;
  "release view") exit "${FAKE_GH_RELEASE_VIEW_EXIT:-1}" ;;
  "release create") exit "${FAKE_GH_RELEASE_EXIT:-0}" ;;
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

  set +e
  (
    export TOUCHSTONE_ROOT="$PROJECT"
    export PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
    export FAKE_GH_LOG="$GH_LOG"
    export FAKE_GH_AUTH_EXIT="$auth_exit"
    export FAKE_GH_RELEASE_EXIT="$github_release_exit"
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
assert_contains "$ATOMIC_OUT" "Retry after resolving remote state"
assert_contains "$ATOMIC_OUT" "Abort the local release"
echo "==> PASS: remote branch and tag remain all-or-nothing"

echo "==> Test: GitHub Release failure prints an executable resume command"
new_release_fixture github-release-failure
RELEASE_OUT="$TEST_DIR/github-release-failure/release.out"
run_release "$RELEASE_OUT" 0 99
[ "$RELEASE_RESULT" -eq 99 ] || fail "GitHub Release failure did not preserve its exit status"
PUBLISHED_HEAD="$(git -C "$PROJECT" rev-parse HEAD)"
[ "$(git --git-dir="$REMOTE" rev-parse refs/heads/main)" = "$PUBLISHED_HEAD" ] \
  || fail "successful atomic publication did not advance remote main"
[ "$(git --git-dir="$REMOTE" rev-parse refs/tags/v1.2.4)" = "$PUBLISHED_HEAD" ] \
  || fail "successful atomic publication did not publish the matching tag"
assert_contains "$RELEASE_OUT" "Git refs were published, but the GitHub Release was not created"
RECOVERY_COMMAND="$(sed -n 's/^.*Resume idempotently: //p' "$RELEASE_OUT")"
[ -n "$RECOVERY_COMMAND" ] || fail "GitHub Release failure omitted its recovery command"
FAKE_GH_LOG="$GH_LOG" FAKE_GH_RELEASE_VIEW_EXIT=0 FAKE_GH_RELEASE_EXIT=0 \
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash -c "$RECOVERY_COMMAND"
[ "$(grep -c '^release create ' "$GH_LOG")" -eq 1 ] \
  || fail "idempotent recovery retried creation when the GitHub Release already existed"
FAKE_GH_LOG="$GH_LOG" FAKE_GH_RELEASE_VIEW_EXIT=1 FAKE_GH_RELEASE_EXIT=0 \
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash -c "$RECOVERY_COMMAND"
[ "$(grep -c '^release create ' "$GH_LOG")" -eq 2 ] \
  || fail "printed recovery command did not retry the GitHub Release creation"
assert_contains "$GH_LOG" "release view v1.2.4 --repo autumngarage/touchstone"
assert_contains "$GH_LOG" "release create v1.2.4 --repo autumngarage/touchstone --title v1.2.4 --generate-notes --verify-tag"
echo "==> PASS: published Git refs have a deterministic forward-fix path"

echo "==> PASS: release publication is exact-base, atomic, and recoverable"
