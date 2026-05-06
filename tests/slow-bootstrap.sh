#!/usr/bin/env bash
#
# tests/slow-bootstrap.sh — opt-in integration smoke for the bootstrap
# flow against the real `cortex` and `sentinel` binaries.
#
# The fast tier (tests/test-bootstrap.sh) prepends tests/fixtures/ to
# PATH so the wizard's default Cortex/Sentinel init paths exercise the
# Touchstone scaffold contract without paying the real binaries'
# startup cost. That is the right trade-off ~30 times per run, but it
# leaves a gap: if Cortex or Sentinel changes its CLI contract, the
# fast tier will not catch it. This wrapper re-runs the same test
# script with TOUCHSTONE_REAL_BOOTSTRAP=1 so the real binaries are
# invoked instead.
#
# Run this before a release-confidence check whenever the contract
# between Touchstone and Cortex/Sentinel changes.
#
set -euo pipefail

if ! command -v cortex >/dev/null 2>&1; then
  echo "ERROR: 'cortex' is not on PATH; install it (brew install autumngarage/cortex/cortex) before running this slow probe." >&2
  exit 1
fi
if ! command -v sentinel >/dev/null 2>&1; then
  echo "ERROR: 'sentinel' is not on PATH; install it (brew install autumngarage/sentinel/sentinel) before running this slow probe." >&2
  exit 1
fi
if ! command -v conductor >/dev/null 2>&1; then
  echo "ERROR: 'conductor' is not on PATH; install it (brew install autumngarage/conductor/conductor) before running this slow probe." >&2
  exit 1
fi

DIR="$(cd "$(dirname "$0")" && pwd)"
exec env TOUCHSTONE_REAL_BOOTSTRAP=1 bash "$DIR/test-bootstrap.sh" "$@"
