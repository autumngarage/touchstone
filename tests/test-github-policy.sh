#!/usr/bin/env bash
# Offline lifecycle tests for the audited GitHub policy migration.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_SCRIPT="$ROOT/scripts/github-policy.sh"
SCRIPT="$SOURCE_SCRIPT"
POLICY="$ROOT/policy/github/touchstone-main.json"
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
endpoint=""
jq_filter=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    api) shift ;;
    -H) shift 2 ;;
    --method | -X) method="$2"; shift 2 ;;
    --input) shift 2 ;;
    --jq) jq_filter="$2"; shift 2 ;;
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
    emit '{"id":1333343261}'
    ;;
  "GET repos/autumngarage/touchstone-workflows/commits/main")
    emit '{"sha":"5719b59619add320b39c994cff696444b4b98c25"}'
    ;;
  "GET repos/autumngarage/touchstone-workflows/contents/.github/workflows/validate.yml?ref=5719b59619add320b39c994cff696444b4b98c25")
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
  "GET repos/autumngarage/touchstone-workflows/compare/5719b59619add320b39c994cff696444b4b98c25...5719b59619add320b39c994cff696444b4b98c25")
    emit '{"status":"identical"}'
    ;;
  "GET repos/autumngarage/touchstone-workflows/branches/main/protection")
    if [ "${GH_FAKE_SOURCE_UNPROTECTED:-0}" = 1 ]; then
      emit '{"enforce_admins":{"enabled":false},"required_pull_request_reviews":null,"required_conversation_resolution":{"enabled":false},"allow_force_pushes":{"enabled":true},"allow_deletions":{"enabled":true}}'
    else
      emit '{"enforce_admins":{"enabled":true},"required_pull_request_reviews":{},"required_conversation_resolution":{"enabled":true},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}'
    fi
    ;;
  "GET orgs/autumngarage/rulesets")
    if [ "${GH_FAKE_DUPLICATE_RULESET:-0}" = 1 ]; then
      emit '[{"id":123,"name":"Touchstone policy v1: autumngarage/touchstone@main"},{"id":124,"name":"Touchstone policy v1: autumngarage/touchstone@main"}]'
    elif [ "${GH_FAKE_UNRELATED_NAME_COLLISION:-0}" = 1 ]; then
      emit '[{"id":777,"name":"Touchstone main delivery"}]'
    elif [ -f "$state/ruleset.json" ]; then
      emit "$(jq '[{id:.id,name:.name}]' "$state/ruleset.json")"
    else
      emit '[]'
    fi
    ;;
  "GET orgs/autumngarage/rulesets/123")
    cat "$state/ruleset.json"
    ;;
  "GET orgs/autumngarage/rulesets/777")
    emit '{"id":777,"name":"Touchstone main delivery","target":"branch","enforcement":"active","bypass_actors":[],"conditions":{"repository_name":{"include":["other-repository"],"exclude":[],"protected":false},"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"deletion"}]}'
    ;;
  "POST orgs/autumngarage/rulesets")
    jq '(.rules[] | select(.type == "pull_request") | .parameters.required_reviewers) = [] | . + {id:123}' >"$state/ruleset.json"
    echo "POST org-ruleset" >>"$state/mutations.log"
    if [ "${GH_FAKE_FAIL_ORG_MUTATION_ONCE:-0}" = 1 ] && [ ! -f "$state/org-mutation-failed" ]; then
      touch "$state/org-mutation-failed"
      echo "gh: API unavailable after mutation (HTTP 503)" >&2
      exit 1
    fi
    emit "$(cat "$state/ruleset.json")"
    ;;
  "PUT orgs/autumngarage/rulesets/123")
    jq '(.rules[] | select(.type == "pull_request") | .parameters.required_reviewers) = [] | . + {id:123}' >"$state/ruleset.json"
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
  "GET repos/autumngarage/touchstone/rulesets/321")
    cat "$state/repo-ruleset.json"
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
mkdir -p "$RUNNER_REPO/scripts"
cp "$SOURCE_SCRIPT" "$RUNNER_REPO/scripts/github-policy.sh"
git -C "$RUNNER_REPO" init -q
git -C "$RUNNER_REPO" symbolic-ref HEAD refs/heads/main
git -C "$RUNNER_REPO" add scripts/github-policy.sh
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
    "$TMP_DIR/state/repo-ruleset.json"
}

run_policy() {
  PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" "$SCRIPT" "$@"
}

