#!/usr/bin/env bash
#
# tests/test-auto-update.sh — guard CLI self-update re-exec behavior.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-auto-update.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

FAKE_BIN="$TEST_DIR/bin"
STATE_DIR="$TEST_DIR/state"
mkdir -p "$FAKE_BIN" "$STATE_DIR"

cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"tag_name":"v999.0.0"}\n'
EOF
chmod +x "$FAKE_BIN/curl"

cat >"$FAKE_BIN/brew" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list)
    [ "${2:-}" = "touchstone" ] || exit 1
    exit 0
    ;;
  upgrade)
    [ "${2:-}" = "touchstone" ] || exit 1
    echo "fake brew upgraded touchstone"
    exit 0
    ;;
  *)
    echo "unexpected brew args: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/brew"

cat >"$FAKE_BIN/touchstone" <<'EOF'
#!/usr/bin/env bash
printf 'REEXECED:%s:%s\n' "${TOUCHSTONE_AUTO_UPDATE_REEXECED:-0}" "$*"
EOF
chmod +x "$FAKE_BIN/touchstone"

OUT="$TEST_DIR/reexec.out"
PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  TOUCHSTONE_UPDATE_INTERVAL=0 \
  TOUCHSTONE_STATE_DIR="$STATE_DIR" \
  "$TOUCHSTONE_ROOT/bin/touchstone" version >"$OUT" 2>&1

if grep -q 'fake brew upgraded touchstone' "$OUT" \
  && grep -q '^REEXECED:1:version$' "$OUT"; then
  echo "PASS: touchstone auto-update re-execs upgraded CLI"
else
  echo "FAIL: expected brew upgrade followed by CLI re-exec" >&2
  cat "$OUT" >&2
  exit 1
fi
