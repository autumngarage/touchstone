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

# All THREE legacy dotfiles. State detection that keys on .toolkit-version
# alone calls a half-migrated project normally managed: rename that one file
# and .toolkit-config keeps sitting on disk unread, where `touchstone init`
# writes a default .touchstone-config straight over the project's targets and
# command overrides. The deleted migrator scanned all three; anything that
# decides "is this project legacy?" has to scan all three too (#801 review,
# round 3).
touchstone_legacy_toolkit_dotfiles() {
  printf '.toolkit-version\n'
  printf '.toolkit-manifest\n'
  printf '.toolkit-config\n'
}

# Every legacy dotfile still present in the project, one per line (empty when
# the project is clean). Presence is `-e OR -L`: a dangling symlink named
# .toolkit-config is still a half-migrated project, and a predicate that only
# asks -e would wave it through.
touchstone_legacy_toolkit_present() {
  local project_dir="$1" name
  while IFS= read -r name; do
    [ -e "$project_dir/$name" ] || [ -L "$project_dir/$name" ] || continue
    printf '%s\n' "$name"
  done < <(touchstone_legacy_toolkit_dotfiles)
  return 0
}

# touchstone_legacy_toolkit_refusal <project_dir> <resume_command>
#
# The whole refusal body — headline, what is still there, and the recipe — one
# line per output line, unindented and unprefixed so each caller owns its
# gutter. This is the DECISION as well as the message:
#
#   exit 0  a refusal was printed; the caller must stop
#   exit 1  nothing legacy remains; nothing printed
#
# Callers must not re-derive the condition from a single filename, which is
# the bug this exists to close.
touchstone_legacy_toolkit_refusal() {
  local project_dir="$1" resume_command="$2"
  local present name new_name

  present="$(touchstone_legacy_toolkit_present "$project_dir")"
  [ -n "$present" ] || return 1

  if [ -e "$project_dir/.touchstone-version" ] || [ -L "$project_dir/.touchstone-version" ]; then
    printf 'Migration conflict: legacy toolkit dotfiles remain alongside .touchstone-version.\n'
  else
    printf 'Legacy toolkit dotfiles found: this project predates the toolkit -> touchstone rename.\n'
  fi
  while IFS= read -r name; do
    new_name=".touchstone${name#.toolkit}"
    if [ -e "$project_dir/$new_name" ] || [ -L "$project_dir/$new_name" ]; then
      printf '  still present: %s   (and %s already exists — reconcile them by hand)\n' "$name" "$new_name"
    else
      printf '  still present: %s\n' "$name"
    fi
  done <<<"$present"
  touchstone_legacy_toolkit_migration_steps "$resume_command"
  return 0
}

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
