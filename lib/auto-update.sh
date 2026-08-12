#!/usr/bin/env bash
#
# lib/auto-update.sh — auto-update check for the Touchstone CLI.
#
# Checks if a newer version is available. Brew installs use Homebrew's formula
# state; source checkouts use GitHub Releases before pulling.
#
# Called on every `touchstone` invocation. Throttled to check at most
# once per hour to avoid slowing down every command.
#
# Env overrides:
#   TOUCHSTONE_NO_AUTO_UPDATE=1  — disable auto-update and auto-project-sync entirely
#   TOUCHSTONE_NO_AUTO_PROJECT_SYNC=1 — disable per-project file sync only
#   TOUCHSTONE_NO_AUTO_PROJECT_SHIP=1 — sync locally but do not auto-ship the update PR
#   TOUCHSTONE_UPDATE_INTERVAL   — seconds between checks (default: 3600 = 1 hour)
#

TOUCHSTONE_AUTO_UPDATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOUCHSTONE_SYNC_DISCIPLINE_PATH="$TOUCHSTONE_ROOT/lib/sync-discipline.sh"
if [ ! -f "$TOUCHSTONE_SYNC_DISCIPLINE_PATH" ]; then
  TOUCHSTONE_SYNC_DISCIPLINE_PATH="$TOUCHSTONE_AUTO_UPDATE_LIB_DIR/sync-discipline.sh"
fi
# shellcheck source=sync-discipline.sh
source "$TOUCHSTONE_SYNC_DISCIPLINE_PATH"

# Shared content-currency verdict (#731) — the same predicate behind
# `touchstone update --check`, `update-all --check`, and `touchstone status`.
# Prefer the installed root's copy so a fixture root can override it; fall
# back to this file's sibling for roots that predate the module.
TOUCHSTONE_SYNC_CONTENT_LIB_PATH="$TOUCHSTONE_ROOT/lib/sync-content.sh"
if [ ! -f "$TOUCHSTONE_SYNC_CONTENT_LIB_PATH" ]; then
  TOUCHSTONE_SYNC_CONTENT_LIB_PATH="$TOUCHSTONE_AUTO_UPDATE_LIB_DIR/sync-content.sh"
fi
# shellcheck source=sync-content.sh
source "$TOUCHSTONE_SYNC_CONTENT_LIB_PATH"

TOUCHSTONE_UPDATE_INTERVAL="${TOUCHSTONE_UPDATE_INTERVAL:-3600}"
TOUCHSTONE_STATE_DIR="${TOUCHSTONE_STATE_DIR:-$HOME/.touchstone}"
LAST_CHECK_FILE="$TOUCHSTONE_STATE_DIR/last-update-check"
TOUCHSTONE_AUTO_UPDATE_REEXEC_EXIT=75

touchstone_auto_update_version_gte() {
  local current="${1#v}" latest="${2#v}"
  awk -v current="$current" -v latest="$latest" '
    function parse_version(version, parts, count, i) {
      count = split(version, parts, ".")
      if (count < 2 || count > 3) {
        return 0
      }
      for (i = 1; i <= count; i++) {
        if (parts[i] !~ /^[0-9]+$/) {
          return 0
        }
        parts[i] += 0
      }
      for (i = count + 1; i <= 3; i++) {
        parts[i] = 0
      }
      return 1
    }

    BEGIN {
      if (!parse_version(current, cur) || !parse_version(latest, lat)) {
        exit 1
      }
      for (i = 1; i <= 3; i++) {
        if (cur[i] > lat[i]) {
          exit 0
        }
        if (cur[i] < lat[i]) {
          exit 1
        }
      }
      exit 0
    }'
}

touchstone_auto_update_installed_via_brew() {
  command -v brew >/dev/null 2>&1 && brew list touchstone &>/dev/null
}

touchstone_auto_update_brew_outdated() {
  local outdated

  outdated="$(brew outdated --quiet touchstone 2>/dev/null)" || return 2
  if printf '%s\n' "$outdated" | grep -Eq '(^|/)touchstone$'; then
    return 0
  fi

  return 1
}

