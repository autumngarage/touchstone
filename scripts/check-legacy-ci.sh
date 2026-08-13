#!/usr/bin/env bash
# Detect the frozen Touchstone workflow/config pairing that blocks validation
# after a legitimate push to a protected default branch.
set -euo pipefail

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
PRE_COMMIT="$ROOT/.pre-commit-config.yaml"
WORKFLOW_DIR="$ROOT/.github/workflows"

[ -f "$PRE_COMMIT" ] || exit 0
[ -d "$WORKFLOW_DIR" ] || exit 0

if ! grep -q 'id:[[:space:]]*no-commit-to-branch' "$PRE_COMMIT" \
  || ! grep -q 'stages:[[:space:]]*\[pre-commit\]' "$PRE_COMMIT"; then
  exit 0
fi

found=0
for workflow in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
  [ -f "$workflow" ] || continue
  grep -q '^[[:space:]]*push:' "$workflow" || continue
  grep -Eq 'branches:.*(main|master)|-[[:space:]]*(main|master)' "$workflow" || continue
  grep -q 'pre-commit run --all-files --hook-stage pre-commit' "$workflow" || continue
  if grep -Eq 'SKIP[^[:cntrl:]]*no-commit-to-branch|no-commit-to-branch[^[:cntrl:]]*SKIP' "$workflow"; then
    continue
  fi
  printf 'LEGACY-CI-BRANCH-GUARD %s\n' "${workflow#"$ROOT/"}"
  found=$((found + 1))
done

if [ "$found" -eq 0 ]; then exit 0; fi

cat >&2 <<'EOF'
ERROR: protected-branch CI runs the local no-commit-to-branch guard.
Repair the pre-commit step so only protected-branch push runs set
SKIP=no-commit-to-branch. Keep pull-request hygiene and every other hook on.
Then run the project validation command normally. Review this migration; do
not silently rewrite project-owned CI.
EOF
exit 3
