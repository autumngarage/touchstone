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
# Stacked PRs — read this before using --base:
#   Stacking a PR on another PR's branch is useful when work naturally
#   splits into a chain (parent PR ships primitive, child PR ships the
#   consumer that depends on it). merge-pr.sh retains the head branch after
#   every merge (and refuses to merge when the repository's
#   deleteBranchOnMerge setting would delete it server-side), so
#   squash-merging the parent no longer closes stacked children: the child
#   PR stays open, still based on the retained parent branch. The child does
#   not follow the parent to the default branch by itself — after the parent
#   lands, retarget it (gh pr edit <n> --base <default>) and rebase it onto
#   the default branch so the parent's already-squashed commits drop out of
#   its diff. Branch DELETION is what endangers a stack: GitHub closes open
#   PRs whose base branch disappears (issue #713), which is why the merge
#   path keeps the branch and leaves deletion to cleanup-branches.sh, which
#   refuses while dependents exist.
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
OPEN_PR_TRUSTED_REVIEW_AUTHORS="chatgpt-codex-connector,chatgpt-codex-connector[bot]"
OPEN_PR_HEAD_REVIEW_LOOKUP_ERROR=""
OPEN_PR_REVIEW_CONFIG_ERROR=""
OPEN_PR_REVIEW_REQUEST_COUNT=0
# Review-stall threshold (#759), minutes, env-overridable via
# TOUCHSTONE_REVIEW_STALL_MINUTES. A durable request whose @codex trigger has
# gone unanswered this long is reported as possibly skipped by the reviewer —
# observed 2026-08-11: a re-request unanswered for 40+ minutes while the same
# reviewer served other PRs in the window, and an empty re-trigger commit drew
# no review either. The threshold gates only the report and the --fresh-review
# advertisement; absence of an answer is a heuristic, not evidence, so no
# request is ever fired from it automatically.
OPEN_PR_REVIEW_STALL_DEFAULT_MINUTES=30
# The exact base OID request_pr_triggered_review validated (GitHub's base SHA,
# cross-checked against a refreshed origin/<base>). The merge authorizer is
# extracted at THIS commit, not at whatever origin/<base> resolves to later —
# otherwise the base can advance between review validation and gate extraction
# and the gate would come from a different revision than the one the review
# was admitted against (PR #707 review).
OPEN_PR_VALIDATED_BASE_SHA=""
REPO_FULL_NAME=""

on_exit() {
  local rc="$?"
  # Always clean up the temp body file, no matter how we exit.
  if [ -n "$BODY_FILE" ] && [ -f "$BODY_FILE" ]; then
    rm -f "$BODY_FILE"
  fi
  if [ -n "$TRUSTED_MERGE_BUNDLE_DIR" ] && [ -d "$TRUSTED_MERGE_BUNDLE_DIR" ]; then
    rm -rf "$TRUSTED_MERGE_BUNDLE_DIR"
  fi
  print_orphan_warning "$rc"
  return "$rc"
}

# --- Trusted merge authorizer -----------------------------------------------
#
# The merge gate decides whether review evidence is clean and then calls
# `gh pr merge`. Running it from this worktree means a PR that edits
# merge-pr.sh is authorized by the edited merge-pr.sh — the gate's verdict
# becomes conditional on the very change it is supposed to be gating. That is
# not hypothetical for a repo whose own PRs routinely touch the gate.
#
# So the authorizer is materialized from the PR's BASE revision instead: code
# that is already merged and already reviewed. A PR can still change the gate;
# it just cannot use the changed gate to admit itself. The next PR gets the new
# gate, because by then it is on the base.
#
# The whole of lib/ comes along, not a hand-listed subset. merge-pr.sh sources
# script-sync-guard, events, preflight and toml, and preflight sources sha256
# and preflight-scope; a hardcoded list would silently rot the first time that
# sourcing changes, and the failure mode would be a gate running half-trusted.
#
# This closes the accidental case, which is the real one. It does not make the
# authorizer independent of a deliberately hostile open-pr.sh — that caller is
# still this file. Issue #640's full form moves invocation to the installed
# CLI, outside the repository entirely.
TRUSTED_MERGE_BUNDLE_DIR=""
TRUSTED_MERGE_SCRIPT=""
TRUSTED_MERGE_BASE_OID=""

