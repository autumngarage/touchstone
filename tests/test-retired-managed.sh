#!/usr/bin/env bash
#
# tests/test-retired-managed.sh — the outcome contract of the shared retirement
# remover (lib/retired-managed.sh).
#
# Retirement is the one destructive thing Touchstone does to a project's tracked
# files, and its exit status is what both entrypoints (`touchstone init` via
# bootstrap/new-project.sh, `touchstone update` via bootstrap/update-project.sh)
# turn into counters, manifest entries, and staged deletions. Two ways that
# contract can lie, both found in PR #801 review:
#
#   * a symlink at the retired path was unlinked by the write-side safety guard
#     BEFORE the ownership and dirty-state checks ran, so a path the checks
#     would have protected was already gone when they refused;
#   * `rm` failing was never checked, so the function announced a removal that
#     did not happen and returned success — and the caller then dropped the
#     manifest entry that was the only way a later update could retry it.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-retired.XXXXXX)"
trap 'chmod -R u+w "$TEST_DIR" 2>/dev/null || true; rm -rf "$TEST_DIR"' EXIT

ERRORS=0

fail() {
  echo "FAIL: $1" >&2
  ERRORS=$((ERRORS + 1))
}

# shellcheck source=../lib/safe-write.sh
source "$TOUCHSTONE_ROOT/lib/safe-write.sh"
# shellcheck source=../lib/retired-managed.sh
source "$TOUCHSTONE_ROOT/lib/retired-managed.sh"

# A `rm` that refuses one exact path and delegates everything else to the real
# binary. Read-only parent directories would do the same job for a normal user
# and none at all for root, and this test must assert the same thing either way.
REAL_RM=""
for candidate in /bin/rm /usr/bin/rm; do
  if [ -x "$candidate" ]; then
    REAL_RM="$candidate"
    break
  fi
done
if [ -z "$REAL_RM" ]; then
  echo "FAIL: no real rm(1) found to delegate to" >&2
  exit 1
fi
FAKE_BIN="$TEST_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/rm" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *"\$TOUCHSTONE_RM_REFUSE_SUFFIX")
      [ -n "\${TOUCHSTONE_RM_REFUSE_SUFFIX:-}" ] || break
      echo "rm: \$arg: Operation not permitted" >&2
      exit 1
      ;;
  esac
done
exec "$REAL_RM" "\$@"
EOF
chmod +x "$FAKE_BIN/rm"

# --------------------------------------------------------------------------
# Fixture: a git project whose ledger claims one retired path.
# --------------------------------------------------------------------------
RETIRED_REL="lib/events.sh"

make_project() {
  local dir="$1"
  mkdir -p "$dir/lib"
  git -C "$dir" init -q -b main 2>/dev/null || {
    git init -q -b main "$dir"
  }
  git -C "$dir" config user.email "touchstone-test@example.com"
  git -C "$dir" config user.name "Touchstone Test"
  printf '%s\n' "$RETIRED_REL" >"$dir/.touchstone-manifest"
  printf 'placeholder\n' >"$dir/README.md"
  git -C "$dir" add .touchstone-manifest README.md
  git -C "$dir" commit -q -m "initial"
}

new_project() {
  local dir="$TEST_DIR/$1"
  mkdir -p "$dir"
  make_project "$dir"
  printf '%s' "$dir"
}

run_remove() {
  local dir="$1" dry="${2:-false}" rc=0
  touchstone_remove_retired_managed_file "$dir" "$RETIRED_REL" "$dry" \
    >"$TEST_DIR/out.txt" 2>&1 || rc=$?
  printf '%s' "$rc"
}

