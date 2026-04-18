#!/usr/bin/env bash
#
# tests/test-dogfood.sh — verify Touchstone's own repo uses the same validate
# entrypoint it ships to downstream projects. A regression here would mean
# the shared entrypoint could break without anyone noticing until a downstream
# project tried to use it.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRE_COMMIT_CONFIG="$TOUCHSTONE_ROOT/.pre-commit-config.yaml"
TOUCHSTONE_CONFIG="$TOUCHSTONE_ROOT/.touchstone-config"

if [ ! -f "$PRE_COMMIT_CONFIG" ]; then
  echo "FAIL: $PRE_COMMIT_CONFIG is missing" >&2
  exit 1
fi

# Touchstone must gate pushes via the same touchstone-validate hook downstream
# projects get from templates/pre-commit-config.yaml — otherwise a regression
# in the dispatcher only surfaces on downstream projects.
if ! grep -q 'id: touchstone-validate' "$PRE_COMMIT_CONFIG"; then
  echo "FAIL: $PRE_COMMIT_CONFIG must dogfood the touchstone-validate hook" >&2
  echo "      Downstream projects use this hook; Touchstone must exercise the same path." >&2
  exit 1
fi

if ! grep -q 'scripts/touchstone-run.sh validate' "$PRE_COMMIT_CONFIG"; then
  echo "FAIL: touchstone-validate hook must invoke scripts/touchstone-run.sh validate" >&2
  exit 1
fi

# The bespoke self-tests hook was retired in favor of routing through the shared
# validate entrypoint. Re-adding it would break the dogfood loop.
if grep -q 'id: self-tests' "$PRE_COMMIT_CONFIG"; then
  echo "FAIL: the bespoke 'self-tests' hook was replaced by 'touchstone-validate' — do not re-add it" >&2
  exit 1
fi

# .touchstone-config must set a validate_command that actually runs the
# self-tests; an empty validate_command would silently reduce coverage to
# zero since touchstone is a generic project with no profile defaults.
if [ ! -f "$TOUCHSTONE_CONFIG" ]; then
  echo "FAIL: $TOUCHSTONE_CONFIG is missing — the validate hook would no-op without it" >&2
  exit 1
fi

VALIDATE_LINE="$(sed -n 's/^validate_command[[:space:]]*=[[:space:]]*//p' "$TOUCHSTONE_CONFIG" | head -1)"
if [ -z "$VALIDATE_LINE" ]; then
  echo "FAIL: validate_command in $TOUCHSTONE_CONFIG is empty — dogfood loop has no coverage" >&2
  exit 1
fi

if ! printf '%s' "$VALIDATE_LINE" | grep -q 'tests/test-\*\.sh'; then
  echo "FAIL: validate_command must exercise tests/test-*.sh to cover the full self-test surface" >&2
  echo "      Current value: $VALIDATE_LINE" >&2
  exit 1
fi

echo "==> PASS: Touchstone dogfoods its own validate path"
