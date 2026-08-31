#!/usr/bin/env bash
# Offline lifecycle tests for the audited GitHub policy migration.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_SCRIPT="$ROOT/scripts/github-policy.sh"
SCRIPT="$SOURCE_SCRIPT"
POLICY="$ROOT/policy/github/touchstone-main.json"
SOURCE_POLICY="$ROOT/policy/github/workflow-sources/touchstone-workflows.json"
# The fake source repository serves exactly the pin the checked-in policy
# names, so bumping the pin never needs a matching edit here.
WORKFLOWS_PIN="$(jq -r '[.managedRuleset.rules[] | select(.type == "workflows") | .parameters.workflows[].sha] | unique | .[0]' "$POLICY")"
export WORKFLOWS_PIN
BASELINE="$ROOT/policy/github/baseline-2026-08-13.json"
ROLLBACK_VALIDATE="$ROOT/policy/github/rollback/validate.yml"
POLICY_GUIDE="$ROOT/policy/github/README.md"
SETUP="$ROOT/setup.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/state"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

ok() {
  echo "  OK: $*"
}

cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

method=GET
fields=""
endpoint=""
jq_filter=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    api) shift ;;
    -H) shift 2 ;;
    --method | -X) method="$2"; shift 2 ;;
    --input) shift 2 ;;
    --jq) jq_filter="$2"; shift 2 ;;
    -F | -f) fields="${fields:-} $2"; shift 2 ;;
    -*) shift ;;
    *) endpoint="$1"; shift ;;
  esac
done
[ -n "$endpoint" ] || exit 2
state="$GH_FAKE_STATE"

emit() {
  local json="$1"
  if [ -n "$jq_filter" ]; then
    jq -r "$jq_filter" <<<"$json"
  else
    printf '%s\n' "$json"
  fi
}

case "$method $endpoint" in
  "GET repos/autumngarage/touchstone-workflows")
    if [ -f "$state/source-auto-merge" ]; then
      emit '{"id":1333343261,"allow_auto_merge":true}'
    else
      emit '{"id":1333343261,"allow_auto_merge":false}'
    fi
    ;;
  "GET repos/autumngarage/touchstone")
    if [ -f "$state/auto-merge" ]; then emit '{"allow_auto_merge":true}'; else emit '{"allow_auto_merge":false}'; fi
    ;;
  "PATCH repos/autumngarage/touchstone")
    case "${fields:-}" in
      *allow_auto_merge=true*) touch "$state/auto-merge" ;;
      *allow_auto_merge=false*) rm -f "$state/auto-merge" ;;
    esac
    echo "PATCH repo-settings" >>"$state/mutations.log"
    emit '{"allow_auto_merge":true}'
    ;;
  "GET repos/autumngarage/touchstone-workflows/commits/main")
    emit "{\"sha\":\"$WORKFLOWS_PIN\"}"
    ;;
  "GET repos/autumngarage/touchstone-workflows/contents/.github/workflows/validate.yml?ref=$WORKFLOWS_PIN" | \
  "GET repos/autumngarage/touchstone-workflows/contents/.github/workflows/review-gate.yml?ref=$WORKFLOWS_PIN" | \
  "GET repos/autumngarage/touchstone-workflows/contents/.github/workflows/delivery-evidence.yml?ref=$WORKFLOWS_PIN")
    emit '{"type":"file"}'
    ;;
  "GET repos/autumngarage/touchstone/contents/.github/workflows/validate.yml?ref=main")
    if [ "${GH_FAKE_MISSING_ROLLBACK_FILE:-0}" = 1 ] || \
      [ -f "$state/local-workflow-absent" ]; then
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi
    emit "{\"type\":\"file\",\"sha\":\"${GH_FAKE_ROLLBACK_FILE_SHA:-c2dc082e0702090f3fc9de095d78a85ddde902a5}\"}"
    ;;
  "GET repos/autumngarage/touchstone/contents/.github/workflows/review-binding.yml?ref=main")
    if [ -f "$state/local-workflow-absent" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    emit '{"type":"file","sha":"a4c161279b39f0e7c301c46f3d474b83dc4b10d7"}'
    ;;
  "GET repos/autumngarage/touchstone/contents/.github/workflows/review-evidence-signal.yml?ref=main")
    if [ -f "$state/local-workflow-absent" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    emit '{"type":"file","sha":"3c34d7792afdc9c99c728b76bebe4e527a5db760"}'
    ;;
  "GET repos/autumngarage/touchstone/contents/.github/review-binding/evaluate.jq?ref=main")
    if [ -f "$state/local-workflow-absent" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    emit '{"type":"file","sha":"0f30e59859b936ca16a8d6f4dd8cb1e8960eb917"}'
    ;;
  "GET repos/autumngarage/touchstone/contents/.touchstone-source-contract.json?ref=main")
    jq -n --arg context "${GH_FAKE_SOURCE_STATUS_CONTEXT:-source contract}" \
      --argjson behaviorVersion "${GH_FAKE_GATE_BEHAVIOR_VERSION:-2}" '{
      contractVersion: 1,
      gateBehaviorContractVersion: $behaviorVersion,
      requiredStatusCheck: $context,
      sourceRepository: "autumngarage/touchstone-workflows",
      statusJob: "source-contract",
      statusPublisher: ".github/workflows/validate.yml",
      workflowPaths: [
        ".github/workflows/delivery-evidence.yml",
        ".github/workflows/review-gate.yml",
        ".github/workflows/validate.yml"
      ]
    }'
    ;;
  "GET repos/autumngarage/touchstone-workflows/contents/.touchstone-source-contract.json?ref=main" | \
  "GET repos/autumngarage/touchstone-workflows/contents/.touchstone-source-contract.json?ref=$WORKFLOWS_PIN")
    jq -n --arg context "${GH_FAKE_SOURCE_STATUS_CONTEXT:-source contract}" \
      --arg nested "${GH_FAKE_SOURCE_NESTED_WORKFLOW:-}" \
      --argjson behaviorVersion "${GH_FAKE_GATE_BEHAVIOR_VERSION:-2}" '{
      contractVersion: 1,
      gateBehaviorContractVersion: $behaviorVersion,
      requiredStatusCheck: $context,
      sourceRepository: "autumngarage/touchstone-workflows",
      statusJob: "source-contract",
      statusPublisher: ".github/workflows/validate.yml",
      workflowPaths: ([
        ".github/workflows/delivery-evidence.yml",
        ".github/workflows/review-gate.yml",
        ".github/workflows/validate.yml"
      ] + (if $nested == "" then [] else [$nested] end))
    }'
    ;;
  "GET repos/autumngarage/touchstone-workflows/git/trees/main?recursive=1")
    jq -n --arg extra "${GH_FAKE_SOURCE_EXTRA_WORKFLOW:-}" \
      --arg nested "${GH_FAKE_SOURCE_NESTED_WORKFLOW:-}" '{
      truncated: false,
      tree: ([
        {path: ".github/workflows/delivery-evidence.yml", type: "blob"},
        {path: ".github/workflows/review-gate.yml", type: "blob"},
        {path: ".github/workflows/validate.yml", type: "blob"}
      ]
      + (if $extra == "" then [] else [{path: $extra, type: "blob"}] end)
      + (if $nested == "" then [] else [{path: $nested, type: "blob"}] end))
    }'
    ;;
  "GET repos/autumngarage/touchstone-workflows/compare/$WORKFLOWS_PIN...$WORKFLOWS_PIN")
    emit '{"status":"identical"}'
    ;;
  "GET repos/autumngarage/touchstone-workflows/branches/main/protection")
    if [ -f "$state/source-ruleset.json" ]; then
      echo "gh: Branch not protected (HTTP 404)" >&2
      exit 1
    elif [ "${GH_FAKE_SOURCE_UNPROTECTED:-0}" = 1 ]; then
      emit '{"enforce_admins":{"enabled":false},"required_pull_request_reviews":null,"required_conversation_resolution":{"enabled":false},"allow_force_pushes":{"enabled":true},"allow_deletions":{"enabled":true}}'
    else
      emit '{"enforce_admins":{"enabled":true},"required_pull_request_reviews":{},"required_conversation_resolution":{"enabled":true},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}'
    fi
    ;;
  "GET orgs/autumngarage/rulesets")
    if [ "${GH_FAKE_SOURCE_RULESET_READ_ERROR:-0}" = 1 ] \
      && [ ! -f "$state/source-ruleset-read-error-used" ]; then
      touch "$state/source-ruleset-read-error-used"
      echo "gh: API unavailable (HTTP 503)" >&2
      exit 1
    elif [ "${GH_FAKE_DUPLICATE_RULESET:-0}" = 1 ]; then
      emit '[{"id":123,"name":"Touchstone policy v1: autumngarage/touchstone@main"},{"id":124,"name":"Touchstone policy v1: autumngarage/touchstone@main"}]'
    elif [ "${GH_FAKE_UNRELATED_NAME_COLLISION:-0}" = 1 ]; then
      emit '[{"id":777,"name":"Touchstone main delivery"}]'
    else
      rulesets='[]'
      if [ -f "$state/ruleset.json" ]; then
        rulesets="$(jq --argjson current "$rulesets" '$current + [{id:.id,name:.name}]' "$state/ruleset.json")"
      fi
      if [ -f "$state/source-ruleset.json" ]; then
        rulesets="$(jq --argjson current "$rulesets" '$current + [{id:.id,name:.name}]' "$state/source-ruleset.json")"
      fi
      emit "$rulesets"
    fi
    ;;
  "GET orgs/autumngarage/rulesets/123")
    cat "$state/ruleset.json"
    ;;
  "GET orgs/autumngarage/rulesets/777")
    emit '{"id":777,"name":"Touchstone main delivery","target":"branch","enforcement":"active","bypass_actors":[],"conditions":{"repository_name":{"include":["other-repository"],"exclude":[],"protected":false},"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"deletion"}]}'
    ;;
  "GET orgs/autumngarage/rulesets/456")
    cat "$state/source-ruleset.json"
    ;;
  "POST orgs/autumngarage/rulesets")
    # GitHub fills in defaults the caller omitted: required_reviewers, and
    # since 2026-08 require_extra_approval_for_unattributed_changes. The
    # policy must carry what GitHub will echo back, or apply never verifies.
    jq '(.rules[] | select(.type == "pull_request") | .parameters) |= (. + {required_reviewers: [], require_extra_approval_for_unattributed_changes: (.require_extra_approval_for_unattributed_changes // true)}) | . + {id:123}' >"$state/ruleset.json"
    echo "POST org-ruleset" >>"$state/mutations.log"
    if [ "${GH_FAKE_FAIL_ORG_MUTATION_ONCE:-0}" = 1 ] && [ ! -f "$state/org-mutation-failed" ]; then
      touch "$state/org-mutation-failed"
      echo "gh: API unavailable after mutation (HTTP 503)" >&2
      exit 1
    fi
    emit "$(cat "$state/ruleset.json")"
    ;;
  "PUT orgs/autumngarage/rulesets/123")
    jq '(.rules[] | select(.type == "pull_request") | .parameters) |= (. + {required_reviewers: [], require_extra_approval_for_unattributed_changes: (.require_extra_approval_for_unattributed_changes // true)}) | . + {id:123}' >"$state/ruleset.json"
    echo "PUT org-ruleset" >>"$state/mutations.log"
    if [ "${GH_FAKE_FAIL_ORG_MUTATION_ONCE:-0}" = 1 ] && [ ! -f "$state/org-mutation-failed" ]; then
      touch "$state/org-mutation-failed"
      echo "gh: API unavailable after mutation (HTTP 503)" >&2
      exit 1
    fi
    emit "$(cat "$state/ruleset.json")"
    ;;
  "PUT orgs/autumngarage/rulesets/777")
    cat >/dev/null
    echo "PUT unrelated-ruleset" >>"$state/mutations.log"
    emit '{"id":777}'
    ;;
  "DELETE orgs/autumngarage/rulesets/123")
    if [ "${GH_FAKE_FAIL_ORG_DELETE:-0}" = 1 ]; then
      echo "gh: Server error (HTTP 500)" >&2
      exit 1
    fi
    rm -f "$state/ruleset.json"
    echo "DELETE org-ruleset" >>"$state/mutations.log"
    ;;
  "GET repos/autumngarage/touchstone/branches/main/protection")
    if [ "${GH_FAKE_BRANCH_ERROR:-0}" = 1 ]; then
      echo "gh: API unavailable (HTTP 503)" >&2
      exit 1
    fi
    if [ -n "${GH_FAKE_BRANCH_ERROR_ON_CALL:-}" ]; then
      branch_calls=0
      [ ! -f "$state/branch-calls" ] || branch_calls="$(cat "$state/branch-calls")"
      branch_calls=$((branch_calls + 1))
      printf '%s\n' "$branch_calls" >"$state/branch-calls"
      if [ "$branch_calls" -eq "$GH_FAKE_BRANCH_ERROR_ON_CALL" ]; then
        echo "gh: API unavailable (HTTP 503)" >&2
        exit 1
      fi
    fi
    if [ ! -f "$state/branch.json" ]; then
      echo "gh: Branch not protected (HTTP 404)" >&2
      exit 1
    fi
    cat "$state/branch.json"
    ;;
  "GET repos/autumngarage/touchstone/branches/main/protection/required_signatures")
    if [ ! -f "$state/branch.json" ]; then
      echo "gh: Branch not protected (HTTP 404)" >&2
      exit 1
    fi
    if [ "${GH_FAKE_SIGNATURE_ERROR:-0}" = 1 ]; then
      echo "gh: signature protection unavailable (HTTP 503)" >&2
      exit 1
    fi
    if ! jq -e '.required_signatures.enabled == true' "$state/branch.json" >/dev/null; then
      echo "gh: Signature protection not enabled (HTTP 404)" >&2
      exit 1
    fi
    emit '{"enabled":true}'
    ;;
  "PUT repos/autumngarage/touchstone/branches/main/protection")
    payload="$(cat)"
    if [ "${GH_FAKE_FAIL_BRANCH_PUT_ONCE:-0}" = 1 ] && [ ! -f "$state/branch-put-failed" ]; then
      touch "$state/branch-put-failed"
      echo "gh: branch protection unavailable (HTTP 503)" >&2
      exit 1
    fi
    if [ -f "$state/branch.json" ]; then
      current_signatures="$(jq -c '.required_signatures // {enabled:false}' "$state/branch.json")"
    else
      current_signatures='{"enabled":false}'
    fi
    jq -e '
      .restrictions == null or
      ((.restrictions.users + .restrictions.teams + .restrictions.apps) |
        all(.[]; type == "string"))
    ' <<<"$payload" >/dev/null || {
      echo "gh: restrictions must use login or slug strings (HTTP 422)" >&2
      exit 1
    }
    jq -e '
      .required_pull_request_reviews == null or
      ([
        .required_pull_request_reviews.dismissal_restrictions?,
        .required_pull_request_reviews.bypass_pull_request_allowances?
      ] | map(select(. != null)) |
        all(.[]; ((.users + .teams + .apps) | all(.[]; type == "string"))))
    ' <<<"$payload" >/dev/null || {
      echo "gh: review exceptions must use login or slug strings (HTTP 422)" >&2
      exit 1
    }
    jq --argjson current_signatures "$current_signatures" '{
      required_status_checks: .required_status_checks,
      enforce_admins: {enabled:.enforce_admins},
      required_pull_request_reviews: (if .required_pull_request_reviews then
        .required_pull_request_reviews
        | if .dismissal_restrictions then .dismissal_restrictions = {
            users: [.dismissal_restrictions.users[] | {login:.}],
            teams: [.dismissal_restrictions.teams[] | {slug:.}],
            apps: [.dismissal_restrictions.apps[] | {slug:.}]
          } else . end
        | if .bypass_pull_request_allowances then .bypass_pull_request_allowances = {
            users: [.bypass_pull_request_allowances.users[] | {login:.}],
            teams: [.bypass_pull_request_allowances.teams[] | {slug:.}],
            apps: [.bypass_pull_request_allowances.apps[] | {slug:.}]
          } else . end
        else null end),
      restrictions: (if .restrictions then {
        users: [.restrictions.users[] | {login:.}],
        teams: [.restrictions.teams[] | {slug:.}],
        apps: [.restrictions.apps[] | {slug:.}]
      } else null end),
      required_linear_history: {enabled:.required_linear_history},
      required_signatures: $current_signatures,
      allow_force_pushes: {enabled:.allow_force_pushes},
      allow_deletions: {enabled:.allow_deletions},
      block_creations: {enabled:.block_creations},
      required_conversation_resolution: {enabled:.required_conversation_resolution},
      lock_branch: {enabled:.lock_branch},
      allow_fork_syncing: {enabled:.allow_fork_syncing}
    }' <<<"$payload" >"$state/branch.json"
    echo "PUT branch-protection" >>"$state/mutations.log"
    ;;
  "POST repos/autumngarage/touchstone/branches/main/protection/required_signatures")
    jq '.required_signatures = {enabled:true}' "$state/branch.json" >"$state/branch-signed.json"
    mv "$state/branch-signed.json" "$state/branch.json"
    echo "POST required-signatures" >>"$state/mutations.log"
    emit '{"enabled":true}'
    ;;
  "DELETE repos/autumngarage/touchstone/branches/main/protection/required_signatures")
    jq '.required_signatures = {enabled:false}' "$state/branch.json" >"$state/branch-unsigned.json"
    mv "$state/branch-unsigned.json" "$state/branch.json"
    echo "DELETE required-signatures" >>"$state/mutations.log"
    ;;
  "DELETE repos/autumngarage/touchstone/branches/main/protection")
    rm -f "$state/branch.json"
    echo "DELETE branch-protection" >>"$state/mutations.log"
    ;;
  "GET repos/autumngarage/touchstone/rulesets?includes_parents=false" | \
  "GET repos/autumngarage/touchstone/rulesets?includes_parents=true")
    if [ -f "$state/repo-ruleset.json" ]; then
      emit "$(jq '[{id:.id,name:.name}]' "$state/repo-ruleset.json")"
    else
      emit '[]'
    fi
    ;;
  "GET repos/autumngarage/touchstone-workflows/rulesets?includes_parents=false" | \
  "GET repos/autumngarage/touchstone-workflows/rulesets?includes_parents=true")
    if [ -f "$state/source-repo-ruleset.json" ]; then
      emit "$(jq '[{id:.id,name:.name}]' "$state/source-repo-ruleset.json")"
    else
      emit '[]'
    fi
    ;;
  "GET repos/autumngarage/touchstone/rulesets/321")
    cat "$state/repo-ruleset.json"
    ;;
  "GET repos/autumngarage/touchstone-workflows/rulesets/654")
    cat "$state/source-repo-ruleset.json"
    ;;
  "POST repos/autumngarage/touchstone/rulesets")
    jq '. + {id:321}' >"$state/repo-ruleset.json"
    echo "POST repo-ruleset" >>"$state/mutations.log"
    if [ "${GH_FAKE_FAIL_REPO_MUTATION:-0}" = 1 ]; then
      rm -f "$state/repo-ruleset.json"
      echo "gh: Invalid request. Invalid property /rules/0 (HTTP 422)" >&2
      exit 1
    fi
    emit "$(cat "$state/repo-ruleset.json")"
    ;;
  "PUT repos/autumngarage/touchstone/rulesets/321")
    jq '. + {id:321}' >"$state/repo-ruleset.json"
    echo "PUT repo-ruleset" >>"$state/mutations.log"
    emit "$(cat "$state/repo-ruleset.json")"
    ;;
  "DELETE repos/autumngarage/touchstone/rulesets/321")
    rm -f "$state/repo-ruleset.json"
    echo "DELETE repo-ruleset" >>"$state/mutations.log"
    ;;
  "GET repos/autumngarage/touchstone/rules/branches/main")
    if [ ! -f "$state/ruleset.json" ]; then
      emit '[]'
    elif [ "${GH_FAKE_BAD_EFFECTIVE_ONCE:-0}" = 1 ] && [ ! -f "$state/bad-effective-used" ]; then
      touch "$state/bad-effective-used"
      jq '[.rules[] | select(.type != "workflows")]' "$state/ruleset.json"
    elif [ "${GH_FAKE_BAD_EFFECTIVE:-0}" = 1 ]; then
      jq '[.rules[] | select(.type != "workflows")]' "$state/ruleset.json"
    else
      jq -s 'map(.rules) | add' "$state/ruleset.json" "$state/repo-ruleset.json" 2>/dev/null \
        || jq '[.rules[]]' "$state/ruleset.json"
    fi
    ;;
  "GET repos/autumngarage/touchstone-workflows/rules/branches/main")
    if [ -f "$state/source-ruleset.json" ] && [ -f "$state/source-repo-ruleset.json" ]; then
      jq -s 'map(.rules) | add' "$state/source-ruleset.json" "$state/source-repo-ruleset.json"
    else
      emit '[]'
    fi
    ;;
  *)
    echo "unhandled fake gh call: $method $endpoint" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