expect_rc() {
  local label="$1" actual="$2" expected="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# --------------------------------------------------------------------------
# 1. Tracked and clean: removed, status 0.
# --------------------------------------------------------------------------
echo "==> tracked and clean retired file is removed"
P="$(new_project p-clean)"
printf '# retired telemetry\n' >"$P/$RETIRED_REL"
git -C "$P" add "$RETIRED_REL"
git -C "$P" commit -q -m "add retired file"
expect_rc "tracked+clean" "$(run_remove "$P")" 0
[ ! -e "$P/$RETIRED_REL" ] || fail "tracked+clean: file should be gone"
grep -q "removed retired managed file" "$TEST_DIR/out.txt" \
  || fail "tracked+clean: expected the removal to be announced"

# --------------------------------------------------------------------------
# 2. Untracked: left in place, status 3.
# --------------------------------------------------------------------------
echo "==> untracked retired file is left in place"
P="$(new_project p-untracked)"
printf '# project-owned\n' >"$P/$RETIRED_REL"
expect_rc "untracked" "$(run_remove "$P")" 3
[ -f "$P/$RETIRED_REL" ] || fail "untracked: file should survive"

# --------------------------------------------------------------------------
# 3. Locally modified: left in place, status 3.
# --------------------------------------------------------------------------
echo "==> locally modified retired file is left in place"
P="$(new_project p-dirty)"
printf '# retired telemetry\n' >"$P/$RETIRED_REL"
git -C "$P" add "$RETIRED_REL"
git -C "$P" commit -q -m "add retired file"
printf '# local customization\n' >>"$P/$RETIRED_REL"
expect_rc "modified" "$(run_remove "$P")" 3
grep -q "local customization" "$P/$RETIRED_REL" \
  || fail "modified: local edit should survive"

# --------------------------------------------------------------------------
# 4. REGRESSION (#801): an untracked SYMLINK at the retired path survives.
#
# touchstone_ensure_safe_dest replaces a final-component symlink so a managed
# copy can land on a real file. Reused as the removal guard it unlinked the
# symlink first; the `! -f` test then saw the hole it had just made, reported
# "refusing to remove unsafe retired path", and returned before the ownership
# check that exists to protect exactly this file. The link was already gone.
# --------------------------------------------------------------------------
echo "==> untracked symlink at a retired path is inspected, not unlinked"
P="$(new_project p-symlink-untracked)"
printf '# my own telemetry\n' >"$P/lib/my-telemetry.sh"
ln -s "my-telemetry.sh" "$P/$RETIRED_REL"
expect_rc "untracked symlink" "$(run_remove "$P")" 3
[ -L "$P/$RETIRED_REL" ] \
  || fail "untracked symlink: the link itself should still be there, unfollowed"
[ -f "$P/lib/my-telemetry.sh" ] || fail "untracked symlink: link target should survive"
grep -q "leaving untracked retired file in place" "$TEST_DIR/out.txt" \
  || fail "untracked symlink: expected the untracked refusal, not the unsafe-path one"
if grep -q "replacing unexpected symlink with managed file" "$TEST_DIR/out.txt"; then
  fail "untracked symlink: the write-side symlink replacement must not run on a removal"
fi

# --------------------------------------------------------------------------
# 5. A tracked, clean symlink is removed like any other tracked managed copy —
#    the link, never what it points at.
# --------------------------------------------------------------------------
echo "==> tracked clean symlink is removed without following it"
P="$(new_project p-symlink-tracked)"
printf '# shared telemetry\n' >"$P/lib/shared-telemetry.sh"
ln -s "shared-telemetry.sh" "$P/$RETIRED_REL"
git -C "$P" add "$RETIRED_REL" "lib/shared-telemetry.sh"
git -C "$P" commit -q -m "add retired symlink"
expect_rc "tracked symlink" "$(run_remove "$P")" 0
[ ! -L "$P/$RETIRED_REL" ] || fail "tracked symlink: the link should be removed"
[ -f "$P/lib/shared-telemetry.sh" ] \
  || fail "tracked symlink: rm must unlink the link, never its target"

# --------------------------------------------------------------------------
# 6. A directory at the retired path is refused untouched, status 2.
# --------------------------------------------------------------------------
echo "==> a directory at a retired path is refused untouched"
P="$(new_project p-directory)"
mkdir -p "$P/$RETIRED_REL"
printf 'keep\n' >"$P/$RETIRED_REL/inner.txt"
expect_rc "directory" "$(run_remove "$P")" 2
[ -f "$P/$RETIRED_REL/inner.txt" ] || fail "directory: contents should be untouched"

# --------------------------------------------------------------------------
# 7. Dry run reports without removing, status 4.
# --------------------------------------------------------------------------
echo "==> dry run reports without removing"
P="$(new_project p-dry)"
printf '# retired telemetry\n' >"$P/$RETIRED_REL"
git -C "$P" add "$RETIRED_REL"
git -C "$P" commit -q -m "add retired file"
expect_rc "dry run" "$(run_remove "$P" true)" 4
[ -f "$P/$RETIRED_REL" ] || fail "dry run: file should survive"

# --------------------------------------------------------------------------
# 8. Not claimed by the ledger: nothing to do, status 1.
# --------------------------------------------------------------------------
echo "==> a path the manifest does not claim is left alone"
P="$(new_project p-unmanifested)"
: >"$P/.touchstone-manifest"
printf '# project-owned\n' >"$P/$RETIRED_REL"
expect_rc "unmanifested" "$(run_remove "$P")" 1
[ -f "$P/$RETIRED_REL" ] || fail "unmanifested: file should survive"

# --------------------------------------------------------------------------
# 9. REGRESSION (#801): a failed `rm` is reported as a failure, never as a
#    removal.
#
#    Both callers invoke this function in a status-capturing conditional, which
#    makes `set -e` inert inside it. An unchecked `rm` therefore fell through to
#    the success message and returned 0; the updater recorded a retirement,
#    regenerated the manifest without the entry, and left the file on disk where
#    no later update could ever reach it again.
# --------------------------------------------------------------------------
echo "==> a failed removal returns a failure and announces nothing"
P="$(new_project p-rm-fails)"
printf '# retired telemetry\n' >"$P/$RETIRED_REL"
git -C "$P" add "$RETIRED_REL"
git -C "$P" commit -q -m "add retired file"
RM_FAIL_RC=0
(
  export PATH="$FAKE_BIN:$PATH"
  export TOUCHSTONE_RM_REFUSE_SUFFIX="/$RETIRED_REL"
  touchstone_remove_retired_managed_file "$P" "$RETIRED_REL" false
) >"$TEST_DIR/out.txt" 2>&1 || RM_FAIL_RC=$?
expect_rc "failed rm" "$RM_FAIL_RC" 5
[ -f "$P/$RETIRED_REL" ] || fail "failed rm: the file is the whole point — it must still be there"
grep -q "failed to remove retired managed file" "$TEST_DIR/out.txt" \
  || fail "failed rm: expected the failure to be named"
if grep -q "^    - removed retired managed file" "$TEST_DIR/out.txt"; then
  fail "failed rm: announced a removal that did not happen"
fi

# --------------------------------------------------------------------------
# 10. The fake rm must actually be able to fail, or test 9 proves nothing.
# --------------------------------------------------------------------------
echo "==> the fake rm refuses only its target"
P="$(new_project p-fake-rm-sanity)"
printf 'x\n' >"$P/$RETIRED_REL"
printf 'y\n' >"$P/lib/other.sh"
(
  export PATH="$FAKE_BIN:$PATH"
  export TOUCHSTONE_RM_REFUSE_SUFFIX="/$RETIRED_REL"
  rm -f "$P/lib/other.sh"
) || fail "fake rm sanity: unrelated removals must still work"
[ ! -e "$P/lib/other.sh" ] || fail "fake rm sanity: unrelated file should be gone"
if (
  export PATH="$FAKE_BIN:$PATH"
  export TOUCHSTONE_RM_REFUSE_SUFFIX="/$RETIRED_REL"
  rm -f "$P/$RETIRED_REL"
) 2>/dev/null; then
  fail "fake rm sanity: the refused path should have failed"
fi

echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: retirement remover outcome contract holds"
  exit 0
fi
echo "==> FAIL: $ERRORS problem(s)" >&2
exit 1
