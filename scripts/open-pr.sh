#!/usr/bin/env bash
#
# scripts/open-pr.sh — push the current branch and open a PR via gh.
#
# Refuses to run on the default branch. Sets upstream on first push.
# Idempotent: if a PR already exists for this branch it just prints the URL.
# Always uses the project's PR template if one exists.
#
# Usage:
#   bash scripts/open-pr.sh                          # title from last commit; base = default branch
#   bash scripts/open-pr.sh --auto-merge             # open + merge-gate review + squash-merge
#   bash scripts/open-pr.sh --auto-merge \
#                            --cleanup-worktree       # auto-merge, then remove this feature worktree
#   bash scripts/open-pr.sh --draft                  # create/update a review-free draft
#   bash scripts/open-pr.sh --base feat/X            # stacked PR: base this PR on feat/X, not main
#   bash scripts/open-pr.sh "Custom title"           # explicit title
#
# Exit contract (--auto-merge):
#   exit 0 ⇔ GitHub reports the PR state as MERGED or has a populated mergedAt.
#   Any other terminal state exits nonzero AND prints the PR URL with recovery
#   commands as the last lines of output. This prevents the "swarm-agent orphan
#   PR" failure mode where an agent's session ends mid-merge and leaves a
#   reviewed-but-unmerged PR open indefinitely.
#
#   Why local polling instead of `gh pr merge --auto`: Touchstone validates
#   exact-head review evidence and unresolved threads locally before asking
#   GitHub to merge. Keeping the merge in-band lets us positively confirm that
#   authorization before reporting success.
#
# ⚠ Stacked PRs — read this before using --base:
#   Stacking a PR on another PR's branch is useful when work naturally
#   splits into a chain (parent PR ships primitive, child PR ships the
#   consumer that depends on it). GitHub does NOT auto-rebase the child
#   onto main when the parent squash-merges; it closes the child's branch
#   instead. So stacked PRs work well with a merge commit or rebase merge,
#   but the `--auto-merge` default (squash) will orphan the child.
#
#   Prefer independent PRs against the default branch when slices can ship
#   separately; rebase or cherry-pick child-only commits onto the default
#   branch first. Use a stack only when a child truly depends on an unmerged
#   parent. See principles/git-workflow.md.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_SYNC_GUARD="$SCRIPT_DIR/../lib/script-sync-guard.sh"
if [ -f "$SCRIPT_SYNC_GUARD" ]; then
  # shellcheck source=../lib/script-sync-guard.sh
  source "$SCRIPT_SYNC_GUARD"
  touchstone_script_sync_guard "$0" "$@"
fi
PREFLIGHT_SCRIPT="$SCRIPT_DIR/../lib/preflight.sh"
ISSUE_CLAIM_CHECK_SCRIPT="$SCRIPT_DIR/issue-claim-check.sh"
if [ -f "$SCRIPT_DIR/../lib/events.sh" ]; then
  # shellcheck source=../lib/events.sh
  source "$SCRIPT_DIR/../lib/events.sh"
else
  touchstone_emit_event() { :; }
fi
if [ -f "$PREFLIGHT_SCRIPT" ]; then
  # shellcheck source=../lib/preflight.sh
  source "$PREFLIGHT_SCRIPT"
else
  # Fail CLOSED (issue #689 finding 3): an absent preflight module means
  # required validation cannot run; silently skipping it would let a
  # partially-synced or tampered checkout ship without its gates.
  echo "ERROR: lib/preflight.sh is missing; required preflight validation cannot run." >&2
  echo "       Re-sync Touchstone files (touchstone update) before shipping." >&2
  exit 1
fi
# orphan_warning is set to a PR URL once we know one — any nonzero exit after
# that point prints recovery instructions as the script's last output, so the
# user (or future agent) can see exactly which PR is stuck.
ORPHAN_PR_URL=""
ORPHAN_PR_NUMBER=""
BODY_FILE=""
PR_TRIGGERED_REVIEW_REQUEST_ON_PUSH=true
PR_TRIGGERED_REVIEW_PROVIDER="github-codex"
OPEN_PR_REVIEW_CONFIG_ERROR=""
OPEN_PR_REVIEW_REQUEST_COUNT=0
REPO_FULL_NAME=""

on_exit() {
  local rc="$?"
  # Always clean up the temp body file, no matter how we exit.
  if [ -n "$BODY_FILE" ] && [ -f "$BODY_FILE" ]; then
    rm -f "$BODY_FILE"
  fi
  print_orphan_warning "$rc"
  return "$rc"
}

print_orphan_warning() {
  local rc="$1"
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if [ -z "$ORPHAN_PR_URL" ]; then
    return 0
  fi
  # Re-check merge state on exit — if the PR actually merged in flight (e.g.
  # we ran past the merge step but tripped on a follow-up like the local pull)
  # then this isn't an orphan. The exit code stays nonzero; we just suppress
  # the misleading orphan banner.
  if [ -n "$ORPHAN_PR_NUMBER" ] \
    && command -v gh >/dev/null 2>&1 \
    && verify_pr_merged "$ORPHAN_PR_NUMBER" quiet >/dev/null 2>&1; then
    return 0
  fi
  touchstone_emit_event failed phase=open-pr reason=orphan-risk pr_number="$ORPHAN_PR_NUMBER"
  {
    echo ""
    echo "==> ORPHAN RISK: PR opened but not merged. Resolve manually:"
    echo "==>   $ORPHAN_PR_URL"
    if [ -n "$ORPHAN_PR_NUMBER" ]; then
      echo "==>   gh pr merge $ORPHAN_PR_NUMBER --squash --delete-branch    (if review passed)"
      echo "==>   gh pr close $ORPHAN_PR_NUMBER                              (if abandoning)"
    fi
  } >&2
}

gh_pr_view() {
  local pr_number="$1"
  shift

  if [ -n "$REPO_FULL_NAME" ]; then
    gh pr view "$pr_number" --repo "$REPO_FULL_NAME" "$@"
  else
    gh pr view "$pr_number" "$@"
  fi
}

# Verify the PR actually merged. Returns 0 if the PR is MERGED on GitHub,
# 1 otherwise. Used as the post-merge sanity check that turns the script's
# exit contract from "merge-pr.sh exited 0" (proxy) into "GitHub says it's
# merged" (truth).
#
# GitHub can briefly report an empty mergedAt immediately after gh pr merge
# returns, while state is already MERGED. Prefer state as authoritative, still
# accept a populated mergedAt for compatibility, and retry once before declaring
# failure. Keep this function self-contained; downstream regression tests source
# it by itself.
verify_pr_merged() {
  local pr_number="$1"
  local quiet="${2:-}"
  local attempt payload state merged_at

  for attempt in 1 2; do
    if [ -n "${REPO_FULL_NAME:-}" ]; then
      payload="$(gh pr view "$pr_number" --repo "$REPO_FULL_NAME" --json state,mergedAt 2>/dev/null || echo '{}')"
    else
      payload="$(gh pr view "$pr_number" --json state,mergedAt 2>/dev/null || echo '{}')"
    fi
    state="$(printf '%s\n' "$payload" | sed -nE 's/.*"state"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)"
    merged_at="$(printf '%s\n' "$payload" | sed -nE 's/.*"mergedAt"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)"
    if [ "$state" = "MERGED" ]; then
      if [ "$quiet" != "quiet" ]; then
        if [ -n "$merged_at" ]; then
          echo "==> Verified: PR #$pr_number merged at $merged_at"
        else
          echo "==> Verified: PR #$pr_number state=MERGED (mergedAt not yet populated by API)"
        fi
      fi
      return 0
    fi
    if [ -n "$merged_at" ]; then
      [ "$quiet" = "quiet" ] || echo "==> Verified: PR #$pr_number merged at $merged_at"
      return 0
    fi
    [ "$attempt" -eq 1 ] && sleep "${VERIFY_PR_MERGED_BACKOFF_SEC:-2}"
  done
  return 1
}

