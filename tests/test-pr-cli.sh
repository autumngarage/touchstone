#!/usr/bin/env bash
# Deterministic PR lifecycle boundary tests for scripts/touchstone-pr.sh and
# scripts/respond-review.sh: fake gh/git on PATH, no network.
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

ok() {
  echo "  OK: $*"
}

(
  # tests/test-pr-cli.sh — deterministic PR lifecycle boundary tests.

  set -euo pipefail

  ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
  TMP="$(mktemp -d -t touchstone-pr.XXXXXX)"
  trap '[ "${KEEP_TMP:-false}" = true ] || rm -rf "$TMP"' EXIT
  ERRORS=0

  fail() {
    echo "FAIL: $*" >&2
    ERRORS=$((ERRORS + 1))
  }
  assert_has() { grep -qF -- "$2" "$1" || fail "expected $1 to contain: $2"; }
  assert_not_has() { grep -qF -- "$2" "$1" && fail "expected $1 not to contain: $2" || true; }
  assert_rc() { [ "$1" -eq "$2" ] || fail "expected rc $2, got $1"; }

  mkdir -p "$TMP/bin" "$TMP/project/policy/github" "$TMP/origin.git" "$TMP/state"
  git -C "$TMP/origin.git" init -q --bare
  git -C "$TMP/project" init -q -b main
  git -C "$TMP/project" config user.name test
  git -C "$TMP/project" config user.email test@example.com
  printf 'fixture\n' >"$TMP/project/README.md"
  printf '%s\n' 'schema = 1' '' '[validation]' 'runtime = "bash"' \
    '' '[[validation.targets]]' 'name = "root"' 'path = "."' \
    '' '[[validation.tasks]]' 'name = "test"' 'target = "root"' \
    'command = "true"' 'required = true' >"$TMP/project/.touchstone.toml"
  printf '%s\n' 'schema = 1' 'type = "github"' >"$TMP/project/.touchstone-tracker.toml"
  cp "$ROOT/policy/github/touchstone-main.json" "$TMP/project/policy/github/touchstone-main.json"
  git -C "$TMP/project" add README.md .touchstone.toml .touchstone-tracker.toml policy/github/touchstone-main.json
  git -C "$TMP/project" commit -qm fixture
  git -C "$TMP/project" remote add origin "$TMP/origin.git"
  git -C "$TMP/project" push -qu origin main
  git -C "$TMP/project" remote set-head origin main
  MAIN_SHA="$(git -C "$TMP/project" rev-parse HEAD)"
  git -C "$TMP/project" switch -qc legacy-policy
  jq 'del(.workflowSource.sourceContract)' "$TMP/project/policy/github/touchstone-main.json" >"$TMP/legacy-policy.json"
  mv "$TMP/legacy-policy.json" "$TMP/project/policy/github/touchstone-main.json"
  git -C "$TMP/project" add policy/github/touchstone-main.json
  git -C "$TMP/project" commit -qm 'legacy policy fixture'
  GH_LEGACY_POLICY_SHA="$(git -C "$TMP/project" rev-parse HEAD)"
  git -C "$TMP/project" switch -qc feat/test "$MAIN_SHA"
  printf 'change\n' >>"$TMP/project/README.md"
  jq '(.managedRuleset.rules[] | select(.type == "workflows") | .parameters.workflows[].sha) = "9ab13f0c5d2e47bb8c6a1f30d94e7c2b5a08d613"' \
    "$TMP/project/policy/github/touchstone-main.json" >"$TMP/project/policy/github/touchstone-main.next.json"
  mv "$TMP/project/policy/github/touchstone-main.next.json" "$TMP/project/policy/github/touchstone-main.json"
  git -C "$TMP/project" add README.md
  git -C "$TMP/project" add policy/github/touchstone-main.json
  git -C "$TMP/project" commit -qm change
  git -C "$TMP/project" push -qu origin HEAD
  HEAD_SHA="$(git -C "$TMP/project" rev-parse HEAD)"
  git -C "$TMP/project" switch -qc empty-policy "$MAIN_SHA"
  : >"$TMP/project/policy/github/touchstone-main.json"
  git -C "$TMP/project" add policy/github/touchstone-main.json
  git -C "$TMP/project" commit -qm 'empty policy fixture'
  EMPTY_POLICY_SHA="$(git -C "$TMP/project" rev-parse HEAD)"
  git -C "$TMP/project" switch -q feat/test
  printf '%s\n' 'Change summary.' '' 'Closes #42' >"$TMP/body"
  printf '%s\n' 'Handled the finding.' >"$TMP/reply"

  cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_CALLS"
has() { local needle="$1"; shift; printf '%s\n' "$*" | grep -qF -- "$needle"; }
serve_rules() {
  # A real effective-rules document through the caller's real jq: the
  # policy's three pinned workflows plus the queue and the native rules
  # when the gate is "installed", only the native rules otherwise.
  pr_rule='{"type":"pull_request","parameters":{"required_review_thread_resolution":true}}'
  [ ! -f "$GH_STATE/pr-rule-no-threads" ] || pr_rule='{"type":"pull_request","parameters":{}}'
  if [ "${GH_FAKE_REPO:-${GH_REPO:-autumngarage/current}}" = autumngarage/touchstone-workflows ]; then
    rules="[$pr_rule"
    [ -f "$GH_STATE/source-no-deletion" ] || rules="$rules"',{"type":"deletion"}'
    [ -f "$GH_STATE/source-no-non-fast-forward" ] || rules="$rules"',{"type":"non_fast_forward"}'
    [ -f "$GH_STATE/no-queue-rule" ] || rules="$rules"',{"type":"merge_queue"}'
    [ -f "$GH_STATE/source-no-status" ] || rules="$rules"',{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"source contract"}]}}'
    rules="$rules]"
  elif [ -f "$GH_STATE/review-gate" ]; then
    # validate and review-gate carry the fixture's variant pin; delivery-evidence
    # stays at the policy revision, so a variant names exactly two gates.
    pin_sha="$GH_POLICY_SHA"
    evidence_sha="$GH_POLICY_SHA"
    evidence_source_id=1333343261
    source_id=1333343261
    [ ! -f "$GH_STATE/stale-pin" ] || pin_sha="$GH_DIVERGED_SHA"
    [ ! -f "$GH_STATE/behind-pin" ] || pin_sha="$GH_BEHIND_SHA"
    [ ! -f "$GH_STATE/offref-pin" ] || pin_sha="$GH_OFFREF_SHA"
    [ ! -f "$GH_STATE/unknown-pin" ] || pin_sha="$GH_UNKNOWN_SHA"
    [ ! -f "$GH_STATE/other-source-pin" ] || source_id=424242
    [ ! -f "$GH_STATE/local-evidence-rule" ] || evidence_source_id=424243
    # The AUT-559 shape: the deployed ruleset pins the source branch head,
    # several revisions ahead of the policy the installed tool carries.
    if [ -f "$GH_STATE/ahead-pin" ]; then
      pin_sha="$GH_AHEAD_SHA"
      evidence_sha="$GH_AHEAD_SHA"
    fi
    extra_workflows=""
    ahead_workflows="$(printf ',{"path":".github/workflows/validate.yml","repository_id":1333343261,"ref":"refs/heads/main","sha":"%s"},{"path":".github/workflows/review-gate.yml","repository_id":1333343261,"ref":"refs/heads/main","sha":"%s"},{"path":".github/workflows/delivery-evidence.yml","repository_id":1333343261,"ref":"refs/heads/main","sha":"%s"}' "$GH_AHEAD_SHA" "$GH_AHEAD_SHA" "$GH_AHEAD_SHA")"
    if [ -f "$GH_STATE/overlapping-pins" ]; then
      pin_sha="$GH_MID_SHA"
      evidence_sha="$GH_MID_SHA"
      extra_workflows="$ahead_workflows"
    fi
    if [ -f "$GH_STATE/incompatible-evidence-overlap" ]; then
      evidence_sha="$GH_BEHIND_SHA"
      extra_workflows="$ahead_workflows"
    fi
    [ ! -f "$GH_STATE/overlapping-exact-pins" ] || extra_workflows="$ahead_workflows"
    queue_rule=',{"type":"merge_queue"}'
    [ ! -f "$GH_STATE/no-queue-rule" ] || queue_rule=""
    status_rule=""
    [ ! -f "$GH_STATE/consumer-status" ] || status_rule=',{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"convoy/delivery-protocol"}]}}'
    rules='['"$pr_rule"',{"type":"deletion"},{"type":"non_fast_forward"}'"$queue_rule"',{"type":"workflows","parameters":{"workflows":[{"path":".github/workflows/validate.yml","repository_id":'"$source_id"',"ref":"refs/heads/main","sha":"'"$pin_sha"'"},{"path":".github/workflows/review-gate.yml","repository_id":'"$source_id"',"ref":"refs/heads/main","sha":"'"$pin_sha"'"},{"path":".github/workflows/delivery-evidence.yml","repository_id":'"$evidence_source_id"',"ref":"refs/heads/main","sha":"'"$evidence_sha"'"}'"$extra_workflows"']}}'"$status_rule"']'
    if [ -f "$GH_STATE/no-review-gate-rule" ]; then
      rules="$(printf '%s' "$rules" | jq -c 'map(if .type == "workflows" then .parameters.workflows |= map(select(.path != ".github/workflows/review-gate.yml")) else . end)')"
    fi
  elif [ -f "$GH_STATE/no-rules" ]; then
    rules='[]'
  else
    rules='[{"type":"pull_request","parameters":{"required_review_thread_resolution":true}},{"type":"deletion"},{"type":"non_fast_forward"}]'
  fi
  # Served as two pages, as --paginate would deliver them: the native
  # rules on one page, the workflows and queue on the next.
  page1="$(printf '%s' "$rules" | jq -c '[.[] | select(.type != "workflows" and .type != "merge_queue")]')"
  page2="$(printf '%s' "$rules" | jq -c '[.[] | select(.type == "workflows" or .type == "merge_queue")]')"
  if has --jq "$@"; then
    if [ -f "$GH_STATE/required-workflow-later-page" ]; then
      # Match gh api: without --paginate only page one exists; with it the
      # inline filter runs once per page rather than over an aggregate.
      printf '%s' "$page1" | jq -r "$(value_after --jq "$@")"
      if has --paginate "$@"; then printf '%s' "$page2" | jq -r "$(value_after --jq "$@")"; fi
    else
      printf '%s' "$rules" | jq -r "$(value_after --jq "$@")"
    fi
  else
    printf '%s\n' "$page1"
    if has --paginate "$@"; then printf '%s\n' "$page2"; fi
  fi
}

value_after() {
  local wanted="$1"
  shift
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "$wanted" ]; then
      printf '%s\n' "$2"
      return 0
    fi
    shift
  done
  return 1
}

budget_item() {
  jq -cn "$@" | jq -r @base64
}