materialize_trusted_merge_authorizer() {
  local base_branch="$1"
  local validated_oid="$2"
  local base_oid bundle

  # Extract at the exact base OID request_pr_triggered_review validated, not
  # at origin/<base> as currently cached. Resolving the branch name again here
  # would reopen a TOCTOU window: the base can advance between review
  # validation and gate extraction (a stacked parent landing, a concurrent
  # merge), and the authorizer would then come from a different commit than
  # the one the review admission was checked against (PR #707 review).
  # `git archive` accepts any commit, so binding to the OID costs nothing.
  if ! base_oid="$(GIT_NO_REPLACE_OBJECTS=1 git rev-parse --verify --quiet \
    "$validated_oid^{commit}" 2>/dev/null)"; then
    git fetch --quiet --no-tags origin "$base_branch" >/dev/null 2>&1 || true
    if ! base_oid="$(GIT_NO_REPLACE_OBJECTS=1 git rev-parse --verify --quiet \
      "$validated_oid^{commit}" 2>/dev/null)"; then
      echo "ERROR: cannot resolve the validated base revision of '$base_branch' to materialize the merge gate." >&2
      echo "       validated base: $validated_oid" >&2
      echo "       The gate must come from the reviewed base commit the review request was" >&2
      echo "       admitted against, not from this branch. Fetch the base and rerun:" >&2
      echo "         git fetch origin $base_branch" >&2
      return 1
    fi
  fi

  if ! bundle="$(mktemp -d -t touchstone-trusted-merge.XXXXXX)"; then
    echo "ERROR: could not create a temporary directory for the trusted merge gate." >&2
    return 1
  fi
  TRUSTED_MERGE_BUNDLE_DIR="$bundle"

  # Check presence before archiving: `git archive` fails on an unmatched
  # pathspec, so without this the precise diagnosis is lost in a generic
  # extraction error.
  #
  # GIT_NO_REPLACE_OBJECTS=1 on every object read here. A `refs/replace/<oid>`
  # entry in the checkout makes both `git cat-file` and `git archive`
  # transparently serve the REPLACEMENT object while the displayed base OID is
  # unchanged — so the extracted "trusted base gate" would be attacker-supplied
  # merge-pr.sh with the reviewed SHA still printed beside it. This function
  # exists to take the authorization logic out of the PR's control, so it must
  # not read through a redirection the PR can add (PR #707 review).
  if ! GIT_NO_REPLACE_OBJECTS=1 git cat-file -e "$base_oid:scripts/merge-pr.sh" 2>/dev/null; then
    echo "ERROR: base $base_branch (${base_oid:0:12}) has no scripts/merge-pr.sh." >&2
    echo "       The merge gate must come from the base, and this base does not carry one." >&2
    echo "       Land the Touchstone delivery scripts on $base_branch first." >&2
    return 1
  fi

  # Archive the whole scripts/ tree, not just merge-pr.sh. A base gate older
  # than e5617d0 invokes siblings — scripts/codex-review.sh among them — and
  # those historical gates treat a MISSING sibling as "skipping review" and
  # proceed to merge. Bundling only merge-pr.sh therefore hands the first
  # upgrade PR a gate that is materially weaker than the one committed on the
  # base, which is the opposite of what extracting from the base is for
  # (PR #707 review).
  if ! GIT_NO_REPLACE_OBJECTS=1 git archive "$base_oid" scripts lib 2>/dev/null | tar -x -C "$bundle" 2>/dev/null; then
    echo "ERROR: could not extract scripts/merge-pr.sh and lib/ from base $base_branch (${base_oid:0:12})." >&2
    echo "       Refusing to authorize a merge with the gate from this worktree." >&2
    return 1
  fi
  if [ ! -f "$bundle/scripts/merge-pr.sh" ]; then
    echo "ERROR: base $base_branch (${base_oid:0:12}) has no scripts/merge-pr.sh." >&2
    echo "       Land the Touchstone update on $base_branch before shipping from this branch." >&2
    return 1
  fi

  # Capability check on the EXTRACTED gate, not just its existence.
  #
  # A base predating 2f7c09a carries a merge-pr.sh with no PR-visible review
  # gate at all: it can reach `gh pr merge` without ever waiting for a trusted
  # exact-head review result. Executing whatever historical gate happens to be
  # present would therefore let the first upgrade PR — the one whose whole
  # purpose is to introduce the review gate — merge without one.
  #
  # A base predating c38e5d6 has the review wait but reviews against
  # origin/<default branch> instead of the PR's actual base
  # (current_pr_base_revision): a stacked PR targeting a feature branch would
  # be authorized against the wrong diff and base revision. The gate is only
  # as strong as the contract with BOTH capabilities — the review-wait pair
  # AND PR-base binding — so all three names are required, not any-of.
  #
  # "Run the gate from the base" is only a safety property while the base's
  # gate is at least as strong as the contract being enforced. Where it is not,
  # this fails closed with a migration path rather than silently executing a
  # weaker authorizer (PR #707 review).
  local capability
  for capability in \
    require_pr_feedback_clear \
    wait_for_pr_triggered_review \
    current_pr_base_revision; do
    if grep -q "$capability" "$bundle/scripts/merge-pr.sh" 2>/dev/null; then
      continue
    fi
    echo "ERROR: the merge gate on base $base_branch (${base_oid:0:12}) predates the" >&2
    echo "       PR-visible review requirement — it lacks '$capability', so it cannot" >&2
    echo "       enforce a trusted exact-head review bound to this PR's actual base." >&2
    echo "       Refusing to authorize with it. Running it would let this very PR" >&2
    echo "       merge without the review gate it is meant to introduce." >&2
    echo "       Migration: land the Touchstone delivery scripts on $base_branch first," >&2
    echo "         git switch $base_branch && touchstone update --ship" >&2
    echo "       then reopen this PR against the updated base." >&2
    return 1
  done

  TRUSTED_MERGE_SCRIPT="$bundle/scripts/merge-pr.sh"
  TRUSTED_MERGE_BASE_OID="$base_oid"
  return 0
}

