#!/usr/bin/env bash
#
# lib/sync-content.sh — the shared, read-only content-currency verdict (#731).
#
# One question, one answer: "would `touchstone update` change this tree?"
# Four surfaces consume the verdict and must always agree:
#
#   * bootstrap/update-project.sh --check   (and the update's own early exit)
#   * lib/auto-update.sh                    (touchstone_auto_project_sync_should_sync)
#   * bootstrap/sync-all.sh --check         (the fleet listing)
#   * lib/status.sh                         (_status_behind_count / `touchstone status`)
#
# Before this file existed, update --check computed content currency while
# auto-sync, sync-all --check, and status compared raw stamp identity — so a
# SHA-stamped-but-content-current tree (the arpeggio state, #773) re-probed a
# no-op update on every non-readonly CLI call and printed '==> auto-synced' /
# 'auto-shipped' lines for syncs that did not happen. Raw identity comparison
# survives only as display detail; the verdict lives here.
#
# Contract:
#   * READ-ONLY. Nothing here may write to the project or to touchstone.
#     The only filesystem mutation is a mktemp probe copy of a steering file,
#     removed before returning.
#   * Cheap enough for status calls: per managed file it costs a byte compare
#     plus a few git index reads, and callers short-circuit on identity
#     equality before probing at all.
#   * Fail closed: anything the update writer would refuse or rewrite reads
#     as stale, so the real update surfaces the error loudly.
#
# Public surface:
#   touchstone_content_installed_id <touchstone_root>
#       The identity `touchstone update` would stamp: the git SHA for a
#       source checkout (.git DIRECTORY, mirroring update-project.sh — a
#       git-worktree checkout stamps VERSION), else VERSION.
#   touchstone_content_is_current <project_dir> <touchstone_root>
#       0 iff every managed artifact matches what the writer would produce.
#   touchstone_content_tree_is_current <project_dir> <touchstone_root> [project_id] [installed_id]
#       The full verdict: stamp identity equal OR content current.
#
# The enumeration helpers (managed file pairs, manifest entries) and the
# soundness sub-predicates are exported too: bootstrap/update-project.sh's
# copy pass consumes the same enumeration the probe compares against, so the
# writer and the probe can never disagree about what "managed" means.

# Guard: only define once per shell.
if [ -n "${TOUCHSTONE_SYNC_CONTENT_SOURCED:-}" ]; then return 0; fi
TOUCHSTONE_SYNC_CONTENT_SOURCED=1

# Sibling modules, sourced defensively (no-ops when the caller already
# sourced them). This lib always ships next to them in lib/.
_TOUCHSTONE_SYNC_CONTENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v touchstone_ensure_safe_dest >/dev/null 2>&1; then
  # shellcheck source=safe-write.sh
  source "$_TOUCHSTONE_SYNC_CONTENT_LIB_DIR/safe-write.sh"
fi
if ! command -v touchstone_block_apply >/dev/null 2>&1; then
  # shellcheck source=touchstone-block.sh
  source "$_TOUCHSTONE_SYNC_CONTENT_LIB_DIR/touchstone-block.sh"
fi
if ! declare -p _TOUCHSTONE_BUNDLED_SKILL_NAMES >/dev/null 2>&1; then
  # shellcheck source=install-skills.sh
  source "$_TOUCHSTONE_SYNC_CONTENT_LIB_DIR/install-skills.sh"
fi

touchstone_content_installed_id() {
  local touchstone_root="$1"
  # Mirror bootstrap/update-project.sh exactly: regular source checkouts
  # stamp the Touchstone git SHA; brew installs and git-worktree checkouts
  # (.git is a file, not a directory) stamp VERSION. Comparing any other
  # field would re-sync forever.
  if [ -d "$touchstone_root/.git" ]; then
    git -C "$touchstone_root" rev-parse HEAD
  else
    cat "$touchstone_root/VERSION" 2>/dev/null | tr -d '[:space:]'
  fi
}

touchstone_content_project_type() {
  local project_dir="$1"
  local project_type="generic"
  if [ -f "$project_dir/.touchstone-config" ]; then
    project_type="$(grep '^project_type=' "$project_dir/.touchstone-config" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)"
  fi
  printf '%s\n' "${project_type:-generic}"
}

