#!/usr/bin/env bash
# Shared test helper: stage the lib/ modules that scripts/open-pr.sh and
# scripts/merge-pr.sh load at startup into a fixture's sibling lib/ dir.
#
# open-pr.sh fails CLOSED when lib/preflight.sh is absent (issue #689), so
# every fixture that copies a delivery script must also carry the modules
# that script sources — and preflight itself sources sha256/toml. Keeping
# that list here means a future module addition updates one place instead
# of every harness.
#
# Usage: stage_touchstone_libs "$TOUCHSTONE_ROOT" "$SCRIPT_DIR"
#   where $SCRIPT_DIR is the fixture dir holding the copied script; the
#   modules land in "$SCRIPT_DIR/../lib" exactly as the scripts resolve them.

stage_touchstone_libs() {
  local touchstone_root="$1" script_dir="$2" lib_dir module
  lib_dir="$script_dir/../lib"
  mkdir -p "$lib_dir"
  for module in preflight.sh sha256.sh toml.sh events.sh; do
    if [ -f "$touchstone_root/lib/$module" ]; then
      cp "$touchstone_root/lib/$module" "$lib_dir/$module"
    fi
  done
}
