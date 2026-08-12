#!/usr/bin/env bash
#
# lib/issue-tracker.sh — which tracker holds this project's issues, and what a
# reference to one of them looks like.
#
# The discipline is tracker-neutral: claim before implementing, reconcile
# before opening the PR, close what you fixed. Only the transport differs, so
# the transport is declared once per project, in .touchstone-review.toml:
#
#   [issues]
#   tracker = "linear"     # "github" (default) | "linear"
#   key_prefix = "CON"     # linear only; restricts refs to one team's keys
#
# A project that declares nothing is a GitHub project — the behavior every
# project had before this file existed.
#
# Public surface:
#   issue_tracker_load <dir> [<dir>...]
#       First directory holding .touchstone-review.toml (or the legacy
#       .codex-review.toml) wins; callers pass the script's own project root
#       first so a CI checkout reads policy from the trusted base, not from a
#       PR-controlled tree. Sets ISSUE_TRACKER, ISSUE_TRACKER_KEY_PREFIX and
#       ISSUE_TRACKER_CONFIG; returns non-zero with a remedy on stderr for a
#       declaration this file cannot honor.
#   issue_tracker_normalize_ref <ref>  canonical reference, or non-zero
#   issue_tracker_ref_regex            ERE matching one bare reference in prose
#   issue_tracker_ref_hint             the form a reference must take
#   issue_tracker_closing_ref <ref>    the line that closes <ref> on merge
#   issue_tracker_closing_example      a closing reference an agent can copy
#   issue_tracker_has_claim_transport  0 iff a script can perform the claim

# Guard: only define once per shell.
if [ -n "${TOUCHSTONE_ISSUE_TRACKER_SOURCED:-}" ]; then return 0; fi
TOUCHSTONE_ISSUE_TRACKER_SOURCED=1

_TOUCHSTONE_ISSUE_TRACKER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v toml_parse >/dev/null 2>&1; then
  # shellcheck source=toml.sh
  source "$_TOUCHSTONE_ISSUE_TRACKER_LIB_DIR/toml.sh"
fi

ISSUE_TRACKER="github"
ISSUE_TRACKER_KEY_PREFIX=""
ISSUE_TRACKER_CONFIG=""
_ISSUE_TRACKER_RAW=""
_ISSUE_TRACKER_KEY_PREFIX_RAW=""

# shellcheck disable=SC2329  # invoked by toml_parse as a callback.
_issue_tracker_collect() {
  local section="$1" key="$2" value="$3"
  [ "$section" = "issues" ] || return 0
  case "$key" in
    tracker) _ISSUE_TRACKER_RAW="$value" ;;
    key_prefix) _ISSUE_TRACKER_KEY_PREFIX_RAW="$value" ;;
  esac
}