touchstone_auto_update_brew_upgrade() {
  if brew upgrade touchstone 2>&1 | sed 's/^/    /' >&2; then
    echo "==> Updated touchstone via brew." >&2
    TOUCHSTONE_AUTO_UPDATE_REEXEC_PATH="$(command -v touchstone 2>/dev/null || true)"
    export TOUCHSTONE_AUTO_UPDATE_REEXEC_PATH
    return "$TOUCHSTONE_AUTO_UPDATE_REEXEC_EXIT"
  fi

  echo "WARNING: touchstone auto-update via brew failed; continuing with current version." >&2
  return 0
}

touchstone_auto_update() {
  # Skip if disabled.
  if [ "${TOUCHSTONE_NO_AUTO_UPDATE:-}" = "1" ] \
    || [ "${TOUCHSTONE_AUTO_UPDATE_REEXECED:-}" = "1" ]; then
    return 0
  fi

  # Ensure state directory exists.
  mkdir -p "$TOUCHSTONE_STATE_DIR"

  # Throttle: skip if we checked recently.
  if [ -f "$LAST_CHECK_FILE" ]; then
    local last_check
    last_check="$(cat "$LAST_CHECK_FILE" 2>/dev/null || echo 0)"
    local now
    now="$(date +%s)"
    local elapsed=$((now - last_check))
    if [ "$elapsed" -lt "$TOUCHSTONE_UPDATE_INTERVAL" ]; then
      return 0
    fi
  fi

  # Record that we're checking now (even if the check fails).
  date +%s >"$LAST_CHECK_FILE"

  # Get current version.
  local current_version
  current_version="$(cat "$TOUCHSTONE_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$current_version" ]; then
    return 0
  fi

  local installed_via_brew=false
  if touchstone_auto_update_installed_via_brew; then
    installed_via_brew=true
    local brew_outdated_status=0
    touchstone_auto_update_brew_outdated || brew_outdated_status=$?
    case "$brew_outdated_status" in
      0)
        echo "==> touchstone v${current_version} is outdated according to Homebrew. Updating..." >&2
        touchstone_auto_update_brew_upgrade
        return $?
        ;;
      1)
        return 0
        ;;
      *)
        echo "WARNING: touchstone auto-update could not check Homebrew formula freshness; falling back to GitHub release metadata." >&2
        ;;
    esac
  fi

  # Fetch latest release version from GitHub (non-blocking, timeout 5s).
  local latest_version
  latest_version="$(curl -fsSL --max-time 5 \
    "https://api.github.com/repos/autumngarage/touchstone/releases/latest" 2>/dev/null \
    | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')" || return 0

  if [ -z "$latest_version" ]; then
    return 0
  fi

  # Only upgrade when the published latest release is newer than this install.
  if touchstone_auto_update_version_gte "$current_version" "$latest_version"; then
    return 0
  fi

  # Installed version is older — try to upgrade.
  echo "==> touchstone v${current_version} is outdated (latest: v${latest_version}). Updating..." >&2

  if [ "$installed_via_brew" = true ]; then
    touchstone_auto_update_brew_upgrade
    return $?
  elif [ -d "$TOUCHSTONE_ROOT/.git" ]; then
    # Running from a git clone. Auto-pulling an unpinned tracking branch and
    # re-exec'ing it runs whatever the remote HEAD points at *now*, with no
    # integrity check — a compromised remote would execute on every machine on
    # the next command. Default to notify-only so fetched code is never run
    # without an explicit user action. Auto-pull+re-exec is opt-in.
    if [ "${TOUCHSTONE_AUTO_UPDATE_GIT_PULL:-}" = "1" ]; then
      if git -C "$TOUCHSTONE_ROOT" pull --rebase 2>&1 | sed 's/^/    /' >&2; then
        echo "==> Updated to latest via git pull." >&2
        TOUCHSTONE_AUTO_UPDATE_REEXEC_PATH="$TOUCHSTONE_ROOT/bin/touchstone"
        export TOUCHSTONE_AUTO_UPDATE_REEXEC_PATH
        return "$TOUCHSTONE_AUTO_UPDATE_REEXEC_EXIT"
      fi
      echo "WARNING: touchstone auto-update via git pull failed; continuing with current version." >&2
    else
      echo "==> Update available: v${latest_version}. Run: git -C \"$TOUCHSTONE_ROOT\" pull --rebase" >&2
      echo "    (set TOUCHSTONE_AUTO_UPDATE_GIT_PULL=1 to auto-pull git-clone installs)" >&2
    fi
  else
    echo "==> Update available: v${latest_version}. Run: brew upgrade touchstone" >&2
  fi
}