# Policy mutation requires a clean reviewed checkout. Run the current script
# from a clean temporary repository so local development edits do not weaken
# that production precondition or prevent the lifecycle fixtures from running.
RUNNER_REPO="$TMP_DIR/policy-runner"
RUNNER_SOURCE_POLICY="$RUNNER_REPO/policy/github/workflow-sources/touchstone-workflows.json"
mkdir -p "$RUNNER_REPO/scripts" "$(dirname "$RUNNER_SOURCE_POLICY")"
cp "$SOURCE_SCRIPT" "$RUNNER_REPO/scripts/github-policy.sh"
cp "$SOURCE_POLICY" "$RUNNER_SOURCE_POLICY"
git -C "$RUNNER_REPO" init -q
git -C "$RUNNER_REPO" symbolic-ref HEAD refs/heads/main
git -C "$RUNNER_REPO" add scripts/github-policy.sh policy/github/workflow-sources/touchstone-workflows.json
git -C "$RUNNER_REPO" -c user.name=Touchstone -c user.email=touchstone@example.invalid \
  commit -qm "policy test runner"
SCRIPT="$RUNNER_REPO/scripts/github-policy.sh"

init_branch() {
  jq '{
    required_status_checks: .branchProtection.required_status_checks,
    enforce_admins: {enabled:.branchProtection.enforce_admins},
    required_pull_request_reviews: .branchProtection.required_pull_request_reviews,
    restrictions: .branchProtection.restrictions,
    required_linear_history: {enabled:.branchProtection.required_linear_history},
    required_signatures: {enabled:(.branchProtection.required_signatures // false)},
    allow_force_pushes: {enabled:.branchProtection.allow_force_pushes},
    allow_deletions: {enabled:.branchProtection.allow_deletions},
    block_creations: {enabled:.branchProtection.block_creations},
    required_conversation_resolution: {enabled:.branchProtection.required_conversation_resolution},
    lock_branch: {enabled:.branchProtection.lock_branch},
    allow_fork_syncing: {enabled:.branchProtection.allow_fork_syncing}
  }' "$BASELINE" >"$TMP_DIR/state/branch.json"
  : >"$TMP_DIR/state/mutations.log"
  rm -f "$TMP_DIR/state/ruleset.json" "$TMP_DIR/state/bad-effective-used" \
    "$TMP_DIR/state/branch-calls" "$TMP_DIR/state/org-mutation-failed" \
    "$TMP_DIR/state/branch-put-failed" "$TMP_DIR/state/local-workflow-absent" \
    "$TMP_DIR/state/repo-ruleset.json" "$TMP_DIR/state/auto-merge" \
    "$TMP_DIR/state/source-ruleset.json" "$TMP_DIR/state/source-repo-ruleset.json" \
    "$TMP_DIR/state/source-auto-merge"
}

run_policy() {
  PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" "$SCRIPT" "$@"
}

echo "==> Checked-in policy invariants"
jq -e '
  .contractVersion == 1
  and .managedRuleset.name == "Touchstone policy v1: autumngarage/touchstone@main"
  and .workflowSource.repository == "touchstone-workflows"
  and .workflowSource.sourceContract == {
    manifestPath: ".touchstone-source-contract.json",
    gateBehaviorContractVersion: 2
  }
  and .workflowSource.repository != .repository
  and .rollbackPrerequisites.repositoryFiles == [
    {path: ".github/workflows/validate.yml", sha: "c2dc082e0702090f3fc9de095d78a85ddde902a5"},
    {path: ".github/workflows/review-binding.yml", sha: "a4c161279b39f0e7c301c46f3d474b83dc4b10d7"},
    {path: ".github/workflows/review-evidence-signal.yml", sha: "3c34d7792afdc9c99c728b76bebe4e527a5db760"},
    {path: ".github/review-binding/evaluate.jq", sha: "0f30e59859b936ca16a8d6f4dd8cb1e8960eb917"}
  ]
  and .workflowSource.branchProtection == {
    enforce_admins:true,
    required_pull_request_reviews:true,
    required_conversation_resolution:true,
    allow_force_pushes:false,
    allow_deletions:false
  }
  and (.managedRuleset.bypass_actors == [{actor_id:null,actor_type:"OrganizationAdmin",bypass_mode:"pull_request"}])
  and any(.managedRuleset.rules[]; .type == "pull_request" and .parameters.required_review_thread_resolution == true)
  and (any(.managedRuleset.rules[]; .type == "required_status_checks") | not)
  and any(.managedRuleset.rules[]; .type == "workflows" and any(.parameters.workflows[];
    .repository_id == 1333343261
    and .path == ".github/workflows/validate.yml"
    and .ref == "refs/heads/main"
    and (.sha | test("^[0-9a-f]{40}$"))))
  and any(.managedRuleset.rules[]; .type == "workflows" and any(.parameters.workflows[];
    .repository_id == 1333343261
    and .path == ".github/workflows/review-gate.yml"
    and .ref == "refs/heads/main"
    and (.sha | test("^[0-9a-f]{40}$"))))
  and any(.managedRuleset.rules[]; .type == "workflows" and any(.parameters.workflows[];
    .repository_id == 1333343261
    and .path == ".github/workflows/delivery-evidence.yml"
    and .ref == "refs/heads/main"
    and (.sha | test("^[0-9a-f]{40}$"))))
  and ([.managedRuleset.rules[] | select(.type == "workflows") | .parameters.workflows[].sha] | unique | length) == 1
  and any(.managedRuleset.rules[]; .type == "deletion")
  and any(.managedRuleset.rules[]; .type == "non_fast_forward")
' "$POLICY" >/dev/null || fail "checked-in ruleset is missing a required invariant"
# The merged result is validated by the merge queue, not by making every open
# PR rebase: there is no strict up-to-date rule (no status-check rule at all,
# every gate being a required workflow that runs on merge_group) and the
# queue rule is on. Reintroducing a strict status rule would serialize every
# merge again (AUT-331).
jq -e '
  all(.managedRuleset.rules[]; .type != "required_status_checks" or .parameters.strict_required_status_checks_policy == false)
  and all(.managedRuleset.rules[]; .type != "merge_queue")
  and .managedRepositoryRuleset.name == "Touchstone merge queue v1: autumngarage/touchstone@main"
  and .managedRepositoryRuleset.enforcement == "active"
  and .managedRepositoryRuleset.conditions.ref_name.include == ["~DEFAULT_BRANCH"]
  and any(.managedRepositoryRuleset.rules[]; .type == "merge_queue" and .parameters == {
    check_response_timeout_minutes: 60,
    grouping_strategy: "ALLGREEN",
    max_entries_to_build: 1,
    max_entries_to_merge: 1,
    merge_method: "SQUASH",
    min_entries_to_merge: 1,
    min_entries_to_merge_wait_minutes: 0
  })
' "$POLICY" >/dev/null || fail "policy must carry the merge queue in the repository ruleset (GitHub rejects it in an organization ruleset) with no strict up-to-date rule"
# One entry per merge commit: the queue branch names a single PR and the
# publisher evaluates that PR, so a grouped merge commit would carry one PR's
# verdict for several. Grouping is re-enabled only with a publisher that
# aggregates every PR in the group.
# Every gate the queue waits on is a pinned required workflow that runs on
# merge_group itself (asserted in touchstone-workflows); nothing in this
# repository publishes a check, so there is no status-context rule to keep in
# step with a publisher.
[ "$(git hash-object "$ROLLBACK_VALIDATE")" = "c2dc082e0702090f3fc9de095d78a85ddde902a5" ] \
  || fail "durable rollback workflow differs from its recorded prerequisite blob"
# The legacy seed also requires the review-binding status: its publisher,
# evaluator, and event signal are retained as exact payloads so a rollback can
# restore a check something actually produces.
[ "$(git hash-object "$ROOT/policy/github/rollback/review-binding.yml")" = "a4c161279b39f0e7c301c46f3d474b83dc4b10d7" ] \
  || fail "retained review-binding publisher differs from its recorded prerequisite blob"
[ "$(git hash-object "$ROOT/policy/github/rollback/review-evidence-signal.yml")" = "3c34d7792afdc9c99c728b76bebe4e527a5db760" ] \
  || fail "retained review-evidence-signal differs from its recorded prerequisite blob"
[ "$(git hash-object "$ROOT/policy/github/rollback/review-binding-evaluate.jq")" = "0f30e59859b936ca16a8d6f4dd8cb1e8960eb917" ] \
  || fail "retained review-binding evaluator differs from its recorded prerequisite blob"
grep -Fq 'Policy operations require `gh`, `git`, `jq`, and `diff`.' "$POLICY_GUIDE" \
  || fail "policy guide does not declare its jq runtime dependency"
grep -Fq 'brew_install_if_missing "jq" "jq"' "$SETUP" \
  || fail "declared jq dependency is absent from setup"
grep -Fq 'derive-consumer-policy.sh touchstone-policy-canary' "$POLICY_GUIDE" \
  || fail "canary guide does not derive the canary policy through the one derivation script"
grep -Fq 'rollback restores the fresh' "$POLICY_GUIDE" \
  || fail "canary guide does not name the source of rollback protection"
# The derivation owns the coordinate rewrites; the canary exercises the
# same path as every consumer.
derived="$(bash "$ROOT/scripts/derive-consumer-policy.sh" touchstone-policy-canary)"
jq -e '
  .repository == "touchstone-policy-canary"
  and .rollbackPrerequisites.repositoryFiles == []
  and .managedRuleset.name == "Touchstone policy v1: autumngarage/touchstone-policy-canary@main"
  and .managedRuleset.conditions.repository_name.include == ["touchstone-policy-canary"]
  and .managedRepositoryRuleset.name == "Touchstone merge queue v1: autumngarage/touchstone-policy-canary@main"
' <<<"$derived" >/dev/null || fail "consumer derivation does not rewrite every ownership coordinate"
ok "ruleset expresses PR-only audited bypass and every native gate"

echo "==> Workflow source policy has a distinct fail-closed shape"
jq -e '
  .contractVersion == 1
  and .policyType == "workflow-source"
  and .repository == "touchstone-workflows"
  and (has("workflowSource") | not)
  and .sourceContract == {
    manifestPath: ".touchstone-source-contract.json",
    gateBehaviorContractVersion: 2
  }
  and .rollbackPrerequisites.repositoryFiles == []
  and any(.managedRuleset.rules[]; .type == "deletion")
  and any(.managedRuleset.rules[]; .type == "non_fast_forward")
  and any(.managedRuleset.rules[];
    .type == "pull_request"
    and .parameters.require_code_owner_review == false
    and .parameters.required_approving_review_count == 0
    and .parameters.required_review_thread_resolution == true)
  and any(.managedRuleset.rules[];
    .type == "required_status_checks"
    and .parameters.strict_required_status_checks_policy == false
    and .parameters.required_status_checks == [{context: "source contract"}])
  and (any(.managedRuleset.rules[]; .type == "workflows") | not)
  and any(.managedRepositoryRuleset.rules[]; .type == "merge_queue")
' "$SOURCE_POLICY" >/dev/null || fail "checked-in workflow source policy is missing a required invariant"

# Exercise the checked-in source inventory through the same policy runner used
# by the lifecycle suite. Mutations replace that runner's inventory entry so
# each structural guard is tested before restoring the reviewed fixture.
run_policy dry-run "$RUNNER_SOURCE_POLICY" >/dev/null \
  || fail "valid workflow source policy was refused"

jq 'del(.managedRuleset.rules[] | select(.type == "required_status_checks"))' \
  "$SOURCE_POLICY" >"$RUNNER_SOURCE_POLICY"
run_policy dry-run "$RUNNER_SOURCE_POLICY" >/dev/null 2>&1 \
  && fail "workflow source policy without its manifest status was accepted"
jq '(.managedRuleset.rules[] | select(.type == "pull_request") | .parameters.required_review_thread_resolution) = false' \
  "$SOURCE_POLICY" >"$RUNNER_SOURCE_POLICY"
run_policy dry-run "$RUNNER_SOURCE_POLICY" >/dev/null 2>&1 \
  && fail "workflow source policy without review-thread resolution was accepted"
jq '.managedRuleset.rules += [{type:"workflows",parameters:{workflows:[{
  path:".github/workflows/validate.yml",ref:"refs/heads/main",repository_id:1,
  sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}}]' \
  "$SOURCE_POLICY" >"$RUNNER_SOURCE_POLICY"