run_issue_claim_preflight() {
  local label="$1"
  shift

  if [ ! -f "$ISSUE_CLAIM_CHECK_SCRIPT" ]; then
    echo "ERROR: issue-claim-check.sh not found at $ISSUE_CLAIM_CHECK_SCRIPT." >&2
    echo "       Run touchstone update so scripts/open-pr.sh and its helpers stay in sync." >&2
    exit 2
  fi

  echo "==> Running local issue claim preflight ($label) ..."
  bash "$ISSUE_CLAIM_CHECK_SCRIPT" "$@"
}

find_pr_body_protocol_checker() {
  local rel

  for rel in scripts/check-api-boundary-protocol.py scripts/check-pr-body-protocol.py; do
    if [ -f "$REPO_ROOT/$rel" ]; then
      printf '%s\n' "$REPO_ROOT/$rel"
      return 0
    fi
  done

  return 1
}

run_pr_body_protocol_preflight() {
  local label="$1" pr_number="$2"
  local checker body checker_rel rc

  checker="$(find_pr_body_protocol_checker)" || return 0
  checker_rel="${checker#"$REPO_ROOT/"}"

  if ! body="$(gh_pr_view "$pr_number" --json body --jq '.body // ""' 2>/dev/null)"; then
    echo "ERROR: failed to read PR #$pr_number body for protocol preflight." >&2
    exit 1
  fi

  echo "==> Running PR body protocol preflight ($label): $checker_rel"
  rc=0
  if [ -x "$checker" ]; then
    API_BOUNDARY_PR_BODY="$body" PR_BODY="$body" \
      GH_REPO="$REPO_FULL_NAME" PR_NUMBER="$pr_number" \
      "$checker" || rc=$?
  elif [ "${checker##*.}" = "py" ]; then
    if ! command -v python3 >/dev/null 2>&1; then
      echo "ERROR: $checker_rel requires python3, but python3 was not found." >&2
      exit 1
    fi
    API_BOUNDARY_PR_BODY="$body" PR_BODY="$body" \
      GH_REPO="$REPO_FULL_NAME" PR_NUMBER="$pr_number" \
      python3 "$checker" || rc=$?
  else
    API_BOUNDARY_PR_BODY="$body" PR_BODY="$body" \
      GH_REPO="$REPO_FULL_NAME" PR_NUMBER="$pr_number" \
      bash "$checker" || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    echo "ERROR: PR body protocol preflight failed for PR #$pr_number." >&2
    echo "       Edit the PR body, then rerun: bash scripts/open-pr.sh --auto-merge" >&2
    exit "$rc"
  fi
}

truthy() {
  case "$(printf '%s' "${1:-false}" | tr '[:upper:]' '[:lower:]')" in
    true | 1 | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

load_open_pr_review_request_config() {
  local base_branch="$1"
  local trusted_ref=""
  local config_file="" config_tmp="" rel
  local remote_ref="refs/remotes/origin/$base_branch"
  local local_ref="refs/heads/$base_branch"
  local fetch_refspec="+refs/heads/$base_branch:$remote_ref"

  # Review-request policy is an authorization boundary. Refresh only the
  # remote-tracking ref so a long-lived feature branch cannot use stale base
  # policy, while leaving the user's local base branch untouched.
  if git fetch --quiet --no-tags origin "$fetch_refspec" >/dev/null 2>&1; then
    trusted_ref="$remote_ref"
  elif git rev-parse --verify --quiet "$remote_ref^{commit}" >/dev/null; then
    echo "ERROR: Could not refresh trusted review request policy base '$base_branch'." >&2
    echo "       Refusing to use stale $remote_ref." >&2
    return 1
  elif git rev-parse --verify --quiet "$local_ref^{commit}" >/dev/null; then
    # A stacked PR may intentionally target an unpublished local parent.
    trusted_ref="$local_ref"
  else
    echo "ERROR: Could not resolve trusted review request policy base '$base_branch'." >&2
    echo "       Expected $remote_ref or $local_ref." >&2
    return 1
  fi

  for rel in .touchstone-review.toml .codex-review.toml; do
    if ! git cat-file -e "$trusted_ref:$rel" 2>/dev/null; then
      continue
    fi
    if ! config_tmp="$(mktemp -t touchstone-open-pr-review-config.XXXXXX)"; then
      echo "ERROR: Failed to create a temporary trusted review request policy file." >&2
      echo "       source: $trusted_ref:$rel" >&2
      return 1
    fi
    if ! git show "$trusted_ref:$rel" >"$config_tmp" 2>/dev/null; then
      rm -f "$config_tmp"
      echo "ERROR: Failed to extract trusted review request policy." >&2
      echo "       source: $trusted_ref:$rel" >&2
      return 1
    fi
    config_file="$config_tmp"
    break
  done
  [ -n "$config_file" ] || return 0
  if [ ! -f "$SCRIPT_DIR/../lib/toml.sh" ]; then
    rm -f "$config_tmp"
    return 0
  fi

  # shellcheck source=../lib/toml.sh
  source "$SCRIPT_DIR/../lib/toml.sh"

  open_pr_review_request_toml_callback() {
    local section="$1"
    local key="$2"
    local value="$3"

    if [ "$section" = "review.pr_triggered" ] && [ "$key" = "request_on_push" ]; then
      case "$value" in
        true) PR_TRIGGERED_REVIEW_REQUEST_ON_PUSH=true ;;
        false)
          echo "WARNING: [review.pr_triggered].request_on_push=false is retired and ignored; every final-shipping head requests review." >&2
          ;;
        *) OPEN_PR_REVIEW_CONFIG_ERROR="[review.pr_triggered].request_on_push must be true; got: $value" ;;
      esac
    elif [ "$section" = "review.pr_triggered" ] && [ "$key" = "provider" ]; then
      PR_TRIGGERED_REVIEW_PROVIDER="$value"
    fi
  }

  if ! toml_parse "$config_file" open_pr_review_request_toml_callback; then
    rm -f "$config_tmp"
    return 1
  fi
  rm -f "$config_tmp"
  if [ -n "$OPEN_PR_REVIEW_CONFIG_ERROR" ]; then
    echo "ERROR: $OPEN_PR_REVIEW_CONFIG_ERROR" >&2
    echo "       source: $trusted_ref" >&2
    return 1
  fi
  # Validate the provider HERE, not just at request time: this loader runs
  # before any head is published (push / gh pr ready / gh pr create), so an
  # unsupported provider must fail closed now. Deferring to
  # request_pr_triggered_review would publish a final-shipping head and then
  # exit without its required review request.
  if truthy "$PR_TRIGGERED_REVIEW_REQUEST_ON_PUSH" \
    && [ "$PR_TRIGGERED_REVIEW_PROVIDER" != "github-codex" ]; then
    echo "ERROR: request_on_push only supports [review.pr_triggered].provider = \"github-codex\"; got: $PR_TRIGGERED_REVIEW_PROVIDER" >&2
    echo "       source: $trusted_ref" >&2
    return 1
  fi
}