case "$1 ${2:-}" in
  "auth status")
    [ "${GH_MODE:-ok}" != auth_fail ]
    [ "${GH_MODE:-ok}" != auth_unrelated ] || has '--hostname' "$@"
    ;;
  "repo view")
    [ "${GH_MODE:-ok}" != success_stderr ] || printf 'repo debug detail\n' >&2
    # The window the late re-check exists for: the repository read is one of
    # the calls that sit between the two branch comparisons, so switching the
    # checkout here is exactly the race a real worktree can lose.
    if [ -n "${GH_SWITCH_BRANCH_IN:-}" ]; then
      git -C "$GH_SWITCH_BRANCH_IN" checkout -q -b feat/moved 2>/dev/null \
        || git -C "$GH_SWITCH_BRANCH_IN" checkout -q feat/moved
    fi
    fake_repo="${GH_FAKE_REPO:-${GH_REPO:-autumngarage/current}}"
    printf '%s\thttps://%s/%s\tmain\n' "$fake_repo" "${GH_REPO_HOST:-github.com}" "$fake_repo"
    ;;
  "pr list")
    if [ -f "$GH_STATE/pr-exists" ]; then
      head="$GH_HEAD"
      if [ "${GH_MODE:-ok}" = list_head_stale ]; then
        head=stale-head-0000000000000000000000000000
      elif [ "${GH_MODE:-ok}" = list_head_stale_then_current ]; then
        stale_reads=0
        [ ! -f "$GH_STATE/stale-head-reads" ] || stale_reads="$(cat "$GH_STATE/stale-head-reads")"
        stale_reads=$((stale_reads + 1))
        printf '%s\n' "$stale_reads" >"$GH_STATE/stale-head-reads"
        [ "$stale_reads" -ge 3 ] || head=stale-head-0000000000000000000000000000
      fi
      printf '7\thttps://example.test/pr/7\t%s\t%s\t%s\n' \
        "$head" "${GH_BASE_REF:-main}" "${GH_BASE_SHA:-base-sha}"
    fi
    ;;
  "pr edit")
    echo "pr edit $*" >>"$GH_STATE/edits"
    if has --body-file "$@"; then cp "$(value_after --body-file "$@")" "$GH_STATE/pr-body"; fi
    if has --title "$@"; then printf '%s' "$(value_after --title "$@")" >"$GH_STATE/pr-title"; fi
    ;;
  "pr create")
    case "${GH_MODE:-ok}" in
      create_missing) exit 1 ;;
      create_lied)
        touch "$GH_STATE/pr-exists"
        cp "$(value_after --body-file "$@")" "$GH_STATE/pr-body"
        echo 'gateway error' >&2
        exit 1
        ;;
      *)
        touch "$GH_STATE/pr-exists"
        cp "$(value_after --body-file "$@")" "$GH_STATE/pr-body"
        printf '%s\n' https://example.test/pr/7
        ;;
    esac
    ;;
  "pr comment")
    if has 'touchstone:unguarded-merge' "$@"; then
      touch "$GH_STATE/unguarded-recorded"
      printf '%s\n' https://example.test/pr/7#issuecomment-9
      exit 0
    fi
    [ "${GH_MODE:-ok}" != comment_success_stderr ] || printf 'comment debug detail\n' >&2
    [ "${GH_MODE:-ok}" = comment_unverified ] ||
      printf '%s %s %s\n' "$GH_HEAD" "$GH_BASE_REF" "$GH_BASE_SHA" >"$GH_STATE/review-request"
    [ "${GH_MODE:-ok}" != comment_lied ] || exit 1
    printf '%s\n' https://example.test/pr/7#issuecomment-1
    ;;
  "pr view")
    [ "${GH_MODE:-ok}" != success_stderr ] || printf 'view debug detail\n' >&2
    if [ "${GH_MODE:-ok}" = read_retry ] && [ ! -f "$GH_STATE/retried" ]; then
      touch "$GH_STATE/retried"
      exit 1
    fi
    if has '--json headRefOid,baseRefName,baseRefOid,mergeStateStatus' "$@"; then
      if [ "${GH_MODE:-ok}" = conflicting_pr_moved ]; then
        printf 'moved-head\t%s\t%s\tDIRTY\n' "$GH_BASE_REF" "$GH_BASE_SHA"
      elif [ "${GH_MODE:-ok}" = conflicting_pr ]; then
        printf '%s\t%s\t%s\tDIRTY\n' "$GH_HEAD" "$GH_BASE_REF" "$GH_BASE_SHA"
      elif [ "${GH_MODE:-ok}" = unknown_mergeability ]; then
        printf '%s\t%s\t%s\tUNKNOWN\n' "$GH_HEAD" "$GH_BASE_REF" "$GH_BASE_SHA"
      else
        printf '%s\t%s\t%s\tCLEAN\n' "$GH_HEAD" "$GH_BASE_REF" "$GH_BASE_SHA"
      fi
    elif has '--json headRefOid,baseRefName,baseRefOid' "$@"; then
      if [ "${GH_MODE:-ok}" = binding_moved ] || [ "${GH_MODE:-ok}" = moved_during_gate ] \
        || { [ "${GH_MODE:-ok}" = delivery_moved ] && [ -f "$GH_STATE/evidence-reruns" ]; } \
        || { [ "${GH_MODE:-ok}" = candidate_files_moved ] && [ -f "$GH_STATE/candidate-files-read" ]; }; then
        printf 'moved-head\t%s\t%s\n' "$GH_BASE_REF" "$GH_BASE_SHA"
      elif [ "${GH_MODE:-ok}" = base_advanced ]; then
        printf '%s\t%s\tadvanced-base-sha\n' "$GH_HEAD" "$GH_BASE_REF"
      else
        printf '%s\t%s\t%s\n' "$GH_HEAD" "$GH_BASE_REF" "$GH_BASE_SHA"
      fi
    elif has '--json headRefOid,baseRefName' "$@"; then
      if [ "${GH_MODE:-ok}" = moved_during_gate ]; then
        printf 'moved-head\t%s\n' "$GH_BASE_REF"
      else
        printf '%s\t%s\n' "$GH_HEAD" "$GH_BASE_REF"
      fi
    elif has '--json title,body' "$@"; then
      title="Test PR"; [ -f "$GH_STATE/pr-title" ] && title="$(cat "$GH_STATE/pr-title")"
      if [ -f "$GH_STATE/pr-body" ]; then body="$(cat "$GH_STATE/pr-body")"; else body="$(printf '%s\n' 'Change summary.' '' 'Closes #42')"; fi
      jq -cn --arg t "$title" --arg b "$body" '[$t, $b]'
    elif has '--json body' "$@"; then
      if [ "${GH_MODE:-ok}" = delivery_body_moved ] && [ -f "$GH_STATE/gate-reruns" ]; then
        printf 'Concurrent body mutation.\n'
      elif [ -f "$GH_STATE/pr-body" ]; then
        cat "$GH_STATE/pr-body"
      else
        printf '%s\n' 'Change summary.' '' 'Closes #42'
      fi
    elif has '--json state,url' "$@"; then
      if [ -f "$GH_STATE/merged" ]; then printf 'MERGED\thttps://example.test/pr/7\n'; else printf 'OPEN\thttps://example.test/pr/7\n'; fi
    elif [ -f "$GH_STATE/merged" ]; then
      head_repo="${GH_FAKE_HEAD_REPO:-${GH_FAKE_REPO:-${GH_REPO:-autumngarage/current}}}"
      [ ! -f "$GH_STATE/head-repo-missing" ] || head_repo=-
      printf '7\tMERGED\thttps://example.test/pr/7\t%s\t%s\tmain\t%s\tUNKNOWN\tfalse\n' \
        "$GH_HEAD" "$head_repo" "${GH_BASE_SHA:-base-sha}"
    else
      head_repo="${GH_FAKE_HEAD_REPO:-${GH_FAKE_REPO:-${GH_REPO:-autumngarage/current}}}"
      [ ! -f "$GH_STATE/head-repo-missing" ] || head_repo=-
      pr_state=OPEN
      merge_state=CLEAN
      draft=false
      case "${GH_MODE:-ok}" in
        status_closed) pr_state=CLOSED ;;
        status_merged) pr_state=MERGED ;;
        status_gate_queue_removed | status_gate_blocked_success) merge_state=BLOCKED ;;
      esac
      [ ! -f "$GH_STATE/status-draft" ] || draft=true
      [ ! -f "$GH_STATE/status-conflicts" ] || merge_state=DIRTY
      printf '7\t%s\thttps://example.test/pr/7\t%s\t%s\tmain\t%s\t%s\t%s\n' \
        "$pr_state" "$GH_HEAD" "$head_repo" "${GH_BASE_SHA:-base-sha}" "$merge_state" "$draft"
    fi
    ;;
  "pr merge")
    if [ "${GH_MODE:-ok}" = merge_failed ]; then exit 1; fi
    if [ "${GH_MODE:-ok}" = merge_reconcile_failed ]; then
      printf 'merge rejected by rules\n' >&2
      exit 1
    fi
    case "${GH_MODE:-ok}" in merge_queue | auto_merge | merge_queue_unmergeable_after) exit 0 ;; esac
    touch "$GH_STATE/merged"
    case "${GH_MODE:-ok}" in merge_lied | merge_head_moved) exit 1 ;; esac
    ;;
  "issue view")
    if [ -f "$GH_STATE/merged" ]; then printf 'CLOSED\tCOMPLETED\n'; else printf 'OPEN\t\n'; fi
    ;;
  "api user") printf '%s\n' alice ;;
  "api graphql")
    if has 'autoMergeEnabledAt' "$@"; then
      if [ "${GH_MODE:-ok}" = status_observation_failure ]; then
        printf 'GraphQL unavailable\n' >&2
        exit 1
      fi
      observed_head="$GH_HEAD"
      [ "${GH_MODE:-ok}" != status_head_moved ] || observed_head=moved-head
      auto_merge_enabled_at=null
      [ "${GH_MODE:-ok}" != status_auto_merge ] || auto_merge_enabled_at='"2026-08-24T20:00:00Z"'
      queue_state=null
      case "${GH_MODE:-ok}" in
        status_gate_queued) queue_state='"AWAITING_CHECKS"' ;;
        status_gate_queue_unmergeable) queue_state='"UNMERGEABLE"' ;;
        status_gate_queue_unknown) queue_state='"FUTURE_STATE"' ;;
        merge_queue_existing) queue_state='"AWAITING_CHECKS"' ;;
        merge_queue_unknown_existing) queue_state='"FUTURE_STATE"' ;;
      esac
      printf '{"head":"%s","autoMergeEnabledAt":%s,"mergeQueueState":%s}\n' \
        "$observed_head" "$auto_merge_enabled_at" "$queue_state"
    elif has 'mergeQueueEntry' "$@"; then
      if [ "${GH_MODE:-ok}" = merge_reconcile_failed ]; then
        printf 'GraphQL unavailable\n' >&2
        exit 1
      elif [ "${GH_MODE:-ok}" = merge_head_moved ]; then
        printf 'MERGED\thttps://example.test/pr/7\tmoved-head\tfalse\t\n'
      elif [ "${GH_MODE:-ok}" = merge_queue_unmergeable_after ]; then
        printf 'OPEN\thttps://example.test/pr/7\t%s\tfalse\tUNMERGEABLE\n' "$GH_HEAD"
      elif [ -f "$GH_STATE/merged" ]; then
        printf 'MERGED\thttps://example.test/pr/7\t%s\tfalse\t\n' "$GH_HEAD"
      elif [ "${GH_MODE:-ok}" = merge_queue ]; then
        printf 'OPEN\thttps://example.test/pr/7\t%s\tfalse\tQUEUED\n' "$GH_HEAD"
      elif [ "${GH_MODE:-ok}" = auto_merge ]; then
        printf 'OPEN\thttps://example.test/pr/7\t%s\ttrue\t\n' "$GH_HEAD"
      else
        printf 'OPEN\thttps://example.test/pr/7\t%s\tfalse\t\n' "$GH_HEAD"
      fi
    elif has '... on WorkflowRun' "$@"; then
      run_node=""
      for field in "$@"; do case "$field" in id=*) run_node="${field#id=}" ;; esac; done
      run_id="${run_node#RUN_}"
      source_revision="$GH_POLICY_SHA"
      source_repository="autumngarage/touchstone-workflows"
      source_path=".github/workflows/review-gate.yml"
      case "$run_id" in
        80) source_path=".github/workflows/delivery-evidence.yml" ;;
        82)
          source_repository="autumngarage/decoy-workflows"
          source_path=".github/workflows/delivery-evidence.yml"
          ;;
      esac
      [ ! -f "$GH_STATE/ahead-pin" ] || source_revision="$GH_AHEAD_SHA"
      [ ! -f "$GH_STATE/incompatible-evidence-run" ] || [ "$run_id" != 80 ] \
        || source_revision="$GH_BEHIND_SHA"
      [ "${GH_MODE:-ok}" != status_gate_historical ] || source_revision="$GH_AHEAD_SHA"
      [ ! -f "$GH_STATE/gate-run-unbound" ] || [ "$run_id" = 80 ] || source_revision="$GH_AHEAD_SHA"
      jq -cn --argjson id "$run_id" --arg revision "$source_revision" \
        --arg repository "$source_repository" --arg path "$source_path" \
        '{data:{node:{databaseId:$id,file:{path:$path,repositoryName:$repository,repositoryFileUrl:("https://github.com/" + $repository + "/blob/" + $revision + "/" + $path)}}}}'
    elif has 'resolveReviewThread' "$@"; then
      printf '%s\n' true
    elif has 'node(id:' "$@"; then
      printf '%s\n' true
    elif has 'threadId:.id' "$@"; then
      printf '%s\n' '[{"threadId":"T1","resolved":false,"commentId":51,"path":"app.js","body":"fix it","url":"https://example.test/thread"}]'
    elif has 'select(.comments.nodes[0].databaseId' "$@"; then
      printf '%s\n' T1
    elif has 'select(.isResolved == false)' "$@"; then
      [ "${GH_MODE:-ok}" != unresolved ] || printf 'T1\t51\tapp.js\n'
    else
      printf '%s\n' '  thread 51 [resolved=false] app.js'
    fi
    ;;
  "api --paginate")
    if has 'rules/branches/' "$@"; then
      serve_rules "$@"
    elif has '/actions/runs/88/attempts/1/jobs?per_page=100' "$@"; then
      if [ "${GH_MODE:-ok}" = status_gate_new_run_race ]; then
        printf '%s\n' '{"jobs":[{"id":89,"name":"review-gate","run_attempt":1,"status":"in_progress","conclusion":null}]}'
      else
        printf '%s\n' '{"jobs":[{"id":89,"name":"review-gate","run_attempt":1,"status":"completed","conclusion":"failure"}]}'
      fi
    elif has '/actions/runs/77/attempts/3/jobs?per_page=100' "$@"; then
      if [ "${GH_MODE:-ok}" = status_gate_run_recency ]; then
        printf '%s\n' '{"jobs":[{"id":88,"name":"review-gate","run_attempt":3,"status":"completed","conclusion":"success"}]}'
      else
        printf '%s\n' '{"jobs":[{"id":87,"name":"review-gate","run_attempt":3,"status":"in_progress","conclusion":null}]}'
      fi
    elif has '/actions/runs/77/attempts/2/jobs?per_page=100' "$@"; then
      case "${GH_MODE:-ok}" in
        status_gate_pending | status_gate_run_recency)
          printf '%s\n' '{"jobs":[{"id":81,"name":"review-gate","run_attempt":2,"status":"in_progress","conclusion":null}]}' ;;
        status_gate_failure | status_gate_collision)
          printf '%s\n' '{"jobs":[{"id":82,"name":"review-gate","run_attempt":2,"status":"completed","conclusion":"failure"}]}' ;;
        status_gate_cancelled)
          printf '%s\n' '{"jobs":[{"id":82,"name":"review-gate","run_attempt":2,"status":"completed","conclusion":"cancelled"}]}' ;;
        status_gate_workflow_cancelled)
          printf '%s\n' '{"jobs":[]}' ;;
        status_gate_success | status_gate_historical)
          printf '%s\n' '{"jobs":[{"id":84,"name":"review-gate","run_attempt":2,"status":"completed","conclusion":"success"}]}' ;;
        status_gate_status_race)
          printf '%s\n' '{"jobs":[{"id":84,"name":"review-gate","run_attempt":2,"status":"completed","conclusion":"success"}]}' ;;
        status_gate_attempt_race)
          printf '%s\n' '{"jobs":[{"id":84,"name":"review-gate","run_attempt":2,"status":"completed","conclusion":"success"}]}' ;;
        status_gate_stale_attempt)
          printf '%s\n' '{"jobs":[{"id":86,"name":"review-gate","run_attempt":2,"status":"in_progress","conclusion":null}]}' ;;
        status_gate_stale)
          printf '%s\n' '{"jobs":[{"id":85,"name":"review-gate","run_attempt":2,"status":"completed","conclusion":"success"}]}' ;;
        *) printf '%s\n' '{"jobs":[{"id":84,"name":"review-gate","run_attempt":2,"status":"completed","conclusion":"success"}]}' ;;
      esac
    elif has 'check-runs?check_name=review-gate&filter=all&per_page=100' "$@"; then
      case "${GH_MODE:-ok}" in
        status_gate_pending)
          jq -cn --arg head "$GH_HEAD" '{check_runs:[{id:81,name:"review-gate",head_sha:$head,check_suite:{id:900},status:"in_progress",conclusion:null,details_url:"https://example.test/runs/81",output:{title:"Evaluating exact-head review",summary:"Waiting for hosted review evidence."}}]}'
          ;;
        status_gate_failure)
          jq -cn --arg head "$GH_HEAD" '{check_runs:[{id:82,name:"review-gate",head_sha:$head,check_suite:{id:900},status:"completed",conclusion:"failure",details_url:"https://example.test/runs/82",output:{title:"No request binds this head",summary:"Run touchstone pr open for the live head."}}]}'
          ;;
        status_gate_cancelled)
          jq -cn --arg head "$GH_HEAD" '{check_runs:[{id:82,name:"review-gate",head_sha:$head,check_suite:{id:900},status:"completed",conclusion:"cancelled",details_url:"https://example.test/runs/82",output:{title:"Review evaluation cancelled",summary:"Inspect the workflow run."}}]}'
          ;;
        status_gate_workflow_cancelled)
          jq -cn '{check_runs:[]}'
          ;;
        status_gate_success | status_gate_historical)
          jq -cn --arg head "$GH_HEAD" '{check_runs:[
            {id:83,name:"review-gate",head_sha:$head,check_suite:{id:900},status:"completed",conclusion:"failure",details_url:"https://example.test/runs/83",output:{title:"Superseded attempt",summary:"Old evidence."}},
            {id:84,name:"review-gate",head_sha:$head,check_suite:{id:900},status:"completed",conclusion:"success",completed_at:"2026-08-27T17:30:00Z",details_url:"https://example.test/runs/84",output:{title:"Exact-head review accepted",summary:"All review feedback was answered."}}
          ]}'
          ;;
        status_gate_status_race)
          touch "$GH_STATE/status-run-completed"
          jq -cn --arg head "$GH_HEAD" '{check_runs:[
            {id:84,name:"review-gate",head_sha:$head,check_suite:{id:900},status:"completed",conclusion:"success",details_url:"https://example.test/runs/84",output:{title:"Exact-head review accepted",summary:"The run completed during observation."}}
          ]}'
          ;;
        status_gate_run_recency)
          jq -cn --arg head "$GH_HEAD" '{check_runs:[{id:88,name:"review-gate",head_sha:$head,check_suite:{id:900},status:"completed",conclusion:"success",details_url:"https://example.test/runs/88",output:{title:"Latest execution accepted",summary:"The rerun completed successfully."}}]}'
          ;;
        status_gate_run_overlap)
          jq -cn --arg head "$GH_HEAD" '{check_runs:[{id:89,name:"review-gate",head_sha:$head,check_suite:{id:906},status:"completed",conclusion:"failure",details_url:"https://example.test/runs/89",output:{title:"Later attempt rejected",summary:"The later-started run completed first."}}]}'
          ;;
        status_gate_attempt_race)
          touch "$GH_STATE/status-attempt-advanced"
          jq -cn --arg head "$GH_HEAD" '{check_runs:[
            {id:84,name:"review-gate",head_sha:$head,check_suite:{id:900},status:"completed",conclusion:"success",details_url:"https://example.test/runs/84",output:{title:"Superseded success",summary:"Previous attempt."}},
            {id:87,name:"review-gate",head_sha:$head,check_suite:{id:900},status:"in_progress",conclusion:null,details_url:"https://example.test/runs/87",output:{title:"Evaluating rerun",summary:"Current attempt."}}
          ]}'
          ;;
        status_gate_new_run_race)
          touch "$GH_STATE/status-new-run-started"
          jq -cn --arg head "$GH_HEAD" '{check_runs:[
            {id:84,name:"review-gate",head_sha:$head,check_suite:{id:900},status:"completed",conclusion:"success",details_url:"https://example.test/runs/84",output:{title:"Superseded success",summary:"Previous execution."}},
            {id:89,name:"review-gate",head_sha:$head,check_suite:{id:906},status:"in_progress",conclusion:null,details_url:"https://example.test/runs/89",output:{title:"Evaluating new execution",summary:"Current execution."}}
          ]}'
          ;;
        status_gate_collision)
          jq -cn --arg head "$GH_HEAD" '{check_runs:[
            {id:82,name:"review-gate",head_sha:$head,check_suite:{id:900},status:"completed",conclusion:"failure",details_url:"https://example.test/runs/82",output:{title:"No request binds this head",summary:"Run touchstone pr open for the live head."}},
            {id:999,name:"review-gate",head_sha:$head,check_suite:{id:901},status:"completed",conclusion:"success",details_url:"https://example.test/runs/999",output:{title:"Local look-alike passed",summary:"This is not the policy gate."}}
          ]}'
          ;;
        status_gate_stale_attempt)
          jq -cn --arg head "$GH_HEAD" '{check_runs:[
            {id:84,name:"review-gate",head_sha:$head,check_suite:{id:900},status:"completed",conclusion:"success",details_url:"https://example.test/runs/84",output:{title:"Superseded success",summary:"Previous attempt."}},
            {id:86,name:"review-gate",head_sha:$head,check_suite:{id:900},status:"in_progress",conclusion:null,details_url:"https://example.test/runs/86",output:{title:"Evaluating current attempt",summary:"Waiting for evidence."}}
          ]}'
          ;;
        status_gate_stale)
          jq -cn --arg head "$GH_HEAD" '{check_runs:[{id:85,name:"review-gate",head_sha:"stale-head",check_suite:{id:900},status:"completed",conclusion:"success",details_url:"https://example.test/runs/85",output:{title:"Stale success",summary:"Wrong head."}}]}'
          ;;
        status_gate_malformed) : ;;
        *)
          jq -cn --arg head "$GH_HEAD" '{check_runs:[{id:84,name:"review-gate",head_sha:$head,check_suite:{id:900},status:"completed",conclusion:"success",completed_at:"2026-08-27T17:30:00Z",details_url:"https://example.test/runs/84",output:{title:"Exact-head review accepted",summary:"All review feedback was answered."}}]}'
          ;;
      esac
    elif has '/pulls/7/files?per_page=100' "$@"; then
      [ "${GH_MODE:-ok}" != candidate_files_moved ] || touch "$GH_STATE/candidate-files-read"
      if [ -f "$GH_STATE/policy-unchanged" ]; then
        :
      elif [ -f "$GH_STATE/policy-removed" ]; then
        printf 'removed\tpolicy/github/touchstone-main.json\t-\n'
      elif [ -f "$GH_STATE/policy-renamed" ]; then
        printf 'renamed\tpolicy/github/touchstone-renamed.json\tpolicy/github/touchstone-main.json\n'
      else
        printf 'modified\tpolicy/github/touchstone-main.json\t-\n'
      fi
    elif has 'touchstone:unguarded-merge' "$@"; then
      # The count of prior unguarded-merge records for this head, one per
      # page as --paginate delivers it: two pages, the record (if any) on the
      # second.
      if [ -f "$GH_STATE/unguarded-recorded" ]; then printf '0\n1\n'; else printf '0\n0\n'; fi
    elif has '.[] | @base64' "$@" && [ -f "$GH_STATE/review-budget-fixture" ]; then
      request_one='@codex review

<!-- touchstone:pr-open head=1111111111111111111111111111111111111111 base=main base_sha=base-sha -->'
      request_two='@codex review

<!-- touchstone:pr-open head=2222222222222222222222222222222222222222 base=main base_sha=base-sha -->'
      request_three='@codex review

<!-- touchstone:pr-open head=3333333333333333333333333333333333333333 base=main base_sha=base-sha -->'
      request_four='@codex review

<!-- touchstone:pr-open head=5555555555555555555555555555555555555555 base=main base_sha=base-sha -->'
      request_five='@codex review

<!-- touchstone:pr-open head=6666666666666666666666666666666666666666 base=main base_sha=base-sha -->'
      if has '/issues/7/comments' "$@"; then
        budget_item --arg body "$request_one" '{id:1,created_at:"2026-08-27T10:00:00Z",updated_at:"2026-08-27T10:00:00Z",user:{login:"alice"},body:$body}'
        # A replacement provider trigger on the same head is one round, not two.
        budget_item --arg body "$request_one" '{id:2,created_at:"2026-08-27T10:01:00Z",updated_at:"2026-08-27T10:01:00Z",user:{login:"alice"},body:$body}'
        budget_item --arg body "$request_two" '{id:3,created_at:"2026-08-27T11:00:00Z",updated_at:"2026-08-27T11:00:00Z",user:{login:"alice"},body:$body}'
        budget_item --arg body "$request_three" '{id:4,created_at:"2026-08-27T12:00:00Z",updated_at:"2026-08-27T12:00:00Z",user:{login:"alice"},body:$body}'
        budget_item --arg body "$request_four" '{id:5,created_at:"2026-08-27T14:00:00Z",updated_at:"2026-08-27T14:00:00Z",user:{login:"alice"},body:$body}'
        budget_item --arg body 'Codex Review: P1 result finding

**Reviewed commit:** `5555555`' '{id:6,created_at:"2026-08-27T14:05:00Z",updated_at:"2026-08-27T14:05:00Z",user:{login:"chatgpt-codex-connector[bot]"},body:$body}'
        budget_item --arg body "$request_five" '{id:7,created_at:"2026-08-27T15:00:00Z",updated_at:"2026-08-27T15:00:00Z",user:{login:"alice"},body:$body}'
        budget_item --arg body "Codex Review: Didn't find any major issues.

