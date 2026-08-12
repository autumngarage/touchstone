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
#   issue_tracker_github_closing_refs [<owner/repo>]
#       reads text on stdin, prints every GitHub closing reference in it that
#       would close an issue in <owner/repo> — the grammar both wrong-tracker
#       guards judge, so the commit-message channel and the PR-body channel
#       refuse the same thing

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
_ISSUE_TRACKER_DECLARED=0
_ISSUE_TRACKER_KEY_PREFIX_DECLARED=0

# shellcheck disable=SC2329  # invoked by toml_parse as a callback.
_issue_tracker_collect() {
  local section="$1" key="$2" value="$3"
  [ "$section" = "issues" ] || return 0
  case "$key" in
    tracker)
      _ISSUE_TRACKER_RAW="$value"
      _ISSUE_TRACKER_DECLARED=1
      ;;
    key_prefix)
      _ISSUE_TRACKER_KEY_PREFIX_RAW="$value"
      _ISSUE_TRACKER_KEY_PREFIX_DECLARED=1
      ;;
  esac
}

# A policy file this loader cannot READ is not a policy file that says
# "github". lib/toml.sh skips every line it does not understand, so a header
# typed as `[issues` (no closing bracket) parses as nothing at all: the header
# is ignored, the `tracker = "linear"` below it is attributed to the empty
# section, the callback drops it, and the load would return success with the
# GitHub default — silently retracking a Linear project, closing-reference
# injection included (#743 review). Refuse the file instead, naming the line,
# so a typo fails closed rather than changing which tracker a project has.
#
# The same silence swallows a malformed ASSIGNMENT, which is why this walk
# also judges the lines inside [issues]: `tracker "linear"` (no `=`) is not a
# key/value pair to lib/toml.sh, so the callback is never invoked, the load
# succeeds, and ISSUE_TRACKER stays "github" — the identical retrack, one
# character further along (#743 review round 4). Only [issues] is judged:
# other sections belong to other readers, which are free to accept TOML this
# subset parser skips.
_issue_tracker_validate_syntax() {
  local config_file="$1"
  local raw_line line header key value
  local section=""
  local lineno=0
  local in_array=false

  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    lineno=$((lineno + 1))
    line="$(toml_trim "$(toml_strip_comment "$raw_line")")"
    [ -n "$line" ] || continue

    # Section headers are tested first, exactly as toml_parse orders it, so a
    # bracketed line is read the same way here and there.
    case "$line" in
      \[*)
        case "$line" in
          *\]) ;;
          *)
            echo "ERROR: unclosed section header at $config_file:$lineno: $line" >&2
            echo "       A section header must be bracketed, as in [issues]. Until it is, this file" >&2
            echo "       declares nothing, and Touchstone will not read that as a GitHub project." >&2
            return 1
            ;;
        esac
        header="${line#\[}"
        header="${header%\]}"
        header="$(toml_trim "$header")"
        if [ -z "$header" ]; then
          echo "ERROR: empty section header at $config_file:$lineno: $line" >&2
          echo "       Name the section, as in [issues], or delete the line." >&2
          return 1
        fi
        section="$header"
        in_array=false
        continue
        ;;
    esac

    [ "$section" = "issues" ] || continue

    # A wrapped array's continuation lines carry no `=` and are not
    # assignments; toml_parse consumes them as array content, so mirror its
    # state machine rather than refusing valid TOML.
    if [ "$in_array" = true ]; then
      if toml_array_content_before_close "$line" >/dev/null; then
        in_array=false
      fi
      continue
    fi

    key=""
    case "$line" in
      *=*) key="$(toml_trim "${line%%=*}")" ;;
    esac
    if [ -z "$key" ]; then
      echo "ERROR: unreadable line in [issues] at $config_file:$lineno: $line" >&2
      echo "       Every line in [issues] must be a key = value assignment, as in" >&2
      echo "       tracker = \"linear\". lib/toml.sh reports nothing for this line, so whatever" >&2
      echo "       it was meant to declare never arrives — and a tracker Touchstone cannot" >&2
      echo "       read is not the GitHub default." >&2
      return 1
    fi

    value="$(toml_trim "${line#*=}")"
    case "$value" in
      \[*)
        if ! toml_array_content_before_close "${value#\[}" >/dev/null; then
          in_array=true
        fi
        ;;
    esac
  done <"$config_file"
}