# Resolve and announce the authorizer. Both --auto-merge call sites go through
# this, so they cannot drift apart on which gate they trust.
resolve_merge_authorizer() {
  local base_branch="$1"

  # Invariant: --auto-merge always runs request_pr_triggered_review first, and
  # that call validates the PR's base OID before returning. No validated OID
  # here means the sequencing broke — refuse rather than fall back to
  # extracting at whatever origin/<base> happens to be cached as.
  if [ -z "$OPEN_PR_VALIDATED_BASE_SHA" ]; then
    echo "ERROR: no validated base revision is available to materialize the merge gate." >&2
    echo "       request_pr_triggered_review must validate the PR base before auto-merge." >&2
    return 1
  fi
  if ! materialize_trusted_merge_authorizer "$base_branch" "$OPEN_PR_VALIDATED_BASE_SHA"; then
    return 1
  fi
  echo "==> Merge gate materialized from $base_branch @ ${TRUSTED_MERGE_BASE_OID:0:12} (not this worktree)."
  if ! cmp -s "$TRUSTED_MERGE_SCRIPT" "$SCRIPT_DIR/merge-pr.sh"; then
    echo "    NOTE: this branch modifies merge-pr.sh. The base version is authorizing"
    echo "          this merge; your changes take effect for the next PR."
  fi
  return 0
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
  {
    echo ""
    echo "==> ORPHAN RISK: PR opened but not merged. Resolve manually:"
    echo "==>   $ORPHAN_PR_URL"
    if [ -n "$ORPHAN_PR_NUMBER" ]; then
      # Deliberately NOT `gh pr merge --delete-branch`: following that here
      # deletes the head branch, and if any PR is stacked on it those get
      # closed with their review threads (issue #713). Route recovery through
      # the same non-deleting merge path the gate uses (PR #715 review).
      # Absolute, derived from this script's own location. A relative path is
      # only correct when the operator happens to be at the repository root;
      # invoked from a subdirectory the printed command fails with
      # "No such file or directory" and the orphaned PR stays orphaned
      # (PR #715 review). Rendered with %q so a checkout path containing
      # spaces or shell metacharacters survives copy-paste as one word.
      printf '==>   bash %q %s    (if review passed)\n' \
        "${SCRIPT_DIR:-scripts}/merge-pr.sh" "$ORPHAN_PR_NUMBER"
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

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

csv_contains() {
  local csv="$1"
  local wanted="$2"
  local item
  local -a csv_items

  if [ -n "$csv" ]; then
    IFS=',' read -r -a csv_items <<<"$csv"
    for item in "${csv_items[@]}"; do
      item="$(trim "$item")"
      if [ "$item" = "$wanted" ]; then
        return 0
      fi
    done
  fi
  return 1
}

# Issue #751: the review request is idempotent PER HEAD. A trusted formal
# review already bound to the exact current head means the head is reviewed;
# asking again re-runs a non-deterministic oracle on unchanged input and
# manufactures new findings (measured: four reviews at one byte-identical
# head on PR #715).
#
# Returns 0 when at least one trusted formal review has commit_id == head,
# 1 when none does, 2 when the lookup failed. A failed lookup is reported in
# OPEN_PR_HEAD_REVIEW_LOOKUP_ERROR and is never collapsed into 0 or 1.
trusted_review_exists_for_head() {
  local pr_number="$1"
  local head_sha="$2"
  local reviews_tsv login commit

  OPEN_PR_HEAD_REVIEW_LOOKUP_ERROR=""
  OPEN_PR_HEAD_REVIEW_DISMISSED_AT=""
  OPEN_PR_HEAD_REVIEW_LIVE_AT=""
  # Spent review rounds on this PR: every submitted trusted review, at ANY
  # head — the same formal-review definition merge-pr.sh's
  # report_review_rounds uses (the two unify when #734 thins the gate).
  # PENDING is unsubmitted and costs nothing; DISMISSED was still a spent
  # round. Consumed by the round-budget gate (#760).
  OPEN_PR_TRUSTED_REVIEW_ROUNDS=0
  # Comment-channel answer state for THIS head (the channel formal-review
  # lookup cannot see; clean results normally arrive here). AT is the latest
  # trusted result comment naming this exact head by merge-pr.sh's canonical
  # 10-char marker (verdict classification stays in the filter for the test
  # tier; the gate owns verdict semantics — #734). LOOKUP_ERROR nonempty means the
  # comment inspection FAILED — unknown, not absent — and every stall
  # classification/recovery consumer must suppress rather than act on
  # incomplete GitHub state (PR #781 review).
  OPEN_PR_HEAD_RESULT_COMMENT_AT=""
  OPEN_PR_RESULT_COMMENT_LOOKUP_ERROR=""
  OPEN_PR_RESULT_COMMENT_LOOKUP_OK=false
  local submitted
  if ! reviews_tsv="$(gh api --paginate "repos/$REPO_FULL_NAME/pulls/$pr_number/reviews" \
    --jq '.[] | [(.user.login // ""), (.commit_id // ""), (.state // ""), (.submitted_at // "")] | @tsv' 2>&1)"; then
    OPEN_PR_HEAD_REVIEW_LOOKUP_ERROR="$reviews_tsv"
    return 2
  fi
  local found=1
  while IFS=$'\t' read -r login commit state submitted || [ -n "$login" ]; do
    [ -n "$login" ] || continue
    csv_contains "$OPEN_PR_TRUSTED_REVIEW_AUTHORS" "$login" || continue
    [ "$state" = "PENDING" ] && continue
    OPEN_PR_TRUSTED_REVIEW_ROUNDS=$((OPEN_PR_TRUSTED_REVIEW_ROUNDS + 1))
    [ "$commit" = "$head_sha" ] || continue
    # A DISMISSED review is revoked evidence. The merge gate refuses it, so
    # letting it satisfy request idempotency here would suppress the only
    # re-request that could produce valid evidence — open-pr.sh saying
    # "already reviewed" while merge-pr.sh says "not reviewed", forever
    # (PR #755 review). PENDING has not been submitted and proves nothing.
    # The dismissal timestamp is kept so the EVIDENCE skip below can tell
    # "requested, awaiting the answer" (skip is correct) from "requested,
    # answered, answer revoked" (a re-request is the only way forward).
    case "$state" in
      DISMISSED)
        if [ -z "$OPEN_PR_HEAD_REVIEW_DISMISSED_AT" ] \
          || [[ "$submitted" > "$OPEN_PR_HEAD_REVIEW_DISMISSED_AT" ]]; then
          OPEN_PR_HEAD_REVIEW_DISMISSED_AT="$submitted"
        fi
        continue
        ;;
    esac
    found=0
    if [ -z "$OPEN_PR_HEAD_REVIEW_LIVE_AT" ] \
      || [[ "$submitted" > "$OPEN_PR_HEAD_REVIEW_LIVE_AT" ]]; then
      OPEN_PR_HEAD_REVIEW_LIVE_AT="$submitted"
    fi
  done <<<"$reviews_tsv"
  # Comment-delivered results ("Reviewed commit:" issue comments from a
  # trusted author) are spent rounds too: merge-pr.sh counts them as a
  # supported result channel, so a budget that ignored them would be
  # evadable by channel (PR #765 review). Lookup failure leaves the count
  # partial rather than refusing — friction control, not authorization.
  # Each row is login<TAB>reviewed-sha<TAB>created-at<TAB>verdict. The jq
  # program lives in ONE single-quoted assignment so the test tier can eval
  # this exact line and exercise the real filter with real jq — the P1 on
  # PR #781 was an uncompilable filter that stub-served fixtures never ran.
  # A row is kept even when the body carries no backticked commit (empty sha)
  # so round counting never depends on the capture. The head answer requires
  # the canonical 10-char short exactly, as merge-pr.sh's matcher does — a
  # 7-char or full-length sha would be rejected by the merge gate, so it must
  # not count as an answer here either. Lookup failure records the error and
  # leaves the round count partial: friction control, not authorization.
  OPEN_PR_RESULT_COMMENT_JQ='.[] | select((.body // "") | contains("Reviewed commit:")) | [(.user.login // ""), (((.body // "") | (capture("Reviewed commit:[^`]*`(?<sha>[0-9a-fA-F]{7,40})`")? | .sha) // "")), (.created_at // ""), (if ((.body // "") | (startswith("Codex Review: Didn'\''t find any major issues.") or startswith("Codex Review: No major issues."))) then "clean" else "non-clean" end)] | @tsv'
  local result_comment_rows comment_login comment_result_sha comment_result_at
  local head_short_lc comment_sha_lc
  head_short_lc="$(printf '%.10s' "$head_sha" | tr '[:upper:]' '[:lower:]')"
  # Success is an explicit status, never inferred from the diagnostic
  # string: a killed gh or silent wrapper exits nonzero with EMPTY stderr,
  # and empty-diagnostic-means-success would read that failure as a
  # confirmed absence of answers (PR #781 review, override round 2).
  if result_comment_rows="$(gh api --paginate "repos/$REPO_FULL_NAME/issues/$pr_number/comments" \
    --jq "$OPEN_PR_RESULT_COMMENT_JQ" 2>&1)"; then
    OPEN_PR_RESULT_COMMENT_LOOKUP_OK=true
    while IFS=$'\t' read -r comment_login comment_result_sha comment_result_at _; do
      [ -n "$comment_login" ] || continue
      csv_contains "$OPEN_PR_TRUSTED_REVIEW_AUTHORS" "$comment_login" || continue
      OPEN_PR_TRUSTED_REVIEW_ROUNDS=$((OPEN_PR_TRUSTED_REVIEW_ROUNDS + 1))
      comment_sha_lc="$(printf '%s' "$comment_result_sha" | tr '[:upper:]' '[:lower:]')"
      [ -n "$comment_sha_lc" ] && [ "$comment_sha_lc" = "$head_short_lc" ] || continue
      [ -n "$comment_result_at" ] || continue
      if [ -z "$OPEN_PR_HEAD_RESULT_COMMENT_AT" ] \
        || [[ "$comment_result_at" > "$OPEN_PR_HEAD_RESULT_COMMENT_AT" ]]; then
        OPEN_PR_HEAD_RESULT_COMMENT_AT="$comment_result_at"
      fi
    done <<<"$result_comment_rows"
  else
    OPEN_PR_RESULT_COMMENT_LOOKUP_ERROR="${result_comment_rows:-comment lookup failed with no diagnostic}"
  fi
  return "$found"
}

# ISO8601 UTC (2026-08-11T13:13:52Z) -> epoch seconds. BSD date first, GNU
# fallback (the touchstone_sync_timestamp_epoch pattern). Prints nothing and
# fails when neither form parses.
open_pr_utc_epoch() {
  local ts="$1"
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" '+%s' 2>/dev/null \
    || date -u -d "$ts" '+%s' 2>/dev/null
}

# Stall report (#759): without it, "already requested" is indistinguishable
# from "will never be answered" — the reviewer can skip a pushed head with no
# error surfaced anywhere on the PR, and the recovery gesture the guidance
# implied (an empty commit) draws no review either. Advisory only: it names
# the sanctioned recovery (--fresh-review, which retires the stale request)
# and never fires a request itself. Returns 1 only for a malformed threshold,
# which refuses loudly rather than silently disabling the report.
report_unanswered_request_stall() {
  local trigger_at="$1"
  local stall_minutes="${TOUCHSTONE_REVIEW_STALL_MINUTES:-$OPEN_PR_REVIEW_STALL_DEFAULT_MINUTES}"
  local trigger_epoch now_epoch age_minutes

  case "$stall_minutes" in
    '' | *[!0-9]*)
      echo "ERROR: TOUCHSTONE_REVIEW_STALL_MINUTES must be a non-negative integer; got '$stall_minutes' (#759)." >&2
      return 1
      ;;
  esac
  if ! trigger_epoch="$(open_pr_utc_epoch "$trigger_at")" || [ -z "$trigger_epoch" ]; then
    echo "WARNING: cannot parse review-request trigger timestamp '$trigger_at'; stall detection (#759) skipped." >&2
    return 0
  fi
  now_epoch="$(date -u '+%s')"
  [ "$now_epoch" -ge "$trigger_epoch" ] || return 0
  age_minutes=$(((now_epoch - trigger_epoch) / 60))
  [ "$age_minutes" -ge "$stall_minutes" ] || return 0
  echo "    The request has been unanswered for $age_minutes minute(s) (trigger $trigger_at),"
  echo "    past the stall threshold of $stall_minutes minute(s) (TOUCHSTONE_REVIEW_STALL_MINUTES)."
  echo "    The reviewer may have skipped this head (#759); an empty commit does not recover"
  echo "    it. Retire this request and re-ask for the SAME head without a new commit:"
  echo "      bash scripts/open-pr.sh --fresh-review"
}

