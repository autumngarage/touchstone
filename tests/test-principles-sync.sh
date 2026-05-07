#!/usr/bin/env bash
#
# tests/test-principles-sync.sh — ensure lib/agents-principles-block.sh is in sync with principles/*.md.
#
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

echo "==> Test: principles sync"

# Generate a temporary fresh version
tmp_lib="$(mktemp)"
cp lib/agents-principles-block.sh "$tmp_lib"
bash scripts/refresh-principles.sh >/dev/null

if diff -u "$tmp_lib" lib/agents-principles-block.sh; then
  echo "==> PASS: principles are in sync"
  rm "$tmp_lib"
  exit 0
else
  echo "FAIL: principles have drifted. Run 'bash scripts/refresh-principles.sh' and commit the changes." >&2
  # Restore the old one so the worktree stays as it was if this is run in a check mode
  cat "$tmp_lib" >lib/agents-principles-block.sh
  rm "$tmp_lib"
  exit 1
fi