issue_tracker_load() {
  local dir candidate

  ISSUE_TRACKER="github"
  ISSUE_TRACKER_KEY_PREFIX=""
  ISSUE_TRACKER_CONFIG=""
  _ISSUE_TRACKER_RAW=""
  _ISSUE_TRACKER_KEY_PREFIX_RAW=""

  for dir in "$@"; do
    [ -n "$dir" ] || continue
    for candidate in .touchstone-review.toml .codex-review.toml; do
      if [ -f "$dir/$candidate" ]; then
        ISSUE_TRACKER_CONFIG="$dir/$candidate"
        break 2
      fi
    done
  done

  # No policy file at all is the pre-declaration state, not an error: those
  # projects are GitHub projects and must keep behaving as one.
  [ -n "$ISSUE_TRACKER_CONFIG" ] || return 0

  toml_parse "$ISSUE_TRACKER_CONFIG" _issue_tracker_collect

  if [ -n "$_ISSUE_TRACKER_RAW" ]; then
    case "$_ISSUE_TRACKER_RAW" in
      github | linear) ISSUE_TRACKER="$_ISSUE_TRACKER_RAW" ;;
      *)
        echo "ERROR: unknown issue tracker '$_ISSUE_TRACKER_RAW' in $ISSUE_TRACKER_CONFIG." >&2
        echo "       Set [issues].tracker = \"github\" or [issues].tracker = \"linear\" in $ISSUE_TRACKER_CONFIG." >&2
        return 1
        ;;
    esac
  fi

  if [ -n "$_ISSUE_TRACKER_KEY_PREFIX_RAW" ]; then
    # A prefix under GitHub would silently do nothing; say so rather than
    # letting the project believe its references are constrained.
    if [ "$ISSUE_TRACKER" != "linear" ]; then
      echo "ERROR: [issues].key_prefix applies to the linear tracker only, but $ISSUE_TRACKER_CONFIG declares tracker \"$ISSUE_TRACKER\"." >&2
      echo "       Remove key_prefix from $ISSUE_TRACKER_CONFIG, or set [issues].tracker = \"linear\" there." >&2
      return 1
    fi
    # Letters and digits only: the prefix is interpolated into the extended
    # regular expressions below and in scripts/issue-claim-check.sh.
    if ! printf '%s' "$_ISSUE_TRACKER_KEY_PREFIX_RAW" | grep -qE '^[A-Za-z][A-Za-z0-9]*$'; then
      echo "ERROR: [issues].key_prefix '$_ISSUE_TRACKER_KEY_PREFIX_RAW' in $ISSUE_TRACKER_CONFIG is not a Linear team key." >&2
      echo "       Set key_prefix = \"CON\" (letters and digits, starting with a letter) in $ISSUE_TRACKER_CONFIG." >&2
      return 1
    fi
    ISSUE_TRACKER_KEY_PREFIX="$(printf '%s' "$_ISSUE_TRACKER_KEY_PREFIX_RAW" | tr '[:lower:]' '[:upper:]')"
  fi
}

issue_tracker_ref_regex() {
  case "$ISSUE_TRACKER" in
    linear)
      if [ -n "$ISSUE_TRACKER_KEY_PREFIX" ]; then
        printf '%s-[0-9]+' "$ISSUE_TRACKER_KEY_PREFIX"
      else
        printf '[A-Za-z][A-Za-z0-9]*-[0-9]+'
      fi
      ;;
    *) printf '#[0-9]+' ;;
  esac
}

# Canonical form on stdout; non-zero when the reference does not belong to the
# declared tracker. `#12` under Linear and `CON-12` under GitHub are both
# refusals, so an agent carrying the wrong tracker's habit is told once,
# before any work starts, instead of claiming nothing.
issue_tracker_normalize_ref() {
  local ref="$1"
  case "$ISSUE_TRACKER" in
    linear)
      printf '%s' "$ref" | grep -qE "^$(issue_tracker_ref_regex)$" || return 1
      printf '%s' "$ref" | tr '[:lower:]' '[:upper:]'
      ;;
    *)
      ref="${ref#\#}"
      printf '%s' "$ref" | grep -qE '^[0-9]+$' || return 1
      printf '%s' "$ref"
      ;;
  esac
}

issue_tracker_ref_hint() {
  case "$ISSUE_TRACKER" in
    linear) printf 'a Linear issue key like %s-123' "${ISSUE_TRACKER_KEY_PREFIX:-CON}" ;;
    *) printf 'a GitHub issue number like 123 or #123' ;;
  esac
}

# The line that closes <ref> when the PR merges, in the declared tracker's
# syntax. Callers render remedies with it so no message hardcodes `#N`.
issue_tracker_closing_ref() {
  local ref="$1"
  case "$ISSUE_TRACKER" in
    linear) printf 'Fixes %s' "$ref" ;;
    *) printf 'Closes-issue: #%s' "${ref#\#}" ;;
  esac
}

issue_tracker_closing_example() {
  case "$ISSUE_TRACKER" in
    linear) issue_tracker_closing_ref "${ISSUE_TRACKER_KEY_PREFIX:-CON}-123" ;;
    *) issue_tracker_closing_ref 123 ;;
  esac
}

issue_tracker_has_claim_transport() {
  [ "$ISSUE_TRACKER" = "github" ]
}