request_pr_triggered_review() {
  local pr_number="$1"
  local expected_head_sha="$2"
  local head_sha base_revision base_branch base_sha marker request_records context created_at _creator creator_permission description request_pr request_base request_intent_at request_trigger_at body trigger_at attempt=1
  local completion_head completion_revision completion_branch completion_base
  local intent_at="" completion_records="" matching_request=false conflicting_bases=""
  local max_attempts="${TOUCHSTONE_PR_HEAD_CONVERGENCE_ATTEMPTS:-10}"
  local retry_interval="${TOUCHSTONE_PR_HEAD_CONVERGENCE_INTERVAL:-1}"

  if ! truthy "$PR_TRIGGERED_REVIEW_REQUEST_ON_PUSH"; then
    return 0
  fi
  if [ "$PR_TRIGGERED_REVIEW_PROVIDER" != "github-codex" ]; then
    echo "ERROR: request_on_push only supports [review.pr_triggered].provider = \"github-codex\"." >&2
    return 1
  fi
  case "$max_attempts" in
    "" | 0 | *[!0-9]*)
      echo "ERROR: TOUCHSTONE_PR_HEAD_CONVERGENCE_ATTEMPTS must be a positive integer." >&2
      return 1
      ;;
  esac

  while [ "$attempt" -le "$max_attempts" ]; do
    if ! head_sha="$(gh pr view "$pr_number" --json headRefOid --jq '.headRefOid')"; then
      echo "ERROR: failed to resolve the remote head for PR #$pr_number before requesting review." >&2
      return 1
    fi
    if [ -z "$head_sha" ]; then
      echo "ERROR: GitHub returned an empty remote head for PR #$pr_number." >&2
      return 1
    fi
    if [ "$head_sha" = "$expected_head_sha" ]; then
      break
    fi
    if [ "$attempt" -eq "$max_attempts" ]; then
      echo "ERROR: PR #$pr_number head remained $head_sha; expected pushed head $expected_head_sha." >&2
      return 1
    fi
    sleep "$retry_interval"
    attempt=$((attempt + 1))
  done
  if ! base_revision="$(
    gh api "repos/$REPO_FULL_NAME/pulls/$pr_number" --jq '[.base.ref, .base.sha] | @tsv'
  )"; then
    echo "ERROR: failed to resolve the base revision for PR #$pr_number before requesting review." >&2
    return 1
  fi
  IFS=$'\t' read -r base_branch base_sha <<<"$base_revision"
  if [ -z "$base_branch" ] || [ -z "$base_sha" ]; then
    echo "ERROR: GitHub returned incomplete base metadata for PR #$pr_number." >&2
    return 1
  fi
  if [ "$base_branch" != "$BASE_BRANCH" ]; then
    echo "ERROR: PR #$pr_number base changed before review was requested." >&2
    echo "       expected: $BASE_BRANCH" >&2
    echo "       actual:   $base_branch" >&2
    return 1
  fi

  local remote_base_ref="refs/remotes/origin/$base_branch"
  local fetched_base_sha
  if ! git fetch --quiet --no-tags origin \
    "+refs/heads/$base_branch:$remote_base_ref" >/dev/null 2>&1; then
    echo "ERROR: Could not refresh PR #$pr_number base '$base_branch' before requesting review." >&2
    echo "       No review request was recorded or submitted." >&2
    return 1
  fi
  if ! fetched_base_sha="$(git rev-parse "$remote_base_ref^{commit}" 2>/dev/null)"; then
    echo "ERROR: Could not resolve refreshed base '$remote_base_ref' before requesting review." >&2
    echo "       No review request was recorded or submitted." >&2
    return 1
  fi
  if [ "$fetched_base_sha" != "$base_sha" ]; then
    echo "ERROR: PR #$pr_number base moved while review admission was being checked." >&2
    echo "       GitHub base:   $base_sha" >&2
    echo "       fetched base:  $fetched_base_sha" >&2
    echo "       Rerun scripts/open-pr.sh against the current base." >&2
    echo "       No review request was recorded or submitted." >&2
    return 1
  fi
  if ! git merge-base --is-ancestor "$base_sha" "$head_sha" >/dev/null 2>&1; then
    echo "ERROR: PR #$pr_number head does not contain the current $base_branch revision." >&2
    echo "       head:        $head_sha" >&2
    echo "       current base: $base_sha" >&2
    echo "       Update the branch before spending exact-head review budget:" >&2
    echo "         git fetch origin $base_branch" >&2
    echo "         git rebase origin/$base_branch" >&2
    echo "       Then rerun: bash scripts/open-pr.sh --auto-merge" >&2
    echo "       No review request was recorded or submitted." >&2
    return 1
  fi
  marker="<!-- touchstone:pr-review-request provider=github-codex pr=$pr_number head=$head_sha base=$base_sha -->"
  if ! request_records="$(
    gh api --paginate "repos/$REPO_FULL_NAME/commits/$head_sha/statuses?per_page=100" \
      --jq '.[] |
        select(
          .context == "touchstone/review-request-intent" or
          .context == "touchstone/review-request-complete"
        ) |
        select(.state == "success") |
        [.context, .created_at, .creator.login, .description] |
        @tsv'
  )"; then
    echo "ERROR: failed to inspect prior GitHub Codex review requests for PR #$pr_number." >&2
    return 1
  fi
  while IFS=$'\t' read -r context created_at _creator description || [ -n "$context" ]; do
    [ -n "$context" ] || continue
    case "$context" in
      touchstone/review-request-intent)
        case "$description" in
          pr=*' base='*) ;;
          *) continue ;;
        esac
        request_pr="${description#pr=}"
        request_pr="${request_pr%% base=*}"
        request_base="${description#* base=}"
        request_intent_at="$created_at"
        ;;
      touchstone/review-request-complete)
        case "$description" in
          pr=*' base='*' intent='*' trigger='*) ;;
          *) continue ;;
        esac
        request_pr="${description#pr=}"
        request_pr="${request_pr%% base=*}"
        request_base="${description#* base=}"
        request_base="${request_base%% intent=*}"
        request_intent_at="${description#* intent=}"
        request_intent_at="${request_intent_at%% trigger=*}"
        request_trigger_at="${description##* trigger=}"
        ;;
      *) continue ;;
    esac
    [ "$request_pr" = "$pr_number" ] || continue
    if ! creator_permission="$(
      gh api "repos/$REPO_FULL_NAME/collaborators/$_creator/permission" --jq '.permission' 2>/dev/null
    )"; then
      creator_permission=""
    fi
    case "$creator_permission" in
      admin | maintain | write) ;;
      *)
        echo "ERROR: PR #$pr_number head $head_sha has review-request status from untrusted creator '$_creator'." >&2
        echo "       Update the PR head before requesting review." >&2
        return 1
        ;;
    esac
    if [ "$request_base" != "$base_sha" ]; then
      conflicting_bases="${conflicting_bases}${conflicting_bases:+, }$request_base"
    elif [ "$context" = "touchstone/review-request-intent" ]; then
      if [ -z "$intent_at" ] || [[ "$request_intent_at" > "$intent_at" ]]; then
        intent_at="$request_intent_at"
      fi
    else
      completion_records="${completion_records}${completion_records:+$'\n'}$request_intent_at"$'\t'"$request_trigger_at"
    fi
  done <<<"$request_records"
  if [ -n "$conflicting_bases" ]; then
    echo "ERROR: PR #$pr_number head $head_sha already has trusted review requests for another base revision." >&2
    echo "       current base:  $base_sha" >&2
    echo "       prior base(s): $conflicting_bases" >&2
    echo "       Update the PR head before requesting review for the new base." >&2
    return 1
  fi
  if [ -n "$intent_at" ] && printf '%s\n' "$completion_records" | cut -f1 | grep -Fxq "$intent_at"; then
    matching_request=true
  fi
  if [ "$matching_request" = true ]; then
    echo "==> GitHub Codex review already requested for head $head_sha at base $base_sha."
    return 0
  fi

  if [ -z "$intent_at" ]; then
    if ! intent_at="$(
      gh api -X POST "repos/$REPO_FULL_NAME/statuses/$head_sha" \
        -f state=success \
        -f context=touchstone/review-request-intent \
        -f description="pr=$pr_number base=$base_sha" \
        --jq '.created_at'
    )"; then
      echo "ERROR: failed to record review-request intent for PR #$pr_number." >&2
      return 1
    fi
  fi
  if [ -z "$intent_at" ]; then
    echo "ERROR: GitHub returned no timestamp for review-request intent." >&2
    return 1
  fi

  body="$(printf '@codex review\n\nPlease report every finding for this exact head in this single review pass -- findings\naddressed one per round each cost a full review cycle (issue #649).\n\n%s' "$marker")"
  if ! trigger_at="$(gh api -X POST "repos/$REPO_FULL_NAME/issues/$pr_number/comments" \
    -f body="$body" --jq '.created_at')"; then
    echo "ERROR: failed to request GitHub Codex review for PR #$pr_number." >&2
    return 1
  fi
  if [ -z "$trigger_at" ]; then
    echo "ERROR: GitHub returned no timestamp for the review trigger comment." >&2
    return 1
  fi
  if ! completion_head="$(gh pr view "$pr_number" --json headRefOid --jq '.headRefOid')"; then
    echo "ERROR: failed to revalidate PR #$pr_number head after requesting review." >&2
    return 1
  fi
  if ! completion_revision="$(
    gh api "repos/$REPO_FULL_NAME/pulls/$pr_number" --jq '[.base.ref, .base.sha] | @tsv'
  )"; then
    echo "ERROR: failed to revalidate PR #$pr_number base after requesting review." >&2
    return 1
  fi
  IFS=$'\t' read -r completion_branch completion_base <<<"$completion_revision"
  if [ "$completion_head" != "$head_sha" ] \
    || [ "$completion_branch" != "$base_branch" ] \
    || [ "$completion_base" != "$base_sha" ]; then
    echo "ERROR: PR #$pr_number revision changed while review was being requested." >&2
    echo "       requested: $base_branch@$base_sha head=$head_sha" >&2
    echo "       current:   ${completion_branch:-<empty>}@${completion_base:-<empty>} head=${completion_head:-<empty>}" >&2
    echo "       Rerun scripts/open-pr.sh against the current revision." >&2
    return 1
  fi
  if ! gh api -X POST "repos/$REPO_FULL_NAME/statuses/$head_sha" \
    -f state=success \
    -f context=touchstone/review-request-complete \
    -f description="pr=$pr_number base=$base_sha intent=$intent_at trigger=$trigger_at" \
    --jq '.created_at' >/dev/null; then
    echo "ERROR: failed to record durable review-request evidence for PR #$pr_number." >&2
    return 1
  fi
  OPEN_PR_REVIEW_REQUEST_COUNT=$((OPEN_PR_REVIEW_REQUEST_COUNT + 1))
  touchstone_emit_event review_requested \
    worktree_path="$REPO_ROOT" pr_number="$pr_number" head_sha="$head_sha" base_sha="$base_sha" \
    phase=open-pr request_count="$OPEN_PR_REVIEW_REQUEST_COUNT"
  echo "==> Requested GitHub Codex review for head $head_sha at base $base_sha."
}