touchstone_installed_id() {
  local current_version
  current_version="$(cat "$TOUCHSTONE_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"

  # Mirror bootstrap/update-project.sh exactly: regular source checkouts record
  # the Touchstone git SHA, while brew installs and git-worktree checkouts
  # record VERSION. Comparing any other field would re-sync forever.
  if [ -d "$TOUCHSTONE_ROOT/.git" ]; then
    git -C "$TOUCHSTONE_ROOT" rev-parse HEAD
  else
    printf '%s\n' "$current_version"
  fi
}

touchstone_find_project_root() {
  local dir
  dir="$(pwd)"

  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.touchstone-version" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  return 1
}

touchstone_auto_project_sync_config_enabled() {
  local project_dir="$1" config value
  config="$project_dir/.touchstone-config"
  [ -f "$config" ] || return 0

  value="$(awk '
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    function unquote(s) {
      s = trim(s)
      if ((s ~ /^".*"$/) || (s ~ /^\047.*\047$/)) {
        s = substr(s, 2, length(s) - 2)
      }
      return s
    }
    {
      line = $0
      sub(/[[:space:]]+#.*$/, "", line)
      line = trim(line)
      if (line == "") {
        next
      }
      if (line ~ /^\[[^]]+\]$/) {
        section = substr(line, 2, length(line) - 2)
        next
      }
      eq = index(line, "=")
      if (eq == 0) {
        next
      }
      key = trim(substr(line, 1, eq - 1))
      val = unquote(substr(line, eq + 1))
      if (key == "sync_auto" || key == "auto_sync" || key == "auto_project_sync") {
        print val
      } else if (section == "sync" && key == "auto") {
        print val
      }
    }
  ' "$config" 2>/dev/null | tail -1)"

  case "$value" in
    false | False | FALSE | 0 | no | No | NO | off | Off | OFF)
      return 1
      ;;
  esac

  return 0
}

touchstone_auto_project_ship_config_enabled() {
  local project_dir="$1" config value
  config="$project_dir/.touchstone-config"
  [ -f "$config" ] || return 0

  value="$(awk '
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    function unquote(s) {
      s = trim(s)
      if ((s ~ /^".*"$/) || (s ~ /^\047.*\047$/)) {
        s = substr(s, 2, length(s) - 2)
      }
      return s
    }
    {
      line = $0
      sub(/[[:space:]]+#.*$/, "", line)
      line = trim(line)
      if (line == "") {
        next
      }
      if (line ~ /^\[[^]]+\]$/) {
        section = substr(line, 2, length(line) - 2)
        next
      }
      eq = index(line, "=")
      if (eq == 0) {
        next
      }
      key = trim(substr(line, 1, eq - 1))
      val = unquote(substr(line, eq + 1))
      if (key == "sync_ship" || key == "auto_sync_ship" || key == "auto_project_sync_ship") {
        print val
      } else if (section == "sync" && (key == "ship" || key == "auto_ship")) {
        print val
      }
    }
  ' "$config" 2>/dev/null | tail -1)"

  case "$value" in
    false | False | FALSE | 0 | no | No | NO | off | Off | OFF)
      return 1
      ;;
  esac

  return 0
}

touchstone_auto_project_ship_enabled() {
  local project_dir="$1"

  [ "${TOUCHSTONE_NO_AUTO_PROJECT_SHIP:-}" != "1" ] || return 1
  touchstone_auto_project_ship_config_enabled "$project_dir"
}

