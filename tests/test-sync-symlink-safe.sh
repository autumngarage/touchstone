#!/usr/bin/env bash
#
# tests/test-sync-symlink-safe.sh — regression guard against symlink-traversal
# writes during sync. cp/mkdir/redirects all follow symlinks, so a symlink at a
# managed path — OR at any ancestor directory of one — could make a write land
# outside the project. Every project-write site routes through ensure_safe_dest,
# which replaces a final-component symlink with the real file and hard-refuses a
# symlinked ancestor directory.
#
# We extract ensure_safe_dest() and update_file() from the real updater and
# exercise them directly.
#
# DRY_RUN/ADDED/UPDATED/UNCHANGED/ADDED_PATHS/SKIPPED_UNSAFE/PROJECT_DIR are
# consumed by the eval'd functions; shellcheck can't see through eval.
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

relative_project_path() { printf '%s' "$1"; }
DRY_RUN=false
ADDED=0
UPDATED=0
UNCHANGED=0
SKIPPED_UNSAFE=0
ADDED_PATHS=()
# update_file's ensure_safe_dest wrapper delegates to the shared guard.
# shellcheck source=../lib/safe-write.sh
source "$TOUCHSTONE_ROOT/lib/safe-write.sh"
eval "$(extract_fn ensure_safe_dest)"
eval "$(extract_fn update_file)"

OUTSIDE="$TEST_DIR/outside"
mkdir -p "$OUTSIDE"
MANAGED_SRC="$TEST_DIR/managed-source.sh"
printf 'MANAGED_CONTENT\n' >"$MANAGED_SRC"

# Each scenario gets a fresh PROJECT_DIR (ensure_safe_dest walks up to it).
fresh_project() {
  PROJECT_DIR="$TEST_DIR/proj-$1"
  mkdir -p "$PROJECT_DIR/scripts"
}

# === Case 1: managed path is a symlink to an EXISTING outside file ===
fresh_project c1
printf 'PROTECTED\n' >"$OUTSIDE/secret1"
ln -s "$OUTSIDE/secret1" "$PROJECT_DIR/scripts/a.sh"
update_file "$MANAGED_SRC" "$PROJECT_DIR/scripts/a.sh" >/dev/null 2>&1 || true
[ "$(cat "$OUTSIDE/secret1")" = "PROTECTED" ] || fail "C1: write-through clobbered outside file"
[ ! -L "$PROJECT_DIR/scripts/a.sh" ] || fail "C1: managed path still a symlink"
[ "$(cat "$PROJECT_DIR/scripts/a.sh" 2>/dev/null)" = "MANAGED_CONTENT" ] || fail "C1: managed file not written"

# === Case 2: DANGLING symlink at the managed path ===
fresh_project c2
ln -s "$OUTSIDE/created2" "$PROJECT_DIR/scripts/b.sh"
update_file "$MANAGED_SRC" "$PROJECT_DIR/scripts/b.sh" >/dev/null 2>&1 || true
[ ! -e "$OUTSIDE/created2" ] || fail "C2: write-through dangling symlink created outside file"
[ "$(cat "$PROJECT_DIR/scripts/b.sh" 2>/dev/null)" = "MANAGED_CONTENT" ] || fail "C2: managed file not written"

# === Case 3 (the new finding): a managed ANCESTOR DIRECTORY is a symlink ===
# `scripts` itself points outside the project. A write to scripts/c.sh must be
# refused, not redirected through the symlinked dir.
fresh_project c3
rm -rf "${PROJECT_DIR:?}/scripts"
mkdir -p "$OUTSIDE/evil-scripts"
ln -s "$OUTSIDE/evil-scripts" "$PROJECT_DIR/scripts"
before_unsafe="$SKIPPED_UNSAFE"
update_file "$MANAGED_SRC" "$PROJECT_DIR/scripts/c.sh" >/dev/null 2>&1 || true
[ ! -e "$OUTSIDE/evil-scripts/c.sh" ] || fail "C3: wrote through symlinked ancestor directory"
[ "$SKIPPED_UNSAFE" -gt "$before_unsafe" ] || fail "C3: skipped-unsafe counter did not increment"