# Locate the worktree that has the default branch checked out, by parsing
# `git worktree list --porcelain`. Returns empty when no sibling worktree
# owns the default branch (single-checkout case).
default_branch_worktree_path() {
  local default_branch="$1"
  local current_path=""
  awk -v target="refs/heads/$default_branch" '
    /^worktree / { path = substr($0, length("worktree ") + 1) }
    /^branch /   { if ($2 == target) { print path; exit } }
  ' < <(git worktree list --porcelain)
}

# Remove the current feature worktree from the default-branch worktree.
# Called after a successful auto-merge when --cleanup-worktree is set.
# The cleanup is a best-effort convenience: failures are reported but do
# not fail the script — the merge already happened, and a leftover
# worktree is recoverable via `scripts/cleanup-worktrees.sh`.
cleanup_feature_worktree() {
  local current_path default_path
  current_path="$(git rev-parse --show-toplevel)"
  default_path="$(default_branch_worktree_path "$DEFAULT_BRANCH")"

  if [ -z "$default_path" ]; then
    echo "==> --cleanup-worktree: no sibling worktree owns $DEFAULT_BRANCH; nothing to remove."
    return 0
  fi
  if [ "$current_path" = "$default_path" ]; then
    echo "==> --cleanup-worktree: already in $DEFAULT_BRANCH worktree; nothing to remove."
    return 0
  fi

  echo "==> Removing feature worktree $current_path (from $default_path) ..."
  touchstone_emit_event cleanup_started worktree_path="$current_path"
  if (cd "$default_path" && git worktree remove "$current_path"); then
    echo "==> Worktree removed."
    touchstone_emit_event cleanup_done worktree_path="$current_path" result=removed
  else
    echo "WARNING: git worktree remove failed for $current_path." >&2
    echo "         Run 'bash scripts/cleanup-worktrees.sh' from $default_path to inspect and clean up." >&2
    touchstone_emit_event cleanup_done worktree_path="$current_path" result=failed
  fi
}

find_base_merge_commit() {
  local base_branch="$1"
  local ref
  for ref in "origin/$base_branch" "$base_branch"; do
    if git rev-parse --verify "$ref^{commit}" >/dev/null 2>&1; then
      git merge-base HEAD "$ref"
      return 0
    fi
  done
  return 1
}

find_issue_closing_refs() {
  local base_branch="$1"
  local merge_base
  if ! merge_base="$(find_base_merge_commit "$base_branch")"; then
    echo "WARNING: could not find merge-base for $base_branch; skipping linked-issue detection" >&2
    return 0
  fi

  # Invariant: only commits unique to this PR branch are scanned; base-branch
  # history must not contribute stale issue references to new PR bodies.
  git log "$merge_base..HEAD" --format='%b' | awk '
    {
      line = tolower($0)
      should_scan = 0
      if (line ~ /^[[:space:]]*(closes-issue|closes|fixes|resolves):[[:space:]]*/) {
        should_scan = 1
      }
      if (line ~ /(^|[^[:alnum:]_-])(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)[[:space:]]+#[0-9]+/) {
        should_scan = 1
      }
      if (should_scan) {
        rest = line
        while (match(rest, /#[0-9]+/)) {
          issue = substr(rest, RSTART + 1, RLENGTH - 1)
          if (!seen[issue]++) {
            print issue
          }
          rest = substr(rest, RSTART + RLENGTH)
        }
      }
    }
  '
}

usage() {
  cat <<'EOF'
Usage: bash scripts/open-pr.sh [--auto-merge] [--cleanup-worktree] [--draft] [--base <branch>] [title]

Push the current feature branch, create or reuse its GitHub PR, and optionally
run the local merge gate.

Options:
  --auto-merge        Open or finalize the PR, request review, and run merge-pr.sh.
  --cleanup-worktree  Remove this worktree after a verified auto-merge.
  --draft             Create or update a draft without final body protocol, review, or merge.
                      Mutually exclusive with --auto-merge.
  --base <branch>     Target a non-default base branch.
  -h, --help          Show this help.
EOF
}

case "${1:-}" in
  -h | --help | help)
    usage
    exit 0
    ;;
esac

REPO_ROOT="$(git rev-parse --show-toplevel)"
TEMPLATE_PATH="$REPO_ROOT/.github/pull_request_template.md"
# Fail fast if gh is missing or unauthenticated.
if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: 'gh' (GitHub CLI) is not installed. Install it before opening PRs." >&2
  exit 1
fi
if ! DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)"; then
  echo "ERROR: Failed to resolve default branch via 'gh'. Is gh authenticated?" >&2
  echo "       Run: gh auth status" >&2
  exit 1
fi
if ! REPO_FULL_NAME="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)"; then
  echo "ERROR: Failed to resolve repository name via 'gh'. Is gh authenticated?" >&2
  echo "       Run: gh auth status" >&2
  exit 1
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

if [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ] || [ "$CURRENT_BRANCH" = "master" ]; then
  echo "ERROR: You are on '$CURRENT_BRANCH'. Code changes must go through a feature branch + PR." >&2
  echo "  git checkout -b feat/short-description   # or fix/, chore/, refactor/, docs/" >&2
  exit 1
fi

# Warn on uncommitted changes.
UNTRACKED="$(git -C "$REPO_ROOT" ls-files --others --exclude-standard)"
if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet || [ -n "$UNTRACKED" ]; then
  echo "WARNING: working tree has uncommitted changes — they will NOT be included in this PR." >&2
  if [ -n "$UNTRACKED" ]; then
    echo "         Untracked files detected:" >&2
    while IFS= read -r untracked_file; do
      printf '           %s\n' "$untracked_file" >&2
    done <<<"$UNTRACKED"
  fi
  echo "         Commit them first if they should be part of the PR." >&2
  read -r -p "         Continue anyway? [y/N] " answer
  case "$answer" in
    y | Y | yes | YES) ;;
    *)
      echo "Aborted."
      exit 1
      ;;
  esac
fi

# Parse flags early (needed before the existing-PR check).
DRAFT_FLAG=""
AUTO_MERGE=false
CLEANUP_WORKTREE=false
BASE_OVERRIDE=""
POSITIONAL=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --draft)
      DRAFT_FLAG="--draft"
      shift
      ;;
    --auto-merge)
      AUTO_MERGE=true
      shift
      ;;
    --cleanup-worktree)
      CLEANUP_WORKTREE=true
      shift
      ;;
    --base)
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --base requires a branch name." >&2
        exit 1
      fi
      BASE_OVERRIDE="$2"
      shift 2
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

