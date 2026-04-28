#!/usr/bin/env bash
#
# lib/status.sh — version distribution and update-age helpers for `touchstone status`.
#
# Sourced by bin/touchstone. Owns the per-project read of `.touchstone-version`,
# the "behind" computation against the touchstone git history, the file-age
# computation, and the table renderer for `touchstone status --all`.
#
# Two outputs:
#   touchstone status        single-project block for the current working dir
#   touchstone status --all  fixed-width table walking $HOME/.touchstone-projects
#
# This file relies on RED/GREEN/YELLOW/DIM/RESET from lib/colors.sh and on
# tk_header / tk_warn from lib/colors.sh. Source colors.sh before this file.

# Guard: only define helpers once per shell.
if [ -n "${TK_STATUS_SOURCED:-}" ]; then return 0; fi
TK_STATUS_SOURCED=1

# --- registry path -----------------------------------------------------------
# Single source of truth for the registry location. Tests can point at a
# tempdir registry by overriding HOME; we deliberately do not introduce a
# second env-var override because every other touchstone caller of the
# registry already keys off HOME (sync-all.sh, completions, doctor, list).
# Adding a second knob would split the registry-resolution code path.
_status_projects_file() {
  printf '%s\n' "$HOME/.touchstone-projects"
}

# --- version / id helpers ----------------------------------------------------
# Read .touchstone-version from a project directory, trimming whitespace.
# Empty string when missing or unreadable.
_status_read_project_version() {
  local project_dir="$1"
  [ -f "$project_dir/.touchstone-version" ] || return 0
  tr -d '[:space:]' < "$project_dir/.touchstone-version" 2>/dev/null || true
}

# Render a recorded id for display. Long SHAs become short SHAs; semver-ish
# strings ("2.3.4") pass through unchanged. The 12-char threshold matches the
# rest of bin/touchstone's id-shortening (cmd_init's installed/current dim).
_status_display_id() {
  local id="$1"
  if [ "${#id}" -ge 12 ] && printf '%s' "$id" | grep -Eq '^[0-9a-f]+$'; then
    printf '%s' "${id:0:12}"
  else
    printf '%s' "$id"
  fi
}

# --- "behind" computation ----------------------------------------------------
# Count touchstone commits between the project's recorded version and the
# current touchstone HEAD. Mirrors the OLD_SHA/CURRENT_SHA logic in
# bootstrap/update-project.sh:
#   - same id            -> "current"
#   - reachable history  -> integer count of commits ahead
#   - non-SHA / GC'd     -> "?"
#   - non-git touchstone -> "?" (brew install: no history to walk)
#
# Echoes the display string. Never errors.
_status_behind_count() {
  local recorded="$1" current="$2"
  if [ -z "$recorded" ]; then
    printf '?'
    return 0
  fi
  if [ "$recorded" = "$current" ]; then
    printf 'current'
    return 0
  fi
  if [ ! -d "${TOUCHSTONE_ROOT:-/nonexistent}/.git" ]; then
    printf '?'
    return 0
  fi
  # Both ids must resolve in touchstone's git history. If the recorded id is a
  # version string (no SHA) or has been garbage-collected, rev-list will fail
  # — print "?" so the caller can paint it red without inventing a count.
  if ! git -C "$TOUCHSTONE_ROOT" rev-parse --verify "$recorded^{commit}" >/dev/null 2>&1; then
    printf '?'
    return 0
  fi
  local count
  count="$(git -C "$TOUCHSTONE_ROOT" rev-list --count "$recorded..$current" 2>/dev/null || echo "?")"
  if [ -z "$count" ]; then
    printf '?'
  else
    printf '%s' "$count"
  fi
}

# --- file-age helpers --------------------------------------------------------
# Portable mtime in epoch seconds. macOS/BSD use `stat -f %m`; GNU/Linux uses
# `stat -c %Y`. Returns empty string when the file is missing or stat fails.
_status_file_mtime() {
  local file="$1"
  [ -e "$file" ] || return 0
  local mtime
  mtime="$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null || true)"
  printf '%s' "$mtime"
}

