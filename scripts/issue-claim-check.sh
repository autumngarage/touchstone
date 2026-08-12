#!/usr/bin/env bash
#
# scripts/issue-claim-check.sh — enforce claim-before-dispatch locally and in CI.
#
# Usage:
#   bash scripts/issue-claim-check.sh --body-file <file> [--author <login>]
#   bash scripts/issue-claim-check.sh --pr-number <number> [--comment-pr]
#
# Ownership is only verifiable where Touchstone speaks the tracker's API. The
# GitHub adapter enforces; other trackers report the references they found and
# name what a human must confirm, so a Linear project keeps the discipline
# without this check failing every PR it cannot judge.
#
# Unverifiable is not the same as unenforced. GitHub's own closing syntax is
# refused under any other tracker, because GitHub acts on it whatever the
# project declares — that reference is verifiably wrong, not merely
# unreadable.
#
# Exit codes are a contract every caller branches on — scripts/open-pr.sh,
# scripts/merge-pr.sh's trusted-base substitution, and the CI workflow — and
# they cross revisions (merge-pr runs the BASE revision of this file), so
# treat them as a wire format:
#
#   0  verified: every open referenced issue is assigned to the PR author,
#      or there was nothing to enforce, or the documented [skip-claim-check]
#      bypass was honored.
#   1  refuted: a referenced open issue is not assigned to the PR author, or
#      the body carries a closing reference in a tracker's syntax this
#      project does not use — GitHub would act on it anyway.
#   2  usage or environment error, including a tracker declaration this
#      Touchstone cannot honor.
#   3  UNVERIFIABLE: closing references were found, but this project's
#      tracker has no verification transport, so nothing was checked. It is
#      not a pass; a caller that maps it to green must say so out loud.
#
set -euo pipefail

# Wire contract above. Named here so the branch that returns it reads as the
# documented state and not as a bare number.
ISSUE_CLAIM_CHECK_UNVERIFIABLE_RC=3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUE_TRACKER_LIB="$SCRIPT_DIR/../lib/issue-tracker.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  bash scripts/issue-claim-check.sh --body-file <file> [--author <login>]
  bash scripts/issue-claim-check.sh --pr-number <number> [--comment-pr]
EOF
}

require_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI is required for issue claim checks." >&2
    exit 2
  fi
}

resolve_current_repo() {
  if [ -n "${GH_REPO:-}" ]; then
    printf '%s\n' "$GH_REPO"
    return 0
  fi

  gh repo view --json nameWithOwner --jq '.nameWithOwner // empty' 2>/dev/null || true
}

resolve_repo_context() {
  local resolved repo_url repo_host server_url
  resolved="$(resolve_current_repo)"
  current_repo=""
  current_host=""
  case "$resolved" in
    */*/*)
      current_host="${resolved%%/*}"
      current_repo="${resolved#*/}"
      ;;
    */*)
      current_repo="$resolved"
      ;;
    *) return 1 ;;
  esac

  if [ -z "$current_host" ] && [ -n "${GH_HOST:-}" ]; then
    current_host="$GH_HOST"
  fi
  if [ -z "$current_host" ] && [ -n "${GITHUB_SERVER_URL:-}" ]; then
    server_url="$GITHUB_SERVER_URL"
    case "$server_url" in
      http://* | https://*)
        current_host="${server_url#*://}"
        current_host="${current_host%%/*}"
        ;;
    esac
  fi
  if [ -z "$current_host" ]; then
    repo_url="$(gh repo view --json url --jq '.url // empty' 2>/dev/null || true)"
    case "$repo_url" in
      http://* | https://*)
        repo_host="${repo_url#*://}"
        repo_host="${repo_host%%/*}"
        if [ "$repo_host" != "github.com" ]; then
          current_host="$repo_host"
        fi
        ;;
    esac
  fi
}

repo_api() {
  local endpoint="$1"
  shift
  if [ -n "$current_host" ]; then
    gh api --hostname "$current_host" "repos/$current_repo/$endpoint" "$@"
  else
    gh api "repos/$current_repo/$endpoint" "$@"
  fi
}

resolved_repo_name() {
  local resolved
  resolved="$(resolve_current_repo)"
  case "$resolved" in
    */*/*) resolved="${resolved#*/}" ;;
    */*) ;;
    *) return 1 ;;
  esac
  printf '%s' "$resolved" | tr '[:upper:]' '[:lower:]'
}

# GitHub adapter: same-repo `#N` refs behind a closing keyword, cross-repo
# refs skipped.
extract_github_issue_refs() {
  local body_file="$1"
  local refs_file="$2"
  local match normalized issue_number target_repo comparison_repo
  local closing_keywords="(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)"

  comparison_repo="$(resolved_repo_name 2>/dev/null || true)"

  # Pattern 1: same-repo numeric refs including closes-issue.
  while IFS= read -r match; do
    issue_number="$(printf '%s' "$match" | sed -E 's/.*#([0-9]+).*/\1/')"
    if [ -n "$issue_number" ]; then
      printf '%s\n' "$issue_number" >>"$refs_file"
    fi
  done < <(grep -Eoi "\\b(${closing_keywords}|closes-issue):?[[:space:]]*#[0-9]+\\b" "$body_file" || true)

  # Pattern 2: GitHub closing keywords with optional owner/repo prefix.
  while IFS= read -r match; do
    normalized="$(printf '%s' "$match" | tr '[:upper:]' '[:lower:]')"
    target_repo="$(printf '%s' "$normalized" | sed -nE "s/^${closing_keywords}:?[[:space:]]*([[:alnum:]_.-]+\/[[:alnum:]_.-]+)#[0-9]+$/\\2/p")"
    if [ -n "$target_repo" ] && [ -n "$comparison_repo" ] && [ "$target_repo" != "$comparison_repo" ]; then
      echo "==> Skipping cross-repo reference: $match"
      continue
    fi
    issue_number="$(printf '%s' "$match" | sed -E 's/.*#([0-9]+).*/\1/')"
    if [ -n "$issue_number" ]; then
      printf '%s\n' "$issue_number" >>"$refs_file"
    fi
  done < <(grep -Eoi "\\b${closing_keywords}:?[[:space:]]*([[:alnum:]_.-]+/[[:alnum:]_.-]+)?#[0-9]+\\b" "$body_file" || true)
}