# --cleanup-worktree is only meaningful with --auto-merge: without a merge
# there is nothing to clean up to. Reject the combination loudly so the user
# notices instead of getting silent no-op behavior.
if [ "$CLEANUP_WORKTREE" = true ] && [ "$AUTO_MERGE" != true ]; then
  echo "ERROR: --cleanup-worktree requires --auto-merge (cleanup runs only after a successful merge)." >&2
  exit 1
fi

# A draft is intentionally open while --auto-merge promises a verified merged
# terminal state. Reject the contradiction before push or PR mutation so a
# caller can never mistake an intentionally open draft for successful delivery.
if [ -n "$DRAFT_FLAG" ] && [ "$AUTO_MERGE" = true ]; then
  echo "ERROR: --draft and --auto-merge are mutually exclusive." >&2
  exit 1
fi

# Discover an existing PR before selecting trusted review-request policy. An
# existing stacked PR keeps its GitHub base even when a later invocation omits
# --base, so the repository default is not necessarily its authorization
# boundary.
if ! EXISTING_PR_RECORD="$(
  gh pr list \
    --head "$CURRENT_BRANCH" \
    --author "@me" \
    --state open \
    --json url,baseRefName,headRefOid,isDraft,isCrossRepository \
    --jq 'if length > 0 then .[0] | [.url, .baseRefName, .headRefOid, .isDraft, .isCrossRepository] | @tsv else empty end' \
    2>/dev/null
)"; then
  echo "ERROR: Failed to inspect existing PR metadata for branch '$CURRENT_BRANCH'." >&2
  exit 1
fi
EXISTING_PR_URL=""
EXISTING_PR_BASE_BRANCH=""
EXISTING_PR_HEAD_SHA=""
EXISTING_PR_IS_DRAFT=""
EXISTING_PR_IS_CROSS_REPO=""
if [ -n "$EXISTING_PR_RECORD" ]; then
  IFS=$'\t' read -r EXISTING_PR_URL EXISTING_PR_BASE_BRANCH EXISTING_PR_HEAD_SHA EXISTING_PR_IS_DRAFT EXISTING_PR_IS_CROSS_REPO <<<"$EXISTING_PR_RECORD"
  if [ -z "$EXISTING_PR_URL" ] || [ -z "$EXISTING_PR_BASE_BRANCH" ] || [ -z "$EXISTING_PR_HEAD_SHA" ]; then
    echo "ERROR: Existing PR metadata is missing its URL, base branch, or head revision." >&2
    exit 1
  fi
  case "$EXISTING_PR_IS_DRAFT" in
    true | false) ;;
    *)
      echo "ERROR: GitHub returned invalid draft state for PR $EXISTING_PR_URL: ${EXISTING_PR_IS_DRAFT:-<empty>}." >&2
      exit 1
      ;;
  esac
  case "$EXISTING_PR_IS_CROSS_REPO" in
    true | false) ;;
    *)
      echo "ERROR: GitHub returned invalid cross-repository state for PR $EXISTING_PR_URL: ${EXISTING_PR_IS_CROSS_REPO:-<empty>}." >&2
      exit 1
      ;;
  esac
  # Reject --draft against a ready PR before the unconditional push below.
  # Pushing first would update the ready PR's head and invalidate its
  # exact-head review evidence before we refuse; refusing here leaves the
  # remote PR exactly as it was.
  if [ -n "$DRAFT_FLAG" ] && [ "$EXISTING_PR_IS_DRAFT" != true ]; then
    EXISTING_PR_NUMBER="$(basename "$EXISTING_PR_URL")"
    echo "ERROR: PR #$EXISTING_PR_NUMBER is already ready for review; refusing --draft." >&2
    echo "       Reverting a ready PR to draft would leave prior exact-head review" >&2
    echo "       request markers and @codex review comments in place, which could" >&2
    echo "       be reused as though still valid. To start fresh, close this PR and" >&2
    echo "       open a new draft." >&2
    exit 1
  fi
  if [ -n "$BASE_OVERRIDE" ] && [ "$BASE_OVERRIDE" != "$EXISTING_PR_BASE_BRANCH" ]; then
    EXISTING_PR_NUMBER="$(basename "$EXISTING_PR_URL")"
    echo "ERROR: --base '$BASE_OVERRIDE' does not match existing PR #$EXISTING_PR_NUMBER base '$EXISTING_PR_BASE_BRANCH'." >&2
    echo "       Retarget the PR first: gh pr edit $EXISTING_PR_NUMBER --base '$BASE_OVERRIDE'" >&2
    echo "       Or rerun without --base to use the PR's current base." >&2
    exit 1
  fi
fi

# An explicit --base selects a new PR's base, or confirms an existing PR's
# actual base after the mismatch check above. Otherwise, updates to an existing
# PR trust its actual GitHub base; new PRs trust the repository default.
BASE_BRANCH="${BASE_OVERRIDE:-${EXISTING_PR_BASE_BRANCH:-$DEFAULT_BRANCH}}"
if [ "$BASE_BRANCH" = "$CURRENT_BRANCH" ]; then
  echo "ERROR: --base $BASE_BRANCH cannot equal the current branch." >&2
  exit 1
fi

# Warn when stacking + auto-merge combine — the user is likely about to
# orphan their stack. --auto-merge squashes the parent, which closes (not
# rebases) stacked children.
if [ "$BASE_BRANCH" != "$DEFAULT_BRANCH" ] && [ "$AUTO_MERGE" = true ]; then
  echo "WARNING: base $BASE_BRANCH with --auto-merge stacks this PR on another branch" >&2
  echo "         AND will squash-merge it, which orphans any later stacked children." >&2
  echo "         Either drop --auto-merge (open stack, merge manually in order)" >&2
  echo "         or rebase/cherry-pick child-only commits onto $DEFAULT_BRANCH." >&2
  if [ -n "$EXISTING_PR_URL" ]; then
    EXISTING_PR_NUMBER="$(basename "$EXISTING_PR_URL")"
    echo "         Then retarget the existing PR: gh pr edit $EXISTING_PR_NUMBER --base $DEFAULT_BRANCH" >&2
  else
    echo "         Then rerun without --base to open an independent PR." >&2
  fi
fi

# Final-shipping updates to an existing PR validate review policy BEFORE the
# push: for a ready PR the push itself publishes a new head, and a malformed
# policy or failed trusted-base refresh discovered afterwards would strand
# that published head without its required review request. This condition
# mirrors exactly the invocations that reach the existing-PR final-shipping
# path below (draft-only updates exit early and stay review-free).
OPEN_PR_REVIEW_POLICY_LOADED=false
if [ -n "$EXISTING_PR_URL" ] && [ -z "$DRAFT_FLAG" ] \
  && { [ "$EXISTING_PR_IS_DRAFT" != true ] || [ "$AUTO_MERGE" = true ]; }; then
  load_open_pr_review_request_config "$BASE_BRANCH"
  OPEN_PR_REVIEW_POLICY_LOADED=true
fi

# Push. The "do I already have an upstream?" check is name-aware: a fresh
# `git checkout -b <branch> origin/main` sets upstream to `origin/main`,
# which makes `git push` (without `-u`) fail with "upstream does not match
# the name of your current branch." Treat any upstream that doesn't point
# at `origin/<current-branch>` the same as "no upstream yet" and rewrite
# it on first push, so the workflow works regardless of how the branch
# was created.
EXISTING_UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
EXPECTED_UPSTREAM="origin/$CURRENT_BRANCH"
# Git resolves the ref selected for transport before running pre-push hooks.
# A hook may create a newer local commit, but that commit is not part of this
# push. Preserve the selected SHA so the review request cannot drift to it.
PUSHED_HEAD_SHA="$(git rev-parse HEAD)"
PUSH_STATUS=0
if [ -n "$EXISTING_UPSTREAM" ] && [ "$EXISTING_UPSTREAM" = "$EXPECTED_UPSTREAM" ]; then
  echo "==> Pushing $CURRENT_BRANCH ..."
  git push || PUSH_STATUS=$?
