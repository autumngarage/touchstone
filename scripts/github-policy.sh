#!/usr/bin/env bash
# Diff, apply, verify, back up, or roll back Touchstone's GitHub policy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_POLICY="$ROOT/policy/github/touchstone-main.json"
API_VERSION="2026-03-10"

usage() {
  cat <<'EOF'
Usage:
  scripts/github-policy.sh diff [policy.json]
  scripts/github-policy.sh dry-run [policy.json]
  scripts/github-policy.sh backup <output.json> [policy.json]
  scripts/github-policy.sh apply [policy.json]
  scripts/github-policy.sh verify [policy.json]
  scripts/github-policy.sh rollback <backup.json> [policy.json]

apply installs and verifies the organization ruleset before removing legacy
branch protection. rollback restores branch protection before changing the
ruleset, so neither direction creates an unprotected interval.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

api() {
  gh api -H "Accept:application/vnd.github+json" \
    -H "X-GitHub-Api-Version:$API_VERSION" "$@"
}

policy_value() {
  jq -er "$1" "$POLICY"
}

normalize_ruleset() {
  jq -S '{
    name,
    target,
    enforcement,
    bypass_actors: ((.bypass_actors // []) | sort_by([.actor_type, (.actor_id // 0 | tostring), .bypass_mode])),
    conditions: (.conditions
      | if .repository_name then
          (.repository_name.include |= sort) | (.repository_name.exclude |= sort)
        else . end
      | if .repository_id then (.repository_id.repository_ids |= sort) else . end
      | (.ref_name.include |= sort) | (.ref_name.exclude |= sort)),
    rules: ((.rules // [])
      | map(
          if .type == "pull_request" then
            (.parameters.allowed_merge_methods |= sort)
          elif .type == "required_status_checks" then
            (.parameters.required_status_checks |= sort_by([.context, (.integration_id // 0)]))
          elif .type == "workflows" then
            (.parameters.workflows |= sort_by([.repository_id, .path, (.ref // ""), (.sha // "")]))
          else . end)
      | sort_by(.type))
  }'
}

managed_ruleset_json() {
  local list ids count id
  list="$(api --paginate "orgs/$ORG/rulesets" | jq -s 'add // []')"
  ids="$(jq -c --arg name "$RULESET_NAME" '[.[] | select(.name == $name) | .id]' <<<"$list")"
  count="$(jq -r length <<<"$ids")"
  if [ "$count" -eq 0 ]; then
    printf 'null\n'
  elif [ "$count" -eq 1 ]; then
    id="$(jq -r '.[0]' <<<"$ids")"
    api "orgs/$ORG/rulesets/$id"
  else
    die "more than one organization ruleset is named $RULESET_NAME"
  fi
}

branch_protection_json() {
  local raw error
  error="$(mktemp)"
  if ! raw="$(api "repos/$ORG/$REPOSITORY/branches/$BRANCH/protection" 2>"$error")"; then
    if grep -q 'HTTP 404' "$error"; then
      rm -f "$error"
      printf 'null\n'
      return
    fi
    cat "$error" >&2
    rm -f "$error"
    die "could not read legacy branch protection"
  fi
  rm -f "$error"
  jq -S '{
    required_status_checks: (if .required_status_checks then {
      strict: .required_status_checks.strict,
      checks: (.required_status_checks.checks | sort_by(.context))
    } else null end),
    enforce_admins: (.enforce_admins.enabled // false),
    required_pull_request_reviews: (if .required_pull_request_reviews then {
      dismiss_stale_reviews: .required_pull_request_reviews.dismiss_stale_reviews,
      require_code_owner_reviews: .required_pull_request_reviews.require_code_owner_reviews,
      required_approving_review_count: .required_pull_request_reviews.required_approving_review_count,
      require_last_push_approval: .required_pull_request_reviews.require_last_push_approval
    } else null end),
    restrictions: .restrictions,
    required_linear_history: (.required_linear_history.enabled // false),
    allow_force_pushes: (.allow_force_pushes.enabled // false),
    allow_deletions: (.allow_deletions.enabled // false),
    block_creations: (.block_creations.enabled // false),
    required_conversation_resolution: (.required_conversation_resolution.enabled // false),
    lock_branch: (.lock_branch.enabled // false),
    allow_fork_syncing: (.allow_fork_syncing.enabled // false)
  }' <<<"$raw"
}

verify_source() {
  local workflow repository_id path ref sha actual_id actual_sha
  workflow="$(jq -cer '.managedRuleset.rules[] | select(.type == "workflows") | .parameters.workflows[]' "$POLICY")"
  repository_id="$(jq -r .repository_id <<<"$workflow")"
  path="$(jq -r .path <<<"$workflow")"
  ref="$(jq -r .ref <<<"$workflow")"
  sha="$(jq -r .sha <<<"$workflow")"
  [[ "$sha" =~ ^[0-9a-fA-F]{40}$ ]] || die "required workflow SHA is not a full commit ID"
  actual_id="$(api "repos/$ORG/$WORKFLOW_SOURCE_REPOSITORY" --jq .id)"
  [ "$actual_id" = "$repository_id" ] || die "required workflow repository id is stale"
  actual_sha="$(api "repos/$ORG/$WORKFLOW_SOURCE_REPOSITORY/commits/${ref#refs/heads/}" --jq .sha)"
  api "repos/$ORG/$WORKFLOW_SOURCE_REPOSITORY/contents/$path?ref=$sha" --jq '.type == "file"' | grep -qx true \
    || die "required workflow does not exist at pinned SHA $sha"
  api "repos/$ORG/$WORKFLOW_SOURCE_REPOSITORY/compare/$sha...$actual_sha" --jq '.status == "ahead" or .status == "identical"' \
    | grep -qx true \
    || die "required workflow SHA $sha is not reachable from $ref"
}

verify_ruleset() {
  local desired current effective types
  desired="$(jq -S '.managedRuleset' "$POLICY" | normalize_ruleset)"
  current="$(managed_ruleset_json)"
  [ "$current" != null ] || die "managed organization ruleset is missing"
  diff -u <(printf '%s\n' "$desired") <(normalize_ruleset <<<"$current") >/dev/null \
    || die "managed organization ruleset differs from checked-in policy"
  effective="$(api "repos/$ORG/$REPOSITORY/rules/branches/$BRANCH")"
  types="$(jq -r '[.[].type] | unique | sort | join(",")' <<<"$effective")"
  for required in deletion non_fast_forward pull_request required_status_checks workflows; do
    jq -e --arg type "$required" 'any(.[]; .type == $type)' <<<"$effective" >/dev/null \
      || die "effective policy is missing $required"
  done
  echo "Verified effective rule types: $types"
}

restore_branch_protection() {
  local protection="$1"
  [ "$protection" != null ] || return 0
  jq '{
    required_status_checks,
    enforce_admins,
    required_pull_request_reviews,
    restrictions,
    required_linear_history,
    allow_force_pushes,
    allow_deletions,
    block_creations,
    required_conversation_resolution,
    lock_branch,
    allow_fork_syncing
  }' <<<"$protection" \
    | api --method PUT "repos/$ORG/$REPOSITORY/branches/$BRANCH/protection" --input - >/dev/null
}

COMMAND="${1:-}"
[ -n "$COMMAND" ] || {
  usage
  exit 2
}
shift

case "$COMMAND" in
  backup | rollback)
    ARTIFACT="${1:-}"
    [ -n "$ARTIFACT" ] || die "$COMMAND requires an artifact path"
    shift
    ;;
esac
POLICY="${1:-$DEFAULT_POLICY}"
[ "$#" -le 1 ] || die "too many arguments"
[ -f "$POLICY" ] || die "policy not found: $POLICY"

need gh
need jq
need diff
jq -e '.contractVersion == 1' "$POLICY" >/dev/null || die "unsupported policy contract"
ORG="$(policy_value .organization)"
REPOSITORY="$(policy_value .repository)"
WORKFLOW_SOURCE_REPOSITORY="$(policy_value .workflowSourceRepository)"
BRANCH="$(policy_value .branch)"
RULESET_NAME="$(policy_value .managedRuleset.name)"

case "$COMMAND" in
  diff)
    desired="$(jq -S '.managedRuleset' "$POLICY" | normalize_ruleset)"
    current="$(managed_ruleset_json)"
    if [ "$current" = null ]; then
      current='null'
    else
      current="$(normalize_ruleset <<<"$current")"
    fi
    diff -u --label current --label desired \
      <(printf '%s\n' "$current") <(printf '%s\n' "$desired") || [ "$?" -eq 1 ]
    ;;
  dry-run)
    verify_source
    "$0" diff "$POLICY"
    echo "Would install/replace organization ruleset: $RULESET_NAME"
    echo "Would verify the active effective rules before removing legacy branch protection."
    ;;
  backup)
    [ ! -e "$ARTIFACT" ] || die "backup already exists: $ARTIFACT"
    mkdir -p "$(dirname "$ARTIFACT")"
    branch="$(branch_protection_json)"
    managed="$(managed_ruleset_json)"
    repository_rulesets="$(api "repos/$ORG/$REPOSITORY/rulesets?includes_parents=false")"
    effective_rulesets="$(api "repos/$ORG/$REPOSITORY/rulesets?includes_parents=true")"
    jq -n --argjson branch "$branch" --argjson managed "$managed" \
      --argjson repositoryRulesets "$repository_rulesets" --argjson effectiveRulesets "$effective_rulesets" \
      --arg org "$ORG" --arg repository "$REPOSITORY" --arg branchName "$BRANCH" \
      '{contractVersion:1,capturedAt:(now|todate),organization:$org,repository:$repository,branch:$branchName,
        branchProtection:$branch,repositoryRulesets:$repositoryRulesets,effectiveRulesets:$effectiveRulesets,
        managedOrganizationRuleset:$managed}' >"$ARTIFACT"
    echo "Wrote backup: $ARTIFACT"
    ;;
  apply)
    verify_source
    desired="$(jq -c '.managedRuleset' "$POLICY")"
    current="$(managed_ruleset_json)"
    if [ "$current" = null ]; then
      jq -c '.managedRuleset' "$POLICY" \
        | api --method POST "orgs/$ORG/rulesets" --input - >/dev/null
    else
      ruleset_id="$(jq -r .id <<<"$current")"
      if ! diff -q \
        <(printf '%s\n' "$desired" | normalize_ruleset) \
        <(printf '%s\n' "$current" | normalize_ruleset) >/dev/null; then
        printf '%s\n' "$desired" \
          | api --method PUT "orgs/$ORG/rulesets/$ruleset_id" --input - >/dev/null
      fi
    fi
    verify_ruleset
    if [ "$(branch_protection_json)" != null ]; then
      api --method DELETE "repos/$ORG/$REPOSITORY/branches/$BRANCH/protection"
    fi
    "$0" verify "$POLICY"
    ;;
  verify)
    verify_source
    verify_ruleset
    [ "$(branch_protection_json)" = null ] || die "legacy branch protection still duplicates the ruleset"
    echo "Verified legacy branch protection is absent."
    ;;
  rollback)
    jq -e '.contractVersion == 1' "$ARTIFACT" >/dev/null || die "unsupported backup contract"
    [ "$(jq -r .organization "$ARTIFACT")" = "$ORG" ] || die "backup organization does not match policy"
    [ "$(jq -r .repository "$ARTIFACT")" = "$REPOSITORY" ] || die "backup repository does not match policy"
    [ "$(jq -r .branch "$ARTIFACT")" = "$BRANCH" ] || die "backup branch does not match policy"
    before="$(jq -c .managedOrganizationRuleset "$ARTIFACT")"
    protection="$(jq -c .branchProtection "$ARTIFACT")"
    if [ "$protection" = null ] && [ "$before" = null ]; then
      die "backup contains no branch protection or managed ruleset to restore"
    fi
    restore_branch_protection "$protection"
    current="$(managed_ruleset_json)"
    if [ "$before" = null ] && [ "$current" != null ]; then
      api --method DELETE "orgs/$ORG/rulesets/$(jq -r .id <<<"$current")"
    elif [ "$before" != null ]; then
      restore_payload="$(jq 'del(.id,.node_id,.source_type,.source,._links,.created_at,.updated_at)' <<<"$before")"
      if [ "$current" = null ]; then
        printf '%s\n' "$restore_payload" | api --method POST "orgs/$ORG/rulesets" --input - >/dev/null
      else
        printf '%s\n' "$restore_payload" \
          | api --method PUT "orgs/$ORG/rulesets/$(jq -r .id <<<"$current")" --input - >/dev/null
      fi
    fi
    restored_managed="$(managed_ruleset_json)"
    if [ "$before" = null ]; then
      [ "$restored_managed" = null ] || die "rollback left the replacement ruleset installed"
    else
      [ "$restored_managed" != null ] || die "rollback did not restore the captured ruleset"
      diff -u \
        <(normalize_ruleset <<<"$before") \
        <(normalize_ruleset <<<"$restored_managed") >/dev/null \
        || die "rollback managed ruleset does not match backup"
    fi
    restored="$(branch_protection_json)"
    expected="$(jq -S .branchProtection "$ARTIFACT")"
    diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$restored") >/dev/null \
      || die "rollback branch protection does not match backup"
    echo "Rollback matches captured branch protection."
    ;;
  *)
    usage
    exit 2
    ;;
esac