# Non-GitHub adapter: closing keyword plus one reference in the declared
# tracker's grammar, upper-cased so CON-7 and con-7 are one issue. The grammar
# is interpolated into these patterns, so issue_tracker_load must keep
# key_prefix free of regex metacharacters.
extract_tracker_issue_refs() {
  local body_file="$1"
  local refs_file="$2"
  local match ref
  local closing_keywords="(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)"

  while IFS= read -r match; do
    ref="$(printf '%s' "$match" | grep -Eoi "$(issue_tracker_ref_regex)\$" || true)"
    [ -n "$ref" ] || continue
    printf '%s\n' "$ref" | tr '[:lower:]' '[:upper:]' >>"$refs_file"
  done < <(grep -Eoi "\\b${closing_keywords}:?[[:space:]]*$(issue_tracker_ref_regex)\\b" "$body_file" || true)
}

extract_issue_refs() {
  if [ "$ISSUE_TRACKER" = "github" ]; then
    extract_github_issue_refs "$@"
    return 0
  fi
  extract_tracker_issue_refs "$@"
}

# Every closing reference GitHub itself acts on, whatever this project
# declares: its nine closing keywords with an optional owner/repo prefix, plus
# Touchstone's own `Closes-issue:` trailer, which scripts/open-pr.sh renders
# as `Closes #N`. Under a non-GitHub tracker these are not "no reference
# found" — they are a merge that closes a GitHub issue the project does not
# track.
github_closing_refs_in() {
  local body_file="$1"
  local closing_keywords="(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved|closes-issue)"

  grep -Eoi "\\b${closing_keywords}:?[[:space:]]*([[:alnum:]_.-]+/[[:alnum:]_.-]+)?#[0-9]+\\b" \
    "$body_file" | sort -u || true
}

format_assignee_label() {
  local assignees="$1"
  if [ -z "$assignees" ]; then
    printf '(none)'
    return 0
  fi
  printf '%s\n' "$assignees" | awk '
    NF {
      if (out == "") {
        out = $0
      } else {
        out = out ", " $0
      }
    }
    END {
      if (out != "") {
        printf "%s", out
      }
    }
  '
}

write_failure_report() {
  local failures_file="$1"
  local pr_author="$2"
  local mode="$3"
  local issue_number assignees

  if [ "$mode" = "markdown" ]; then
    echo "Issue claim check failed"
    echo ""
    echo "This PR references issue(s) with closing keywords, but the PR author (@$pr_author) is not assigned to all open referenced issues:"
    echo ""
    while IFS='|' read -r issue_number assignees; do
      [ -n "$issue_number" ] || continue
      echo "- #$issue_number - current assignees: $assignees"
    done <"$failures_file"
    echo ""
    echo "### Remediation"
    echo "1. Claim each open referenced issue before dispatch:"
    # shellcheck disable=SC2016  # backticks are intentional Markdown.
    echo '   - `bash scripts/claim-issue.sh <issue-number>`'
    echo "2. Keep the closing keyword in this PR body once claimed, then push any update if needed."
    echo ""
    # shellcheck disable=SC2016  # backticks are intentional Markdown.
    echo 'If this is a legitimate exception (drive-by fix, emergency PR), add `[skip-claim-check]` to the PR body as a documented bypass.'
    return 0
  fi

  echo "ERROR: Issue claim check failed." >&2
  echo "This PR references issue(s) with closing keywords, but the PR author (@$pr_author) is not assigned to all open referenced issues:" >&2
  while IFS='|' read -r issue_number assignees; do
    [ -n "$issue_number" ] || continue
    echo "  - #$issue_number - current assignees: $assignees" >&2
  done <"$failures_file"
  echo "" >&2
  echo "Remediation:" >&2
  echo "  bash scripts/claim-issue.sh <issue-number>" >&2
  while IFS='|' read -r issue_number _; do
    [ -n "$issue_number" ] || continue
    echo "  bash scripts/claim-issue.sh $issue_number" >&2
  done <"$failures_file"
  echo "  Or add [skip-claim-check] to the PR body for a documented exception." >&2
}

