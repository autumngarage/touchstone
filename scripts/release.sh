#!/usr/bin/env bash
#
# scripts/release.sh — cut a touchstone release.
#
# Usage:
#   scripts/release.sh --patch   # default
#   scripts/release.sh --minor
#   scripts/release.sh --major
#   scripts/release.sh --resume vMAJOR.MINOR.PATCH RELEASE_COMMIT
#   scripts/release.sh --retry vMAJOR.MINOR.PATCH BASE_COMMIT RELEASE_COMMIT
#   scripts/release.sh --abort-local vMAJOR.MINOR.PATCH BASE_COMMIT
#
# Thin wrapper around `bin/touchstone release` so all four autumn-garage
# tools expose the same scripts/release.sh interface. Touchstone owns the
# real release logic in lib/release.sh (VERSION bump, --no-verify commit,
# tag, push, gh release create, async tap bump via release.yml).
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

bump="${1:---patch}"
case "$bump" in
  --major | --minor | --patch) ;;
  --resume)
    [ "$#" -eq 3 ] || {
      echo "ERROR: --resume requires vMAJOR.MINOR.PATCH and RELEASE_COMMIT" >&2
      exit 1
    }
    TOUCHSTONE_NO_AUTO_UPDATE=1 exec "$REPO_ROOT/bin/touchstone" release --resume "$2" "$3"
    ;;
  --retry)
    [ "$#" -eq 4 ] || {
      echo "ERROR: --retry requires vMAJOR.MINOR.PATCH, BASE_COMMIT, and RELEASE_COMMIT" >&2
      exit 1
    }
    TOUCHSTONE_NO_AUTO_UPDATE=1 exec "$REPO_ROOT/bin/touchstone" release --retry "$2" "$3" "$4"
    ;;
  --abort-local)
    [ "$#" -eq 3 ] || {
      echo "ERROR: --abort-local requires vMAJOR.MINOR.PATCH and BASE_COMMIT" >&2
      exit 1
    }
    TOUCHSTONE_NO_AUTO_UPDATE=1 exec "$REPO_ROOT/bin/touchstone" release --abort-local "$2" "$3"
    ;;
  *)
    echo "ERROR: unknown release arg: $bump (use a bump, --resume TAG COMMIT, --retry TAG BASE COMMIT, or --abort-local TAG BASE)" >&2
    exit 1
    ;;
esac

TOUCHSTONE_NO_AUTO_UPDATE=1 exec "$REPO_ROOT/bin/touchstone" release "$bump"
