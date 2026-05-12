#!/usr/bin/env bash
#
# tests/test-codex-review-sync.sh — guard against drift between the legacy source
# `hooks/codex-review.sh` and the `scripts/codex-review.sh` copy that every
# touchstone self-update and every downstream `update-project.sh` writes
# from the same source. If they diverge mid-development, the stale copy
# gets invoked by the local pre-push hook until the next self-update, and
# the duplication stops being safe.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$TOUCHSTONE_ROOT/hooks/codex-review.sh"
COPY="$TOUCHSTONE_ROOT/scripts/codex-review.sh"
CONDUCTOR_SOURCE="$TOUCHSTONE_ROOT/hooks/conductor-review.sh"
CONDUCTOR_COPY="$TOUCHSTONE_ROOT/scripts/conductor-review.sh"

if [ ! -f "$SOURCE" ]; then
  echo "FAIL: expected source file missing: $SOURCE" >&2
  exit 1
fi

if [ ! -f "$COPY" ]; then
  echo "FAIL: expected copy missing: $COPY" >&2
  echo "      Regenerate with: cp $SOURCE $COPY" >&2
  exit 1
fi

if [ ! -f "$CONDUCTOR_SOURCE" ]; then
  echo "FAIL: expected Conductor entry point missing: $CONDUCTOR_SOURCE" >&2
  exit 1
fi

if [ ! -f "$CONDUCTOR_COPY" ]; then
  echo "FAIL: expected Conductor copy missing: $CONDUCTOR_COPY" >&2
  exit 1
fi

if ! cmp -s "$SOURCE" "$COPY"; then
  echo "FAIL: scripts/codex-review.sh has drifted from hooks/codex-review.sh" >&2
  echo "      bootstrap/update-project.sh treats them as the same file." >&2
  echo "" >&2
  diff -u "$SOURCE" "$COPY" | head -40 >&2
  echo "" >&2
  echo "  Resync with: cp hooks/codex-review.sh scripts/codex-review.sh" >&2
  exit 1
fi

if ! cmp -s "$CONDUCTOR_SOURCE" "$CONDUCTOR_COPY"; then
  echo "FAIL: scripts/conductor-review.sh has drifted from hooks/conductor-review.sh" >&2
  diff -u "$CONDUCTOR_SOURCE" "$CONDUCTOR_COPY" | head -40 >&2
  exit 1
fi

if ! grep -q 'exec "$SCRIPT_DIR/codex-review.sh" "$@"' "$CONDUCTOR_SOURCE"; then
  echo "FAIL: conductor-review.sh should delegate to the legacy compatibility implementation" >&2
  exit 1
fi

legacy_sentinel="$(printf 'CODEX_REVIEW_CLEAN\n' | CODEX_REVIEW_TEST_SENTINEL=1 bash "$SOURCE")"
conductor_sentinel="$(printf 'CODEX_REVIEW_CLEAN\n' | CODEX_REVIEW_TEST_SENTINEL=1 bash "$CONDUCTOR_SOURCE")"
if [ "$legacy_sentinel" != "CODEX_REVIEW_CLEAN" ] || [ "$conductor_sentinel" != "CODEX_REVIEW_CLEAN" ]; then
  echo "FAIL: expected both legacy and Conductor entry points to run the sentinel helper" >&2
  exit 1
fi

echo "==> PASS: Conductor and legacy review entry points are in sync"