# Single source of truth for touchstone-owned file copies: src<TAB>dst lines
# consumed by both update-project.sh's copy pass and the content probe, so
# the two can never disagree about what "managed" means.
touchstone_content_managed_file_pairs() {
  local project_dir="$1" touchstone_root="$2"
  local f

  # Principles
  if [ -d "$touchstone_root/principles" ]; then
    for f in "$touchstone_root/principles/"*.md; do
      printf '%s\t%s\n' "$f" "$project_dir/principles/$(basename "$f")"
    done
  fi

  # TOUCHSTONE.md — canonical lean-router steering doc, imported by CLAUDE.md
  # (@TOUCHSTONE.md) and inlined into AGENTS.md/GEMINI.md by touchstone_block_apply.
  if [ -f "$touchstone_root/TOUCHSTONE.md" ]; then
    printf '%s\t%s\n' "$touchstone_root/TOUCHSTONE.md" "$project_dir/TOUCHSTONE.md"
  fi

  # Required deterministic backstop for the issue-claim workflow. General CI
  # validate.yml remains opt-in and project-owned; this workflow is part of the
  # documented Touchstone delivery contract.
  printf '%s\t%s\n' "$touchstone_root/templates/ci/issue-claim-check.yml" "$project_dir/.github/workflows/issue-claim-check.yml"

  # Scripts
  printf '%s\t%s\n' "$touchstone_root/hooks/branch-guard.sh" "$project_dir/scripts/branch-guard.sh"
  printf '%s\t%s\n' "$touchstone_root/hooks/emergency-disclosure.sh" "$project_dir/scripts/emergency-disclosure.sh"
  printf '%s\t%s\n' "$touchstone_root/scripts/touchstone-run.sh" "$project_dir/scripts/touchstone-run.sh"
  printf '%s\t%s\n' "$touchstone_root/scripts/open-pr.sh" "$project_dir/scripts/open-pr.sh"
  printf '%s\t%s\n' "$touchstone_root/scripts/merge-pr.sh" "$project_dir/scripts/merge-pr.sh"
  printf '%s\t%s\n' "$touchstone_root/scripts/claim-issue.sh" "$project_dir/scripts/claim-issue.sh"
  printf '%s\t%s\n' "$touchstone_root/scripts/respond-review.sh" "$project_dir/scripts/respond-review.sh"
  printf '%s\t%s\n' "$touchstone_root/scripts/issue-claim-check.sh" "$project_dir/scripts/issue-claim-check.sh"
  printf '%s\t%s\n' "$touchstone_root/scripts/cleanup-branches.sh" "$project_dir/scripts/cleanup-branches.sh"

  # Libraries used by touchstone-owned scripts.
  printf '%s\t%s\n' "$touchstone_root/lib/toml.sh" "$project_dir/lib/toml.sh"
  printf '%s\t%s\n' "$touchstone_root/lib/script-sync-guard.sh" "$project_dir/lib/script-sync-guard.sh"
  printf '%s\t%s\n' "$touchstone_root/lib/sha256.sh" "$project_dir/lib/sha256.sh"
  printf '%s\t%s\n' "$touchstone_root/lib/preflight.sh" "$project_dir/lib/preflight.sh"
  printf '%s\t%s\n' "$touchstone_root/lib/preflight-scope.sh" "$project_dir/lib/preflight-scope.sh"
}