# === Case 4: nested ancestor symlink (.claude -> outside), deeper dst ===
fresh_project c4
mkdir -p "$OUTSIDE/evil-claude"
ln -s "$OUTSIDE/evil-claude" "$PROJECT_DIR/.claude"
update_file "$MANAGED_SRC" "$PROJECT_DIR/.claude/skills/x/y.md" >/dev/null 2>&1 || true
[ ! -e "$OUTSIDE/evil-claude/skills" ] || fail "C4: mkdir/cp traversed nested symlinked ancestor"

# === Case 5: ensure_safe_dest accepts a legitimate real path ===
fresh_project c5
mkdir -p "$PROJECT_DIR/principles"
ensure_safe_dest "$PROJECT_DIR/principles/ok.md" || fail "C5: refused a legitimate real path"

# === Case 6: chmod pass must not follow a symlink onto an outside target ===
fresh_project c6
printf 'X\n' >"$OUTSIDE/exec6"
chmod 600 "$OUTSIDE/exec6"
ln -s "$OUTSIDE/exec6" "$PROJECT_DIR/scripts/link.sh"
find "$PROJECT_DIR/scripts" -maxdepth 1 -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
case "$(ls -l "$OUTSIDE/exec6" | cut -c1-10)" in
  *x*) fail "C6: chmod followed a symlink onto an outside file" ;;
esac

# === Case 7: shared guard touchstone_ensure_safe_dest directly ===
fresh_project c7
# final-component symlink -> replaced (returns 0)
ln -s "$OUTSIDE/secret7" "$PROJECT_DIR/scripts/final.sh"
printf 'KEEP\n' >"$OUTSIDE/secret7"
touchstone_ensure_safe_dest "$PROJECT_DIR/scripts/final.sh" "$PROJECT_DIR" false || fail "C7: rejected a final-component symlink instead of replacing"
[ ! -L "$PROJECT_DIR/scripts/final.sh" ] || fail "C7: final-component symlink not removed"
[ "$(cat "$OUTSIDE/secret7")" = "KEEP" ] || fail "C7: removing final symlink touched its target"
# symlinked ancestor -> hard refuse (returns 1)
rm -rf "${PROJECT_DIR:?}/scripts"
ln -s "$OUTSIDE" "$PROJECT_DIR/scripts"
if touchstone_ensure_safe_dest "$PROJECT_DIR/scripts/x.sh" "$PROJECT_DIR" false; then
  fail "C7: accepted a write through a symlinked ancestor"
fi
# legitimate real path -> accept
fresh_project c7b
mkdir -p "$PROJECT_DIR/lib"
touchstone_ensure_safe_dest "$PROJECT_DIR/lib/real.sh" "$PROJECT_DIR" false || fail "C7: refused a legitimate real path"

# === Case 8: touchstone_block_apply refuses a symlinked AGENTS.md/GEMINI.md ===
# shellcheck source=../lib/touchstone-block.sh
source "$TOUCHSTONE_ROOT/lib/touchstone-block.sh"
fresh_project c8
printf 'OUTSIDE_AGENTS\n' >"$OUTSIDE/real-agents.md"
ln -s "$OUTSIDE/real-agents.md" "$PROJECT_DIR/AGENTS.md"
set +e
touchstone_block_apply "$PROJECT_DIR/AGENTS.md" "$TOUCHSTONE_ROOT" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "C8: touchstone_block_apply did not refuse a symlinked target"
[ "$(cat "$OUTSIDE/real-agents.md")" = "OUTSIDE_AGENTS" ] || fail "C8: block_apply wrote through the symlink to the outside file"

if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: sync never writes/chmods through a symlink at the final path or any ancestor dir"
else
  echo "==> FAILED with $ERRORS error(s)" >&2
  exit 1
fi