touchstone_auto_project_ship_preflight() {
  local project_dir="$1"
  local current_branch default_branch

  if ! command -v gh >/dev/null 2>&1; then
    echo "WARNING: touchstone auto-ship unavailable for $project_dir (gh CLI not installed)." >&2
    echo "         Install GitHub CLI, then run: cd \"$project_dir\" && touchstone update --ship" >&2
    return 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "WARNING: touchstone auto-ship unavailable for $project_dir (gh is not authenticated)." >&2
    echo "         Authenticate, then run: cd \"$project_dir\" && touchstone update --ship" >&2
    return 1
  fi
  if ! git -C "$project_dir" remote get-url origin >/dev/null 2>&1; then
    echo "WARNING: touchstone auto-ship unavailable for $project_dir (no git remote named origin)." >&2
    echo "         Add a GitHub remote, then run: cd \"$project_dir\" && touchstone update --ship" >&2
    return 1
  fi

  current_branch="$(git -C "$project_dir" branch --show-current 2>/dev/null || true)"
  default_branch="$(git -C "$project_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's#^origin/##' || true)"
  if [ -z "$default_branch" ]; then
    if git -C "$project_dir" show-ref --verify --quiet refs/heads/main; then
      default_branch="main"
    elif git -C "$project_dir" show-ref --verify --quiet refs/heads/master; then
      default_branch="master"
    fi
  fi
  if [ -z "$current_branch" ]; then
    echo "WARNING: touchstone auto-ship unavailable for $project_dir (detached HEAD)." >&2
    echo "         Check out the default branch, then run: cd \"$project_dir\" && touchstone update --ship" >&2
    return 1
  fi
  if [ -n "$default_branch" ] && [ "$current_branch" != "$default_branch" ]; then
    echo "WARNING: touchstone auto-ship deferred for $project_dir (current branch '$current_branch' is not '$default_branch')." >&2
    echo "         To avoid mixing app work into the Touchstone update PR, run: cd \"$project_dir\" && git switch $default_branch && touchstone update --ship" >&2
    return 1
  fi
  if [ -z "$default_branch" ] && [ "$current_branch" != "main" ] && [ "$current_branch" != "master" ]; then
    echo "WARNING: touchstone auto-ship deferred for $project_dir (could not identify the default branch from '$current_branch')." >&2
    echo "         Run from the default branch: cd \"$project_dir\" && touchstone update --ship" >&2
    return 1
  fi

  return 0
}

touchstone_semver_major_minor() {
  local version="$1"

  case "$version" in
    v*) version="${version#v}" ;;
  esac

  if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)([-+].*)?$ ]]; then
    printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi

  return 1
}

# Decide whether auto-sync should run. Identity drift is only the trigger;
# with a project_dir the CONTENT verdict decides (#731): a SHA-stamped but
# byte-identical tree used to re-run a no-op update — and print
# '==> auto-synced'/'auto-shipped' lines for syncs that did not happen — on
# every non-readonly CLI call, forever, because the no-op never rewrites the
# stamp. The 2-arg form stays identity-only for callers without a tree.
touchstone_auto_project_sync_should_sync() {
  local project_id="$1" installed_id="$2" project_dir="${3:-}"
  local project_mm installed_mm

  [ -n "$project_id" ] || return 1
  [ -n "$installed_id" ] || return 1
  [ "$project_id" != "$installed_id" ] || return 1

  if project_mm="$(touchstone_semver_major_minor "$project_id")" \
    && installed_mm="$(touchstone_semver_major_minor "$installed_id")"; then
    # Patch-only semver drift never auto-syncs; this throttle is auto-sync
    # policy layered on top of the shared verdict, not a currency claim.
    [ "$project_mm" != "$installed_mm" ] || return 1
  fi

  # Source checkouts record git SHAs instead of semver, so any drift lands
  # here. The shared content probe gives the same verdict `touchstone update
  # --check` would: content-current means nothing to sync, regardless of the
  # stamp. Probe cost is paid only on identity drift, and it replaces a full
  # update-project.sh subprocess run.
  if [ -n "$project_dir" ] \
    && touchstone_content_is_current "$project_dir" "$TOUCHSTONE_ROOT" 2>/dev/null; then
    return 1
  fi

  return 0
}

