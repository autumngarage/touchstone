#!/usr/bin/env bash
#
# tests/test-shellcheck.sh — run the shell linter on every script Touchstone
# ships or uses internally. This closes the R5.3 gap: before this test
# existed, SC2034 warnings on scripts/codex-review.sh passed Touchstone's
# own CI but failed downstream projects' pre-push hooks (which lint the
# synced copy at --severity=warning). Any future SC2034-class bug should
# now fail Touchstone's release flow before shipping instead of surfacing
# in a fresh downstream scaffold.
#
# Severity matches the downstream scaffold's templates/pre-commit-config.yaml
# (--severity=warning) so this test's bar is exactly what autumn-mail and
# every touchstone-bootstrapped project enforces on push.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "==> SKIP: shellcheck not installed (brew install shellcheck)"
  exit 0
fi

# Collect every shell script under the load-bearing directories. Keeps the
# coverage legible — if a new directory starts shipping .sh files, it has to
# be added here explicitly, which is the prompt to think about downstream
# propagation.
#
# Uses a portable while-read loop instead of `mapfile` because macOS ships
# /bin/bash 3.2, where `mapfile` is a missing builtin. The find + sort + loop
# combo works identically on macOS stock bash and Homebrew bash.
SCRIPTS=()
while IFS= read -r script; do
  [ -n "$script" ] && SCRIPTS+=("$script")
done < <(
  find \
    "$TOUCHSTONE_ROOT/hooks" \
    "$TOUCHSTONE_ROOT/scripts" \
    "$TOUCHSTONE_ROOT/bootstrap" \
    "$TOUCHSTONE_ROOT/lib" \
    "$TOUCHSTONE_ROOT/tests" \
    -maxdepth 1 -type f -name '*.sh' -print 2>/dev/null | sort;
  find "$TOUCHSTONE_ROOT/bin" -maxdepth 1 -type f -print 2>/dev/null | sort
)

if [ "${#SCRIPTS[@]}" -eq 0 ]; then
  echo "FAIL: no shell scripts found under bin/, hooks/, scripts/, bootstrap/, lib/, tests/" >&2
  exit 1
fi

echo "==> Test: shellcheck --severity=warning on ${#SCRIPTS[@]} shipped shell scripts"

if ! shellcheck --severity=warning "${SCRIPTS[@]}"; then
  echo "" >&2
  echo "FAIL: shellcheck flagged warnings in touchstone-shipped scripts." >&2
  echo "      Downstream projects run shellcheck at this same severity on" >&2
  echo "      their pre-push hook (templates/pre-commit-config.yaml), so" >&2
  echo "      any warning here will block a fresh scaffold's first push." >&2
  echo "      Fix the warning or add an inline '# shellcheck disable=<code>'" >&2
  echo "      with a short comment explaining why the exception is safe." >&2
  exit 1
fi

echo "==> PASS: shellcheck clean at --severity=warning"
