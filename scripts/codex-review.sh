#!/usr/bin/env bash
#
# scripts/codex-review.sh — thin wrapper so the toolkit repo has a runnable
# scripts/ path while hooks/codex-review.sh remains the single source of truth.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec /usr/bin/env bash "$SCRIPT_DIR/../hooks/codex-review.sh" "$@"