load_open_pr_review_request_config() {
  local base_branch="$1"
  local trusted_ref="" trusted_oid=""
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

  # Pin the chosen ref to a commit OID and read every object through the OID.
  # A ref name is shared mutable state: a concurrent fetch can move it between
  # the refresh above and the reads below, so ref-relative reads could serve
  # policy from a commit this function never chose — the same
  # validate-then-re-resolve window the merge-gate extraction closes by
  # binding to the validated base OID (PR #707 review).
  if ! trusted_oid="$(GIT_NO_REPLACE_OBJECTS=1 git rev-parse --verify --quiet \
    "$trusted_ref^{commit}")"; then
    echo "ERROR: Could not pin trusted review request policy base '$base_branch' to a commit." >&2
    echo "       ref: $trusted_ref" >&2
    return 1
  fi

  # Same reasoning as the gate extraction above: this reads review POLICY from
  # the trusted base, so a replacement object must not be able to supply it.
  for rel in .touchstone-review.toml .codex-review.toml; do
    if ! GIT_NO_REPLACE_OBJECTS=1 git cat-file -e "$trusted_oid:$rel" 2>/dev/null; then
      continue
    fi
    if ! config_tmp="$(mktemp -t touchstone-open-pr-review-config.XXXXXX)"; then
      echo "ERROR: Failed to create a temporary trusted review request policy file." >&2
      echo "       source: $trusted_ref@$trusted_oid:$rel" >&2
      return 1
    fi
    if ! GIT_NO_REPLACE_OBJECTS=1 git show "$trusted_oid:$rel" >"$config_tmp" 2>/dev/null; then
      rm -f "$config_tmp"
      echo "ERROR: Failed to extract trusted review request policy." >&2
      echo "       source: $trusted_ref@$trusted_oid:$rel" >&2
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
    elif [ "$section" = "review.pr_triggered" ] && [ "$key" = "trusted_review_authors" ]; then
      OPEN_PR_TRUSTED_REVIEW_AUTHORS="$(toml_normalize_array "$value")"
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
  local intent_at="" completion_records="" matching_request=false conflicting_bases="" matching_trigger_at="" request_consumed_by_dismissal=false
  local head_review_status
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
  # Base fully validated: GitHub's base SHA matches a freshly fetched
  # origin/<base> and the head contains it. Publish it so the merge authorizer
  # is extracted at this exact commit (see OPEN_PR_VALIDATED_BASE_SHA above).
  OPEN_PR_VALIDATED_BASE_SHA="$base_sha"
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
  # Per-head idempotency (issue #751): when a trusted formal review already
  # exists for this exact head, the head is reviewed — do not re-request.
  # The skip requires matching durable request evidence too, because the
  # merge gate refuses heads without it (review-request-legacy-head); a
  # review without evidence must still fall through and record the request,
  # or open-pr.sh and merge-pr.sh would each point at the other forever.
  head_review_status=0
  trusted_review_exists_for_head "$pr_number" "$head_sha" || head_review_status=$?
  if [ "$head_review_status" -eq 2 ]; then
    # Inspection failure is not a "no": say so and continue with the durable
    # request-evidence checks, which are themselves idempotent.
    echo "WARNING: could not determine whether head $head_sha already has a trusted review:" >&2
    printf '%s\n' "$OPEN_PR_HEAD_REVIEW_LOOKUP_ERROR" | sed 's/^/         /' >&2
    echo "         Falling back to durable request-evidence checks." >&2
  fi
  # A dismissal that postdates the completed request's TRIGGER consumed that
  # request — its answer was revoked. This must be known BEFORE the
  # reviewed-head skip: an older still-live review on the same head would
  # otherwise satisfy that skip and make the consumption branch unreachable,
  # stranding the gate between a rejected dismissed answer and an older
  # review that predates the request (PR #755 review, round 9).
  matching_trigger_at="$(printf '%s\n' "$completion_records" \
    | awk -F'\t' -v i="$intent_at" '$1 == i { print $2; exit }')"
  # A formal review only answers THIS request when it postdates the
  # request's trigger: after --fresh-review re-asks on an unchanged head, the
  # older review answered an older ask, and merge-pr.sh rejects pre-trigger
  # results — the reviewed-head skip must not hide the stalled replacement
  # (PR #781 review, round 2).
  formal_answer_post_trigger=false
  if [ -n "${OPEN_PR_HEAD_REVIEW_LIVE_AT:-}" ] \
    && { [ -z "$matching_trigger_at" ] \
      || [[ "$OPEN_PR_HEAD_REVIEW_LIVE_AT" > "$matching_trigger_at" ]]; }; then
    formal_answer_post_trigger=true
  fi
  request_consumed_by_dismissal=false
  if [ -n "${OPEN_PR_HEAD_REVIEW_DISMISSED_AT:-}" ] \
    && [ -n "$matching_trigger_at" ] \
    && [[ "$OPEN_PR_HEAD_REVIEW_DISMISSED_AT" > "$matching_trigger_at" ]]; then
    # A dismissal only consumes the request when NO live post-trigger answer
    # exists: multiple exact-head reviews are supported, and if a valid
    # non-dismissed review also postdates the trigger, the request WAS
    # answered — merge-pr.sh authorizes from it, and re-requesting would
    # spend a full review cycle for nothing, the anti-goal of this change
    # (PR #755 review, round 10).
    # The shield covers BOTH channels: a trusted comment result naming this
    # head also answers the request — merge-pr.sh ignores the dismissed
    # formal review and can accept the comment — and an errored comment
    # lookup proves nothing, so consumption stays conservative
    # (PR #781 review, override round).
    comment_answer_shields=false
    if [ -n "$OPEN_PR_HEAD_RESULT_COMMENT_AT" ] \
      && [[ "$OPEN_PR_HEAD_RESULT_COMMENT_AT" > "$matching_trigger_at" ]]; then
      comment_answer_shields=true
    fi
    if { [ -z "${OPEN_PR_HEAD_REVIEW_LIVE_AT:-}" ] \
      || ! [[ "$OPEN_PR_HEAD_REVIEW_LIVE_AT" > "$matching_trigger_at" ]]; } \
      && [ "$comment_answer_shields" != true ] \
      && [ "$OPEN_PR_RESULT_COMMENT_LOOKUP_OK" = true ]; then
      request_consumed_by_dismissal=true
    fi
  fi

  if [ "$head_review_status" -eq 0 ] && [ "$matching_request" = true ] \
    && [ "${FRESH_REVIEW:-false}" != true ] \
    && [ "$request_consumed_by_dismissal" != true ] \
    && [ "$formal_answer_post_trigger" = true ]; then
    echo "==> Head $head_sha is already reviewed: a trusted formal review exists for this exact head; not re-requesting (issue #751)."
    echo "    (If the merge gate reported a BODY-ONLY finding, re-run with --fresh-review.)"
    return 0
  fi
  if [ "$head_review_status" -eq 0 ]; then
    echo "==> Head $head_sha already has a trusted formal review, but no durable request"
    echo "    evidence binds this head to base $base_sha; recording the request so the"
    echo "    merge gate can bind it."
  fi
  if [ "$matching_request" = true ] && [ "${FRESH_REVIEW:-false}" != true ]; then
    if [ "$request_consumed_by_dismissal" = true ]; then
      # The durable request was answered — and the answer was then dismissed.
      # "Answered" is anchored to the completed request's TRIGGER timestamp,
      # not its intent: a review submitted between intent and trigger predates
      # the @codex ask, so it was never this request's answer, and the real
      # answer is still in flight — consuming the request then would fire an
      # unnecessary replacement while it works (PR #755 review, round 8).
      # Skipping here would strand the head: the merge gate refuses dismissed
      # evidence, so no rerun of either script could ever produce a usable
      # result (PR #755 review). A revoked answer consumes its request.
      #
      # Consuming it must also RETIRE the old intent: the dismissal postdates
      # that intent forever, so reusing it would make every ordinary rerun in
      # the replacement window fire yet another request — a review-cycle spam
      # loop (PR #755 review, round 7). A fresh intent postdates the
      # dismissal, so the next rerun sees dismissed_at < intent_at and the
      # normal idempotent skip holds while the replacement review is awaited.
      echo "==> The review request for head $head_sha was answered by a review that was later"
      echo "    DISMISSED (at $OPEN_PR_HEAD_REVIEW_DISMISSED_AT). Revoked evidence consumes its"
      echo "    request; posting a fresh request intent and requesting a fresh review."
      intent_at=""
    else
      echo "==> GitHub Codex review already requested for head $head_sha at base $base_sha."
      # An unanswered request is only "in flight" until the stall threshold;
      # past it, absence must be distinguishable from latency (#759). Only a
      # definite no-review answer (status 1) reports — a failed lookup
      # (status 2) proves nothing about the reviewer.
      # Stall classification needs COMPLETE answer state: a failed comment
      # lookup is unknown, not absence, and must not spend a review cycle on
      # incomplete GitHub state; an answer PREDATING this request's trigger
      # answered an earlier ask, not this one (PR #781 review).
      if [ "$OPEN_PR_RESULT_COMMENT_LOOKUP_OK" != true ]; then
        echo "WARNING: comment-result lookup failed; stall detection (#759) skipped this run:"
        echo "         $OPEN_PR_RESULT_COMMENT_LOOKUP_ERROR"
      elif [ "$head_review_status" -ne 2 ] \
        && [ "$formal_answer_post_trigger" != true ] \
        && [ -n "$matching_trigger_at" ] \
        && { [ -z "$OPEN_PR_HEAD_RESULT_COMMENT_AT" ] \
          || ! [[ "$OPEN_PR_HEAD_RESULT_COMMENT_AT" > "$matching_trigger_at" ]]; }; then
        report_unanswered_request_stall "$matching_trigger_at" || return 1
      fi
      return 0
    fi
  fi
  if [ "${FRESH_REVIEW:-false}" = true ]; then
    if [ "$matching_request" = true ] && [ "$head_review_status" -ne 2 ] \
      && [ "$formal_answer_post_trigger" != true ] \
      && [ "$OPEN_PR_RESULT_COMMENT_LOOKUP_OK" = true ] \
      && { [ -z "$OPEN_PR_HEAD_RESULT_COMMENT_AT" ] \
        || ! [[ "$OPEN_PR_HEAD_RESULT_COMMENT_AT" > "$matching_trigger_at" ]]; }; then
      # Stall recovery (#759): the durable request for this exact head was
      # never answered, and the replacement ask must not reuse its intent —
      # matching_trigger_at anchors to the intent, so the stall clock would
      # keep dating the new request from the trigger the reviewer skipped.
      # Retire it the way dismissal-consumption retires consumed requests: a
      # fresh intent postdates the stall, the completion record binds the new
      # trigger to it, and the ordinary idempotent skip resumes.
      echo "==> --fresh-review: the review request for head $head_sha was never answered (#759);"
      echo "    retiring the stale request record and posting a fresh request intent."
      intent_at=""
    else
      echo "==> --fresh-review: forcing a new review request for head $head_sha despite existing evidence."
    fi
  fi

  # Round-budget gate (#760). By this point every idempotent skip has passed:
  # a real request WILL be posted. Spending it is the expensive act — each
  # round costs full review latency (#649), and past a small number of rounds
  # the findings historically stop being defects in the diff and start being
  # hardening of whatever the reviewer is looking at (#706: closed after 6;
  # #755: 7 rounds for a 60-line core). The budget forces the stop-and-decide
  # moment the process otherwise never has.
  #
  # An unknown round count (lookup failure, status 2 above) does not refuse:
  # this is friction control, not an authorization boundary — the merge gate
  # owns authorization.
  ROUND_BUDGET="${TOUCHSTONE_REVIEW_ROUND_BUDGET:-3}"
  # A malformed budget must fail loudly, not silently disable the cap: the
  # numeric -ge below would print a diagnostic and evaluate false, letting
  # every request through (PR #765 review).
  case "$ROUND_BUDGET" in
    '' | *[!0-9]*)
      echo "ERROR: TOUCHSTONE_REVIEW_ROUND_BUDGET must be a non-negative integer; got '$ROUND_BUDGET' (#760)." >&2
      return 1
      ;;
  esac
  if [ "${OPEN_PR_TRUSTED_REVIEW_ROUNDS:-0}" -ge "$ROUND_BUDGET" ] \
    && [ -z "$ROUND_BUDGET_OVERRIDE" ]; then
    echo "ERROR: PR #$pr_number has already spent $OPEN_PR_TRUSTED_REVIEW_ROUNDS review round(s); the budget is $ROUND_BUDGET (#760)." >&2
    # Does ANY post-trigger answer exist for this head, on either channel?
    # That is the one predicate this side can compute soundly. Whether the
    # merge gate ACCEPTS that answer (clean vs body-only, same-second ties,
    # an active CHANGES_REQUESTED) is the gate's own verdict — three review
    # rounds of trying to mirror it here each found another divergence, and
    # replicating the reviewer-semantics layer in a second place is exactly
    # what #734 exists to delete. So: no answer at all -> the deadlock exit
    # is certain; an answer exists -> the exits text states both outcomes
    # conditionally instead of guessing the gate's verdict; lookups failed
    # -> unknown, conservative (PR #781 review, rounds 2-3).
    head_answer_state=none
    if [ "$OPEN_PR_RESULT_COMMENT_LOOKUP_OK" != true ] || [ "$head_review_status" -eq 2 ]; then
      head_answer_state=unknown
    elif [ "$formal_answer_post_trigger" = true ]; then
      head_answer_state=answered
    elif [ -n "$OPEN_PR_HEAD_RESULT_COMMENT_AT" ] \
      && { [ -z "$matching_trigger_at" ] \
        || [[ "$OPEN_PR_HEAD_RESULT_COMMENT_AT" > "$matching_trigger_at" ]]; }; then
      head_answer_state=answered
    fi
    if [ "$matching_request" != true ] || [ "$request_consumed_by_dismissal" = true ] \
      || [ "$head_answer_state" = none ]; then
      # The budget/evidence deadlock (#775): this head has no reviewer answer
      # the merge gate accepts (no request recorded, its answer was dismissed,
      # or the request was never answered — the #759 stall), so "run
      # merge-pr.sh" would bounce straight back here —
      # an error naming an unavailable remedy costs a full round-trip to
      # discover. The head-advances that create this state (rebase after the
      # base moved, a fix commit answering a finding) are this tooling's own
      # instructions, so the refusal names the one exit that exists.
      echo "       Head $head_sha has no reviewer answer the merge gate can accept (no" >&2
      echo "       request recorded, answer dismissed, or request never answered), so" >&2
      echo "       'merge if answered' is NOT available: the merge gate would" >&2
      echo "       refuse this head and send you back here — the budget/evidence deadlock" >&2
      echo "       (#775). A head advanced by rebase or a finding-fix after the budget was" >&2
      echo "       spent is following this tooling's own instructions; the sanctioned path" >&2
      echo "       is to spend the round deliberately:" >&2
      echo "         bash scripts/open-pr.sh --round-budget-override \\" >&2
      echo "           \"head advanced by rebase/fix after budget spent; prior rounds reviewed the substance\"" >&2
      echo "       Adjust the reason to what actually happened — it is recorded in the" >&2
      echo "       PR-visible request comment. Splitting the PR or closing it (the #706" >&2
      echo "       pattern) remain available if the diff outgrew what prior rounds reviewed." >&2
    else
      echo "       Requesting another round is usually the wrong move. The legitimate exits:" >&2
      echo "         1. Merge if answered — every thread resolved satisfies the gate (issue #751);" >&2
      echo "            run: bash scripts/merge-pr.sh $pr_number" >&2
      echo "            If the gate REFUSES the current answer (a body-only result, a" >&2
      echo "            same-second tie, or an active CHANGES_REQUESTED), its remedy needs a" >&2
      echo "            fresh review — past budget that is the override below, with the" >&2
      echo "            gate's refusal as the reason." >&2
      echo "         2. Split the PR — the diff is carrying more than one concern." >&2
      echo "         3. Close it, preserving the corpus on the tracking issue (the #706 pattern)." >&2
      echo "       Findings that harden a component the plan deletes belong on the owning" >&2
      echo "       issue, not in this diff (principles/git-workflow.md)." >&2
      echo "       To spend the round anyway, state why:" >&2
      echo "         bash scripts/open-pr.sh --round-budget-override \"<reason>\"" >&2
    fi
    return 1
  fi
  if [ -n "$ROUND_BUDGET_OVERRIDE" ] && [ "${OPEN_PR_TRUSTED_REVIEW_ROUNDS:-0}" -ge "$ROUND_BUDGET" ]; then
    echo "==> Round budget ($ROUND_BUDGET) exceeded deliberately: $ROUND_BUDGET_OVERRIDE"
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
  if [ -n "$ROUND_BUDGET_OVERRIDE" ]; then
    # The override reason is part of the durable record: whoever audits the
    # PR sees who chose to spend a past-budget round and why (#760).
    body="$(printf '%s\n\nRound-budget override: %s' "$body" "$ROUND_BUDGET_OVERRIDE")"
  fi
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
# worktree is recoverable with `git worktree remove`.
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
  if (cd "$default_path" && git worktree remove "$current_path"); then
    echo "==> Worktree removed."
  else
    echo "WARNING: git worktree remove failed for $current_path." >&2
    echo "         Inspect it, then run 'git -C $default_path worktree remove $current_path'." >&2
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
  --fresh-review      Force a new review request even when this head already has
                      trusted review evidence (the body-only-finding escape). On a
                      requested-but-unanswered head it retires the stale request
                      record and re-asks without a new commit (the #759 stall
                      recovery).
  --round-budget-override <reason>
                      Spend a review round past the per-PR budget (#760). The
                      reason is recorded in the PR-visible request comment.
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
# --fresh-review: force a new review request even when the head already has a
# trusted review and matching durable evidence. This is the escape hatch for
# BODY-ONLY findings (PR #755 review): the merge gate cannot accept them via
# thread resolution, and the per-head idempotency would otherwise skip the
# re-request — leaving the driver in a loop where the gate says "request a
# fresh review" and this script answers "already reviewed". It is also the
# stall recovery (#759): on a requested-but-unanswered head it retires the
# stale request record and re-asks without a new commit. Bounded: it spends
# exactly one request, and nothing advertises it except the body-only block
# and the stall report.
FRESH_REVIEW=false
# --round-budget-override "<reason>": the review-round budget (#760) refuses
# to request review round N+1 (default 3) on one PR. Past budget the
# legitimate exits are merge-if-answered, split the PR, or close it
# preserving the corpus — spending another round requires a stated reason,
# recorded in the PR-visible request comment.
ROUND_BUDGET_OVERRIDE=""
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
    --fresh-review)
      FRESH_REVIEW=true
      shift
      ;;
    --round-budget-override)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "ERROR: --round-budget-override requires a reason." >&2
        exit 1
      fi
      ROUND_BUDGET_OVERRIDE="$2"
      shift 2
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