run_policy dry-run "$RUNNER_SOURCE_POLICY" >/dev/null 2>&1 \
  && fail "workflow source policy accepted a self-referential required workflow"
cp "$SOURCE_POLICY" "$RUNNER_SOURCE_POLICY"
GH_FAKE_SOURCE_STATUS_CONTEXT="renamed source contract" \
  run_policy dry-run "$RUNNER_SOURCE_POLICY" >/dev/null 2>&1 \
  && fail "workflow source policy accepted a status context that drifted from its manifest"
GH_FAKE_GATE_BEHAVIOR_VERSION=3 \
  run_policy dry-run "$RUNNER_SOURCE_POLICY" >/dev/null 2>&1 \
  && fail "workflow source policy accepted a gate behavior contract it does not declare"
GH_FAKE_SOURCE_EXTRA_WORKFLOW=".github/workflows/undeclared.yaml" \
  run_policy dry-run "$RUNNER_SOURCE_POLICY" >/dev/null 2>&1 \
  && fail "workflow source policy accepted a live workflow omitted from its manifest"
GH_FAKE_SOURCE_NESTED_WORKFLOW=".github/workflows/archive/validate.yml" \
  run_policy dry-run "$RUNNER_SOURCE_POLICY" >/dev/null 2>&1 \
  && fail "workflow source policy accepted a nested workflow path GitHub does not discover"
jq '.repository = "unlisted-source"
  | .managedRuleset.name = "Touchstone policy v1: autumngarage/unlisted-source@main"
  | .managedRuleset.conditions.repository_name.include = ["unlisted-source"]
  | .managedRepositoryRuleset.name = "Touchstone merge queue v1: autumngarage/unlisted-source@main"' \
  "$SOURCE_POLICY" >"$TMP_DIR/unlisted-source-policy.json"
run_policy dry-run "$TMP_DIR/unlisted-source-policy.json" >/dev/null 2>&1 \
  && fail "workflow source policy accepted a target absent from the checked-in inventory"
cp "$RUNNER_SOURCE_POLICY" "$(dirname "$RUNNER_SOURCE_POLICY")/duplicate.json"
run_policy dry-run "$RUNNER_SOURCE_POLICY" >/dev/null 2>&1 \
  && fail "workflow source policy accepted ambiguous duplicate inventory entries"
rm "$(dirname "$RUNNER_SOURCE_POLICY")/duplicate.json"
jq 'del(.managedRuleset.rules[] | select(.type == "workflows"))' \
  "$POLICY" >"$TMP_DIR/consumer-policy-no-workflows.json"
run_policy dry-run "$TMP_DIR/consumer-policy-no-workflows.json" >/dev/null 2>&1 \
  && fail "consumer policy without a required workflow was accepted"
jq 'del(.workflowSource.sourceContract.gateBehaviorContractVersion)' \
  "$POLICY" >"$TMP_DIR/consumer-policy-no-behavior-contract.json"
run_policy dry-run "$TMP_DIR/consumer-policy-no-behavior-contract.json" >/dev/null 2>&1 \
  && fail "consumer policy without a gate behavior contract was accepted"
GH_FAKE_GATE_BEHAVIOR_VERSION=3 run_policy dry-run "$POLICY" >/dev/null 2>&1 \
  && fail "consumer policy accepted a pinned source revision with an unsupported gate behavior contract"
ok "workflow source uses its manifest status while consumers still require external workflows"

echo "==> Checked-in consumer policies equal their derivation"
# One contract, many repositories: a consumer policy may differ from the
# canonical one only in the repository coordinates and the absence of
# Touchstone's own rollback prerequisites.
bash "$ROOT/scripts/derive-consumer-policy.sh" vesper --no-queue extra >/dev/null 2>&1 && fail "derive accepted a surplus argument" || ok "derive refuses surplus arguments"
# Stock macOS /bin/bash is 3.2; the empty --require-status case must derive
# there too (set -u and empty arrays are where 3.2 differs).
if [ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}" -le 4 ]' 2>/dev/null; then
  diff -q <(/bin/bash "$ROOT/scripts/derive-consumer-policy.sh" touchstone-policy-canary --no-queue) <(bash "$ROOT/scripts/derive-consumer-policy.sh" touchstone-policy-canary --no-queue) >/dev/null \
    && ok "derivation without --require-status is identical under /bin/bash $(/bin/bash -c 'echo ${BASH_VERSION%%(*}')" \
    || fail "derivation differs or fails under /bin/bash (bash 3/4)"
fi
# --require-status adds exactly one repository-owned context rule and nothing
# else: the canonical rules are joined, never removed or weakened.
with_status="$(bash "$ROOT/scripts/derive-consumer-policy.sh" touchstone-policy-canary --no-queue --require-status canary/body-check --require-status canary/body-check)"
without_status="$(bash "$ROOT/scripts/derive-consumer-policy.sh" touchstone-policy-canary --no-queue)"
[ "$(jq -c '[.managedRuleset.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]' <<<"$with_status")" = '["canary/body-check"]' ] \
  && [ "$(jq -S 'del(.managedRuleset.rules[] | select(.type == "required_status_checks"))' <<<"$with_status")" = "$(jq -S . <<<"$without_status")" ] \
  && ok "--require-status adds one deduplicated context rule and changes nothing else" \
  || fail "--require-status changed more than the status rule"
[ "$(bash "$ROOT/scripts/derive-consumer-policy.sh" touchstone-policy-canary --no-queue --require-status "validate (ubuntu-latest)" | jq -r '.managedRuleset.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context')" = "validate (ubuntu-latest)" ] \
  && ok "derive preserves an Actions-shaped context verbatim" || fail "derive mangled or refused 'validate (ubuntu-latest)'"
bash "$ROOT/scripts/derive-consumer-policy.sh" touchstone-policy-canary --no-queue --require-status "$(printf 'two\nlines')" >/dev/null 2>&1 && fail "derive accepted a context containing a line break" || ok "derive refuses a context containing a line break"
# A PR-only publisher never reports on a queue commit; the flag is refused
# with the queue so a queued consumer cannot be wedged by its own gate.
bash "$ROOT/scripts/derive-consumer-policy.sh" touchstone-policy-canary --require-status canary/body-check >/dev/null 2>&1 && fail "derive accepted --require-status with the merge queue" || ok "derive refuses --require-status without --no-queue"
bash "$ROOT/scripts/derive-consumer-policy.sh" touchstone-policy-canary --no-queue --require-status >/dev/null 2>&1 && fail "derive accepted --require-status without a value" || ok "derive refuses --require-status without a value"
# A status known to publish on merge_group can remain required with the queue.
with_queue_status="$(bash "$ROOT/scripts/derive-consumer-policy.sh" touchstone-policy-canary --require-merge-group-status canary/merged-result)"
[ "$(jq -c '[.managedRuleset.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]' <<<"$with_queue_status")" = '["canary/merged-result"]' ] \
  && jq -e 'any(.managedRepositoryRuleset.rules[]; .type == "merge_queue")' <<<"$with_queue_status" >/dev/null \
  && ok "--require-merge-group-status keeps the queue and adds the named status" \
  || fail "--require-merge-group-status did not preserve the queued policy"
bash "$ROOT/scripts/derive-consumer-policy.sh" touchstone-policy-canary --no-queue --require-merge-group-status canary/merged-result >/dev/null 2>&1 \
  && fail "derive accepted a merge-group status without the merge queue" \
  || ok "derive refuses --require-merge-group-status with --no-queue"
bash "$ROOT/scripts/derive-consumer-policy.sh" touchstone-policy-canary --require-status one --require-merge-group-status two >/dev/null 2>&1 \
  && fail "derive mixed pull-request and merge-group status declarations" \
  || ok "derive refuses mixed status event contracts"
