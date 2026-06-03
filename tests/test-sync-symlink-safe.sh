#!/usr/bin/env bash
#
# tests/test-sync-symlink-safe.sh — regression guard against symlink-through
# writes during sync. `cp` follows symlinks, so a symlink planted at a managed
# path (by a hostile/cloned project tree) would make update_file clobber or
# CREATE the link target — possibly outside the project. update_file must
# replace an unexpected symlink with the real managed file instead. The
# executable-bit pass must likewise skip symlinks.
#
# We extract update_file() from the real updater and exercise it directly.
#
# DRY_RUN/ADDED/UPDATED/UNCHANGED/ADDED_PATHS are consumed by the eval'd
# update_file; shellcheck cannot see through eval (file-scoped directive).
# shellcheck disable=SC2034
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$TOUCHSTONE_ROOT/bootstrap/update-project.sh"
TEST_DIR="$(mktemp -d -t touchstone-test-symlink-safe.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0
fail() {
  echo "FAIL: $1" >&2
  ERRORS=$((ERRORS + 1))
}

extract_fn() {
  awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{f=1} f{print} f&&/^}/{exit}' "$SRC"
}

# Load the real update_file with a minimal stub for its one helper + globals.
relative_project_path() { printf '%s' "$1"; }
DRY_RUN=false
ADDED=0
UPDATED=0
UNCHANGED=0
ADDED_PATHS=()
eval "$(extract_fn update_file)"

PROJ="$TEST_DIR/project"
OUTSIDE="$TEST_DIR/outside"
mkdir -p "$PROJ/scripts" "$OUTSIDE"

# Managed source content we expect to land in the project (and nowhere else).
MANAGED_SRC="$TEST_DIR/managed-source.sh"
printf 'MANAGED_CONTENT\n' >"$MANAGED_SRC"

# === Case 1: managed path is a symlink to an EXISTING file outside the project ===
printf 'PROTECTED_SECRET\n' >"$OUTSIDE/secret"
ln -s "$OUTSIDE/secret" "$PROJ/scripts/managed-a.sh"
update_file "$MANAGED_SRC" "$PROJ/scripts/managed-a.sh" >/dev/null 2>&1 || true
if [ "$(cat "$OUTSIDE/secret")" != "PROTECTED_SECRET" ]; then
  fail "write through symlink clobbered an outside file (Case 1)"
fi
if [ -L "$PROJ/scripts/managed-a.sh" ]; then
  fail "managed path still a symlink after update (Case 1)"
fi
if [ "$(cat "$PROJ/scripts/managed-a.sh" 2>/dev/null)" != "MANAGED_CONTENT" ]; then
  fail "managed file not written with managed content (Case 1)"
fi

# === Case 2: managed path is a DANGLING symlink pointing outside the project ===
ln -s "$OUTSIDE/created-by-attack" "$PROJ/scripts/managed-b.sh"
update_file "$MANAGED_SRC" "$PROJ/scripts/managed-b.sh" >/dev/null 2>&1 || true
if [ -e "$OUTSIDE/created-by-attack" ]; then
  fail "write through dangling symlink CREATED a file outside the project (Case 2)"
fi
if [ -L "$PROJ/scripts/managed-b.sh" ]; then
  fail "managed path still a symlink after update (Case 2)"
fi
if [ "$(cat "$PROJ/scripts/managed-b.sh" 2>/dev/null)" != "MANAGED_CONTENT" ]; then
  fail "managed file not written with managed content (Case 2)"
fi

# === Case 3: ordinary managed file still updates normally ===
printf 'OLD\n' >"$PROJ/scripts/managed-c.sh"
update_file "$MANAGED_SRC" "$PROJ/scripts/managed-c.sh" >/dev/null 2>&1 || true
if [ "$(cat "$PROJ/scripts/managed-c.sh")" != "MANAGED_CONTENT" ]; then
  fail "ordinary managed file failed to update (Case 3)"
fi

# === Case 4: chmod pass must not follow a symlink onto an outside target ===
printf 'OUTSIDE_EXEC_TARGET\n' >"$OUTSIDE/exec-target"
chmod 600 "$OUTSIDE/exec-target"
ln -s "$OUTSIDE/exec-target" "$PROJ/scripts/link.sh"
# Exact command shipped by update-project.sh:
find "$PROJ/scripts" -maxdepth 1 -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
perms="$(ls -l "$OUTSIDE/exec-target" | cut -c1-10)"
case "$perms" in
  *x*) fail "chmod followed a symlink and made an outside file executable (perms=$perms)" ;;
esac

if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: sync never writes through or chmods through symlinks"
else
  echo "==> FAILED with $ERRORS error(s)" >&2
  exit 1
fi