BODY_FILE=""
PR_NUMBER=""
PR_AUTHOR=""
COMMENT_PR=false
OWNED_BODY_FILE=""
current_repo=""
current_host=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --body-file)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      BODY_FILE="$2"
      shift 2
      ;;
    --pr-number)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      PR_NUMBER="$2"
      shift 2
      ;;
    --author)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      PR_AUTHOR="$2"
      shift 2
      ;;
    --comment-pr)
      COMMENT_PR=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2
      usage
      exit 2
      ;;
  esac
done

if [ -z "$BODY_FILE" ] && [ -z "$PR_NUMBER" ]; then
  usage
  exit 2
fi
if [ -n "$BODY_FILE" ] && [ ! -f "$BODY_FILE" ]; then
  echo "ERROR: PR body file not found: $BODY_FILE" >&2
  exit 2
fi
if [ "$COMMENT_PR" = true ] && [ -z "$PR_NUMBER" ]; then
  echo "ERROR: --comment-pr requires --pr-number." >&2
  exit 2
fi

if [ ! -f "$ISSUE_TRACKER_LIB" ]; then
  echo "ERROR: issue-tracker library not found at $ISSUE_TRACKER_LIB." >&2
  echo "       Run: touchstone update" >&2
  exit 2
fi
# shellcheck source=../lib/issue-tracker.sh
source "$ISSUE_TRACKER_LIB"

# Project root first: in CI this script runs from a checkout of the PR's base,
# so its own root is the trusted policy, and the PR cannot redeclare the
# tracker to dodge the check.
if ! issue_tracker_load "$SCRIPT_DIR/.." "$PWD"; then
  exit 2
fi

# The PR itself always lives on GitHub; only the issues may not. gh is
# required to read a PR body, and to read issues under the GitHub adapter.
if [ "$ISSUE_TRACKER" = "github" ] || [ -n "$PR_NUMBER" ]; then
  require_gh
fi

# shellcheck disable=SC2329  # invoked by EXIT trap.
cleanup() {
  if [ -n "$OWNED_BODY_FILE" ]; then
    rm -f "$OWNED_BODY_FILE"
  fi
}
trap cleanup EXIT

if [ -n "$BODY_FILE" ] && grep -Eqi '\[skip-claim-check\]' "$BODY_FILE"; then
  echo "[skip-claim-check] token found in PR body; bypassing issue claim check."
  exit 0
fi

if [ -n "$PR_NUMBER" ] && [ -z "$BODY_FILE" ]; then
  if ! resolve_repo_context; then
    echo "ERROR: could not resolve current repository for issue claim check." >&2
    exit 2
  fi
  current_repo="$(printf '%s' "$current_repo" | tr '[:upper:]' '[:lower:]')"
  OWNED_BODY_FILE="$(mktemp -t touchstone-claim-body.XXXXXX)"
  BODY_FILE="$OWNED_BODY_FILE"
  repo_api "pulls/$PR_NUMBER" --jq '.body // ""' >"$BODY_FILE"
  if grep -Eqi '\[skip-claim-check\]' "$BODY_FILE"; then
    echo "[skip-claim-check] token found in PR body; bypassing issue claim check."
    exit 0
  fi
fi

issue_refs_file="$(mktemp -t touchstone-claim-refs.XXXXXX)"
failures_file="$(mktemp -t touchstone-claim-failures.XXXXXX)"
comment_file=""
trap 'rm -f "$issue_refs_file" "$failures_file" "$comment_file"; cleanup' EXIT

extract_issue_refs "$BODY_FILE" "$issue_refs_file"