echo "==> Checked-in policy invariants"
jq -e '
  .contractVersion == 1
  and .managedRuleset.name == "Touchstone policy v1: autumngarage/touchstone@main"
  and .workflowSource.repository == "touchstone-workflows"
  and .workflowSource.repository != .repository
  and .rollbackPrerequisites.repositoryFiles == [{
    path: ".github/workflows/validate.yml",
    sha: "c2dc082e0702090f3fc9de095d78a85ddde902a5"
  }]
  and .workflowSource.branchProtection == {
    enforce_admins:true,
    required_pull_request_reviews:true,
    required_conversation_resolution:true,
    allow_force_pushes:false,
    allow_deletions:false
  }
  and (.managedRuleset.bypass_actors == [{actor_id:null,actor_type:"OrganizationAdmin",bypass_mode:"pull_request"}])
  and any(.managedRuleset.rules[]; .type == "pull_request" and .parameters.required_review_thread_resolution == true)
  and any(.managedRuleset.rules[]; .type == "required_status_checks" and any(.parameters.required_status_checks[]; .context == "review-binding" and .integration_id == 15368))
  and any(.managedRuleset.rules[]; .type == "workflows" and any(.parameters.workflows[];
    .repository_id == 1333343261
    and .path == ".github/workflows/validate.yml"
    and .ref == "refs/heads/main"
    and (.sha | test("^[0-9a-f]{40}$"))))
  and any(.managedRuleset.rules[]; .type == "deletion")
  and any(.managedRuleset.rules[]; .type == "non_fast_forward")
' "$POLICY" >/dev/null || fail "checked-in ruleset is missing a required invariant"
# The merged result is validated by the merge queue, not by making every open
# PR rebase: strict up-to-date is off and the queue rule is on, together. One
# without the other either serializes every merge (AUT-331) or lands
# combinations nothing tested.
jq -e '
  any(.managedRuleset.rules[]; .type == "required_status_checks" and .parameters.strict_required_status_checks_policy == false)
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
' "$POLICY" >/dev/null || fail "policy must pair a merge queue (in the repository ruleset: GitHub rejects it in an organization ruleset) with non-strict status checks"
# One entry per merge commit: the queue branch names a single PR and the
# publisher evaluates that PR, so a grouped merge commit would carry one PR's
# verdict for several. Grouping is re-enabled only with a publisher that
# aggregates every PR in the group.
# A queue rule makes the required review-binding context due on the queue's
# merge commit. This repository's publisher reaches that commit only through
# the signal workflow's merge_group handoff; a policy that enables the queue
# before that handoff exists ejects every entry. The order is enforced here,
# not in a PR description.
SIGNAL_WORKFLOW="$ROOT/.github/workflows/review-evidence-signal.yml"
if jq -e 'any(.managedRepositoryRuleset.rules[]?; .type == "merge_queue")' "$POLICY" >/dev/null; then
  grep -Fq 'merge_group:' "$SIGNAL_WORKFLOW" \
    || fail "policy enables a merge queue but review-evidence-signal.yml does not carry merge_group to the publisher"
fi
[ "$(git hash-object "$ROLLBACK_VALIDATE")" = "c2dc082e0702090f3fc9de095d78a85ddde902a5" ] \
  || fail "durable rollback workflow differs from its recorded prerequisite blob"
grep -Fq 'Policy operations require `gh`, `git`, `jq`, and `diff`.' "$POLICY_GUIDE" \
  || fail "policy guide does not declare its jq runtime dependency"
grep -Fq 'brew_install_if_missing "jq" "jq"' "$SETUP" \
  || fail "declared jq dependency is absent from setup"
grep -Fq '.rollbackPrerequisites.repositoryFiles = []' "$POLICY_GUIDE" \
  || fail "canary derivation retained Touchstone-only rollback prerequisites"
grep -Fq 'rollback restores the fresh' "$POLICY_GUIDE" \
  || fail "canary guide does not name the source of rollback protection"
grep -Fq '.managedRepositoryRuleset.name = "Touchstone merge queue v1: autumngarage/touchstone-policy-canary@main"' "$POLICY_GUIDE" \
  || fail "canary derivation does not re-derive the companion ruleset marker"
ok "ruleset expresses PR-only audited bypass and every native gate"

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
ok "self-hosted or unprotected required-workflow sources fail closed"

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
[ "$(sed -n '3p' "$TMP_DIR/state/mutations.log")" = "DELETE branch-protection" ] \
  || fail "apply removed branch protection before verified ruleset install"
jq -e 'any(.rules[]; .type == "merge_queue")' "$TMP_DIR/state/repo-ruleset.json" >/dev/null \
  || fail "companion repository ruleset does not carry the merge queue"
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
tail -3 "$TMP_DIR/state/mutations.log" >"$TMP_DIR/rollback-order.txt"
diff -u <(printf 'PUT branch-protection\nDELETE org-ruleset\nDELETE repo-ruleset\n') "$TMP_DIR/rollback-order.txt" >/dev/null \
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
jq '.managedRuleset.rules[] |= if .type == "required_status_checks" then
  (.parameters.required_status_checks += [{context:"new-policy-check",integration_id:15368}]) else . end' \
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

echo "==> PASS: audited GitHub policy lifecycle is safe and deterministic"