**Reviewed commit:** \`6666666\`" '{id:8,created_at:"2026-08-27T15:05:00Z",updated_at:"2026-08-27T15:05:00Z",user:{login:"chatgpt-codex-connector[bot]"},body:$body}'
      elif has '/pulls/7/reviews' "$@"; then
        budget_item '{id:61,commit_id:"1111111111111111111111111111111111111111",submitted_at:"2026-08-27T10:05:00Z",updated_at:"2026-08-27T10:05:00Z",state:"COMMENTED",body:""}'
        budget_item '{id:62,commit_id:"1111111111111111111111111111111111111111",submitted_at:"2026-08-27T10:06:00Z",updated_at:"2026-08-27T10:06:00Z",state:"COMMENTED",body:""}'
        budget_item '{id:63,commit_id:"2222222222222222222222222222222222222222",submitted_at:"2026-08-27T11:05:00Z",updated_at:"2026-08-27T11:05:00Z",state:"COMMENTED",body:"P1 body-only finding."}'
        budget_item '{id:64,commit_id:"3333333333333333333333333333333333333333",submitted_at:"2026-08-27T12:05:00Z",updated_at:"2026-08-27T12:05:00Z",state:"CHANGES_REQUESTED",body:"Fix the provenance boundary."}'
        # A finding on an unrequested head is not part of this PR's review rounds.
        budget_item '{id:65,commit_id:"4444444444444444444444444444444444444444",submitted_at:"2026-08-27T13:05:00Z",updated_at:"2026-08-27T13:05:00Z",state:"COMMENTED",body:""}'
      elif has '/pulls/7/comments' "$@"; then
        budget_item '{id:101,pull_request_review_id:61,in_reply_to_id:null,created_at:"2026-08-27T10:05:00Z",updated_at:"2026-08-27T10:05:00Z",user:{login:"reviewer"},body:"Finding."}'
        budget_item '{id:102,pull_request_review_id:61,in_reply_to_id:101,created_at:"2026-08-27T10:07:00Z",updated_at:"2026-08-27T10:07:00Z",user:{login:"alice"},body:"Answered."}'
        budget_item '{id:103,pull_request_review_id:65,in_reply_to_id:null,created_at:"2026-08-27T13:05:00Z",updated_at:"2026-08-27T13:05:00Z",user:{login:"reviewer"},body:"Unbound finding."}'
      fi
    elif has '.[] | @base64' "$@"; then
      :
    elif has '/issues/7/comments' "$@"; then
      if has 'updated_at // .created_at' "$@"; then
        printf '%s\n' '2026-08-27T17:05:00Z'
      elif [ "${GH_MODE:-ok}" = many_requests ]; then
        for index in $(awk 'BEGIN { for (i = 1; i <= 4000; i++) print i }'); do
          printf 'https://example.test/pr/7#issuecomment-%s\talice\t%s\n' "$index" \
            "@codex review\\n\\n<!-- touchstone:pr-open head=$GH_HEAD base=$GH_BASE_REF base_sha=$GH_BASE_SHA -->"
        done
      elif [ "${GH_MODE:-ok}" = spoofed_request ]; then
        printf '%s\tmallory\t%s\n' 'https://example.test/pr/7#issuecomment-spoofed' \
          "@codex review\\n\\n<!-- touchstone:pr-open head=$GH_HEAD base=$GH_BASE_REF base_sha=$GH_BASE_SHA -->"
        if [ -f "$GH_STATE/review-request" ]; then
          printf '%s\talice\t%s\n' 'https://example.test/pr/7#issuecomment-1' \
            "@codex review\\n\\n<!-- touchstone:pr-open head=$GH_HEAD base=$GH_BASE_REF base_sha=$GH_BASE_SHA -->"
        fi
      elif [ "${GH_MODE:-ok}" = marker_only ]; then
        printf '%s\talice\t%s\n' 'https://example.test/pr/7#issuecomment-marker' \
          "<!-- touchstone:pr-open head=$GH_HEAD base=$GH_BASE_REF base_sha=$GH_BASE_SHA -->"
        if [ -f "$GH_STATE/review-request" ]; then
          printf '%s\talice\t%s\n' 'https://example.test/pr/7#issuecomment-1' \
            "@codex review\\n\\n<!-- touchstone:pr-open head=$GH_HEAD base=$GH_BASE_REF base_sha=$GH_BASE_SHA -->"
        fi
      elif [ -f "$GH_STATE/review-request" ]; then
        read -r saved_head saved_base saved_base_sha <"$GH_STATE/review-request"
        printf '%s\talice\t%s\n' 'https://example.test/pr/7#issuecomment-1' \
          "@codex review\\n\\n<!-- touchstone:pr-open head=$saved_head base=$saved_base base_sha=$saved_base_sha -->"
      fi
    elif has '/reviews?per_page=100' "$@"; then
      if has 'submitted_at' "$@"; then
        if [ "${GH_MODE:-ok}" = status_gate_stale_review ] && has 'updated_at // .submitted_at' "$@"; then
          printf '%s\n' '2026-08-27T17:35:00Z'
        else
          printf '%s\n' '2026-08-27T17:06:00Z'
        fi
      elif has 'reviewId:.id' "$@"; then
        printf '%s\n' '[{"reviewId":61,"state":"COMMENTED","body":"body finding","url":"https://example.test/review","commit":"old-head"}]'
      else
        printf '%s\n' '  review 61 [COMMENTED] at old-head'
      fi
    elif has '/pulls/7/comments' "$@"; then
      if has 'updated_at // .created_at' "$@"; then
        printf '%s\n' '2026-08-27T17:07:00Z'
      elif [ -f "$GH_STATE/reply" ]; then printf '%s\n' '<!-- touchstone:respond-review comment=51 -->'; fi
    fi
    ;;
  "api repos/autumngarage/current/pulls/7/comments/51/replies")
    touch "$GH_STATE/reply"
    printf '%s\n' 71
    ;;
  api*)
    if has 'touchstone-workflows/contents/.touchstone-source-contract.json?ref=' "$@"; then
      [ ! -f "$GH_STATE/behavior-manifest-unreadable" ] || { printf 'Not Found\n' >&2; exit 1; }
      # The source tree's own policies declare gate behavior 2, so a GitHub
      # that agrees with them is the default; each flag below is one drifted
      # world -- the pre-rollout gate, an unsupported future one, or an
      # overlapping pin whose other enforced revision is the compatible one.
      behavior_version=2
      [ ! -f "$GH_STATE/behavior-version-legacy" ] || behavior_version=1
      [ ! -f "$GH_STATE/behavior-version-unsupported" ] || behavior_version=3
      if [ -f "$GH_STATE/overlapping-pins" ] && has "?ref=$GH_MID_SHA" "$@"; then behavior_version=1; fi
      if [ -f "$GH_STATE/behavior-version-missing" ]; then
        printf '%s\n' '{"contractVersion":1}'
      else
        jq -cn --argjson version "$behavior_version" \
          '{contractVersion:1,gateBehaviorContractVersion:$version}'
      fi
    elif has '/contents/' "$@" && has '?ref=' "$@"; then
      cat "$GH_CANDIDATE_POLICY"
    elif has 'actions/permissions --jq .enabled' "$@"; then
      # Repository Actions: on unless the fixture says otherwise. The
      # "-after-preflight" shape answers true once (open's up-front check)
      # and false from then on: Actions switched off while the gate waited.
      if [ -f "$GH_STATE/actions-disabled" ]; then
        printf 'false\n'
      elif [ -f "$GH_STATE/actions-disabled-after-preflight" ]; then
        if [ -f "$GH_STATE/actions-preflight-seen" ]; then printf 'false\n'; else touch "$GH_STATE/actions-preflight-seen"; printf 'true\n'; fi
      else
        printf 'true\n'
      fi
    elif has "repos/${GH_FAKE_REPO:-${GH_REPO:-autumngarage/current}} --jq .allow_auto_merge" "$@"; then
      # The repository's auto-merge setting: on unless the fixture says otherwise.
      if [ -f "$GH_STATE/auto-merge-off" ]; then printf 'false\n'; else printf 'true\n'; fi
    elif has 'repositories/1333343261' "$@"; then
      # The workflow source repository, resolved by the id the pin carries.
      printf '%s' '{"full_name":"autumngarage/touchstone-workflows"}' | jq -r "$(value_after --jq "$@")"
    elif has 'repositories/' "$@"; then
      # Any other id is a repository this token cannot see.
      printf 'Not Found\n' >&2
      exit 1
    elif has 'touchstone-workflows/commits/main' "$@"; then
      [ ! -f "$GH_STATE/source-head-unreadable" ] || { printf 'Not Found\n' >&2; exit 1; }
      printf '%s' "{\"sha\":\"$GH_SOURCE_HEAD\"}" | jq -r "$(value_after --jq "$@")"
    elif has 'touchstone-workflows/compare/' "$@"; then
      # A real ancestry graph, answered the way GitHub answers it. The fixture
      # commits, oldest first: BEHIND -> POLICY -> AHEAD (= the branch head),
      # with OFFREF descended from POLICY but never merged into the branch and
      # DIVERGED on a lineage of its own.
      spec="$(printf '%s\n' "$@" | tr ' ' '\n' | grep -F '/compare/' | head -1)"
      spec="${spec##*/compare/}"
      base="${spec%%...*}"
      head="${spec##*...}"
      for sha in "$base" "$head"; do
        case "$sha" in
          "$GH_BEHIND_SHA" | "$GH_POLICY_SHA" | "$GH_MID_SHA" | "$GH_AHEAD_SHA" | "$GH_OFFREF_SHA" | "$GH_DIVERGED_SHA") ;;
          *)
            printf 'No common ancestor between %s and %s.\n' "$base" "$head" >&2
            exit 1
            ;;
        esac
      done
      rank_of() {
        case "$1" in
          "$GH_BEHIND_SHA") printf '1\n' ;;
          "$GH_POLICY_SHA") printf '2\n' ;;
          "$GH_MID_SHA") printf '3\n' ;;
          "$GH_AHEAD_SHA") printf '4\n' ;;
          *) printf '0\n' ;;
        esac
      }
      base_rank="$(rank_of "$base")"
      head_rank="$(rank_of "$head")"
      if [ "$base" = "$head" ]; then
        status=identical
      elif [ "$base_rank" -gt 0 ] && [ "$head_rank" -gt 0 ]; then
        if [ "$head_rank" -gt "$base_rank" ]; then status=ahead; else status=behind; fi
      elif [ "$head" = "$GH_OFFREF_SHA" ] && [ "$base_rank" -gt 0 ] && [ "$base_rank" -le 2 ]; then
        # OFFREF descends from POLICY (and from BEHIND before it).
        status=ahead
      elif [ "$base" = "$GH_OFFREF_SHA" ] && [ "$head_rank" -gt 0 ] && [ "$head_rank" -le 2 ]; then
        status=behind
      else
        status=diverged
      fi
      printf '%s' "{\"status\":\"$status\"}" | jq -r "$(value_after --jq "$@")"
    elif has 'user --jq .login' "$@"; then
      printf 'alice\n'
    elif has 'actions/runs/77/rerun' "$@"; then
      echo "rerun 77" >>"$GH_STATE/gate-reruns"
      # After a re-run the run is in progress until the fake says otherwise.
      [ -f "$GH_STATE/gate-after-rerun" ] || echo 2 >"$GH_STATE/gate-after-rerun"
    elif has 'actions/runs/80/rerun' "$@"; then
      [ "${GH_MODE:-ok}" != delivery_rerun_failure ] || exit 1
      echo "rerun 80" >>"$GH_STATE/evidence-reruns"
      [ -f "$GH_STATE/evidence-after-rerun" ] || echo 2 >"$GH_STATE/evidence-after-rerun"
    elif has 'actions/runs/88/rerun' "$@"; then
      echo "rerun 88" >>"$GH_STATE/gate-reruns"
    elif has 'actions/runs/88' "$@"; then
      printf '1\n'
    elif has 'actions/runs/77' "$@"; then
      # Single-run read. Before a re-run: attempt 1 completed. Right after a
      # re-run GitHub may still report attempt 1 completed (stale), then the
      # new attempt in progress, then attempt 2 completed.
      if has 'run_attempt | type' "$@"; then
        if [ "${GH_MODE:-ok}" = status_gate_attempt_race ] || [ "${GH_MODE:-ok}" = status_gate_run_recency ]; then
          touch "$GH_STATE/status-attempt-advanced"
          printf '3\n'
        else
          printf '2\n'
        fi
      elif has '.run_attempt' "$@" && ! has 'status' "$@"; then
        if [ -f "$GH_STATE/gate-after-rerun" ]; then
          left="$(cat "$GH_STATE/gate-after-rerun")"
          if [ "$left" -ge 2 ]; then echo 1 >"$GH_STATE/gate-after-rerun"; printf '1\n'; else rm -f "$GH_STATE/gate-after-rerun"; printf '2\n'; fi
        else
          printf '1\n'
        fi
      elif [ -f "$GH_STATE/gate-after-rerun" ]; then
        left="$(cat "$GH_STATE/gate-after-rerun")"
        if [ "$left" -ge 2 ]; then
          echo 1 >"$GH_STATE/gate-after-rerun"
          printf 'completed success 1\n'
        else
          rm -f "$GH_STATE/gate-after-rerun"
          printf 'in_progress  2\n'
        fi
      else
        printf 'completed %s 2\n' "${GH_GATE_CONCLUSION:-success}"
      fi
    elif has 'actions/runs/80' "$@"; then
      if has '.run_attempt' "$@"; then
        if [ -f "$GH_STATE/evidence-after-rerun" ]; then
          left="$(cat "$GH_STATE/evidence-after-rerun")"
          if [ "$left" -ge 2 ]; then echo 1 >"$GH_STATE/evidence-after-rerun"; printf '1\n'; else rm -f "$GH_STATE/evidence-after-rerun"; printf '2\n'; fi
        else
          printf '1\n'
        fi
      else
        printf 'completed %s 1\n' "${GH_EVIDENCE_CONCLUSION:-success}"
      fi
    elif has 'actions/workflows?' "$@"; then
      first_workflow_page='{"workflows":[{"id":2,"path":".github/workflows/local-review-gate.yml"}]}'
      expected_workflow_page='{"workflows":[{"id":3,"path":".github/workflows/local-delivery-evidence.yml"}]}'
      all_workflow_page='{"workflows":[{"id":2,"path":".github/workflows/local-review-gate.yml"},{"id":3,"path":".github/workflows/local-delivery-evidence.yml"}]}'
      if [ -f "$GH_STATE/required-workflow-later-page" ]; then
        printf '%s\n' "$first_workflow_page"
        if has --paginate "$@"; then printf '%s\n' "$expected_workflow_page"; fi
      else
        printf '%s\n' "$all_workflow_page"
      fi
    elif has 'rules/branches/' "$@"; then
      serve_rules "$@"
    elif has 'actions/runs?head_sha=' "$@"; then
      # Real selector over a real list: the pinned gate (run 77, unlisted
      # workflow id 999) next to a NEWER repository-local decoy of the same
      # name (run 78, listed workflow id 2) and another PR's run (79). Only
      # the jq the CLI passes decides which one it sees.
      if { [ -f "$GH_STATE/review-gate" ] || [[ "${GH_MODE:-ok}" == status_gate_* ]]; } \
        && [ ! -f "$GH_STATE/gate-never-runs" ]; then
        if [ -f "$GH_STATE/gate-in-progress" ]; then
          left="$(cat "$GH_STATE/gate-in-progress")"
          if [ "$left" -le 1 ]; then rm -f "$GH_STATE/gate-in-progress"; else echo $((left - 1)) >"$GH_STATE/gate-in-progress"; fi
          gate_status=in_progress
        else
          gate_status=completed
        fi
        gate_attempt=2
        gate_conclusion_json="\"${GH_GATE_CONCLUSION:-success}\""
        case "${GH_MODE:-ok}" in
          status_gate_pending | status_gate_stale_attempt)
            gate_status=in_progress
            gate_conclusion_json=null
            ;;
          status_gate_run_recency)
            gate_attempt=3
            ;;
          status_gate_failure | status_gate_collision)
            gate_status=completed
            gate_conclusion_json='"failure"'
            ;;
          status_gate_cancelled | status_gate_workflow_cancelled)
            gate_status=completed
            gate_conclusion_json='"cancelled"'
            ;;
          status_gate_attempt_race)
            if [ -f "$GH_STATE/status-attempt-advanced" ]; then
              gate_attempt=3
              gate_status=in_progress
              gate_conclusion_json=null
            fi
            ;;
          status_gate_status_race)
            if [ -f "$GH_STATE/status-run-completed" ]; then
              gate_status=completed
              gate_conclusion_json='"success"'
            else
              gate_status=in_progress
              gate_conclusion_json=null
            fi
            ;;
        esac
        gate_started_at='2026-08-27T17:10:00Z'
        [ ! -f "$GH_STATE/gate-fresh-active" ] || gate_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if [ -f "$GH_STATE/gate-review-window-active" ]; then
          gate_started_at="$(jq -nr --argjson started "$(( $(date -u +%s) - 300 ))" '$started | todateiso8601')"
        fi
        evidence_conclusion="${GH_EVIDENCE_CONCLUSION:-success}"
        [ "${GH_MODE:-ok}" != delivery_evidence_failure ] || evidence_conclusion=failure
        [ ! -f "$GH_STATE/evidence-reruns" ] || evidence_conclusion=success
        runs="{\"workflow_runs\":[
          {\"id\":77,\"node_id\":\"RUN_77\",\"name\":\"review-gate\",\"head_sha\":\"$GH_HEAD\",\"check_suite_id\":900,\"run_attempt\":$gate_attempt,\"event\":\"pull_request\",\"status\":\"$gate_status\",\"conclusion\":$gate_conclusion_json,\"workflow_id\":999,\"run_started_at\":\"$gate_started_at\",\"updated_at\":\"2026-08-27T17:30:00Z\",\"pull_requests\":[{\"number\":7}]},
          {\"id\":78,\"name\":\"review-gate\",\"head_sha\":\"$GH_HEAD\",\"check_suite_id\":901,\"event\":\"pull_request\",\"status\":\"completed\",\"conclusion\":\"success\",\"workflow_id\":2,\"run_started_at\":\"2026-08-27T17:20:00Z\",\"updated_at\":\"2026-08-27T17:20:00Z\",\"pull_requests\":[{\"number\":7}]},
          {\"id\":79,\"name\":\"review-gate\",\"head_sha\":\"$GH_HEAD\",\"check_suite_id\":902,\"event\":\"pull_request\",\"status\":\"completed\",\"conclusion\":\"success\",\"workflow_id\":999,\"run_started_at\":\"2026-08-27T17:20:00Z\",\"updated_at\":\"2026-08-27T17:20:00Z\",\"pull_requests\":[{\"number\":8}]},
          {\"id\":80,\"node_id\":\"RUN_80\",\"name\":\"delivery-evidence\",\"head_sha\":\"$GH_HEAD\",\"check_suite_id\":903,\"event\":\"pull_request\",\"status\":\"completed\",\"conclusion\":\"$evidence_conclusion\",\"run_started_at\":\"${GH_EVIDENCE_STARTED_AT:-2026-08-26T22:20:00Z}\",\"updated_at\":\"2026-08-27T17:30:00Z\",\"run_attempt\":2,\"workflow_id\":1000,\"pull_requests\":[{\"number\":7}]},
          {\"id\":81,\"name\":\"delivery-evidence\",\"head_sha\":\"$GH_HEAD\",\"check_suite_id\":904,\"event\":\"pull_request\",\"status\":\"completed\",\"conclusion\":\"failure\",\"workflow_id\":3,\"pull_requests\":[{\"number\":7}]},
          {\"id\":82,\"name\":\"other-external-gate\",\"head_sha\":\"$GH_HEAD\",\"check_suite_id\":905,\"event\":\"pull_request\",\"status\":\"completed\",\"conclusion\":\"success\",\"workflow_id\":1001,\"pull_requests\":[{\"number\":7}]},
          {\"id\":83,\"name\":\"other-external-gate\",\"head_sha\":\"$GH_HEAD\",\"check_suite_id\":905,\"event\":\"pull_request\",\"status\":\"completed\",\"conclusion\":\"success\",\"workflow_id\":1001,\"pull_requests\":[{\"number\":7}]}]}"
        if [ "${GH_MODE:-ok}" = status_gate_run_recency ] || [ "${GH_MODE:-ok}" = status_gate_run_overlap ] || [ "${GH_MODE:-ok}" = status_gate_run_tie ] || [ "${GH_MODE:-ok}" = required_run_recency ] || [ "${GH_MODE:-ok}" = required_run_tie ]; then
          extra_started_at='2026-08-27T17:00:00Z'
          if [ "${GH_MODE:-ok}" = status_gate_run_overlap ]; then
            runs="$(printf '%s' "$runs" | jq -c '(.workflow_runs[] | select(.id == 77) | .run_started_at) = "2026-08-27T17:00:00Z"')"
            extra_started_at='2026-08-27T17:10:00Z'
          elif [ "${GH_MODE:-ok}" = status_gate_run_tie ] || [ "${GH_MODE:-ok}" = required_run_tie ]; then
            extra_started_at='2026-08-27T17:10:00Z'
          fi
          runs="$(printf '%s' "$runs" | jq -c '.workflow_runs += [{
            id:88,
            node_id:"RUN_88",
            name:"review-gate",
            head_sha:"'"$GH_HEAD"'",
            check_suite_id:906,
            run_attempt:1,
            event:"pull_request",
            status:"completed",
            conclusion:"failure",
            workflow_id:999,
            run_started_at:"'"$extra_started_at"'",
            updated_at:"2026-08-27T17:20:00Z",
            pull_requests:[{number:7}]
          }]')"
        fi
        if [ "${GH_MODE:-ok}" = status_gate_new_run_race ] && [ -f "$GH_STATE/status-new-run-started" ]; then
          runs="$(printf '%s' "$runs" | jq -c '.workflow_runs += [{
            id:88,
            node_id:"RUN_88",
            name:"review-gate",
            head_sha:"'"$GH_HEAD"'",
            check_suite_id:906,
            run_attempt:1,
            event:"pull_request",
            status:"in_progress",
            conclusion:null,
            workflow_id:999,
            run_started_at:"2026-08-27T17:20:00Z",
            updated_at:"2026-08-27T17:20:00Z",
            pull_requests:[{number:7}]
          }]')"
        fi
        if [ "${GH_MODE:-ok}" = required_run_malformed ]; then
          runs="$(printf '%s' "$runs" | jq -c '(.workflow_runs[] | select(.id == 77)) |= del(.run_started_at)')"
        fi
        if [ "${GH_MODE:-ok}" = status_gate_unbound ]; then
          runs="$(printf '%s' "$runs" | jq -c '(.workflow_runs[] | select(.id == 77) | .pull_requests) = []')"
        fi
        if [ -f "$GH_STATE/same-name-external-decoy" ] || [ -f "$GH_STATE/same-name-external-decoy-only" ]; then
          runs="$(printf '%s' "$runs" | jq -c '.workflow_runs += [{"id":82,"node_id":"RUN_82","name":"delivery-evidence","head_sha":"'"$GH_HEAD"'","check_suite_id":905,"run_attempt":1,"event":"pull_request","status":"completed","conclusion":"success","workflow_id":1001,"run_started_at":"2026-08-27T17:25:00Z","updated_at":"2026-08-27T17:25:00Z","pull_requests":[{"number":7}]}]')"
        fi
        if [ -f "$GH_STATE/same-name-external-decoy-only" ]; then
          runs="$(printf '%s' "$runs" | jq -c '{workflow_runs: [.workflow_runs[] | select(.id != 80)]}')"
        fi
      else
        runs='{"workflow_runs":[]}'
      fi
      if [ -f "$GH_STATE/local-evidence-rule" ]; then
        runs="$(printf '%s' "$runs" | jq -c '{workflow_runs: [.workflow_runs[] | select(.id != 80)]}')"
      fi
      if [ -f "$GH_STATE/required-run-later-page" ]; then
        first_page="$(printf '%s' "$runs" | jq -c '{workflow_runs: [.workflow_runs[] | select(.id != 77 and .id != 80)]}')"
        later_page="$(printf '%s' "$runs" | jq -c '{workflow_runs: [.workflow_runs[] | select(.id == 77 or .id == 80)]}')"
        if has --jq "$@"; then
          printf '%s' "$first_page" | jq -r "$(value_after --jq "$@")"
          if has --paginate "$@"; then printf '%s' "$later_page" | jq -r "$(value_after --jq "$@")"; fi
        else
          printf '%s\n' "$first_page"
          if has --paginate "$@"; then printf '%s\n' "$later_page"; fi
        fi
      elif has --jq "$@"; then
        printf '%s' "$runs" | jq -r "$(value_after --jq "$@")"
      else
        printf '%s\n' "$runs"
      fi
    elif has '/issues/comments/1' "$@"; then
      if [ "${GH_MODE:-ok}" = live_comment_invalid ]; then
        jq -cn '{id: 1, user: {login: "mallory"}, body: "not a review request", author_association: "OWNER"}'
      else
        if [ -f "$GH_STATE/review-request" ]; then
          read -r saved_head saved_base saved_base_sha <"$GH_STATE/review-request"
        else
          saved_head="$GH_HEAD"; saved_base="$GH_BASE_REF"; saved_base_sha="$GH_BASE_SHA"
        fi
        jq -cn --arg body "@codex review

<!-- touchstone:pr-open head=$saved_head base=$saved_base base_sha=$saved_base_sha -->" \
          '{id: 1, user: {login: "alice"}, body: $body, author_association: "NONE"}'
      fi
    elif has '/issues/7/comments' "$@"; then
      if [ -f "$GH_STATE/review-request" ]; then printf '%s\n' https://example.test/pr/7#issuecomment-1; fi
    elif has '/commits/' "$@" && has '/status' "$@"; then
      if [ -f "$GH_STATE/review-request" ]; then printf '%s\n' https://example.test/pr/7#issuecomment-1; fi
    elif has 'check-runs?check_name=review-binding' "$@"; then
      [ "${GH_MODE:-ok}" = binding_missing ] || printf 'completed\tsuccess\n'
    fi
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TMP/bin/gh"
  GH_POLICY_SHA="$(jq -r '[.managedRuleset.rules[] | select(.type == "workflows") | .parameters.workflows[].sha] | unique | .[0]' "$ROOT/policy/github/touchstone-main.json")"
  # The workflow-source lineage the fake serves, relative to the revision the
  # tool's own policy file carries (GH_POLICY_SHA):
  #   BEHIND -> POLICY -> AHEAD, with AHEAD the branch head.
  # OFFREF descends from POLICY but is not on the branch; DIVERGED shares no
  # lineage; UNKNOWN is not a commit in the source repository at all.
  GH_BEHIND_SHA=7c2e48d21b8031df4e607a3f0935cc37f363fcd5
  GH_MID_SHA=8ab13f0c5d2e47bb8c6a1f30d94e7c2b5a08d612
  GH_AHEAD_SHA=9ab13f0c5d2e47bb8c6a1f30d94e7c2b5a08d613
  GH_OFFREF_SHA=3d5c7e91b02a4f68d17c9ae5b436f0c82d197ae4
  GH_DIVERGED_SHA=1f0b9d4c8e37a25610cd9f8b47e3a05c6d21f9b8
  GH_UNKNOWN_SHA=0000000000000000000000000000000000000000
  GH_SOURCE_HEAD="$GH_AHEAD_SHA"
  export PATH="$TMP/bin:$PATH" GH_CALLS="$TMP/calls" GH_STATE="$TMP/state" GH_HEAD="$HEAD_SHA" GH_POLICY_SHA
  export GH_CANDIDATE_POLICY="$TMP/project/policy/github/touchstone-main.json"
  export GH_BEHIND_SHA GH_MID_SHA GH_AHEAD_SHA GH_OFFREF_SHA GH_DIVERGED_SHA GH_UNKNOWN_SHA GH_SOURCE_HEAD
  export GH_LEGACY_POLICY_SHA
  export GH_BASE_REF=main GH_BASE_SHA=base-sha
  export TOUCHSTONE_READ_ATTEMPTS=2 TOUCHSTONE_REQUEST_ATTEMPTS=2 TOUCHSTONE_RETRY_DELAY=0 TOUCHSTONE_GATE_RETRY_DELAY=0

  run_pr() {
    local output="$1"
    shift
    : >"$GH_CALLS"
    set +e
    bash "$ROOT/bin/touchstone" pr "$@" --project "$TMP/project" >"$output" 2>&1
    RUN_RC=$?
    set -e
  }

  # The source tree's policies now declare gate behavior 2, so the packaged
  # fixture is the older client: an installed release that still declares v1
  # must keep working while the pin rolls out repository by repository.
  mkdir -p "$TMP/tool-v1/bin" "$TMP/tool-v1/scripts" "$TMP/tool-v1/policy/github"
  cp "$ROOT/bin/touchstone" "$TMP/tool-v1/bin/touchstone"
  cp "$ROOT/scripts/touchstone-pr.sh" "$TMP/tool-v1/scripts/touchstone-pr.sh"
  cp -R "$ROOT/policy/github/." "$TMP/tool-v1/policy/github/"
  printf '3.7.6\n' >"$TMP/tool-v1/VERSION"
  # A released client carries the whole previous policy, not just its behavior
  # version: 3.7.6 pins the revision this one supersedes. GH_BEHIND_SHA is that
  # relationship in the fixture lineage, so the fixture reproduces the real
  # rollout shape -- GitHub enforcing a descendant of what the client pins.
  jq --arg sha "$GH_BEHIND_SHA" '
      .workflowSource.sourceContract.gateBehaviorContractVersion = 1
      | (.managedRuleset.rules[] | select(.type == "workflows") | .parameters.workflows[] | .sha) = $sha' \
    "$ROOT/policy/github/touchstone-main.json" >"$TMP/tool-v1/policy/github/touchstone-main.json"
  run_pr_v1() {
    local output="$1"
    shift
    : >"$GH_CALLS"
    set +e
    bash "$TMP/tool-v1/bin/touchstone" pr "$@" --project "$TMP/project" >"$output" 2>&1
    RUN_RC=$?
    set -e
  }

  echo "==> status is versioned, read-only, and retries bounded transport failures"
  touch "$TMP/state/pr-exists"
  GH_MODE=read_retry run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"schema":"touchstone.pr/v1"'
  assert_has "$TMP/out" '"status":"observed"'
  assert_has "$TMP/out" "\"head\":\"$HEAD_SHA\""
  assert_has "$TMP/out" "\"autoMerge\":{\"armed\":false,\"enabledAt\":null,\"head\":\"$HEAD_SHA\"}"
  assert_has "$TMP/out" '"mergeQueue":null,"phase":"action-required","nextAction":"inspect"'
  assert_has "$TMP/out" "\"reviewGateCheck\":{\"present\":false,\"head\":\"$HEAD_SHA\",\"configured\":false}"
  assert_has "$GH_CALLS" 'api graphql --hostname github.com -f owner=autumngarage -f name=current -F number=7'
  [ "$(grep -c '^pr view .*--json number,state,url,headRefOid' "$GH_CALLS")" -eq 2 ] \
    || fail "status did not retry its primary PR read exactly once"
  run_pr "$TMP/out" status 7
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" 'phase: action-required'
  assert_has "$TMP/out" 'next action: inspect'
  assert_has "$TMP/out" "auto-merge: not armed for $HEAD_SHA"
  assert_has "$TMP/out" 'merge queue: not queued'
  assert_has "$TMP/out" "review gate: not configured by the effective policy for $HEAD_SHA"

  echo "==> status exposes the cumulative review budget without treating it as a verdict"
  cat >"$TMP/state/pr-body" <<EOF
## Validation
- Local review: codex on \`$HEAD_SHA\`: 2 findings, fixed.
- Review budget: v1 capability=AUT-461 local_rounds=1 prior_hosted_rounds=2 reviewed_head=$HEAD_SHA cascade=true exit=split
EOF
  touch "$TMP/state/review-budget-fixture"
  run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewBudget":{"recorded":true,"limit":3,"capability":"AUT-461","localFindingBearingRounds":1,"hostedFindingBearingRounds":6,"findingBearingRounds":7,"sameShapeRoundsRemaining":0,"exhausted":true'
  assert_has "$TMP/out" "\"reviewedHead\":\"$HEAD_SHA\",\"currentHeadReviewed\":true,\"cascade\":true,\"selectedExit\":\"split\""
  run_pr "$TMP/out" status 7
  assert_has "$TMP/out" 'review budget: AUT-461 — 7/3 finding-bearing rounds; same-shape rounds remaining: 0; exhausted: yes; exact-head review still required'
  assert_has "$TMP/out" "reviewed head: $HEAD_SHA (current); cascade: yes; selected exit: split"
  [ "$(grep -c -- '--paginate.*issues/7/comments' "$GH_CALLS")" -eq 1 ] \
    || fail "review-budget issue comments were not read once with pagination"
  [ "$(grep -c -- '--paginate.*pulls/7/reviews' "$GH_CALLS")" -eq 1 ] \
    || fail "review-budget formal reviews were not read once with pagination"
  [ "$(grep -c -- '--paginate.*pulls/7/comments' "$GH_CALLS")" -eq 1 ] \
    || fail "review-budget inline comments were not read once with pagination"

  printf '%s\n' 'Change summary.' '' 'Closes #42' >"$TMP/state/pr-body"
  run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewBudget":{"recorded":false,"limit":3,"capability":null,"localFindingBearingRounds":null,"hostedFindingBearingRounds":4,"findingBearingRounds":null,"sameShapeRoundsRemaining":null,"exhausted":null,"reviewedHead":"6666666666666666666666666666666666666666"'

  printf '%s\n' '- Review budget: local_rounds=one' >"$TMP/state/pr-body"
  run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'malformed Review budget record'
  rm -f "$TMP/state/review-budget-fixture" "$TMP/state/pr-body"

  GH_MODE=status_auto_merge run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" "\"autoMerge\":{\"armed\":true,\"enabledAt\":\"2026-08-24T20:00:00Z\",\"head\":\"$HEAD_SHA\"}"
  GH_MODE=status_auto_merge run_pr "$TMP/out" status 7
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" "auto-merge: armed at 2026-08-24T20:00:00Z for $HEAD_SHA"
  touch "$TMP/state/review-gate"
  GH_MODE=status_gate_pending run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"phase":"reviewing","nextAction":"wait"'
  assert_has "$TMP/out" '"reviewGateCheck":{"present":true'
  assert_has "$TMP/out" '"checkRunId":81,"status":"in_progress","conclusion":null'
  GH_MODE=status_gate_failure run_pr "$TMP/out" status 7
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" 'review gate: completed/failure (check run 82): No request binds this head — https://example.test/runs/82'
  GH_MODE=status_gate_failure run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"phase":"fix-required","nextAction":"address-review"'
  assert_has "$TMP/out" '"title":"No request binds this head","summary":"Run touchstone pr open for the live head."'
  GH_MODE=status_gate_success run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"phase":"ready-to-queue","nextAction":"queue"'
  assert_has "$TMP/out" '"checkRunId":84,"status":"completed","conclusion":"success"'
  assert_not_has "$TMP/out" 'Superseded attempt'
  GH_MODE=status_gate_success run_pr "$TMP/out" status 7
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" 'phase: ready-to-queue'
  assert_has "$TMP/out" 'next action: queue'
  assert_has "$TMP/out" "command: touchstone pr merge 7 --head $HEAD_SHA"
  GH_MODE=status_gate_blocked_success run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"mergeState":"BLOCKED"'
  assert_has "$TMP/out" '"phase":"action-required","nextAction":"inspect"'
  assert_not_has "$TMP/out" '"phase":"ready-to-queue"'
  GH_MODE=status_gate_cancelled run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"completed","conclusion":"cancelled"'
  assert_has "$TMP/out" '"phase":"action-required","nextAction":"inspect"'
  assert_not_has "$TMP/out" '"phase":"fix-required"'
  GH_MODE=status_gate_workflow_cancelled run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"workflowStatus":"completed","workflowConclusion":"cancelled"'
  assert_has "$TMP/out" '"phase":"action-required","nextAction":"inspect"'
  assert_not_has "$TMP/out" '"phase":"fix-required"'
  GH_MODE=status_gate_stale_review run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"phase":"action-required","nextAction":"inspect"'
  assert_not_has "$TMP/out" '"phase":"ready-to-queue"'
  GH_MODE=status_gate_queued run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"mergeQueue":{"state":"AWAITING_CHECKS"},"phase":"queued","nextAction":"wait"'
  assert_not_has "$GH_CALLS" 'pr merge'
  assert_not_has "$GH_CALLS" 'pr comment'

  echo "==> a partial-policy queue entry is observed before an unguarded record"
  rm -f "$TMP/calls"
  touch "$TMP/state/no-queue-rule"
  GH_MODE=merge_queue_existing run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --unguarded --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'already accepted for delivery'
  assert_not_has "$GH_CALLS" 'pr merge'
  assert_not_has "$GH_CALLS" 'pr comment'
  rm -f "$TMP/state/no-queue-rule"
  touch "$TMP/state/no-review-gate-rule"
  GH_MODE=status_gate_queued run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"mergeQueue":{"state":"AWAITING_CHECKS"},"phase":"action-required","nextAction":"inspect"'
  rm -f "$TMP/state/no-review-gate-rule"
  GH_MODE=status_merged run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"phase":"merged","nextAction":"done"'
  GH_MODE=status_gate_queue_unmergeable run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"mergeQueue":{"state":"UNMERGEABLE"},"phase":"action-required","nextAction":"inspect"'
  GH_MODE=status_gate_queue_unknown run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"mergeQueue":{"state":"FUTURE_STATE"},"phase":"action-required","nextAction":"inspect"'
  GH_MODE=status_head_moved run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" "moved from $HEAD_SHA to moved-head while status was being read"
  GH_MODE=status_observation_failure run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'could not read auto-merge or merge-queue state'
  GH_MODE=status_gate_historical run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"present":false,"head":"'"$HEAD_SHA"'","unbound":true,"workflowRunId":77'
  assert_has "$TMP/out" '"revision":"'"$GH_AHEAD_SHA"'"'
  assert_not_has "$GH_CALLS" '/attempts/2/jobs'
  touch "$TMP/state/overlapping-exact-pins"
  GH_MODE=status_gate_historical run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"checkRunId":84,"status":"completed","conclusion":"success"'
  rm -f "$TMP/state/overlapping-exact-pins"
  touch "$TMP/state/no-review-gate-rule"
  GH_MODE=status_gate_success run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewGateCheck":{"present":false,"head":"'"$HEAD_SHA"'","configured":false}'
  assert_not_has "$GH_CALLS" 'actions/runs?head_sha='
  rm -f "$TMP/state/no-review-gate-rule"
  GH_MODE=status_gate_run_recency run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"phase":"action-required","nextAction":"inspect"'
  assert_has "$TMP/out" '"workflowRunId":77,"runAttempt":3'
  assert_not_has "$TMP/out" '"workflowRunId":88'
  GH_MODE=status_gate_run_overlap run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"workflowRunId":88,"runAttempt":1'
  assert_has "$TMP/out" '"checkRunId":89,"status":"completed","conclusion":"failure"'
  assert_not_has "$TMP/out" '"workflowRunId":77'
  GH_MODE=status_gate_run_tie run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"phase":"action-required","nextAction":"inspect"'
  assert_has "$TMP/out" '"present":false,"head":"'"$HEAD_SHA"'","ambiguous":true,"workflowRunIds":[77,88],"runStartedAt":"2026-08-27T17:10:00Z"'
  assert_not_has "$GH_CALLS" '/attempts/'
  GH_MODE=status_gate_collision run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"checkRunId":82,"status":"completed","conclusion":"failure"'
  assert_not_has "$TMP/out" 'Local look-alike passed'
  GH_MODE=status_gate_stale_attempt run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"runAttempt":2,"runStartedAt":"2026-08-27T17:10:00Z","workflowStatus":"in_progress","workflowConclusion":null,"checkRunId":86'
  assert_not_has "$TMP/out" 'Superseded success'
  rm -f "$TMP/state/status-attempt-advanced"
  GH_MODE=status_gate_attempt_race run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"runAttempt":3,"runStartedAt":"2026-08-27T17:10:00Z","workflowStatus":"in_progress","workflowConclusion":null,"checkRunId":87'
  assert_not_has "$TMP/out" 'Superseded success'
  [ "$(grep -c 'actions/runs?head_sha=' "$GH_CALLS")" -eq 3 ] \
    || fail "status did not retry the binding after a concurrent gate rerun"
  rm -f "$TMP/state/status-new-run-started"
  GH_MODE=status_gate_new_run_race run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"workflowRunId":88,"runAttempt":1,"runStartedAt":"2026-08-27T17:20:00Z","workflowStatus":"in_progress","workflowConclusion":null,"checkRunId":89'
  assert_not_has "$TMP/out" 'Superseded success'
  [ "$(grep -c 'actions/runs?head_sha=' "$GH_CALLS")" -eq 3 ] \
    || fail "status did not retry the binding after a concurrent new gate run"
  rm -f "$TMP/state/status-run-completed"
  GH_MODE=status_gate_status_race run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"workflowStatus":"completed","workflowConclusion":"success","checkRunId":84,"status":"completed","conclusion":"success"'
  [ "$(grep -c 'actions/runs?head_sha=' "$GH_CALLS")" -eq 3 ] \
    || fail "status did not retry the binding after a concurrent gate completion"
  GH_MODE=status_gate_unbound run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" "\"reviewGateCheck\":{\"present\":false,\"head\":\"$HEAD_SHA\"}"
  assert_not_has "$GH_CALLS" '/attempts/2/jobs'
  GH_MODE=status_gate_stale run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" "\"reviewGateCheck\":{\"present\":false,\"head\":\"$HEAD_SHA\",\"workflowRunId\":77"
  GH_MODE=status_gate_malformed run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" '"status":"failed"'
  assert_has "$TMP/out" 'GitHub returned malformed review-gate check data'
  GH_REPO_HOST=github.enterprise.example run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$GH_CALLS" 'pr view 7 --repo github.enterprise.example/autumngarage/current'
  GH_REPO=ambient/wrong run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$GH_CALLS" 'pr view 7 --repo github.com/autumngarage/current'
  assert_not_has "$GH_CALLS" 'ambient/wrong'
  GH_MODE=success_stderr run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" "\"head\":\"$HEAD_SHA\""
  # A read-only sandbox (no writable TMPDIR) must still observe: the read
  # captures stdout alone and lets diagnostics pass through, so the parsed
  # data never contains them (AUT-421; Codex cold starts could not run this).
  TMPDIR="$TMP/does-not-exist" GH_MODE=success_stderr run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  # run_pr merges both streams into the file; the JSON line itself must be
  # intact and parse with the right head, whatever gh said on stderr.
  [ "$(grep '^{' "$TMP/out" | jq -r .head)" = "$HEAD_SHA" ] \
    || fail "status without a writable TMPDIR did not produce a clean JSON line: $(cat "$TMP/out")"
  rm -f "$TMP/state/review-gate"
  TMPDIR="$TMP/does-not-exist" run_pr "$TMP/out" policy-status --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"enforcement":{"status":"partial"'
  assert_not_has "$TMP/out" 'debug detail'
  run_pr "$TMP/out" status 7 --title invalid
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'does not accept mutation options'
  run_pr "$TMP/out" status 7 --project '' --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'missing value for --project'
  GH_MODE=auth_fail run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 1
  assert_not_has "$TMP/out" '"status":"observed"'
  GH_MODE=auth_unrelated run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$GH_CALLS" 'auth status --hostname github.com'

  echo "==> open refuses a conflicting new PR before requesting review"
  rm -f "$TMP/state/pr-exists" "$TMP/state/review-request"
  : >"$GH_CALLS"
  GH_MODE=conflicting_pr run_pr "$TMP/out" open --title 'Conflict' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" '"status":"failed"'
  assert_has "$TMP/out" 'conflicts with main'
  assert_not_has "$GH_CALLS" 'pr comment'
  assert_not_has "$GH_CALLS" 'actions/runs?head_sha='
  ok "a conflicting new PR consumes no hosted review or workflow recovery"
  rm -f "$TMP/state/pr-exists"

  echo "==> open requires authoritative delivery evidence before hosted review (AUT-877)"
  touch "$TMP/state/review-gate"
  : >"$GH_CALLS"
  GH_MODE=delivery_evidence_failure run_pr "$TMP/out" open --title 'Invalid evidence' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'delivery-evidence rejected PR #7'
  assert_not_has "$GH_CALLS" 'pr comment'
  assert_not_has "$GH_CALLS" 'actions/runs/80/rerun'
  [ ! -f "$TMP/state/review-request" ] \
    && ok "a rejected body consumes no hosted review or redundant evidence rerun" \
    || fail "a rejected body still posted a hosted review request"
  rm -f "$TMP/state/pr-exists" "$TMP/state/pr-body" "$TMP/state/review-request"

  echo "==> open re-runs the pinned review gate where the repository has one"
  touch "$TMP/state/review-gate" "$TMP/state/behavior-version-legacy"
  rm -f "$TMP/state/gate-reruns" "$TMP/state/review-request"
  run_pr_v1 "$TMP/out" open --title 'Gate' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  [ -f "$TMP/state/gate-reruns" ] && grep -q 'rerun 77' "$TMP/state/gate-reruns" \
    || fail "open did not re-run the review-gate run for the head"
  rm -f "$TMP/state/gate-reruns"
  echo 3 >"$TMP/state/gate-in-progress"
  run_pr_v1 "$TMP/out" open --title 'Gate' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  grep -q 'rerun 77' "$TMP/state/gate-reruns" 2>/dev/null \
    || fail "open did not wait for an in-progress gate run before re-running it"
  [ "$(grep -c 'actions/runs?head_sha=' "$GH_CALLS")" -ge 2 ] \
    || fail "open did not poll the in-progress gate run"
  rm -f "$TMP/state/gate-reruns" "$TMP/state/gate-in-progress" "$TMP/state/behavior-version-legacy"
  # The rollout state this pin creates: GitHub enforces the waiting gate while
  # an installed release still declares v1. The older client keeps its own
  # semantics -- it re-runs rather than trusting an evaluation it cannot
  # reason about -- instead of inheriting v2 behavior from the repository.
  touch "$TMP/state/gate-fresh-active"
  echo 30 >"$TMP/state/gate-in-progress"
  run_pr_v1 "$TMP/out" open --title 'Gate v1 against v2 GitHub' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewGate":{"runId":"77","action":"rerun-requested"}'
  assert_not_has "$TMP/out" '"action":"already-active"'
  grep -q 'rerun 77' "$TMP/state/gate-reruns" 2>/dev/null \
    || fail "a v1 client adopted v2 waiting semantics from the repository"
  rm -f "$TMP/state/gate-reruns" "$TMP/state/gate-in-progress" "$TMP/state/gate-fresh-active"
  # ...and its guarded merge fails closed rather than certifying that gate. The
  # released tool must be upgraded before the pin is applied to a consumer;
  # this is the failure that ordering exists to avoid.
  rm -f "$TMP/state/merged"
  run_pr_v1 "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'does not declare supported gate behavior contract 1'
  assert_not_has "$GH_CALLS" 'pr merge'
  rm -f "$TMP/state/gate-reruns"
  run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewGateBehaviorContractVersion":2'
  touch "$TMP/state/gate-fresh-active"
  echo 30 >"$TMP/state/gate-in-progress"
  run_pr "$TMP/out" open --title 'Gate v2' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewGate":{"runId":"77","action":"already-active"}'
  assert_has "$TMP/out" '"reviewBudget":{"recorded":false,"limit":3'
  [ ! -f "$TMP/state/gate-reruns" ] \
    || fail "behavior v2 open re-ran an evaluation that was already active"
  [ "$(grep -c 'actions/runs?head_sha=' "$GH_CALLS")" -le 3 ] \
    || fail "behavior v2 open repeatedly polled an active evaluation instead of returning control"
  rm -f "$TMP/state/gate-in-progress" "$TMP/state/gate-reruns" "$TMP/state/gate-fresh-active"
  touch "$TMP/state/gate-fresh-active" "$TMP/state/gate-run-unbound"
  echo 3 >"$TMP/state/gate-in-progress"
  run_pr "$TMP/out" open --title 'Gate v2 rollout' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewGate":{"runId":"77","action":"rerun-requested"}'
  assert_not_has "$TMP/out" '"action":"already-active"'
  grep -q 'rerun 77' "$TMP/state/gate-reruns" 2>/dev/null \
    || fail "behavior v2 open reused an active run from an unbound source revision"
  rm -f "$TMP/state/gate-in-progress" "$TMP/state/gate-reruns" "$TMP/state/gate-fresh-active" "$TMP/state/gate-run-unbound"
  touch "$TMP/state/gate-review-window-active"
  echo 30 >"$TMP/state/gate-in-progress"
  run_pr "$TMP/out" open --title 'Gate v2 existing request' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewGate":{"runId":"77","action":"already-active"}'
  [ ! -f "$TMP/state/gate-reruns" ] \
    || fail "behavior v2 open did not reuse an existing request's active review window"
  rm -f "$TMP/state/gate-in-progress" "$TMP/state/gate-review-window-active"
  run_pr "$TMP/out" open --title 'Gate v2' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewGate":{"runId":"77","action":"rerun-requested"}'
  grep -q 'rerun 77' "$TMP/state/gate-reruns" 2>/dev/null \
    || fail "behavior v2 open did not refresh a completed evaluation"
  rm -f "$TMP/state/gate-reruns"
  touch "$TMP/state/behavior-version-legacy"
  echo 3 >"$TMP/state/gate-in-progress"
  run_pr "$TMP/out" open --title 'Gate rollout mismatch' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewGate":{"runId":"77","action":"rerun-requested"}'
  grep -q 'rerun 77' "$TMP/state/gate-reruns" 2>/dev/null \
    || fail "open trusted local behavior v2 intent while GitHub still enforced v1"
  rm -f "$TMP/state/gate-reruns" "$TMP/state/behavior-version-legacy"
  echo 3 >"$TMP/state/gate-in-progress"
  run_pr "$TMP/out" open --title 'Expired gate v2' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewGate":{"runId":"77","action":"rerun-requested"}'
  grep -q 'rerun 77' "$TMP/state/gate-reruns" 2>/dev/null \
    || fail "behavior v2 open reused a run whose request-evidence window had expired"
  rm -f "$TMP/state/gate-in-progress"
  jq '.workflowSource.sourceContract.gateBehaviorContractVersion = 3' \
    "$TMP/tool-v1/policy/github/touchstone-main.json" >"$TMP/tool-v1/policy/github/touchstone-main.next"
  mv "$TMP/tool-v1/policy/github/touchstone-main.next" "$TMP/tool-v1/policy/github/touchstone-main.json"
  touch "$TMP/state/behavior-version-unsupported"
  run_pr_v1 "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'invalid workflow source contract declaration'
  assert_not_has "$GH_CALLS" 'pr merge'
  jq '.workflowSource.sourceContract.gateBehaviorContractVersion = 1' \
    "$TMP/tool-v1/policy/github/touchstone-main.json" >"$TMP/tool-v1/policy/github/touchstone-main.next"
  mv "$TMP/tool-v1/policy/github/touchstone-main.next" "$TMP/tool-v1/policy/github/touchstone-main.json"
  rm -f "$TMP/state/behavior-version-unsupported"
  rm -f "$TMP/state/review-gate" "$TMP/state/gate-reruns"

  echo "==> open refreshes required delivery evidence after body convergence (AUT-481)"
  # Put both the policy declaration and matching organization run on page two.
  # Required-workflow decisions must aggregate the paginated API, not apply an
  # inline filter independently to each page or stop after the first.
  touch "$TMP/state/review-gate" "$TMP/state/pr-exists" \
    "$TMP/state/required-workflow-later-page" "$TMP/state/required-run-later-page"
  rm -f "$TMP/state/evidence-reruns" "$TMP/state/evidence-after-rerun" "$TMP/state/review-request"
  printf 'Original evidence body.\n' >"$TMP/state/pr-body"
  printf 'Corrected evidence body.\n' >"$TMP/body2"

  : >"$GH_CALLS"
  GH_MODE=conflicting_pr run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body2"
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'PR #7 at'
  assert_has "$TMP/out" "conflicts with $GH_BASE_REF at $GH_BASE_SHA"
  assert_has "$TMP/out" "fetch $GH_BASE_REF from the PR base repository https://github.com/autumngarage/current"
  assert_has "$TMP/out" "refuse unless FETCH_HEAD is $GH_BASE_SHA"
  assert_has "$TMP/out" 'merge that verified commit'
  assert_has "$TMP/out" 'prove every feature-side edit survived against the pre-merge head'
  assert_has "$TMP/out" 'run the complete validation suite'
  assert_not_has "$TMP/out" 'rebase'
  assert_not_has "$GH_CALLS" 'actions/runs?head_sha='
  assert_not_has "$GH_CALLS" '/rerun'
  ok "a conflicting PR fails before required-workflow recovery"

  : >"$GH_CALLS"
  GH_MODE=conflicting_pr_moved run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body2"
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'PR coordinates moved before required-workflow recovery'
  assert_not_has "$TMP/out" 'conflicts with'
  assert_not_has "$GH_CALLS" 'actions/runs?head_sha='
  assert_not_has "$GH_CALLS" '/rerun'
  ok "conflict diagnosis is bound to re-read PR coordinates"

  : >"$GH_CALLS"
  GH_MODE=unknown_mergeability run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body2"
  assert_rc "$RUN_RC" 0
  assert_has "$GH_CALLS" 'actions/runs?head_sha='
  grep -q 'rerun 80' "$TMP/state/evidence-reruns" 2>/dev/null \
    || fail "unknown mergeability did not continue bounded workflow recovery"
  ok "unknown mergeability continues bounded workflow recovery"

  rm -f "$TMP/state/evidence-reruns" "$TMP/state/evidence-after-rerun"
  printf 'Original evidence body.\n' >"$TMP/state/pr-body"
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body2"
  assert_rc "$RUN_RC" 0
  grep -q 'rerun 80' "$TMP/state/evidence-reruns" 2>/dev/null \
    && ok "a corrected body re-ran the organization-required delivery-evidence run" \
    || fail "a corrected body did not re-run delivery evidence"
  assert_has "$TMP/out" 'Delivery evidence accepted by run 80 before hosted review.'

  rm -f "$TMP/state/evidence-reruns" "$TMP/state/evidence-after-rerun"
  touch "$TMP/state/same-name-external-decoy"
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body2"
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'multiple external delivery-evidence workflow identities'
  [ ! -f "$TMP/state/evidence-reruns" ] \
    && ok "same-named external workflows fail closed instead of rerunning the wrong gate" \
    || fail "an ambiguous external workflow was rerun"
  rm -f "$TMP/state/same-name-external-decoy"

  rm -f "$TMP/state/evidence-reruns" "$TMP/state/evidence-after-rerun" "$TMP/state/review-request"
  touch "$TMP/state/same-name-external-decoy-only"
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body2"
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'delivery-evidence run 82 is not bound to the policy-declared source file'
  [ ! -f "$TMP/state/review-request" ] \
    && ok "a sole same-named decoy cannot authorize hosted review" \
    || fail "a same-named decoy posted a hosted review request"
  rm -f "$TMP/state/same-name-external-decoy-only"

  rm -f "$TMP/state/evidence-reruns" "$TMP/state/evidence-after-rerun" "$TMP/state/review-request"
  touch "$TMP/state/incompatible-evidence-overlap" "$TMP/state/incompatible-evidence-run"
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body2"
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'delivery-evidence run 80 is not bound to the policy-declared source file'
  [ ! -f "$TMP/state/review-request" ] \
    && ok "an obsolete overlapping evidence pin cannot authorize hosted review" \
    || fail "an obsolete overlapping evidence pin posted a hosted review request"
  rm -f "$TMP/state/incompatible-evidence-overlap" "$TMP/state/incompatible-evidence-run"

  rm -f "$TMP/state/evidence-reruns" "$TMP/state/evidence-after-rerun"
  GH_EVIDENCE_CONCLUSION=failure run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body2"
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" 'body: unchanged'
  grep -q 'rerun 80' "$TMP/state/evidence-reruns" 2>/dev/null \
    && ok "an unchanged corrected body can recover a prior failed evaluation" \
    || fail "unchanged-body recovery did not re-run delivery evidence"

  rm -f "$TMP/state/evidence-reruns" "$TMP/state/evidence-after-rerun" "$TMP/state/review-request"
  printf 'Moved recovery body.\n' >"$TMP/body3"
  GH_MODE=delivery_moved run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body3"
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'PR coordinates moved before the review request was bound'
  [ ! -f "$TMP/state/review-request" ] \
    && ok "a moved PR is refused after the evidence request and before review mutation" \
    || fail "a moved PR still posted a review request"

  rm -f "$TMP/state/evidence-reruns" "$TMP/state/evidence-after-rerun" "$TMP/state/review-request"
  printf 'Transport recovery body.\n' >"$TMP/body4"
  GH_MODE=delivery_rerun_failure run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body4"
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'could not re-run delivery-evidence run 80'
  [ ! -f "$TMP/state/review-request" ] \
    && ok "a required-workflow transport failure stops before the review request" \
    || fail "a transport failure still posted a review request"

  # The edit above survived even though its rerun request did not. On retry,
  # the body is unchanged, but the older green attempt must not be reused.
  rm -f "$TMP/state/evidence-reruns" "$TMP/state/evidence-after-rerun" "$TMP/state/review-request"
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body4"
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" 'body: unchanged'
  grep -q 'rerun 80' "$TMP/state/evidence-reruns" 2>/dev/null \
    && ok "a retry re-runs evidence after a surviving body edit" \
    || fail "a retry reused evidence from before the surviving body edit"

  # GitHub exposes only a PR-wide update timestamp, so even a green result is
  # re-run: comments and reviews cannot be mistaken for body-version evidence.
  rm -f "$TMP/state/evidence-reruns" "$TMP/state/evidence-after-rerun"
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body4"
  assert_rc "$RUN_RC" 0
  grep -q 'rerun 80' "$TMP/state/evidence-reruns" 2>/dev/null \
    && ok "an unchanged green result is re-run against the surviving body" \
    || fail "an unchanged green result was reused without body-version evidence"

  rm -f "$TMP/state/evidence-reruns" "$TMP/state/evidence-after-rerun" "$TMP/state/gate-reruns" "$TMP/state/review-request"
  printf 'Expected final body.\n' >"$TMP/body5"
  GH_MODE=delivery_body_moved run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body5"
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'body moved while delivery evidence was refreshed'
  ok "a concurrent body mutation after request binding is refused before success"

  # A same-path repository-local workflow is not the organization-required
  # source declared by policy. Ignore it rather than waiting for an external
  # run that cannot exist.
  rm -f "$TMP/state/evidence-reruns" "$TMP/state/evidence-after-rerun" \
    "$TMP/state/gate-reruns" "$TMP/state/required-workflow-later-page" "$TMP/state/required-run-later-page"
  touch "$TMP/state/local-evidence-rule"
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body5"
  assert_rc "$RUN_RC" 0
  [ ! -f "$TMP/state/evidence-reruns" ] \
    && ok "a same-path local workflow is not mistaken for central delivery evidence" \
    || fail "a same-path local workflow triggered an external evidence rerun"
  rm -f "$TMP/state/review-gate" "$TMP/state/gate-reruns" "$TMP/state/evidence-reruns" \
    "$TMP/state/evidence-after-rerun" "$TMP/state/review-request" "$TMP/state/pr-body" \
    "$TMP/state/required-workflow-later-page" "$TMP/state/required-run-later-page" \
    "$TMP/state/local-evidence-rule"

  echo "==> open converges a reused PR on the title and body given (AUT-437)"
  # The PR exists with the original body; a second open with a different
  # body must apply it and say so, and a third with the same body must not
  # edit again. Silently keeping the old body let the delivery-evidence gate
  # fail with no signal from the one command the driver is told to use.
  rm -f "$TMP/state/edits" "$TMP/state/pr-title"
  printf 'Original body.\n' >"$TMP/state/pr-body"
  printf 'Corrected body with ## Review tier\n' >"$TMP/body2"
  run_pr "$TMP/out" open --title 'Test PR' \
    --body-file <(printf 'Corrected body with ## Review tier\n') --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"body":"updated"'
  if grep -q -- '--body-file' "$TMP/state/edits" \
    && [ "$(cat "$TMP/state/pr-body")" = "$(cat "$TMP/body2")" ]; then
    ok "a streamed body is reused from one snapshot"
  else
    fail "body not applied on reuse: $(cat "$TMP/state/edits" 2>/dev/null)"
  fi
  grep -q -- '--title' "$TMP/state/edits" && fail "title edited although unchanged" || true
  rm -f "$TMP/state/edits"
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body2" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"body":"unchanged"'
  [ ! -f "$TMP/state/edits" ] && ok "identical body performs no edit" || fail "an identical body was edited again"
  run_pr "$TMP/out" open --title 'Retitled' --body-file "$TMP/body2"
  assert_rc "$RUN_RC" 0
  grep -q -- '--title Retitled' "$TMP/state/edits" && assert_has "$TMP/out" 'body: updated' && ok "title converges too" || fail "title not applied: $(cat "$TMP/state/edits" 2>/dev/null)"
  rm -f "$TMP/state/edits" "$TMP/state/pr-title" "$TMP/state/pr-body"
  # A PR refused for head drift is not edited first: no partial mutation.
  rm -f "$TMP/state/edits"
  printf 'Original body.\n' >"$TMP/state/pr-body"
  touch "$TMP/state/pr-exists"
  rm -f "$TMP/state/stale-head-reads"
  GH_MODE=list_head_stale_then_current run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body2" --json
  assert_rc "$RUN_RC" 0
  [ "$(cat "$TMP/state/stale-head-reads")" -eq 3 ] \
    && ok "a post-push stale PR head converged within the bounded retry" \
    || fail "stale PR head did not take the expected three reads"
  assert_not_has "$TMP/out" 'does not match local/remote head'
  rm -f "$TMP/state/stale-head-reads" "$TMP/state/edits"
  GH_MODE=list_head_stale run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body2" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'does not match local/remote head'
  [ "$(grep -c '^pr list ' "$GH_CALLS")" -eq 11 ] \
    && ok "a real PR-head mismatch stops after the bounded retry window" \
    || fail "PR-head mismatch was not bounded to eleven reads"
  [ ! -f "$TMP/state/edits" ] && ok "no edit before the head check refuses" || fail "a drifted PR was edited before being refused"
  rm -f "$TMP/state/pr-body"
  # A freshly created PR carries the body by construction and says nothing
  # about applying it.
  rm -f "$TMP/state/pr-exists"
  streamed_body='Streamed PR body.

Closes #42'
  TMPDIR="$TMP" run_pr "$TMP/out" open --title 'Test PR' \
    --body-file <(printf '%s\n' "$streamed_body") --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"opened"'
  assert_not_has "$TMP/out" '"body":'
  if [ "$(cat "$TMP/state/pr-body")" = "$streamed_body" ]; then
    ok "a process-substitution body is snapshotted before PR creation"
  else
    fail "the streamed body did not survive PR creation"
  fi
  snapshot_leftover=""
  for candidate in "$TMP"/touchstone-pr-body.*; do
    [ -e "$candidate" ] || continue
    snapshot_leftover="$candidate"
    break
  done
  if [ -n "$snapshot_leftover" ]; then
    fail "the PR-body snapshot survived command exit"
  fi
  run_pr "$TMP/out" open --title 'Empty stream' --body-file <(printf '') --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'open requires a non-empty --body-file'
  [ ! -s "$GH_CALLS" ] || fail "an empty body stream reached GitHub"

  echo "==> open refuses head drift and reconciles a lying creation response"
  rm -f "$TMP/state/pr-exists" "$TMP/state/review-request"
  git -C "$TMP/project" switch -q main
  GH_HEAD="$MAIN_SHA" run_pr "$TMP/out" open --title 'Default branch' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'cannot open a pull request from the default branch'
  GH_HEAD="$MAIN_SHA" GH_BASE_REF=release run_pr "$TMP/out" open --title 'Default branch' \
    --body-file "$TMP/body" --base release --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'cannot open a pull request from the default branch'
  git -C "$TMP/project" switch -q feat/test
  : >"$GH_CALLS"
  run_pr "$TMP/out" open --title 'Wrong base' --body-file "$TMP/body" --base release --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'protects main, not PR base release'
  assert_not_has "$GH_CALLS" 'pr create'
  touch "$TMP/state/pr-exists"
  GH_HEAD=wrong run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'does not match local/remote head'
  GH_HEAD="$HEAD_SHA"
  rm -f "$TMP/state/pr-exists"
  caller_directory="$PWD"
  cd "$TMP"
  GH_MODE=create_lied run_pr "$TMP/out" open --title 'Test PR' --body-file body --json
  cd "$caller_directory"
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"opened"'
  assert_has "$TMP/out" '"reviewRequest":"posted:'
  # The result names the branch it acted on. Two pull requests were opened for
  # the wrong branch, and nothing in the output would have shown it.
  assert_has "$TMP/out" '"branch":"feat/test"'
  assert_has "$GH_CALLS" "pr create --repo github.com/autumngarage/current --head feat/test --base main --title Test PR --body-file"
  [ "$(cat "$TMP/state/pr-body")" = "$(cat "$TMP/body")" ] \
    || fail "a relative body path was not snapshotted before the project-directory change"
  [ "$(grep -c '^pr comment' "$GH_CALLS")" -eq 1 ] || fail "open did not post one review request"
  rm -f "$TMP/state/review-request"
  GH_MODE=comment_lied run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'could not post the review request'
  rm -f "$TMP/state/review-request"
  GH_MODE=comment_unverified run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'was not verified'
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"existing"'
  assert_has "$TMP/out" '"reviewRequest":"posted:'
  [ "$(grep -c '^pr comment' "$GH_CALLS")" -eq 1 ] || fail "recovery did not post exactly one review request"
  rm -f "$TMP/state/review-request"
  GH_MODE=comment_success_stderr run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewRequest":"posted:https://example.test/pr/7#issuecomment-1"'
  assert_not_has "$TMP/out" 'comment debug detail'
  # Human-readable output carries the branch too: the JSON mode is not the
  # one an operator reads while shipping.
  rm -f "$TMP/state/review-request"
  GH_MODE=comment_success_stderr run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body"
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" 'branch: feat/test'
  # A matching --expect-branch reaches a successful open rather than being
  # refused somewhere along the way.
  rm -f "$TMP/state/review-request"
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --expect-branch feat/test --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"branch":"feat/test"'
  # A mismatch refuses before any GitHub call is made.
  : >"$GH_CALLS"
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --expect-branch feat/other --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'expected branch feat/other'
  [ ! -s "$GH_CALLS" ] || fail "a refused branch binding still called gh"
  # The late re-check is the only thing standing between a checkout that
  # moves mid-command and a wrong-branch mutation. Delete it and the two
  # assertions above still pass, so exercise the race directly: the mock
  # switches the branch during the repository read, between the two
  # comparisons.
  : >"$GH_CALLS"
  GH_SWITCH_BRANCH_IN="$TMP/project" run_pr "$TMP/out" open --title 'Test PR' \
    --body-file "$TMP/body" --expect-branch feat/test --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'now has'
  if grep -qE '^pr create|^pr comment' "$GH_CALLS"; then
    fail "a checkout that moved mid-command still mutated the pull request"
  fi
  git -C "$TMP/project" checkout -q feat/test
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewRequest":"existing:'
  [ "$(grep -c '^pr comment' "$GH_CALLS" || true)" -eq 0 ] || fail "rerun duplicated the review request"
  # Without a pinned gate on the base there is no server-side binding to
  # wait for: the command proves the request comment and the coordinates,
  # names the gap, and never polls the retired status context.
  assert_not_has "$GH_CALLS" 'touchstone/review-request-v1'
  assert_not_has "$GH_CALLS" "/commits/$HEAD_SHA/statuses"
  assert_has "$TMP/out" 'No pinned review gate protects main here'
  GH_MODE=binding_moved run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'PR coordinates moved before the review request was bound'
  GH_MODE=live_comment_invalid run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'is no longer a valid driver request'
  rm -f "$TMP/state/review-request"
  GH_MODE=spoofed_request run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  [ "$(grep -c '^pr comment' "$GH_CALLS")" -eq 1 ] || fail "spoofed marker suppressed the real review request"
  rm -f "$TMP/state/review-request"
  GH_MODE=marker_only run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  [ "$(grep -c '^pr comment' "$GH_CALLS")" -eq 1 ] || fail "marker without trigger suppressed the real review request"
  GH_MODE=many_requests run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewRequest":"existing:https://example.test/pr/7#issuecomment-1"'

  printf '%s\n' 'Local draft without a closer.' >"$TMP/local-draft"
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/local-draft" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"existing"'

  printf '%s\n' 'Live body without a locally parsed closer.' >"$TMP/state/pr-body"
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  cp "$TMP/body" "$TMP/state/pr-body"

  GH_BASE_SHA=release-sha \
    run_pr "$TMP/out" open --title 'Moved-base PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'already has a review request for different base coordinates'
  rm -f "$TMP/state/review-request"
  GH_BASE_SHA=release-sha \
    run_pr "$TMP/out" open --title 'Moved-base PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$GH_CALLS" "touchstone:pr-open head=$HEAD_SHA base=main base_sha=release-sha"
  GH_BASE_SHA=base-sha

  echo "==> review findings and responses stay on the canonical GitHub surface"
  run_pr "$TMP/out" findings 7 --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'touchstone pr open'
  run_pr "$TMP/out" respond 7 --comment-id 51 --body-file "$TMP/reply" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'touchstone pr open'

  echo "==> merge admits only a head the pinned gate already accepts"
  touch "$TMP/state/review-gate" "$TMP/state/pr-exists"
  rm -f "$TMP/state/gate-reruns" "$TMP/state/gate-after-rerun"
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 0
  [ ! -e "$TMP/state/gate-reruns" ] \
    || fail "merge re-ran review instead of observing the existing verdict"
  assert_has "$GH_CALLS" 'pr merge'
  assert_has "$TMP/out" '"reviewGate":{"runId":"77","action":"verified-success"}'
  rm -f "$TMP/state/merged"
  : >"$GH_CALLS"
  GH_MODE=status_gate_stale_review run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'review evidence is stale'
  assert_has "$TMP/out" '2026-08-27T17:35:00Z'
  assert_not_has "$GH_CALLS" 'pr merge'
  rm -f "$TMP/state/gate-reruns" "$TMP/state/gate-after-rerun" "$TMP/state/merged"
  : >"$GH_CALLS"
  GH_MODE=status_gate_pending run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'is still evaluating'
  assert_not_has "$GH_CALLS" 'pr merge'
  [ ! -e "$TMP/state/gate-reruns" ] \
    || fail "merge mutated a pending review evaluation"
  : >"$GH_CALLS"
  GH_MODE=status_gate_failure run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'is not successful'
  assert_not_has "$GH_CALLS" 'pr merge'
  [ ! -e "$TMP/state/gate-reruns" ] \
    || fail "merge mutated a failed review evaluation"
  : >"$GH_CALLS"
  GH_MODE=moved_during_gate run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'moved (head moved-head'
  assert_not_has "$GH_CALLS" 'pr merge'
  rm -f "$TMP/state/gate-reruns" "$TMP/state/gate-after-rerun" "$TMP/state/merged"
  GH_MODE=base_advanced run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 0
  assert_has "$GH_CALLS" 'pr merge'
  rm -f "$TMP/state/review-gate" "$TMP/state/gate-reruns" "$TMP/state/gate-after-rerun"

  echo "==> behavior v2 merge returns control without arming an active evaluation"
  touch "$TMP/state/review-gate"
  rm -f "$TMP/state/merged" "$TMP/state/gate-reruns"
  : >"$GH_CALLS"
  GH_MODE=status_gate_pending run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'is still evaluating'
  assert_not_has "$GH_CALLS" 'pr merge'
  [ ! -f "$TMP/state/gate-reruns" ] \
    || fail "behavior v2 merge re-ran an evaluation that was already active"
  rm -f "$TMP/state/review-gate" "$TMP/state/merged"

  echo "==> without a pinned gate, merge fails closed unless --unguarded, which records the gap"
  rm -f "$TMP/state/review-gate" "$TMP/state/merged"
  : >"$GH_CALLS"
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'enforcement on main of autumngarage/current is partial'
  assert_has "$TMP/out" 'derive a consumer policy first'
  assert_not_has "$GH_CALLS" 'pr merge'
  : >"$GH_CALLS"
  rm -f "$TMP/state/unguarded-recorded"
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --unguarded --json
  assert_rc "$RUN_RC" 0
  grep -q 'touchstone:unguarded-merge head=' "$GH_CALLS" || fail "unguarded merge did not record the gap on the PR"
  grep -q 'Unguarded merge requested' "$GH_CALLS" || fail "the record does not describe an attempt"
  assert_has "$GH_CALLS" 'pr merge'
  # A retry reuses the record instead of posting it again.
  : >"$GH_CALLS"
  rm -f "$TMP/state/merged"
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --unguarded --json
  assert_rc "$RUN_RC" 0
  [ "$(grep -c '^pr comment' "$GH_CALLS" || true)" -eq 0 ] || fail "a retried unguarded merge posted a second record"
  rm -f "$TMP/state/unguarded-recorded"
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --unguarded --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'applies to merge only'

  echo "==> policy status and pr status report what GitHub enforces"
  run_pr "$TMP/out" policy-status --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"enforcement":{"status":"partial","missing":["delivery-evidence workflow","merge queue","review-gate workflow","validate workflow"]}'
  run_pr "$TMP/out" policy-status
  assert_has "$TMP/out" 'enforcement: partial (missing: delivery-evidence workflow, merge queue, review-gate workflow, validate workflow)'
  # No consumer policy is shipped for this fixture repository: the remedy is
  # the derivation step, never a file that does not exist.
  assert_has "$TMP/out" 'remedy: derive a consumer policy first: scripts/derive-consumer-policy.sh current'
  assert_has "$TMP/out" "at $(git -C "$ROOT" rev-parse HEAD)"

  echo "==> source policy provenance ignores ambient Git state (AUT-522)"
  GIT_DIR="$TMP/project/.git" GIT_WORK_TREE="$TMP/project" run_pr "$TMP/out" policy-status --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" "\"policyRevision\":\"$(git -C "$ROOT" rev-parse HEAD)\""

  echo "==> source provenance covers the complete policy inventory (AUT-522)"
  mkdir -p "$TMP/source-tool"
  cp -R "$ROOT/bin" "$ROOT/scripts" "$ROOT/policy" "$TMP/source-tool/"
  cp "$ROOT/VERSION" "$TMP/source-tool/VERSION"
  git -C "$TMP/source-tool" init -q -b main
  git -C "$TMP/source-tool" config user.name test
  git -C "$TMP/source-tool" config user.email test@example.com
  git -C "$TMP/source-tool" add bin scripts policy VERSION
  git -C "$TMP/source-tool" commit -qm fixture
  printf '\n' >>"$TMP/source-tool/policy/github/consumers/vesper.json"
  set +e
  bash "$TMP/source-tool/bin/touchstone" pr policy-status --project "$TMP/project" --json >"$TMP/out" 2>&1
  RUN_RC=$?
  set -e
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'the policy inventory is not represented by source revision'

  echo "==> an installed policy remedy names its immutable release (AUT-522)"
  mkdir -p "$TMP/installed/bin" "$TMP/installed/scripts" "$TMP/installed/policy/github/workflow-sources"
  cp "$ROOT/bin/touchstone" "$TMP/installed/bin/touchstone"
  cp "$ROOT/scripts/touchstone-pr.sh" "$TMP/installed/scripts/touchstone-pr.sh"
  cp "$ROOT/policy/github/touchstone-main.json" "$TMP/installed/policy/github/touchstone-main.json"
  printf '3.4.0\n' >"$TMP/installed/VERSION"
  set +e
  bash "$TMP/installed/bin/touchstone" pr policy-status --project "$TMP/project" >"$TMP/out" 2>&1
  RUN_RC=$?
  set -e
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" 'policy: policy/github/touchstone-main.json at v3.4.0'
  assert_has "$TMP/out" 'in a clean Touchstone checkout at v3.4.0'
  assert_not_has "$TMP/out" "$(git -C "$ROOT" rev-parse HEAD)"

  touch "$TMP/state/review-gate"
  run_pr "$TMP/out" policy-status --json
  assert_has "$TMP/out" '"enforcement":{"status":"applied","missing":[]}'

  echo "==> a Touchstone policy-pin PR assesses the live base policy (AUT-522)"
  GH_FAKE_REPO=autumngarage/touchstone GH_BASE_SHA="$MAIN_SHA" run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"enforcement":{"status":"applied","missing":[]}'
  assert_has "$TMP/out" "\"policy\":{\"source\":\"policy/github/touchstone-main.json\",\"revision\":\"$MAIN_SHA\"}"
  assert_has "$TMP/out" "\"candidatePolicy\":{\"source\":\"policy/github/touchstone-main.json\",\"revision\":\"$HEAD_SHA\",\"role\":\"desired-after-merge\"}"
  GH_FAKE_REPO=autumngarage/touchstone GH_BASE_SHA="$GH_LEGACY_POLICY_SHA" run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"enforcement":{"status":"applied","missing":[]}'
  assert_has "$TMP/out" "\"revision\":\"$GH_LEGACY_POLICY_SHA\""
  assert_not_has "$GH_CALLS" 'touchstone-workflows/contents/.touchstone-source-contract.json'
  jq '.branch = "release"' "$GH_CANDIDATE_POLICY" >"$TMP/candidate-invalid-branch.json"
  GH_CANDIDATE_POLICY="$TMP/candidate-invalid-branch.json" GH_FAKE_REPO=autumngarage/touchstone \
    GH_BASE_SHA="$MAIN_SHA" run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" "\"policy\":{\"source\":\"policy/github/touchstone-main.json\",\"revision\":\"$MAIN_SHA\"}"
  assert_has "$TMP/out" '"enforcement":{"status":"applied","missing":[]}'
  printf '%s\n' '{not-json' >"$TMP/candidate-malformed.json"
  GH_CANDIDATE_POLICY="$TMP/candidate-malformed.json" GH_FAKE_REPO=autumngarage/touchstone \
    GH_BASE_SHA="$MAIN_SHA" run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" "\"policy\":{\"source\":\"policy/github/touchstone-main.json\",\"revision\":\"$MAIN_SHA\"}"
  assert_has "$TMP/out" "\"candidatePolicy\":{\"source\":\"policy/github/touchstone-main.json\",\"revision\":\"$HEAD_SHA\",\"role\":\"desired-after-merge\"}"
  rm -f "$TMP/state/candidate-files-read"
  GH_MODE=candidate_files_moved GH_FAKE_REPO=autumngarage/touchstone GH_BASE_SHA="$MAIN_SHA" \
    run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'after enforcement was assessed'
  TMPDIR="$TMP/does-not-exist" GH_FAKE_REPO=autumngarage/touchstone GH_BASE_SHA="$MAIN_SHA" \
    run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" "\"policy\":{\"source\":\"policy/github/touchstone-main.json\",\"revision\":\"$MAIN_SHA\"}"
  touch "$TMP/state/policy-unchanged"
  GH_FAKE_REPO=autumngarage/touchstone GH_BASE_SHA="$MAIN_SHA" run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_not_has "$TMP/out" '"candidatePolicy"'
  assert_not_has "$GH_CALLS" "/contents/policy/github/touchstone-main.json?ref=$HEAD_SHA"
  rm -f "$TMP/state/policy-unchanged"
  touch "$TMP/state/policy-removed"
  GH_FAKE_REPO=autumngarage/touchstone GH_BASE_SHA="$MAIN_SHA" run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" "\"candidatePolicy\":{\"source\":\"policy/github/touchstone-main.json\",\"revision\":\"$HEAD_SHA\",\"role\":\"absent-after-merge\"}"
  assert_not_has "$GH_CALLS" "/contents/policy/github/touchstone-main.json?ref=$HEAD_SHA"
  rm -f "$TMP/state/policy-removed"
  touch "$TMP/state/policy-renamed"
  GH_FAKE_REPO=autumngarage/touchstone GH_BASE_SHA="$MAIN_SHA" run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" "\"candidatePolicy\":{\"source\":\"policy/github/touchstone-renamed.json\",\"revision\":\"$HEAD_SHA\",\"role\":\"desired-after-merge\"}"
  assert_has "$GH_CALLS" "repos/autumngarage/touchstone/contents/policy/github/touchstone-renamed.json?ref=$HEAD_SHA"
  rm -f "$TMP/state/policy-renamed"
  touch "$TMP/state/policy-unchanged" "$TMP/state/head-repo-missing"
  GH_FAKE_REPO=autumngarage/touchstone GH_BASE_SHA="$MAIN_SHA" run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" "\"baseRef\":\"main\",\"baseSha\":\"$MAIN_SHA\""
  rm -f "$TMP/state/policy-unchanged" "$TMP/state/head-repo-missing"
  GH_FAKE_REPO=autumngarage/touchstone GH_BASE_SHA="$EMPTY_POLICY_SHA" run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" "could not read the protected branch from policy/github/touchstone-main.json at $EMPTY_POLICY_SHA"
  fork_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  GH_HEAD="$fork_head" GH_FAKE_REPO=autumngarage/touchstone GH_FAKE_HEAD_REPO=someone/touchstone \
    GH_BASE_SHA="$MAIN_SHA" run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" "\"revision\":\"$fork_head\",\"role\":\"desired-after-merge\""
  assert_has "$GH_CALLS" "repos/someone/touchstone/contents/policy/github/touchstone-main.json?ref=$fork_head"
  GH_FAKE_REPO=autumngarage/touchstone GH_BASE_SHA=unresolved run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'PR base policy revision is not an immutable commit SHA: unresolved'
  : >"$GH_CALLS"
  rm -f "$TMP/state/merged" "$TMP/state/gate-reruns" "$TMP/state/gate-after-rerun"
  GH_MODE=base_advanced GH_FAKE_REPO=autumngarage/touchstone GH_BASE_SHA="$MAIN_SHA" \
    run_pr "$TMP/out" merge 7 --head "$HEAD_SHA"
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'after enforcement was assessed'
  assert_not_has "$GH_CALLS" 'pr merge'
  : >"$GH_CALLS"
  rm -f "$TMP/state/gate-reruns" "$TMP/state/gate-after-rerun"
  GH_FAKE_REPO=autumngarage/touchstone GH_BASE_SHA="$MAIN_SHA" run_pr "$TMP/out" merge 7 --head "$HEAD_SHA"
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" "Enforcement assessed with policy/github/touchstone-main.json at $MAIN_SHA."
  assert_has "$TMP/out" "Candidate policy/github/touchstone-main.json at $HEAD_SHA is desired-after-merge."
  assert_has "$GH_CALLS" 'pr merge'
  assert_not_has "$GH_CALLS" 'touchstone:unguarded-merge'
  rm -f "$TMP/state/merged" "$TMP/state/gate-reruns" "$TMP/state/gate-after-rerun"

  # The same paths from a stale revision are not the canonical gates, and a
  # stale gate does not take the guarded merge path either.
  touch "$TMP/state/stale-pin"
  run_pr "$TMP/out" policy-status --json
  assert_has "$TMP/out" '"status":"partial"'
  assert_has "$TMP/out" 'review-gate workflow (present but not pinned at the policy revision)'
  assert_has "$TMP/out" "expected $GH_POLICY_SHA; observed $GH_DIVERGED_SHA"
  assert_has "$TMP/out" 'validate workflow (present but not pinned at the policy revision)'
  assert_not_has "$TMP/out" 'delivery-evidence workflow'
  : >"$GH_CALLS"
  rm -f "$TMP/state/merged"
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'not pinned at the policy revision'
  assert_not_has "$GH_CALLS" 'pr merge'
  rm -f "$TMP/state/stale-pin"

  echo "==> a pin ahead of the tool's own revision on the same lineage is enforcement (AUT-559)"
  # The tool's policy file travels with the release; the ruleset is applied
  # from a checkout that moves ahead of it. A gate pinned at a descendant of
  # the tool's revision, published on the branch the policy pins, enforces at
  # least what the tool expects -- reporting it as unpinned made every
  # consumer PR unmergeable until the next release.
  touch "$TMP/state/ahead-pin"
  : >"$GH_CALLS"
  run_pr "$TMP/out" policy-status --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"enforcement":{"status":"applied","missing":[]}'
  # The source repository is resolved by the id the pin carries, and the
  # lineage is read from GitHub -- not assumed from the bundled SHA.
  assert_has "$GH_CALLS" 'repositories/1333343261'
  assert_has "$GH_CALLS" "repos/autumngarage/touchstone-workflows/compare/$GH_POLICY_SHA...$GH_AHEAD_SHA"
  # Three gates carry one pin between them: it is resolved once, not thrice.
  [ "$(grep -c 'repositories/1333343261' "$GH_CALLS")" -eq 1 ] \
    || fail "the workflow source was resolved once per gate instead of once per pin"
  [ "$(grep -c "touchstone-workflows/contents/.touchstone-source-contract.json?ref=$GH_AHEAD_SHA" "$GH_CALLS")" -eq 1 ] \
    || fail "the gate behavior contract was read once per gate instead of once per pin"
  : >"$GH_CALLS"
  rm -f "$TMP/state/merged" "$TMP/state/gate-reruns" "$TMP/state/gate-after-rerun"
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 0
  assert_has "$GH_CALLS" 'pr merge'
  rm -f "$TMP/state/ahead-pin" "$TMP/state/merged" "$TMP/state/gate-reruns" "$TMP/state/gate-after-rerun"

  echo "==> overlapping pins accept any compatible enforced descendant (AUT-568)"
  touch "$TMP/state/overlapping-pins"
  run_pr "$TMP/out" policy-status --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"enforcement":{"status":"applied","missing":[]}'
  assert_has "$GH_CALLS" "touchstone-workflows/contents/.touchstone-source-contract.json?ref=$GH_MID_SHA"
  assert_has "$GH_CALLS" "touchstone-workflows/contents/.touchstone-source-contract.json?ref=$GH_AHEAD_SHA"
  rm -f "$TMP/state/overlapping-pins"

  echo "==> pinned gate behavior is checked at the exact enforced revision (AUT-568)"
  touch "$TMP/state/review-gate" "$TMP/state/ahead-pin" "$TMP/state/behavior-version-legacy"
  run_pr "$TMP/out" policy-status --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"partial"'
  assert_has "$TMP/out" "does not declare supported gate behavior contract 2"
  assert_has "$TMP/out" "observed $GH_AHEAD_SHA"
  assert_has "$GH_CALLS" "touchstone-workflows/contents/.touchstone-source-contract.json?ref=$GH_AHEAD_SHA"
  rm -f "$TMP/state/ahead-pin" "$TMP/state/behavior-version-legacy"
  touch "$TMP/state/behavior-version-missing"
  run_pr "$TMP/out" policy-status --json
  assert_has "$TMP/out" '"status":"partial"'
  assert_has "$TMP/out" "does not declare supported gate behavior contract 2"
  rm -f "$TMP/state/behavior-version-missing"
  touch "$TMP/state/behavior-manifest-unreadable"
  run_pr "$TMP/out" policy-status --json
  assert_has "$TMP/out" '"status":"partial"'
  assert_has "$TMP/out" ".touchstone-source-contract.json could not be read"
  rm -f "$TMP/state/behavior-manifest-unreadable"

  echo "==> a pin behind, off the branch, from another source, or unreadable still fails closed"
  # Behind the tool's revision: the repository is enforcing less than the
  # policy, which is the gap the guard exists for.
  touch "$TMP/state/behind-pin"
  run_pr "$TMP/out" policy-status --json
  assert_has "$TMP/out" '"status":"partial"'
  assert_has "$TMP/out" 'review-gate workflow (present but not pinned at the policy revision)'
  rm -f "$TMP/state/behind-pin"
  # Descended from the tool's revision but never published on the branch the
  # policy pins: a floor alone would admit it; the branch head is the ceiling.
  touch "$TMP/state/offref-pin"
  run_pr "$TMP/out" policy-status --json
  assert_has "$TMP/out" '"status":"partial"'
  assert_has "$TMP/out" 'validate workflow (present but not pinned at the policy revision)'
  : >"$GH_CALLS"
  rm -f "$TMP/state/merged"
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 2
  assert_not_has "$GH_CALLS" 'pr merge'
  rm -f "$TMP/state/offref-pin"
  # The right path and revision from the wrong repository is not the gate,
  # and lineage is never asked about across repositories.
  touch "$TMP/state/other-source-pin"
  : >"$GH_CALLS"
  run_pr "$TMP/out" policy-status --json
  assert_has "$TMP/out" '"status":"partial"'
  assert_has "$TMP/out" 'review-gate workflow (present but not pinned at the policy revision)'
  assert_not_has "$GH_CALLS" '/compare/'
  rm -f "$TMP/state/other-source-pin"
  # Indeterminate is not permission: a revision the source repository does
  # not carry, and a branch head that cannot be read, both stay closed and
  # say so rather than being reported as the policy revision.
  touch "$TMP/state/unknown-pin"
  run_pr "$TMP/out" policy-status --json
  assert_has "$TMP/out" '"status":"partial"'
  assert_has "$TMP/out" 'review-gate workflow (present but pinned at a revision this tool could not verify:'
  : >"$GH_CALLS"
  rm -f "$TMP/state/merged"
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'could not verify'
  assert_not_has "$GH_CALLS" 'pr merge'
  rm -f "$TMP/state/unknown-pin"
  touch "$TMP/state/ahead-pin" "$TMP/state/source-head-unreadable"
  run_pr "$TMP/out" policy-status --json
  assert_has "$TMP/out" '"status":"partial"'
  assert_has "$TMP/out" 'could not verify'
  rm -f "$TMP/state/ahead-pin" "$TMP/state/source-head-unreadable"
  # A pull-request rule without thread resolution is not the policy's rule.
  touch "$TMP/state/pr-rule-no-threads"
  run_pr "$TMP/out" policy-status --json
  assert_has "$TMP/out" 'pull-request rule (with thread resolution)'
  rm -f "$TMP/state/pr-rule-no-threads"
  # Nothing at all -- no rules, auto-merge off -- is "none", not "partial".
  rm -f "$TMP/state/review-gate"
  touch "$TMP/state/no-rules" "$TMP/state/auto-merge-off"
  run_pr "$TMP/out" policy-status --json
  assert_has "$TMP/out" '"status":"none"'
  rm -f "$TMP/state/no-rules" "$TMP/state/auto-merge-off"
  touch "$TMP/state/review-gate"
  # Disabled repository Actions void every required workflow at once: the
  # status is "none" with the gap named first, whatever the rules say, and
  # open refuses before it pushes anything (AUT-467).
  touch "$TMP/state/actions-disabled"
  run_pr "$TMP/out" policy-status --json
  assert_has "$TMP/out" '"status":"none"'
  assert_has "$TMP/out" '"missing":["repository Actions (disabled: no required workflow can run; enable them: gh api --hostname github.com -X PUT repos/autumngarage/current/actions/permissions -F enabled=true)"'
  run_pr "$TMP/out" policy-status
  assert_has "$TMP/out" 'enforcement: none (missing: repository Actions (disabled'
  assert_has "$TMP/out" 'remedy: enable them: gh api --hostname github.com -X PUT repos/autumngarage/current/actions/permissions -F enabled=true, then re-run this command'
  assert_not_has "$TMP/out" 'github-policy.sh apply'
  : >"$GH_CALLS"
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --expect-branch feat/test --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'repository Actions are disabled for autumngarage/current'
  assert_has "$TMP/out" 'Enable them: gh api --hostname github.com -X PUT repos/autumngarage/current/actions/permissions -F enabled=true, then retry.'
  assert_not_has "$GH_CALLS" 'pr create'
  assert_not_has "$GH_CALLS" 'pr comment'
  rm -f "$TMP/state/actions-disabled"
  # Actions switched off after open's preflight, with a required gate that
  # never produces a run: the timeout names the setting, not a slow run.
  rm -f "$TMP/state/review-request" "$TMP/state/pr-exists"
  touch "$TMP/state/review-gate" "$TMP/state/gate-never-runs" "$TMP/state/actions-disabled-after-preflight"
  TOUCHSTONE_GATE_ATTEMPTS=2 run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --expect-branch feat/test --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'no delivery-evidence run can exist for'
  assert_has "$TMP/out" 'repository Actions are disabled for autumngarage/current'
  assert_not_has "$TMP/out" 'Wait for the gate run to finish'
  rm -f "$TMP/state/review-gate" "$TMP/state/gate-never-runs" "$TMP/state/actions-disabled-after-preflight" "$TMP/state/actions-preflight-seen" "$TMP/state/review-request"
  touch "$TMP/state/review-gate"
  # A consumer derived --no-queue expects no queue: the tool consults the
  # repository's own shipped policy, reports the missing atomic queue boundary,
  # and requires an audited override before arming auto-merge.
  mkdir -p "$TMP/tool2/policy/github/consumers" "$TMP/tool2/policy/github/workflow-sources"
  cp -R "$ROOT/bin" "$ROOT/scripts" "$TMP/tool2/"
  cp "$ROOT/VERSION" "$TMP/tool2/VERSION"
  cp "$ROOT/policy/github/touchstone-main.json" "$TMP/tool2/policy/github/touchstone-main.json"
  cp "$ROOT/policy/github/workflow-sources/touchstone-workflows.json" "$TMP/tool2/policy/github/workflow-sources/touchstone-workflows.json"
  jq '.managedRepositoryRuleset = null | .repository = "current"' "$ROOT/policy/github/touchstone-main.json" >"$TMP/tool2/policy/github/consumers/current.json"
  # A same-named consumer file for another organization must not be consulted.
  jq '.organization = "someone-else"' "$TMP/tool2/policy/github/consumers/current.json" >"$TMP/tool2/policy/github/consumers/current.other.json"
  touch "$TMP/state/no-queue-rule"
  set +e
  bash "$TMP/tool2/bin/touchstone" pr policy-status --project "$TMP/project" --json >"$TMP/out" 2>&1
  RUN_RC=$?
  set -e
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"policy":"policy/github/consumers/current.json"'
  assert_has "$TMP/out" '"enforcement":{"status":"partial","missing":["merge queue"]}'
  : >"$GH_CALLS"
  rm -f "$TMP/state/merged" "$TMP/state/gate-reruns" "$TMP/state/gate-after-rerun"
  set +e
  GH_MODE=auto_merge bash "$TMP/tool2/bin/touchstone" pr merge 7 --head "$HEAD_SHA" --project "$TMP/project" --json >"$TMP/out" 2>&1
  RUN_RC=$?
  set -e
  assert_rc "$RUN_RC" 2
  assert_not_has "$GH_CALLS" 'pr merge'
  assert_has "$TMP/out" 'merge queue'
  set +e
  GH_MODE=auto_merge bash "$TMP/tool2/bin/touchstone" pr merge 7 --head "$HEAD_SHA" --project "$TMP/project" --unguarded --json >"$TMP/out" 2>&1
  RUN_RC=$?
  set -e
  assert_rc "$RUN_RC" 0
  grep -q '^pr merge.*--auto' "$GH_CALLS" || fail "an explicitly unguarded queue-less merge did not arm auto-merge: $(grep '^pr merge' "$GH_CALLS")"
  assert_has "$TMP/out" '"status":"auto-merge-enabled"'
  touch "$TMP/state/auto-merge-off"
  set +e
  bash "$TMP/tool2/bin/touchstone" pr policy-status --project "$TMP/project" --json >"$TMP/out" 2>&1
  set -e
  assert_has "$TMP/out" '"missing":["auto-merge setting","merge queue"]'
  rm -f "$TMP/state/auto-merge-off" "$TMP/state/no-queue-rule"
  run_pr "$TMP/out" status 7 --json
  assert_has "$TMP/out" '"enforcement":{"status":"applied","missing":[]}'
  run_pr "$TMP/out" status 7
  assert_has "$TMP/out" 'enforcement on main: applied'
  rm -f "$TMP/state/review-gate"

  echo "==> consumer policy assesses every declared required status (AUT-577)"
  jq '.repository = "current"
    | .managedRuleset.name = "Touchstone policy v1: autumngarage/current@main"
    | .managedRuleset.conditions.repository_name.include = ["current"]' \
    "$ROOT/policy/github/consumers/convoy.json" >"$TMP/tool2/policy/github/consumers/current.json"
  touch "$TMP/state/review-gate" "$TMP/state/no-queue-rule" "$TMP/state/consumer-status"
  bash "$TMP/tool2/bin/touchstone" pr policy-status --project "$TMP/project" --json >"$TMP/out" 2>&1
  assert_has "$TMP/out" '"enforcement":{"status":"partial","missing":["merge queue"]}'
  rm -f "$TMP/state/consumer-status"
  bash "$TMP/tool2/bin/touchstone" pr policy-status --project "$TMP/project" --json >"$TMP/out" 2>&1
  assert_has "$TMP/out" '"enforcement":{"status":"partial","missing":["convoy/delivery-protocol status","merge queue"]}'
  rm -f "$TMP/state/no-queue-rule" "$TMP/state/review-gate"

  echo "==> workflow-source policy uses its required status without inventing a review gate (AUT-531)"
  GH_FAKE_REPO=autumngarage/touchstone-workflows run_pr "$TMP/out" policy-status --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"policy":"policy/github/workflow-sources/touchstone-workflows.json"'
  assert_has "$TMP/out" '"enforcement":{"status":"applied","missing":[]}'
  while IFS='|' read -r flag missing; do
    touch "$TMP/state/$flag"
    GH_FAKE_REPO=autumngarage/touchstone-workflows run_pr "$TMP/out" policy-status --json
    assert_rc "$RUN_RC" 0
    assert_has "$TMP/out" '"status":"partial"'
    assert_has "$TMP/out" "$missing"
    rm -f "$TMP/state/$flag"
  done <<'EOF'
source-no-status|source contract status
no-queue-rule|merge queue
pr-rule-no-threads|pull-request rule (with thread resolution)
source-no-deletion|deletion protection
source-no-non-fast-forward|force-push protection
auto-merge-off|auto-merge setting
EOF
  rm -f "$TMP/state/gate-reruns" "$TMP/state/merged"
  GH_FAKE_REPO=autumngarage/touchstone-workflows run_pr "$TMP/out" open --title 'Source change' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" 'exact-head review remains mandatory driver procedure'
  assert_not_has "$TMP/out" 'Track the policy gap'
  assert_not_has "$GH_CALLS" 'actions/runs?head_sha='
  GH_FAKE_REPO=autumngarage/touchstone-workflows run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 0
  assert_has "$GH_CALLS" 'pr merge 7 --repo github.com/autumngarage/touchstone-workflows --squash'
  assert_has "$GH_CALLS" "--match-head-commit $HEAD_SHA"
  assert_not_has "$GH_CALLS" 'actions/runs?head_sha='
  assert_not_has "$GH_CALLS" ' --auto '
  rm -f "$TMP/state/merged"

  source_policy="$TMP/tool2/policy/github/workflow-sources/touchstone-workflows.json"
  cp "$source_policy" "$TMP/source-policy.good"
  jq '(.managedRuleset.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) = []' \
    "$source_policy" >"$TMP/source-policy.empty"
  mv "$TMP/source-policy.empty" "$source_policy"
  set +e
  GH_FAKE_REPO=autumngarage/touchstone-workflows bash "$TMP/tool2/bin/touchstone" pr policy-status --project "$TMP/project" --json >"$TMP/out" 2>&1
  RUN_RC=$?
  set -e
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'declares no required status check'
  mv "$TMP/source-policy.good" "$source_policy"
  cp "$source_policy" "$TMP/source-policy.good"
  jq '.branch = "release"' "$source_policy" >"$TMP/source-policy.wrong-branch"
  mv "$TMP/source-policy.wrong-branch" "$source_policy"
  set +e
  GH_FAKE_REPO=autumngarage/touchstone-workflows bash "$TMP/tool2/bin/touchstone" pr policy-status --project "$TMP/project" --json >"$TMP/out" 2>&1
  RUN_RC=$?
  set -e
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'protects release, not PR base main'
  assert_has "$TMP/out" 'enforcement cannot be inferred from another branch'
  mv "$TMP/source-policy.good" "$source_policy"
  cp "$source_policy" "$TMP/tool2/policy/github/workflow-sources/duplicate.json"
  set +e
  GH_FAKE_REPO=autumngarage/touchstone-workflows bash "$TMP/tool2/bin/touchstone" pr policy-status --project "$TMP/project" --json >"$TMP/out" 2>&1
  RUN_RC=$?
  set -e
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'multiple workflow-source policies match autumngarage/touchstone-workflows'
  rm "$TMP/tool2/policy/github/workflow-sources/duplicate.json"
  jq '.organization = "someone-else"' "$source_policy" >"$TMP/tool2/policy/github/workflow-sources/unrelated.json"
  set +e
  GH_FAKE_REPO=autumngarage/touchstone-workflows bash "$TMP/tool2/bin/touchstone" pr policy-status --project "$TMP/project" --json >"$TMP/out" 2>&1
  RUN_RC=$?
  set -e
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"policy":"policy/github/workflow-sources/touchstone-workflows.json"'
  rm "$TMP/tool2/policy/github/workflow-sources/unrelated.json"

  echo "==> pr answer is the installed name for respond-review and forwards its arguments"
  # A stand-in script records the argv it received and the directory it ran
  # in, so the dispatch is asserted by what arrives, not by usage text.
  mkdir -p "$TMP/tool/bin" "$TMP/tool/scripts" "$TMP/tool/elsewhere"
  cp "$ROOT/bin/touchstone" "$TMP/tool/bin/touchstone"
  printf '%s\n' "$(cat "$ROOT/VERSION")" >"$TMP/tool/VERSION"
  cat >"$TMP/tool/scripts/respond-review.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$PWD" >"$ANSWER_LOG.cwd"
printf '%s %s\n' "${GH_REPO-unset}" "${GIT_DIR-unset}" >"$ANSWER_LOG.ghrepo"
printf '%s\n' "$@" >"$ANSWER_LOG"
STUB
  ANSWER_LOG="$TMP/answer.argv" bash "$TMP/tool/bin/touchstone" pr answer 7 --comment-id 51 --body-file "$TMP/body" --fix-commit abc123 --project "$TMP/tool/elsewhere"
  diff -u <(printf '7\n--comment-id\n51\n--body-file\n%s\n--fix-commit\nabc123\n' "$TMP/body") "$TMP/answer.argv" >/dev/null \
    || fail "pr answer did not forward its arguments intact: $(tr '\n' ' ' <"$TMP/answer.argv")"
  [ "$(cat "$TMP/answer.argv.cwd")" = "$(cd "$TMP/tool/elsewhere" && pwd)" ] || fail "pr answer did not honour --project"
  # A relative reply file resolves against the invoking directory, not the
  # project; an exported GH_REPO cannot redirect a --project answer.
  (cd "$TMP" && printf 'reply\n' >reply.md && GH_REPO=other/repo GIT_DIR="$TMP/elsewhere.git" ANSWER_LOG="$TMP/answer2.argv" bash "$TMP/tool/bin/touchstone" pr answer 7 --comment-id 51 --body-file reply.md --project "$TMP/tool/elsewhere")
  grep -qx "$TMP/reply.md" "$TMP/answer2.argv" || fail "a relative --body-file was not resolved against the invoking directory: $(tr '\n' ' ' <"$TMP/answer2.argv")"
  [ "$(cat "$TMP/answer2.argv.ghrepo")" = "unset unset" ] || fail "GH_REPO or GIT_DIR survived into a --project answer: $(cat "$TMP/answer2.argv.ghrepo")"
  # A relative --project resolves against the invoking directory even when an
  # exported CDPATH holds a same-named directory elsewhere.
  mkdir -p "$TMP/cdtrap/elsewhere" "$TMP/invoke/elsewhere"
  (cd "$TMP/invoke" && CDPATH="$TMP/cdtrap" ANSWER_LOG="$TMP/answer4.argv" bash "$TMP/tool/bin/touchstone" pr answer 7 --comment-id 51 --body-file "$TMP/body" --project elsewhere)
  [ "$(cat "$TMP/answer4.argv.cwd")" = "$(cd "$TMP/invoke/elsewhere" && pwd)" ] || fail "a relative --project resolved through CDPATH: $(cat "$TMP/answer4.argv.cwd")"
  if ANSWER_LOG="$TMP/answer3.argv" bash "$TMP/tool/bin/touchstone" pr answer 7 --comment-id 51 --body-file "$TMP/body" --project "" >"$TMP/answer3.out" 2>&1; then
    fail "pr answer accepted an empty --project"
  fi
  grep -q "non-empty directory" "$TMP/answer3.out" || fail "empty --project was not refused clearly: $(cat "$TMP/answer3.out")"
  if bash "$ROOT/bin/touchstone" pr answer 7 --json >"$TMP/answer.json.out" 2>&1; then
    fail "pr answer accepted --json"
  fi

  echo "==> merge binds both mutation and reconciliation to the reviewed head"
  rm -f "$TMP/state/merged"
  run_pr "$TMP/out" merge 7 --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'merge requires --head SHA'
  run_pr "$TMP/out" merge 7 --head wrong --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'expected head wrong'
  GH_MODE=merge_lied run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --unguarded --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"merged"'
  assert_has "$GH_CALLS" "--match-head-commit $HEAD_SHA"
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --unguarded --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"already-merged"'
  assert_not_has "$GH_CALLS" 'pr merge'

  rm -f "$TMP/state/merged"
  GH_MODE=merge_queue run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --unguarded --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"queued"'
  GH_MODE=auto_merge run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --unguarded --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"auto-merge-enabled"'

  echo "==> an existing exact-head queue entry receives no second merge mutation"
  rm -f "$TMP/state/merged" "$TMP/calls"
  touch "$TMP/state/review-gate"
  GH_MODE=merge_queue_existing run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"queued"'
  assert_not_has "$GH_CALLS" 'pr merge'
  assert_not_has "$GH_CALLS" 'pr comment'

  echo "==> an unknown live queue state fails closed without a merge mutation"
  rm -f "$TMP/calls"
  GH_MODE=merge_queue_unknown_existing run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'unknown merge-queue state FUTURE_STATE'
  assert_has "$TMP/out" 'no merge mutation was made'
  assert_not_has "$GH_CALLS" 'pr merge'
  assert_not_has "$GH_CALLS" 'pr comment'

  echo "==> post-mutation queue reconciliation rejects an unmergeable state"
  rm -f "$TMP/calls"
  GH_MODE=merge_queue_unmergeable_after run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'unmergeable queue state'
  assert_has "$GH_CALLS" 'pr merge'
  assert_not_has "$TMP/out" '"status":"queued"'

  echo "==> merge refuses a success state observed on a moved head"
  rm -f "$TMP/state/merged"
  GH_MODE=merge_head_moved run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --unguarded --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'moved to moved-head during merge reconciliation'
  assert_not_has "$TMP/out" '"status":"merged"'

  echo "==> an unsuccessful mutation never claims a merge"
  rm -f "$TMP/state/merged"
  GH_MODE=merge_failed run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --unguarded --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'GitHub did not accept merge'
  assert_not_has "$TMP/out" '"status":"merged"'

  echo "==> merge preserves both diagnostics when reconciliation also fails"
  GH_MODE=merge_reconcile_failed run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --unguarded --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'merge rejected by rules'
  assert_has "$TMP/out" 'GraphQL unavailable'
  assert_not_has "$TMP/out" '"status":"merged"'

  if [ "$ERRORS" -gt 0 ]; then
    echo "==> FAIL: $ERRORS PR CLI assertion(s) failed" >&2
    exit 1
  fi
  echo "==> PASS: PR CLI preserves exact-head and idempotency invariants"
)

# respond-review.sh parses GitHub response data from stdout alone; diagnostics
# a successful gh call writes to stderr never become an author login, a reply
# id, or a thread id (AUT-294). With the streams merged, a debug line ahead of
# the login made the idempotency author check fail, so a rerun posted a
# duplicate reply; the same line ahead of `.id` was echoed as the reply id.
(
  RR="$TMP_DIR/respond-review"
  ERRORS=0
  mkdir -p "$RR/bin" "$RR/state"
  cat >"$RR/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Every successful call writes a diagnostic to stderr first, as gh does
# under GH_DEBUG or when warning about a deprecated flag.
echo "gh: debug detail for $*" >&2
[ "${GH_MODE:-ok}" = fail_user ] && [[ "$*" == *"api user"* ]] && {
  echo "gh: HTTP 401 bad credentials" >&2
  exit 1
}
has() { local needle="$1"; shift; for arg in "$@"; do [[ "$arg" == *"$needle"* ]] && return 0; done; return 1; }
value_after() { local wanted="$1"; shift; while [ "$#" -gt 0 ]; do if [ "$1" = "$wanted" ]; then printf '%s\n' "$2"; return 0; fi; shift; done; return 1; }
field_value() { local wanted="$1"; shift; for arg in "$@"; do case "$arg" in "$wanted"=*) printf '%s\n' "${arg#*=}"; return 0 ;; esac; done; return 1; }
case "$1 $2" in
  "repo view")
    if [ "${GH_MODE:-}" = fail_repo ]; then echo "gh: not a git repository" >&2; exit 1; fi
    echo "autumngarage/current"
    ;;
  "api user")
    echo "alice"
    ;;
  "api graphql")
    if has resolveReviewThread "$@"; then
      touch "$GH_STATE/resolved"
      echo "true"
    elif has "node(id:" "$@"; then
      echo "true"
    elif [ -f "$GH_STATE/resolved" ]; then
      # Thread lookup after resolution: by first-comment id only.
      has 'databaseId == 51' "$@" && echo "THREAD_51"
    else
      has 'databaseId == 51' "$@" && echo "THREAD_51"
      has 'isResolved == false' "$@" && printf 'THREAD_51\t51\tscripts/x.sh\n'
    fi
    ;;
  "api repos/autumngarage/current/pulls/7/comments/51/replies")
    echo 1 >>"$GH_STATE/replies"
    field_value body "$@" >"$GH_STATE/reply-body"
    echo "71"
    ;;
  "api repos/autumngarage/current/commits/abc123")
    echo "abcdef0123456789abcdef0123456789abcdef01"
    ;;
  "api repos/autumngarage/current/commits/offhead")
    echo "feedfacefeedfacefeedfacefeedfacefeedface"
    ;;
  "api repos/autumngarage/current/commits/missing")
    echo "gh: HTTP 422 no commit found" >&2
    exit 1
    ;;
  "api repos/autumngarage/current/compare/abcdef0123456789abcdef0123456789abcdef01...abcdef0123456789abcdef0123456789abcdef01")
    echo "identical"
    ;;
  "api repos/autumngarage/current/compare/feedfacefeedfacefeedfacefeedfacefeedface...abcdef0123456789abcdef0123456789abcdef01")
    echo "diverged"
    ;;
  "pr view")
    # Coordinates (head + base) before the answer; the bare head re-read
    # after it. A moved_head state makes the re-read return a later push.
    if value_after --json "$@" | grep -q baseRefName; then
      printf 'abcdef0123456789abcdef0123456789abcdef01\tmain\n'
    elif [ -f "$GH_STATE/moved-head" ]; then
      printf 'feedfacefeedfacefeedfacefeedfacefeedface\n'
    else
      printf 'abcdef0123456789abcdef0123456789abcdef01\n'
    fi
    ;;
  "api --paginate")
    if has 'actions/workflows' "$@"; then
      printf '1\n2\n3\n'
    elif [ -f "$GH_STATE/replies" ]; then
      echo "<!-- touchstone:respond-review comment=51 -->"
      [ -f "$GH_STATE/legacy-reply-only" ] \
        || echo "<!-- touchstone:review-answer v=1 id=51 disposition=no-code-change -->"
    fi
    ;;
  "api repos/autumngarage/current/rules/branches/main")
    if [ -f "$GH_STATE/review-gate" ]; then echo true; else echo false; fi
    ;;
  "api repos/autumngarage/current/actions/runs?head_sha=abcdef0123456789abcdef0123456789abcdef01&per_page=100")
    if [ -f "$GH_STATE/review-gate" ]; then
      if [ -f "$GH_STATE/gate-in-progress" ]; then
        left="$(cat "$GH_STATE/gate-in-progress")"
        if [ "$left" -le 1 ]; then rm -f "$GH_STATE/gate-in-progress"; else echo $((left - 1)) >"$GH_STATE/gate-in-progress"; fi
        gate_status=in_progress
      else
        gate_status=completed
      fi
      gate_started_at='2026-08-27T17:30:00Z'
      [ ! -f "$GH_STATE/gate-fresh-active" ] || gate_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      runs="{\"workflow_runs\":[
        {\"id\":77,\"name\":\"review-gate\",\"status\":\"$gate_status\",\"run_attempt\":2,\"run_started_at\":\"$gate_started_at\",\"workflow_id\":999,\"pull_requests\":[{\"number\":7}]},
        {\"id\":78,\"name\":\"review-gate\",\"status\":\"completed\",\"run_attempt\":1,\"run_started_at\":\"2026-08-27T17:20:00Z\",\"workflow_id\":2,\"pull_requests\":[{\"number\":7}]}]}"
      if [ "${GH_MODE:-ok}" = run_recency ] || [ "${GH_MODE:-ok}" = run_recency_later_page ]; then
        runs="$(printf '%s' "$runs" | jq -c '.workflow_runs += [{id:88,name:"review-gate",status:"completed",run_attempt:1,run_started_at:"2026-08-27T17:20:00Z",workflow_id:999,pull_requests:[{number:7}]}]')"
      elif [ "${GH_MODE:-ok}" = run_recency_tie ]; then
        runs="$(printf '%s' "$runs" | jq -c '.workflow_runs += [{id:88,name:"review-gate",status:"completed",run_attempt:1,run_started_at:"2026-08-27T17:30:00Z",workflow_id:999,pull_requests:[{number:7}]}]')"
      elif [ "${GH_MODE:-ok}" = malformed_run_recency ]; then
        runs="$(printf '%s' "$runs" | jq -c '(.workflow_runs[] | select(.id == 77)) |= del(.run_started_at)')"
      fi
    else
      runs='{"workflow_runs":[]}'
    fi
    if [ "${GH_MODE:-ok}" = run_recency_later_page ]; then
      printf '%s\n' "$runs" | jq -c '{workflow_runs:[.workflow_runs[] | select(.id != 77)]}'
      printf '%s\n' "$runs" | jq -c '{workflow_runs:[.workflow_runs[] | select(.id == 77)]}'
    else
      printf '%s\n' "$runs"
    fi
    ;;
  "api -X")
    # POST .../actions/runs/77/rerun
    has 'actions/runs/77/rerun' "$@" && echo "rerun 77" >>"$GH_STATE/gate-reruns"
    has 'actions/runs/88/rerun' "$@" && echo "rerun 88" >>"$GH_STATE/gate-reruns"
    ;;
  *) exit 1 ;;
esac
exit 0
STUB
  chmod +x "$RR/bin/gh"
  export PATH="$RR/bin:$PATH" GH_STATE="$RR/state"

  mkdir -p "$RR/tool-v1/scripts"
  cp "$TOUCHSTONE_ROOT/scripts/respond-review.sh" "$RR/tool-v1/scripts/respond-review.sh"
  cat >"$RR/tool-v1/scripts/touchstone-pr.sh" <<'STATUS_STUB'
#!/usr/bin/env bash
set -euo pipefail
version=null
[ ! -f "$GH_STATE/status-fails" ] || exit 1
[ ! -f "$GH_STATE/effective-behavior-v2" ] || version=2
gate_check='{"present":true,"workflowRunId":77}'
[ ! -f "$GH_STATE/status-run-unbound" ] || gate_check='{"present":false,"unbound":true,"workflowRunId":77}'
printf '{"schema":"touchstone.pr/v1","operation":"status","reviewGateBehaviorContractVersion":%s,"reviewGateCheck":%s}\n' "$version" "$gate_check"
STATUS_STUB

  printf 'Fixed.\n' >"$RR/body"
  run() {
    set +e
    bash "$RR/tool-v1/scripts/respond-review.sh" "$@" >"$RR/out" 2>&1
    RUN_RC=$?
    set -e
  }
  mkdir -p "$RR/tool-v2/scripts"
  cp "$TOUCHSTONE_ROOT/scripts/respond-review.sh" "$RR/tool-v2/scripts/respond-review.sh"
  cp "$RR/tool-v1/scripts/touchstone-pr.sh" "$RR/tool-v2/scripts/touchstone-pr.sh"
  run_v2() {
    touch "$GH_STATE/effective-behavior-v2"
    set +e
    bash "$RR/tool-v2/scripts/respond-review.sh" "$@" >"$RR/out" 2>&1
    RUN_RC=$?
    set -e
  }

  echo "==> --fix-commit is verified against the captured PR head before mutation"
  run 7 --comment-id 51 --body-file "$RR/body" --fix-commit missing
  [ "$RUN_RC" -ne 0 ] && grep -qF "does not resolve to a commit" "$RR/out" \
    && [ ! -e "$GH_STATE/replies" ] && [ ! -e "$GH_STATE/resolved" ] \
    && ok "nonexistent fix commit refused before reply or resolution" \
    || fail "nonexistent fix commit mutated or lacked a useful refusal (rc=$RUN_RC): $(tail -3 "$RR/out")"

  run 7 --comment-id 51 --body-file "$RR/body" --fix-commit offhead
  [ "$RUN_RC" -ne 0 ] && grep -qF "is not reachable from PR #7 head" "$RR/out" \
    && [ ! -e "$GH_STATE/replies" ] && [ ! -e "$GH_STATE/resolved" ] \
    && ok "off-head fix commit refused before reply or resolution" \
    || fail "off-head fix commit mutated or lacked a useful refusal (rc=$RUN_RC): $(tail -3 "$RR/out")"

  run 7 --comment-id 51 --body-file "$RR/body" --fix-commit abc123
  [ "$RUN_RC" -eq 0 ] \
    && grep -qF 'Fixed in abcdef0123456789abcdef0123456789abcdef01.' "$GH_STATE/reply-body" \
    && ok "reachable short fix revision normalized to its canonical SHA" \
    || fail "reachable short fix revision was not normalized (rc=$RUN_RC): $(cat "$RR/out")"
  rm -f "$GH_STATE/replies" "$GH_STATE/reply-body" "$GH_STATE/resolved"

  echo "==> a reply is posted once and the id is parsed from stdout alone"
  run 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || {
    fail "first run exited $RUN_RC"
    cat "$RR/out"
  }
  grep -qF 'reply id: 71' "$RR/out" && ok "reply id carries no diagnostic text" \
    || fail "reply id was not parsed from stdout alone: $(grep 'reply id' "$RR/out")"
  [ -f "$GH_STATE/resolved" ] && ok "thread resolved" || fail "thread was not resolved"
  # The merge hint names the head this answer was bound to. A hint that
  # resolves the head live (`$(gh pr view … headRefOid)`) would accept a
  # commit pushed after the answer, unreviewed.
  if grep -qF 'pr merge 7 --head abcdef0123456789abcdef0123456789abcdef01' "$RR/out" && ! grep -qF '$(gh pr view' "$RR/out"; then
    ok "merge hint carries the captured head, not a live read"
  else
    fail "merge hint does not bind the captured head: $(grep 'pr merge' "$RR/out")"
  fi

  echo "==> a head that moves while answering is refused before any hint or gate re-run"
  touch "$GH_STATE/moved-head"
  run 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -ne 0 ] && grep -qF 'PR head moved from abcdef0123456789abcdef0123456789abcdef01 to feedface' "$RR/out" \
    && ok "moved head refused with both SHAs named" \
    || fail "moved head was not refused (rc=$RUN_RC): $(tail -2 "$RR/out")"
  grep -qF 'pr merge 7 --head' "$RR/out" && fail "merge hint printed for a moved head" || true
  rm -f "$GH_STATE/moved-head"

  echo "==> a rerun recognises its own reply despite stderr noise on the login read"
  run 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "rerun exited $RUN_RC"
  replies="$(wc -l <"$GH_STATE/replies" | tr -d ' ')"
  [ "$replies" -eq 1 ] && ok "no duplicate reply posted" \
    || fail "rerun posted a duplicate reply (replies=$replies): author check read stderr"
  grep -qF 'matched our own reply as @alice' "$RR/out" && ok "author parsed as alice" \
    || fail "author was not parsed cleanly: $(grep 'matched' "$RR/out")"

  echo "==> an answer must record exactly one disposition (AUT-800)"
  # Vesper PR #1047 resolved a finding with prose alone. Refusal comes before
  # any read of the PR, so nothing is replied to, resolved, or re-run.
  rm -f "$GH_STATE/replies" "$GH_STATE/reply-body" "$GH_STATE/resolved" "$GH_STATE/gate-reruns"
  run 7 --comment-id 51 --body-file "$RR/body"
  [ "$RUN_RC" -eq 2 ] && grep -qF 'an answer must record its disposition' "$RR/out" \
    && [ ! -e "$GH_STATE/replies" ] && [ ! -e "$GH_STATE/resolved" ] \
    && ok "an answer without a disposition is invalid input, refused before any mutation" \
    || fail "an answer without a disposition mutated the PR or misreported (rc=$RUN_RC): $(tail -2 "$RR/out")"
  run 7 --comment-id 51 --body-file "$RR/body" --fix-commit abc123 --no-code-change
  [ "$RUN_RC" -eq 2 ] && grep -qF 'pass exactly one' "$RR/out" \
    && [ ! -e "$GH_STATE/replies" ] && [ ! -e "$GH_STATE/resolved" ] \
    && ok "two dispositions are invalid input, refused before any mutation" \
    || fail "two dispositions were accepted or misreported (rc=$RUN_RC): $(tail -2 "$RR/out")"
  run 7 --all-resolved-check --no-code-change
  [ "$RUN_RC" -eq 2 ] && grep -qF 'takes no disposition' "$RR/out" \
    && ok "the read-only check refuses a disposition as invalid input" \
    || fail "--all-resolved-check accepted a disposition (rc=$RUN_RC): $(tail -2 "$RR/out")"
  # Invalid input precedes every transport: with no repository resolvable at
  # all, a missing disposition still reads as a missing disposition.
  GH_MODE=fail_repo run 7 --comment-id 51 --body-file "$RR/body"
  [ "$RUN_RC" -eq 2 ] && grep -qF 'an answer must record its disposition' "$RR/out" \
    && ok "the disposition is validated before the repository is resolved" \
    || fail "a missing disposition reported a transport failure (rc=$RUN_RC): $(tail -2 "$RR/out")"

  echo "==> the recorded disposition is what the gate reads, never the prose"
  rm -f "$GH_STATE/replies" "$GH_STATE/reply-body" "$GH_STATE/resolved"
  run 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] \
    && grep -qF '<!-- touchstone:review-answer v=1 id=51 disposition=no-code-change -->' "$GH_STATE/reply-body" \
    && ! grep -qF 'disposition=fixed' "$GH_STATE/reply-body" \
    && ok "a no-code-change answer records that disposition and invents no commit" \
    || fail "no-code-change did not record its disposition: $(cat "$GH_STATE/reply-body")"
  rm -f "$GH_STATE/replies" "$GH_STATE/reply-body" "$GH_STATE/resolved"
  run 7 --comment-id 51 --body-file "$RR/body" --fix-commit abc123
  [ "$RUN_RC" -eq 0 ] \
    && grep -qF '<!-- touchstone:review-answer v=1 id=51 disposition=fixed fix=abcdef0123456789abcdef0123456789abcdef01 -->' "$GH_STATE/reply-body" \
    && ok "a fixed answer records the canonical SHA GitHub resolved" \
    || fail "fixed disposition did not record the canonical SHA: $(cat "$GH_STATE/reply-body")"

  echo "==> an answer written before dispositions existed is re-recorded, not skipped"
  # Backward compatibility for an already-open PR: the legacy reply is ours and
  # carries the old marker, so the idempotency check must not read it as this
  # answer -- otherwise the finding could never gain the disposition its gate
  # now requires.
  rm -f "$GH_STATE/reply-body" "$GH_STATE/resolved"
  touch "$GH_STATE/legacy-reply-only"
  run 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] \
    && grep -qF 'disposition=no-code-change' "$GH_STATE/reply-body" \
    && ok "a legacy answer is re-recorded with its disposition" \
    || fail "a legacy answer was treated as already disposed (rc=$RUN_RC): $(tail -2 "$RR/out")"
  rm -f "$GH_STATE/legacy-reply-only" "$GH_STATE/replies" "$GH_STATE/reply-body" "$GH_STATE/resolved"

  echo "==> an answer re-runs the pinned review gate where the repository has one"
  touch "$GH_STATE/review-gate"
  rm -f "$GH_STATE/gate-reruns"
  run 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "answer with a review gate exited $RUN_RC"
  grep -q 'rerun 77' "$GH_STATE/gate-reruns" 2>/dev/null && ok "answer re-ran the review gate" \
    || fail "answer did not re-run the review gate"
  rm -f "$GH_STATE/gate-reruns"
  GH_MODE=run_recency run 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "answer rejected valid workflow-run recency data (rc=$RUN_RC)"
  grep -q 'rerun 77' "$GH_STATE/gate-reruns" 2>/dev/null \
    && ! grep -q 'rerun 88' "$GH_STATE/gate-reruns" 2>/dev/null \
    && ok "answer selected the lower-id workflow run rerun most recently" \
    || fail "answer selected the wrong workflow run by creation id"
  rm -f "$GH_STATE/gate-reruns"
  GH_MODE=run_recency_later_page run 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] && grep -q 'rerun 77' "$GH_STATE/gate-reruns" 2>/dev/null \
    && ! grep -q 'rerun 88' "$GH_STATE/gate-reruns" 2>/dev/null \
    && ok "answer ranked workflow execution recency across every API page" \
    || fail "answer ignored a later workflow-run page"
  rm -f "$GH_STATE/gate-reruns"
  GH_MODE=run_recency_tie run 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -ne 0 ] && grep -q 'malformed or ambiguous review-gate run data' "$RR/out" \
    && [ ! -e "$GH_STATE/gate-reruns" ] \
    && ok "answer failed closed on tied workflow execution timestamps" \
    || fail "answer broke an execution-time tie by creation id (rc=$RUN_RC)"
  rm -f "$GH_STATE/gate-reruns"
  GH_MODE=malformed_run_recency run 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -ne 0 ] && grep -q 'malformed or ambiguous review-gate run data' "$RR/out" \
    && [ ! -e "$GH_STATE/gate-reruns" ] \
    && ok "answer failed closed on a workflow run without execution recency" \
    || fail "answer accepted malformed workflow-run recency data (rc=$RUN_RC)"
  rm -f "$GH_STATE/gate-reruns"
  # The run stays in progress for longer than the GraphQL transport retry
  # would tolerate; the gate wait has its own budget.
  echo 6 >"$GH_STATE/gate-in-progress"
  TOUCHSTONE_GATE_RETRY_DELAY=0 run 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "answer gave up on a gate run that was still in progress (rc=$RUN_RC)"
  grep -q 'rerun 77' "$GH_STATE/gate-reruns" 2>/dev/null && ok "answer waited for an in-progress gate run" \
    || fail "answer skipped the refresh while the gate run was in progress"
  rm -f "$GH_STATE/gate-reruns"
  touch "$GH_STATE/gate-fresh-active"
  echo 30 >"$GH_STATE/gate-in-progress"
  run_v2 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "behavior v2 answer failed while its gate was active (rc=$RUN_RC)"
  grep -qF 'Review gate run 77 is already evaluating this head; returning control' "$RR/out" \
    && ok "behavior v2 answer returned control to the agent" \
    || fail "behavior v2 answer did not report its active authoritative run"
  [ ! -f "$GH_STATE/gate-reruns" ] \
    || fail "behavior v2 answer re-ran an evaluation that was already active"
  [ "$(cat "$GH_STATE/gate-in-progress")" = 29 ] \
    || fail "behavior v2 answer polled an active evaluation instead of returning control"
  rm -f "$GH_STATE/gate-in-progress" "$GH_STATE/gate-reruns" "$GH_STATE/gate-fresh-active"
  touch "$GH_STATE/gate-fresh-active" "$GH_STATE/status-run-unbound"
  echo 3 >"$GH_STATE/gate-in-progress"
  run_v2 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "behavior v2 answer failed to refresh an unbound gate (rc=$RUN_RC)"
  grep -q 'rerun 77' "$GH_STATE/gate-reruns" 2>/dev/null \
    || fail "behavior v2 answer reused an active run from an unbound source revision"
  grep -q 'no verified policy-bound review-gate run' "$RR/out" \
    || fail "behavior v2 answer did not explain its conservative unbound-run refresh"
  rm -f "$GH_STATE/gate-in-progress" "$GH_STATE/gate-reruns" "$GH_STATE/gate-fresh-active" "$GH_STATE/status-run-unbound"
  run_v2 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "behavior v2 answer failed to refresh a completed gate (rc=$RUN_RC)"
  grep -q 'rerun 77' "$GH_STATE/gate-reruns" 2>/dev/null \
    && ok "behavior v2 answer refreshed a completed evaluation" \
    || fail "behavior v2 answer skipped a completed evaluation"
  rm -f "$GH_STATE/gate-reruns"
  echo 3 >"$GH_STATE/gate-in-progress"
  run_v2 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "behavior v2 answer failed to recover an expired active gate (rc=$RUN_RC)"
  grep -q 'rerun 77' "$GH_STATE/gate-reruns" 2>/dev/null \
    || fail "behavior v2 answer reused a run whose review-evidence window had expired"
  rm -f "$GH_STATE/gate-in-progress" "$GH_STATE/gate-reruns"
  touch "$GH_STATE/status-fails"
  run_v2 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "answer failed instead of falling back when full status needed unavailable admin access (rc=$RUN_RC)"
  grep -q 'rerun 77' "$GH_STATE/gate-reruns" 2>/dev/null \
    || fail "answer did not conservatively refresh after behavior verification failed"
  grep -q 'conservatively refreshing the gate' "$RR/out" \
    || fail "answer silently hid its behavior-v1 fallback"
  rm -f "$GH_STATE/status-fails" "$GH_STATE/gate-reruns"
  rm -f "$GH_STATE/effective-behavior-v2"
  rm -f "$GH_STATE/review-gate"

  echo "==> --all-resolved-check reads the thread list from stdout alone"
  run 7 --all-resolved-check
  [ "$RUN_RC" -eq 0 ] && ok "resolved PR passes the check" || {
    fail "all-resolved-check exited $RUN_RC"
    cat "$RR/out"
  }

  echo "==> a failed read still surfaces its diagnostics"
  GH_MODE=fail_user run 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 1 ] || fail "failed login read exited $RUN_RC, expected 1"
  grep -qF 'bad credentials' "$RR/out" && ok "failure keeps the stderr detail" \
    || fail "failure diagnostic was dropped"

  echo "==> no production script captures a gh response with stderr merged in"
  # The guardrail for the class: a $(gh ... 2>&1) capture parses diagnostics
  # as data. Successful reads take stdout alone; failure detail is gathered
  # separately (gh_read here, capture_command in touchstone-pr.sh). POSIX
  # classes only, and the pattern must first match a known sample so a grep
  # that does not understand it cannot make the guard silently pass.
  merged_pattern='\$\([[:space:]]*gh[[:space:]][^)]*2>&1'
  if printf '%s\n' 'value="$(gh api user 2>&1)"' | grep -qE "$merged_pattern"; then
    merged="$(grep -nE "$merged_pattern" "$TOUCHSTONE_ROOT"/scripts/*.sh "$TOUCHSTONE_ROOT"/bin/* || true)"
    [ -z "$merged" ] && ok "no merged-stream gh capture in scripts/ or bin/" \
      || fail "merged-stream gh capture found:
  $merged"
  else
    fail "the merged-stream guard pattern does not match its own positive sample"
  fi

  echo "==> workflow-run mutation selectors never rank by creation id alone"
  creation_id_selector='sort_by(.id) | last | "\(.id'
  stale_selectors="$(grep -nF "$creation_id_selector" "$TOUCHSTONE_ROOT"/scripts/*.sh || true)"
  [ -z "$stale_selectors" ] && ok "no creation-id-only workflow-run selector remains" \
    || fail "creation-id-only workflow-run selector found:
  $stale_selectors"

  if [ "$ERRORS" -gt 0 ]; then
    echo "==> FAIL: $ERRORS respond-review assertion(s) failed" >&2
    exit 1
  fi
  echo "==> PASS: respond-review parses GitHub responses from stdout alone"
)
