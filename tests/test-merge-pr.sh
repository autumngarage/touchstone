#!/usr/bin/env bash
#
# tests/test-merge-pr.sh — verify merge-pr.sh does not depend on local jq.
#
set -euo pipefail

TOOLKIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t toolkit-test-merge-pr.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "==> Test: merge script works without jq in PATH"

FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1 $2" in
  "repo view")
    echo "main"
    ;;
  "pr view")
    if [ "$5" = "state" ]; then
      echo "OPEN"
    elif [ "$5" = "mergeStateStatus,mergeable" ]; then
      echo "CLEAN MERGEABLE"
    else
      echo "unexpected gh pr view args: $*" >&2
      exit 1
    fi
    ;;
  "pr merge")
    echo "merged"
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
EOF

cat > "$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1 $2 ${3:-}" in
  "rev-parse --abbrev-ref HEAD")
    echo "feature/test"
    ;;
  "checkout main ")
    echo "Switched to branch 'main'"
    ;;
  "pull --rebase ")
    echo "Already up to date."
    ;;
  *)
    echo "unexpected git args: $*" >&2
    exit 1
    ;;
esac
EOF

chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/git"

OUTPUT_FILE="$TEST_DIR/output.txt"
PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$TOOLKIT_ROOT/scripts/merge-pr.sh" 123 >"$OUTPUT_FILE" 2>&1

if grep -q 'attempt 1: mergeStateStatus=CLEAN mergeable=MERGEABLE' "$OUTPUT_FILE" \
  && grep -q '==> Done\.' "$OUTPUT_FILE"; then
  echo "==> PASS: merge-pr.sh completed without jq"
  exit 0
fi

echo "FAIL: merge-pr.sh output did not show a successful jq-free merge path" >&2
cat "$OUTPUT_FILE" >&2
exit 1
