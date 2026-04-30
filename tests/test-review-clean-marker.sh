#!/usr/bin/env bash
#
# tests/test-review-clean-marker.sh — clean reviews record branch-level markers.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-review-clean-marker.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "==> Test: clean review writes branch marker"

REPO="$TEST_DIR/repo"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$REPO" "$FAKE_BIN"

cat > "$FAKE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  doctor)
    printf '{"configured": true}\n'
    ;;
  exec|call)
    cat >/dev/null
    printf 'No blocking issues found.\n'
    printf 'CODEX_REVIEW_CLEAN\n'
    ;;
  *)
    echo "unexpected conductor args: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/conductor"

if (
  cd "$REPO"
  git init -q
  git config user.email test@example.com
  git config user.name "Touchstone Test"
  printf '[review]\nreviewer = "conductor"\nmode = "review-only"\n' > .codex-review.toml
  printf 'base\n' > example.txt
  git add .codex-review.toml example.txt
  git commit -q -m "base"
  printf 'change\n' >> example.txt
  git add example.txt
  git commit -q -m "change"

  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_REVIEW_BASE=HEAD~1 \
    CODEX_REVIEW_BRANCH_NAME="feature/clean-marker" \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    TOUCHSTONE_REVIEW_LOG=/dev/null \
    bash "$TOUCHSTONE_ROOT/scripts/codex-review.sh" > "$TEST_DIR/output.txt" 2>&1

  MARKER="$(git rev-parse --git-path touchstone/reviewer-clean/feature_clean-marker.clean)"
  if [ -f "$MARKER" ] \
    && grep -q '^result=CODEX_REVIEW_CLEAN$' "$MARKER" \
    && grep -q '^branch=feature/clean-marker$' "$MARKER" \
    && grep -q '^head=' "$MARKER"; then
    exit 0
  fi
  exit 1
); then
  echo "==> PASS: clean review marker written"
  exit 0
fi

echo "FAIL: clean review marker was not written" >&2
cat "$TEST_DIR/output.txt" >&2
exit 1
