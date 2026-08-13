#!/usr/bin/env bash
# Offline lifecycle tests for the audited GitHub policy migration.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/github-policy.sh"
POLICY="$ROOT/policy/github/touchstone-main.json"
BASELINE="$ROOT/policy/github/baseline-2026-08-13.json"
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
      emit '[{"id":123,"name":"Touchstone main delivery"},{"id":124,"name":"Touchstone main delivery"}]'
    elif [ -f "$state/ruleset.json" ]; then
      emit "$(jq '[{id:.id,name:.name}]' "$state/ruleset.json")"
    else
      emit '[]'
    fi
    ;;
  "GET orgs/autumngarage/rulesets/123")
    cat "$state/ruleset.json"
    ;;
  "POST orgs/autumngarage/rulesets")
    jq '(.rules[] | select(.type == "pull_request") | .parameters.required_reviewers) = [] | . + {id:123}' >"$state/ruleset.json"
    echo "POST org-ruleset" >>"$state/mutations.log"
    emit "$(cat "$state/ruleset.json")"
    ;;
  "PUT orgs/autumngarage/rulesets/123")
    jq '(.rules[] | select(.type == "pull_request") | .parameters.required_reviewers) = [] | . + {id:123}' >"$state/ruleset.json"
    echo "PUT org-ruleset" >>"$state/mutations.log"
    emit "$(cat "$state/ruleset.json")"
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
    if [ "${GH_FAKE_BRANCH_ERROR_ONCE:-0}" = 1 ] && [ ! -f "$state/branch-error-used" ]; then
      touch "$state/branch-error-used"
      echo "gh: API unavailable (HTTP 503)" >&2
      exit 1
    fi
    if [ ! -f "$state/branch.json" ]; then
      echo "gh: Branch not protected (HTTP 404)" >&2
      exit 1
    fi
    cat "$state/branch.json"
    ;;
  "PUT repos/autumngarage/touchstone/branches/main/protection")
    payload="$(cat)"
    jq -e '
      .restrictions == null or
      ((.restrictions.users + .restrictions.teams + .restrictions.apps) |
        all(.[]; type == "string"))
    ' <<<"$payload" >/dev/null || {
      echo "gh: restrictions must use login or slug strings (HTTP 422)" >&2
      exit 1
    }
    jq '{
      required_status_checks: .required_status_checks,
      enforce_admins: {enabled:.enforce_admins},
      required_pull_request_reviews: .required_pull_request_reviews,
      restrictions: (if .restrictions then {
        users: [.restrictions.users[] | {login:.}],
        teams: [.restrictions.teams[] | {slug:.}],
        apps: [.restrictions.apps[] | {slug:.}]
      } else null end),
      required_linear_history: {enabled:.required_linear_history},
      allow_force_pushes: {enabled:.allow_force_pushes},
      allow_deletions: {enabled:.allow_deletions},
      block_creations: {enabled:.block_creations},
      required_conversation_resolution: {enabled:.required_conversation_resolution},
      lock_branch: {enabled:.lock_branch},
      allow_fork_syncing: {enabled:.allow_fork_syncing}
    }' <<<"$payload" >"$state/branch.json"
    echo "PUT branch-protection" >>"$state/mutations.log"
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
    allow_force_pushes: {enabled:.branchProtection.allow_force_pushes},
    allow_deletions: {enabled:.branchProtection.allow_deletions},
    block_creations: {enabled:.branchProtection.block_creations},
    required_conversation_resolution: {enabled:.branchProtection.required_conversation_resolution},
    lock_branch: {enabled:.branchProtection.lock_branch},
    allow_fork_syncing: {enabled:.branchProtection.allow_fork_syncing}
  }' "$BASELINE" >"$TMP_DIR/state/branch.json"
  : >"$TMP_DIR/state/mutations.log"
  rm -f "$TMP_DIR/state/ruleset.json" "$TMP_DIR/state/bad-effective-used" \
    "$TMP_DIR/state/branch-error-used"
}

run_policy() {
  PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" "$SCRIPT" "$@"
}

echo "==> Checked-in policy invariants"
jq -e '
  .contractVersion == 1
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

echo "==> Backup, apply, and idempotency"
run_policy backup "$TMP_DIR/backup.json" "$POLICY"
jq -e '.branchProtection.required_status_checks.checks | length == 2' "$TMP_DIR/backup.json" >/dev/null \
  || fail "backup omitted current required checks"
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
}' "$TMP_DIR/state/branch.json" >"$TMP_DIR/state/restricted.json"
mv "$TMP_DIR/state/restricted.json" "$TMP_DIR/state/branch.json"
run_policy backup "$TMP_DIR/restricted-backup.json" "$POLICY" >/dev/null
jq -e '.branchProtection.restrictions == {
  users:["octocat"],teams:["release-engineers"],apps:["touchstone-bot"]
}' "$TMP_DIR/restricted-backup.json" >/dev/null \
  || fail "backup did not normalize restriction objects into writable strings"
run_policy apply "$POLICY" >/dev/null
run_policy rollback "$TMP_DIR/restricted-backup.json" "$POLICY" >/dev/null
jq -e '.restrictions == {
  users:[{login:"octocat"}],
  teams:[{slug:"release-engineers"}],
  apps:[{slug:"touchstone-bot"}]
}' "$TMP_DIR/state/branch.json" >/dev/null \
  || fail "rollback did not restore restricted branch protection"
ok "restricted protection round-trips through backup and rollback"

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
if PATH="$TMP_DIR/bin:$PATH" GH_FAKE_STATE="$TMP_DIR/state" GH_FAKE_BRANCH_ERROR_ONCE=1 \
  "$SCRIPT" rollback "$BASELINE" "$POLICY" >/dev/null 2>&1; then
  fail "rollback deletion succeeded after branch verification failed"
fi
[ -f "$TMP_DIR/state/ruleset.json" ] \
  || fail "failed rollback deletion did not recreate the prior ruleset"
diff -u <(printf 'PUT branch-protection\nDELETE org-ruleset\nPOST org-ruleset\n') \
  "$TMP_DIR/state/mutations.log" >/dev/null \
  || fail "failed rollback deletion did not restore the previous ruleset immediately"
ok "failed rollback deletion restores the prior active gate"

echo "==> PASS: audited GitHub policy lifecycle is safe and deterministic"