# Repair state that lives outside the project tree for a content-current
# project. Deliberately narrow: it runs update-project.sh, whose
# content-current early exit reconciles hooks and skills and then stops
# before any project write. Failures are non-fatal — this is ambient repair
# on someone else's command, never that command's business.
touchstone_auto_project_reconcile_external() {
  local project_dir="${1:-}"
  local reconcile_log reconcile_rc=0

  [ -n "$project_dir" ] || return 0
  [ -d "$project_dir" ] || return 0
  git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  # ONLY for a CONTENT-CURRENT tree. should_sync returns false for two very
  # different reasons: content is current (nothing to do but reconcile), or
  # policy declined (the patch-only semver throttle) while content is STALE.
  # In the second case update-project.sh would not take its early exit — it
  # would create and commit an update branch, bypassing the throttle it was
  # told to respect (PR #787 review, round 2). Re-probing here is the same
  # verdict the caller computed; it is cheap and it keeps this helper honest
  # regardless of which skip sent us here.
  touchstone_content_is_current "$project_dir" "$TOUCHSTONE_ROOT" 2>/dev/null || return 0

  # Non-fatal, but never silent: a failed hook or skill repair leaves the
  # project ungated, and swallowing the diagnostics made that invisible and
  # self-repeating (PR #787 review, round 2).
  reconcile_log="$(mktemp -t touchstone-reconcile.XXXXXX 2>/dev/null || true)"
  if [ -z "$reconcile_log" ]; then
    # No log is available (full or unwritable temp dir), but the STATUS still
    # is. Discarding it forced every failure to success and left the project
    # silently ungated -- the exact hole the logged path was added to close
    # (PR #787 review, round 7). Warn with the diagnose command instead.
    (cd "$project_dir" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >/dev/null 2>&1 \
      || reconcile_rc=$?
    if [ "$reconcile_rc" -ne 0 ]; then
      echo "WARNING: touchstone could not reconcile hooks/skills for $project_dir (exit $reconcile_rc)." >&2
      echo "         Diagnostics unavailable (could not create a temp log)." >&2
      echo "         Diagnose with: cd $project_dir && touchstone update" >&2
    fi
    return 0
  fi
  (cd "$project_dir" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh") >"$reconcile_log" 2>&1 \
    || reconcile_rc=$?
  if [ "$reconcile_rc" -ne 0 ]; then
    echo "WARNING: touchstone could not reconcile hooks/skills for $project_dir (exit $reconcile_rc)." >&2
    echo "         The project may be ungated. Diagnose with: cd $project_dir && touchstone update" >&2
    tail -5 "$reconcile_log" 2>/dev/null | sed 's/^/         /' >&2
  fi
  rm -f "$reconcile_log"
  return 0
}

touchstone_auto_project_sync_command_skips() {
  local command="${1:-}" subcommand="${2:-}"

  case "$command" in
    "" | help | -h | --help | version | --version | status | list | ls | diff | changelog | doctor | detect | skills | update | update-all | sync | new | init | release)
      return 0
      ;;
  esac

  # `review` still dispatches (to a deterministic preflight), and its dry-run
  # flags still mean "inspect, change nothing" — a read-only invocation must
  # not rewrite the project's managed files as a side effect. #737 dropped the
  # `adr:list` and `worker:*` entries that shared this block because those
  # commands no longer exist; these two do.
  case "$command:$subcommand" in
    review:--dry-run | review:-n)
      return 0
      ;;
  esac

  return 1
}

