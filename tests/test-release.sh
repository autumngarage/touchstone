#!/usr/bin/env bash
#
# tests/test-release.sh — release workflow guardrails.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-release.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

PROJECT="$TEST_DIR/project"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$PROJECT/lib" "$FAKE_BIN"

cp "$REPO_ROOT/lib/colors.sh" "$PROJECT/lib/colors.sh"
printf '1.2.3\n' >"$PROJECT/VERSION"
printf '1.2.3\n' >"$PROJECT/.touchstone-version"

git -C "$PROJECT" init -q
git -C "$PROJECT" checkout -q -b main
git -C "$PROJECT" config user.email test@example.test
git -C "$PROJECT" config user.name "Touchstone Test"
git -C "$PROJECT" add VERSION .touchstone-version lib/colors.sh
git -C "$PROJECT" commit -q -m "initial"
INITIAL_HEAD="$(git -C "$PROJECT" rev-parse HEAD)"

cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_GH_LOG:?}"
case "${1:-} ${2:-}" in
  "auth status") exit 1 ;;
  "release create") exit 99 ;;
esac
exit 1
EOF
chmod +x "$FAKE_BIN/gh"

OUT="$TEST_DIR/release.out"
FAKE_GH_LOG="$TEST_DIR/gh.log"
export FAKE_GH_LOG

set +e
(
  export TOUCHSTONE_ROOT="$PROJECT"
  export PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  # shellcheck source=../lib/release.sh
  source "$REPO_ROOT/lib/release.sh"
  touchstone_release patch
) >"$OUT" 2>&1
release_status=$?
set -e

if [ "$release_status" -eq 0 ]; then
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

echo "PASS: release auth preflight fails before VERSION, commit, or tag mutation"
