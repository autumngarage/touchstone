#!/usr/bin/env bash
# Offline lifecycle tests for the audited GitHub policy migration.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/github-policy.sh"
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
    emit '{"sha":"776669cd7429e988a4e3e3cb7ef9d5a33a38e8ab"}'
    ;;
  "GET repos/autumngarage/touchstone-workflows/contents/.github/workflows/validate.yml?ref=776669cd7429e988a4e3e3cb7ef9d5a33a38e8ab")
    emit '{"type":"file"}'
    ;;
  "GET repos/autumngarage/touchstone/contents/.github/workflows/validate.yml?ref=main")
    if [ "${GH_FAKE_MISSING_ROLLBACK_FILE:-0}" = 1 ]; then
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi
    emit "{\"type\":\"file\",\"sha\":\"${GH_FAKE_ROLLBACK_FILE_SHA:-c2dc082e0702090f3fc9de095d78a85ddde902a5}\"}"
    ;;
  "GET repos/autumngarage/touchstone-workflows/compare/776669cd7429e988a4e3e3cb7ef9d5a33a38e8ab...776669cd7429e988a4e3e3cb7ef9d5a33a38e8ab")
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
    emit "$(jq -c '.required_signatures // {enabled:false}' "$state/branch.json")"
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
    emit '[]'
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
      jq '[.rules[]]' "$state/ruleset.json"
    fi
    ;;
  *)
    echo "unhandled fake gh call: $method $endpoint" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

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
    "$TMP_DIR/state/branch-put-failed"
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
[ "$(git hash-object "$ROLLBACK_VALIDATE")" = "c2dc082e0702090f3fc9de095d78a85ddde902a5" ] \
  || fail "durable rollback workflow differs from its recorded prerequisite blob"
grep -Fq 'Policy operations require `gh`, `jq`, and `diff`.' "$POLICY_GUIDE" \
  || fail "policy guide does not declare its jq runtime dependency"
grep -Fq 'brew_install_if_missing "jq" "jq"' "$SETUP" \
  || fail "declared jq dependency is absent from setup"
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
[ "$(sed -n '2p' "$TMP_DIR/state/mutations.log")" = "DELETE branch-protection" ] \
  || fail "apply removed branch protection before verified ruleset install"
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

echo "==> Rollback restores before removing replacement"
run_policy rollback "$TMP_DIR/backup.json" "$POLICY"
[ -f "$TMP_DIR/state/branch.json" ] || fail "rollback did not restore branch protection"
[ ! -f "$TMP_DIR/state/ruleset.json" ] || fail "rollback did not remove the replacement ruleset"
tail -2 "$TMP_DIR/state/mutations.log" >"$TMP_DIR/rollback-order.txt"
diff -u <(printf 'PUT branch-protection\nDELETE org-ruleset\n') "$TMP_DIR/rollback-order.txt" >/dev/null \
  || fail "rollback created a protection gap"
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
run_policy verify "$TMP_DIR/updated-policy.json" >/dev/null \
  || fail "failed rollback update did not restore the prior ruleset"
diff -u <(printf 'PUT org-ruleset\nPUT org-ruleset\n') "$TMP_DIR/state/mutations.log" >/dev/null \
  || fail "failed rollback update did not restore the previous ruleset immediately"
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
diff -u <(printf 'PUT branch-protection\nDELETE org-ruleset\nPOST org-ruleset\n') \
  <(head -3 "$TMP_DIR/state/mutations.log") >/dev/null \
  || fail "failed rollback deletion did not restore the previous ruleset immediately"
tail -1 "$TMP_DIR/state/mutations.log" | grep -qx 'DELETE branch-protection' \
  || fail "failed rollback deletion did not restore the previous branch state"
run_policy verify "$POLICY" >/dev/null \
  || fail "failed rollback deletion did not verify the complete prior policy state"
ok "failed rollback deletion restores the prior active gate"

echo "==> PASS: audited GitHub policy lifecycle is safe and deterministic"