# One enumeration serves the writer AND the content probe: a manifest that
# omits entries the writer would emit is stale content — doctor validates
# only listed paths, so an incomplete ledger hides files from it
# (PR #780 review).
touchstone_content_manifest_entries() {
  local project_dir="$1" touchstone_root="$2"
  local f
  printf '# Managed by touchstone. These paths may be updated by `touchstone update`.\n'
  printf '.touchstone-manifest\n'
  printf '.touchstone-version\n'
  printf 'TOUCHSTONE.md\n'
  printf '.github/workflows/issue-claim-check.yml\n'
  if [ -d "$touchstone_root/principles" ]; then
    for f in "$touchstone_root/principles/"*.md; do
      printf 'principles/%s\n' "$(basename "$f")"
    done
  fi
  printf 'scripts/branch-guard.sh\n'
  printf 'scripts/emergency-disclosure.sh\n'
  printf 'scripts/touchstone-run.sh\n'
  printf 'scripts/open-pr.sh\n'
  printf 'scripts/merge-pr.sh\n'
  printf 'scripts/claim-issue.sh\n'
  printf 'scripts/respond-review.sh\n'
  printf 'scripts/issue-claim-check.sh\n'
  printf 'scripts/cleanup-branches.sh\n'
  printf 'lib/toml.sh\n'
  printf 'lib/script-sync-guard.sh\n'
  printf 'lib/sha256.sh\n'
  printf 'lib/preflight.sh\n'
  printf 'lib/preflight-scope.sh\n'
  printf '.claude/settings.json\n'
  # Touchstone-bundled skills are user-scoped (~/.claude/skills); the update
  # ships nothing into <project>/.claude/skills, so the ledger must not
  # claim those paths. The old enumeration here manifested files the copy
  # pass never wrote — phantom entries every downstream manifest carried
  # since the user-scope migration (surfaced by PR #780's ledger probe).
}

# Index equality is decided by OBJECT IDs, never `git diff --quiet`: the
# assume-unchanged and skip-worktree bits mark an index entry "not changing",
# so diff-based checks report clean while the indexed blob — the bytes a
# clean clone actually receives — differs from the working tree. Hashing the
# working-tree file with the path's attribute filters applied compares the
# same conversion `git add` would perform (PR #780 review, round 3 P2).
touchstone_content_index_blob_matches_worktree() {
  local project_dir="$1" rel="$2"
  local index_blob worktree_blob link_target
  index_blob="$(git -C "$project_dir" rev-parse --verify --quiet ":$rel")" || return 1
  if [ -L "$project_dir/$rel" ]; then
    # git stores a symlink as a blob holding its TARGET PATH, while
    # `git hash-object -- <link>` opens the link and hashes what it points at
    # — so hashing the file would report every tracked, unmodified symlink as
    # modified. Hash the link text, which is the byte sequence a clean clone
    # receives. --path is deliberately absent: no attribute filter applies to
    # a symlink blob (#801 review, round 3). Every caller in this file rejects
    # symlinks before asking, so this branch exists for the retirement remover
    # in lib/retired-managed.sh, which must inspect one.
    link_target="$(readlink "$project_dir/$rel")" || return 1
    worktree_blob="$(printf '%s' "$link_target" | git -C "$project_dir" hash-object -t blob --stdin)" || return 1
  else
    worktree_blob="$(git -C "$project_dir" hash-object --path="$rel" -- "$project_dir/$rel" 2>/dev/null)" || return 1
  fi
  [ "$index_blob" = "$worktree_blob" ]
}

# One soundness predicate for every managed path the content probe accepts:
# not a symlink (the writer would replace it), safe destination (no symlinked
# ancestors — the writer would refuse), tracked in the index (clean clones
# would miss it), and index blob identical to the working tree (a stale
# staged blob would commit stale content right past a green probe). The
# probe's per-file byte comparison means nothing without these
# (PR #780 review, rounds 1-2).
touchstone_content_managed_path_is_sound() {
  local project_dir="$1" rel="$2"
  local dst="$project_dir/$rel"
  [ ! -L "$dst" ] || return 1
  touchstone_ensure_safe_dest "$dst" "$project_dir" true >/dev/null 2>&1 || return 1
  git -C "$project_dir" ls-files --error-unmatch "$rel" >/dev/null 2>&1 || return 1
  touchstone_content_index_blob_matches_worktree "$project_dir" "$rel" || return 1
  # Blob OIDs deliberately omit the mode: an executable working file over a
  # 100644 stage entry hashes identically, and a clean clone would receive a
  # non-executable script (PR #780 review). The stage mode must carry the
  # same executable bit the working tree has.
  local stage_mode
  stage_mode="$(git -C "$project_dir" ls-files --stage -- "$rel" | awk '{print $1; exit}')"
  if [ -x "$dst" ]; then
    [ "$stage_mode" = "100755" ] || return 1
  else
    [ "$stage_mode" != "100755" ] || return 1
  fi
}