for consumer in "$ROOT"/policy/github/consumers/*.json; do
  [ -f "$consumer" ] || continue
  name="$(basename "$consumer" .json)"
  # A queue-less consumer (private repository outside Enterprise Cloud) is the
  # same derivation with --no-queue; the checked-in file says which it is.
  # A consumer-owned required status uses the flag matching its checked-in
  # queue shape: pull_request-only when queue-less, merge_group when queued.
  derive_flags=()
  if jq -e '.managedRepositoryRuleset == null' "$consumer" >/dev/null; then
    derive_flags+=(--no-queue)
    status_flag=--require-status
  else
    status_flag=--require-merge-group-status
  fi
  while IFS= read -r context; do
    [ -n "$context" ] && derive_flags+=("$status_flag" "$context")
  done < <(jq -r '[.managedRuleset.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] | .[]' "$consumer")
  diff -u <(bash "$ROOT/scripts/derive-consumer-policy.sh" "$name" ${derive_flags[@]+"${derive_flags[@]}"} | jq -S .) <(jq -S . "$consumer") >/dev/null \
    || fail "policy/github/consumers/$name.json drifted from its derivation; regenerate it with scripts/derive-consumer-policy.sh $name ${derive_flags[*]+"${derive_flags[*]}"}"
  run_policy diff "$consumer" >/dev/null 2>"$TMP_DIR/consumer-$name.err" \
    || grep -q "HTTP 404\|unhandled fake gh call" "$TMP_DIR/consumer-$name.err" \
    || fail "consumer policy $name was refused locally: $(tail -1 "$TMP_DIR/consumer-$name.err")"
done
ok "consumer policies are exact derivations of the canonical policy"

# The derivation loop above infers --no-queue from the checked-in file, so it
# cannot notice a consumer losing its queue: regenerating with --no-queue would
# satisfy it silently. Name the expectation instead. A consumer eligible for the
# queue (Enterprise Cloud, or public) must declare one; convoy must not, until
# its repository-owned required checks report on a merge group -- without that,
# a queue there ejects every entry at the timeout.
echo "==> Queue-eligible consumers declare a merge queue"
jq -e 'any(.managedRepositoryRuleset.rules[]?; .type == "merge_queue")' \
  "$ROOT/policy/github/consumers/arpeggio.json" >/dev/null \
  && ok "arpeggio declares a merge queue" \
  || fail "arpeggio lost its merge queue; regenerate it without --no-queue"
# Hesperus (private, Enterprise Cloud) is queue-eligible from its first policy.
jq -e 'any(.managedRepositoryRuleset.rules[]?; .type == "merge_queue")' \
  "$ROOT/policy/github/consumers/hesperus.json" >/dev/null \
  && ok "hesperus declares a merge queue" \
  || fail "hesperus lost its merge queue; regenerate it without --no-queue"
# Hesperus's persistent acceptance fixture exists to exercise that queue end to
# end, so losing either its registration or its queue must fail independently
# of the generic derivation loop above.
jq -e 'any(.managedRepositoryRuleset.rules[]?; .type == "merge_queue")' \
  "$ROOT/policy/github/consumers/hesperus-acceptance-fixture.json" >/dev/null \
  && ok "hesperus acceptance fixture declares a merge queue" \
  || fail "hesperus acceptance fixture lost its merge queue; regenerate it without --no-queue"
# Vesper's hosted macOS workflow publishes on merge_group, so its checked-in
# policy keeps the queue and requires that exact prospective-merge verdict.
jq -e '
  any(.managedRepositoryRuleset.rules[]?; .type == "merge_queue")
  and [.managedRuleset.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] == ["Build, test, and smoke"]
' "$ROOT/policy/github/consumers/vesper.json" >/dev/null \
  && ok "vesper queues on its hosted macOS prospective-merge verdict" \
  || fail "vesper must queue on the required Build, test, and smoke merge-group status"
# Convoy's repository-owned publishers now report on merge_group. Its policy
# must preserve the delivery-protocol status while making the queue the atomic
# final review boundary.
jq -e '
  any(.managedRepositoryRuleset.rules[]?; .type == "merge_queue")
  and [.managedRuleset.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] == ["convoy/delivery-protocol"]
' "$ROOT/policy/github/consumers/convoy.json" >/dev/null \
  && ok "convoy queues on its trusted delivery-protocol merge-group verdict" \
  || fail "convoy must queue on the required convoy/delivery-protocol merge-group status"

echo "==> Read-only diff and dry-run"
init_branch
run_policy dry-run "$POLICY" >"$TMP_DIR/dry-run.txt"
[ ! -s "$TMP_DIR/state/mutations.log" ] || fail "dry-run mutated remote policy"
grep -q 'Would install/replace organization ruleset' "$TMP_DIR/dry-run.txt" \
  || fail "dry-run did not describe the apply"
ok "dry-run describes the change without mutating state"
grep -Fq 'diff -u -L current -L desired' "$SCRIPT" \
  || fail "policy diff does not use portable BSD/GNU label flags"
! grep -Fq -- '--label' "$SCRIPT" \
  || fail "policy diff uses GNU-only --label"
ok "policy diff uses portable BSD/GNU label flags"

echo "==> Apply requires reviewed removal of rollback-only files"
REVIEWED_REPO="$TMP_DIR/reviewed-repo"
mkdir -p "$REVIEWED_REPO/scripts" "$REVIEWED_REPO/policy/github" \
  "$REVIEWED_REPO/.github/workflows"
cp "$SCRIPT" "$REVIEWED_REPO/scripts/github-policy.sh"
cp "$POLICY" "$REVIEWED_REPO/policy/github/touchstone-main.json"
cp "$ROLLBACK_VALIDATE" "$REVIEWED_REPO/.github/workflows/validate.yml"
git -C "$REVIEWED_REPO" init -q
git -C "$REVIEWED_REPO" symbolic-ref HEAD refs/heads/main
git -C "$REVIEWED_REPO" add scripts/github-policy.sh policy/github/touchstone-main.json \
  .github/workflows/validate.yml
git -C "$REVIEWED_REPO" -c user.name=Touchstone -c user.email=touchstone@example.invalid \
  commit -qm baseline
rm "$REVIEWED_REPO/.github/workflows/validate.yml"
if PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" \
  "$REVIEWED_REPO/scripts/github-policy.sh" apply \
  "$REVIEWED_REPO/policy/github/touchstone-main.json" >/dev/null 2>&1; then
  fail "apply accepted an unstaged deletion absent only from the working tree"
fi
[ ! -s "$TMP_DIR/state/mutations.log" ] \
  || fail "apply checked rollback-only file removal after policy mutation"
git -C "$REVIEWED_REPO" add .github/workflows/validate.yml
git -C "$REVIEWED_REPO" -c user.name=Touchstone -c user.email=touchstone@example.invalid \
  commit -qm "remove rollback workflow"
touch "$REVIEWED_REPO/untracked-file"
if PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" \
  "$REVIEWED_REPO/scripts/github-policy.sh" apply \
  "$REVIEWED_REPO/policy/github/touchstone-main.json" >/dev/null 2>&1; then
  fail "apply accepted a dirty checkout after the reviewed removal"
fi
[ ! -s "$TMP_DIR/state/mutations.log" ] \
  || fail "apply checked checkout cleanliness after policy mutation"
ok "apply requires committed removal and a clean reviewed checkout"

echo "==> Required workflow source stays outside and protected from the target"
jq '.workflowSource.repository = .repository' "$POLICY" >"$TMP_DIR/self-source-policy.json"
if run_policy dry-run "$TMP_DIR/self-source-policy.json" >/dev/null 2>&1; then
  fail "policy accepted the target repository as its own required-workflow source"
fi
if PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" GH_FAKE_SOURCE_UNPROTECTED=1 \
  "$SCRIPT" dry-run "$POLICY" >/dev/null 2>&1; then
  fail "policy accepted an unprotected required-workflow source branch"
fi
if PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" GH_FAKE_SOURCE_RULESET_READ_ERROR=1 \
  "$SCRIPT" dry-run "$POLICY" >/dev/null 2>&1; then
  fail "consumer policy hid a workflow-source ruleset read failure behind legacy protection"
fi
jq '.managedRuleset + {id:456}' "$SOURCE_POLICY" >"$TMP_DIR/state/source-ruleset.json"
if run_policy dry-run "$POLICY" >/dev/null 2>&1; then
  fail "consumer policy accepted a partially installed workflow-source ruleset policy"
fi
jq '.managedRepositoryRuleset + {id:654}' "$SOURCE_POLICY" >"$TMP_DIR/state/source-repo-ruleset.json"
if run_policy dry-run "$POLICY" >/dev/null 2>&1; then
  fail "consumer policy accepted workflow-source rulesets with auto-merge disabled"
fi
touch "$TMP_DIR/state/source-auto-merge"
run_policy dry-run "$POLICY" >/dev/null \
  || fail "consumer policy rejected the complete workflow-source ruleset policy"
rm "$TMP_DIR/state/source-ruleset.json" "$TMP_DIR/state/source-repo-ruleset.json" \
  "$TMP_DIR/state/source-auto-merge"
ok "consumer verification accepts the complete source rulesets and rejects self-hosted, partial, or unprotected sources"
# Every required workflow is verified, not only the first: a second entry
# whose file is absent at its pin must be refused.
jq '(.managedRuleset.rules[] | select(.type == "workflows") | .parameters.workflows) += [{
  path: ".github/workflows/not-yet-there.yml", ref: "refs/heads/main", repository_id: 1333343261,
  sha: "4f93a259be6e8c83449c254d19e337ba50f3ff7a"}]' "$POLICY" >"$TMP_DIR/two-workflows-policy.json"
if run_policy dry-run "$TMP_DIR/two-workflows-policy.json" >/dev/null 2>"$TMP_DIR/two-workflows.err"; then
  fail "a second required workflow missing at its pin was accepted"
fi
grep -q "not-yet-there.yml does not exist at pinned SHA" "$TMP_DIR/two-workflows.err" \
  || fail "the missing second workflow was not the stated refusal: $(tail -1 "$TMP_DIR/two-workflows.err")"
ok "every required workflow is verified at its pin"

echo "==> A repository with no protection at all bootstraps, and a failed bootstrap leaves nothing behind"
# A fresh consumer has neither a managed ruleset nor legacy branch protection.
rm -f "$TMP_DIR/state/branch.json" "$TMP_DIR/state/ruleset.json" "$TMP_DIR/state/repo-ruleset.json" "$TMP_DIR/state/auto-merge" "$TMP_DIR/state/bad-effective-used"
: >"$TMP_DIR/state/mutations.log"
if PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" GH_FAKE_BAD_EFFECTIVE_ONCE=1 \
  "$SCRIPT" apply "$POLICY" >"$TMP_DIR/bootstrap-fail.out" 2>&1; then
  fail "a bootstrap whose verification failed reported success"
fi
grep -q "bootstrap failed; the rulesets it created were removed" "$TMP_DIR/bootstrap-fail.out" \
  || fail "failed bootstrap did not report its own cleanup: $(tail -1 "$TMP_DIR/bootstrap-fail.out")"
[ ! -f "$TMP_DIR/state/ruleset.json" ] || fail "failed bootstrap left the organization ruleset behind"
[ ! -f "$TMP_DIR/state/repo-ruleset.json" ] || fail "failed bootstrap left the repository ruleset behind"
[ ! -f "$TMP_DIR/state/auto-merge" ] || fail "failed bootstrap left auto-merge enabled"
ok "failed bootstrap removes what it created"
# Cleanup attempts every independent step even when one fails, and names it.
rm -f "$TMP_DIR/state/branch.json" "$TMP_DIR/state/ruleset.json" "$TMP_DIR/state/repo-ruleset.json" "$TMP_DIR/state/auto-merge" "$TMP_DIR/state/bad-effective-used"
if PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" GH_FAKE_BAD_EFFECTIVE_ONCE=1 GH_FAKE_FAIL_ORG_DELETE=1 \
  "$SCRIPT" apply "$POLICY" >"$TMP_DIR/bootstrap-partial.out" 2>&1; then
  fail "a bootstrap whose cleanup partly failed reported success"
fi
grep -q "bootstrap cleanup could not complete: organization-ruleset" "$TMP_DIR/bootstrap-partial.out" \
  || fail "partial cleanup did not name the failed step: $(tail -2 "$TMP_DIR/bootstrap-partial.out" | tr '\n' ' ')"
[ ! -f "$TMP_DIR/state/repo-ruleset.json" ] || fail "repository ruleset was not removed after the organization deletion failed"
[ ! -f "$TMP_DIR/state/auto-merge" ] || fail "auto-merge was not restored after the organization deletion failed"
ok "partial cleanup still attempts every independent step and names the failure"
rm -f "$TMP_DIR/state/ruleset.json"
# A companion ruleset with no organization ruleset is an interrupted adoption, not a bare repository.
rm -f "$TMP_DIR/state/branch.json" "$TMP_DIR/state/ruleset.json" "$TMP_DIR/state/auto-merge" "$TMP_DIR/state/bad-effective-used"
jq '.managedRepositoryRuleset + {id:321}' "$POLICY" >"$TMP_DIR/state/repo-ruleset.json"
if run_policy apply "$POLICY" >"$TMP_DIR/bootstrap-companion.out" 2>&1; then
  fail "a companion-only repository was bootstrapped over"
fi
grep -q "companion repository ruleset already exists" "$TMP_DIR/bootstrap-companion.out" \
  || fail "companion-only state was not routed to manual recovery: $(tail -1 "$TMP_DIR/bootstrap-companion.out")"
if [ -f "$TMP_DIR/state/repo-ruleset.json" ]; then
  ok "companion-only state refused and left untouched"
else
  fail "companion ruleset was deleted"
fi
rm -f "$TMP_DIR/state/repo-ruleset.json"
: >"$TMP_DIR/state/mutations.log"
run_policy apply "$POLICY" >"$TMP_DIR/bootstrap.out" 2>&1 || fail "bootstrap apply failed: $(cat "$TMP_DIR/bootstrap.out")"
grep -q "installing the policy fresh (bootstrap)" "$TMP_DIR/bootstrap.out" || fail "bootstrap was not announced"
grep -q "Applied and verified GitHub policy" "$TMP_DIR/bootstrap.out" || fail "bootstrap did not verify"
if [ -f "$TMP_DIR/state/ruleset.json" ] && [ -f "$TMP_DIR/state/repo-ruleset.json" ] && [ -f "$TMP_DIR/state/auto-merge" ]; then
  ok "bootstrap installed both rulesets and enabled auto-merge"
else
  fail "bootstrap did not install the complete policy state"
fi
if grep -q "DELETE" "$TMP_DIR/state/mutations.log"; then
  fail "bootstrap deleted something on a bare repository"
else
  ok "bootstrap deleted nothing"
fi

echo "==> A queue-less policy still enables auto-merge (touchstone pr merge arms it)"
rm -f "$TMP_DIR/state/branch.json" "$TMP_DIR/state/ruleset.json" "$TMP_DIR/state/repo-ruleset.json" "$TMP_DIR/state/auto-merge" "$TMP_DIR/state/bad-effective-used"
jq '.managedRepositoryRuleset = null' "$POLICY" >"$TMP_DIR/queueless.json"
run_policy apply "$TMP_DIR/queueless.json" >"$TMP_DIR/queueless.out" 2>&1 || fail "queue-less apply failed: $(cat "$TMP_DIR/queueless.out")"
[ -f "$TMP_DIR/state/auto-merge" ] && ok "auto-merge enabled without a queue" || fail "queue-less apply left auto-merge disabled"
[ ! -f "$TMP_DIR/state/repo-ruleset.json" ] || fail "queue-less apply created a repository ruleset"
touch "$TMP_DIR/state/local-workflow-absent"
run_policy verify "$TMP_DIR/queueless.json" >"$TMP_DIR/queueless-verify.out" 2>&1 || fail "queue-less verify failed: $(tail -1 "$TMP_DIR/queueless-verify.out")"
rm -f "$TMP_DIR/state/auto-merge"
run_policy verify "$TMP_DIR/queueless.json" >/dev/null 2>&1 && fail "verify passed with auto-merge disabled on a queue-less policy" || ok "verify requires auto-merge on a queue-less policy"
rm -f "$TMP_DIR/state/ruleset.json" "$TMP_DIR/state/local-workflow-absent"

echo "==> Ambiguous and failed reads fail closed"
if PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" GH_FAKE_DUPLICATE_RULESET=1 \
  "$SCRIPT" diff "$POLICY" >/dev/null 2>&1; then
  fail "duplicate managed ruleset names were treated as absence"
fi
if PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" GH_FAKE_BRANCH_ERROR=1 \
  "$SCRIPT" backup "$TMP_DIR/failed-backup.json" "$POLICY" >/dev/null 2>&1; then
  fail "branch-protection API failure was treated as absence"
fi
[ ! -e "$TMP_DIR/failed-backup.json" ] || fail "failed backup left an artifact"
ok "ambiguous rulesets and non-404 protection failures stop the operation"

echo "==> Ruleset ownership is explicit"
init_branch
jq '.managedRuleset.name = "Touchstone main delivery"' "$POLICY" >"$TMP_DIR/unmarked-policy.json"
if PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" GH_FAKE_UNRELATED_NAME_COLLISION=1 \
  "$SCRIPT" apply "$TMP_DIR/unmarked-policy.json" >/dev/null 2>&1; then
  fail "unmarked policy adopted an unrelated same-name organization ruleset"
fi
[ ! -s "$TMP_DIR/state/mutations.log" ] \
  || fail "unmarked policy mutated an unrelated same-name organization ruleset"
ok "only the derived ownership marker identifies a mutable ruleset"

echo "==> Backup, apply, and idempotency"
run_policy backup "$TMP_DIR/backup.json" "$POLICY"
jq -e '.branchProtection.required_status_checks.checks | length == 2' "$TMP_DIR/backup.json" >/dev/null \
  || fail "backup omitted current required checks"
jq -e '.branchProtection.required_signatures == false' "$TMP_DIR/backup.json" >/dev/null \
  || fail "backup omitted current signed-commit protection state"
jq -e '.rollbackPrerequisites.repositoryFiles[0].sha ==
  "c2dc082e0702090f3fc9de095d78a85ddde902a5"' \
  "$TMP_DIR/backup.json" >/dev/null \
  || fail "backup omitted the legacy policy rollback prerequisite"
run_policy apply "$POLICY"
[ ! -f "$TMP_DIR/state/branch.json" ] || fail "apply left duplicate branch protection"
[ "$(sed -n '1p' "$TMP_DIR/state/mutations.log")" = "POST org-ruleset" ] \
  || fail "apply did not install ruleset first"
[ "$(sed -n '2p' "$TMP_DIR/state/mutations.log")" = "POST repo-ruleset" ] \
  || fail "apply did not install the companion repository ruleset after the organization ruleset"
[ "$(sed -n '3p' "$TMP_DIR/state/mutations.log")" = "PATCH repo-settings" ] \
  || fail "apply did not enable auto-merge after the companion ruleset"
[ "$(sed -n '4p' "$TMP_DIR/state/mutations.log")" = "DELETE branch-protection" ] \
  || fail "apply removed branch protection before verified ruleset install"
jq -e 'any(.rules[]; .type == "merge_queue")' "$TMP_DIR/state/repo-ruleset.json" >/dev/null \
  || fail "companion repository ruleset does not carry the merge queue"
[ -f "$TMP_DIR/state/auto-merge" ] || fail "apply did not enable allow_auto_merge for the queue"
rm -f "$TMP_DIR/state/auto-merge"
touch "$TMP_DIR/state/local-workflow-absent"
if run_policy verify "$POLICY" >/dev/null 2>&1; then
  fail "verify accepted a repository whose allow_auto_merge is off"
fi
rm -f "$TMP_DIR/state/local-workflow-absent"
touch "$TMP_DIR/state/auto-merge"
before_count="$(wc -l <"$TMP_DIR/state/mutations.log" | tr -d ' ')"
jq '.rules |= reverse' "$TMP_DIR/state/ruleset.json" >"$TMP_DIR/state/reordered.json"
mv "$TMP_DIR/state/reordered.json" "$TMP_DIR/state/ruleset.json"
run_policy apply "$POLICY"
after_count="$(wc -l <"$TMP_DIR/state/mutations.log" | tr -d ' ')"
[ "$before_count" = "$after_count" ] || fail "second apply changed remote state"
ok "apply is ordered safely and a second apply is a no-op"
jq -e '.rules[] | select(.type == "pull_request") | .parameters.required_reviewers == []' \
  "$TMP_DIR/state/ruleset.json" >/dev/null \
  || fail "fake API did not exercise GitHub's required_reviewers default"
ok "GitHub's empty required_reviewers default does not create false drift"
jq -e '.managedRuleset.rules[] | select(.type == "pull_request") | .parameters.require_extra_approval_for_unattributed_changes == true' "$POLICY" >/dev/null \
  || fail "policy omits require_extra_approval_for_unattributed_changes, which GitHub echoes back as true and apply then reads as drift"
ok "the policy carries GitHub's injected pull_request default"

if run_policy verify "$POLICY" >/dev/null 2>&1; then
  fail "verify accepted a duplicate local validation workflow on main"
fi
touch "$TMP_DIR/state/local-workflow-absent"
run_policy verify "$POLICY" >/dev/null
ok "final verification requires rollback-only files to be absent from main"
rm -f "$TMP_DIR/state/local-workflow-absent"

echo "==> A queue rule in the organization ruleset is refused before any API call"
jq '(.managedRuleset.rules += .managedRepositoryRuleset.rules) | del(.managedRepositoryRuleset)' "$POLICY" \
  >"$TMP_DIR/org-queue-policy.json"
if run_policy diff "$TMP_DIR/org-queue-policy.json" >/dev/null 2>"$TMP_DIR/org-queue.err"; then
  fail "a merge_queue rule in the organization ruleset was accepted"
fi
grep -q "GitHub rejects it in an organization ruleset" "$TMP_DIR/org-queue.err" \
  || fail "organization-level merge_queue refusal did not name the reason"
jq '.managedRepositoryRuleset.name = "queue"' "$POLICY" >"$TMP_DIR/misnamed-companion.json"
if run_policy diff "$TMP_DIR/misnamed-companion.json" >/dev/null 2>&1; then
  fail "a companion ruleset without the ownership marker was accepted"
fi
ok "queue placement and companion ownership are validated locally"

echo "==> A failed companion ruleset install restores the complete prior state"
# GitHub rejected the queue rule at the organization endpoint on 2026-08-20;
# the same failure at the repository endpoint must leave the prior policy
# intact, not an organization ruleset that was replaced without its queue.
init_branch
if GH_FAKE_FAIL_REPO_MUTATION=1 run_policy apply "$POLICY" >/dev/null 2>&1; then
  fail "apply succeeded although the companion repository ruleset was rejected"
fi
[ ! -f "$TMP_DIR/state/repo-ruleset.json" ] || fail "a rejected companion ruleset was left behind"
[ ! -f "$TMP_DIR/state/ruleset.json" ] || fail "the organization ruleset was left installed after the companion failed"
[ ! -f "$TMP_DIR/state/auto-merge" ] || fail "a failed apply left auto-merge enabled although it was off before"
ok "a rejected companion ruleset restores the prior policy"

# Re-establish the applied state for the rollback case.
init_branch
run_policy apply "$POLICY" >/dev/null

echo "==> A policy that drops the companion removes the installed queue"
jq 'del(.managedRepositoryRuleset)' "$POLICY" >"$TMP_DIR/no-companion-policy.json"
run_policy dry-run "$TMP_DIR/no-companion-policy.json" >"$TMP_DIR/no-companion-dry-run.txt" 2>&1 || true
grep -q "Would DELETE repository ruleset" "$TMP_DIR/no-companion-dry-run.txt" \
  || fail "dry-run did not disclose the planned companion deletion"
run_policy apply "$TMP_DIR/no-companion-policy.json" >/dev/null
[ ! -f "$TMP_DIR/state/repo-ruleset.json" ] \
  || fail "the companion ruleset survived a policy that no longer declares it"
touch "$TMP_DIR/state/local-workflow-absent"
run_policy verify "$TMP_DIR/no-companion-policy.json" >/dev/null \
  || fail "verify did not accept the companion-free state"
rm -f "$TMP_DIR/state/local-workflow-absent"
ok "removing the companion from policy removes it from GitHub"
run_policy apply "$POLICY" >/dev/null
[ -f "$TMP_DIR/state/repo-ruleset.json" ] || fail "re-applying the policy did not reinstall the companion"

echo "==> Rollback restores before removing replacement"
run_policy rollback "$TMP_DIR/backup.json" "$POLICY"
[ -f "$TMP_DIR/state/branch.json" ] || fail "rollback did not restore branch protection"
[ ! -f "$TMP_DIR/state/ruleset.json" ] || fail "rollback did not remove the replacement ruleset"
[ ! -f "$TMP_DIR/state/repo-ruleset.json" ] || fail "rollback did not remove the companion repository ruleset"
[ ! -f "$TMP_DIR/state/auto-merge" ] || fail "rollback did not restore auto-merge to its captured value (off)"
tail -4 "$TMP_DIR/state/mutations.log" >"$TMP_DIR/rollback-order.txt"
diff -u <(printf 'PUT branch-protection\nDELETE org-ruleset\nDELETE repo-ruleset\nPATCH repo-settings\n') "$TMP_DIR/rollback-order.txt" >/dev/null \
  || fail "rollback created a protection gap: $(tr '\n' ' ' <"$TMP_DIR/rollback-order.txt")"
ok "rollback restores the captured gate before removing its replacement"

echo "==> Restricted rollback uses the writable API shape"
init_branch
jq '.restrictions = {
  users: [{login:"octocat"}],
  teams: [{slug:"release-engineers"}],
  apps: [{slug:"touchstone-bot"}]
}
| .required_pull_request_reviews.dismissal_restrictions = {
  users: [{login:"review-admin"}],
  teams: [{slug:"review-leads"}],
  apps: [{slug:"review-bot"}]
}
| .required_pull_request_reviews.bypass_pull_request_allowances = {
  users: [{login:"release-admin"}],
  teams: [{slug:"release-engineers"}],
  apps: [{slug:"touchstone-bot"}]
}
| .required_signatures.enabled = true' \
  "$TMP_DIR/state/branch.json" >"$TMP_DIR/state/restricted.json"
mv "$TMP_DIR/state/restricted.json" "$TMP_DIR/state/branch.json"
run_policy backup "$TMP_DIR/restricted-backup.json" "$POLICY" >/dev/null
jq -e '.branchProtection.restrictions == {
  users:["octocat"],teams:["release-engineers"],apps:["touchstone-bot"]
}
and .branchProtection.required_pull_request_reviews.dismissal_restrictions == {
  users:["review-admin"],teams:["review-leads"],apps:["review-bot"]
}
and .branchProtection.required_pull_request_reviews.bypass_pull_request_allowances == {
  users:["release-admin"],teams:["release-engineers"],apps:["touchstone-bot"]
}
and .branchProtection.required_signatures == true' \
  "$TMP_DIR/restricted-backup.json" >/dev/null \
  || fail "backup did not normalize restriction and review-exception objects into writable strings"
run_policy apply "$POLICY" >/dev/null
run_policy rollback "$TMP_DIR/restricted-backup.json" "$POLICY" >/dev/null
jq -e '.restrictions == {
  users:[{login:"octocat"}],
  teams:[{slug:"release-engineers"}],
  apps:[{slug:"touchstone-bot"}]
}
and .required_pull_request_reviews.dismissal_restrictions == {
  users:[{login:"review-admin"}],
  teams:[{slug:"review-leads"}],
  apps:[{slug:"review-bot"}]
}
and .required_pull_request_reviews.bypass_pull_request_allowances == {
  users:[{login:"release-admin"}],
  teams:[{slug:"release-engineers"}],
  apps:[{slug:"touchstone-bot"}]
}
and .required_signatures.enabled == true' \
  "$TMP_DIR/state/branch.json" >/dev/null \
  || fail "rollback did not restore restricted branch protection and review exceptions"
grep -qx 'POST required-signatures' "$TMP_DIR/state/mutations.log" \
  || fail "rollback did not recreate signed-commit protection through its separate endpoint"
ok "restricted protection, review exceptions, and signatures round-trip through backup and rollback"

echo "==> Rollback removes signed-commit protection when the backup is unsigned"
init_branch
run_policy backup "$TMP_DIR/unsigned-backup.json" "$POLICY" >/dev/null
jq 'del(.branchProtection.required_signatures)' \
  "$TMP_DIR/unsigned-backup.json" >"$TMP_DIR/legacy-unsigned-backup.json"
jq '.required_signatures.enabled = true' \
  "$TMP_DIR/state/branch.json" >"$TMP_DIR/state/signed-branch.json"
mv "$TMP_DIR/state/signed-branch.json" "$TMP_DIR/state/branch.json"
: >"$TMP_DIR/state/mutations.log"
run_policy rollback "$TMP_DIR/legacy-unsigned-backup.json" "$POLICY" >/dev/null
jq -e '.required_signatures.enabled == false' "$TMP_DIR/state/branch.json" >/dev/null \
  || fail "rollback retained signed-commit protection absent from the backup"
grep -qx 'DELETE required-signatures' "$TMP_DIR/state/mutations.log" \
  || fail "rollback did not remove signed-commit protection through its separate endpoint"
ok "signed-commit protection is removed, including from a compatible older backup"

echo "==> Signature API failures retain the active replacement gate"
init_branch
run_policy apply "$POLICY" >/dev/null
if PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" GH_FAKE_SIGNATURE_ERROR=1 \
  "$SCRIPT" rollback "$BASELINE" "$POLICY" >/dev/null 2>&1; then
  fail "rollback accepted a failed signature-protection read"
fi
[ -f "$TMP_DIR/state/ruleset.json" ] \
  || fail "signature API failure removed the surviving active ruleset"
[ ! -f "$TMP_DIR/state/branch.json" ] \
  || fail "signature API failure left a partially restored branch policy"
ok "non-404 signature failures propagate without removing the active gate"

echo "==> Rollback refuses an unprotected backup"
jq '.branchProtection = null | .managedOrganizationRuleset = null' \
  "$TMP_DIR/backup.json" >"$TMP_DIR/unprotected-backup.json"
if run_policy rollback "$TMP_DIR/unprotected-backup.json" "$POLICY" >/dev/null 2>&1; then
  fail "rollback accepted a backup with no protection to restore"
fi
ok "rollback cannot remove the gate using an unprotected backup"

echo "==> Rollback prerequisites fail before policy mutation"
init_branch
if PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" GH_FAKE_MISSING_ROLLBACK_FILE=1 \
  "$SCRIPT" rollback "$BASELINE" "$POLICY" >/dev/null 2>&1; then
  fail "rollback restored a status requirement whose workflow was absent"
fi
[ ! -s "$TMP_DIR/state/mutations.log" ] \
  || fail "missing rollback prerequisite was detected after policy mutation"
if PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" \
  GH_FAKE_ROLLBACK_FILE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  "$SCRIPT" rollback "$BASELINE" "$POLICY" >/dev/null 2>&1; then
  fail "rollback accepted a different fallback workflow blob"
fi
[ ! -s "$TMP_DIR/state/mutations.log" ] \
  || fail "mismatched rollback prerequisite was detected after policy mutation"
run_policy rollback "$BASELINE" "$POLICY" >/dev/null
ok "rollback requires the exact fallback workflow before restoring its check"

echo "==> Failed verification retains old protection"
init_branch
if PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" GH_FAKE_BAD_EFFECTIVE=1 \
  "$SCRIPT" apply "$POLICY" >/dev/null 2>&1; then
  fail "apply succeeded with a missing effective workflow rule"
fi
[ -f "$TMP_DIR/state/branch.json" ] || fail "failed verification removed old branch protection"
[ ! -f "$TMP_DIR/state/ruleset.json" ] || fail "failed initial migration left its invalid ruleset installed"
! grep -q 'DELETE branch-protection' "$TMP_DIR/state/mutations.log" \
  || fail "failed verification reached destructive migration step"
ok "failed replacement verification leaves the old gate intact"

echo "==> Failed in-place update restores the prior ruleset"
init_branch
run_policy apply "$POLICY" >/dev/null
jq '.managedRuleset.rules[] |= if .type == "pull_request" then
  (.parameters.required_approving_review_count = 1) else . end' \
  "$POLICY" >"$TMP_DIR/updated-policy.json"
: >"$TMP_DIR/state/mutations.log"
if PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" GH_FAKE_BAD_EFFECTIVE_ONCE=1 \
  "$SCRIPT" apply "$TMP_DIR/updated-policy.json" >/dev/null 2>&1; then
  fail "in-place update succeeded after its effective-policy verification failed"
fi
[ ! -f "$TMP_DIR/state/branch.json" ] || fail "failed update recreated legacy protection unexpectedly"
touch "$TMP_DIR/state/local-workflow-absent"
run_policy verify "$POLICY" >/dev/null \
  || fail "failed update did not restore and verify the prior ruleset"
diff -u <(printf 'PUT org-ruleset\nPUT org-ruleset\n') "$TMP_DIR/state/mutations.log" >/dev/null \
  || fail "failed update did not restore the previous ruleset immediately"
ok "failed in-place update restores and verifies the prior active gate"

echo "==> Ambiguous apply mutation restores the complete prior state"
init_branch
if PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" GH_FAKE_FAIL_ORG_MUTATION_ONCE=1 \
  "$SCRIPT" apply "$POLICY" >/dev/null 2>&1; then
  fail "apply succeeded after an ambiguous organization-ruleset mutation"
fi
[ -f "$TMP_DIR/state/branch.json" ] \
  || fail "ambiguous apply mutation did not preserve branch protection"
[ ! -f "$TMP_DIR/state/ruleset.json" ] \
  || fail "ambiguous apply mutation left an unverified ruleset installed"
ok "ambiguous apply mutation restores and verifies the complete prior state"

echo "==> Failed branch restore retains the active replacement gate"
init_branch
if PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" \
  GH_FAKE_BRANCH_ERROR_ON_CALL=2 GH_FAKE_FAIL_BRANCH_PUT_ONCE=1 \
  "$SCRIPT" apply "$POLICY" >/dev/null 2>&1; then
  fail "apply succeeded after verification and branch restoration both failed"
fi
[ ! -f "$TMP_DIR/state/branch.json" ] \
  || fail "failed branch restore unexpectedly recreated legacy protection"
[ -f "$TMP_DIR/state/ruleset.json" ] \
  || fail "failed branch restore deleted the surviving active ruleset"
ok "a failed branch restore cannot remove the surviving active ruleset"

echo "==> Failed rollback update restores the prior ruleset"
init_branch
run_policy apply "$POLICY" >/dev/null
run_policy backup "$TMP_DIR/post-migration-backup.json" "$POLICY" >/dev/null
run_policy apply "$TMP_DIR/updated-policy.json" >/dev/null
: >"$TMP_DIR/state/mutations.log"
rm -f "$TMP_DIR/state/bad-effective-used"
if PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" GH_FAKE_BAD_EFFECTIVE_ONCE=1 \
  "$SCRIPT" rollback "$TMP_DIR/post-migration-backup.json" "$POLICY" >/dev/null 2>&1; then
  fail "rollback update succeeded after effective-policy verification failed"
fi
touch "$TMP_DIR/state/local-workflow-absent"
run_policy verify "$TMP_DIR/updated-policy.json" >/dev/null \
  || fail "failed rollback update did not restore the prior ruleset"
diff -u <(printf 'PUT org-ruleset\nPUT org-ruleset\n') "$TMP_DIR/state/mutations.log" >/dev/null \
  || fail "failed rollback update did not restore the previous ruleset immediately: $(tr '\n' ' ' <"$TMP_DIR/state/mutations.log")"
ok "failed rollback update restores and verifies the prior active gate"

echo "==> Failed rollback deletion restores the prior ruleset"
init_branch
run_policy apply "$POLICY" >/dev/null
: >"$TMP_DIR/state/mutations.log"
if PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" GH_FAKE_BRANCH_ERROR_ON_CALL=3 \
  "$SCRIPT" rollback "$BASELINE" "$POLICY" >/dev/null 2>&1; then
  fail "rollback deletion succeeded after branch verification failed"
fi
[ -f "$TMP_DIR/state/ruleset.json" ] \
  || fail "failed rollback deletion did not recreate the prior ruleset"
[ -f "$TMP_DIR/state/repo-ruleset.json" ] \
  || fail "failed rollback deletion did not recreate the prior companion ruleset"
diff -u <(printf 'PUT branch-protection\nDELETE org-ruleset\nDELETE repo-ruleset\nPOST org-ruleset\nPOST repo-ruleset\n') \
  <(head -5 "$TMP_DIR/state/mutations.log") >/dev/null \
  || fail "failed rollback deletion did not restore the previous rulesets immediately: $(tr '\n' ' ' <"$TMP_DIR/state/mutations.log")"
tail -1 "$TMP_DIR/state/mutations.log" | grep -qx 'DELETE branch-protection' \
  || fail "failed rollback deletion did not restore the previous branch state"
touch "$TMP_DIR/state/local-workflow-absent"
run_policy verify "$POLICY" >/dev/null \
  || fail "failed rollback deletion did not verify the complete prior policy state"
ok "failed rollback deletion restores the prior active gate"

# =============================================================================
# Delivery evidence — the merge gate refuses a pull request that has not
# recorded its review tier and validation. Assertions live here rather than in
# a new file per the self-test rule: policy and merge-gate behavior is this
# file's surface.
EVIDENCE_CHECK="$ROOT/scripts/check-delivery-evidence.sh"
EVIDENCE_TMP="$TMP_DIR/evidence"
mkdir -p "$EVIDENCE_TMP"
body() { printf '%s\n' "$1" >"$EVIDENCE_TMP/body.md"; }
accepts() { bash "$EVIDENCE_CHECK" "$EVIDENCE_TMP/body.md" >/dev/null 2>&1; }

echo "==> a fully recorded pull request is accepted"
body '## Intent
Bind the branch a PR is opened for.

## Invariants
- The reviewed head is the merged head.

## Validation
- Build: n/a — shell
- Automated tests: full suite, pass.
- Manual validation: opened a PR from a worktree; the request bound the expected branch.
- Local review: codex on 0123abc: 0 findings.

## Review tier
serious

## Why this tier
Touches the merge boundary used by every project.'
if accepts; then
  ok "a recorded serious pull request passes"
else
  fail "the gate refused a fully recorded pull request"
fi

echo "==> an unedited template is absence, not evidence"
body '## Intent
<State exactly what behavior this change creates.>

## Invariants
<List the conditions that must remain true.>

## Validation
- Build: <exact command and result>

## Review tier
normal

## Why this tier
<One or two concrete sentences.>'
if accepts; then
  fail "the gate accepted an unedited template"
else
  ok "placeholder text does not satisfy the gate"
fi

echo "==> a missing or invalid tier is refused"
for tier in "" "quick" "SERIOUSLY"; do
  body "## Intent
Real intent.

## Invariants
- Something true.

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none

## Review tier
$tier

## Why this tier
Because."
  if accepts; then
    fail "the gate accepted tier '$tier'"
  else
    ok "tier '$tier' is refused"
  fi
done

echo "==> trivial needs less, but still needs its reasoning"
body '## Intent
Fix a typo in a comment.

## Validation
- Build: n/a — comment only
- Automated tests: lint, pass.
- Manual validation: n/a — none

## Review tier
trivial

## Why this tier
Comment-only, no behavior change.'
if accepts; then
  ok "a trivial pull request needs no invariants section"
else
  fail "the gate demanded invariants from a trivial change"
fi

body '## Intent
Fix a typo.

## Validation
- Build: n/a — comment only
- Automated tests: lint, pass.
- Manual validation: n/a — none

## Review tier
trivial

## Why this tier
'
if accepts; then
  fail "the gate accepted a tier with no justification"
else
  ok "an unjustified tier is refused at every level"
fi

echo "==> a normal or serious change must state its invariants"
body '## Intent
Change how merges bind.

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none
- Local review: coderabbit on the staged slice: 0 findings.

## Review tier
normal

## Why this tier
Contained logic change.'
if accepts; then
  fail "the gate accepted a normal change with no invariants"
else
  ok "normal requires invariants"
fi

echo "==> evasions that look like content are still absence"
for evasion in "n/a" "TBD" "todo" "-"; do
  body "## Intent
$evasion

## Invariants
- Real invariant.

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none

## Review tier
normal

## Why this tier
Contained."
  if accepts; then
    fail "the gate accepted '$evasion' as intent"
  else
    ok "'$evasion' does not satisfy a required section"
  fi
done

echo "==> placeholders inside labeled bullets are still placeholders"
# "- Build: <exact command and result>" is the template, not a record of
# anything that ran.
body '## Intent
Real intent.

## Invariants
- Real invariant.

## Validation
- Build: <exact command and result>
- Automated tests: <exact command and result>

## Review tier
normal

## Why this tier
Contained.'
if accepts; then
  fail "the gate accepted labeled placeholder bullets as validation"
else
  ok "a labeled placeholder bullet does not satisfy validation"
fi

echo "==> n/a with a reason is honest and accepted"
body '## Intent
Fix prose.

## Invariants
- The rendered blocks match canon.

## Validation
- Build: n/a — documentation only, no build step
- Automated tests: full suite, pass
- Manual validation: n/a — rendered blocks are asserted by the suite
- Local review: coderabbit on the staged slice: 0 findings.

## Review tier
normal

## Why this tier
Contained doc change with deterministic coverage.'
if accepts; then
  ok "n/a with a recorded reason satisfies the section"
else
  fail "the gate refused an honest n/a-with-reason"
fi

echo "==> the shipped template refuses itself"
body "$(cat "$ROOT/.github/pull_request_template.md")"
if accepts; then
  fail "the unedited PR template satisfies the gate it feeds"
else
  ok "the unedited template is absence"
fi

echo "==> the gate refuses a body it cannot read"
if bash "$EVIDENCE_CHECK" "$EVIDENCE_TMP/absent.md" >/dev/null 2>&1; then
  fail "the gate passed on an unreadable body"
else
  ok "an unreadable body fails closed"
fi

# Installation of this check as a required gate is deliberately absent here:
# a repository workflow on pull_request_target never reports on a merge-queue
# commit, so requiring its context would eject every queue entry. The gate
# ships as a required workflow from touchstone-workflows (AUT-332 / 3.1),
# which runs from the pinned source on pull_request and merge_group alike.

echo "==> unchecked task boxes and bullet-hidden comments are absence"
body '## Intent
- [ ] Build
- [ ] Test

## Invariants
- [ ] something

## Validation
- [ ] Tests pass locally

## Review tier
normal

## Why this tier
- [ ] contained'
if accepts; then
  fail "a body of unchecked task boxes satisfied the gate"
fi
ok "unchecked task-list scaffolding records nothing"

body '## Intent
- <!-- hidden behind a bullet -->

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none

## Review tier
trivial

## Why this tier
Docs.'
if accepts; then
  fail "a comment hidden behind a bullet satisfied a required section"
fi
ok "scaffolding cannot hide a one-line comment"

echo "==> the template's guidance comment does not corrupt the tier"
# An author who follows the shipped template leaves its <!-- trivial | normal
# | serious --> hint in place and writes the value beneath it. That must
# parse, or the gate blocks exactly the authors who did it right.
body '## Intent
real

## Invariants
- x holds

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none
- Local review: coderabbit on the staged slice: 1 finding, fixed.

## Review tier
<!-- trivial | normal | serious -->
normal

## Why this tier
contained'
if accepts; then
  ok "a tier beneath the template guidance comment parses"
else
  fail "the gate blocked a correctly filled template"
fi

echo "==> headings inside a comment are not sections"
body '<!--
## Intent
real
## Invariants
- x
## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none
- Local review: coderabbit on the staged slice: 0 findings.
## Review tier
normal
## Why this tier
x
-->'
if accepts; then
  fail "a body hidden entirely inside a comment satisfied the gate"
fi
ok "a body that opens an unclosed comment on its first line is refused with a remedy"

echo "==> nested empty list markers are still nothing"
body '## Intent
- -
* *

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none

## Review tier
trivial

## Why this tier
Docs.'
if accepts; then
  fail "nested bare list markers satisfied a required section"
fi
ok "repeated scaffolding stripping holds"

echo "==> ordered unchecked task items are still promises"
body '## Intent
+ [ ] plus-marker task

## Validation
+ [ ] Tests

## Invariants
+ [ ] x

## Review tier
normal

## Why this tier
+ [ ] contained'
if accepts; then
  fail "plus-prefixed unchecked task items satisfied the gate"
fi
ok "the third Markdown bullet marker strips like the other two"

body '## Intent
1. [ ] run tests

## Invariants
2. [ ] something

## Validation
1. [ ] Tests

## Review tier
normal

## Why this tier
3. [ ] contained'
if accepts; then
  fail "ordered unchecked task items satisfied the gate"
fi
ok "numbered scaffolding strips like bulleted scaffolding"

echo "==> literal comment openers in code are visible text"
# The gate must not swallow the body of a PR that mentions the token its own
# template uses.
body '## Intent
Support the literal `<!--` token in templates.

## Invariants
- x holds

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none
- Local review: coderabbit on the staged slice: 0 findings.

## Review tier
normal

## Why this tier
contained'
if accepts; then
  ok "an inline-code comment opener does not eat the body"
else
  fail "the gate refused a valid body mentioning <!-- in code"
fi

body '## Intent
real

```
<!--
```

## Invariants
- x

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none
- Local review: coderabbit on the staged slice: 0 findings.

## Review tier
normal

## Why this tier
contained'
if accepts; then
  ok "a fenced comment opener does not eat the body"
else
  fail "the gate refused a valid body with <!-- in a fence"
fi

echo "==> blockquoted unchecked tasks are still promises"
body '## Intent
> - [ ] run tests

## Invariants
> - [ ] x

## Validation
> - [ ] Tests

## Review tier
normal

## Why this tier
> - [ ] contained'
if accepts; then
  fail "blockquoted unchecked task items satisfied the gate"
fi
ok "blockquote markers strip like list markers"

echo "==> a fenced copy of the template is sample text, not sections"
body '```
## Intent
real
## Invariants
- x
## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none
- Local review: coderabbit on the staged slice: 0 findings.
## Review tier
normal
## Why this tier
x
```'
if accepts; then
  fail "a fenced copy of the whole template satisfied the gate"
fi
ok "fenced headings are not sections"

echo "==> a longer fence is not closed by a shorter line"
# Markdown closes a fence only with the same character repeated at least as
# many times as the opener; the parser must agree or fenced samples re-enter
# section parsing while the rendered body keeps them hidden.
body '````
```
## Intent
real
## Invariants
- x
## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none
- Local review: coderabbit on the staged slice: 0 findings.
## Review tier
normal
## Why this tier
x
````'
if accepts; then
  fail "a four-backtick fence was closed by a three-backtick line"
fi
ok "fence closing honors delimiter length"

echo "==> Markdown edge fidelity: strict closers, run-length spans"
# A closing fence is delimiter plus trailing spaces only; an info-string line
# inside a fence closes nothing.
body '````
```not-a-closing-fence
## Intent
real
## Invariants
- x
## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none
- Local review: coderabbit on the staged slice: 0 findings.
## Review tier
normal
## Why this tier
x
````'
if accepts; then
  fail "an info-string line inside a fence was treated as its closer"
fi
ok "a closer is the delimiter alone"

# Inline spans open and close with equal-length runs; a double-backtick span
# holding a comment opener is visible text, and refusing it blocks exactly
# the authors discussing this template.
body '## Intent
Support the ``<!--`` token in templates.

## Invariants
- x holds

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none
- Local review: coderabbit on the staged slice: 0 findings.

## Review tier
normal

## Why this tier
contained'
if accepts; then
  ok "a double-backtick span keeps its comment opener visible"
else
  fail "the gate refused a valid body using a double-backtick span"
fi

echo "==> the tier is one word; whitespace does not assemble one"
for bad_tier in 'nor mal' 'nor
mal'; do
  body "## Intent
real

## Invariants
- x

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none

## Review tier
$bad_tier

## Why this tier
x"
  if accepts; then
    fail "a tier containing whitespace was normalized into a valid one"
  fi
done
ok "internal whitespace never assembles a valid tier"

echo "==> a 4-space-indented delimiter inside a fence closes nothing"
body '```
    ```
## Intent
real
## Invariants
- x
## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none
- Local review: coderabbit on the staged slice: 0 findings.
## Review tier
normal
## Why this tier
x
```'
if accepts; then
  fail "an indented delimiter line was treated as a fence closer"
fi
ok "fence delimiters honor the three-space indentation bound"

echo "==> an indented code sample keeps its comment opener visible"
body '## Intent
Example:

    <!--

## Invariants
- x

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none
- Local review: coderabbit on the staged slice: 0 findings.

## Review tier
normal

## Why this tier
contained'
if accepts; then
  ok "a 4-space-indented opener does not eat the body"
else
  fail "the gate refused a valid body with an indented code sample"
fi

echo "==> a backtick in a fence info string means no fence at all"
body '## Intent
See ```inline`code``` here.

## Invariants
- x holds

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none
- Local review: coderabbit on the staged slice: 0 findings.

## Review tier
normal

## Why this tier
contained'
if accepts; then
  ok "an info string containing a backtick does not open a fence"
else
  fail "the gate refused a valid body over a non-fence backtick line"
fi

echo "==> a backslash-escaped comment opener stays visible text"
body '## Intent
The literal token is \<!-- in the rendered body.

## Invariants
- x holds

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none
- Local review: coderabbit on the staged slice: 0 findings.

## Review tier
normal

## Why this tier
contained'
if accepts; then
  ok "an escaped opener does not eat the body"
else
  fail "the gate refused a valid body over a backslash-escaped opener"
fi

echo "==> a bare list marker satisfies nothing"
body '## Intent
-
*

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none

## Review tier
trivial

## Why this tier
Docs.'
if accepts; then
  fail "a section of bare list markers satisfied the gate"
fi
ok "bare list markers are absence"

echo "==> comment handling is one-line by declared limit"
# A comment that opens and closes on one line is invisible. Anything else --
# an opener in a code span, a fence, a blockquote, an escaped opener, a
# comment spanning lines -- is visible text, because the only way to get
# those right is a Markdown parser and six rounds of review proved that one
# never ends. The template carries only one-line comments, so the template
# is still absence and an author's own prose is still presence.
body '## Intent
<!-- one-line guidance -->

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none

## Review tier
trivial

## Why this tier
Docs.'
if accepts; then
  fail "a one-line HTML comment satisfied a required section"
fi
ok "a one-line comment is invisible"

body '## Intent
Support the literal `<!--
token` across a line break, and `<!-- -->` inline, and > quoted `    <!--`.

## Invariants
- x holds

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none
- Local review: coderabbit on the staged slice: 0 findings.

## Review tier
normal

## Why this tier
contained'
if accepts; then
  ok "an opener outside a one-line comment is visible text and eats nothing"
else
  fail "the gate refused a valid body over a multi-line code span"
fi

body 'Support the literal `<!--` token in an opening sentence.

## Intent
Real intent.

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none

## Review tier
trivial

## Why this tier
Docs.'
if accepts; then
  ok "a first line that merely mentions the opener is visible text"
else
  fail "the first-line guard refused a body whose opening sentence mentions the token"
fi

echo "==> every Validation row is filled, not only one"
body '## Intent
Real intent.

## Validation
- Build: n/a — shell
- Automated tests:
- Manual validation: <specific scenario and result>

## Review tier
trivial

## Why this tier
Docs.'
if accepts; then
  fail "one filled Validation row satisfied the section while two stayed empty"
fi
ok "an empty or placeholder Validation row is reported by name"
body '## Intent
Real intent.

## Validation
- Build: n/a — shell
- Automated tests: TBD
- Manual validation: none

## Review tier
trivial

## Why this tier
Docs.'
if accepts; then
  fail "a bare placeholder word on a Validation row satisfied it"
fi
ok "placeholder rules apply to each Validation row"
body '## Intent
Real intent.

## Validation
- Build: pass

## Review tier
trivial

## Why this tier
Docs.'
if accepts; then
  fail "deleting two of the three shipped Validation rows satisfied the section"
fi
ok "all three shipped Validation rows are required"
body '## Intent
Real intent.

## Validation
The Build: passed in CI, honestly.
- Build:
- Automated tests: suite passed
- Manual validation: n/a — no UI

## Review tier
trivial

## Why this tier
Docs.'
if accepts; then
  fail "prose mentioning a row label was read as the row value"
fi
ok "a row value comes from its own bullet, not from prose"
body '## Intent
Real intent.

## Validation
- Build: n/a — shell
- Automated tests: suite passed
- Manual validation: n/a — no UI

## Review tier
trivial

## Why this tier
Docs.'
if accepts; then
  ok "every row filled passes"
else
  fail "fully filled Validation rows were refused"
fi

echo "==> an empty fenced block is not content"
body '## Intent
```
```

## Invariants
```bash
```

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none
- Local review: coderabbit on the staged slice: 0 findings.

## Review tier
normal

## Why this tier
contained'
if accepts; then
  fail "empty fence delimiters satisfied a required section"
fi
ok "fence delimiters alone are scaffolding"
body '## Intent
```c++
```

## Invariants
~~~text/plain
~~~

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none
- Local review: coderabbit on the staged slice: 0 findings.

## Review tier
normal

## Why this tier
```foo bar
```'
if accepts; then
  fail "empty fences with punctuated info strings satisfied required sections"
fi
ok "any fence delimiter line is scaffolding, whatever its info string"
body '## Intent
Real intent.

## Validation
- Build: n/a —
- Automated tests: n/a -
- Manual validation: n/a —

## Review tier
trivial

## Why this tier
Docs.'
if accepts; then
  fail "n/a followed only by a separator counted as a reason"
fi
ok "n/a needs a reason, not a dash"
if LC_ALL=C accepts; then
  fail "under LC_ALL=C an em dash after n/a counted as a reason"
fi
ok "the em dash is recognised byte-wise under the C locale"
body '## Intent
```inline`code``` is visible text, not a fence.

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none

## Review tier
trivial

## Why this tier
Docs.'
if accepts; then
  ok "a backtick line with a backtick in its info string is content"
else
  fail "a non-fence backtick line was dropped as a delimiter"
fi
body '## Intent
```
real intent inside a fence
```

## Invariants
- x holds

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none
- Local review: coderabbit on the staged slice: 0 findings.

## Review tier
normal

## Why this tier
contained'
if accepts; then
  ok "content inside a fence still counts"
else
  fail "fenced content was refused"
fi

echo "==> a higher-level heading ends a section"
body '## Intent

# Notes
Unrelated prose under an H1 is not Intent.

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none

## Review tier
trivial

## Why this tier
Docs.'
if accepts; then
  fail "prose under a following H1 satisfied an empty section"
fi
ok "an H1 closes the section before it"
body "$(printf '## Intent\n\n##\tNotes\nUnrelated prose under a tab-delimited heading.\n\n## Validation\n- Build: n/a — shell\n- Automated tests: pass\n- Manual validation: n/a — none\n\n## Review tier\ntrivial\n\n## Why this tier\nDocs.')"
if accepts; then
  fail "prose under a tab-delimited heading satisfied an empty section"
fi
ok "a tab after the hashes is a heading boundary too"
body '## Intent

Notes
=====
Unrelated prose under a Setext heading.

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none

## Review tier
trivial

## Why this tier
Docs.'
if accepts; then
  fail "prose under a Setext heading satisfied an empty section"
fi
ok "a Setext heading ends the section before it"
body '## Intent
Real intent
---
still part of intent? no: a dash underline makes the line above an H2, so the section is just the heading line

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none

## Review tier
trivial

## Why this tier
Docs.'
if accepts; then
  fail "a dash-underlined line counted as section content"
fi
ok "a dash underline is a Setext H2 boundary, not content"

echo "==> a heading may carry up to three leading spaces"
body '   ## Intent
Real intent.

  ## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none

 ## Review tier
trivial

## Why this tier
Docs.'
if accepts; then
  ok "indented ATX headings are sections"
else
  fail "the gate refused a valid body over indented headings"
fi

echo "==> an unreadable body fails closed (non-root only)"
# chmod does not stop root, which is what the required workflow's container
# runs as -- the same UID trap recorded in the staging-failure fixture.
if [ "$(id -u)" -ne 0 ]; then
  printf '## Intent\nreal\n' >"$EVIDENCE_TMP/unreadable.md"
  chmod 000 "$EVIDENCE_TMP/unreadable.md"
  if bash "$EVIDENCE_CHECK" "$EVIDENCE_TMP/unreadable.md" >/dev/null 2>&1; then
    chmod 644 "$EVIDENCE_TMP/unreadable.md"
    fail "the gate passed on a body it could not read"
  fi
  chmod 644 "$EVIDENCE_TMP/unreadable.md"
  ok "an existing but unreadable body fails closed"
fi

echo "==> the local review pass must leave evidence on normal and serious tiers (AUT-443)"
# An agent shipped four PRs without ever running the tier's local pass and
# nothing could notice: every other step is gated, this one was prose. A
# normal or serious body without the row, with a bare n/a, or naming no
# reviewer is refused; a waiver with a reason, or a reviewer with its result,
# passes; trivial needs nothing.
lr_body() {
  body "## Intent
real

## Invariants
- x holds

## Validation
- Build: n/a — shell
- Automated tests: pass
- Manual validation: n/a — none
$1

## Review tier
$2

## Why this tier
contained"
}
lr_body '' normal
accepts && fail "a normal PR without a Local review row was accepted" || ok "no Local review row is refused on normal"
lr_body '- Local review: n/a' serious
accepts && fail "a bare n/a Local review was accepted" || ok "a bare n/a Local review is refused"
lr_body '- Local review: ran it, looked fine' normal
accepts && fail "a Local review naming no reviewer was accepted" || ok "a Local review naming no reviewer is refused"
lr_body '- Local review: codex on 1234567: 3 findings, 2 fixed, 1 routed.' serious
accepts && ok "a recorded codex pass is accepted" || fail "a recorded codex pass was refused: $(bash "$EVIDENCE_CHECK" "$EVIDENCE_TMP/body.md" 2>&1 | tail -3)"
lr_body '- Local review: n/a — coderabbit CLI is not installed on this machine; recorded waiver.' normal
accepts && ok "a waiver with a reason is accepted" || fail "a reasoned waiver was refused"
lr_body '- Local review: n/a — skipped' normal
accepts && ok "a waiver's reason is the author's words, not a keyword list" || fail "a waiver with a stated reason was refused"
lr_body '- Local review: codex' serious
accepts && fail "a reviewer name with no result was accepted" || ok "a reviewer name with no result is refused"
lr_body '- Local review: codex not run' serious
accepts && fail "'codex not run' was accepted" || ok "'codex not run' is refused"
lr_body '- Local review: CodeRabbit on the staged slice: 0 findings.' normal
accepts && ok "the transition still accepts a coderabbit normal pass" || fail "a coderabbit normal pass was refused during the transition"
lr_body '- Local review: codex on the staged slice (review-normal): 0 findings.' normal
accepts && ok "the transition accepts a codex normal pass" || fail "a codex normal pass was refused during the transition"
lr_body '- Local review: codex on    : 0 findings.' normal
accepts && fail "a normal pass naming only whitespace as its target was accepted" || ok "a normal target contains non-whitespace text"
lr_body '- Local review: codex on 1234567: 0 findings.' normal
accepts && fail "a normal pass naming a bare revision was accepted" || ok "a normal target is not a bare revision"
lr_body '- Local review: codex on `1234567`: 0 findings.' normal
accepts && fail "a normal pass naming a decorated bare revision was accepted" || ok "normal target decoration cannot disguise a bare revision"
lr_body '- Local review: codex on 1234567 : 0 findings.' normal
accepts && fail "a normal pass naming a space-padded bare revision was accepted" || ok "normal target whitespace cannot disguise a bare revision"
lr_body '- Local review: codex on  1234567: 0 findings.' normal
accepts && fail "a normal pass naming a leading-padded bare revision was accepted" || ok "leading target whitespace cannot disguise a bare revision"
lr_body '- Local review: codex on `1234567 `: 0 findings.' normal
accepts && fail "a normal pass naming an inner-padded bare revision was accepted" || ok "whitespace inside target decoration cannot disguise a bare revision"
lr_body '- Local review: coderabbit on 1234567: 0 findings.' normal
accepts && fail "a normal coderabbit pass naming a bare revision was accepted" || ok "the normal target rule applies to both transition reviewers"
lr_body '- Local review: coderabbit on the staged slice: 0 findings.' serious
accepts && fail "a serious PR recording coderabbit was accepted" || ok "the wrong reviewer for the tier is refused (serious wants codex)"
lr_body '- Local review: codex on the branch head: 0 findings.' serious
accepts && fail "a serious codex pass naming no revision was accepted" || ok "a serious codex pass must name the revision it reviewed"
lr_body '- Local review: codex on origin/main: 0 findings, accepted.' serious
accepts && fail "a serious codex pass naming its symbolic base was accepted" || ok "a serious pass records the captured reviewed head, not its symbolic base"
lr_body '- Local review: n/a — the codex executable is missing from this runner.' serious
accepts && ok "a waiver with any stated reason is accepted" || fail "a waiver stating a reason in its own words was refused"
lr_body '- Local review: n/a —' serious
accepts && fail "a waiver with an empty reason was accepted" || ok "a waiver with an empty reason is refused"
lr_body '- Local review: codex on 1234567: 0 findings; coderabbit CLI was unavailable.' normal
accepts && fail "a codex run mentioning coderabbit was accepted on normal" || ok "the reviewer must open the run record, a mention elsewhere does not count"
lr_body '- Local review: coderabbit on the staged slice: 1 finding (tests not run), fixed.' normal
accepts && ok "a finding disposition may say 'not run' without being read as a skipped pass" || fail "a real pass was refused for a finding's wording"
lr_body '- Local review: coderabbit not run: 0 findings.' normal
accepts && fail "a skipped pass with a count was accepted" || ok "the run record must read '<reviewer> on <target>:'"
lr_body '- Local review: codex on the branch head: 1 finding, fixed in 9decc0c9.' serious
accepts && fail "a serious row sourcing its SHA from a disposition was accepted" || ok "a serious revision binds to the run target, not to a later SHA"
lr_body '- Local review: codex on 1234567 0 findings: not run' serious
accepts && fail "a finding count inside the target was accepted" || ok "the finding count is read from the result after the target"
lr_body '- Local review: codex on 1234567: not run; 0 findings' serious
accepts && fail "a skip stated before the count was accepted" || ok "the finding count must open the result immediately after the target"
lr_body '- Local review: n/a — <reason>' serious
accepts && fail "an unedited <reason> placeholder was accepted as a waiver" || ok "an unedited waiver placeholder is refused"
lr_body '- Local review: codex on branch-1234567-not-head: 0 findings' serious
accepts && fail "a decorated serious target was accepted" || ok "a serious target is the bare reviewed revision"
lr_body '```
- Local review: codex on 1234567: 0 findings.
```' serious
accepts && fail "a fenced example row was accepted as evidence" || ok "a fenced example row is not a record"
lr_body '    - Local review: codex on 1234567: 0 findings.' serious
accepts && fail "an indented-code example row was accepted as evidence" || ok "an indented-code example row is not a record"
lr_body '- Local review: n/approved' serious
accepts && fail "'n/approved' was read as an n/a waiver" || ok "the n/a waiver token is bounded"
lr_body '- Local review: codex on `0bd1b934`: 1 finding, fixed in `34973a19`.' serious
accepts && ok "a backticked revision is the same record (AUT-468)" || fail "a backticked revision was refused"
lr_body '- Local review: **coderabbit** on the staged slice: 0 findings.' normal
accepts && ok "a bold reviewer name is the same record" || fail "a bold reviewer name was refused"
lr_body '- Local review: code*x on 1234567: 0 findings.' serious
accepts && fail "a marker inside a token was read as decoration" || ok "a marker inside a token is not a boundary: code*x is not codex"
lr_body '- Local review: codex on dead*beef: 0 findings.' serious
accepts && fail "a marker inside a token was read as decoration" || ok "a marker inside a token is not a boundary: dead*beef is not a revision"
lr_body '- Local review: *codex* on `1234567`: 0 findings.' serious
accepts && ok "emphasis and code-span decoration around a field is accepted" || fail "a balanced-wrapper row was refused"
lr_body '- Local review: **codex **on 1234567: 0 findings.' serious
accepts && fail "a marker run that does not bound the reviewer was accepted" || ok "a marker must bound the field: '**codex **on' names no reviewer"
lr_body '- Local review: ** codex**on 1234567: 0 findings.' serious
accepts && fail "a marker run that does not bound the reviewer was accepted" || ok "a marker must bound the field: '** codex**on' names no reviewer"
# Decoration the gate deliberately accepts: a mismatched backtick run is not
# a valid CommonMark code span, but the row still names codex and 1234567
# unambiguously. The gate reads identity, not rendering -- refusing a legible
# record would recreate the AUT-468 failure it exists to fix.
lr_body '- Local review: codex on ``1234567````: 0 findings.' serious
accepts && ok "decoration that leaves the record unambiguous is accepted" || fail "a legible record was refused over invalid Markdown"
lr_body '- Local review: ran `codex review --base main` (serious), pre-push at 0bd1b934 — 3 findings' serious
if accepts; then fail "a row that does not begin with the run record was accepted"; else
  # Read the whole report first: under pipefail a -q grep that closes the
  # pipe early would fail the evaluator with SIGPIPE.
  unread_report="$(bash "$EVIDENCE_CHECK" "$EVIDENCE_TMP/body.md" 2>&1 || true)"
  case "$unread_report" in
    *"  unreadable: the Validation row '- Local review:' is present but not in the shape"*"got: 'ran "*) ok "an unreadable row is reported as present and quoted, not missing" ;;
    *) fail "an unreadable row was not quoted back: $unread_report" ;;
  esac
fi
echo "==> rejected evidence is named in Actions annotations and the step summary"
: >"$EVIDENCE_TMP/summary.md"
set +e
GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$EVIDENCE_TMP/summary.md" \
  bash "$EVIDENCE_CHECK" "$EVIDENCE_TMP/body.md" >"$EVIDENCE_TMP/actions.out" 2>&1
actions_rc=$?
set -e
if [ "$actions_rc" -ne 0 ] \
  && grep -qF "::error title=Delivery evidence unreadable::the Validation row '- Local review:' is present but not in the shape" "$EVIDENCE_TMP/actions.out" \
  && grep -qF "the Validation row '- Local review:' is present but not in the shape" "$EVIDENCE_TMP/summary.md" \
  && grep -qF "it must begin with 'codex on &lt;revision&gt;: &lt;n&gt; findings, &lt;disposition&gt;'" "$EVIDENCE_TMP/summary.md"; then
  ok "an unreadable row names the rejected row and expected shape on GitHub"
else
  fail "an unreadable row lacked a useful Actions diagnostic: $(cat "$EVIDENCE_TMP/actions.out") $(cat "$EVIDENCE_TMP/summary.md")"
fi
lr_body '' normal
: >"$EVIDENCE_TMP/summary.md"
set +e
GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$EVIDENCE_TMP/summary.md" \
  bash "$EVIDENCE_CHECK" "$EVIDENCE_TMP/body.md" >"$EVIDENCE_TMP/actions.out" 2>&1
actions_rc=$?
set -e
if [ "$actions_rc" -ne 0 ] \
  && grep -qF "::error title=Delivery evidence missing::the Validation row '- Local review:' present" "$EVIDENCE_TMP/actions.out" \
  && grep -qF "the Validation row '- Local review:' present" "$EVIDENCE_TMP/summary.md"; then
  ok "a missing row is named in the annotation and summary"
else
  fail "a missing row lacked a useful Actions diagnostic: $(cat "$EVIDENCE_TMP/actions.out") $(cat "$EVIDENCE_TMP/summary.md")"
fi
lr_body '' trivial
accepts && ok "trivial needs no Local review row" || fail "trivial was refused without a Local review row"

echo "==> Every policy file pins the required workflows at one touchstone-workflows revision"
# The engine a consumer's required validate runs is whatever the pinned
# validate.yml fetches; a stale pin failed every schema-2 consumer for eight
# days (AUT-417). Offline, this suite cannot read touchstone-workflows, so
# the invariant it can hold is: canonical and every consumer policy name the
# same revision for all three workflows, and that revision is the one the
# suite's own fixtures are written against -- so a revert or a partial bump
# is a visible, reviewed change here, never a silent divergence.
PINNED_WORKFLOWS_REVISION="118f04bd43e8b75a5175ec84c495d7abf3dc908c"
for policy_file in "$ROOT"/policy/github/touchstone-main.json "$ROOT"/policy/github/consumers/*.json; do
  pins="$(jq -r '[.managedRuleset.rules[] | select(.type == "workflows") | .parameters.workflows[] | .sha] | unique | join(" ")' "$policy_file")"
  [ "$pins" = "$PINNED_WORKFLOWS_REVISION" ] \
    || fail "$(basename "$policy_file") pins required workflows at '$pins', expected $PINNED_WORKFLOWS_REVISION"
  count="$(jq '[.managedRuleset.rules[] | select(.type == "workflows") | .parameters.workflows[]] | length' "$policy_file")"
  [ "$count" -eq 3 ] || fail "$(basename "$policy_file") declares $count required workflows, expected 3"
done
ok "canonical and consumer policies agree on the required-workflow revision"

echo "==> PASS: audited GitHub policy lifecycle is safe and deterministic"