else
  if [ -n "$EXISTING_UPSTREAM" ] && [ "$EXISTING_UPSTREAM" != "$EXPECTED_UPSTREAM" ]; then
    echo "==> Existing upstream '$EXISTING_UPSTREAM' does not match '$EXPECTED_UPSTREAM'; resetting on first push." >&2
  else
    echo "==> Pushing $CURRENT_BRANCH (setting upstream) ..."
  fi
  git push -u origin "$CURRENT_BRANCH" || PUSH_STATUS=$?
fi

# Rebased-PR resume (issue #630): a rejected push on a branch with an open PR
# is the sanctioned rebase-after-takeover flow, not an error. Retry ONCE with
# --force-with-lease pinned to the PR head observed in this run's pre-push
# snapshot — but the lease only proves nothing moved AFTER the snapshot, not
# that this checkout ever incorporated that head. Before forcing, require
# integration evidence: the observed head must exist locally and contribute
# no patches absent from the local history (git cherry). A stale checkout
# missing remote-only commits fails closed instead of deleting them. The
# retry pushes the CAPTURED head SHA explicitly so a pre-push hook that
# advances HEAD cannot publish a head the review request is not bound to.
# Branches without an open PR never force-push.
if [ "$PUSH_STATUS" -ne 0 ]; then
  if [ -z "$EXISTING_PR_URL" ] || [ -z "$EXISTING_PR_HEAD_SHA" ]; then
    echo "ERROR: push failed for '$CURRENT_BRANCH' and no open PR authorizes a guarded retry." >&2
    exit "$PUSH_STATUS"
  fi
  # gh pr list --head matches branch NAME only; a fork-backed PR with the
  # same branch name would supply a fork SHA as the lease while the retry
  # pushes to origin — rewriting a same-named base-repository branch without
  # touching the PR. Cross-repository PRs never authorize the retry.
  if [ "$EXISTING_PR_IS_CROSS_REPO" != false ]; then
    echo "ERROR: push failed and PR $EXISTING_PR_URL is fork-backed (cross-repository);" >&2
    echo "       its observed head does not describe origin/$CURRENT_BRANCH, so a guarded" >&2
    echo "       retry could rewrite an unrelated same-named branch. Push to the fork" >&2
    echo "       remote manually after reconciling." >&2
    exit 1
  fi
  # Every integration inspection runs with replacement objects disabled: a
  # local `git replace` ref for the observed head would otherwise substitute
  # a different commit during validation while the lease still matches the
  # original remote SHA — the checks would bless content the force-push then
  # deletes.
  if ! GIT_NO_REPLACE_OBJECTS=1 git cat-file -e "$EXISTING_PR_HEAD_SHA^{commit}" 2>/dev/null; then
    echo "ERROR: push rejected and the observed PR head ${EXISTING_PR_HEAD_SHA:0:12} is not present locally." >&2
    echo "       This checkout never had the remote branch's current history; forcing would" >&2
    echo "       delete it. Fetch the branch, reconcile (rebase or merge), then rerun." >&2
    exit 1
  fi
  # git cherry compares patch IDs and SKIPS merge commits entirely, so a
  # remote merge whose conflict-resolution content is absent locally would
  # sail through the patch check. Any merge commit reachable from the
  # observed head but not from the captured local head is unprovable by
  # patch equivalence — refuse and require manual reconciliation. Both
  # history inspections FAIL CLOSED on traversal errors (missing or corrupt
  # ancestor objects): a check that could not run is not a clean check.
  if ! MERGE_LIST="$(GIT_NO_REPLACE_OBJECTS=1 git rev-list --merges "$EXISTING_PR_HEAD_SHA" --not "$PUSHED_HEAD_SHA" 2>&1)"; then
    echo "ERROR: push rejected and the observed PR head's history could not be traversed:" >&2
    printf '%s\n' "$MERGE_LIST" | sed 's/^/       /' >&2
    echo "       Cannot prove the remote history is incorporated; refusing to force-push." >&2
    echo "       Fetch the branch fully, reconcile, then rerun." >&2
    exit 1
  fi
  UNPROVABLE_MERGES="$(printf '%s' "$MERGE_LIST" | grep -c . || true)"
  if [ "$UNPROVABLE_MERGES" != 0 ]; then
    echo "ERROR: push rejected and the observed PR head ${EXISTING_PR_HEAD_SHA:0:12} contains $UNPROVABLE_MERGES merge commit(s)" >&2
    echo "       outside this checkout's history. Merge resolutions cannot be proven" >&2
    echo "       incorporated by patch comparison; forcing could delete them. Reconcile" >&2
    echo "       manually (fetch, merge or rebase), then rerun." >&2
    exit 1
  fi
  # Exact-content integration evidence. git cherry's patch-ids ignore
  # whitespace, which is behaviorally significant in Python, YAML, and shell
  # continuations — a remote commit differing only in whitespace would count
  # as incorporated and its content would be forced away. Instead, every
  # remote-only commit must have a whitespace-EXACT patch twin among the
  # local-only commits: hunk headers and index lines are normalized out
  # (rebases renumber them), everything else must match byte-for-byte.
  open_pr_exact_patch_fingerprint() {
    local commit="$1" patch_text
    # --binary: without it, differing binary blobs render an identical
    # "Binary files differ" placeholder and two DIFFERENT binary changes
    # fingerprint equal (issue #685).
    if ! patch_text="$(GIT_NO_REPLACE_OBJECTS=1 git diff-tree --no-commit-id --full-index --binary -p -U3 "$commit" 2>&1)"; then
      echo "ERROR: could not compute the patch for commit ${commit:0:12}:" >&2
      printf '%s\n' "$patch_text" | sed 's/^/       /' >&2
      return 1
    fi
    # An empty patch carries no provable content; the caller refuses.
    [ -n "$patch_text" ] || return 2
    # Hunk normalization keeps line COUNTS and hunk order: rebases
    # renumber start offsets but never change how many lines a hunk
    # touches, so "@@ -12,7 +12,9 @@" and its rebased twin normalize
    # identically while hunks of different shape stay distinct
    # (issue #689 finding 5). Residual bound, documented: identical
    # content added at a different location with byte-identical context
    # is indistinguishable from a rebase shift by content alone; the
    # multiset twin-consumption (issue #674) covers the duplicated-block
    # form of that ambiguity.
    printf '%s\n' "$patch_text" \
      | sed -e '/^index /d' \
        -e 's/^@@ -[0-9]*\(,[0-9]*\)\{0,1\} +[0-9]*\(,[0-9]*\)\{0,1\} @@.*/@@ -\1 +\2 @@/' \
      | touchstone_sha256_stream
  }
  if [ ! -f "$SCRIPT_DIR/../lib/sha256.sh" ]; then
    echo "ERROR: push rejected and lib/sha256.sh is missing; cannot prove remote history" >&2
    echo "       is incorporated. Refusing to force-push." >&2
    exit 1
  fi
  # shellcheck source=../lib/sha256.sh
  source "$SCRIPT_DIR/../lib/sha256.sh"
  if ! REMOTE_ONLY_COMMITS="$(GIT_NO_REPLACE_OBJECTS=1 git rev-list "$EXISTING_PR_HEAD_SHA" --not "$PUSHED_HEAD_SHA" 2>&1)"; then
    echo "ERROR: push rejected and the observed PR head's history could not be traversed:" >&2
    printf '%s\n' "$REMOTE_ONLY_COMMITS" | sed 's/^/       /' >&2
    echo "       Cannot prove the remote history is incorporated; refusing to force-push." >&2
    exit 1
  fi
  if [ -n "$REMOTE_ONLY_COMMITS" ]; then
    if ! LOCAL_ONLY_COMMITS="$(GIT_NO_REPLACE_OBJECTS=1 git rev-list "$PUSHED_HEAD_SHA" --not "$EXISTING_PR_HEAD_SHA" 2>&1)"; then
      echo "ERROR: push rejected and the local branch history could not be traversed:" >&2
      printf '%s\n' "$LOCAL_ONLY_COMMITS" | sed 's/^/       /' >&2
      echo "       Cannot prove the remote history is incorporated; refusing to force-push." >&2
      exit 1
    fi
    LOCAL_PATCH_FINGERPRINTS=" "
    for local_commit in $LOCAL_ONLY_COMMITS; do
      fp_status=0
      local_fp="$(open_pr_exact_patch_fingerprint "$local_commit")" || fp_status=$?
      # Status 2 (empty patch) just contributes no twin; hard errors abort.
      if [ "$fp_status" -eq 1 ]; then
        echo "       Refusing to force-push without complete integration evidence." >&2
        exit 1
      fi
      [ "$fp_status" -eq 0 ] && LOCAL_PATCH_FINGERPRINTS="${LOCAL_PATCH_FINGERPRINTS}${local_fp} "
    done
    for remote_commit in $REMOTE_ONLY_COMMITS; do
      fp_status=0
      remote_fp="$(open_pr_exact_patch_fingerprint "$remote_commit")" || fp_status=$?
      if [ "$fp_status" -ne 0 ]; then
        echo "ERROR: push rejected and remote commit ${remote_commit:0:12} has no provable patch content." >&2
        echo "       Refusing to force-push without complete integration evidence." >&2
        exit 1
      fi
      case "$LOCAL_PATCH_FINGERPRINTS" in
        *" $remote_fp "*)
          # Consume the twin: each remote occurrence needs its OWN local
          # occurrence. Remote histories can carry the same patch twice
          # (add X, revert X, add X again); set-membership would let both
          # occurrences claim one local twin and force away real content.
          LOCAL_PATCH_FINGERPRINTS="${LOCAL_PATCH_FINGERPRINTS/ ${remote_fp} / }"
          ;;
        *)
          echo "ERROR: push rejected and the observed PR head ${EXISTING_PR_HEAD_SHA:0:12} carries commit ${remote_commit:0:12}" >&2
          echo "       whose changes are not in this checkout's history byte-for-byte (whitespace" >&2
          echo "       differences count). Forcing would delete them. Fetch and reconcile" >&2
          echo "       (rebase or merge), then rerun; refusing to overwrite unseen work." >&2
          exit 1
          ;;
      esac
    done
  fi
  echo "==> Push rejected; PR $EXISTING_PR_URL exists and every observed-head change is incorporated locally."
  echo "==> Retrying with --force-with-lease pinned to observed PR head ${EXISTING_PR_HEAD_SHA:0:12} ..."
  if ! git push --force-with-lease="$CURRENT_BRANCH:$EXISTING_PR_HEAD_SHA" \
    origin "$PUSHED_HEAD_SHA:refs/heads/$CURRENT_BRANCH"; then
    echo "ERROR: guarded force-with-lease push failed for '$CURRENT_BRANCH'." >&2
    echo "       The remote branch no longer points at the observed PR head ${EXISTING_PR_HEAD_SHA:0:12}," >&2
    echo "       so something else updated it since this run's snapshot. Inspect the remote" >&2
    echo "       branch and rerun after reconciling; refusing to overwrite unseen work." >&2
    exit 1
  fi
  # The refspec push does not manage upstream; make later plain pushes work.
  # A failure here must be visible (the review flow continues, but a later
  # plain push would target the old upstream or need another recovery run).
  if ! UPSTREAM_SET_OUTPUT="$(git branch --set-upstream-to="origin/$CURRENT_BRANCH" 2>&1)"; then
    echo "WARNING: could not restore upstream origin/$CURRENT_BRANCH after the guarded push:" >&2
    printf '%s\n' "$UPSTREAM_SET_OUTPUT" | sed 's/^/         /' >&2
    echo "         Set it manually: git branch --set-upstream-to=origin/$CURRENT_BRANCH" >&2
  fi