# Convert an mtime epoch into a "Nd" / "Nh" / "Nm" age string, relative to now.
# Empty input -> "?".
_status_age_short() {
  local mtime="$1"
  if [ -z "$mtime" ]; then
    printf '?'
    return 0
  fi
  local now elapsed days hours minutes
  now="$(date +%s)"
  elapsed=$((now - mtime))
  if [ "$elapsed" -lt 0 ]; then
    elapsed=0
  fi
  days=$((elapsed / 86400))
  if [ "$days" -ge 1 ]; then
    printf '%dd' "$days"
    return 0
  fi
  hours=$((elapsed / 3600))
  if [ "$hours" -ge 1 ]; then
    printf '%dh' "$hours"
    return 0
  fi
  minutes=$((elapsed / 60))
  if [ "$minutes" -ge 1 ]; then
    printf '%dm' "$minutes"
    return 0
  fi
  printf '<1m'
}

# Long-form age "N days ago (YYYY-MM-DD HH:MM)" for the single-project block.
_status_age_long() {
  local mtime="$1"
  if [ -z "$mtime" ]; then
    printf 'unknown'
    return 0
  fi
  local now elapsed days human stamp
  now="$(date +%s)"
  elapsed=$((now - mtime))
  if [ "$elapsed" -lt 0 ]; then
    elapsed=0
  fi
  days=$((elapsed / 86400))
  if [ "$days" -le 0 ]; then
    if [ "$elapsed" -lt 60 ]; then
      human="just now"
    elif [ "$elapsed" -lt 3600 ]; then
      human="$((elapsed / 60)) minutes ago"
    else
      human="$((elapsed / 3600)) hours ago"
    fi
  elif [ "$days" -eq 1 ]; then
    human="1 day ago"
  else
    human="$days days ago"
  fi
  # `date -r` (BSD/macOS) takes an epoch; `date -d @epoch` is GNU. Try both.
  stamp="$(date -r "$mtime" '+%Y-%m-%d %H:%M' 2>/dev/null \
        || date -d "@$mtime" '+%Y-%m-%d %H:%M' 2>/dev/null \
        || echo '')"
  if [ -n "$stamp" ]; then
    printf '%s (%s)' "$human" "$stamp"
  else
    printf '%s' "$human"
  fi
}

# --- color picking -----------------------------------------------------------
# Map a behind-count to a color from lib/colors.sh. Inputs:
#   "current"  -> GREEN
#   1..3       -> YELLOW
#   4..        -> RED
#   "?"        -> RED (unknown is treated as a problem, not a neutral)
# RED/GREEN/YELLOW/RESET are empty strings when stdout isn't a tty
# (lib/colors.sh handles that), so this function works in pipes too.
_status_behind_color() {
  local behind="$1"
  case "$behind" in
    current) printf '%s' "$GREEN" ;;
    \?)      printf '%s' "$RED" ;;
    *)
      # Numeric: 1..3 yellow, 4+ red.
      if [ "$behind" -ge 4 ] 2>/dev/null; then
        printf '%s' "$RED"
      else
        printf '%s' "$YELLOW"
      fi
      ;;
  esac
}

# Stale-age coloring for the AGE column in --all. Threshold is 30 days, named
# here so future tweaks don't have to chase a magic number around the file.
STATUS_STALE_AGE_DAYS=30
_status_age_color() {
  local mtime="$1"
  if [ -z "$mtime" ]; then
    printf '%s' "$RED"
    return 0
  fi
  local now elapsed days
  now="$(date +%s)"
  elapsed=$((now - mtime))
  days=$((elapsed / 86400))
  if [ "$days" -ge "$STATUS_STALE_AGE_DAYS" ]; then
    printf '%s' "$RED"
  else
    printf '%s' ""
  fi
}