issue_tracker_load() {
  local dir candidate

  ISSUE_TRACKER="github"
  ISSUE_TRACKER_KEY_PREFIX=""
  ISSUE_TRACKER_CONFIG=""
  _ISSUE_TRACKER_RAW=""
  _ISSUE_TRACKER_KEY_PREFIX_RAW=""
  _ISSUE_TRACKER_DECLARED=0
  _ISSUE_TRACKER_KEY_PREFIX_DECLARED=0

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

  if ! _issue_tracker_validate_syntax "$ISSUE_TRACKER_CONFIG"; then
    return 1
  fi

  if ! toml_parse "$ISSUE_TRACKER_CONFIG" _issue_tracker_collect; then
    echo "ERROR: failed to parse $ISSUE_TRACKER_CONFIG." >&2
    echo "       Touchstone cannot resolve this project's issue tracker from an unreadable" >&2
    echo "       policy file, and will not fall back to the GitHub default." >&2
    return 1
  fi

  if [ "$_ISSUE_TRACKER_DECLARED" = 1 ] && [ -z "$_ISSUE_TRACKER_RAW" ]; then
    echo "ERROR: [issues].tracker is declared empty in $ISSUE_TRACKER_CONFIG." >&2
    echo "       Set [issues].tracker = \"github\" or [issues].tracker = \"linear\" there, or" >&2
    echo "       remove the key — an empty declaration is not the GitHub default." >&2
    return 1
  fi

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

  if [ "$_ISSUE_TRACKER_KEY_PREFIX_DECLARED" = 1 ]; then
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
      # Canonicalize BEFORE validating. `con-42` is the same issue as `CON-42`
      # — it is what branch names and copied references look like — and
      # scripts/issue-claim-check.sh already extracts closing references
      # case-insensitively. Validating the raw input first refused here what
      # the claim checker accepts there (#743 review), which is one grammar
      # described two ways.
      ref="$(printf '%s' "$ref" | tr '[:lower:]' '[:upper:]')"
      grep -qE "^$(issue_tracker_ref_regex)$" <<<"$ref" || return 1
      printf '%s' "$ref"
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

# GitHub's own closing grammar: its nine closing keywords, plus Touchstone's
# `Closes-issue:` trailer, which scripts/open-pr.sh renders into the PR body
# as `Closes #N`. GitHub acts on these whatever a project declares, which is
# what makes them refusable under another tracker.
ISSUE_TRACKER_GITHUB_CLOSING_KEYWORDS='(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved|closes-issue)'
# The owner/repo prefix GitHub allows in front of the `#N`. Matched, not
# ignored, so that a qualified reference can be JUDGED rather than silently
# treated as unqualified.
ISSUE_TRACKER_GITHUB_REPO_PATTERN='[[:alnum:]_.-]+/[[:alnum:]_.-]+'

# Every closing reference on stdin that would close an issue in <owner/repo>,
# one per line, deduplicated, in the text that carried it.
#
# GitHub reads this grammar from two places on the way to a merge — the PR
# body, and the squash commit message `gh pr merge --squash` builds out of the
# branch's commits — so both guards apply it here instead of each keeping its
# own idea of what a merge would close.
#
# `owner/repo#N` closes an issue in THAT repository, not this one, so it is
# not a same-repo closing reference and is not reported — the exemption
# extract_github_issue_refs in scripts/issue-claim-check.sh has always made,
# now made once for both callers (#743 review round 4). A caller that cannot
# resolve the current repository passes an empty <owner/repo> and gets
# qualified references reported: unknown is not "someone else's".
issue_tracker_github_closing_refs() {
  local current_repo match normalized target_repo matches
  current_repo="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"

  # stdin is consumed whole before any filtering. `grep -Eo ... | while read`
  # would put a producer in a pipeline whose status this function returns, and
  # every caller reads it through command substitution under `set -e`.
  matches="$(grep -Eoi "\\b${ISSUE_TRACKER_GITHUB_CLOSING_KEYWORDS}:?[[:space:]]*(${ISSUE_TRACKER_GITHUB_REPO_PATTERN})?#[0-9]+\\b" || true)"
  [ -n "$matches" ] || return 0

  while IFS= read -r match; do
    [ -n "$match" ] || continue
    normalized="$(printf '%s' "$match" | tr '[:upper:]' '[:lower:]')"
    # `,` delimits the substitution: the keyword alternation contains `|` and
    # the repo pattern contains `/`, so neither of the usual delimiters is
    # available here.
    target_repo="$(sed -nE "s,^${ISSUE_TRACKER_GITHUB_CLOSING_KEYWORDS}:?[[:space:]]*(${ISSUE_TRACKER_GITHUB_REPO_PATTERN})#[0-9]+\$,\\2,p" <<<"$normalized")"
    if [ -n "$target_repo" ] && [ -n "$current_repo" ] && [ "$target_repo" != "$current_repo" ]; then
      continue
    fi
    printf '%s\n' "$match"
  done <<<"$matches" | sort -u
}