# Steering files may legitimately live untracked or gitignored
# (stage_refreshed_steering_file supports exactly that), so their soundness
# drops the tracking requirement: never a symlink, safe destination, and —
# only when tracked — index blob equal to the working tree
# (PR #780 review, override round).
touchstone_content_steering_path_is_sound() {
  local project_dir="$1" rel="$2"
  local dst="$project_dir/$rel"
  [ ! -L "$dst" ] || return 1
  touchstone_ensure_safe_dest "$dst" "$project_dir" true >/dev/null 2>&1 || return 1
  if git -C "$project_dir" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
    touchstone_content_index_blob_matches_worktree "$project_dir" "$rel" || return 1
  fi
}

# An add-if-missing template slot counts as occupied when ANY directory
# entry exists there — regular file, symlink to a file, dangling symlink, or
# directory. Occupied means project-owned and hands-off for both the writer
# (add_project_template_if_missing) and the content probe; `-f` alone
# follows symlinks and made the two disagree (PR #780 review, round 3 P2).
touchstone_content_template_slot_occupied() {
  [ -e "$1" ] || [ -L "$1" ]
}

# Would touchstone_block_apply change this steering file? Runs the exact
# writer against a throwaway copy so probe and writer can never diverge.
# Fail closed: anything the writer would refuse (orphaned sentinel, symlink)
# reads as stale so the real update surfaces the error loudly.
touchstone_content_steering_block_is_current() {
  local target="$1" touchstone_root="$2"
  local tmp status=0

  [ -e "$target" ] || return 0
  [ -L "$target" ] && return 1
  [ -f "$target" ] || return 1

  tmp="$(mktemp -t touchstone-block-probe.XXXXXX)"
  cp "$target" "$tmp"
  touchstone_block_apply "$tmp" "$touchstone_root" >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 0 ] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# #773: .touchstone-version is derived state. A source-checkout sync stamps a