# --- single-project block ----------------------------------------------------
# Print the block for `touchstone status` (no flags). Caller passes the project
# directory (typically $(pwd)). Returns 1 when the directory has no manifest,
# so the CLI can exit nonzero per spec.
status_print_project() {
  local project_dir="$1"
  if [ ! -f "$project_dir/.touchstone-version" ]; then
    printf 'not a touchstone project\n'
    return 1
  fi

  local recorded current_id current_version behind mtime age_long display_recorded display_current
  recorded="$(_status_read_project_version "$project_dir")"
  current_id="$(touchstone_current_id)"
  current_version="$(touchstone_version_str)"
  behind="$(_status_behind_count "$recorded" "$current_id")"
  mtime="$(_status_file_mtime "$project_dir/.touchstone-version")"
  age_long="$(_status_age_long "$mtime")"
  display_recorded="$(_status_display_id "$recorded")"
  display_current="$(_status_display_id "$current_id")"

  # "latest" line: if the project's recorded id matches the touchstone HEAD,
  # tag it "(current)"; otherwise show how far behind it is.
  local latest_suffix
  case "$behind" in
    current) latest_suffix='(current)' ;;
    \?)      latest_suffix='(unknown — recorded id not in touchstone history)' ;;
    *)       latest_suffix="(${behind} commits behind)" ;;
  esac

  # Prefer the human-readable VERSION ("2.3.4") for the "latest" label when
  # available; the CURRENT_SHA the project records is opaque to humans.
  local latest_label="$current_version"
  [ -z "$latest_label" ] && latest_label="$display_current"

  printf 'project:        %s\n' "$project_dir"
  printf 'touchstone:     %s\n' "$display_recorded"
  printf 'latest:         %s %s\n' "$latest_label" "$latest_suffix"
  printf 'last update:    %s\n' "$age_long"
}

# --- registry walker ---------------------------------------------------------
# Iterate the registry and invoke a callback for each project line. The
# callback gets ($project_dir) and is responsible for output + tallying.
# Skips empty lines and "#"-prefixed comments to match every other registry
# reader in the codebase.
_status_iter_registry() {
  local cb="$1"
  local projects_file
  projects_file="$(_status_projects_file)"
  if [ ! -f "$projects_file" ] || [ ! -s "$projects_file" ]; then
    return 1
  fi
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    # Trim leading + trailing whitespace before the empty/comment check —
    # otherwise a "   " line in the registry falls through to the callback
    # and renders as "(missing)" because $project_dir doesn't exist.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    "$cb" "$line"
  done < "$projects_file"
  return 0
}

# Truncate a string to N visible columns, preserving the tail (most informative
# for paths — the basename matters; the leading directory components don't).
# Adds a leading "…" when cut. Keeps the table readable in a 100-column
# terminal even when a project path is long, and keeps the basename visible
# so tests and humans can both identify which project is which.
_status_truncate() {
  local s="$1" max="$2"
  if [ "${#s}" -le "$max" ]; then
    printf '%s' "$s"
  else
    # Reserve 1 column for the ellipsis; keep the rightmost (max-1) chars.
    local keep=$((max - 1))
    printf '…%s' "${s: -keep}"
  fi
}

# Replace $HOME prefix with "~" for compact display. The literal "~" in the
# printf format is intentional — we're rendering it as text, not asking the
# shell to expand it (shellcheck SC2088 fires on the tilde-in-quotes pattern
# precisely because most callers want expansion; here we don't).
_status_tildefy() {
  local p="$1"
  if [ -n "${HOME:-}" ] && [ "${p#"$HOME"/}" != "$p" ]; then
    # shellcheck disable=SC2088  # literal tilde for display, not expansion
    printf '~/%s' "${p#"$HOME"/}"
  elif [ "$p" = "$HOME" ]; then
    # shellcheck disable=SC2088  # literal tilde for display, not expansion
    printf '~'
  else
    printf '%s' "$p"
  fi
}