fi

# Install the cleanup/orphan-warning trap now — every later exit path may
# already have a PR URL we need to surface to the user, and the trap also
# handles temp-file cleanup once BODY_FILE is set further down.
trap on_exit EXIT

# If a PR already exists for this branch, reuse it. Draft invocations remain
# review-free; final shipping validates the contract before requesting review.
if [ -n "$EXISTING_PR_URL" ]; then
  echo "==> PR already open for $CURRENT_BRANCH: $EXISTING_PR_URL"
  PR_NUMBER="$(basename "$EXISTING_PR_URL")"
  if [ "$AUTO_MERGE" = true ]; then
    ORPHAN_PR_URL="$EXISTING_PR_URL"
    ORPHAN_PR_NUMBER="$PR_NUMBER"
  fi

  # Draft-ness authorizes the review-free exits below AND the semantic
  # review request in final shipping, so the pre-push snapshot cannot be
  # trusted for either direction. Re-read the state now: a concurrent actor
  # may have promoted a draft (the pushed head would skip its required
  # review) or demoted a ready PR (a review request would land on a draft
  # coordination surface). Route on the fresh value.
  if ! FRESH_PR_IS_DRAFT="$(
    gh pr view "$PR_NUMBER" --json isDraft --jq '.isDraft' 2>/dev/null
  )"; then
    echo "ERROR: Failed to re-check draft state for PR #$PR_NUMBER after push." >&2
    exit 1
  fi
  case "$FRESH_PR_IS_DRAFT" in
    true | false) ;;
    *)
      echo "ERROR: GitHub returned invalid draft state for PR #$PR_NUMBER: ${FRESH_PR_IS_DRAFT:-<empty>}." >&2
      exit 1
      ;;
  esac
  if [ "$EXISTING_PR_IS_DRAFT" = true ] && [ "$FRESH_PR_IS_DRAFT" != true ]; then
    if [ -n "$DRAFT_FLAG" ]; then
      echo "ERROR: PR #$PR_NUMBER was marked ready for review while this draft update pushed." >&2
      echo "       The just-pushed head has no review request, and a --draft invocation" >&2
      echo "       cannot request one. Ship it properly: bash scripts/open-pr.sh --auto-merge" >&2
      exit 1
    fi
    echo "==> PR #$PR_NUMBER was concurrently marked ready; routing through final shipping."
    if [ "$OPEN_PR_REVIEW_POLICY_LOADED" != true ]; then
      load_open_pr_review_request_config "$BASE_BRANCH"
      OPEN_PR_REVIEW_POLICY_LOADED=true
    fi
  elif [ "$EXISTING_PR_IS_DRAFT" != true ] && [ "$FRESH_PR_IS_DRAFT" = true ]; then
    echo "==> PR #$PR_NUMBER was concurrently converted to draft; treating it as a draft."
  fi
  EXISTING_PR_IS_DRAFT="$FRESH_PR_IS_DRAFT"

  if [ -n "$DRAFT_FLAG" ]; then
    # A ready PR was already rejected before the push, and a concurrent
    # promotion was rejected just above; only a still-draft PR reaches this.
    echo "    PR remains a draft; no semantic review was requested."
    ORPHAN_PR_URL=""
    ORPHAN_PR_NUMBER=""
    exit 0
  fi

  if [ "$EXISTING_PR_IS_DRAFT" = true ] && [ "$AUTO_MERGE" != true ]; then
    echo "    PR is still a draft; no semantic review was requested."
    echo "    Rerun with --auto-merge to mark it ready and ship the exact head."
    exit 0
  fi

  run_issue_claim_preflight "existing PR #$PR_NUMBER" --pr-number "$PR_NUMBER"
  run_pr_body_protocol_preflight "existing PR #$PR_NUMBER" "$PR_NUMBER"
  # Review policy was already loaded and validated before the push above.
  if [ "$EXISTING_PR_IS_DRAFT" = true ]; then
    echo "==> Marking draft PR #$PR_NUMBER ready for review ..."
    gh pr ready "$PR_NUMBER" >/dev/null
  fi
  request_pr_triggered_review "$PR_NUMBER" "$PUSHED_HEAD_SHA"
  if [ "$AUTO_MERGE" = true ]; then
    MERGE_SCRIPT="$SCRIPT_DIR/merge-pr.sh"
    if [ ! -f "$MERGE_SCRIPT" ]; then
      echo "ERROR: merge-pr.sh not found at $MERGE_SCRIPT — cannot auto-merge." >&2
      exit 1
    fi
    echo ""
    echo "==> Auto-merging PR #$PR_NUMBER ..."
    # Don't exec — we need to verify mergedAt after merge-pr.sh returns.
    if ! TOUCHSTONE_PR_TRIGGERED_REVIEW_REQUEST_COUNT="$OPEN_PR_REVIEW_REQUEST_COUNT" \
      bash "$MERGE_SCRIPT" "$PR_NUMBER"; then
      echo "ERROR: merge-pr.sh failed for PR #$PR_NUMBER." >&2
      exit 1
    fi
    if ! verify_pr_merged "$PR_NUMBER"; then
      echo "ERROR: merge-pr.sh exited 0 but PR #$PR_NUMBER is not merged on GitHub." >&2
      exit 1
    fi
    if [ "$CLEANUP_WORKTREE" = true ]; then
      cleanup_feature_worktree
    fi
    exit 0
  fi
  exit 0