# git SHA while a brew install compares its release semver, so the identities
# can disagree over a byte-identical tree — and the stale-guard then blocks
# every PR while `touchstone update` reports nothing to update. Staleness is
# decided by the content the update would actually write, never by the stamp
# alone. Fail closed: any missing, differing, or unrefreshable managed
# artifact keeps the tree stale.
touchstone_content_is_current() {
  local project_dir="$1" touchstone_root="$2"
  local src dst skill_name project_type

  project_type="$(touchstone_content_project_type "$project_dir")"

  # The manifest must be a rewritable regular file; let the real update
  # surface anything else as a loud failure.
  [ -f "$project_dir/.touchstone-manifest" ] || return 1
  [ -r "$project_dir/.touchstone-manifest" ] || return 1
  touchstone_content_managed_path_is_sound "$project_dir" ".touchstone-manifest" || return 1
  # The stamp's VALUE differs by definition in the identity-mismatch case;
  # its soundness (tracked, unsymlinked, index==worktree) must not — an
  # untracked marker leaves clean clones unable to recognize a bootstrapped
  # project (PR #780 review, override round).
  touchstone_content_managed_path_is_sound "$project_dir" ".touchstone-version" || return 1

  # A retirement the update would still apply is a pending change.
  local manifest_entries
  manifest_entries="$(tr -d '\r' <"$project_dir/.touchstone-manifest" 2>/dev/null)" || return 1
  if grep -qxF "lib/review-comment.sh" <<<"$manifest_entries" \
    && [ -e "$project_dir/lib/review-comment.sh" ]; then
    return 1
  fi

  # The ledger itself must match what the writer would emit today.
  if ! diff -q <(touchstone_content_manifest_entries "$project_dir" "$touchstone_root") \
    <(printf '%s\n' "$manifest_entries") >/dev/null 2>&1; then
    return 1
  fi

  while IFS=$'\t' read -r src dst; do
    touchstone_content_managed_path_is_sound "$project_dir" "${dst#"$project_dir"/}" || return 1
    [ -f "$dst" ] || return 1
    cmp -s "$src" "$dst" || return 1
    case "$dst" in
      "$project_dir"/scripts/*.sh)
        # The update chmods managed scripts; a missing execute bit is a change.
        [ -x "$dst" ] || return 1
        ;;
    esac
  done < <(touchstone_content_managed_file_pairs "$project_dir" "$touchstone_root")

  if [ -f "$touchstone_root/templates/claude-settings.json" ]; then
    touchstone_content_managed_path_is_sound "$project_dir" ".claude/settings.json" || return 1
    cmp -s "$touchstone_root/templates/claude-settings.json" "$project_dir/.claude/settings.json" || return 1
  fi

  # Project-owned templates the update would ADD when missing (their content
  # is never compared: present means project-owned, hands off). Presence is
  # ANY directory entry — regular file, symlink (even dangling), directory —
  # matching touchstone_content_template_slot_occupied exactly: `-f` follows
  # symlinks, so a symlinked config read as "present" here while the writer
  # replaced it, and a dangling one read as "missing" while the writer skips
  # it — probe and writer must never disagree (PR #780 review, round 3 P2).
  if [ -f "$touchstone_root/templates/.markdownlint.json" ] \
    && ! touchstone_content_template_slot_occupied "$project_dir/.markdownlint.json"; then
    return 1
  fi
  if [ "$project_type" = "swift" ] \
    && [ -f "$touchstone_root/templates/swift/.swiftlint.yml" ] \
    && ! touchstone_content_template_slot_occupied "$project_dir/.swiftlint.yml"; then
    return 1
  fi
  if [ -f "$touchstone_root/templates/GEMINI.md" ] \
    && ! touchstone_content_template_slot_occupied "$project_dir/GEMINI.md"; then
    return 1
  fi

  # Legacy project-scoped skill copies the update would remove.
  if [ -d "$touchstone_root/skills" ] && [ -d "$project_dir/.claude/skills" ]; then
    for skill_name in "${_TOUCHSTONE_BUNDLED_SKILL_NAMES[@]}"; do
      if [ -d "$project_dir/.claude/skills/$skill_name" ]; then
        return 1
      fi
    done
  fi

  # Both steering files are backfill-exempt here: a Gemini-only project
  # omits AGENTS.md by design, and soundness applies only to files that
  # exist — an unconditional check would recreate the stamp-only update
  # loop for those projects (PR #780 review, round 3).
  # An occupied non-file slot (e.g. a GEMINI.md directory) is project-owned:
  # the template writer and the block writer both leave it untouched, so the
  # probe must agree or every check loops a stamp-only update
  # (PR #780 review). Only regular files get soundness + block probing.
  if [ -e "$project_dir/AGENTS.md" ] && [ ! -f "$project_dir/AGENTS.md" ] && [ ! -L "$project_dir/AGENTS.md" ]; then
    :
  else
    if [ -f "$project_dir/AGENTS.md" ]; then
      touchstone_content_steering_path_is_sound "$project_dir" "AGENTS.md" || return 1
    fi
    touchstone_content_steering_block_is_current "$project_dir/AGENTS.md" "$touchstone_root" || return 1
  fi
  if [ -e "$project_dir/GEMINI.md" ] && [ ! -f "$project_dir/GEMINI.md" ] && [ ! -L "$project_dir/GEMINI.md" ]; then
    :
  else
    if [ -f "$project_dir/GEMINI.md" ]; then
      touchstone_content_steering_path_is_sound "$project_dir" "GEMINI.md" || return 1
    fi
    touchstone_content_steering_block_is_current "$project_dir/GEMINI.md" "$touchstone_root" || return 1
  fi

  return 0
}

# The full tree verdict: identity equality short-circuits (no probe cost on
# the common in-sync case), then the content probe decides. project_id /
# installed_id may be passed when the caller already read them.
touchstone_content_tree_is_current() {
  local project_dir="$1" touchstone_root="$2"
  local project_id="${3:-}" installed_id="${4:-}"

  if [ -z "$project_id" ]; then
    project_id="$(tr -d '[:space:]' <"$project_dir/.touchstone-version" 2>/dev/null || true)"
  fi
  [ -n "$project_id" ] || return 1
  if [ -z "$installed_id" ]; then
    installed_id="$(touchstone_content_installed_id "$touchstone_root")"
  fi
  if [ -n "$installed_id" ] && [ "$project_id" = "$installed_id" ]; then
    return 0
  fi
  touchstone_content_is_current "$project_dir" "$touchstone_root"
}
