#!/usr/bin/env bash
# Compatibility fixture for the upgrade boundary shipped in Touchstone 3.5.0.
# It contains only the relevant prefix branch: that launcher execs its own
# installer and therefore cannot run code that exists only in the new release.
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
TOUCHSTONE_ROOT="$(cd -P "$(dirname "$SCRIPT_PATH")/.." && pwd)"

[ "${1:-}" = upgrade ] || {
  echo "ERROR: compatibility fixture serves only upgrade" >&2
  exit 2
}
shift

INSTALL_PREFIX=""
case "$TOUCHSTONE_ROOT" in
  */cli/*) INSTALL_PREFIX="${TOUCHSTONE_ROOT%/cli/*}" ;;
esac
if [ -n "$INSTALL_PREFIX" ] && [ -f "$INSTALL_PREFIX/current" ] \
  && [ "$INSTALL_PREFIX/cli/$(cat "$INSTALL_PREFIX/current")" = "$TOUCHSTONE_ROOT" ]; then
  exec bash "$TOUCHSTONE_ROOT/install.sh" --prefix "$INSTALL_PREFIX" "$@"
fi

echo "ERROR: compatibility fixture is not in an install.sh prefix" >&2
exit 1