# Stacking + --auto-merge means THIS PR squash-merges into $BASE_BRANCH, not
# into $DEFAULT_BRANCH. That is no longer dangerous — merge-pr.sh retains the
# head branch after merge (and refuses under repository-level auto-delete), so
# the old warning that squash orphans stacked children is obsolete (issue
# #713, PR #715 review) — but it is worth saying out loud, because "merged"
# here does not mean "landed on $DEFAULT_BRANCH".
if [ "$BASE_BRANCH" != "$DEFAULT_BRANCH" ] && [ "$AUTO_MERGE" = true ]; then
  echo "NOTE: base $BASE_BRANCH + --auto-merge merges this PR into $BASE_BRANCH, not $DEFAULT_BRANCH." >&2
  echo "      Head branches are retained on merge, so this cannot close a stacked child;" >&2
  echo "      children stay based on the retained branch and need retargeting" >&2
  echo "      (gh pr edit <n> --base ...) plus a rebase once their parent lands." >&2
  if [ -n "$EXISTING_PR_URL" ]; then
    EXISTING_PR_NUMBER="$(basename "$EXISTING_PR_URL")"
    echo "      To ship straight to $DEFAULT_BRANCH instead: gh pr edit $EXISTING_PR_NUMBER --base $DEFAULT_BRANCH" >&2
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
    if ! patch_text="$(GIT_NO_REPLACE_OBJECTS=1 git diff-tree --no-commit-id --full-index -p -U3 "$commit" 2>&1)"; then
      echo "ERROR: could not compute the patch for commit ${commit:0:12}:" >&2
      printf '%s\n' "$patch_text" | sed 's/^/       /' >&2
      return 1
    fi
    # An empty patch carries no provable content; the caller refuses.
    [ -n "$patch_text" ] || return 2
    printf '%s\n' "$patch_text" \
      | sed -e '/^index /d' -e 's/^@@ .*@@/@@/' \
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
    if ! resolve_merge_authorizer "$BASE_BRANCH"; then
      exit 1
    fi
    MERGE_SCRIPT="$TRUSTED_MERGE_SCRIPT"
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
  if ! resolve_merge_authorizer "$BASE_BRANCH"; then
    exit 1
  fi
  MERGE_SCRIPT="$TRUSTED_MERGE_SCRIPT"
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