# Column widths for the --all table. Tuned so a typical entry fits in ~80
# columns; the project column expands to 30 visible chars with truncation.
STATUS_COL_PROJECT=30
STATUS_COL_VERSION=12
STATUS_COL_BEHIND=8
STATUS_COL_AGE=6

# Row renderer. Stateful — bumps the four counters defined by status_print_all
# via dynamic-scope inheritance (matching how cmd_doctor_project handles
# `issues` in bin/touchstone). Every code path here updates exactly one
# tally, so the totals always sum to the total row count.
_status_render_row() {
  local project_dir="$1"
  local display_path
  display_path="$(_status_tildefy "$project_dir")"
  local proj_col
  proj_col="$(_status_truncate "$display_path" "$STATUS_COL_PROJECT")"

  local version_col behind_col age_col behind_color age_color row_color reset_inline
  reset_inline="$RESET"

  if [ ! -d "$project_dir" ]; then
    version_col='(missing)'
    behind_col='?'
    age_col='?'
    row_color="$RED"
    total_missing=$((total_missing + 1))
  elif [ ! -f "$project_dir/.touchstone-version" ]; then
    version_col='(no manifest)'
    behind_col='?'
    age_col='?'
    row_color="$RED"
    total_missing=$((total_missing + 1))
  else
    local recorded behind mtime
    recorded="$(_status_read_project_version "$project_dir")"
    if [ -z "$recorded" ]; then
      recorded='(empty)'
      behind='?'
    else
      behind="$(_status_behind_count "$recorded" "$status_current_id")"
    fi
    version_col="$(_status_display_id "$recorded")"
    behind_col="$behind"
    mtime="$(_status_file_mtime "$project_dir/.touchstone-version")"
    age_col="$(_status_age_short "$mtime")"
    behind_color="$(_status_behind_color "$behind")"
    age_color="$(_status_age_color "$mtime")"
    if [ "$behind" = "current" ]; then
      total_current=$((total_current + 1))
    else
      total_behind=$((total_behind + 1))
    fi
    # Row color is the more concerning of behind/age. RED beats YELLOW beats
    # green/none. We compose by checking from most-severe down.
    if [ "$behind_color" = "$RED" ] || [ "$age_color" = "$RED" ]; then
      row_color="$RED"
    elif [ "$behind_color" = "$YELLOW" ]; then
      row_color="$YELLOW"
    else
      row_color="$GREEN"
    fi
  fi

  total_rows=$((total_rows + 1))

  # printf %-Ns pads to N visible chars; ANSI escapes don't count toward
  # printf's width, which is why we wrap the whole row in one color pair
  # instead of coloring each cell. Width math stays right.
  printf "${row_color}%-${STATUS_COL_PROJECT}s  %-${STATUS_COL_VERSION}s  %-${STATUS_COL_BEHIND}s  %-${STATUS_COL_AGE}s${reset_inline}\n" \
    "$proj_col" "$version_col" "$behind_col" "$age_col"
}

# Render the --all view. Returns 0 on success (including the empty-registry
# case, per spec).
status_print_all() {
  local projects_file
  projects_file="$(_status_projects_file)"
  if [ ! -f "$projects_file" ] || [ ! -s "$projects_file" ]; then
    printf 'no registered projects\n'
    return 0
  fi

  # Cache touchstone HEAD once for the whole walk — every row reuses it.
  local status_current_id
  status_current_id="$(touchstone_current_id)"

  # Tallies for the footer. Updated by _status_render_row through dynamic scope.
  local total_rows=0 total_current=0 total_behind=0 total_missing=0

  # Header row (uncolored, plain).
  printf "${BOLD}%-${STATUS_COL_PROJECT}s  %-${STATUS_COL_VERSION}s  %-${STATUS_COL_BEHIND}s  %-${STATUS_COL_AGE}s${RESET}\n" \
    "PROJECT" "VERSION" "BEHIND" "AGE"

  _status_iter_registry _status_render_row || true

  printf '\n%d projects total, %d current, %d behind, %d missing\n' \
    "$total_rows" "$total_current" "$total_behind" "$total_missing"
}