# Refuse another tracker's closing syntax BEFORE either exit below. "No
# closing issue references found" would be literally true here and still
# wrong: this body references nothing in the declared tracker, yet GitHub
# closes the numbered issue on merge regardless. Placed ahead of the
# unverifiable branch too, so a body carrying both grammars is refused rather
# than waved through as merely unverifiable.
if [ "$ISSUE_TRACKER" != "github" ]; then
  foreign_refs="$(github_closing_refs_in "$BODY_FILE")"
  if [ -n "$foreign_refs" ]; then
    echo "ERROR: this PR body closes GitHub issues, but this project's issues live in $ISSUE_TRACKER." >&2
    echo "       GitHub acts on these references whatever the project declares, so merging" >&2
    echo "       would close GitHub issues this project does not track:" >&2
    printf '%s\n' "$foreign_refs" | sed 's/^/         /' >&2
    echo "       Remedy: rewrite each one in $ISSUE_TRACKER syntax, in the PR BODY — for example:" >&2
    echo "         $(issue_tracker_closing_example)" >&2
    echo "       The PR body is the only place a $ISSUE_TRACKER reference is read from; Touchstone" >&2
    echo "       injects nothing for $ISSUE_TRACKER, so a reference left in a commit message" >&2
    echo "       reconciles nothing. Then re-run." >&2
    echo "       Deliberate cross-tracker close? Add [skip-claim-check] to the PR body as a" >&2
    echo "       documented bypass." >&2
    exit 1
  fi
fi

if [ ! -s "$issue_refs_file" ]; then
  echo "No closing issue references found in PR body; nothing to enforce."
  exit 0
fi

# Unverifiable, not passed. With no API for this tracker there is no assignee
# to compare against; blocking every PR outright would teach agents to reach
# for [skip-claim-check], and exiting 0 would report a verification that never
# happened. Exit 3 instead, and let each caller decide — visibly — what an
# unverifiable claim means for it.
if [ "$ISSUE_TRACKER" != "github" ]; then
  echo "==> Tracker '$ISSUE_TRACKER' has no claim-verification transport; assignment is NOT checked here."
  while IFS= read -r tracker_ref; do
    [ -n "$tracker_ref" ] || continue
    echo "    referenced: $tracker_ref"
  done < <(sort -u "$issue_refs_file")
  echo "    Confirm in $ISSUE_TRACKER that each reference above is assigned to you and carries a dispatch comment."
  echo "    Exit $ISSUE_CLAIM_CHECK_UNVERIFIABLE_RC (unverifiable): this check enforced nothing for those references."
  exit "$ISSUE_CLAIM_CHECK_UNVERIFIABLE_RC"
fi

if [ -z "$current_repo" ]; then
  if ! resolve_repo_context; then
    echo "ERROR: could not resolve current repository for issue claim check." >&2
    exit 2
  fi
  current_repo="$(printf '%s' "$current_repo" | tr '[:upper:]' '[:lower:]')"
fi

if [ -n "$PR_NUMBER" ] && [ -z "$PR_AUTHOR" ]; then
  PR_AUTHOR="$(repo_api "pulls/$PR_NUMBER" --jq '.user.login // empty')"
fi
if [ -z "$PR_AUTHOR" ]; then
  PR_AUTHOR="$(gh api user --jq '.login' 2>/dev/null || true)"
fi
if [ -z "$PR_AUTHOR" ]; then
  echo "ERROR: could not resolve PR author for issue claim check." >&2
  exit 2
fi

unique_issues="$(sort -u "$issue_refs_file")"
echo "==> Checking issue ownership for PR author @$PR_AUTHOR"

while IFS= read -r issue_number; do
  [ -n "$issue_number" ] || continue
  echo "==> Checking issue #$issue_number"

  issue_state="$(repo_api "issues/$issue_number" --jq '.state' | tr '[:upper:]' '[:lower:]')"
  if [ "$issue_state" = "closed" ]; then
    echo "    issue is closed; skipping"
    continue
  fi

  assignees="$(repo_api "issues/$issue_number" --jq '.assignees | map(.login) | join("\n")')"
  if printf '%s\n' "$assignees" | grep -Fxq "$PR_AUTHOR"; then
    echo "    pass: @$PR_AUTHOR is assigned"
    continue
  fi

  printf '%s|%s\n' "$issue_number" "$(format_assignee_label "$assignees")" >>"$failures_file"
done <<<"$unique_issues"

if [ ! -s "$failures_file" ]; then
  echo "All referenced issues are claimed by the PR author."
  exit 0
fi

write_failure_report "$failures_file" "$PR_AUTHOR" "terminal"

if [ "$COMMENT_PR" = true ]; then
  comment_file="$(mktemp -t touchstone-claim-comment.XXXXXX)"
  write_failure_report "$failures_file" "$PR_AUTHOR" "markdown" >"$comment_file"
  repo_api "issues/$PR_NUMBER/comments" --method POST -F "body=@$comment_file" >/dev/null
  echo "Issue claim check failed; remediation comment posted to PR #$PR_NUMBER."
fi

exit 1