fi

if [ "$#" -gt 0 ]; then
  TITLE="$1"
else
  TITLE="$(git log -1 --format=%s)"
fi

COMMIT_BODY="$(git log -1 --format=%b)"
LINKED_ISSUES="$(find_issue_closing_refs "$BASE_BRANCH")"

# ---------------------------------------------------------------------------
# Sentinel-cycle PR body: when the current branch was authored by a sentinel
# agent, pull the PR body from the cycle artifact's anchored region instead
# of from commit messages.  Falls back to commit-message behavior silently if
# no anchors are found or the run file is missing.
# ---------------------------------------------------------------------------

# Returns 0 (truthy) when .sentinel/runs/ contains at least one .md artifact.
is_sentinel_authored_branch() {
  [ -n "$(find .sentinel/runs -maxdepth 1 -name "*.md" 2>/dev/null | head -1)" ]
}

# Prints the path of the most-recently-modified sentinel run artifact.
find_latest_sentinel_run() {
  # ls -t is the simplest portable mtime sort; filenames here are controlled.
  # shellcheck disable=SC2012
  ls -t .sentinel/runs/*.md 2>/dev/null | head -1
}

# Reads the schema-version from the YAML frontmatter of a run artifact.
get_schema_version() {
  local run_file="$1"
  awk '/^---$/{f=1-f; next} f && /^schema-version:/{print $2; exit}' "$run_file"
}

# Extracts lines between <!-- pr-body-start --> and <!-- pr-body-end -->.
extract_pr_body_from_run() {
  local run_file="$1"
  awk '/<!-- pr-body-start -->/{flag=1; next} /<!-- pr-body-end -->/{flag=0} flag' "$run_file"
}

SENTINEL_BODY=""
if is_sentinel_authored_branch; then
  SENTINEL_RUN="$(find_latest_sentinel_run)"
  if [ -n "$SENTINEL_RUN" ]; then
    SCHEMA_VER="$(get_schema_version "$SENTINEL_RUN")"
    if [ -n "$SCHEMA_VER" ]; then
      major="${SCHEMA_VER%%.*}"
      if [ "$major" -ge 2 ] 2>/dev/null; then
        echo "WARNING: sentinel run schema-version $SCHEMA_VER not recognized; attempting 1.x extraction" >&2
      fi
    fi
    SENTINEL_BODY="$(extract_pr_body_from_run "$SENTINEL_RUN")"
    if [ -z "$SENTINEL_BODY" ]; then
      echo "WARNING: sentinel cycle artifact found but PR-body anchors are empty — falling back to commit-message body" >&2
    fi
  fi
fi

# Build body from commit body + PR template (if present). The unified EXIT
# trap installed above (`on_exit`) will rm the file regardless of how we exit.
BODY_FILE="$(mktemp -t touchstone-pr-body.XXXXXX.md)"

{
  if [ -n "$LINKED_ISSUES" ]; then
    printf '## Linked Issues\n\n'
    while IFS= read -r issue_number; do
      [ -n "$issue_number" ] || continue
      printf 'Closes #%s\n' "$issue_number"
    done <<<"$LINKED_ISSUES"
    printf '\n'
  fi
  if [ -n "$SENTINEL_BODY" ]; then
    printf '%s\n' "$SENTINEL_BODY"
  else
    if [ -n "$COMMIT_BODY" ]; then
      printf '%s\n\n---\n\n' "$COMMIT_BODY"
    fi
    if [ -f "$TEMPLATE_PATH" ]; then
      cat "$TEMPLATE_PATH"
    fi
  fi
} >"$BODY_FILE"

run_issue_claim_preflight "new PR body" --body-file "$BODY_FILE"

# Load and validate review policy before `gh pr create` on the final-shipping
# path: malformed policy or a failed trusted-base refresh must fail before a
# ready PR is published without its required review request. Draft creation
# stays review-free and skips review infrastructure entirely.
if [ -z "$DRAFT_FLAG" ]; then
  load_open_pr_review_request_config "$BASE_BRANCH"
fi

echo "==> Opening PR against $BASE_BRANCH ..."
if [ -n "$DRAFT_FLAG" ]; then
  PR_URL="$(gh pr create --base "$BASE_BRANCH" --title "$TITLE" --body-file "$BODY_FILE" --draft)"
else
  PR_URL="$(gh pr create --base "$BASE_BRANCH" --title "$TITLE" --body-file "$BODY_FILE")"
fi

echo "$PR_URL"

# Capture the PR for the orphan-warning trap — anything that exits nonzero
# from here on is a stuck-PR risk.
ORPHAN_PR_URL="$PR_URL"
ORPHAN_PR_NUMBER="$(basename "$PR_URL")"
HEAD_SHA="$(git rev-parse HEAD)"
touchstone_emit_event pr_opened \
  pr_url="$PR_URL" \
  pr_number="$ORPHAN_PR_NUMBER" \
  branch="$CURRENT_BRANCH" \
  base_branch="$BASE_BRANCH" \
  head_sha="$HEAD_SHA"

if [ -n "$DRAFT_FLAG" ]; then
  echo "    Opened as draft; no semantic review was requested."
  echo "    Rerun with --auto-merge to mark it ready and ship the exact head."
  # Draft path: PR is intentionally open and not merged. That's not an orphan.
  ORPHAN_PR_URL=""
  ORPHAN_PR_NUMBER=""
  exit 0
fi

run_pr_body_protocol_preflight "new PR #$ORPHAN_PR_NUMBER" "$ORPHAN_PR_NUMBER"
request_pr_triggered_review "$ORPHAN_PR_NUMBER" "$PUSHED_HEAD_SHA"

# Auto-merge: extract PR number and run merge-pr.sh, then positively verify
# the PR actually reached MERGED state on GitHub before claiming success.
if [ "$AUTO_MERGE" = true ]; then
  PR_NUMBER="$(basename "$PR_URL")"
  MERGE_SCRIPT="$SCRIPT_DIR/merge-pr.sh"
  if [ ! -f "$MERGE_SCRIPT" ]; then
    echo "ERROR: merge-pr.sh not found at $MERGE_SCRIPT — cannot auto-merge." >&2
    exit 1
  fi
  echo ""
  echo "==> Auto-merging PR #$PR_NUMBER ..."
  # Don't exec — we need to verify mergedAt after merge-pr.sh returns. The
  # earlier `exec bash "$MERGE_SCRIPT"` form propagated merge-pr.sh's exit
  # code but never positively confirmed merge happened, so any silent failure
  # post-review (network blip on `gh pr merge`, etc.) could end with exit 0
  # and a still-open PR. The new flow always asks GitHub.
  if ! TOUCHSTONE_PR_TRIGGERED_REVIEW_REQUEST_COUNT="$OPEN_PR_REVIEW_REQUEST_COUNT" \
    bash "$MERGE_SCRIPT" "$PR_NUMBER"; then
    echo "ERROR: merge-pr.sh failed for PR #$PR_NUMBER." >&2
    exit 1
  fi
  if ! verify_pr_merged "$PR_NUMBER"; then
    echo "ERROR: merge-pr.sh exited 0 but PR #$PR_NUMBER is not merged on GitHub." >&2
    exit 1
  fi

  if [ "$CLEANUP_WORKTREE" = true ]; then
    cleanup_feature_worktree
  fi
fi

# Reached the natural end with no failures — clear the orphan markers so the
# EXIT trap stays quiet on a clean exit 0.
ORPHAN_PR_URL=""
ORPHAN_PR_NUMBER=""
