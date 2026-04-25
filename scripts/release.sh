#!/usr/bin/env bash
#
# scripts/release.sh — cut a touchstone release.
#
# Usage:
#   scripts/release.sh --patch   # default
#   scripts/release.sh --minor
#   scripts/release.sh --major
#
# Thin wrapper around `bin/touchstone release` so all four autumn-garage
# tools expose the same scripts/release.sh interface. Touchstone owns the
# real release logic in lib/release.sh (VERSION bump, --no-verify commit,
# tag, push, gh release create, async tap bump via release.yml).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

bump="${1:---patch}"
case "$bump" in
  --major|--minor|--patch) ;;
  *) echo "ERROR: unknown bump arg: $bump (use --major, --minor, --patch)" >&2; exit 1 ;;
esac

TOUCHSTONE_NO_AUTO_UPDATE=1 exec bin/touchstone release "$bump"
