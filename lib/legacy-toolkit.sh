#!/usr/bin/env bash
#
# lib/legacy-toolkit.sh — the one recovery recipe for a project bootstrapped
# before the v1.0.0 toolkit -> touchstone rename.
#
# `touchstone migrate-from-toolkit` used to drive this migration. It went with
# the rest of the conveniences (#737): three renames and one sed is work the
# agent reading the error can do, and Touchstone's job is to refuse to run on a
# half-migrated project, not to perform the rename for it.
#
# What the cut must not lose is the recipe's completeness. The migrator renamed
# all THREE legacy dotfiles and rewrote the path references recorded inside the
# manifest. Instructions naming only .toolkit-version and .toolkit-manifest
# leave .toolkit-config sitting on disk where nothing reads it — project_type,
# targets, sync_auto, and every command override silently revert to defaults,
# and the migration looks finished (#801 review).
#
# One helper, three call sites (update, init, doctor), because three hand-kept
# copies of a recipe is how a surface ends up complete in one place and stale
# in the others.

# touchstone_legacy_toolkit_migration_steps <resume_command>
# Prints the migration one step per line, unindented and unprefixed: each
# caller owns its own gutter (an ERROR block on stderr in update-project.sh,
# tk_dim in the CLI).
touchstone_legacy_toolkit_migration_steps() {
  local resume_command="$1"
  printf 'Migrate the legacy dotfiles yourself, then rerun: %s\n' "$resume_command"
  printf '  1. git mv .toolkit-version .touchstone-version\n'
  printf '  2. git mv .toolkit-manifest .touchstone-manifest\n'
  printf '  3. git mv .toolkit-config .touchstone-config     (skip any that is absent)\n'
  printf '  4. rewrite the legacy paths recorded inside .touchstone-manifest:\n'
  printf '     .toolkit- -> .touchstone- , toolkit-run.sh -> touchstone-run.sh\n'
  printf '  5. commit that rename on its own, so the migration stays reviewable\n'
  printf 'Skipping step 3 leaves .toolkit-config unread: project_type, targets,\n'
  printf 'and every command override silently revert to their defaults.\n'
}
