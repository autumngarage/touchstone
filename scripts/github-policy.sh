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
            | (.parameters.required_reviewers = (.parameters.required_reviewers // []))
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
    restrictions: (if .restrictions then {
      users: ([.restrictions.users[]?.login] | sort),
      teams: ([.restrictions.teams[]?.slug] | sort),
      apps: ([.restrictions.apps[]?.slug] | sort)
    } else null end),
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
  local workflow repository_id path ref sha actual_id actual_sha desired_protection actual_protection
  workflow="$(jq -cer '.managedRuleset.rules[] | select(.type == "workflows") | .parameters.workflows[]' "$POLICY")"
  repository_id="$(jq -r .repository_id <<<"$workflow")"
  path="$(jq -r .path <<<"$workflow")"
  ref="$(jq -r .ref <<<"$workflow")"
  sha="$(jq -r .sha <<<"$workflow")"
  [[ "$sha" =~ ^[0-9a-fA-F]{40}$ ]] || die "required workflow SHA is not a full commit ID"
  [ "$WORKFLOW_SOURCE_REPOSITORY" != "$REPOSITORY" ] \
    || die "required workflow source repository must differ from the target repository"
  actual_id="$(api "repos/$ORG/$WORKFLOW_SOURCE_REPOSITORY" --jq .id)"
  [ "$actual_id" = "$repository_id" ] || die "required workflow repository id is stale"
  actual_sha="$(api "repos/$ORG/$WORKFLOW_SOURCE_REPOSITORY/commits/${ref#refs/heads/}" --jq .sha)"
  api "repos/$ORG/$WORKFLOW_SOURCE_REPOSITORY/contents/$path?ref=$sha" --jq '.type == "file"' | grep -qx true \
    || die "required workflow does not exist at pinned SHA $sha"
  api "repos/$ORG/$WORKFLOW_SOURCE_REPOSITORY/compare/$sha...$actual_sha" --jq '.status == "ahead" or .status == "identical"' \
    | grep -qx true \
    || die "required workflow SHA $sha is not reachable from $ref"
  desired_protection="$(jq -S '.workflowSource.branchProtection' "$POLICY")"
  actual_protection="$(api "repos/$ORG/$WORKFLOW_SOURCE_REPOSITORY/branches/${ref#refs/heads/}/protection" \
    | jq -S '{
      enforce_admins: (.enforce_admins.enabled // false),
      required_pull_request_reviews: (.required_pull_request_reviews != null),
      required_conversation_resolution: (.required_conversation_resolution.enabled // false),
      allow_force_pushes: (.allow_force_pushes.enabled // false),
      allow_deletions: (.allow_deletions.enabled // false)
    }')"
  diff -u <(printf '%s\n' "$desired_protection") <(printf '%s\n' "$actual_protection") >/dev/null \
    || die "required workflow source branch is not protected as checked in"
}

verify_ruleset_against() {
  local expected="$1" current effective types required
  current="$(managed_ruleset_json)" || return $?
  [ "$current" != null ] || die "managed organization ruleset is missing"
  diff -u <(normalize_ruleset <<<"$expected") <(normalize_ruleset <<<"$current") >/dev/null \
    || die "managed organization ruleset differs from expected policy"
  effective="$(api "repos/$ORG/$REPOSITORY/rules/branches/$BRANCH")" || return $?
  types="$(jq -r '[.[].type] | unique | sort | join(",")' <<<"$effective")"
  while IFS= read -r required; do
    jq -e --arg type "$required" 'any(.[]; .type == $type)' <<<"$effective" >/dev/null \
      || die "effective policy is missing $required"
  done < <(jq -r '.rules[].type' <<<"$expected")
  echo "Verified effective rule types: $types"
}

verify_ruleset() {
  verify_ruleset_against "$(jq -c '.managedRuleset' "$POLICY")"
}

ruleset_update_payload() {
  jq '{name,target,enforcement,bypass_actors,conditions,rules}'
}

verify_rollback_prerequisites() {
  local artifact="$1" prerequisite path expected_sha actual_sha
  while IFS= read -r prerequisite; do
    path="$(jq -r .path <<<"$prerequisite")"
    expected_sha="$(jq -r .sha <<<"$prerequisite")"
    if ! actual_sha="$(api "repos/$ORG/$REPOSITORY/contents/$path?ref=$BRANCH" --jq .sha)"; then
      die "rollback prerequisite is missing from $BRANCH: $path"
    fi
    [ "$actual_sha" = "$expected_sha" ] \
      || die "rollback prerequisite differs from the captured version: $path"
  done < <(jq -c '.rollbackPrerequisites.repositoryFiles[]?' "$artifact")
}

verify_policy_state() {
  local expected_ruleset="$1" expected_protection="$2" actual_ruleset actual_protection
  actual_ruleset="$(managed_ruleset_json)" || return $?
  if [ "$expected_ruleset" = null ]; then
    [ "$actual_ruleset" = null ] || die "managed ruleset exists when none was expected"
  else
    verify_ruleset_against "$expected_ruleset" || return $?
  fi
  actual_protection="$(branch_protection_json)" || return $?
  diff -u \
    <(jq -S . <<<"$expected_protection") \
    <(printf '%s\n' "$actual_protection") >/dev/null \
    || die "branch protection differs from expected policy state"
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

restore_policy_state() {
  local expected_ruleset="$1" expected_protection="$2" current current_protection payload id
  if [ "$expected_protection" != null ]; then
    restore_branch_protection "$expected_protection" || return $?
  fi
  current="$(managed_ruleset_json)" || return $?
  if [ "$expected_ruleset" = null ]; then
    [ "$expected_protection" != null ] || die "refusing to restore an unprotected policy state"
    if [ "$current" != null ]; then
      api --method DELETE "orgs/$ORG/rulesets/$(jq -r .id <<<"$current")" || return $?
    fi
  else
    payload="$(ruleset_update_payload <<<"$expected_ruleset")"
    if [ "$current" = null ]; then
      printf '%s\n' "$payload" \
        | api --method POST "orgs/$ORG/rulesets" --input - >/dev/null || return $?
    else
      id="$(jq -r .id <<<"$current")"
      printf '%s\n' "$payload" \
        | api --method PUT "orgs/$ORG/rulesets/$id" --input - >/dev/null || return $?
    fi
    verify_ruleset_against "$expected_ruleset" || return $?
  fi
  if [ "$expected_protection" = null ]; then
    current_protection="$(branch_protection_json)" || return $?
    if [ "$current_protection" != null ]; then
      api --method DELETE "repos/$ORG/$REPOSITORY/branches/$BRANCH/protection" || return $?
    fi
  fi
  verify_policy_state "$expected_ruleset" "$expected_protection" || return $?
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
WORKFLOW_SOURCE_REPOSITORY="$(policy_value .workflowSource.repository)"
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
    diff -u -L current -L desired \
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
    if [ "$branch" = null ]; then
      rollback_prerequisites='{}'
    else
      rollback_prerequisites="$(jq -c '.rollbackPrerequisites // {}' "$POLICY")"
    fi
    repository_rulesets="$(api "repos/$ORG/$REPOSITORY/rulesets?includes_parents=false")"
    effective_rulesets="$(api "repos/$ORG/$REPOSITORY/rulesets?includes_parents=true")"
    jq -n --argjson branch "$branch" --argjson managed "$managed" \
      --argjson rollbackPrerequisites "$rollback_prerequisites" \
      --argjson repositoryRulesets "$repository_rulesets" --argjson effectiveRulesets "$effective_rulesets" \
      --arg org "$ORG" --arg repository "$REPOSITORY" --arg branchName "$BRANCH" \
      '{contractVersion:1,capturedAt:(now|todate),organization:$org,repository:$repository,branch:$branchName,
        rollbackPrerequisites:$rollbackPrerequisites,
        branchProtection:$branch,repositoryRulesets:$repositoryRulesets,effectiveRulesets:$effectiveRulesets,
        managedOrganizationRuleset:$managed}' >"$ARTIFACT"
    echo "Wrote backup: $ARTIFACT"
    ;;
  apply)
    verify_source
    desired="$(jq -c '.managedRuleset' "$POLICY")"
    source_ruleset="$(managed_ruleset_json)"
    source_protection="$(branch_protection_json)"
    if [ "$source_ruleset" = null ] && [ "$source_protection" = null ]; then
      die "no existing protection is present to guard policy replacement"
    fi
    if ! (
      if [ "$source_ruleset" = null ]; then
        printf '%s\n' "$desired" \
          | api --method POST "orgs/$ORG/rulesets" --input - >/dev/null || exit $?
      elif ! diff -q \
        <(printf '%s\n' "$desired" | normalize_ruleset) \
        <(printf '%s\n' "$source_ruleset" | normalize_ruleset) >/dev/null; then
        printf '%s\n' "$desired" \
          | api --method PUT "orgs/$ORG/rulesets/$(jq -r .id <<<"$source_ruleset")" --input - >/dev/null \
          || exit $?
      fi
      verify_ruleset || exit $?
      if [ "$source_protection" != null ]; then
        api --method DELETE "repos/$ORG/$REPOSITORY/branches/$BRANCH/protection" || exit $?
      fi
      verify_policy_state "$desired" null || exit $?
    ); then
      (restore_policy_state "$source_ruleset" "$source_protection") \
        || die "policy replacement failed and the complete prior state could not be restored"
      die "policy replacement failed; the complete prior policy state was restored"
    fi
    echo "Applied and verified policy without legacy branch protection."
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
    verify_rollback_prerequisites "$ARTIFACT"
    source_ruleset="$(managed_ruleset_json)"
    source_protection="$(branch_protection_json)"
    if [ "$source_ruleset" = null ] && [ "$source_protection" = null ]; then
      die "current policy state has no protection to preserve"
    fi
    if ! (
      if [ "$protection" != null ]; then
        restore_branch_protection "$protection" || exit $?
        verify_policy_state "$source_ruleset" "$protection" || exit $?
      fi
      current="$(managed_ruleset_json)" || exit $?
      if [ "$before" = null ]; then
        [ "$protection" != null ] || die "rollback target contains no protection"
        if [ "$current" != null ]; then
          api --method DELETE "orgs/$ORG/rulesets/$(jq -r .id <<<"$current")" || exit $?
        fi
      else
        restore_payload="$(ruleset_update_payload <<<"$before")"
        if [ "$current" = null ]; then
          printf '%s\n' "$restore_payload" \
            | api --method POST "orgs/$ORG/rulesets" --input - >/dev/null || exit $?
        else
          printf '%s\n' "$restore_payload" \
            | api --method PUT "orgs/$ORG/rulesets/$(jq -r .id <<<"$current")" --input - >/dev/null \
            || exit $?
        fi
        verify_ruleset_against "$before" || exit $?
      fi
      if [ "$protection" = null ]; then
        current_protection="$(branch_protection_json)" || exit $?
        if [ "$current_protection" != null ]; then
          api --method DELETE "repos/$ORG/$REPOSITORY/branches/$BRANCH/protection" || exit $?
        fi
      fi
      verify_policy_state "$before" "$protection" || exit $?
    ); then
      (restore_policy_state "$source_ruleset" "$source_protection") \
        || die "rollback failed and the complete prior policy state could not be restored"
      die "rollback failed verification; the complete prior policy state was restored"
    fi
    echo "Rollback matches captured branch protection."
    ;;
  *)
    usage
    exit 2
    ;;
esac