touchstone_auto_project_sync() {
  local command="${1:-}"
  shift 2>/dev/null || true

  if [ "${TOUCHSTONE_NO_AUTO_UPDATE:-}" = "1" ] \
    || [ "${TOUCHSTONE_NO_AUTO_PROJECT_SYNC:-}" = "1" ]; then
    return 0
  fi

  case " $command $* " in
    *" --no-auto-sync "*) return 0 ;;
  esac

  if touchstone_auto_project_sync_command_skips "$command" "$@"; then
    return 0
  fi

  local project_dir
  if ! project_dir="$(touchstone_find_project_root)"; then
    return 0
  fi

  local project_realpath touchstone_realpath
  project_realpath="$(cd "$project_dir" 2>/dev/null && pwd -P || true)"
  touchstone_realpath="$(cd "$TOUCHSTONE_ROOT" 2>/dev/null && pwd -P || true)"
  if [ -n "$project_realpath" ] && [ "$project_realpath" = "$touchstone_realpath" ]; then
    return 0
  fi

  if ! touchstone_auto_project_sync_config_enabled "$project_dir"; then
    return 0
  fi

  local project_id installed_id
  project_id="$(tr -d '[:space:]' <"$project_dir/.touchstone-version" 2>/dev/null || true)"
  installed_id="$(touchstone_installed_id)"
  [ -n "$project_id" ] || return 0
  [ -n "$installed_id" ] || return 0

  if ! touchstone_auto_project_sync_should_sync "$project_id" "$installed_id" "$project_dir"; then
    # No sync to claim — but git hooks and user-scoped skills live OUTSIDE
    # the probed project content, so a content-current tree can still have a
    # deleted hook. update-project.sh's own early exit is the ONE code path
    # that repairs them; invoking it here keeps an automatically managed
    # project gated instead of silently ungated until someone runs the
    # update by hand (PR #787 review).
    touchstone_auto_project_reconcile_external "$project_dir"
    return 0
  fi

  if ! git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "WARNING: touchstone auto-sync skipped for $project_dir (not a git repository)." >&2
    return 0
  fi

  local dirty_paths overlap_paths
  dirty_paths="$(touchstone_sync_dirty_paths "$project_dir")"
  overlap_paths="$(touchstone_sync_dirty_overlap_paths "$project_dir" "$TOUCHSTONE_ROOT")"

  # Always skip background auto-sync when dirty paths overlap planned writes.
  # Unlike an explicit `touchstone update`, auto-sync must never honor
  # TOUCHSTONE_FORCE_OVERLAP: silently overwriting uncommitted work from an
  # ambient env var is unrecoverable (managed files are not backed up).
  if [ -n "$overlap_paths" ]; then
    echo "WARNING: touchstone auto-sync skipped for $project_dir (dirty paths overlap planned touchstone writes)." >&2
    printf '%s\n' "$overlap_paths" | sed 's/^/         - /' >&2
    echo "         Resolve those paths, then run: cd \"$project_dir\" && touchstone update --ship" >&2
    touchstone_sync_log_skip "$project_dir" "$project_id" "$installed_id" "dirty-overlap" "$overlap_paths" "touchstone $command"
    return 0
  fi

  if [ -n "$dirty_paths" ]; then
    printf '==> Proceeding with sync past unrelated dirty paths: ' >&2
    printf '%s\n' "$dirty_paths" | touchstone_sync_format_path_list >&2
  fi

  local log_file
  log_file="$(mktemp -t touchstone-auto-project-sync.XXXXXX)"
  local ship_update=false
  local -a update_args=()

  if touchstone_auto_project_ship_enabled "$project_dir" \
    && touchstone_auto_project_ship_preflight "$project_dir"; then
    ship_update=true
    update_args+=("--ship")
  elif touchstone_auto_project_ship_enabled "$project_dir"; then
    echo "==> touchstone auto-sync will create a local update branch only." >&2
    echo "    Ship it later with: cd \"$project_dir\" && git checkout <chore/touchstone-branch> && bash scripts/open-pr.sh --auto-merge" >&2
  fi

  # Invariant: after any non-readonly `touchstone <subcmd>` in a
  # touchstone-aware project, the project's principles/hooks/scripts match the
  # installed Touchstone CONTENT, or the user opted out, or the tree was dirty.
  local sync_rc=0
  (cd "$project_dir" && bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" ${update_args[@]+"${update_args[@]}"}) >"$log_file" 2>&1 \
    || sync_rc=$?
  if [ "$sync_rc" -eq 0 ]; then
    rm -f "$log_file"
    if [ "$ship_update" = true ]; then
      # update-project.sh --ship exits 0 only on positive merge evidence
      # (its documented tri-state contract), so "auto-shipped" here means
      # the PR actually landed.
      echo "==> auto-shipped touchstone $project_id -> $installed_id" >&2
    else
      echo "==> auto-synced touchstone $project_id -> $installed_id" >&2
      echo "    Ship the update with: cd \"$project_dir\" && git checkout <chore/touchstone-branch> && bash scripts/open-pr.sh --auto-merge" >&2
    fi
    return 0
  fi

  # Tri-state contract (bootstrap/update-project.sh): 20 = the update PR is
  # armed but NOT merged. Not a success ("auto-shipped" would be a lie) and
  # not a failure (the sync itself landed on its branch) — report it as what
  # it is so a human finishes the merge.
  if [ "$sync_rc" -eq 20 ]; then
    echo "==> touchstone auto-sync armed an update PR for $project_dir ($project_id -> $installed_id) but it is NOT merged." >&2
    echo "    Review pending or auto-merge refused; details: $log_file" >&2
    echo "    Finish it: cd \"$project_dir\" && git checkout <chore/touchstone-branch> && bash scripts/open-pr.sh --auto-merge" >&2
    return 0
  fi

  echo "WARNING: touchstone auto-sync failed for $project_dir; continuing. Log: $log_file" >&2
  echo "         Retry: cd \"$project_dir\" && touchstone update --ship" >&2
  echo "         If an update branch was created, ship it with: cd \"$project_dir\" && git checkout <chore/touchstone-branch> && bash scripts/open-pr.sh --auto-merge" >&2
  touchstone_sync_log_skip "$project_dir" "$project_id" "$installed_id" "auto-sync-failed" "" "touchstone $command"
  return 0
}
