#!/usr/bin/env bash
# Diff, apply, verify, back up, or roll back Touchstone's GitHub policy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
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

api_raw() {
  gh api -H "Accept:application/vnd.github.raw+json" \
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

normalize_branch_protection() {
  jq -S 'if . == null then null else .required_signatures = (.required_signatures // false) end'
}

signature_protection_enabled() {
  local endpoint error raw status=0
  endpoint="repos/$ORG/$REPOSITORY/branches/$BRANCH/protection/required_signatures"
  error="$(mktemp)" || return $?
  raw="$(api "$endpoint" --jq '.enabled // false' 2>"$error")" || status=$?
  if [ "$status" -eq 0 ]; then
    rm -f "$error"
    printf '%s\n' "$raw"
    return 0
  fi
  if grep -q 'HTTP 404' "$error"; then
    rm -f "$error"
    printf 'false\n'
    return 0
  fi
  cat "$error" >&2
  rm -f "$error"
  return "$status"
}

organization_ruleset_named() {
  local name="$1" list ids count id
  list="$(api --paginate "orgs/$ORG/rulesets" | jq -s 'add // []')" || return $?
  ids="$(jq -c --arg name "$name" '[.[] | select(.name == $name) | .id]' <<<"$list")" \
    || return $?
  count="$(jq -r length <<<"$ids")" || return $?
  if [ "$count" -eq 0 ]; then
    printf 'null\n'
  elif [ "$count" -eq 1 ]; then
    id="$(jq -r '.[0]' <<<"$ids")" || return $?
    api "orgs/$ORG/rulesets/$id"
  else
    die "more than one organization ruleset is named $name"
  fi
}

managed_ruleset_json() {
  organization_ruleset_named "$RULESET_NAME"
}

# GitHub accepts the merge_queue rule only in repository rulesets, never in an
# organization ruleset (verified 2026-08-20: identical payload, 422 at the
# organization endpoint). The queue therefore lives in a companion repository
# ruleset managed alongside the organization one: same backup, apply, verify,
# and rollback transaction.
repository_ruleset_named() {
  local repository="$1" name="$2" list ids count id
  list="$(api --paginate "repos/$ORG/$repository/rulesets?includes_parents=false" | jq -s 'add // []')" || return $?
  ids="$(jq -c --arg name "$name" '[.[] | select(.name == $name) | .id]' <<<"$list")" \
    || return $?
  count="$(jq -r length <<<"$ids")" || return $?
  if [ "$count" -eq 0 ]; then
    printf 'null\n'
  elif [ "$count" -eq 1 ]; then
    id="$(jq -r '.[0]' <<<"$ids")" || return $?
    api "repos/$ORG/$repository/rulesets/$id"
  else
    die "more than one repository ruleset is named $name"
  fi
}

managed_repo_ruleset_json() {
  repository_ruleset_named "$REPOSITORY" "$REPO_RULESET_NAME"
}

repo_ruleset_payload() {
  jq '{name,target,enforcement,bypass_actors:(.bypass_actors // []),conditions,rules}'
}

verify_repo_ruleset_against() {
  local expected="$1" current effective required
  current="$(managed_repo_ruleset_json)" || return $?
  if [ "$expected" = null ]; then
    [ "$current" = null ] || die "companion repository ruleset exists when none was expected"
    return 0
  fi
  [ "$current" != null ] || die "companion repository ruleset is missing"
  diff -u <(normalize_ruleset <<<"$expected") <(normalize_ruleset <<<"$current") >/dev/null \
    || die "companion repository ruleset differs from expected policy"
  effective="$(api "repos/$ORG/$REPOSITORY/rules/branches/$BRANCH")" || return $?
  while IFS= read -r required; do
    jq -e --arg type "$required" 'any(.[]; .type == $type)' <<<"$effective" >/dev/null \
      || die "effective policy is missing $required"
  done < <(jq -r '.rules[].type' <<<"$expected")
}

# Create or replace the companion ruleset so it matches $1; delete it when $1
# is null. Verified afterwards in every case.
restore_repo_ruleset() {
  local expected="$1" current payload
  current="$(managed_repo_ruleset_json)" || return $?
  if [ "$expected" = null ]; then
    if [ "$current" != null ]; then
      api --method DELETE "repos/$ORG/$REPOSITORY/rulesets/$(jq -r .id <<<"$current")" || return $?
    fi
  else
    payload="$(repo_ruleset_payload <<<"$expected")" || return $?
    if [ "$current" = null ]; then
      printf '%s\n' "$payload" \
        | api --method POST "repos/$ORG/$REPOSITORY/rulesets" --input - >/dev/null || return $?
    elif ! diff -q <(normalize_ruleset <<<"$expected") <(normalize_ruleset <<<"$current") >/dev/null; then
      printf '%s\n' "$payload" \
        | api --method PUT "repos/$ORG/$REPOSITORY/rulesets/$(jq -r .id <<<"$current")" --input - >/dev/null \
        || return $?
    fi
  fi
  verify_repo_ruleset_against "$expected"
}

# The merge queue admits a pull request through auto-merge, so the repository
# setting must allow it; without it every `pr merge` fails with "Auto merge
# is not allowed for this repository". Set and verified with the rulesets.
verify_auto_merge_allowed() {
  local allowed
  allowed="$(api "repos/$ORG/$REPOSITORY" --jq '.allow_auto_merge')" || return $?
  [ "$allowed" = true ] || die "repository setting allow_auto_merge is off; pull requests land through it (the queue admits through it, and without a queue touchstone pr merge arms it)"
}

auto_merge_setting() {
  api "repos/$ORG/$REPOSITORY" --jq '.allow_auto_merge'
}

set_auto_merge() {
  local desired="$1" current
  current="$(auto_merge_setting)" || return $?
  [ "$current" = "$desired" ] && return 0
  api --method PATCH "repos/$ORG/$REPOSITORY" -F "allow_auto_merge=$desired" >/dev/null
}

ensure_auto_merge_allowed() {
  local allowed
  allowed="$(api "repos/$ORG/$REPOSITORY" --jq '.allow_auto_merge')" || return $?
  if [ "$allowed" != true ]; then
    api --method PATCH "repos/$ORG/$REPOSITORY" -F allow_auto_merge=true >/dev/null || return $?
  fi
  verify_auto_merge_allowed
}

branch_protection_json() {
  local raw error
  error="$(mktemp)" || return $?
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
    }
    + (if .required_pull_request_reviews.dismissal_restrictions then {
        dismissal_restrictions: {
          users: ([.required_pull_request_reviews.dismissal_restrictions.users[]?.login] | sort),
          teams: ([.required_pull_request_reviews.dismissal_restrictions.teams[]?.slug] | sort),
          apps: ([.required_pull_request_reviews.dismissal_restrictions.apps[]?.slug] | sort)
        }
      } else {} end)
    + (if .required_pull_request_reviews.bypass_pull_request_allowances then {
        bypass_pull_request_allowances: {
          users: ([.required_pull_request_reviews.bypass_pull_request_allowances.users[]?.login] | sort),
          teams: ([.required_pull_request_reviews.bypass_pull_request_allowances.teams[]?.slug] | sort),
          apps: ([.required_pull_request_reviews.bypass_pull_request_allowances.apps[]?.slug] | sort)
        }
      } else {} end)
    else null end),
    restrictions: (if .restrictions then {
      users: ([.restrictions.users[]?.login] | sort),
      teams: ([.restrictions.teams[]?.slug] | sort),
      apps: ([.restrictions.apps[]?.slug] | sort)
    } else null end),
    required_linear_history: (.required_linear_history.enabled // false),
    required_signatures: (.required_signatures.enabled // false),
    allow_force_pushes: (.allow_force_pushes.enabled // false),
    allow_deletions: (.allow_deletions.enabled // false),
    block_creations: (.block_creations.enabled // false),
    required_conversation_resolution: (.required_conversation_resolution.enabled // false),
    lock_branch: (.lock_branch.enabled // false),
    allow_fork_syncing: (.allow_fork_syncing.enabled // false)
  }' <<<"$raw"
}

workflow_source_policy_path() {
  local repository="$1" branch="$2" candidate match="" count=0
  for candidate in "$ROOT"/policy/github/workflow-sources/*.json; do
    [ -f "$candidate" ] || continue
    if jq -e --arg org "$ORG" --arg repo "$repository" --arg branch "$branch" '
      .policyType == "workflow-source"
      and .organization == $org
      and .repository == $repo
      and .branch == $branch
    ' "$candidate" >/dev/null; then
      match="$candidate"
      count=$((count + 1))
    fi
  done
  if [ "$count" -gt 1 ]; then
    echo "ERROR: workflow-source target has ambiguous checked-in policy inventory: $ORG/$repository@$branch" >&2
    return 2
  fi
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$match"
}

verify_installed_workflow_source_policy() {
  local repository="$1" branch="$2" source_policy expected_org expected_repo actual_org actual_repo effective required allowed policy_status=0
  source_policy="$(workflow_source_policy_path "$repository" "$branch")" || policy_status=$?
  case "$policy_status" in
    0) ;;
    1) return 3 ;;
    *) die "could not resolve checked-in workflow-source policy: $ORG/$repository@$branch" ;;
  esac
  expected_org="$(jq -c .managedRuleset "$source_policy")" || return $?
  expected_repo="$(jq -c .managedRepositoryRuleset "$source_policy")" || return $?
  actual_org="$(organization_ruleset_named "$(jq -r .name <<<"$expected_org")")" || return $?
  actual_repo="$(repository_ruleset_named "$repository" "$(jq -r .name <<<"$expected_repo")")" || return $?
  if [ "$actual_org" = null ] && [ "$actual_repo" = null ]; then
    return 3
  fi
  [ "$actual_org" != null ] && [ "$actual_repo" != null ] \
    || die "workflow source has only part of its checked-in ruleset policy installed: $ORG/$repository@$branch"
  diff -u <(normalize_ruleset <<<"$expected_org") <(normalize_ruleset <<<"$actual_org") >/dev/null \
    || die "workflow source organization ruleset differs from checked-in policy: $ORG/$repository@$branch"
  diff -u <(normalize_ruleset <<<"$expected_repo") <(normalize_ruleset <<<"$actual_repo") >/dev/null \
    || die "workflow source repository ruleset differs from checked-in policy: $ORG/$repository@$branch"
  effective="$(api "repos/$ORG/$repository/rules/branches/$branch")" || return $?
  while IFS= read -r required; do
    jq -e --arg type "$required" 'any(.[]; .type == $type)' <<<"$effective" >/dev/null \
      || die "workflow source effective policy is missing $required: $ORG/$repository@$branch"
  done < <(
    jq -r '.rules[].type' <<<"$expected_org"
    jq -r '.rules[].type' <<<"$expected_repo"
  )
  allowed="$(api "repos/$ORG/$repository" --jq '.allow_auto_merge')" || return $?
  [ "$allowed" = true ] \
    || die "workflow source policy is installed but allow_auto_merge is off: $ORG/$repository@$branch"
}

verify_required_workflow_source_protection() {
  local repository="$1" branch="$2" desired_protection actual_protection error status=0 ruleset_status=0
  verify_installed_workflow_source_policy "$repository" "$branch" || ruleset_status=$?
  case "$ruleset_status" in
    0) return 0 ;;
    3) ;;
    *) die "could not verify workflow source ruleset policy: $ORG/$repository@$branch" ;;
  esac
  error="$(mktemp)" || return $?
  actual_protection="$(api "repos/$ORG/$repository/branches/$branch/protection" 2>"$error")" || status=$?
  if [ "$status" -ne 0 ]; then
    cat "$error" >&2
    rm -f "$error"
    die "required workflow source has neither its checked-in ruleset policy nor readable legacy branch protection: $ORG/$repository@$branch"
  fi
  rm -f "$error"
  desired_protection="$(jq -S '.workflowSource.branchProtection' "$POLICY")"
  actual_protection="$(jq -S '{
    enforce_admins: (.enforce_admins.enabled // false),
    required_pull_request_reviews: (.required_pull_request_reviews != null),
    required_conversation_resolution: (.required_conversation_resolution.enabled // false),
    allow_force_pushes: (.allow_force_pushes.enabled // false),
    allow_deletions: (.allow_deletions.enabled // false)
  }' <<<"$actual_protection")"
  diff -u <(printf '%s\n' "$desired_protection") <(printf '%s\n' "$actual_protection") >/dev/null \
    || die "required workflow source legacy branch protection differs from checked-in policy"
}

verify_required_workflow_source() {
  local workflow repository_id path ref sha actual_id actual_sha count source_refs
  local manifest_path expected_behavior_version manifest pinned_shas
  count="$(jq -r '[.managedRuleset.rules[] | select(.type == "workflows") | .parameters.workflows[]] | length' "$POLICY")"
  [ "$count" -ge 1 ] || die "policy requires at least one required workflow"
  [ "$WORKFLOW_SOURCE_REPOSITORY" != "$REPOSITORY" ] \
    || die "required workflow source repository must differ from the target repository"
  jq -e '
    (.workflowSource.sourceContract | keys == ["gateBehaviorContractVersion", "manifestPath"])
    and (.workflowSource.sourceContract.manifestPath
      | type == "string"
      and test("^[A-Za-z0-9._/-]+$")
      and startswith("/") == false
      and (split("/") | index("..") == null))
    and (.workflowSource.sourceContract.gateBehaviorContractVersion
      | type == "number" and floor == . and . >= 1)
  ' "$POLICY" >/dev/null || die "consumer policy has an invalid workflow source contract declaration"
  manifest_path="$(policy_value .workflowSource.sourceContract.manifestPath)"
  expected_behavior_version="$(policy_value .workflowSource.sourceContract.gateBehaviorContractVersion)"
  actual_id="$(api "repos/$ORG/$WORKFLOW_SOURCE_REPOSITORY" --jq .id)"
  # Every required workflow is checked the same way: pinned to a full SHA
  # that exists, carries the file, and is reachable from the source branch.
  while IFS= read -r workflow; do
    repository_id="$(jq -r .repository_id <<<"$workflow")"
    path="$(jq -r .path <<<"$workflow")"
    ref="$(jq -r .ref <<<"$workflow")"
    sha="$(jq -r .sha <<<"$workflow")"
    [[ "$sha" =~ ^[0-9a-fA-F]{40}$ ]] || die "required workflow SHA for $path is not a full commit ID"
    [ "$actual_id" = "$repository_id" ] || die "required workflow repository id is stale for $path"
    actual_sha="$(api "repos/$ORG/$WORKFLOW_SOURCE_REPOSITORY/commits/${ref#refs/heads/}" --jq .sha)"
    api "repos/$ORG/$WORKFLOW_SOURCE_REPOSITORY/contents/$path?ref=$sha" --jq '.type == "file"' | grep -qx true \
      || die "required workflow $path does not exist at pinned SHA $sha"
    api "repos/$ORG/$WORKFLOW_SOURCE_REPOSITORY/compare/$sha...$actual_sha" --jq '.status == "ahead" or .status == "identical"' \
      | grep -qx true \
      || die "required workflow SHA $sha for $path is not reachable from $ref"
  done < <(jq -c '.managedRuleset.rules[] | select(.type == "workflows") | .parameters.workflows[]' "$POLICY")
  pinned_shas="$(jq -r '[.managedRuleset.rules[] | select(.type == "workflows") | .parameters.workflows[].sha] | unique[]' "$POLICY")"
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    manifest="$(api_raw "repos/$ORG/$WORKFLOW_SOURCE_REPOSITORY/contents/$manifest_path?ref=$sha")" \
      || die "could not read workflow source contract manifest at pinned revision $sha: $manifest_path"
    jq -e --argjson expected "$expected_behavior_version" '
      .contractVersion == 1
      and .gateBehaviorContractVersion == $expected
    ' <<<"$manifest" >/dev/null \
      || die "workflow source contract at pinned revision $sha does not declare supported gate behavior contract $expected_behavior_version"
  done <<<"$pinned_shas"
  source_refs="$(jq -r '[.managedRuleset.rules[] | select(.type == "workflows") | .parameters.workflows[].ref] | unique[]' "$POLICY")"
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case "$ref" in refs/heads/*) ;;
    *) die "required workflow ref is not a branch: $ref" ;;
    esac
    verify_required_workflow_source_protection "$WORKFLOW_SOURCE_REPOSITORY" "${ref#refs/heads/}"
  done <<<"$source_refs"
}

verify_workflow_source_contract() {
  local canonical_policy manifest_path expected_behavior_version manifest context workflow_count status_context_count source_tree declared_workflows live_workflows
  canonical_policy="$(workflow_source_policy_path "$REPOSITORY" "$BRANCH")" \
    || die "workflow-source target must have exactly one checked-in policy inventory entry: $ORG/$REPOSITORY@$BRANCH"
  diff -q <(jq -S . "$canonical_policy") <(jq -S . "$POLICY") >/dev/null \
    || die "workflow-source policy differs from its checked-in inventory entry: $canonical_policy"

  manifest_path="$(policy_value .sourceContract.manifestPath)"
  expected_behavior_version="$(policy_value .sourceContract.gateBehaviorContractVersion)"
  jq -e '
    .policyType == "workflow-source"
    and (.sourceContract | keys == ["gateBehaviorContractVersion", "manifestPath"])
    and (.sourceContract.manifestPath
      | type == "string"
      and test("^[A-Za-z0-9._/-]+$")
      and startswith("/") == false
      and (split("/") | index("..") == null))
    and (.sourceContract.gateBehaviorContractVersion
      | type == "number" and floor == . and . >= 1)
  ' "$POLICY" >/dev/null || die "workflow-source policy has an invalid source contract declaration"

  workflow_count="$(jq -r '[.managedRuleset.rules[] | select(.type == "workflows") | .parameters.workflows[]?] | length' "$POLICY")"
  [ "$workflow_count" -eq 0 ] \
    || die "workflow-source policy must not require a workflow from its own repository"

  jq -e '
    any(.managedRuleset.rules[]; .type == "deletion")
    and any(.managedRuleset.rules[]; .type == "non_fast_forward")
    and any(.managedRuleset.rules[];
      .type == "pull_request"
      and .parameters.required_review_thread_resolution == true)
    and any(.managedRepositoryRuleset.rules[]?; .type == "merge_queue")
  ' "$POLICY" >/dev/null \
    || die "workflow-source policy requires deletion, non-fast-forward, pull-request thread resolution, and merge queue rules"

  manifest="$(api_raw "repos/$ORG/$REPOSITORY/contents/$manifest_path?ref=$BRANCH")" \
    || die "could not read workflow source contract manifest: $manifest_path"
  jq -e --arg repository "$ORG/$REPOSITORY" --argjson expected "$expected_behavior_version" '
    . as $contract
    | .contractVersion == 1
    and .gateBehaviorContractVersion == $expected
    and (.requiredStatusCheck | type == "string" and length > 0)
    and .sourceRepository == $repository
    and (.statusJob | type == "string" and test("^[A-Za-z_][A-Za-z0-9_-]*$"))
    and (.statusPublisher | type == "string")
    and (.workflowPaths | type == "array" and length > 0 and length == (unique | length))
    and ($contract.workflowPaths | index($contract.statusPublisher) != null)
    and all(.workflowPaths[];
      type == "string"
      and test("^\\.github/workflows/[^/]+\\.ya?ml$"))
  ' <<<"$manifest" >/dev/null || die "workflow source contract manifest is malformed: $manifest_path"
  source_tree="$(api "repos/$ORG/$REPOSITORY/git/trees/$BRANCH?recursive=1")" \
    || die "could not enumerate workflow source repository tree at $BRANCH"
  jq -e '.truncated == false and (.tree | type == "array")' <<<"$source_tree" >/dev/null \
    || die "workflow source repository tree is incomplete at $BRANCH"
  declared_workflows="$(jq -c '.workflowPaths | sort' <<<"$manifest")"
  live_workflows="$(jq -c '[
    .tree[]
    | select(.type == "blob")
    | .path
    | select(test("^\\.github/workflows/[^/]+\\.ya?ml$"))
  ] | sort' <<<"$source_tree")"
  [ "$live_workflows" = "$declared_workflows" ] \
    || die "workflow source live inventory differs from its manifest (live: $live_workflows; declared: $declared_workflows)"
  context="$(jq -er .requiredStatusCheck <<<"$manifest")"
  status_context_count="$(jq -r --arg context "$context" '
    [.managedRuleset.rules[]
      | select(.type == "required_status_checks")
      | .parameters.required_status_checks[]
      | select(.context == $context)]
    | length
  ' "$POLICY")"
  [ "$status_context_count" -eq 1 ] \
    || die "workflow-source policy must require the manifest status context exactly once: $context"
}

verify_source() {
  case "$POLICY_TYPE" in
    consumer) verify_required_workflow_source ;;
    workflow-source) verify_workflow_source_contract ;;
    *) die "unsupported policy type: $POLICY_TYPE" ;;
  esac
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

verify_rollback_removal_planned() {
  local prerequisite path committed
  while IFS= read -r prerequisite; do
    path="$(jq -r .path <<<"$prerequisite")" || return $?
    committed="$(git -C "$ROOT" ls-tree -r --name-only HEAD -- "$path")" || return $?
    [ -z "$committed" ] \
      || die "remove rollback prerequisite in the reviewed apply revision: $path"
  done < <(jq -c '.rollbackPrerequisites.repositoryFiles[]?' "$POLICY")
}

verify_clean_checkout() {
  local status tool_git_root version
  tool_git_root="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$tool_git_root" ] && [ -d "$tool_git_root" ]; then
    tool_git_root="$(cd "$tool_git_root" && pwd -P)"
  fi
  if [ "$tool_git_root" = "$ROOT" ]; then
    status="$(git -C "$ROOT" status --porcelain --untracked-files=normal)" || return $?
    [ -z "$status" ] || die "policy mutation requires a clean reviewed checkout"
    return 0
  fi

  # A release archive (including Hesperus's signed bundled copy) has no Git
  # metadata. Its checksum or app signature is the reviewed-source boundary;
  # requiring a development checkout here would make the supported installed
  # API unusable. Refuse an incomplete or unnamed tree rather than silently
  # treating any directory outside Git as a release.
  version="$(head -n 1 "$ROOT/VERSION" 2>/dev/null || true)"
  printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || die "policy mutation requires a clean reviewed checkout or a complete Touchstone release"
  for required in bin/touchstone scripts/github-policy.sh scripts/derive-consumer-policy.sh policy/github/touchstone-main.json; do
    [ -r "$ROOT/$required" ] \
      || die "installed Touchstone release is incomplete: $required"
  done
}

verify_rollback_files_absent() {
  local prerequisite path error
  while IFS= read -r prerequisite; do
    path="$(jq -r .path <<<"$prerequisite")" || return $?
    error="$(mktemp)" || return $?
    if api "repos/$ORG/$REPOSITORY/contents/$path?ref=$BRANCH" >/dev/null 2>"$error"; then
      rm -f "$error"
      die "rollback prerequisite still exists on $BRANCH: $path"
    fi
    if ! grep -q 'HTTP 404' "$error"; then
      cat "$error" >&2
      rm -f "$error"
      die "could not verify rollback prerequisite removal: $path"
    fi
    rm -f "$error"
  done < <(jq -c '.rollbackPrerequisites.repositoryFiles[]?' "$POLICY")
}

verify_policy_state() {
  local expected_ruleset="$1" expected_protection="$2" expected_repo_ruleset="${3:-null}" actual_ruleset actual_protection
  actual_ruleset="$(managed_ruleset_json)" || return $?
  if [ "$expected_ruleset" = null ]; then
    [ "$actual_ruleset" = null ] || die "managed ruleset exists when none was expected"
  else
    verify_ruleset_against "$expected_ruleset" || return $?
  fi
  verify_repo_ruleset_against "$expected_repo_ruleset" || return $?
  actual_protection="$(branch_protection_json)" || return $?
  diff -u \
    <(normalize_branch_protection <<<"$expected_protection") \
    <(printf '%s\n' "$actual_protection") >&2 \
    || die "branch protection differs from expected policy state"
}

restore_branch_protection() {
  local protection="$1" expected_signatures actual_signatures signature_endpoint
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
    | api --method PUT "repos/$ORG/$REPOSITORY/branches/$BRANCH/protection" --input - >/dev/null \
    || return $?
  signature_endpoint="repos/$ORG/$REPOSITORY/branches/$BRANCH/protection/required_signatures"
  expected_signatures="$(jq -r '.required_signatures // false' <<<"$protection")" || return $?
  actual_signatures="$(signature_protection_enabled)" || return $?
  if [ "$expected_signatures" = true ] && [ "$actual_signatures" != true ]; then
    api --method POST "$signature_endpoint" >/dev/null || return $?
  elif [ "$expected_signatures" != true ] && [ "$actual_signatures" = true ]; then
    api --method DELETE "$signature_endpoint" >/dev/null || return $?
  fi
}

# Undo a bootstrap: delete the managed organization and repository rulesets
# this run created and put the auto-merge setting back. Nothing else existed.
# Every step is attempted even when an earlier one fails: the three are
# independent, and stopping at the first error would leave the rest behind
# with no report. Failures are named and the function returns nonzero once.
remove_bootstrapped_state() {
  local prior_auto_merge="$1" current current_repo failed=""
  if current="$(managed_ruleset_json)" && [ "$current" != null ]; then
    api --method DELETE "orgs/$ORG/rulesets/$(jq -r .id <<<"$current")" || failed="$failed organization-ruleset"
  elif [ -z "$current" ]; then
    failed="$failed organization-ruleset(read)"
  fi
  if current_repo="$(managed_repo_ruleset_json)" && [ "$current_repo" != null ]; then
    api --method DELETE "repos/$ORG/$REPOSITORY/rulesets/$(jq -r .id <<<"$current_repo")" || failed="$failed repository-ruleset"
  elif [ -z "$current_repo" ]; then
    failed="$failed repository-ruleset(read)"
  fi
  if [ -n "$prior_auto_merge" ]; then
    set_auto_merge "$prior_auto_merge" || failed="$failed auto-merge"
  fi
  if [ -n "$failed" ]; then
    echo "ERROR: bootstrap cleanup could not complete:$failed" >&2
    return 1
  fi
}

restore_policy_state() {
  local expected_ruleset="$1" expected_protection="$2" expected_repo_ruleset="${3:-null}" expected_auto_merge="${4:-}" current current_protection payload id
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
    payload="$(ruleset_update_payload <<<"$expected_ruleset")" || return $?
    if [ "$current" = null ]; then
      printf '%s\n' "$payload" \
        | api --method POST "orgs/$ORG/rulesets" --input - >/dev/null || return $?
    else
      id="$(jq -r .id <<<"$current")" || return $?
      printf '%s\n' "$payload" \
        | api --method PUT "orgs/$ORG/rulesets/$id" --input - >/dev/null || return $?
    fi
    verify_ruleset_against "$expected_ruleset" || return $?
  fi
  restore_repo_ruleset "$expected_repo_ruleset" || return $?
  if [ "$expected_protection" = null ]; then
    current_protection="$(branch_protection_json)" || return $?
    if [ "$current_protection" != null ]; then
      api --method DELETE "repos/$ORG/$REPOSITORY/branches/$BRANCH/protection" || return $?
    fi
  fi
  verify_policy_state "$expected_ruleset" "$expected_protection" "$expected_repo_ruleset" || return $?
  # Last, after every protective layer is back: a failure here leaves the
  # branch protected and reports the one setting that did not restore.
  if [ -n "$expected_auto_merge" ] && [ "$expected_auto_merge" != null ]; then
    set_auto_merge "$expected_auto_merge" || return $?
  fi
}

COMMAND="${1:-}"
[ -n "$COMMAND" ] || {
  usage
  exit 2
}
shift

# Re-running open pull requests' gates is the default because leaving them
# invalidated is the failure this exists to prevent. The escape is for an
# operator who wants the pin moved without touching pull requests.
RETRIGGER_OPEN_PRS=true
kept=()
for arg in "$@"; do
  if [ "$arg" = "--no-retrigger" ]; then
    RETRIGGER_OPEN_PRS=false
  else
    kept+=("$arg")
  fi
done
set -- "${kept[@]+"${kept[@]}"}"

# A repin invalidates gate evidence produced by the outgoing revision:
# touchstone pr status compares a run's workflow file revision against the
# revisions the effective ruleset pins, so every open pull request whose gate
# already passed reads as "unbound" the moment the pin moves. The check stays
# green in GitHub's UI, which is what makes it confusing -- an agent sees a
# passing gate and a CLI reporting no bound review, and reasonably concludes
# review never happened.
#
# Accepting the outgoing revision as well would be the cheap fix and the wrong
# one: a repin is often made precisely to replace a gate that was failing open,
# and evidence from that gate is exactly what must stop counting.
#
# So the evidence is regenerated rather than grandfathered. Closing and
# reopening re-runs the required workflows on the same head, which keeps the
# reviewed SHA; editing does not start a new run.
retrigger_open_pull_requests() {
  local open_prs number failed=0
  [ "${RETRIGGER_OPEN_PRS:-true}" = true ] || {
    echo "Skipping pull-request re-trigger (--no-retrigger); open pull requests keep evidence this apply invalidated."
    return 0
  }
  open_prs="$(api "repos/$ORG/$REPOSITORY/pulls?state=open&per_page=100" 2>/dev/null \
    | jq -r '[.[] | select(.draft | not) | .number] | join(" ")' 2>/dev/null)" || {
    echo "WARNING: could not list open pull requests in $ORG/$REPOSITORY; re-run their gates manually." >&2
    return 0
  }
  [ -n "$open_prs" ] && [ "$open_prs" != "" ] || return 0
  echo "Re-running required workflows on open pull requests whose evidence this apply invalidated:"
  for number in $open_prs; do
    if gh pr close "$number" --repo "$ORG/$REPOSITORY" >/dev/null 2>&1 \
      && sleep 2 \
      && gh pr reopen "$number" --repo "$ORG/$REPOSITORY" >/dev/null 2>&1; then
      echo "  re-triggered #$number"
      # Every re-trigger starts a gate run that calls the review provider.
      # Firing them all at once is a burst on a shared rate limit, and a burst
      # is exactly what trips it. Space them out.
      sleep "${RETRIGGER_SPACING_SECONDS:-20}"
    else
      echo "  WARNING: could not re-trigger #$number; close and reopen it to re-run its gate." >&2
      failed=1
    fi
  done
  [ "$failed" -eq 0 ] || echo "Some pull requests were not re-triggered; their gates report a passing check and an unbound gate until they are." >&2
}

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
need git
need jq
need diff
jq -e '.contractVersion == 1' "$POLICY" >/dev/null || die "unsupported policy contract"
ORG="$(policy_value .organization)"
REPOSITORY="$(policy_value .repository)"
POLICY_TYPE="$(jq -er '.policyType // "consumer"' "$POLICY")"
case "$POLICY_TYPE" in
  consumer) WORKFLOW_SOURCE_REPOSITORY="$(policy_value .workflowSource.repository)" ;;
  workflow-source) WORKFLOW_SOURCE_REPOSITORY="" ;;
  *) die "unsupported policy type: $POLICY_TYPE" ;;
esac
BRANCH="$(policy_value .branch)"
CONTRACT_VERSION="$(policy_value .contractVersion)"
RULESET_NAME="$(policy_value .managedRuleset.name)"
EXPECTED_RULESET_NAME="Touchstone policy v$CONTRACT_VERSION: $ORG/$REPOSITORY@$BRANCH"
[ "$RULESET_NAME" = "$EXPECTED_RULESET_NAME" ] \
  || die "managed ruleset name must be the ownership marker: $EXPECTED_RULESET_NAME"
jq -e '.managedRuleset.rules | all(.type != "merge_queue")' "$POLICY" >/dev/null \
  || die "merge_queue belongs in managedRepositoryRuleset: GitHub rejects it in an organization ruleset"
# The companion's name is the ownership marker, derived from the policy
# coordinates rather than read from the desired block: a policy that removes
# the companion must still find and delete the one it installed.
REPO_RULESET_NAME="Touchstone merge queue v$CONTRACT_VERSION: $ORG/$REPOSITORY@$BRANCH"
if jq -e '.managedRepositoryRuleset != null' "$POLICY" >/dev/null; then
  [ "$(jq -r '.managedRepositoryRuleset.name // empty' "$POLICY")" = "$REPO_RULESET_NAME" ] \
    || die "companion repository ruleset name must be the ownership marker: $REPO_RULESET_NAME"
fi
DESIRED_REPO_RULESET="$(jq -c '.managedRepositoryRuleset // null' "$POLICY")"

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
    current_repo="$(managed_repo_ruleset_json)"
    [ "$current_repo" = null ] || current_repo="$(normalize_ruleset <<<"$current_repo")"
    desired_repo=null
    [ "$DESIRED_REPO_RULESET" = null ] || desired_repo="$(normalize_ruleset <<<"$DESIRED_REPO_RULESET")"
    diff -u -L current-repository -L desired-repository \
      <(printf '%s\n' "$current_repo") <(printf '%s\n' "$desired_repo") || [ "$?" -eq 1 ]
    ;;
  dry-run)
    verify_rollback_removal_planned
    verify_source
    "$0" diff "$POLICY"
    echo "Would install/replace organization ruleset: $RULESET_NAME"
    current_auto_merge="$(auto_merge_setting)" || die "could not read the repository's auto-merge setting"
    [ "$current_auto_merge" = true ] \
      || echo "Would enable the repository setting allow_auto_merge (pull requests land through it: the queue admits through it, and without a queue touchstone pr merge arms it)."
    if [ "$DESIRED_REPO_RULESET" != null ]; then
      echo "Would install/replace repository ruleset: $REPO_RULESET_NAME"
    elif [ "$(managed_repo_ruleset_json)" != null ]; then
      echo "Would DELETE repository ruleset: $REPO_RULESET_NAME (policy no longer declares it)"
    fi
    echo "Would verify the active effective rules before removing legacy branch protection."
    ;;
  backup)
    [ ! -e "$ARTIFACT" ] || die "backup already exists: $ARTIFACT"
    mkdir -p "$(dirname "$ARTIFACT")"
    branch="$(branch_protection_json)"
    managed="$(managed_ruleset_json)"
    managed_repo="$(managed_repo_ruleset_json)"
    auto_merge="$(auto_merge_setting)" || die "could not read the repository's auto-merge setting"
    if [ "$branch" = null ]; then
      rollback_prerequisites='{}'
    else
      rollback_prerequisites="$(jq -c '.rollbackPrerequisites // {}' "$POLICY")"
    fi
    repository_rulesets="$(api "repos/$ORG/$REPOSITORY/rulesets?includes_parents=false")"
    effective_rulesets="$(api "repos/$ORG/$REPOSITORY/rulesets?includes_parents=true")"
    jq -n --argjson branch "$branch" --argjson managed "$managed" --argjson managedRepo "$managed_repo" --argjson autoMerge "$auto_merge" \
      --argjson rollbackPrerequisites "$rollback_prerequisites" \
      --argjson repositoryRulesets "$repository_rulesets" --argjson effectiveRulesets "$effective_rulesets" \
      --arg org "$ORG" --arg repository "$REPOSITORY" --arg branchName "$BRANCH" \
      '{contractVersion:1,capturedAt:(now|todate),organization:$org,repository:$repository,branch:$branchName,
        rollbackPrerequisites:$rollbackPrerequisites,
        branchProtection:$branch,repositoryRulesets:$repositoryRulesets,effectiveRulesets:$effectiveRulesets,
        managedOrganizationRuleset:$managed,managedRepositoryRuleset:$managedRepo,allowAutoMerge:$autoMerge}' >"$ARTIFACT"
    echo "Wrote backup: $ARTIFACT"
    ;;
  apply)
    verify_clean_checkout
    verify_rollback_removal_planned
    verify_source
    desired="$(jq -c '.managedRuleset' "$POLICY")"
    source_ruleset="$(managed_ruleset_json)"
    source_protection="$(branch_protection_json)"
    source_repo_ruleset="$(managed_repo_ruleset_json)"
    source_auto_merge="$(auto_merge_setting)" || die "could not read the repository's auto-merge setting"
    # A repository with neither a managed ruleset nor legacy protection is a
    # fresh consumer: there is nothing to replace, so the install is a
    # bootstrap. Its failure path is the mirror image -- remove what this run
    # created -- because "restore the prior state" means restoring nothing,
    # which restore_policy_state rightly refuses for a replacement.
    bootstrap=false
    if [ "$source_ruleset" = null ] && [ "$source_protection" = null ]; then
      # A companion repository ruleset with no organization ruleset is an
      # interrupted earlier adoption, not a bare repository: bootstrapping
      # over it would make a later failure delete state this run did not
      # create. Route it to manual recovery instead of guessing.
      [ "$source_repo_ruleset" = null ] \
        || die "no organization ruleset or branch protection, but the companion repository ruleset already exists; remove it or restore the organization ruleset from a backup (rollback) before applying"
      bootstrap=true
      echo "No prior protection on $ORG/$REPOSITORY@$BRANCH: installing the policy fresh (bootstrap)."
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
      restore_repo_ruleset "$DESIRED_REPO_RULESET" || exit $?
      # Auto-merge is how a PR lands in both shapes: the queue admits through
      # it, and a queue-less consumer's `touchstone pr merge` arms it so the
      # merge waits for the required workflows instead of being refused.
      ensure_auto_merge_allowed || exit $?
      if [ "$source_protection" != null ]; then
        api --method DELETE "repos/$ORG/$REPOSITORY/branches/$BRANCH/protection" || exit $?
      fi
      verify_policy_state "$desired" null "$DESIRED_REPO_RULESET" || exit $?
    ); then
      if [ "$bootstrap" = true ]; then
        (remove_bootstrapped_state "$source_auto_merge") \
          || die "bootstrap failed and the rulesets it created could not be removed; inspect $ORG/$REPOSITORY rulesets"
        die "bootstrap failed; the rulesets it created were removed and the repository is as it was"
      fi
      (restore_policy_state "$source_ruleset" "$source_protection" "$source_repo_ruleset" "$source_auto_merge") \
        || die "policy replacement failed and the complete prior state could not be restored"
      die "policy replacement failed; the complete prior policy state was restored"
    fi
    echo "Applied and verified GitHub policy without legacy branch protection."
    retrigger_open_pull_requests
    echo "Merge the reviewed rollback-prerequisite removal, then run verify."
    ;;
  verify)
    verify_source
    verify_ruleset
    verify_repo_ruleset_against "$DESIRED_REPO_RULESET"
    verify_auto_merge_allowed
    [ "$(branch_protection_json)" = null ] || die "legacy branch protection still duplicates the ruleset"
    verify_rollback_files_absent
    echo "Verified legacy branch protection is absent."
    echo "Verified rollback prerequisite files are absent from $BRANCH."
    ;;
  rollback)
    jq -e '.contractVersion == 1' "$ARTIFACT" >/dev/null || die "unsupported backup contract"
    [ "$(jq -r .organization "$ARTIFACT")" = "$ORG" ] || die "backup organization does not match policy"
    [ "$(jq -r .repository "$ARTIFACT")" = "$REPOSITORY" ] || die "backup repository does not match policy"
    [ "$(jq -r .branch "$ARTIFACT")" = "$BRANCH" ] || die "backup branch does not match policy"
    before="$(jq -c .managedOrganizationRuleset "$ARTIFACT")"
    before_repo="$(jq -c '.managedRepositoryRuleset // null' "$ARTIFACT")"
    # `//` treats false as absent; the setting is a real boolean.
    before_auto_merge="$(jq -r 'if has("allowAutoMerge") then .allowAutoMerge else "null" end' "$ARTIFACT")"
    protection="$(jq -c .branchProtection "$ARTIFACT")"
    if [ "$protection" = null ] && [ "$before" = null ]; then
      die "backup contains no branch protection or managed ruleset to restore"
    fi
    verify_rollback_prerequisites "$ARTIFACT"
    source_ruleset="$(managed_ruleset_json)"
    source_protection="$(branch_protection_json)"
    source_repo_ruleset="$(managed_repo_ruleset_json)"
    source_auto_merge="$(auto_merge_setting)" || die "could not read the repository's auto-merge setting"
    if [ "$source_ruleset" = null ] && [ "$source_protection" = null ]; then
      die "current policy state has no protection to preserve"
    fi
    if ! (
      if [ "$protection" != null ]; then
        restore_branch_protection "$protection" || exit $?
        verify_policy_state "$source_ruleset" "$protection" "$source_repo_ruleset" || exit $?
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
      restore_repo_ruleset "$before_repo" || exit $?
      if [ "$before_auto_merge" != null ]; then set_auto_merge "$before_auto_merge" || exit $?; fi
      if [ "$protection" = null ]; then
        current_protection="$(branch_protection_json)" || exit $?
        if [ "$current_protection" != null ]; then
          api --method DELETE "repos/$ORG/$REPOSITORY/branches/$BRANCH/protection" || exit $?
        fi
      fi
      verify_policy_state "$before" "$protection" "$before_repo" || exit $?
    ); then
      (restore_policy_state "$source_ruleset" "$source_protection" "$source_repo_ruleset" "$source_auto_merge") \
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
