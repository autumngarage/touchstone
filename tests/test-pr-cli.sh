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
# The fixture's own reads of its pages (GH_UNLOGGED) are not the command's.
[ -n "${GH_UNLOGGED:-}" ] || printf '%s\n' "$*" >>"$GH_CALLS"
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
    [ ! -f "$GH_STATE/consumer-status" ] || status_rule=',{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"convoy/delivery-protocol"},{"context":"powershell-tests"}]}}'
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

# When the head's review request was posted: old unless a case says
# otherwise, so the contract-4 evidence deadline has passed by default.
fake_request_at() {
  if [ -f "$GH_STATE/request-at" ]; then cat "$GH_STATE/request-at"; else printf '2026-08-27T17:00:00Z\n'; fi
}

# A fixture item that stays hidden for the number of reads its counter file
# holds, then appears: a reply that lands while the client is waiting.
fake_after_reads() {
  local counter="$GH_STATE/$1" left
  [ -f "$counter" ] || return 0
  left="$(cat "$counter")"
  [ "$left" -gt 0 ] || return 0
  echo $((left - 1)) >"$counter"
  return 1
}

# The contract-4 wait's poll clock. Every poll re-reads liveness first, so a
# primary reply that lands N polls into the wait is one that becomes visible
# once N liveness reads were made while a review request exists. It counts
# polls, not which endpoints a poll reads, so the same fixture measures any
# implementation of the wait (AUT-1638).
fake_tick() {
  local counter="$GH_STATE/$1" left
  [ -f "$counter" ] || return 0
  left="$(cat "$counter")"
  [ "$left" -le 0 ] || echo $((left - 1)) >"$counter"
}
fake_visible() { [ ! -f "$GH_STATE/$1" ] || [ "$(cat "$GH_STATE/$1")" -le 0 ]; }

fake_comments='[]'
# id, login, created_at, body, and optionally an updated_at after creation.
fake_add_comment() {
  fake_comments="$(printf '%s' "$fake_comments" | jq -c --argjson id "$1" --arg login "$2" --arg at "$3" --arg body "$4" --arg updated "${5:-$3}" \
    '. + [{id:$id, user:{login:$login}, created_at:$at, updated_at:$updated, body:$body}]')"
}
# A request edited after it was posted keeps its creation time and moves its
# update time (AUT-1636).
fake_request_edited_at() {
  if [ -f "$GH_STATE/request-edited-at" ]; then cat "$GH_STATE/request-edited-at"; else fake_request_at; fi
}
# A reply the given number of seconds after the request was posted.
fake_after_request() { jq -nr --arg at "$(fake_request_at)" --argjson seconds "$1" '($at | fromdateiso8601) + $seconds | todate'; }


# GitHub refusing a request for the token's rate limit, as gh relays it
# (AUT-1638): a REST refusal prints GitHub's message with its HTTP status on
# stderr and the JSON body on stdout; a GraphQL one prints the message alone.
if [ -n "${GH_RATE_LIMITED:-}" ] && has "$GH_RATE_LIMITED" "$@"; then
  case "${GH_RATE_LIMIT_KIND:-core}" in
    secondary) message='You have exceeded a secondary rate limit. Please wait a few minutes before you try again. If you reach out to GitHub Support for help, please include the request ID 0400:1B2C:3D4E.' ;;
    graphql)
      printf 'GraphQL: API rate limit exceeded for user ID 1. (RATE_LIMITED)\n' >&2
      exit 1
      ;;
    *) message='API rate limit exceeded for user ID 1. If you reach out to GitHub Support for help, please include the request ID 0400:1B2C:3D4E.' ;;
  esac
  jq -cn --arg message "$message" '{message:$message, documentation_url:"https://docs.github.com/rest/using-the-rest-api/rate-limits-for-the-rest-api", status:"403"}'
  printf 'gh: %s (HTTP 403)\n' "$message" >&2
  exit 1
fi

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
    if has 'touchstone:review-fallback' "$@"; then
      if [ -f "$GH_STATE/fallback-comment-fails" ]; then
        printf 'gh: Server Error (HTTP 502)\n' >&2
        exit 1
      fi
      touch "$GH_STATE/fallback-announced"
      printf '%s\n' https://example.test/pr/7#issuecomment-3
      exit 0
    fi
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
    elif has '--json state,headRefOid,baseRefName,baseRefOid' "$@"; then
      # The liveness precondition every GitHub-state wait re-reads each poll.
      # Read while a review request exists, it is a poll of the contract-4
      # wait: a primary reply landing N polls in appears on the Nth.
      if [ -f "$GH_STATE/review-request" ] || [ "${GH_MODE:-ok}" = attest_request_present ]; then
        fake_tick primary-comment-delay
        fake_tick primary-review-delay
      fi
      live_state=OPEN
      live_head="$GH_HEAD"
      live_base="$GH_BASE_REF"
      live_base_sha="$GH_BASE_SHA"
      [ ! -f "$GH_STATE/merged" ] || live_state=MERGED
      case "${GH_MODE:-ok}" in
        status_closed) live_state=CLOSED ;;
        status_merged) live_state=MERGED ;;
        moved_during_gate) live_head=moved-head ;;
      esac
      [ ! -f "$GH_STATE/wait-closed" ] || live_state=CLOSED
      [ ! -f "$GH_STATE/wait-moved" ] || live_head=moved-head
      [ ! -f "$GH_STATE/wait-retargeted" ] || live_base=release
      [ ! -f "$GH_STATE/wait-base-advanced" ] || live_base_sha=advanced-base-sha
      printf '%s\t%s\t%s\t%s\n' "$live_state" "$live_head" "$live_base" "$live_base_sha"
    elif has '--json state,url' "$@"; then
      if [ -f "$GH_STATE/merged" ]; then printf 'MERGED\thttps://example.test/pr/7\n'; else printf 'OPEN\thttps://example.test/pr/7\n'; fi
    elif has '--json id --jq' "$@"; then
      # The node id the enqueue mutation addresses.
      printf 'PR_kwDOfixture7\n'
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
      # A head that moves after the number of full reads its counter holds:
      # a push landing between merge's first read and its enqueue decision.
      row_head="$GH_HEAD"
      if [ -f "$GH_STATE/head-moves-after-reads" ] && fake_after_reads head-moves-after-reads; then row_head=moved-head; fi
      printf '7\t%s\thttps://example.test/pr/7\t%s\t%s\tmain\t%s\t%s\t%s\n' \
        "$pr_state" "$row_head" "$head_repo" "${GH_BASE_SHA:-base-sha}" "$merge_state" "$draft"
    fi
    ;;
  "pr merge")
    # Disarming an armed request is its own mutation, recorded in GH_CALLS
    # like every other; it never merges.
    if has '--disable-auto' "$@"; then
      if [ -f "$GH_STATE/disarm-fails" ]; then printf 'auto-merge could not be disabled\n' >&2; exit 1; fi
      rm -f "$GH_STATE/auto-merge-armed"
      exit 0
    fi
    # Under a merge queue `gh pr merge` arms auto-merge and returns; GitHub
    # admits the head later, or -- AUT-1224 -- never does.
    if [ -f "$GH_STATE/arm-on-merge" ]; then
      touch "$GH_STATE/auto-merge-armed"
      exit 0
    fi
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
    # The review surface's counts (AUT-1638), taken from the very pages the
    # REST reads serve, so the two can never disagree.
    if has 'comments{totalCount}' "$@"; then
      # A poll whose own reads outlast the time left before the deadline: the
      # real /bin/sleep, never the stub the caller may have on PATH.
      [ -z "${GH_SLOW_SURFACE_SECONDS:-}" ] || /bin/sleep "$GH_SLOW_SURFACE_SECONDS"
      comment_count="$(GH_UNLOGGED=1 "$0" api --paginate "repos/fixture/issues/7/comments?per_page=100" | jq -s 'add | length')"
      review_count="$(GH_UNLOGGED=1 "$0" api --paginate "repos/fixture/pulls/7/reviews?per_page=100" | jq -s 'add | length')"
      printf '%s %s\n' "$comment_count" "$review_count"
      exit 0
    fi
    # When the PR body last changed (AUT-1632). By default the last edit is
    # after run 80 started, so run 80 is stale and a reused PR re-runs it.
    if has 'lastEditedAt' "$@"; then
      if [ -f "$GH_STATE/body-timing-unavailable" ]; then
        printf 'GraphQL unavailable\n' >&2
        exit 1
      fi
      printf '{"createdAt":"%s","lastEditedAt":%s}\n' "${GH_PR_CREATED_AT:-2026-08-26T20:00:00Z}" "${GH_PR_LAST_EDITED_AT_JSON:-\"2026-08-27T17:00:00Z\"}"
      exit 0
    fi
    # The enqueue mutation: admitted unless a case says GitHub refuses it.
    if has 'enqueuePullRequest' "$@"; then
      if [ -f "$GH_STATE/enqueue-fails" ]; then
        printf 'GraphQL: Pull request is in unstable status (enqueuePullRequest)\n' >&2
        exit 1
      fi
      touch "$GH_STATE/queued"
      printf '%s\n' '{"data":{"enqueuePullRequest":{"mergeQueueEntry":{"state":"QUEUED"}}}}'
      exit 0
    fi
    if has 'reviewThreads(first:100){nodes{isResolved}}' "$@"; then
      if [ "${GH_MODE:-ok}" = status_auto_merge_threads ]; then printf '2\n'; else printf '0\n'; fi
      exit 0
    fi
    if has 'autoMergeEnabledAt' "$@"; then
      if [ "${GH_MODE:-ok}" = status_observation_failure ]; then
        printf 'GraphQL unavailable\n' >&2
        exit 1
      fi
      observed_head="$GH_HEAD"
      [ "${GH_MODE:-ok}" != status_head_moved ] || observed_head=moved-head
      auto_merge_enabled_at=null
      case "${GH_MODE:-ok}" in status_auto_merge | status_auto_merge_blocked | status_auto_merge_threads) auto_merge_enabled_at='"2026-08-24T20:00:00Z"' ;; esac
      # An armed request that outlived a queue eviction (vesper#1171).
      [ ! -f "$GH_STATE/auto-merge-armed" ] || auto_merge_enabled_at='"2026-09-05T02:38:11Z"'
      queue_state=null
      case "${GH_MODE:-ok}" in
        status_gate_queued) queue_state='"AWAITING_CHECKS"' ;;
        status_gate_queue_unmergeable) queue_state='"UNMERGEABLE"' ;;
        status_gate_queue_unknown) queue_state='"FUTURE_STATE"' ;;
        merge_queue_existing) queue_state='"AWAITING_CHECKS"' ;;
        merge_queue_unknown_existing) queue_state='"FUTURE_STATE"' ;;
      esac
      # Admitted by this command's own enqueue mutation.
      [ ! -f "$GH_STATE/queued" ] || queue_state='"QUEUED"'
      queue_position=null
      [ "$queue_state" = null ] || queue_position=1
      queue_events='[]'
      # Eviction history: the newest queue event is a removal bound to the
      # live head (touchstone#1092) -- or to an older head, which is history
      # for a head that has since moved and must not read as evicted.
      # Shapes taken from a live read of vesper#1136 on 2026-09-02: the
      # removal's reason is GitHub's enum value and its beforeCommit is the
      # merge-queue base, not the PR head.
      if [ -f "$GH_STATE/queue-evicted" ]; then
        queue_events='[{"type":"head_moved","createdAt":"2026-09-02T16:00:55Z","reason":null,"queueBase":null},{"type":"added","createdAt":"2026-09-02T16:13:23Z","reason":null,"queueBase":null},{"type":"removed","createdAt":"2026-09-02T16:51:33Z","reason":"failed_checks","queueBase":"dd69484b30f6"}]'
      elif [ -f "$GH_STATE/queue-evicted-then-pushed" ]; then
        queue_events='[{"type":"added","createdAt":"2026-09-02T16:13:23Z","reason":null,"queueBase":null},{"type":"removed","createdAt":"2026-09-02T16:51:33Z","reason":"failed_checks","queueBase":"dd69484b30f6"},{"type":"head_moved","createdAt":"2026-09-02T17:00:00Z","reason":null,"queueBase":null}]'
      elif [ -f "$GH_STATE/queue-evicted-then-retargeted" ]; then
        queue_events='[{"type":"added","createdAt":"2026-09-02T16:13:23Z","reason":null,"queueBase":null},{"type":"removed","createdAt":"2026-09-02T16:51:33Z","reason":"failed_checks","queueBase":"dd69484b30f6"},{"type":"base_changed","createdAt":"2026-09-02T17:00:00Z","reason":null,"queueBase":null}]'
      elif [ -f "$GH_STATE/queue-requeued" ]; then
        queue_events='[{"type":"removed","createdAt":"2026-09-02T16:51:33Z","reason":"failed_checks","queueBase":"dd69484b30f6"},{"type":"added","createdAt":"2026-09-02T17:08:34Z","reason":null,"queueBase":null}]'
      fi
      printf '{"head":"%s","autoMergeEnabledAt":%s,"mergeQueueState":%s,"mergeQueuePosition":%s,"mergeQueueEnqueuedAt":null,"queueEvents":%s}\n' \
        "$observed_head" "$auto_merge_enabled_at" "$queue_state" "$queue_position" "$queue_events"
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
      elif [ -f "$GH_STATE/queued" ]; then
        printf 'OPEN\thttps://example.test/pr/7\t%s\ttrue\tQUEUED\n' "$GH_HEAD"
      elif [ -f "$GH_STATE/auto-merge-armed" ]; then
        printf 'OPEN\thttps://example.test/pr/7\t%s\ttrue\t\n' "$GH_HEAD"
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
        80 | 84) source_path=".github/workflows/delivery-evidence.yml" ;;
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
      # gate-job-refused: only the gate's job is refused, whatever the mode.
      gate_jobs_mode="${GH_MODE:-ok}"
      [ ! -f "$GH_STATE/gate-job-refused" ] || gate_jobs_mode=actions_refused
      case "$gate_jobs_mode" in
        status_gate_pending | status_gate_run_recency)
          printf '%s\n' '{"jobs":[{"id":81,"name":"review-gate","run_attempt":2,"status":"in_progress","conclusion":null}]}' ;;
        status_gate_failure | status_gate_collision)
          printf '%s\n' '{"jobs":[{"id":82,"name":"review-gate","run_attempt":2,"status":"completed","conclusion":"failure"}]}' ;;
        status_gate_cancelled)
          printf '%s\n' '{"jobs":[{"id":82,"name":"review-gate","run_attempt":2,"status":"completed","conclusion":"cancelled"}]}' ;;
        status_gate_workflow_cancelled | status_gate_workflow_failure)
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
        status_gate_refused | actions_refused)
          # The review-gate job GitHub refused on hesperus#354 (run
          # 34491554934): failed, never started, so no steps at all.
          printf '%s\n' '{"total_count":1,"jobs":[{"id":102919303302,"run_id":77,"workflow_name":"review-gate","name":"review-gate","run_attempt":2,"status":"completed","conclusion":"failure","steps":[],"check_run_url":"https://api.github.com/repos/autumngarage/current/check-runs/102919303302","labels":["ubuntu-latest"],"runner_id":0,"runner_name":""}]}' ;;
        *) printf '%s\n' '{"jobs":[{"id":84,"name":"review-gate","run_attempt":2,"status":"completed","conclusion":"success"}]}' ;;
      esac
    elif has '/actions/runs/80/attempts/2/jobs?per_page=100' "$@"; then
      # A real evidence verdict ran its steps before failing; the job GitHub
      # refused on hesperus#354 (run 34491554998) ran none (AUT-1594).
      if [ "${GH_MODE:-ok}" = actions_refused ]; then
        printf '%s\n' '{"total_count":1,"jobs":[{"id":102919303957,"run_id":80,"workflow_name":"delivery-evidence","name":"delivery-evidence","run_attempt":2,"status":"completed","conclusion":"failure","steps":[],"check_run_url":"https://api.github.com/repos/autumngarage/current/check-runs/102919303957","labels":["ubuntu-latest"],"runner_id":0,"runner_name":""}]}'
      else
        printf '%s\n' '{"total_count":1,"jobs":[{"id":102919300001,"run_id":80,"name":"delivery-evidence","run_attempt":2,"status":"completed","conclusion":"failure","steps":[{"name":"Set up job","status":"completed","conclusion":"success","number":1},{"name":"Check delivery evidence","status":"completed","conclusion":"failure","number":2}]}]}'
      fi
    elif has '/actions/runs/90/attempts/1/jobs?per_page=100' "$@"; then
      # The validate job Actions refused (validate-refused): no steps.
      printf '%s\n' '{"total_count":1,"jobs":[{"id":102919304400,"run_id":90,"workflow_name":"validate","name":"validate","run_attempt":1,"status":"completed","conclusion":"failure","steps":[],"labels":["ubuntu-latest"],"runner_id":0,"runner_name":""}]}'
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
        status_gate_workflow_cancelled | status_gate_workflow_failure)
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
        status_gate_refused)
          # A refused job's CheckRun as GitHub serves it: no title, no
          # summary, one annotation carrying the cause.
          jq -cn --arg head "$GH_HEAD" '{check_runs:[{id:102919303302,name:"review-gate",head_sha:$head,check_suite:{id:900},status:"completed",conclusion:"failure",completed_at:"2026-09-10T14:49:08Z",details_url:"https://example.test/runs/102919303302",output:{title:null,summary:null,text:null,annotations_count:1}}]}'
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
    elif has '.[] | @base64' "$@"; then
      :
    elif has '/issues/7/comments' "$@" && ! has --jq "$@"; then
      # The raw comment pages the contract-4 wait reads: every review request
      # for this head, the primary reviewer's replies and its status
      # dashboard, and this tool's fallback notice.
      request_at="$(fake_request_at)"
      # The primary replies a minute after the request, as it does.
      reply_at="$(fake_after_request 60)"
      primary='chatgpt-codex-connector[bot]'
      if [ -f "$GH_STATE/review-request" ]; then
        read -r saved_head saved_base saved_base_sha <"$GH_STATE/review-request"
        fake_add_comment 1 alice "$request_at" "@codex review

<!-- touchstone:pr-open head=$saved_head base=$saved_base base_sha=$saved_base_sha -->" "$(fake_request_edited_at)"
      fi
      if [ "${GH_MODE:-ok}" = attest_request_present ]; then
        fake_add_comment 91 alice "$request_at" "@codex review

<!-- touchstone:attest-request head=$GH_HEAD -->" "$(fake_request_edited_at)"
      fi
      # The dashboard is created after the request and edited in place; it is
      # the primary's comment, but never a reply to anything.
      if [ -f "$GH_STATE/primary-dashboard" ]; then
        fake_add_comment 100 "$primary" "$request_at" "<!-- codex-pull-request-review-summary -->

## Codex Review Summary"
      fi
      if [ "${GH_MODE:-ok}" = primary_quota ]; then
        fake_add_comment 101 "$primary" "$reply_at" 'You have reached your Codex usage limits for code reviews.'
      fi
      if [ -f "$GH_STATE/primary-comment" ] && fake_visible primary-comment-delay; then
        fake_add_comment 102 "$primary" "$reply_at" "$(cat "$GH_STATE/primary-comment")"
      fi
      if [ -f "$GH_STATE/fallback-announced" ]; then
        fake_add_comment 103 alice "$request_at" "<!-- touchstone:review-fallback head=$GH_HEAD -->"
      fi
      printf '%s\n' "$fake_comments"
    elif has '/issues/7/comments' "$@"; then
      if has '[.id, (.user.login // ""), (.body // "")]' "$@"; then
        case "${GH_MODE:-ok}" in
          primary_quota) printf '2\tchatgpt-codex-connector[bot]\tYou have reached your Codex usage limits for code reviews.\n' ;;
          primary_replied) printf '2\tchatgpt-codex-connector[bot]\tReviewed commit: %s\n' "$GH_HEAD" ;;
        esac
        [ ! -f "$GH_STATE/fallback-announced" ] || printf '3\talice\t<!-- touchstone:review-fallback head=%s -->\n' "$GH_HEAD"
      elif has 'updated_at // .created_at' "$@"; then
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
      elif [ "${GH_MODE:-ok}" = attest_request_present ]; then
        # What `pr answer` leaves behind when an answer resolves the last
        # thread: a real review request for this head, carrying the attest
        # marker rather than the pr-open one.
        printf '%s\talice\t%s\n' 'https://example.test/pr/7#issuecomment-91' \
          "@codex review\\n\\n<!-- touchstone:attest-request head=$GH_HEAD -->"
        # Where reuse is refused and a request is posted instead, that request
        # must be visible for this command's own post-write verification.
        if [ -f "$GH_STATE/review-request" ]; then
          printf '%s\talice\t%s\n' 'https://example.test/pr/7#issuecomment-1' \
            "@codex review\\n\\n<!-- touchstone:pr-open head=$GH_HEAD base=$GH_BASE_REF base_sha=$GH_BASE_SHA -->"
        fi
      elif [ "${GH_MODE:-ok}" = attest_request_other_head ]; then
        printf '%s\talice\t%s\n' 'https://example.test/pr/7#issuecomment-92' \
          "@codex review\\n\\n<!-- touchstone:attest-request head=0000000000000000000000000000000000000000 -->"
        # The request this command posts must still be visible, or its own
        # post-write verification cannot find what it just wrote.
        if [ -f "$GH_STATE/review-request" ]; then
          printf '%s\talice\t%s\n' 'https://example.test/pr/7#issuecomment-1' \
            "@codex review\\n\\n<!-- touchstone:pr-open head=$GH_HEAD base=$GH_BASE_REF base_sha=$GH_BASE_SHA -->"
        fi
      elif [ "${GH_MODE:-ok}" = attest_request_moved_base ]; then
        # Both requests for this head: this command's own under a base that has
        # since moved, and an attest request carrying no base at all.
        printf '%s\talice\t%s\n' 'https://example.test/pr/7#issuecomment-94' \
          "@codex review\\n\\n<!-- touchstone:pr-open head=$GH_HEAD base=release base_sha=release-sha -->"
        printf '%s\talice\t%s\n' 'https://example.test/pr/7#issuecomment-91' \
          "@codex review\\n\\n<!-- touchstone:attest-request head=$GH_HEAD -->"
      elif [ "${GH_MODE:-ok}" = attest_request_spoofed ]; then
        printf '%s\tmallory\t%s\n' 'https://example.test/pr/7#issuecomment-93' \
          "@codex review\\n\\n<!-- touchstone:attest-request head=$GH_HEAD -->"
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
    elif has '/reviews?per_page=100' "$@" && ! has --jq "$@"; then
      # The raw review pages: a primary review from before the request, which
      # must never wake the wait, and one of this head submitted after it when
      # a case asks -- a minute after, unless primary-review-offset says. A
      # stale review is the previous head's, landing late (AUT-1636).
      reviews='[{"id":60,"user":{"login":"chatgpt-codex-connector[bot]"},"state":"COMMENTED","commit_id":"2222222222222222222222222222222222222222","submitted_at":"2026-08-01T00:00:00Z","body":"An earlier head."}]'
      if [ -f "$GH_STATE/primary-review-stale" ]; then
        reviews="$(printf '%s' "$reviews" | jq -c --arg at "$(fake_after_request 60)" \
          '. + [{id:62, user:{login:"chatgpt-codex-connector[bot]"}, state:"COMMENTED", commit_id:"1111111111111111111111111111111111111111", submitted_at:$at, body:"The previous head."}]')"
      fi
      if [ -f "$GH_STATE/primary-review" ] && fake_visible primary-review-delay; then
        review_offset=60
        [ ! -f "$GH_STATE/primary-review-offset" ] || review_offset="$(cat "$GH_STATE/primary-review-offset")"
        reviews="$(printf '%s' "$reviews" | jq -c --arg at "$(fake_after_request "$review_offset")" --arg head "$GH_HEAD" \
          '. + [{id:61, user:{login:"chatgpt-codex-connector[bot]"}, state:"COMMENTED", commit_id:$head, submitted_at:$at, body:""}]')"
      fi
      printf '%s\n' "$reviews"
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
    # The free rate-limit read, through the caller's real jq. Only the quota
    # a case exhausts reads zero; a secondary limit leaves both untouched.
    if has 'rate_limit' "$@"; then
      [ ! -f "$GH_STATE/rate-limit-unreadable" ] || { printf 'gh: Bad credentials (HTTP 401)\n' >&2; exit 1; }
      core_remaining=4321
      graphql_remaining=4999
      # Which quota is spent, defaulting to the one the refusal came from;
      # `both` is the machine that polled every quota to zero (AUT-1638).
      case "${GH_RATE_LIMIT_EXHAUSTED:-${GH_RATE_LIMIT_KIND:-core}}" in
        core) core_remaining=0 ;;
        graphql) graphql_remaining=0 ;;
        both)
          core_remaining=0
          graphql_remaining=0
          ;;
      esac
      jq -cn --argjson core "$core_remaining" --argjson graphql "$graphql_remaining" \
        '{resources:{core:{limit:5000,used:(5000 - $core),remaining:$core,reset:1789086073},graphql:{limit:5000,used:(5000 - $graphql),remaining:$graphql,reset:1789086400}}}' \
        | jq -r "$(value_after --jq "$@")"
      exit 0
    fi
    if has '/check-runs/' "$@" && has '/annotations' "$@"; then
      if [ -f "$GH_STATE/annotations-unreadable" ]; then
        printf 'gh: Not Found (HTTP 404)\n' >&2
        exit 1
      fi
      # A job a runner never picked up: readable, and naming no billing.
      if [ -f "$GH_STATE/annotations-nonbilling" ]; then
        jq -cn '[{path:".github",start_line:1,annotation_level:"failure",title:"",message:"The job was not acquired by Runner of type hosted even after multiple attempts",raw_details:""}]'
        exit 0
      fi
      # The annotation GitHub attached to every refused job on hesperus#354
      # and vesper#1255, verbatim.
      jq -cn --arg message "The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the 'Billing & plans' section in your settings" \
        '[{path:".github",start_line:1,start_column:null,end_line:1,end_column:null,annotation_level:"failure",title:"",message:$message,raw_details:""}]'
      exit 0
    fi
    if has "commits/$GH_HEAD/check-runs?per_page=100" "$@"; then
      case "${GH_MODE:-ok}" in
        status_auto_merge_blocked) printf '%s\n' '{"check_runs":[{"name":"review-gate","status":"completed","conclusion":"success"},{"name":"validate","status":"completed","conclusion":"failure"}]}' ;;
        status_auto_merge) printf '%s\n' '{"check_runs":[{"name":"review-gate","status":"completed","conclusion":"success"},{"name":"Build, test, and smoke","status":"in_progress","conclusion":null}]}' ;;
        *) printf '%s\n' '{"check_runs":[{"name":"review-gate","status":"completed","conclusion":"success"}]}' ;;
      esac
      exit 0
    fi
    if has 'touchstone-workflows/contents/.touchstone-source-contract.json?ref=' "$@"; then
      [ ! -f "$GH_STATE/behavior-manifest-unreadable" ] || { printf 'Not Found\n' >&2; exit 1; }
      # The source tree's own policies declare gate behavior 4, so a GitHub
      # that agrees with them is the default; each flag below is one drifted
      # world -- the pre-rollout gates, an unsupported future one, the
      # contract-3 gate a repository runs until its repin is applied, or an
      # overlapping pin whose other enforced revision is the compatible one.
      behavior_version=4
      [ ! -f "$GH_STATE/behavior-version-legacy" ] || behavior_version=1
      [ ! -f "$GH_STATE/behavior-version-unsupported" ] || behavior_version=5
      [ ! -f "$GH_STATE/behavior-version-next" ] || behavior_version=3
      if [ -f "$GH_STATE/overlapping-pins" ] && has "?ref=$GH_MID_SHA" "$@"; then behavior_version=1; fi
      if [ -f "$GH_STATE/behavior-version-missing" ]; then
        printf '%s\n' '{"contractVersion":1}'
      else
        jq -cn --argjson version "$behavior_version" \
          '{contractVersion:1,gateBehaviorContractVersion:$version}'
      fi
    elif has 'touchstone-workflows/contents/.github/workflows/review-gate.yml?ref=' "$@"; then
      # The pinned gate's own text. The contract-4 wait derives its deadline
      # from the env line alone: a commented mention is not a declaration.
      printf 'jobs:\n  review-gate:\n    env:\n      REVIEW_REQUEST_WAIT_SECONDS: 120\n      # REVIEW_EVIDENCE_WAIT_SECONDS: 5 only in a comment\n'
      [ -f "$GH_STATE/review-gate-no-deadline" ] \
        || printf '      REVIEW_EVIDENCE_WAIT_SECONDS: %s\n' "${GH_EVIDENCE_WAIT_SECONDS:-600}"
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
    elif has "repos/${GH_FAKE_REPO:-${GH_REPO:-autumngarage/current}}/commits/" "$@"; then
      # A reviewed-commit abbreviation, resolved as GitHub resolves it: a
      # prefix of the head is the head, unless a case makes it another commit
      # that shares the prefix; anything else is no commit at all.
      commit_ref="$(printf '%s\n' "$@" | grep -F '/commits/' | head -1)"
      commit_ref="${commit_ref##*/commits/}"
      if [ -f "$GH_STATE/abbrev-resolves-elsewhere" ]; then
        resolved="${commit_ref}0000000000000000000000000000000000000000"
        resolved="${resolved:0:40}"
      elif [ "${GH_HEAD#"$commit_ref"}" != "$GH_HEAD" ]; then
        resolved="$GH_HEAD"
      else
        printf 'gh: No commit found for SHA: %s (HTTP 422)\n' "$commit_ref" >&2
        exit 1
      fi
      printf '%s' "{\"sha\":\"$resolved\"}" | jq -r "$(value_after --jq "$@")"
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
        # status, attempt, conclusion: the superseded attempt can still show
        # right after a re-run, then the new one in progress.
        left="$(cat "$GH_STATE/gate-after-rerun")"
        if [ "$left" -ge 2 ]; then
          echo 1 >"$GH_STATE/gate-after-rerun"
          printf 'completed\t1\tsuccess\n'
        else
          rm -f "$GH_STATE/gate-after-rerun"
          printf 'in_progress\t2\t-\n'
        fi
      elif [ -f "$GH_STATE/gate-rerun-running" ] && ! fake_after_reads gate-rerun-running; then
        printf 'in_progress\t2\t-\n'
      else
        printf 'completed\t2\t%s\n' "${GH_GATE_CONCLUSION:-success}"
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
          status_gate_failure | status_gate_collision | status_gate_refused | actions_refused | status_gate_workflow_failure)
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
        case "${GH_MODE:-ok}" in delivery_evidence_failure | actions_refused) evidence_conclusion=failure ;; esac
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
        # The policy's validate workflow, refused by Actions for this head.
        if [ -f "$GH_STATE/validate-refused" ]; then
          runs="$(printf '%s' "$runs" | jq -c '.workflow_runs += [{"id":90,"node_id":"RUN_90","name":"validate","head_sha":"'"$GH_HEAD"'","check_suite_id":908,"run_attempt":1,"event":"pull_request","status":"completed","conclusion":"failure","workflow_id":1002,"run_started_at":"2026-08-27T17:05:00Z","updated_at":"2026-08-27T17:06:00Z","pull_requests":[{"number":7}]}]')"
        fi
        if [ "${GH_MODE:-ok}" = delivery_new_run_after_rerun ] && [ -f "$GH_STATE/evidence-reruns" ]; then
          runs="$(printf '%s' "$runs" | jq -c '.workflow_runs += [{
            id:84,
            node_id:"RUN_84",
            name:"delivery-evidence",
            head_sha:"'"$GH_HEAD"'",
            check_suite_id:907,
            run_attempt:1,
            event:"pull_request",
            status:"completed",
            conclusion:"success",
            workflow_id:1000,
            run_started_at:"2026-08-27T17:40:00Z",
            updated_at:"2026-08-27T17:41:00Z",
            pull_requests:[{number:7}]
          }]')"
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
    elif has '/issues/comments/91' "$@"; then
      # The attest request `pr answer` leaves for this head, served by id so
      # the binding re-read can verify it the same way it verifies its own.
      jq -cn --arg body "@codex review

<!-- touchstone:attest-request head=$GH_HEAD -->" \
        '{id: 91, user: {login: "alice"}, body: $body, author_association: "NONE"}'
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
  # The wait for the primary reviewer's reply is exercised by its own case.
  export TOUCHSTONE_REVIEW_RESPONSE_WAIT_SECONDS=0

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
  # The CLI still carries its gate behavior contract 2 and 3 paths, but the
  # source tree's policies now declare 4. This client carries a contract-3
  # policy; with behavior-version-next, GitHub agrees with it.
  mkdir -p "$TMP/tool-v3/bin" "$TMP/tool-v3/scripts" "$TMP/tool-v3/policy/github"
  cp "$ROOT/bin/touchstone" "$TMP/tool-v3/bin/touchstone"
  cp "$ROOT/scripts/touchstone-pr.sh" "$TMP/tool-v3/scripts/touchstone-pr.sh"
  cp -R "$ROOT/policy/github/." "$TMP/tool-v3/policy/github/"
  cat "$ROOT/VERSION" >"$TMP/tool-v3/VERSION"
  jq '.workflowSource.sourceContract.gateBehaviorContractVersion = 3' \
    "$ROOT/policy/github/touchstone-main.json" >"$TMP/tool-v3/policy/github/touchstone-main.json"
  run_pr_v3() {
    local output="$1"
    shift
    : >"$GH_CALLS"
    set +e
    bash "$TMP/tool-v3/bin/touchstone" pr "$@" --project "$TMP/project" >"$output" 2>&1
    RUN_RC=$?
    set -e
  }

  echo "==> policy status names the pinned gate revision, not just the local tool version (AUT-1249)"
  # "policy: ... at v3.10.1" is the document this compared against; it says
  # nothing about which workflow revision GitHub will run, and a reader took
  # the version as the rules in force while a pre-3.10.1 rule enforced.
  touch "$TMP/state/review-gate"
  run_pr "$TMP/out" policy-status --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"pinnedReviewGate":{"sourceRepository":"autumngarage/touchstone-workflows"'
  assert_has "$TMP/out" "\"revisions\":[\"$GH_POLICY_SHA\"]"
  run_pr "$TMP/out" policy-status
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" "pinned review-gate: autumngarage/touchstone-workflows@"
  assert_has "$TMP/out" "$GH_POLICY_SHA"
  rm -f "$TMP/state/review-gate"

  echo "==> status is versioned, read-only, and retries bounded transport failures"
  touch "$TMP/state/pr-exists"
  GH_MODE=read_retry run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"schema":"touchstone.pr/v2"'
  assert_has "$TMP/out" '"status":"observed"'
  assert_has "$TMP/out" "\"head\":\"$HEAD_SHA\""
  assert_has "$TMP/out" "\"autoMerge\":{\"armed\":false,\"enabledAt\":null,\"head\":\"$HEAD_SHA\"}"
  assert_has "$TMP/out" '"mergeQueue":null,"mergeQueueEviction":null,"phase":"action-required","nextAction":"inspect"'
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

  echo "==> status does not project review-round history"
  printf '%s\n' '- Review budget: malformed legacy record' >"$TMP/state/pr-body"
  : >"$GH_CALLS"
  run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_not_has "$TMP/out" '"reviewBudget"'
  assert_not_has "$GH_CALLS" '--json body'
  assert_not_has "$GH_CALLS" '/issues/7/comments?per_page=100'
  assert_not_has "$GH_CALLS" '/pulls/7/reviews?per_page=100'
  assert_not_has "$GH_CALLS" '/pulls/7/comments?per_page=100'
  rm -f "$TMP/state/pr-body"
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

  echo "==> under gate contract 4, a failed gate may be a head waiting for review, and status says so (AUT-1635)"
  # A contract-4 gate evaluates once and fails fast when review evidence is
  # missing, so this failure may be a head only waiting for review. Which one
  # lives in the gate's log, which status does not read: the phase keeps its
  # compatible values, and the guidance stops sending the driver to fix code.
  assert_has "$TMP/out" '"reviewGateBehaviorContractVersion":4'
  assert_has "$TMP/out" '"summary":"Run touchstone pr open for the live head.","failureMayBeWaiting":true,"recovery":"The gate run says which: if it is waiting for review, re-run touchstone pr open, which waits here for the reviewer and then re-runs the gate once; if it reports findings, answer each with touchstone pr answer --finding. Never push a fix commit for a gate that is only waiting."}'
  GH_MODE=status_gate_failure run_pr "$TMP/out" status 7
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" 'phase: fix-required'
  assert_not_has "$TMP/out" 'address-review'
  assert_has "$TMP/out" 'next action: read the gate run: it may be waiting for review rather than reporting findings (see next step)'
  assert_has "$TMP/out" 'next step: this gate failure may be a head still waiting for review, not findings; read the gate run at https://example.test/runs/82. The gate run says which: if it is waiting for review, re-run touchstone pr open'
  assert_has "$TMP/out" 'answer each with touchstone pr answer --finding. Never push a fix commit for a gate that is only waiting.'
  # The same failure concluded on the workflow run, with no CheckRun to link.
  GH_MODE=status_gate_workflow_failure run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"phase":"fix-required","nextAction":"address-review"'
  assert_has "$TMP/out" '"workflowStatus":"completed","workflowConclusion":"failure","failureMayBeWaiting":true,"recovery":"The gate run says which:'
  GH_MODE=status_gate_workflow_failure run_pr "$TMP/out" status 7
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" 'next step: this gate failure may be a head still waiting for review, not findings; read the log of review-gate workflow run 77. The gate run says which:'
  # A contract-3 gate waited for evidence before it failed, so its failure is
  # findings: that output is unchanged, and carries neither field.
  touch "$TMP/state/behavior-version-next"
  GH_MODE=status_gate_failure run_pr_v3 "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"phase":"fix-required","nextAction":"address-review"'
  assert_has "$TMP/out" '"summary":"Run touchstone pr open for the live head."},"reviewGateBehaviorContractVersion":3,'
  assert_not_has "$TMP/out" 'failureMayBeWaiting'
  assert_not_has "$TMP/out" '"recovery"'
  GH_MODE=status_gate_failure run_pr_v3 "$TMP/out" status 7
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" 'next action: address-review'
  assert_not_has "$TMP/out" 'next step:'
  assert_not_has "$TMP/out" 'waiting for review'
  GH_MODE=status_gate_workflow_failure run_pr_v3 "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"phase":"fix-required","nextAction":"address-review"'
  assert_not_has "$TMP/out" 'failureMayBeWaiting'
  rm -f "$TMP/state/behavior-version-next"

  echo "==> status reports a gate job Actions refused to start as refused, not as findings (AUT-1594)"
  GH_MODE=status_gate_refused run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"phase":"action-required","nextAction":"inspect"'
  assert_not_has "$TMP/out" '"phase":"fix-required"'
  assert_has "$TMP/out" '"actionsRefused":{"jobId":102919303302,"billing":true,"annotation":"The job was not started because recent account payments have failed or your spending limit needs to be increased.'
  GH_MODE=status_gate_refused run_pr "$TMP/out" status 7
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" 'review gate: completed/failure (check run 102919303302): Actions refused this job (billing), not an evidence verdict: GitHub says "The job was not started because'
  assert_has "$TMP/out" 'next step: The PR body needs no change: nothing evaluated it.'
  assert_has "$TMP/out" 'No merge can complete while Actions refuses jobs'
  assert_has "$TMP/out" 'the queue rule admits no audited bypass, so none exists to use'
  assert_has "$TMP/out" 'Restoring Actions capacity (budget or allowance) is the human'\''s decision'
  # No bypass exists under the queue rule (405 on hesperus#354), so none is
  # ever offered, and the agent is never pointed at an admin merge.
  assert_not_has "$TMP/out" '--admin'
  assert_not_has "$TMP/out" 'organization admin'
  # Zero steps alone classifies it: an unreadable annotation is named, not
  # dropped, and never turns the refusal back into findings.
  touch "$TMP/state/annotations-unreadable"
  GH_MODE=status_gate_refused run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"actionsRefused":{"jobId":102919303302,"billing":false,"annotation":null,"annotationError":"gh: Not Found (HTTP 404)"}'
  assert_has "$TMP/out" '"phase":"action-required","nextAction":"inspect"'
  rm -f "$TMP/state/annotations-unreadable"
  # A gate that ran its steps and failed is still a review verdict.
  GH_MODE=status_gate_failure run_pr "$TMP/out" status 7 --json
  assert_not_has "$TMP/out" 'actionsRefused'
  GH_MODE=status_gate_success run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"phase":"ready-to-queue","nextAction":"queue"'
  assert_has "$TMP/out" '"checkRunId":84,"status":"completed","conclusion":"success"'
  assert_not_has "$TMP/out" 'Superseded attempt'
  # A contract-4 success is unchanged: the waiting hint belongs to failure only.
  assert_has "$TMP/out" '"reviewGateBehaviorContractVersion":4'
  assert_not_has "$TMP/out" 'failureMayBeWaiting'
  assert_not_has "$TMP/out" '"recovery"'
  GH_MODE=status_gate_success run_pr "$TMP/out" status 7
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" 'phase: ready-to-queue'
  assert_has "$TMP/out" 'next action: queue'
  assert_has "$TMP/out" "command: touchstone pr merge 7 --head $HEAD_SHA"
  assert_not_has "$TMP/out" 'next step:'

  echo "==> a head the queue already evicted is evicted, not ready to queue (touchstone#1092)"
  # Same green head, same successful gate, same CLEAN merge state -- the only
  # difference is the queue's newest event for this head. On the old reader
  # this was ready-to-queue with a merge command, and following it re-entered
  # the eviction loop.
  touch "$TMP/state/queue-evicted"
  GH_MODE=status_gate_success run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"mergeQueue":null,"mergeQueueEviction":{"at":"2026-09-02T16:51:33Z","reason":"failed_checks","queueBase":"dd69484b30f6"},"phase":"evicted","nextAction":"inspect"'
  assert_not_has "$TMP/out" '"phase":"ready-to-queue"'
  GH_MODE=status_gate_success run_pr "$TMP/out" status 7
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" 'phase: evicted'
  assert_has "$TMP/out" 'merge queue history: evicted at 2026-09-02T16:51:33Z (failed_checks)'
  assert_not_has "$TMP/out" 'command: touchstone pr merge'
  rm -f "$TMP/state/queue-evicted"
  # A head pushed after the removal is a different head: the eviction is
  # history and this head stays ready to queue.
  touch "$TMP/state/queue-evicted-then-pushed"
  GH_MODE=status_gate_success run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"mergeQueueEviction":null,"phase":"ready-to-queue","nextAction":"queue"'
  rm -f "$TMP/state/queue-evicted-then-pushed"
  # A retarget after the removal moves the PR to coordinates the queue never
  # evaluated: the eviction is history. (A base that merely advanced leaves
  # no PR event and stays conservatively evicted -- AUT-1183.)
  touch "$TMP/state/queue-evicted-then-retargeted"
  GH_MODE=status_gate_success run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"mergeQueueEviction":null,"phase":"ready-to-queue","nextAction":"queue"'
  rm -f "$TMP/state/queue-evicted-then-retargeted"
  # An eviction followed by a later re-queue is not the current state either.
  touch "$TMP/state/queue-requeued"
  GH_MODE=status_gate_success run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"mergeQueueEviction":null,"phase":"ready-to-queue","nextAction":"queue"'
  rm -f "$TMP/state/queue-requeued"

  echo "==> stale eviction history never outranks a policy that enforces no queue"
  # A workflow-source policy with no managed ruleset expects no queue, so
  # enforcement is applied even when the repository has none. Queue history
  # left over from before such a policy change must not pin the phase to
  # evicted: there is nothing to be evicted from.
  mkdir -p "$TMP/tool-queueless/bin" "$TMP/tool-queueless/scripts" "$TMP/tool-queueless/policy/github/workflow-sources"
  cp "$ROOT/bin/touchstone" "$TMP/tool-queueless/bin/touchstone"
  cp "$ROOT/scripts/touchstone-pr.sh" "$TMP/tool-queueless/scripts/touchstone-pr.sh"
  cp -R "$ROOT/policy/github/." "$TMP/tool-queueless/policy/github/"
  cp "$ROOT/VERSION" "$TMP/tool-queueless/VERSION"
  jq '.managedRepositoryRuleset = null' "$ROOT/policy/github/workflow-sources/touchstone-workflows.json" \
    >"$TMP/tool-queueless/policy/github/workflow-sources/touchstone-workflows.json"
  touch "$TMP/state/no-queue-rule" "$TMP/state/queue-evicted"
  set +e
  GH_FAKE_REPO=autumngarage/touchstone-workflows bash "$TMP/tool-queueless/bin/touchstone" pr status 7 --project "$TMP/project" --json >"$TMP/out" 2>&1
  RUN_RC=$?
  set -e
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"enforcement":{"status":"applied","missing":[]}'
  assert_has "$TMP/out" '"mergeQueueEviction":{"at":"2026-09-02T16:51:33Z","reason":"failed_checks","queueBase":"dd69484b30f6"}'
  assert_not_has "$TMP/out" '"phase":"evicted"'
  rm -f "$TMP/state/no-queue-rule" "$TMP/state/queue-evicted"

  echo "==> a live queue entry reports its position (touchstone#1049)"
  GH_MODE=status_gate_queued run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"mergeQueue":{"state":"AWAITING_CHECKS","position":1},"mergeQueueEviction":null,"phase":"queued","nextAction":"wait"'
  GH_MODE=status_gate_queued run_pr "$TMP/out" status 7
  assert_has "$TMP/out" 'merge queue: AWAITING_CHECKS (position 1)'

  echo "==> under a merge queue, an armed auto-merge request with no entry is not queued (touchstone#1049)"
  # GitHub armed auto-merge and never enqueued the head. The old reader
  # called this queued, so "armed and waiting" and "armed and never admitted"
  # were the same phase and a Dockmaster polled a PR that would never land.
  GH_MODE=status_auto_merge run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"autoMerge":{"armed":true,"enabledAt":"2026-08-24T20:00:00Z"'
  # ...and since pr merge arms auto-merge while checks still run, the phase
  # says what GitHub is waiting on instead of sending the driver to inspect.
  assert_has "$TMP/out" '"mergeQueue":null,"mergeQueueEviction":null,"phase":"armed-waiting-checks","nextAction":"wait","blockers":{"failedChecks":"","pendingChecks":"Build, test, and smoke (in_progress)","unresolvedThreads":0}'
  assert_not_has "$TMP/out" '"phase":"queued"'
  GH_MODE=status_auto_merge run_pr "$TMP/out" status 7
  assert_has "$TMP/out" 'phase: armed-waiting-checks'
  assert_has "$TMP/out" 'waiting on: Build, test, and smoke (in_progress)'
  assert_has "$TMP/out" 'a reviewer quota notice on the PR is not a blocker and not a wait.'
  GH_MODE=status_auto_merge_blocked run_pr "$TMP/out" status 7 --json
  assert_has "$TMP/out" '"phase":"armed-blocked","nextAction":"inspect","blockers":{"failedChecks":"validate (failure)"'
  GH_MODE=status_auto_merge_blocked run_pr "$TMP/out" status 7
  assert_has "$TMP/out" 'blocked by: validate (failure)'
  GH_MODE=status_auto_merge_threads run_pr "$TMP/out" status 7
  assert_has "$TMP/out" 'phase: armed-blocked'
  assert_has "$TMP/out" 'blocked by: 2 unresolved review thread(s)'

  echo "==> a PR closed without merging is closed, a terminal phase (AUT-511)"
  GH_MODE=status_closed run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"state":"CLOSED"'
  assert_has "$TMP/out" '"phase":"closed","nextAction":"inspect"'
  assert_not_has "$TMP/out" '"phase":"action-required"'

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
  : >"$GH_CALLS"
  GH_MODE=status_gate_stale_review run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"phase":"ready-to-queue","nextAction":"queue"'
  assert_not_has "$GH_CALLS" '/issues/7/comments?per_page=100'
  assert_not_has "$GH_CALLS" '/pulls/7/reviews?per_page=100'
  assert_not_has "$GH_CALLS" '/pulls/7/comments?per_page=100'
  GH_MODE=status_gate_queued run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"mergeQueue":{"state":"AWAITING_CHECKS","position":1},"mergeQueueEviction":null,"phase":"queued","nextAction":"wait"'
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
  assert_has "$TMP/out" '"mergeQueue":{"state":"AWAITING_CHECKS","position":1},"mergeQueueEviction":null,"phase":"action-required","nextAction":"inspect"'
  rm -f "$TMP/state/no-review-gate-rule"
  GH_MODE=status_merged run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"phase":"merged","nextAction":"done"'
  GH_MODE=status_gate_queue_unmergeable run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"mergeQueue":{"state":"UNMERGEABLE","position":1},"mergeQueueEviction":null,"phase":"action-required","nextAction":"inspect"'
  GH_MODE=status_gate_queue_unknown run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"mergeQueue":{"state":"FUTURE_STATE","position":1},"mergeQueueEviction":null,"phase":"action-required","nextAction":"inspect"'
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
  assert_has "$TMP/out" '"phase":"ready-to-queue","nextAction":"queue"'
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
  assert_not_has "$TMP/out" 'Actions refused'
  rm -f "$TMP/state/pr-exists" "$TMP/state/pr-body" "$TMP/state/review-request"

  echo "==> a required job Actions refused to start is not an evidence verdict (AUT-1594)"
  # hesperus#354 and vesper#1255: with the Actions budget at zero, GitHub
  # failed every required job with no steps and one billing annotation, and
  # open sent the driver to correct a body the gate never read. This is the
  # contract 3 client's report: it reads the refused gate run too. A contract 4
  # client reports the refusal without reading or waking the gate, so this runs
  # where GitHub and the client both declare contract 3.
  touch "$TMP/state/review-gate" "$TMP/state/behavior-version-next"
  rm -f "$TMP/state/gate-reruns" "$TMP/state/evidence-reruns"
  GH_MODE=actions_refused run_pr_v3 "$TMP/out" open --title 'Refused' --body-file "$TMP/body"
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'delivery-evidence run 80: Actions refused this job (billing), not an evidence verdict: GitHub says "The job was not started because recent account payments have failed or your spending limit needs to be increased.'
  assert_has "$TMP/out" 'review-gate run 77: Actions refused this job (billing), not an evidence verdict'
  assert_has "$TMP/out" 'hosted review was still requested (posted:https://example.test/pr/7#issuecomment-1) because the reviewer runs outside Actions'
  assert_has "$TMP/out" 'The PR body needs no change: nothing evaluated it.'
  assert_has "$TMP/out" 'the queue rule admits no audited bypass, so none exists to use'
  assert_has "$TMP/out" 'Restoring Actions capacity (budget or allowance) is the human'\''s decision'
  # The recovery is stated once, with each refused run's exact re-run: open
  # never re-runs one itself (AUT-1610).
  assert_has "$TMP/out" 'touchstone pr open never re-runs a refused run'
  assert_has "$TMP/out" 're-run each refused run (gh api --hostname github.com -X POST repos/autumngarage/current/actions/runs/80/rerun; gh api --hostname github.com -X POST repos/autumngarage/current/actions/runs/77/rerun)'
  assert_not_has "$TMP/out" 'organization admin'
  assert_has "$TMP/out" 'PR #7 exists at https://example.test/pr/7'
  assert_not_has "$TMP/out" 'correct the recorded evidence'
  assert_not_has "$TMP/out" 'Delivery evidence accepted'
  assert_not_has "$TMP/out" '--admin'
  [ -f "$TMP/state/review-request" ] \
    && ok "a refused job still requests the hosted review, which runs outside Actions" \
    || fail "a refused job withheld the hosted review request"
  assert_not_has "$GH_CALLS" 'actions/runs/77/rerun'
  assert_not_has "$GH_CALLS" 'actions/runs/80/rerun'
  # A reused PR asks for a fresh evidence attempt first; a refused one is not
  # re-run either, and the existing request is reused rather than re-posted.
  GH_MODE=actions_refused run_pr_v3 "$TMP/out" open --title 'Refused' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 1
  [ "$(grep '^{' "$TMP/out" | jq -r '.status')" = failed ] \
    || fail "a refused open reported something other than failed: $(cat "$TMP/out")"
  assert_has "$TMP/out" 'hosted review was still requested (existing:https://example.test/pr/7#issuecomment-1)'
  assert_not_has "$GH_CALLS" 'actions/runs/80/rerun'
  assert_not_has "$GH_CALLS" 'actions/runs/77/rerun'
  assert_not_has "$GH_CALLS" 'pr comment'
  # Zero steps alone still classifies it when the annotation cannot be read.
  touch "$TMP/state/annotations-unreadable"
  GH_MODE=actions_refused run_pr_v3 "$TMP/out" open --title 'Refused' --body-file "$TMP/body"
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'delivery-evidence run 80: Actions refused this job (no step ran), not an evidence verdict: its annotation was unreadable (gh: Not Found (HTTP 404))'
  assert_not_has "$TMP/out" 'correct the recorded evidence'
  rm -f "$TMP/state/annotations-unreadable" "$TMP/state/pr-exists" "$TMP/state/pr-body" "$TMP/state/review-request" \
    "$TMP/state/behavior-version-next"

  echo "==> a job that never started for a reason other than billing keeps the ordinary retry (AUT-1610)"
  # Only a billing annotation, or none that can be read, makes a job refused.
  # A runner that never picked the job up is a failure a re-run can clear.
  touch "$TMP/state/review-gate" "$TMP/state/behavior-version-next" "$TMP/state/pr-exists" "$TMP/state/annotations-nonbilling"
  rm -f "$TMP/state/gate-reruns" "$TMP/state/evidence-reruns" "$TMP/state/review-request"
  GH_MODE=actions_refused run_pr_v3 "$TMP/out" open --title 'Refused' --body-file "$TMP/body"
  assert_rc "$RUN_RC" 0
  assert_has "$GH_CALLS" 'actions/runs/80/rerun'
  assert_has "$GH_CALLS" 'actions/runs/77/rerun'
  assert_has "$TMP/out" 'delivery-evidence run 80 failed without running a step, and its annotation names no Actions billing refusal (GitHub says "The job was not acquired by Runner'
  assert_not_has "$TMP/out" 'Actions refused this job'
  # status reads the same gate job the same way. GitHub declares contract 4
  # again here, so the gate is applied and actually read (checkRunId).
  rm -f "$TMP/state/behavior-version-next"
  GH_MODE=status_gate_refused run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"checkRunId":102919303302'
  assert_not_has "$TMP/out" 'actionsRefused'
  rm -f "$TMP/state/annotations-nonbilling" "$TMP/state/review-request" \
    "$TMP/state/gate-reruns" "$TMP/state/evidence-reruns"

  echo "==> merge gives a refused gate the refusal's own remedy, not findings to answer (AUT-1610)"
  GH_MODE=status_gate_refused run_pr "$TMP/out" merge 7 --head "$HEAD_SHA"
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'Actions refused this job (billing)'
  assert_has "$TMP/out" 're-run each refused run (gh api --hostname github.com -X POST repos/autumngarage/current/actions/runs/77/rerun)'
  assert_not_has "$TMP/out" 'answer the reported findings'
  assert_not_has "$GH_CALLS" 'pr merge'

  echo "==> status reads delivery-evidence and validate refusals through the gate's reader (AUT-1610)"
  GH_MODE=actions_refused run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"actionsRefused":{"jobId":102919303302'
  assert_has "$TMP/out" '"actionsRefusedRuns":[{"workflow":"delivery-evidence","workflowRunId":80,"jobId":102919303957,"billing":true'
  assert_has "$TMP/out" '"phase":"action-required","nextAction":"inspect"'
  GH_MODE=actions_refused run_pr "$TMP/out" status 7
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '  required run: delivery-evidence run 80: Actions refused this job (billing)'
  assert_has "$TMP/out" 're-run each refused run (gh api --hostname github.com -X POST repos/autumngarage/current/actions/runs/77/rerun; gh api --hostname github.com -X POST repos/autumngarage/current/actions/runs/80/rerun)'
  [ "$(grep -c 'next step:' "$TMP/out" || true)" -eq 1 ] || fail "status printed other than one next step for the refused runs"
  # validate alone: the gate passed, yet the head is held rather than ready.
  touch "$TMP/state/validate-refused"
  GH_MODE=status_gate_success run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"actionsRefusedRuns":[{"workflow":"validate","workflowRunId":90,"jobId":102919304400,"billing":true'
  assert_has "$TMP/out" '"phase":"action-required","nextAction":"inspect"'
  assert_not_has "$TMP/out" '"phase":"ready-to-queue"'
  rm -f "$TMP/state/validate-refused"
  GH_MODE=status_gate_success run_pr "$TMP/out" status 7 --json
  assert_not_has "$TMP/out" 'actionsRefusedRuns'

  echo "==> under contract 4, open names a refused review-gate run beside the refused evidence run (AUT-1610)"
  rm -f "$TMP/state/pr-exists" "$TMP/state/pr-body" "$TMP/state/review-request" "$TMP/state/gate-reruns"
  GH_MODE=actions_refused run_pr "$TMP/out" open --title 'Refused' --body-file "$TMP/body"
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'Not waiting for review'
  assert_has "$TMP/out" 'delivery-evidence run 80: Actions refused this job (billing)'
  assert_has "$TMP/out" 'review-gate run 77: Actions refused this job (billing)'
  assert_has "$TMP/out" 'actions/runs/80/rerun; gh api --hostname github.com -X POST repos/autumngarage/current/actions/runs/77/rerun)'
  assert_not_has "$GH_CALLS" 'actions/runs/77/rerun'
  rm -f "$TMP/state/pr-exists" "$TMP/state/pr-body" "$TMP/state/review-request" "$TMP/state/gate-reruns"

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
  # AUT-1482. `pr answer` posts its own request for this head when an answer
  # resolves the last thread, carrying the attest marker rather than this
  # command's. Scanning only for the pr-open marker bought a SECOND hosted
  # review of the same commit -- observed live on touchstone#1174, attest at
  # 13:35:03 and pr-open at 13:36:00, 57 seconds apart. Where the gate is
  # required, binding is head-only and the gate owns retarget semantics, so
  # the existing request is reused instead of paid for twice.
  rm -f "$TMP/state/gate-reruns" "$TMP/state/review-request"
  GH_CALLS_BEFORE_ATTEST="$(grep -c '^pr comment' "$GH_CALLS" || true)"
  GH_MODE=attest_request_present run_pr_v1 "$TMP/out" open --title 'Gate' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  [ "$(grep -c '^pr comment' "$GH_CALLS" || true)" -eq "$GH_CALLS_BEFORE_ATTEST" ] \
    || fail "an existing attest request for this head still bought a second hosted review"
  assert_has "$TMP/out" '"reviewRequest":"existing:https://example.test/pr/7#issuecomment-91"'
  rm -f "$TMP/state/gate-reruns"

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
  # The reuse rules below belong to the contract 2 and 3 client paths, so they
  # run where GitHub and the client both declare contract 3.
  touch "$TMP/state/behavior-version-next"
  run_pr_v3 "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewGateBehaviorContractVersion":3'
  touch "$TMP/state/gate-fresh-active"
  echo 30 >"$TMP/state/gate-in-progress"
  run_pr_v3 "$TMP/out" open --title 'Gate v2' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewGate":{"runId":"77","action":"already-active"}'
  assert_not_has "$TMP/out" '"reviewBudget"'
  [ ! -f "$TMP/state/gate-reruns" ] \
    || fail "behavior v2 open re-ran an evaluation that was already active"
  [ "$(grep -c 'actions/runs?head_sha=' "$GH_CALLS")" -le 3 ] \
    || fail "behavior v2 open repeatedly polled an active evaluation instead of returning control"
  rm -f "$TMP/state/gate-in-progress" "$TMP/state/gate-reruns" "$TMP/state/gate-fresh-active"
  touch "$TMP/state/gate-fresh-active" "$TMP/state/gate-run-unbound"
  echo 3 >"$TMP/state/gate-in-progress"
  run_pr_v3 "$TMP/out" open --title 'Gate v2 rollout' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewGate":{"runId":"77","action":"rerun-requested"}'
  assert_not_has "$TMP/out" '"action":"already-active"'
  grep -q 'rerun 77' "$TMP/state/gate-reruns" 2>/dev/null \
    || fail "behavior v2 open reused an active run from an unbound source revision"
  rm -f "$TMP/state/gate-in-progress" "$TMP/state/gate-reruns" "$TMP/state/gate-fresh-active" "$TMP/state/gate-run-unbound"
  touch "$TMP/state/gate-review-window-active"
  echo 30 >"$TMP/state/gate-in-progress"
  run_pr_v3 "$TMP/out" open --title 'Gate v2 existing request' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewGate":{"runId":"77","action":"already-active"}'
  [ ! -f "$TMP/state/gate-reruns" ] \
    || fail "behavior v2 open did not reuse an existing request's active review window"
  rm -f "$TMP/state/gate-in-progress" "$TMP/state/gate-review-window-active"
  run_pr_v3 "$TMP/out" open --title 'Gate v2' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewGate":{"runId":"77","action":"rerun-requested"}'
  grep -q 'rerun 77' "$TMP/state/gate-reruns" 2>/dev/null \
    || fail "behavior v2 open did not refresh a completed evaluation"
  # behavior-version-next would override the legacy manifest this case needs.
  rm -f "$TMP/state/gate-reruns" "$TMP/state/behavior-version-next"
  touch "$TMP/state/behavior-version-legacy"
  echo 3 >"$TMP/state/gate-in-progress"
  run_pr_v3 "$TMP/out" open --title 'Gate rollout mismatch' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewGate":{"runId":"77","action":"rerun-requested"}'
  grep -q 'rerun 77' "$TMP/state/gate-reruns" 2>/dev/null \
    || fail "open trusted local behavior v2 intent while GitHub still enforced v1"
  rm -f "$TMP/state/gate-reruns" "$TMP/state/behavior-version-legacy"
  touch "$TMP/state/behavior-version-next"
  echo 3 >"$TMP/state/gate-in-progress"
  run_pr_v3 "$TMP/out" open --title 'Expired gate v2' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewGate":{"runId":"77","action":"rerun-requested"}'
  grep -q 'rerun 77' "$TMP/state/gate-reruns" 2>/dev/null \
    || fail "behavior v2 open reused a run whose request-evidence window had expired"
  rm -f "$TMP/state/gate-in-progress" "$TMP/state/behavior-version-next"
  # Contract 4 is supported now; the next unknown one still fails closed.
  jq '.workflowSource.sourceContract.gateBehaviorContractVersion = 5' \
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

  echo "==> a gate behavior contract 3 policy is accepted and reuses the active run"
  touch "$TMP/state/behavior-version-next" "$TMP/state/review-gate" "$TMP/state/pr-exists"
  run_pr_v3 "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewGateBehaviorContractVersion":3'
  touch "$TMP/state/gate-fresh-active"
  echo 30 >"$TMP/state/gate-in-progress"
  run_pr_v3 "$TMP/out" open --title 'Gate v3' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewGate":{"runId":"77","action":"already-active"}'
  [ ! -f "$TMP/state/gate-reruns" ] \
    || fail "behavior v3 open re-ran an evaluation that was already active"
  rm -f "$TMP/state/gate-in-progress" "$TMP/state/gate-fresh-active" "$TMP/state/behavior-version-next"
  rm -f "$TMP/state/review-gate" "$TMP/state/gate-reruns"

  echo "==> open asks the primary reviewer first and records the move to the fallback when it declines"
  # The bounded first-reply wait is the contract 2 and 3 client's; a contract 4
  # client waits for the review instead (its own section below). So this runs
  # where GitHub and the client both declare contract 3.
  touch "$TMP/state/review-gate" "$TMP/state/behavior-version-next"
  rm -f "$TMP/state/gate-reruns" "$TMP/state/review-request" "$TMP/state/fallback-announced"
  : >"$GH_CALLS"
  TOUCHSTONE_REVIEW_RESPONSE_WAIT_SECONDS=1 GH_MODE=primary_quota run_pr_v3 "$TMP/out" open --title 'Declined' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  grep -q '^pr comment' "$GH_CALLS" && grep -q 'touchstone:review-fallback' "$GH_CALLS" \
    || fail "open did not record the fallback on the pull request after the primary declined"
  assert_has "$TMP/out" '"reviewFallback":"fallback"'
  grep -q '^pr comment.*@codex review' "$GH_CALLS" || fail "open did not ask the primary reviewer before recording the fallback"
  # The notice states the gate's rule, never a verdict: it is posted once the
  # re-run is requested, before that run has evaluated anything (AUT-1636).
  assert_not_has "$GH_CALLS" 'authored the verdict'
  assert_has "$GH_CALLS" "when the gate's run evaluates this exact head it reviews it with its own reviewer"
  awk '/actions\/runs\/77\/rerun/ && !r { r = NR } /^pr comment.*touchstone:review-fallback/ { n = NR } END { exit !(r && n > r) }' "$GH_CALLS" \
    || fail "contract 3 posted the fallback notice before asking the gate to re-run"
  # Idempotent per head: a re-run sees its own notice and posts nothing.
  : >"$GH_CALLS"
  TOUCHSTONE_REVIEW_RESPONSE_WAIT_SECONDS=1 GH_MODE=primary_quota run_pr_v3 "$TMP/out" open --title 'Declined' --body-file "$TMP/body"
  assert_rc "$RUN_RC" 0
  # The summary names the state and its remedy, never "fallback" as prose.
  assert_has "$TMP/out" 'the pinned review-gate reviews this head itself'
  assert_has "$TMP/out" 'complete review evidence, not a degraded mode'
  assert_has "$TMP/out" 'answer a finding: touchstone pr answer'
  assert_not_has "$TMP/out" 'review: fallback'
  [ "$(grep -c 'touchstone:review-fallback' "$GH_CALLS")" -eq 0 ] || fail "open posted a second fallback notice for the same head"
  # A primary that answers is left to the gate; nothing is posted.
  rm -f "$TMP/state/review-request" "$TMP/state/fallback-announced"
  : >"$GH_CALLS"
  TOUCHSTONE_REVIEW_RESPONSE_WAIT_SECONDS=1 GH_MODE=primary_replied run_pr_v3 "$TMP/out" open --title 'Replied' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewFallback":"primary"'
  assert_not_has "$GH_CALLS" 'touchstone:review-fallback'
  # No reply within the bound: the gate decides, nothing is posted.
  rm -f "$TMP/state/review-request"
  : >"$GH_CALLS"
  TOUCHSTONE_REVIEW_RESPONSE_WAIT_SECONDS=1 run_pr_v3 "$TMP/out" open --title 'Silent' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewFallback":"pending"'
  assert_not_has "$GH_CALLS" 'touchstone:review-fallback'
  # A gate run Actions refused reviews nothing, so a quota reply posts no
  # notice that the gate reviews the head; the refusal is the report (AUT-1610).
  rm -f "$TMP/state/review-request" "$TMP/state/fallback-announced"
  touch "$TMP/state/gate-job-refused"
  TOUCHSTONE_REVIEW_RESPONSE_WAIT_SECONDS=1 GH_MODE=primary_quota GH_GATE_CONCLUSION=failure run_pr_v3 "$TMP/out" open --title 'Declined' --body-file "$TMP/body"
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'review-gate run 77: Actions refused this job (billing)'
  assert_has "$TMP/out" 'no fallback notice was posted'
  assert_not_has "$TMP/out" 'Watch the review-gate check'
  assert_not_has "$GH_CALLS" 'touchstone:review-fallback'
  rm -f "$TMP/state/gate-job-refused"
  rm -f "$TMP/state/review-gate" "$TMP/state/gate-reruns" "$TMP/state/review-request" "$TMP/state/fallback-announced" \
    "$TMP/state/behavior-version-next"

  echo "==> gate behavior contract 4: open waits here for the review, then wakes the gate once (AUT-793)"
  # A contract-4 gate evaluates once and never polls. open waits on this
  # machine until the primary reviewer answers the head's latest request, or
  # that request passes the pinned gate's evidence deadline, then re-runs the
  # gate exactly once and reports its conclusion without judging it.
  mkdir -p "$TMP/tool-v4/bin" "$TMP/tool-v4/scripts" "$TMP/tool-v4/policy/github"
  cp "$ROOT/bin/touchstone" "$TMP/tool-v4/bin/touchstone"
  cp "$ROOT/scripts/touchstone-pr.sh" "$TMP/tool-v4/scripts/touchstone-pr.sh"
  cp -R "$ROOT/policy/github/." "$TMP/tool-v4/policy/github/"
  cat "$ROOT/VERSION" >"$TMP/tool-v4/VERSION"
  jq --argjson version 4 '.workflowSource.sourceContract.gateBehaviorContractVersion = $version' \
    "$ROOT/policy/github/touchstone-main.json" >"$TMP/tool-v4/policy/github/touchstone-main.json"
  run_pr_v4() {
    local output="$1"
    shift
    : >"$GH_CALLS"
    set +e
    bash "$TMP/tool-v4/bin/touchstone" pr "$@" --project "$TMP/project" >"$output" 2>&1
    RUN_RC=$?
    set -e
  }
  v4_reset() {
    rm -f "$TMP/state/pr-exists" "$TMP/state/pr-body" "$TMP/state/pr-title" "$TMP/state/review-request" \
      "$TMP/state/gate-reruns" "$TMP/state/fallback-announced" "$TMP/state/request-at" \
      "$TMP/state/primary-comment" "$TMP/state/primary-comment-delay" "$TMP/state/primary-review" \
      "$TMP/state/primary-review-delay" "$TMP/state/primary-dashboard" "$TMP/state/gate-in-progress" \
      "$TMP/state/gate-fresh-active" "$TMP/state/gate-after-rerun" "$TMP/state/gate-rerun-running" \
      "$TMP/state/review-gate-no-deadline" "$TMP/state/evidence-reruns" "$TMP/state/evidence-after-rerun" \
      "$TMP/state/request-edited-at" "$TMP/state/primary-review-stale" "$TMP/state/primary-review-offset" \
      "$TMP/state/abbrev-resolves-elsewhere" "$TMP/state/gate-job-refused"
  }
  # Exactly one re-run per wake and exactly one request per head, counted.
  v4_reruns() { if [ -f "$TMP/state/gate-reruns" ]; then grep -c 'rerun 77' "$TMP/state/gate-reruns" || true; else echo 0; fi; }
  v4_requests() { grep -c '^pr comment.*@codex review' "$GH_CALLS" || true; }
  touch "$TMP/state/review-gate"
  v4_reset
  touch "$TMP/state/pr-exists"
  run_pr_v4 "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewGateBehaviorContractVersion":4'

  # The primary's review lands two polls into the wait: the wait is still
  # reading the review surface when it arrives, and it wakes the gate once.
  v4_reset
  date -u +%Y-%m-%dT%H:%M:%SZ >"$TMP/state/request-at"
  touch "$TMP/state/primary-review"
  echo 2 >"$TMP/state/primary-review-delay"
  run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewWait":{"wokeBy":"primary-review","evidenceDeadlineSeconds":600}'
  assert_has "$TMP/out" '"reviewGate":{"runId":"77","action":"rerun-requested","status":"completed","conclusion":"success"}'
  assert_has "$TMP/out" '"reviewFallback":"primary"'
  [ "$(v4_reruns)" -eq 1 ] || fail "contract 4 re-ran the gate $(v4_reruns) times for one wake; expected exactly one"
  [ "$(v4_requests)" -eq 1 ] || fail "contract 4 posted $(v4_requests) review requests for one head; expected exactly one"
  [ "$(grep -c 'comments{totalCount}' "$GH_CALLS" || true)" -ge 2 ] \
    || fail "contract 4 stopped polling the review surface before the review arrived"
  grep -q 'workflows/review-gate.yml?ref=' "$GH_CALLS" \
    || fail "contract 4 did not derive its deadline from the pinned review-gate"

  # No reply at all: the request is past its evidence deadline, so the gate
  # is woken once to ask its fallback. The failure it reports is the gate's
  # verdict, reported as it stands, not a failure of open.
  v4_reset
  GH_GATE_CONCLUSION=failure run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewWait":{"wokeBy":"deadline","evidenceDeadlineSeconds":600}'
  assert_has "$TMP/out" '"reviewFallback":"pending"'
  assert_has "$TMP/out" '"status":"completed","conclusion":"failure"'
  [ "$(v4_reruns)" -eq 1 ] || fail "contract 4 re-ran the gate $(v4_reruns) times at the deadline; expected exactly one"
  [ "$(v4_requests)" -eq 1 ] || fail "contract 4 posted $(v4_requests) review requests at the deadline; expected exactly one"

  # The status dashboard is the primary's comment but never a reply: alone,
  # it must not wake the wait. With the request still fresh, only the wait's
  # own bound ends it.
  v4_reset
  touch "$TMP/state/primary-dashboard"
  run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"wokeBy":"deadline"'
  assert_not_has "$TMP/out" '"wokeBy":"primary-comment"'
  v4_reset
  touch "$TMP/state/primary-dashboard"
  date -u +%Y-%m-%dT%H:%M:%SZ >"$TMP/state/request-at"
  TOUCHSTONE_REVIEW_WAIT_MAX_SECONDS=1 run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"wokeBy":"wait-bound"'
  [ "$(v4_reruns)" -eq 1 ] || fail "contract 4 re-ran the gate $(v4_reruns) times at its wait bound; expected exactly one"

  # A quota notice is a reply: it wakes the gate at once, and the move to
  # the gate's fallback is recorded once.
  v4_reset
  GH_MODE=primary_quota run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"wokeBy":"primary-comment"'
  assert_has "$TMP/out" '"reviewFallback":"fallback"'
  [ "$(grep -c '^pr comment.*touchstone:review-fallback' "$GH_CALLS" || true)" -eq 1 ] \
    || fail "contract 4 did not record the move to the fallback exactly once"
  [ "$(v4_reruns)" -eq 1 ] || fail "contract 4 re-ran the gate $(v4_reruns) times after a quota notice; expected exactly one"
  # Posted after the woken run, and claiming no verdict (AUT-1636).
  awk '/actions\/runs\/77\/rerun/ && !r { r = NR } /^pr comment.*touchstone:review-fallback/ { n = NR } END { exit !(r && n > r) }' "$GH_CALLS" \
    || fail "contract 4 posted the fallback notice before it woke the gate"
  assert_not_has "$GH_CALLS" 'authored the verdict'
  # A notice GitHub refuses is not a lost gate observation. The woken run has
  # already concluded by the time the notice is posted, so failing here threw
  # that away and asked for a retry that would wake the gate a second time --
  # a second fallback review of a head it had already evaluated (AUT-1610,
  # routed from touchstone#1210).
  v4_reset
  touch "$TMP/state/fallback-comment-fails"
  GH_MODE=primary_quota run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" 'Could not post the review-fallback notice on PR #7: gh: Server Error (HTTP 502)'
  assert_has "$TMP/out" 'post a comment carrying <!-- touchstone:review-fallback head='
  assert_has "$TMP/out" '"reviewGate":{"runId":"77","action":"rerun-requested","status":"completed","conclusion":"success"}'
  assert_has "$TMP/out" '"reviewFallback":"fallback"'
  [ "$(v4_reruns)" -eq 1 ] || fail "a refused fallback notice cost $(v4_reruns) gate runs; expected the one already woken"
  rm -f "$TMP/state/fallback-comment-fails"
  # A woken run Actions refused reviews nothing: no notice (AUT-1610).
  v4_reset
  touch "$TMP/state/gate-job-refused"
  GH_MODE=primary_quota GH_GATE_CONCLUSION=failure run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'review-gate run 77: Actions refused this job (billing)'
  assert_has "$TMP/out" 'no fallback notice was posted'
  assert_not_has "$GH_CALLS" 'touchstone:review-fallback'

  # A contract-4 run is short and never the evaluator of record: a run still
  # in progress is waited on to completion and then re-run, not reused.
  v4_reset
  touch "$TMP/state/gate-fresh-active"
  echo 3 >"$TMP/state/gate-in-progress"
  run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"action":"rerun-requested"'
  assert_not_has "$TMP/out" '"action":"already-active"'
  [ "$(v4_reruns)" -eq 1 ] || fail "contract 4 re-ran an in-progress gate $(v4_reruns) times; expected once, after it completed"

  # The request `pr answer` left is reused, never doubled, and the wait
  # anchors on it.
  v4_reset
  touch "$TMP/state/pr-exists"
  GH_MODE=attest_request_present run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewRequest":"existing:https://example.test/pr/7#issuecomment-91"'
  assert_has "$TMP/out" '"wokeBy":"deadline"'
  [ "$(v4_requests)" -eq 0 ] || fail "contract 4 posted a second review request beside the attest request"
  [ "$(v4_reruns)" -eq 1 ] || fail "contract 4 re-ran the gate $(v4_reruns) times for a reused request; expected exactly one"

  # The deadline is the pinned gate's; a gate that declares none fails closed
  # rather than waking on a deadline invented here.
  v4_reset
  touch "$TMP/state/review-gate-no-deadline"
  run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'declares no REVIEW_EVIDENCE_WAIT_SECONDS'
  [ "$(v4_reruns)" -eq 0 ] || fail "contract 4 woke the gate without a derivable evidence deadline"

  # A woken run that outlasts the follow is reported still running; the gate
  # decides on its own.
  v4_reset
  echo 99 >"$TMP/state/gate-rerun-running"
  TOUCHSTONE_GATE_ATTEMPTS=3 run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"in_progress","conclusion":null'
  [ "$(v4_reruns)" -eq 1 ] || fail "contract 4 re-ran the gate $(v4_reruns) times while following it; expected exactly one"

  # `answer` reaches the same wait through await-review: it posts nothing and
  # wakes the gate once.
  v4_reset
  touch "$TMP/state/pr-exists"
  GH_MODE=attest_request_present run_pr_v4 "$TMP/out" await-review 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"operation":"await-review","status":"woken"'
  assert_has "$TMP/out" '"wokeBy":"deadline"'
  [ "$(grep -c '^pr comment' "$GH_CALLS" || true)" -eq 0 ] || fail "await-review posted a comment"
  [ "$(v4_reruns)" -eq 1 ] || fail "await-review re-ran the gate $(v4_reruns) times; expected exactly one"

  echo "==> the contract-4 wait wakes only on a reply bound to this head (AUT-1636)"
  # A late reply to the previous head -- a formal review GitHub bound to the
  # old commit, or a comment naming it as the reviewed commit -- ended the
  # wait and spent its one re-run before this head's review arrived. Each
  # request here is past its deadline, so a wait that does not wake on the
  # stale reply ends on the deadline at once.
  head_abbrev="$(printf '%s' "$HEAD_SHA" | cut -c1-10)"
  stale_abbrev="$(printf '%s' "$head_abbrev" | tr '0123456789abcdef' '123456789abcdef0')"
  verdict_comment() { printf 'Codex Review: Didn'\''t find any major issues.\n\n**Reviewed commit:** `%s`\n' "$1" >"$TMP/state/primary-comment"; }
  v4_reset
  touch "$TMP/state/primary-review-stale"
  run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"wokeBy":"deadline"'
  assert_not_has "$TMP/out" '"wokeBy":"primary-review"'
  [ "$(v4_reruns)" -eq 1 ] || fail "contract 4 re-ran the gate $(v4_reruns) times past a stale review; expected exactly one"
  v4_reset
  verdict_comment "$stale_abbrev"
  run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"wokeBy":"deadline"'
  assert_not_has "$TMP/out" '"wokeBy":"primary-comment"'
  # The same verdict naming this head wakes it, once GitHub resolves the
  # abbreviation to the head -- the resolution the gate itself makes.
  v4_reset
  verdict_comment "$head_abbrev"
  run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"wokeBy":"primary-comment"'
  assert_has "$TMP/out" '"reviewFallback":"primary"'
  assert_has "$GH_CALLS" "/commits/$head_abbrev"
  # A prefix of the head that GitHub resolves to another commit is that
  # commit's verdict, not this head's.
  v4_reset
  verdict_comment "$head_abbrev"
  touch "$TMP/state/abbrev-resolves-elsewhere"
  run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"wokeBy":"deadline"'
  # A stale reply first does not hide this head's review behind it.
  v4_reset
  verdict_comment "$stale_abbrev"
  touch "$TMP/state/primary-review"
  run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"wokeBy":"primary-review"'
  # A security-review quota notice still ends the wait, as before.
  v4_reset
  printf 'Security review usage limit reached\n' >"$TMP/state/primary-comment"
  run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"wokeBy":"primary-comment"'

  echo "==> an edited request anchors its replies at the edit, the instant it is clocked from (AUT-1636)"
  # Created at 17:00 and edited at 17:05 into this head's request: a review of
  # this head submitted at 17:01 answered something asked before the request
  # existed. Both are long past, so a wait that does not count it ends on the
  # deadline; one submitted after the edit still wakes it.
  v4_reset
  echo '2026-08-27T17:05:00Z' >"$TMP/state/request-edited-at"
  touch "$TMP/state/primary-review"
  run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"wokeBy":"deadline"'
  assert_not_has "$TMP/out" '"wokeBy":"primary-review"'
  v4_reset
  echo '2026-08-27T17:05:00Z' >"$TMP/state/request-edited-at"
  touch "$TMP/state/primary-review"
  echo 600 >"$TMP/state/primary-review-offset"
  run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"wokeBy":"primary-review"'

  echo "==> an explicit error reply wakes the wait labelled as the fallback's, not the primary's (AUT-1636)"
  # The pinned gate reads the primary's latest utterance, when it follows the
  # head's request and matches its provider-error signature, as "cannot
  # answer", and its fallback reviews the head (touchstone#1190).
  error_comment() {
    printf 'Codex Review: Something went wrong. Try again later by commenting “@codex review”.\n\n```\nProvided git ref %s does not exist\n```\n' "$HEAD_SHA" >"$TMP/state/primary-comment"
  }
  v4_reset
  error_comment
  run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewWait":{"wokeBy":"primary-error","evidenceDeadlineSeconds":600}'
  assert_has "$TMP/out" '"reviewFallback":"fallback"'
  assert_has "$TMP/out" 'with an error, so the pinned review-gate reviews it itself'
  assert_has "$TMP/out" "touchstone pr answer 7 --finding <id>"
  [ "$(v4_reruns)" -eq 1 ] || fail "contract 4 re-ran the gate $(v4_reruns) times after an error reply; expected exactly one"
  # The error records the same notice, once, after the woken run, naming the
  # error rather than a quota (AUT-1636).
  [ "$(grep -c '^pr comment.*touchstone:review-fallback' "$GH_CALLS" || true)" -eq 1 ] \
    || fail "an error reply did not record the fallback notice exactly once"
  assert_has "$GH_CALLS" 'The primary reviewer answered the latest review request with an error'
  assert_not_has "$GH_CALLS" 'replied that it is at capacity'
  awk '/actions\/runs\/77\/rerun/ && !r { r = NR } /^pr comment.*touchstone:review-fallback/ { n = NR } END { exit !(r && n > r) }' "$GH_CALLS" \
    || fail "contract 4 posted the error's fallback notice before it woke the gate"
  v4_reset
  error_comment
  run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body"
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" 'not a degraded mode (the primary reviewer answered with an error)'
  # The rule is recency: this head's review after the error is the latest
  # utterance, so the primary answered after all.
  v4_reset
  error_comment
  touch "$TMP/state/primary-review"
  echo 120 >"$TMP/state/primary-review-offset"
  run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"wokeBy":"primary-review"'
  assert_has "$TMP/out" '"reviewFallback":"primary"'

  echo "==> wake-review-gate follows a still-running contract-4 run to completion, then re-runs it once (AUT-1636)"
  # `answer --finding` requests no review, so it needs the wake without the
  # wait: the run in progress may have read the body before the answer.
  v4_reset
  touch "$TMP/state/pr-exists"
  echo 3 >"$TMP/state/gate-in-progress"
  run_pr_v4 "$TMP/out" wake-review-gate 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"operation":"wake-review-gate","status":"woken"'
  assert_has "$TMP/out" '"action":"rerun-requested","status":"completed","conclusion":"success"'
  assert_not_has "$TMP/out" '"reviewWait"'
  assert_not_has "$TMP/out" '"reviewFallback"'
  [ ! -f "$TMP/state/gate-in-progress" ] || fail "wake-review-gate re-ran the gate before the running attempt completed"
  [ "$(v4_reruns)" -eq 1 ] || fail "wake-review-gate re-ran the gate $(v4_reruns) times; expected exactly one"
  assert_not_has "$GH_CALLS" 'comments{totalCount}'
  [ "$(grep -c '^pr comment' "$GH_CALLS" || true)" -eq 0 ] || fail "wake-review-gate posted a comment"
  touch "$TMP/state/behavior-version-next"
  v4_reset
  touch "$TMP/state/pr-exists"
  run_pr_v3 "$TMP/out" wake-review-gate 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'does not implement gate behavior contract 4'
  [ "$(v4_reruns)" -eq 0 ] || fail "wake-review-gate woke a contract-3 gate"
  rm -f "$TMP/state/behavior-version-next"

  # Polling spends the REST quota every agent on the machine shares
  # (AUT-1638). `sleep` is stubbed to record what the command asks for, so a
  # schedule is asserted exactly and five minutes of waiting cost nothing.
  mkdir -p "$TMP/clock-bin"
  cat >"$TMP/clock-bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$SLEEP_LOG"
[ "${SLEEP_REAL:-false}" = false ] || exec /bin/sleep "$1"
SLEEP
  chmod +x "$TMP/clock-bin/sleep"

  echo "==> a gate follow backs off inside its unchanged deadline (AUT-1638)"
  # The woken run never finishes. At the default five-second delay the follow
  # keeps its 60 x 5 s deadline but reads nine times rather than sixty: its
  # waits double from 5 s to the 60 s cap, the last cut to land on 300 s. The
  # leading 5 s is the new-attempt wait, which sees the attempt on its second
  # read.
  v4_reset
  echo 999 >"$TMP/state/gate-rerun-running"
  : >"$TMP/sleeps"
  PATH="$TMP/clock-bin:$PATH" SLEEP_LOG="$TMP/sleeps" TOUCHSTONE_GATE_RETRY_DELAY=5 TOUCHSTONE_GATE_ATTEMPTS=60 \
    run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"in_progress","conclusion":null'
  follow_sleeps="$(paste -sd' ' - <"$TMP/sleeps")"
  [ "$follow_sleeps" = "5 5 10 20 40 60 60 60 45" ] \
    || fail "the gate follow did not back off to its deadline: slept '$follow_sleeps', expected '5 5 10 20 40 60 60 60 45'"
  follow_total="$(tail -n +2 "$TMP/sleeps" | awk '{ total += $1 } END { print total + 0 }')"
  [ "$follow_total" -eq 300 ] || fail "the gate follow waited ${follow_total}s; its deadline is 60 x 5 = 300s, no more and no less"
  [ "$(v4_reruns)" -eq 1 ] || fail "the backed-off follow re-ran the gate $(v4_reruns) times; expected exactly one"

  echo "==> a zero follow delay does not busy-loop the review wait (AUT-1636)"
  # The review wait's interval was three follow delays, so zero at
  # TOUCHSTONE_GATE_RETRY_DELAY=0. It is floored at a second: with the request
  # fresh and a two-second bound, the wait sleeps a second at a time and ends
  # on the bound. Real sleeps, so the case costs two seconds.
  v4_reset
  date -u +%Y-%m-%dT%H:%M:%SZ >"$TMP/state/request-at"
  : >"$TMP/sleeps"
  PATH="$TMP/clock-bin:$PATH" SLEEP_LOG="$TMP/sleeps" SLEEP_REAL=true TOUCHSTONE_REVIEW_WAIT_MAX_SECONDS=2 \
    run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"wokeBy":"wait-bound"'
  if grep -qvx '[1-9][0-9]*' "$TMP/sleeps"; then
    fail "the review wait slept under a second between polls at a zero follow delay: $(paste -sd' ' - <"$TMP/sleeps")"
  fi
  [ "$(wc -l <"$TMP/sleeps" | tr -d ' ')" -le 3 ] \
    || fail "the review wait slept $(wc -l <"$TMP/sleeps" | tr -d ' ') times inside a two-second bound"

  echo "==> the review wait spaces its next poll from the clock after the poll (AUT-1648)"
  # The poll's own reads outlast the time left before the wait ends: five
  # seconds of bound, an eight-second poll. Spacing the next read from the
  # instant the poll started -- the clock read before those reads -- put it
  # that far past the end; the spacing is measured from the clock as it is
  # when the spacing begins, so there is none left to take here. The decision
  # to end the wait keeps the poll's own instant, so nothing ends early: the
  # bound is still what wakes it. Sleeps are recorded in the call log, so a
  # wait scheduled before the gate is woken is told from the gate follow's.
  v4_reset
  date -u +%Y-%m-%dT%H:%M:%SZ >"$TMP/state/request-at"
  PATH="$TMP/clock-bin:$PATH" SLEEP_LOG="$GH_CALLS" GH_SLOW_SURFACE_SECONDS=8 \
    TOUCHSTONE_REVIEW_WAIT_MAX_SECONDS=5 TOUCHSTONE_GATE_RETRY_DELAY=5 \
    run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"wokeBy":"wait-bound"'
  review_wait_sleeps="$(awk '/actions\/runs\/77\/rerun/ { exit } /^[0-9]+$/ { print }' "$GH_CALLS" | paste -sd' ' -)"
  [ -z "$review_wait_sleeps" ] \
    || fail "the review wait scheduled a wait (${review_wait_sleeps}s) from the clock as it was before its poll, with its bound already reached"

  echo "==> the review wait's REST reads do not grow with its polls (AUT-1638)"
  # One GraphQL count per poll says whether the review surface changed, and
  # the REST observation runs on the first poll and when a count moves. A
  # review landing two polls in and one landing eight polls in therefore cost
  # the same REST reads. The counts printed here are the PR's measurement.
  v4_rest_calls() { grep '^api ' "$GH_CALLS" | grep -vc '^api graphql' || true; }
  v4_rest_for_review_after() {
    v4_reset
    date -u +%Y-%m-%dT%H:%M:%SZ >"$TMP/state/request-at"
    touch "$TMP/state/primary-review"
    echo "$1" >"$TMP/state/primary-review-delay"
    : >"$TMP/sleeps"
    PATH="$TMP/clock-bin:$PATH" SLEEP_LOG="$TMP/sleeps" TOUCHSTONE_REVIEW_WAIT_MAX_SECONDS=30 \
      run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
    assert_rc "$RUN_RC" 0
    assert_has "$TMP/out" '"wokeBy":"primary-review"'
    V4_REST_CALLS="$(v4_rest_calls)"
    echo "  REST calls for a contract-4 open whose review lands $1 polls in: $V4_REST_CALLS ($(grep -c '^api graphql' "$GH_CALLS" || true) GraphQL api calls)"
  }
  v4_rest_for_review_after 2
  rest_review_after_2="$V4_REST_CALLS"
  v4_rest_for_review_after 8
  rest_review_after_8="$V4_REST_CALLS"
  [ "$rest_review_after_2" -eq "$rest_review_after_8" ] \
    || fail "the review wait's REST reads grew with its polls: $rest_review_after_2 for a review two polls in, $rest_review_after_8 for one eight polls in"

  echo "==> a rate-limited GitHub request stops the command and names the reset; it is never retried (AUT-1638)"
  # Every session on the machine shares one token's quota, and a retry spends
  # it again the moment it resets. The command stops, reads the reset from the
  # free rate_limit endpoint, and says when to re-run; the refusal is no
  # verdict on anything.
  v4_reset
  touch "$TMP/state/pr-exists"
  GH_RATE_LIMITED='rules/branches/' run_pr_v4 "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" '"schema":"touchstone.pr/v2","operation":"status","status":"failed"'
  assert_has "$TMP/out" "GitHub's REST rate limit for this token is exhausted until 2026-09-11T00:21:13Z; re-run the same command after that"
  assert_has "$TMP/out" '"rateLimit":{"limit":"core","rerunAfter":"2026-09-11T00:21:13Z"}'
  [ "$(grep -c 'rules/branches/' "$GH_CALLS" || true)" -eq 1 ] \
    || fail "a rate-limited read was retried: $(grep -c 'rules/branches/' "$GH_CALLS" || true) requests"
  assert_has "$GH_CALLS" 'rate_limit'
  # A secondary limit names no reset: the command still stops at once.
  GH_RATE_LIMITED='rules/branches/' GH_RATE_LIMIT_KIND=secondary run_pr_v4 "$TMP/out" status 7
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" "GitHub's secondary rate limit refused this token's request; re-run the same command after"
  [ "$(grep -c 'rules/branches/' "$GH_CALLS" || true)" -eq 1 ] \
    || fail "a read refused by the secondary limit was retried: $(grep -c 'rules/branches/' "$GH_CALLS" || true) requests"
  # GraphQL has its own quota, and the reset named is that one's.
  GH_RATE_LIMITED='pr view' GH_RATE_LIMIT_KIND=graphql run_pr_v4 "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" "GitHub's GraphQL rate limit for this token is exhausted until 2026-09-11T00:26:40Z"
  assert_has "$TMP/out" '"rateLimit":{"limit":"graphql","rerunAfter":"2026-09-11T00:26:40Z"}'
  [ "$(grep -c '^pr view' "$GH_CALLS" || true)" -eq 1 ] \
    || fail "a rate-limited GraphQL read was retried: $(grep -c '^pr view' "$GH_CALLS" || true) requests"
  # An unreadable rate_limit still stops the command; it only cannot say when.
  touch "$TMP/state/rate-limit-unreadable"
  GH_RATE_LIMITED='rules/branches/' run_pr_v4 "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'gh api rate_limit could not say until when'
  assert_has "$TMP/out" '"rateLimit":{"limit":"unknown","rerunAfter":'
  rm -f "$TMP/state/rate-limit-unreadable"
  # A refused mutation stops open too, naming the PR it already holds, and
  # reports no gate verdict: the re-run was never made.
  v4_reset
  GH_RATE_LIMITED='actions/runs/77/rerun' run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" "GitHub's REST rate limit for this token is exhausted until 2026-09-11T00:21:13Z"
  assert_has "$TMP/out" '"pullRequest":7'
  assert_not_has "$TMP/out" '"conclusion"'
  [ "$(grep -c 'actions/runs/77/rerun' "$GH_CALLS" || true)" -eq 1 ] \
    || fail "a rate-limited re-run was retried: $(grep -c 'actions/runs/77/rerun' "$GH_CALLS" || true) requests"
  [ "$(v4_reruns)" -eq 0 ] || fail "a rate-limited re-run was recorded as made"
  # So does a mutation gh makes on its own terms, such as the body edit of a
  # reused pull request: no generic failure, no reconciliation read after it.
  v4_reset
  touch "$TMP/state/pr-exists"
  printf 'An older body.\n' >"$TMP/state/pr-body"
  GH_RATE_LIMITED='pr edit' run_pr_v4 "$TMP/out" open --title 'Gate v4' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" "GitHub's REST rate limit for this token is exhausted until 2026-09-11T00:21:13Z"
  assert_has "$TMP/out" '"rateLimit":{"limit":"core"'
  [ "$(grep -c '^pr edit' "$GH_CALLS" || true)" -eq 1 ] \
    || fail "a rate-limited body edit was retried: $(grep -c '^pr edit' "$GH_CALLS" || true) requests"
  v4_reset

  echo "==> a rate limit is recognized where no temporary directory is writable (AUT-1648)"
  # A GraphQL refusal is reported on stderr alone -- no JSON body on stdout --
  # so a read-only sandbox, which cannot capture stderr to a scratch file, saw
  # nothing to match and carried on retrying into the exhausted quota.
  v4_reset
  touch "$TMP/state/pr-exists"
  TMPDIR="$TMP/does-not-exist" GH_RATE_LIMITED='pr view' GH_RATE_LIMIT_KIND=graphql \
    run_pr_v4 "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" "GitHub's GraphQL rate limit for this token is exhausted until 2026-09-11T00:26:40Z"
  assert_has "$TMP/out" '"rateLimit":{"limit":"graphql","rerunAfter":"2026-09-11T00:26:40Z"}'
  [ "$(grep -c '^pr view' "$GH_CALLS" || true)" -eq 1 ] \
    || fail "a rate-limited read without a writable temporary directory was retried: $(grep -c '^pr view' "$GH_CALLS" || true) requests"

  echo "==> both quotas exhausted reports the one the refused request spent (AUT-1648)"
  # Reading core first named the REST reset for a GraphQL refusal, sending the
  # driver back five minutes before its quota could answer.
  v4_reset
  touch "$TMP/state/pr-exists"
  GH_RATE_LIMITED='pr view' GH_RATE_LIMIT_KIND=graphql GH_RATE_LIMIT_EXHAUSTED=both \
    run_pr_v4 "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" '"rateLimit":{"limit":"graphql","rerunAfter":"2026-09-11T00:26:40Z"}'
  assert_not_has "$TMP/out" '"limit":"core"'
  # A REST refusal with the same two quotas spent still names the REST reset.
  GH_RATE_LIMITED='rules/branches/' GH_RATE_LIMIT_EXHAUSTED=both \
    run_pr_v4 "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" '"rateLimit":{"limit":"core","rerunAfter":"2026-09-11T00:21:13Z"}'

  echo "==> the first request's quota read names the checkout's own host (AUT-1648)"
  # The repository read is the first request every command makes, so a refusal
  # of it leaves GitHub's answer for the host unknown; reading github.com's
  # quota there reports a reset an Enterprise token never had.
  v4_reset
  touch "$TMP/state/pr-exists"
  git -C "$TMP/project" remote set-url origin https://github.example.com/autumngarage/current.git
  GH_RATE_LIMITED='repo view' run_pr_v4 "$TMP/out" status 7 --json
  git -C "$TMP/project" remote set-url origin "$TMP/origin.git"
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" '"rateLimit":{"limit":"core","rerunAfter":"2026-09-11T00:21:13Z"}'
  assert_has "$GH_CALLS" 'api --hostname github.example.com rate_limit'
  v4_reset

  # Contract 3 is unchanged: no local wait, no review read, no deadline read,
  # and the same result document as before. A repository's gate stays
  # contract 3 until its repin is applied, and so does its policy.
  touch "$TMP/state/behavior-version-next"
  v4_reset
  touch "$TMP/state/pr-exists"
  GH_MODE=attest_request_present run_pr_v3 "$TMP/out" await-review 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'does not implement gate behavior contract 4'
  [ "$(v4_reruns)" -eq 0 ] || fail "await-review woke a contract-3 gate"
  v4_reset
  TOUCHSTONE_REVIEW_RESPONSE_WAIT_SECONDS=1 GH_MODE=primary_replied run_pr_v3 "$TMP/out" open --title 'Gate v3' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"reviewFallback":"primary"'
  assert_has "$TMP/out" '"reviewGate":{"runId":"77","action":"rerun-requested"}'
  assert_not_has "$TMP/out" '"reviewWait"'
  assert_not_has "$GH_CALLS" 'pulls/7/reviews'
  assert_not_has "$GH_CALLS" 'workflows/review-gate.yml?ref='
  v4_reset
  rm -f "$TMP/state/review-gate" "$TMP/state/behavior-version-next"

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

  echo "==> open re-runs delivery evidence only when no run for this head read the current body (AUT-1632)"
  # Unchanged body, and run 80 started after the body's last edit: it read
  # this body at this head, so it is the verdict and nothing is re-run.
  rm -f "$TMP/state/evidence-reruns" "$TMP/state/evidence-after-rerun" "$TMP/state/review-request"
  cp "$TMP/body2" "$TMP/state/pr-body"
  : >"$GH_CALLS"
  GH_PR_LAST_EDITED_AT_JSON='"2026-08-26T21:00:00Z"' run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body2"
  assert_rc "$RUN_RC" 0
  assert_has "$GH_CALLS" 'lastEditedAt'
  [ ! -f "$TMP/state/evidence-reruns" ] \
    && ok "an unchanged body whose run already read it is not re-run" \
    || fail "an unchanged body re-ran a delivery-evidence run that had already read it"
  assert_has "$TMP/out" 'Delivery evidence accepted by run 80 before hosted review.'
  assert_has "$TMP/out" 'already read this body at this head'

  # A body this command edits is always re-run, however fresh the run looks:
  # no run can have read an edit made a moment ago.
  rm -f "$TMP/state/evidence-reruns" "$TMP/state/evidence-after-rerun" "$TMP/state/review-request"
  printf 'Original evidence body.\n' >"$TMP/state/pr-body"
  GH_PR_LAST_EDITED_AT_JSON='"2026-08-26T21:00:00Z"' run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body2"
  assert_rc "$RUN_RC" 0
  grep -q 'rerun 80' "$TMP/state/evidence-reruns" 2>/dev/null \
    && ok "a body edited by open is re-run even when an earlier run looks fresh" \
    || fail "a body edited by open was not re-run"

  # Unchanged here, but edited on GitHub after run 80 started: run 80 read an
  # older body, so it is never taken as the verdict without a re-run.
  rm -f "$TMP/state/evidence-reruns" "$TMP/state/evidence-after-rerun" "$TMP/state/review-request"
  cp "$TMP/body2" "$TMP/state/pr-body"
  GH_PR_LAST_EDITED_AT_JSON='"2026-08-27T17:00:00Z"' run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body2"
  assert_rc "$RUN_RC" 0
  grep -q 'rerun 80' "$TMP/state/evidence-reruns" 2>/dev/null \
    && ok "a run that started before the body's last edit is re-run" \
    || fail "a run that started before the body's last edit was taken as the verdict"

  # Edited in the same second run 80 started: whole-second timestamps cannot
  # order the edit against the run's read of the body, so run 80 is re-run.
  rm -f "$TMP/state/evidence-reruns" "$TMP/state/evidence-after-rerun" "$TMP/state/review-request"
  cp "$TMP/body2" "$TMP/state/pr-body"
  GH_EVIDENCE_STARTED_AT='2026-08-26T22:20:00Z' GH_PR_LAST_EDITED_AT_JSON='"2026-08-26T22:20:00Z"' \
    run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body2"
  assert_rc "$RUN_RC" 0
  grep -q 'rerun 80' "$TMP/state/evidence-reruns" 2>/dev/null \
    && ok "a run that started in the same second as the body's last edit is re-run" \
    || fail "a run that started in the same second as the body's last edit was taken as the verdict"

  # When the body's change time cannot be read, open re-runs rather than trust
  # an older run: an unknown time fails toward an extra run.
  rm -f "$TMP/state/evidence-reruns" "$TMP/state/evidence-after-rerun" "$TMP/state/review-request"
  touch "$TMP/state/body-timing-unavailable"
  GH_PR_LAST_EDITED_AT_JSON='"2026-08-26T21:00:00Z"' run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body2"
  assert_rc "$RUN_RC" 0
  grep -q 'rerun 80' "$TMP/state/evidence-reruns" 2>/dev/null \
    && ok "an unreadable body change time re-runs delivery evidence" \
    || fail "an unreadable body change time skipped the delivery-evidence re-run"
  rm -f "$TMP/state/body-timing-unavailable"

  rm -f "$TMP/state/evidence-reruns" "$TMP/state/evidence-after-rerun" "$TMP/state/review-request"
  GH_MODE=delivery_new_run_after_rerun run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body2"
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" 'Delivery evidence accepted by run 84 before hosted review.'
  grep -q 'rerun 80' "$TMP/state/evidence-reruns" 2>/dev/null \
    || fail "the existing evidence run was not refreshed before the overlapping new run"
  [ "$(wc -l <"$TMP/state/review-request" | tr -d ' ')" -eq 1 ] \
    && ok "a distinct newer evidence run starts at attempt one without duplicating hosted review" \
    || fail "a distinct newer evidence run was rejected or requested hosted review more than once"

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
  # The PR exists at this point: a failure that hides it sends the operator
  # towards a duplicate PR or a deleted branch with an open PR on it (AUT-1038).
  assert_has "$TMP/out" 'PR #7 exists at https://example.test/pr/7'
  GH_MODE=delivery_rerun_failure run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body4" --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" '"status":"failed"'
  assert_has "$TMP/out" "\"pullRequest\":7,\"url\":\"https://example.test/pr/7\",\"head\":\"$HEAD_SHA\"}"
  echo "==> a failure before any PR exists names none"
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body4" --expect-branch not-this-branch --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" '"status":"failed"'
  assert_not_has "$TMP/out" '"pullRequest":'

  echo "==> a wait stops the moment the PR is closed instead of polling for a run that cannot come (AUT-511)"
  rm -f "$TMP/state/evidence-reruns" "$TMP/state/evidence-after-rerun" "$TMP/state/review-request"
  touch "$TMP/state/wait-closed"
  TOUCHSTONE_GATE_ATTEMPTS=3 run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body4"
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'closed without merging while this command was waiting'
  assert_has "$TMP/out" 'PR #7 exists at https://example.test/pr/7'
  assert_not_has "$TMP/out" 'retrying in'
  assert_not_has "$GH_CALLS" 'actions/runs?head_sha='
  rm -f "$TMP/state/wait-closed"
  echo "==> a wait stops the moment the head moves, naming the live head"
  touch "$TMP/state/wait-moved"
  TOUCHSTONE_GATE_ATTEMPTS=3 run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body4"
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" "moved from $HEAD_SHA to moved-head while this command was waiting"
  assert_not_has "$TMP/out" 'retrying in'
  rm -f "$TMP/state/wait-moved"
  echo "==> a wait stops when the PR is retargeted or its base advances: the binding cannot succeed past either"
  touch "$TMP/state/wait-retargeted"
  TOUCHSTONE_GATE_ATTEMPTS=3 run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body4"
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'was retargeted from main to release while this command was waiting'
  assert_not_has "$TMP/out" 'retrying in'
  rm -f "$TMP/state/wait-retargeted"
  touch "$TMP/state/wait-base-advanced"
  TOUCHSTONE_GATE_ATTEMPTS=3 run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body4"
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" "base main advanced from $GH_BASE_SHA to advanced-base-sha while this command was waiting"
  assert_not_has "$TMP/out" 'retrying in'
  rm -f "$TMP/state/wait-base-advanced"

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
  # AUT-1482. `pr answer` posts its own request for this head when an answer
  # resolves the last thread; it carries the attest marker, not the pr-open
  # one. Scanning only for the pr-open marker posted a SECOND "@codex review"
  # for the same head -- two hosted reviews of one diff, billed twice.
  # Observed live on touchstone#1174: attest at 13:35:03, pr-open at 13:36:00.
  #
  # Reuse is restricted to a base with a pinned gate. Without one, the binding
  # re-read is the only thing verifying coordinates, and the attest marker
  # carries no base for it to verify -- so here the request is posted, not
  # reused. Nothing is lost: `pr answer` writes attest requests only under gate
  # contracts 3 and 4, which is exactly where a gate exists.
  rm -f "$TMP/state/review-request"
  GH_MODE=attest_request_present run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  [ "$(grep -c '^pr comment' "$GH_CALLS")" -eq 1 ] \
    || fail "an attest request was reused on a base with no gate to verify it against"

  # Head-scoped: an attest request for a DIFFERENT head is not this head's.
  rm -f "$TMP/state/review-request"
  GH_MODE=attest_request_other_head run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  [ "$(grep -c '^pr comment' "$GH_CALLS")" -eq 1 ] \
    || fail "an attest request for another head suppressed this head's review request"

  # An attest request carries no base, so reusing one must not slip past the
  # refusal for a head whose base has moved -- that would report a request
  # bound to the old base as successfully bound to the new one.
  rm -f "$TMP/state/review-request"
  GH_MODE=attest_request_moved_base run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'already has a review request for different base coordinates'
  [ "$(grep -c '^pr comment' "$GH_CALLS" || true)" -eq 0 ] \
    || fail "a moved base still posted a review request"

  # Author-scoped, like every other marker read here: anyone can type one.
  rm -f "$TMP/state/review-request"
  GH_MODE=attest_request_spoofed run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  [ "$(grep -c '^pr comment' "$GH_CALLS")" -eq 1 ] \
    || fail "a spoofed attest marker suppressed the real review request"

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
  assert_rc "$RUN_RC" 0
  assert_has "$GH_CALLS" 'pr merge'
  assert_not_has "$GH_CALLS" '/issues/7/comments?per_page=100'
  assert_not_has "$GH_CALLS" '/pulls/7/reviews?per_page=100'
  assert_not_has "$GH_CALLS" '/pulls/7/comments?per_page=100'
  rm -f "$TMP/state/gate-reruns" "$TMP/state/gate-after-rerun" "$TMP/state/merged"
  : >"$GH_CALLS"
  GH_MODE=status_gate_pending run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 0
  grep -q '^pr merge.*--auto' "$GH_CALLS" || fail "merge did not arm auto-merge for a pending gate: $(grep '^pr merge' "$GH_CALLS")"
  assert_has "$TMP/out" '"reviewGate":{"runId":"77","action":"arm-auto-merge"}'
  [ ! -e "$TMP/state/gate-reruns" ] \
    || fail "merge mutated a pending review evaluation"
  rm -f "$TMP/state/merged"
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

  echo "==> merge refuses to re-arm a head the queue already evicted (AUT-1290)"
  # Same green head, same successful gate, same CLEAN merge state as the
  # accepted merge above; the only difference is the queue's newest event
  # for this head. Re-queueing it repeats the eviction (vesper#1171 spent a
  # full runner cycle that way on 2026-09-05), so merge refuses it.
  touch "$TMP/state/review-gate" "$TMP/state/pr-exists" "$TMP/state/queue-evicted"
  rm -f "$TMP/state/merged" "$TMP/state/auto-merge-armed"
  : >"$GH_CALLS"
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'removed from the merge queue at 2026-09-02T16:51:33Z (failed_checks) and nothing has changed since'
  assert_has "$TMP/out" 'no merge was requested'
  assert_has "$TMP/out" "touchstone pr merge 7 --head <new head>"
  assert_not_has "$TMP/out" 'was disarmed'
  # Nothing armed, so nothing to disarm: no mutation of any kind.
  assert_not_has "$GH_CALLS" 'pr merge'
  # An armed request that outlived the eviction is what lets GitHub re-queue
  # the same red head when the base moves; it is disarmed, and the refusal
  # says so. The disarm is the only mutation.
  touch "$TMP/state/auto-merge-armed"
  : >"$GH_CALLS"
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'was disarmed so GitHub does not re-queue this head'
  grep -q '^pr merge 7 .*--disable-auto' "$GH_CALLS" || fail "merge did not disarm the evicted head's auto-merge request: $(cat "$GH_CALLS")"
  assert_not_has "$GH_CALLS" '--squash'
  [ ! -f "$TMP/state/auto-merge-armed" ] || fail "the fake still holds an armed request after the disarm"
  # A disarm GitHub refuses is an operational failure with the raw remedy,
  # never a silent fall-through into the merge.
  touch "$TMP/state/auto-merge-armed" "$TMP/state/disarm-fails"
  : >"$GH_CALLS"
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" 'could not be disarmed: auto-merge could not be disabled'
  assert_has "$TMP/out" 'gh pr merge 7 --repo github.com/autumngarage/current --disable-auto'
  assert_not_has "$GH_CALLS" '--squash'
  rm -f "$TMP/state/disarm-fails" "$TMP/state/auto-merge-armed"
  # The human output carries the same refusal.
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA"
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'ERROR: PR #7 head'
  assert_has "$TMP/out" 'removed from the merge queue'
  rm -f "$TMP/state/queue-evicted"
  # A head pushed after the removal is a different head: the eviction is
  # history and this head merges on the ordinary path.
  touch "$TMP/state/queue-evicted-then-pushed"
  : >"$GH_CALLS"
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 0
  assert_has "$GH_CALLS" 'pr merge'
  rm -f "$TMP/state/queue-evicted-then-pushed" "$TMP/state/merged" "$TMP/state/review-gate"

  echo "==> merge enqueues an armed, green, CLEAN head GitHub never queued (AUT-1224)"
  # hesperus#354, 2026-09-10: armed while a required check ran; the check
  # failed, its re-run passed, and the PR then read CLEAN, armed, and unqueued
  # for 21 minutes. Re-running merge reported auto-merge-enabled and changed
  # nothing; a direct enqueuePullRequest queued it at once.
  touch "$TMP/state/review-gate" "$TMP/state/pr-exists" "$TMP/state/auto-merge-armed"
  rm -f "$TMP/state/merged" "$TMP/state/queued"
  # Status, the one reader, names the command that recovers it.
  run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"phase":"armed-not-queued","nextAction":"queue"'
  run_pr "$TMP/out" status 7
  assert_has "$TMP/out" "command: touchstone pr merge 7 --head $HEAD_SHA"
  # Armed is held to the ready read's gate-binding guards (AUT-1639): the same
  # armed, CLEAN, unqueued head whose gate run is from an unbound source is
  # action-required, and status names no merge command -- merge refuses that
  # head on the same guard and enqueues nothing.
  GH_MODE=status_gate_historical run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"unbound":true'
  assert_has "$TMP/out" '"phase":"action-required","nextAction":"inspect"'
  assert_not_has "$TMP/out" '"nextAction":"queue"'
  GH_MODE=status_gate_historical run_pr "$TMP/out" status 7
  assert_not_has "$TMP/out" 'command: touchstone pr merge'
  GH_MODE=status_gate_historical run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'is not successful: unbound workflow run'
  assert_not_has "$GH_CALLS" 'enqueuePullRequest'
  # A workflow-source policy carries no review gate to bind, so its armed,
  # CLEAN, unqueued head is still sent to the enqueue, and merge enqueues it.
  GH_FAKE_REPO=autumngarage/touchstone-workflows run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"configured":false'
  assert_has "$TMP/out" '"phase":"armed-not-queued","nextAction":"queue"'
  GH_FAKE_REPO=autumngarage/touchstone-workflows run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"queued"'
  assert_has "$GH_CALLS" 'enqueuePullRequest'
  rm -f "$TMP/state/queued"
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"queued"'
  assert_has "$GH_CALLS" 'enqueuePullRequest'
  assert_has "$GH_CALLS" "expectedHeadOid=$HEAD_SHA"
  assert_has "$GH_CALLS" 'pullRequestId=PR_kwDOfixture7'
  # Already armed: nothing arms it again, so the enqueue is the one mutation.
  assert_not_has "$GH_CALLS" 'pr merge'
  # Re-running on the queued head is idempotent: queued, no second enqueue.
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"queued"'
  assert_not_has "$GH_CALLS" 'enqueuePullRequest'
  assert_not_has "$GH_CALLS" 'pr merge'
  # The moment right after arming: GitHub already reads the head green and
  # unqueued, so the same run enqueues it, and the human output says so.
  rm -f "$TMP/state/queued" "$TMP/state/auto-merge-armed"
  touch "$TMP/state/arm-on-merge"
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA"
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" "enqueueing it at $HEAD_SHA"
  assert_has "$TMP/out" "PR #7: queued at $HEAD_SHA"
  grep -q '^pr merge 7 ' "$GH_CALLS" || fail "merge did not arm the head before enqueueing it: $(cat "$GH_CALLS")"
  assert_has "$GH_CALLS" "expectedHeadOid=$HEAD_SHA"
  rm -f "$TMP/state/arm-on-merge" "$TMP/state/queued"
  touch "$TMP/state/auto-merge-armed"
  # An armed head GitHub already queued is reported queued with no enqueue.
  GH_MODE=merge_queue_existing run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"queued"'
  assert_not_has "$GH_CALLS" 'enqueuePullRequest'
  assert_not_has "$GH_CALLS" 'pr merge'
  # A head still waiting on a check stays auto-merge-enabled: GitHub admits it
  # when the check passes, nothing here polls, and nothing is enqueued.
  GH_MODE=status_auto_merge run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"auto-merge-enabled"'
  assert_not_has "$GH_CALLS" 'enqueuePullRequest'
  assert_not_has "$GH_CALLS" 'pr merge'
  # GitHub not reporting CLEAN is GitHub's verdict: status says inspect and
  # names no command, and merge enqueues nothing.
  GH_MODE=status_gate_blocked_success run_pr "$TMP/out" status 7 --json
  assert_has "$TMP/out" '"phase":"armed-not-queued","nextAction":"inspect"'
  GH_MODE=status_gate_blocked_success run_pr "$TMP/out" status 7
  assert_not_has "$TMP/out" 'command: touchstone pr merge'
  GH_MODE=status_gate_blocked_success run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"auto-merge-enabled"'
  assert_not_has "$GH_CALLS" 'enqueuePullRequest'
  # A head that moves before the enqueue decision is refused; nothing is
  # enqueued at any head.
  printf '1\n' >"$TMP/state/head-moves-after-reads"
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'is at moved-head; nothing was enqueued'
  assert_not_has "$GH_CALLS" 'enqueuePullRequest'
  rm -f "$TMP/state/head-moves-after-reads"
  # GitHub's refusal is surfaced in its own words, once, never retried, and
  # never reported as queued.
  touch "$TMP/state/enqueue-fails"
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 1
  assert_has "$TMP/out" "GitHub refused to enqueue PR #7 at $HEAD_SHA"
  assert_has "$TMP/out" 'Pull request is in unstable status (enqueuePullRequest)'
  assert_has "$TMP/out" 'enqueuePullRequest(input:{pullRequestId:'
  assert_not_has "$TMP/out" '"status":"queued"'
  [ "$(grep -c 'enqueuePullRequest' "$GH_CALLS" || true)" -eq 1 ] \
    || fail "a refused enqueue was not attempted exactly once: $(grep -c 'enqueuePullRequest' "$GH_CALLS" || true)"
  rm -f "$TMP/state/enqueue-fails" "$TMP/state/auto-merge-armed" "$TMP/state/queued" "$TMP/state/review-gate"

  echo "==> behavior v2 merge arms auto-merge on an active evaluation without re-running it"
  touch "$TMP/state/review-gate"
  rm -f "$TMP/state/merged" "$TMP/state/gate-reruns"
  : >"$GH_CALLS"
  GH_MODE=status_gate_pending run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 0
  grep -q '^pr merge.*--auto' "$GH_CALLS" || fail "behavior v2 merge did not arm auto-merge for a pending gate"
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
  assert_has "$TMP/out" '"repositoryHost":"github.com"'
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
  assert_has "$TMP/out" "does not declare supported gate behavior contract 4"
  assert_has "$TMP/out" "observed $GH_AHEAD_SHA"
  assert_has "$GH_CALLS" "touchstone-workflows/contents/.touchstone-source-contract.json?ref=$GH_AHEAD_SHA"
  rm -f "$TMP/state/ahead-pin" "$TMP/state/behavior-version-legacy"
  touch "$TMP/state/behavior-version-missing"
  run_pr "$TMP/out" policy-status --json
  assert_has "$TMP/out" '"status":"partial"'
  assert_has "$TMP/out" "does not declare supported gate behavior contract 4"
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
  # Order is the evaluator's, not alphabetical or grouped: the queue rule is
  # reported between the two declared statuses. Asserted as emitted so this
  # case keeps proving every declared status is assessed.
  assert_has "$TMP/out" '"enforcement":{"status":"partial","missing":["convoy/delivery-protocol status","merge queue","powershell-tests status"]}'
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
# The free quota read the shared handler answers from, and GitHub refusing
# this token's GraphQL requests for its rate limit (AUT-1648). The quota read
# comes first: it is REST, and GitHub answers it while a quota is exhausted.
if has 'rate_limit' "$@"; then
  jq -cn '{resources:{core:{remaining:4321,reset:1789086073},graphql:{remaining:0,reset:1789086400}}}' \
    | jq -r "$(value_after --jq "$@")"
  exit 0
fi
if [ -f "$GH_STATE/rate-limited-graphql" ] && [ "${1:-}" = api ] && [ "${2:-}" = graphql ]; then
  printf 'GraphQL: API rate limit exceeded for user ID 1. (RATE_LIMITED)\n' >&2
  exit 1
fi
case "$1 $2" in
  "api repos/autumngarage/current/pulls/7")
    printf '%s\n' "${GH_EXISTING_PR_BODY:-existing body}"
    ;;
  "api --method")
    if has PATCH "$@" && has repos/autumngarage/current/pulls/7 "$@"; then
      body_arg="$(field_value body "$@")"
      cp "${body_arg#@}" "$GH_STATE/pr-body"
      printf '7\n'
    fi
    ;;
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
      ! has THREAD_52 "$@" || touch "$GH_STATE/resolved-52"
      echo "true"
    elif has "node(id:" "$@"; then
      echo "true"
    elif [ -f "$GH_STATE/second-round" ]; then
      # A later verdict on the same head opened thread 52 after 51 was
      # resolved; it stays open until its own answer resolves it.
      has 'databaseId == 51' "$@" && echo "THREAD_51"
      has 'databaseId == 52' "$@" && echo "THREAD_52"
      if [ ! -f "$GH_STATE/resolved-52" ]; then
        has 'isResolved == false' "$@" && printf 'THREAD_52\t52\tscripts/x.sh\n'
        has 'isResolved == true' "$@" && echo "51"
      else
        has 'isResolved == true' "$@" && printf '51\n52\n'
        # Thread 53 was resolved by hand and carries no answer from this
        # tool: a query keyed on the tool's own disposition markers omits it;
        # one keyed on resolution alone would count it.
        if [ -f "$GH_STATE/externally-resolved-53" ] && has 'isResolved == true' "$@" \
          && ! has 'touchstone:review-answer' "$@"; then
          echo "53"
        fi
      fi
    elif [ -f "$GH_STATE/resolved" ]; then
      # Thread lookup after resolution: by first-comment id only.
      has 'databaseId == 51' "$@" && echo "THREAD_51"
      has 'isResolved == true' "$@" && echo "51"
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
  "api repos/autumngarage/current/pulls/7/comments/52/replies")
    echo 1 >>"$GH_STATE/replies"
    field_value body "$@" >"$GH_STATE/reply-body"
    echo "72"
    ;;
  "api repos/autumngarage/current/issues/7/comments")
    field_value body "$@" >>"$GH_STATE/fresh-request"
    echo "99"
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
    if value_after --json "$@" | grep -q 'state,headRefOid,baseRefName'; then
      rr_state=OPEN
      rr_head=abcdef0123456789abcdef0123456789abcdef01
      rr_base=main
      [ ! -f "$GH_STATE/wait-retargeted" ] || rr_base=release
      [ ! -f "$GH_STATE/merged" ] || rr_state=MERGED
      [ ! -f "$GH_STATE/closed" ] || rr_state=CLOSED
      [ ! -f "$GH_STATE/wait-moved-head" ] || rr_head=feedfacefeedfacefeedfacefeedfacefeedface
      printf '%s\t%s\t%s\n' "$rr_state" "$rr_head" "$rr_base"
    elif value_after --json "$@" | grep -q baseRefName; then
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
    elif has 'issues/7/comments' "$@"; then
      [ ! -f "$GH_STATE/fresh-request" ] || cat "$GH_STATE/fresh-request"
    elif [ -f "$GH_STATE/replies" ]; then
      echo "<!-- touchstone:respond-review comment=51 -->"
      [ -f "$GH_STATE/legacy-reply-only" ] \
        || echo "<!-- touchstone:review-answer v=1 id=51 disposition=no-code-change -->"
    fi
    ;;
  "api repos/autumngarage/current/rules/branches/main")
    if [ -f "$GH_STATE/review-gate" ]; then echo true; else echo false; fi
    ;;
  "api repos/autumngarage/current/actions/runs?head_sha=abcdef0123456789abcdef0123456789abcdef01&per_page=30")
    # The finding path asks for the latest review-gate run as "id<TAB>status".
    if [ -f "$GH_STATE/finding-gate-active" ]; then printf '77\tin_progress\n'; else printf '77\tcompleted\n'; fi
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
  export TOUCHSTONE_PR_REAL="$TOUCHSTONE_ROOT/scripts/touchstone-pr.sh" TOUCHSTONE_PR_PROJECT="$TOUCHSTONE_ROOT"

  mkdir -p "$RR/tool-v1/scripts"
  cp "$TOUCHSTONE_ROOT/scripts/respond-review.sh" "$RR/tool-v1/scripts/respond-review.sh"
  cat >"$RR/tool-v1/scripts/touchstone-pr.sh" <<'STATUS_STUB'
#!/usr/bin/env bash
set -euo pipefail
# The shared contract-4 wait is exercised against the real sequencer in its
# own cases; here only the call respond-review.sh makes is recorded.
if [ "${1:-}" = await-review ]; then
  printf '%s\n' "$*" >>"$GH_STATE/await-calls"
  [ ! -f "$GH_STATE/await-fails" ] || { echo "ERROR: the stubbed wait failed" >&2; exit 1; }
  echo "PR #7: review gate woken"
  exit 0
fi
if [ "${1:-}" = wake-review-gate ]; then
  printf '%s\n' "$*" >>"$GH_STATE/wake-calls"
  [ ! -f "$GH_STATE/wake-fails" ] || { echo "ERROR: the stubbed wake failed" >&2; exit 1; }
  echo "PR #7: review gate woken"
  exit 0
fi
# The rate-limit classifier is the real sequencer's, not a second fake of it:
# the point of the case is that the answer client stops where the rest of the
# CLI stops, with the same words (AUT-1648).
if [ "${1:-}" = rate-limit-check ]; then
  printf '%s\n' "$*" >>"$GH_STATE/rate-limit-checks"
  # --project only so the case does not depend on the directory the suite was
  # started from; in production the same root comes from the answer client's
  # own working directory.
  exec bash "$TOUCHSTONE_PR_REAL" "$@" --project "$TOUCHSTONE_PR_PROJECT"
fi
version=null
# A failed status reports itself as a JSON document on stdout, as the real
# one does: here, the token-scope failure a collaborator without
# administration read meets.
if [ -f "$GH_STATE/status-fails" ]; then
  printf '%s\n' '{"schema":"touchstone.pr/v2","operation":"status","status":"failed","reason":"could not read whether Actions are enabled for autumngarage/current (needs repository administration read on the token)","remedy":"Use a credential that can read repos/autumngarage/current/actions/permissions, or retry after GitHub recovers."}'
  exit 1
fi
[ ! -f "$GH_STATE/effective-behavior-v2" ] || version=2
[ ! -f "$GH_STATE/effective-behavior-v3" ] || version=3
[ ! -f "$GH_STATE/effective-behavior-v4" ] || version=4
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
  run_v3() {
    rm -f "$GH_STATE/effective-behavior-v2"
    touch "$GH_STATE/effective-behavior-v3"
    set +e
    bash "$RR/tool-v2/scripts/respond-review.sh" "$@" >"$RR/out" 2>&1
    RUN_RC=$?
    set -e
    rm -f "$GH_STATE/effective-behavior-v3"
  }
  run_v4() {
    rm -f "$GH_STATE/effective-behavior-v2" "$GH_STATE/effective-behavior-v3"
    touch "$GH_STATE/effective-behavior-v4"
    set +e
    bash "$RR/tool-v2/scripts/respond-review.sh" "$@" >"$RR/out" 2>&1
    RUN_RC=$?
    set -e
    rm -f "$GH_STATE/effective-behavior-v4"
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

  echo "==> a gate-reported finding is answered by id: recorded in the PR body, gate re-run (touchstone#1123)"
  # 3.10.1 shipped --finding behind the thread-id guard: a valid finding
  # answer printed usage and exited 2, so no agent could refute a finding.
  rm -f "$GH_STATE/pr-body" "$GH_STATE/gate-reruns" "$GH_STATE/replies" "$GH_STATE/resolved"
  run 7 --finding 0123456789abcdef --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] \
    && grep -qF '<!-- touchstone:review-dismiss id=0123456789abcdef reason=' "$GH_STATE/pr-body" \
    && grep -qF 'existing body' "$GH_STATE/pr-body" \
    && grep -qF 'rerun 77' "$GH_STATE/gate-reruns" \
    && [ ! -e "$GH_STATE/replies" ] && [ ! -e "$GH_STATE/resolved" ] \
    && ok "a refuted finding is recorded in the PR body and the gate is re-run; no thread is touched" \
    || fail "the finding answer did not land (rc=$RUN_RC): $(tail -3 "$RR/out")"
  rm -f "$GH_STATE/pr-body" "$GH_STATE/gate-reruns"
  run 7 --finding 0123456789abcdef --body-file "$RR/body" --fix-commit abc123
  [ "$RUN_RC" -eq 0 ] \
    && grep -qF '<!-- touchstone:review-answer v=1 finding=0123456789abcdef disposition=fixed fix=abcdef0123456789abcdef0123456789abcdef01 -->' "$GH_STATE/pr-body" \
    && ok "a fixed finding records the canonical SHA in the PR body" \
    || fail "the fixed finding answer did not record the canonical SHA: $(tail -2 "$RR/out")"
  run 7 --finding nothex --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 2 ] && grep -qF '16-character id' "$RR/out" \
    && ok "a malformed finding id is invalid input" \
    || fail "a malformed finding id was accepted (rc=$RUN_RC)"

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
  echo "==> an answer whose gate behavior cannot be read fails with the reason, never guessing behavior v1 (AUT-1636)"
  # The guess re-ran whatever gate was there at once. Under contract 4 that
  # spent the one wake before the reviewer was asked for its verdict, and
  # the answer still reported success.
  touch "$GH_STATE/status-fails"
  run_v2 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 1 ] || fail "an answer whose behavior read failed exited $RUN_RC, expected 1: $(tail -3 "$RR/out")"
  [ ! -f "$GH_STATE/gate-reruns" ] || fail "an answer whose behavior read failed still re-ran the gate through the behavior-v1 guess"
  grep -qF 'the reply and resolution are recorded, but which review-gate behavior GitHub enforces could not be read' "$RR/out" \
    || fail "a failed behavior read did not say what stands: $(tail -3 "$RR/out")"
  grep -qF 'needs repository administration read' "$RR/out" \
    || fail "a failed behavior read dropped the status read's own reason: $(tail -3 "$RR/out")"
  rm -f "$GH_STATE/effective-behavior-v2" "$GH_STATE/fresh-request"
  run_v4 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 1 ] || fail "a contract-4 answer whose behavior read failed exited $RUN_RC, expected 1"
  [ ! -f "$GH_STATE/gate-reruns" ] || fail "a contract-4 answer whose behavior read failed re-ran the gate before the verdict was requested"
  [ ! -f "$GH_STATE/await-calls" ] || fail "a contract-4 answer whose behavior read failed still waited"
  [ ! -f "$GH_STATE/fresh-request" ] || fail "a contract-4 answer whose behavior read failed requested review under a guessed contract"
  rm -f "$GH_STATE/status-fails" "$GH_STATE/gate-reruns"

  echo "==> a contract-3 answer does not run the behavior-v1 gate refresh (AUT-1225)"
  # The contract-3 gate long-polls, so an answer that races the run binding
  # finds no re-runnable run. On the old code the v1 refresh below then polled
  # until the attempt budget was spent and exited nonzero -- after the reply,
  # the resolution and the attest request had all already succeeded. An agent
  # reads that as a failed answer and answers again.
  rm -f "$GH_STATE/gate-reruns" "$GH_STATE/fresh-request" "$GH_STATE/gate-fresh-active"
  echo 30 >"$GH_STATE/gate-in-progress"
  TOUCHSTONE_GATE_ATTEMPTS=3 TOUCHSTONE_GATE_RETRY_DELAY=0 run_v3 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "a contract-3 answer exited $RUN_RC after its reply, resolution and attest succeeded: $(tail -3 "$RR/out")"
  ! grep -qF 'did not reach a re-runnable state' "$RR/out" || fail "a contract-3 answer still failed through the behavior-v1 refresh"
  ! grep -qF 'retrying in' "$RR/out" || fail "a contract-3 answer still polled for a re-runnable run"
  grep -qF 'no behavior-v1 gate refresh applies' "$RR/out" || fail "a contract-3 answer did not say why it skipped the refresh: $(tail -3 "$RR/out")"
  rm -f "$GH_STATE/gate-in-progress" "$GH_STATE/gate-reruns" "$GH_STATE/fresh-request"

  echo "==> an answer on a merged PR returns without waiting for a gate run that cannot exist (AUT-511, touchstone#1053)"
  # The reply and resolution are the material work and have already
  # succeeded by the time the gate wait begins. On the old code this loop
  # polled for a run that a merged PR can never receive until GATE_ATTEMPTS
  # ran out, and the operator killed it not knowing whether the answer stuck.
  rm -f "$GH_STATE/gate-in-progress" "$GH_STATE/gate-reruns" "$GH_STATE/fresh-request" "$GH_STATE/gate-fresh-active"
  echo 30 >"$GH_STATE/gate-in-progress"
  touch "$GH_STATE/merged"
  TOUCHSTONE_GATE_ATTEMPTS=3 TOUCHSTONE_GATE_RETRY_DELAY=0 run_v3 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "answer on a merged PR exited $RUN_RC instead of returning: $(tail -3 "$RR/out")"
  grep -qF 'PR #7 is MERGED; the reply and resolution are recorded and no review-gate re-run applies' "$RR/out" \
    || fail "answer on a merged PR did not say why no gate re-run applies: $(tail -3 "$RR/out")"
  ! grep -qF 'retrying in' "$RR/out" || fail "answer on a merged PR still polled for a gate run"
  [ ! -f "$GH_STATE/gate-reruns" ] || fail "answer on a merged PR requested a gate re-run"
  rm -f "$GH_STATE/merged"
  touch "$GH_STATE/closed"
  TOUCHSTONE_GATE_ATTEMPTS=3 TOUCHSTONE_GATE_RETRY_DELAY=0 run_v3 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "answer on a closed PR exited $RUN_RC instead of returning: $(tail -3 "$RR/out")"
  grep -qF 'PR #7 is CLOSED; the reply and resolution are recorded and no review-gate re-run applies' "$RR/out" \
    || fail "answer on a closed PR did not say why no gate re-run applies"
  rm -f "$GH_STATE/closed" "$GH_STATE/gate-in-progress" "$GH_STATE/fresh-request"
  echo "==> an answer whose head moves mid-wait stops and names the live head"
  # moved-head flips the pre-wait re-read, which the exact-head guard already
  # refuses; wait-moved-head moves the head only as seen by the liveness
  # read, so the wait itself is what stops.
  echo 30 >"$GH_STATE/gate-in-progress"
  touch "$GH_STATE/wait-moved-head"
  TOUCHSTONE_GATE_ATTEMPTS=3 TOUCHSTONE_GATE_RETRY_DELAY=0 run_v3 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -ne 0 ] || fail "answer kept waiting after the head moved"
  grep -qF 'moved from abcdef0123456789abcdef0123456789abcdef01 to feedfacefeedfacefeedfacefeedfacefeedface while waiting for the review gate' "$RR/out" \
    || fail "answer did not name the live head when the wait stopped: $(tail -3 "$RR/out")"
  rm -f "$GH_STATE/wait-moved-head" "$GH_STATE/gate-in-progress" "$GH_STATE/fresh-request"
  echo "==> an answer whose PR is retargeted mid-wait stops and names the new base"
  echo 30 >"$GH_STATE/gate-in-progress"
  touch "$GH_STATE/wait-retargeted"
  TOUCHSTONE_GATE_ATTEMPTS=3 TOUCHSTONE_GATE_RETRY_DELAY=0 run_v3 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -ne 0 ] || fail "answer kept waiting after the PR was retargeted"
  grep -qF 'was retargeted from main to release while waiting for the review gate' "$RR/out" \
    || fail "answer did not name the new base when the wait stopped: $(tail -3 "$RR/out")"
  rm -f "$GH_STATE/wait-retargeted" "$GH_STATE/gate-in-progress" "$GH_STATE/fresh-request"

  echo "==> a behavior v3 answer that resolves the last thread posts one fresh review request"
  touch "$GH_STATE/gate-fresh-active"
  echo 30 >"$GH_STATE/gate-in-progress"
  run_v3 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "behavior v3 answer exited $RUN_RC: $(tail -3 "$RR/out")"
  grep -qF '@codex review' "$GH_STATE/fresh-request" 2>/dev/null \
    || fail "behavior v3 answer did not post the fresh review request for the clean verdict"
  [ "$(grep -cF '@codex review' "$GH_STATE/fresh-request")" -eq 1 ] \
    || fail "behavior v3 answer posted more than one review request"
  grep -qF 'posted a fresh review request' "$RR/out" \
    || fail "behavior v3 answer did not announce its review request"
  grep -qF 'touchstone:attest-request head=abcdef0123456789abcdef0123456789abcdef01' "$GH_STATE/fresh-request" \
    || fail "behavior v3 review request carries no head-scoped idempotency marker"

  # A retry after the request was posted must not post a second one.
  echo 30 >"$GH_STATE/gate-in-progress"
  touch "$GH_STATE/gate-fresh-active"
  run_v3 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "behavior v3 retry exited $RUN_RC: $(tail -3 "$RR/out")"
  [ "$(grep -cF '@codex review' "$GH_STATE/fresh-request")" -eq 1 ] \
    || fail "behavior v3 retry posted a duplicate review request"
  grep -qF 'already exists' "$RR/out" \
    || fail "behavior v3 retry did not report the existing request"
  rm -f "$GH_STATE/gate-in-progress" "$GH_STATE/gate-reruns" "$GH_STATE/fresh-request"

  # A later verdict on the unchanged head opens a new finding. Answering it
  # closes a new round, and the gate can only be satisfied by a request that
  # postdates that verdict — so the head-scoped request from the first round
  # must not suppress a fresh one (AUT-1170).
  echo "==> a second round of findings on the same head posts another fresh request"
  echo 30 >"$GH_STATE/gate-in-progress"
  touch "$GH_STATE/gate-fresh-active"
  echo "@codex review

<!-- touchstone:attest-request head=abcdef0123456789abcdef0123456789abcdef01 -->
<!-- touchstone:attest-round head=abcdef0123456789abcdef0123456789abcdef01 answered=51 -->" >"$GH_STATE/fresh-request"
  touch "$GH_STATE/resolved"
  touch "$GH_STATE/second-round"
  run_v3 7 --comment-id 52 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "second-round answer exited $RUN_RC: $(tail -3 "$RR/out")"
  [ "$(grep -cF '@codex review' "$GH_STATE/fresh-request")" -eq 2 ] \
    || fail "a second round of findings did not post a fresh review request: $(cat "$GH_STATE/fresh-request")"
  grep -qF 'touchstone:attest-round head=abcdef0123456789abcdef0123456789abcdef01 answered=51,52' "$GH_STATE/fresh-request" \
    || fail "the second-round request does not name the round it closed: $(cat "$GH_STATE/fresh-request")"
  grep -qF 'posted a fresh review request' "$RR/out" \
    || fail "second-round answer did not announce its review request"
  # ...and retrying that answer posts nothing more.
  echo 30 >"$GH_STATE/gate-in-progress"
  touch "$GH_STATE/gate-fresh-active"
  run_v3 7 --comment-id 52 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "second-round retry exited $RUN_RC: $(tail -3 "$RR/out")"
  [ "$(grep -cF '@codex review' "$GH_STATE/fresh-request")" -eq 2 ] \
    || fail "second-round retry posted a duplicate review request"
  # ...and so does retrying the EARLIER answer of the closed round: the key
  # is the round, so no answer in it posts again.
  echo 30 >"$GH_STATE/gate-in-progress"
  touch "$GH_STATE/gate-fresh-active"
  run_v3 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "earlier-answer retry exited $RUN_RC: $(tail -3 "$RR/out")"
  [ "$(grep -cF '@codex review' "$GH_STATE/fresh-request")" -eq 2 ] \
    || fail "retrying an earlier answer of a closed round posted a duplicate review request"
  # A thread someone resolved by hand, with no answer from this tool, is not
  # a round: it must not change the key and provoke another request.
  touch "$GH_STATE/externally-resolved-53"
  echo 30 >"$GH_STATE/gate-in-progress"
  touch "$GH_STATE/gate-fresh-active"
  run_v3 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "retry after a hand-resolved thread exited $RUN_RC: $(tail -3 "$RR/out")"
  [ "$(grep -cF '@codex review' "$GH_STATE/fresh-request")" -eq 2 ] \
    || fail "a thread resolved by hand changed the round key and posted a duplicate review request"
  rm -f "$GH_STATE/externally-resolved-53"
  rm -f "$GH_STATE/second-round" "$GH_STATE/resolved-52" "$GH_STATE/gate-in-progress" "$GH_STATE/gate-reruns" "$GH_STATE/fresh-request"

  # Behavior v2 must never post one: answered findings satisfy that gate.
  echo 30 >"$GH_STATE/gate-in-progress"
  touch "$GH_STATE/gate-fresh-active"
  run_v2 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "behavior v2 answer exited $RUN_RC"
  [ ! -f "$GH_STATE/fresh-request" ] \
    || fail "behavior v2 answer posted a review request it must not post"
  rm -f "$GH_STATE/gate-in-progress" "$GH_STATE/gate-reruns" "$GH_STATE/gate-fresh-active"
  rm -f "$GH_STATE/effective-behavior-v2"

  echo "==> a contract-4 answer requests the verdict once and waits through the shared sequencer (AUT-793)"
  # A contract-4 gate evaluates once, so the request the last answer posts
  # needs a wake. The wait-and-wake is open's own, run through
  # touchstone-pr.sh await-review: one code path, never a second loop here.
  [ ! -f "$GH_STATE/await-calls" ] \
    || fail "a contract-1, -2, or -3 answer ran the contract-4 wait: $(cat "$GH_STATE/await-calls")"
  rm -f "$GH_STATE/fresh-request" "$GH_STATE/gate-reruns" "$GH_STATE/gate-in-progress" "$GH_STATE/resolved"
  run_v4 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "contract-4 answer exited $RUN_RC: $(tail -3 "$RR/out")"
  [ "$(grep -cF '@codex review' "$GH_STATE/fresh-request" 2>/dev/null || true)" = 1 ] \
    || fail "contract-4 answer did not post exactly one review request"
  [ "$(wc -l <"$GH_STATE/await-calls" 2>/dev/null | tr -d ' ')" = 1 ] \
    && grep -qxF 'await-review 7 --head abcdef0123456789abcdef0123456789abcdef01' "$GH_STATE/await-calls" \
    || fail "contract-4 answer did not wait through await-review exactly once for the captured head"
  [ ! -f "$GH_STATE/gate-reruns" ] || fail "contract-4 answer re-ran the gate itself instead of through the shared wait"
  grep -qF 'Behavior contract 4: waiting here' "$RR/out" || fail "contract-4 answer did not say it waits: $(tail -3 "$RR/out")"
  # A retry posts nothing new and waits once more.
  run_v4 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "contract-4 retry exited $RUN_RC: $(tail -3 "$RR/out")"
  [ "$(grep -cF '@codex review' "$GH_STATE/fresh-request")" = 1 ] || fail "contract-4 retry posted a second review request"
  [ "$(wc -l <"$GH_STATE/await-calls" | tr -d ' ')" = 2 ] || fail "contract-4 retry did not wait exactly once more"
  # A failed wait is reported, and says the answer and request stand.
  touch "$GH_STATE/await-fails"
  run_v4 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 1 ] || fail "a failed contract-4 wait exited $RUN_RC, expected 1"
  grep -qF 'the answers and the review request are recorded' "$RR/out" \
    || fail "a failed contract-4 wait did not say what stands: $(tail -2 "$RR/out")"
  [ "$(grep -cF '@codex review' "$GH_STATE/fresh-request")" = 1 ] || fail "a failed contract-4 wait posted another request"
  rm -f "$GH_STATE/await-fails" "$GH_STATE/await-calls" "$GH_STATE/fresh-request"
  # An earlier answer of a round requests nothing, so it waits for nothing.
  touch "$GH_STATE/second-round"
  run_v4 7 --comment-id 51 --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "contract-4 answer with threads remaining exited $RUN_RC: $(tail -3 "$RR/out")"
  [ ! -f "$GH_STATE/fresh-request" ] || fail "contract-4 answer requested review while threads remained open"
  [ ! -f "$GH_STATE/await-calls" ] || fail "contract-4 answer waited while no review was requested"
  grep -qF 'threads remain open' "$RR/out" || fail "contract-4 answer did not say why nothing waits"
  rm -f "$GH_STATE/second-round" "$GH_STATE/resolved-52" "$GH_STATE/fresh-request" "$GH_STATE/await-calls" "$GH_STATE/gate-reruns"

  echo "==> a contract-4 finding answer waits for a gate run still evaluating, through the shared wake (AUT-1636)"
  # A contract-4 run evaluates once, so one still running may have read the
  # body before this answer landed and would decide without it. The answer
  # follows it to completion and re-runs it once through touchstone-pr.sh
  # wake-review-gate, the wake open and the attest request use: no loop here.
  rm -f "$GH_STATE/pr-body" "$GH_STATE/gate-reruns" "$GH_STATE/wake-calls"
  touch "$GH_STATE/finding-gate-active"
  run_v4 7 --finding 0123456789abcdef --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] || fail "a contract-4 finding answer exited $RUN_RC: $(tail -3 "$RR/out")"
  [ "$(wc -l <"$GH_STATE/wake-calls" 2>/dev/null | tr -d ' ')" = 1 ] \
    && grep -qxF 'wake-review-gate 7 --head abcdef0123456789abcdef0123456789abcdef01' "$GH_STATE/wake-calls" \
    || fail "a contract-4 finding answer did not wake through wake-review-gate exactly once for the captured head"
  [ ! -f "$GH_STATE/gate-reruns" ] || fail "a contract-4 finding answer re-ran the gate itself instead of through the shared wake"
  grep -qF 'Behavior contract 4: review-gate run 77 is still evaluating' "$RR/out" \
    || fail "a contract-4 finding answer did not say it waits: $(tail -3 "$RR/out")"
  grep -qF 'touchstone:review-dismiss id=0123456789abcdef' "$GH_STATE/pr-body" \
    || fail "a contract-4 finding answer did not record the answer before waking the gate"
  # A failed wake is reported, and says the answer stands.
  touch "$GH_STATE/wake-fails"
  run_v4 7 --finding 0123456789abcdef --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 1 ] && grep -qF 'the answer is recorded, but following review-gate run 77' "$RR/out" \
    || fail "a failed contract-4 finding wake was not reported with what stands (rc=$RUN_RC): $(tail -2 "$RR/out")"
  rm -f "$GH_STATE/wake-fails" "$GH_STATE/wake-calls"
  # The behavior read that decides it fails the answer rather than guessing.
  touch "$GH_STATE/status-fails"
  run_v4 7 --finding 0123456789abcdef --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 1 ] && grep -qF 'the answer is recorded, but which review-gate behavior GitHub enforces could not be read' "$RR/out" \
    || fail "a finding answer whose behavior read failed did not fail with context (rc=$RUN_RC): $(tail -2 "$RR/out")"
  [ ! -f "$GH_STATE/wake-calls" ] || fail "a finding answer whose behavior read failed still woke the gate"
  rm -f "$GH_STATE/status-fails"
  # Contract 3 keeps its long-polling run and its message, and wakes nothing.
  run_v3 7 --finding 0123456789abcdef --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] && grep -qF 'still evaluating this head; it reads the answer when it decides' "$RR/out" \
    || fail "a contract-3 finding answer changed behavior (rc=$RUN_RC): $(tail -2 "$RR/out")"
  [ ! -f "$GH_STATE/wake-calls" ] || fail "a contract-3 finding answer ran the contract-4 wake"
  # A completed run is re-run as before under contract 4 too: no behavior read.
  rm -f "$GH_STATE/finding-gate-active"
  touch "$GH_STATE/status-fails"
  run_v4 7 --finding 0123456789abcdef --body-file "$RR/body" --no-code-change
  [ "$RUN_RC" -eq 0 ] && grep -q 'rerun 77' "$GH_STATE/gate-reruns" 2>/dev/null \
    || fail "a contract-4 finding answer on a completed run did not re-run it as before (rc=$RUN_RC): $(tail -2 "$RR/out")"
  [ ! -f "$GH_STATE/wake-calls" ] || fail "a finding answer on a completed run ran the wake"
  rm -f "$GH_STATE/status-fails" "$GH_STATE/gate-reruns" "$GH_STATE/pr-body"
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

  echo "==> a rate-limited read stops the answer with the reset, unretried (AUT-1648)"
  # This client had its own read retries and no rate-limit handling at all:
  # every session on the machine shares the token's quota, so those retries
  # spent it again the moment it reset. It stops where the rest of the CLI
  # stops, through the same handler, with the same words.
  rm -f "$GH_STATE/rate-limit-checks"
  touch "$GH_STATE/rate-limited-graphql"
  TOUCHSTONE_GRAPHQL_RETRY_DELAY=0 run 7 --all-resolved-check
  rm -f "$GH_STATE/rate-limited-graphql"
  [ "$RUN_RC" -ne 0 ] || fail "a rate-limited --all-resolved-check reported the PR clean"
  grep -qF "GitHub's GraphQL rate limit for this token is exhausted until 2026-09-11T00:26:40Z" "$RR/out" \
    || fail "the answer client did not name the quota and its reset: $(tail -3 "$RR/out")"
  ! grep -qF 'GraphQL attempt' "$RR/out" \
    || fail "a rate-limited read was retried: $(grep -c 'GraphQL attempt' "$RR/out") attempt notices"
  [ -f "$GH_STATE/rate-limit-checks" ] \
    || fail "the answer client classified the refusal itself instead of asking the shared handler"

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

  echo "==> the answered-round query selects a thread by this tool's marker for its own root, in the newest comments"
  # The fake serves pre-computed ids, so the jq that decides which resolved
  # threads form a round is exercised here against real thread JSON: the
  # script's own expression, extracted verbatim, over a long thread whose
  # marker is the newest of 60 comments, a thread whose finding merely
  # mentions the marker, a thread answered for a different root, and an
  # unresolved answered thread.
  ROUND_JQ="$(sed -nE "s/^[[:space:]]*--jq '(.*reviewThreads.*root.*review-answer.*)' \\\\\$/\\1/p" "$TOUCHSTONE_ROOT/scripts/respond-review.sh" | head -1)"
  [ -n "$ROUND_JQ" ] || fail "could not extract the answered-round jq from respond-review.sh"
  ROUND_QUERY="$(sed -nE "s/^ANSWERED_THREADS_QUERY='(.*)'\$/\\1/p" "$TOUCHSTONE_ROOT/scripts/respond-review.sh")"
  printf '%s' "$ROUND_QUERY" | grep -qF 'comments(last:50)' \
    || fail "the answered-round query must read the newest comments, not the first: $ROUND_QUERY"
  printf '%s' "$ROUND_QUERY" | grep -qF 'root: comments(first:1)' \
    || fail "the answered-round query must read the thread root separately: $ROUND_QUERY"
  ROUND_THREADS_JSON="$(mktemp)"
  long_thread_comments="$(jq -cn '[range(59) | {body: ("comment " + tostring)}] + [{body: "answered <!-- touchstone:review-answer v=1 id=41 disposition=no-code-change -->"}]')"
  jq -n --argjson long "$long_thread_comments" '{data:{repository:{pullRequest:{reviewThreads:{nodes:[
      {isResolved:true,  root:{nodes:[{databaseId:41}]}, comments:{nodes:$long}},
      {isResolved:true,  root:{nodes:[{databaseId:42}]}, comments:{nodes:[{body:"the finding text mentions touchstone:review-answer v=1 id=42 by name"}]}},
      {isResolved:true,  root:{nodes:[{databaseId:43}]}, comments:{nodes:[{body:"<!-- touchstone:review-answer v=1 id=41 disposition=no-code-change -->"}]}},
      {isResolved:false, root:{nodes:[{databaseId:44}]}, comments:{nodes:[{body:"<!-- touchstone:review-answer v=1 id=44 disposition=no-code-change -->"}]}},
      {isResolved:true,  root:{nodes:[{databaseId:45}]}, comments:{nodes:[{body:"resolved by hand, no answer"}]}}
    ]}}}}}' >"$ROUND_THREADS_JSON"
  ROUND_OUT="$(jq -r "$ROUND_JQ" "$ROUND_THREADS_JSON" | sort -n | paste -sd, -)"
  [ "$ROUND_OUT" = "41" ] \
    || fail "the answered-round jq selected '$ROUND_OUT'; expected only 41 (the marker for its own root, newest of 60 comments)"
  # A window that read the first 50 would miss 41's marker: prove the fixture
  # discriminates by dropping the newest comment from the long thread.
  ROUND_OUT_TRUNCATED="$(jq -r "$ROUND_JQ" <(jq '.data.repository.pullRequest.reviewThreads.nodes[0].comments.nodes |= .[:50]' "$ROUND_THREADS_JSON") | sort -n | paste -sd, -)"
  rm -f "$ROUND_THREADS_JSON"
  [ -z "$ROUND_OUT_TRUNCATED" ] \
    || fail "the long-thread fixture does not depend on the newest comment: '$ROUND_OUT_TRUNCATED'"

  echo "==> every GitHub-state wait re-checks liveness on each poll (AUT-1179)"
  # A loop that sleeps on GATE_RETRY_DELAY, or on the FOLLOW_WAIT backoff
  # derived from it (AUT-1638), is waiting for GitHub state to
  # change. Between its "while :; do" and that sleep it must call the
  # liveness precondition, so a PR that merged, closed, or moved its head
  # ends the wait on the next poll instead of exhausting the attempt budget.
  # Transport retries (GRAPHQL_RETRY_DELAY) are not state waits and are not
  # covered.
  wait_violations=""
  wait_sleeps=0
  for wait_script in touchstone-pr.sh respond-review.sh; do
    found="$(awk -v file="$wait_script" '
      /while :; do/ { in_loop = 1; live = 0; loop_line = NR }
      /assert_wait_liveness|require_open_pr_head/ { if (in_loop) live = 1 }
      /sleep "\$(GATE_RETRY_DELAY|FOLLOW_WAIT)"/ { sleeps++; if (in_loop && !live) print file ":" loop_line " waits on GitHub state without a liveness check" }
      /^[[:space:]]*done([[:space:]]|$)/ { in_loop = 0 }
      END { print "SLEEPS=" sleeps }' "$TOUCHSTONE_ROOT/scripts/$wait_script")"
    wait_sleeps=$((wait_sleeps + $(printf '%s\n' "$found" | sed -n 's/^SLEEPS=//p')))
    wait_violations="$wait_violations$(printf '%s\n' "$found" | grep -v '^SLEEPS=' || true)"
  done
  [ "$wait_sleeps" -ge 3 ] || fail "expected at least three GitHub-state waits to guard; found $wait_sleeps (the scan is not seeing the loops)"
  [ -z "$wait_violations" ] && ok "every GitHub-state wait re-checks liveness on each poll" \
    || fail "GitHub-state wait without a liveness check:
  $wait_violations"

  echo "==> no GitHub request runs inside a command substitution, where a rate limit could not stop the command (AUT-1638)"
  # capture_command stops the command on a rate limit. Inside $(...) or <(...)
  # that exit ends only a subshell, and in --json mode the error document
  # becomes the captured value. Every function that reaches a request is
  # found transitively, and none may be called inside one.
  pr_script="$TOUCHSTONE_ROOT/scripts/touchstone-pr.sh"
  requesters="read_with_retry capture_command"
  while :; do
    requester_pattern="$(printf '%s\n' $requesters | paste -sd'|' -)"
    callers="$(awk -v pattern="(^|[^a-zA-Z0-9_])($requester_pattern)([^a-zA-Z0-9_]|\$)" '
      /^[a-z_]+\(\) \{/ { name = $1; sub(/\(\)$/, "", name); next }
      /^\}/ { name = ""; next }
      name != "" && $0 !~ /^[[:space:]]*#/ && $0 ~ pattern { print name }
    ' "$pr_script")"
    next_requesters="$(printf '%s\n' $requesters $callers | sort -u | paste -sd' ' -)"
    [ "$next_requesters" != "$(printf '%s\n' $requesters | sort -u | paste -sd' ' -)" ] || break
    requesters="$next_requesters"
  done
  substituted="$(grep -nE "[\$<]\\((${requester_pattern})([^a-zA-Z0-9_]|\$)" "$pr_script" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  [ -z "$substituted" ] && ok "no function that reaches a GitHub request runs inside a command substitution" \
    || fail "a GitHub request runs inside a command substitution, where a rate limit cannot stop the command:
  $substituted"

  echo "==> every GitHub request goes through the rate-limit path (AUT-1638)"
  # capture_command is where a rate-limited request stops the command; a gh
  # command anywhere else fails generically, or is retried, instead. Allowed:
  # a gh command on a capture_command or read_with_retry line; one inside a
  # function only ever invoked through them (read_repository, project_gh);
  # and stop_on_rate_limit's own free rate_limit read, which names the reset
  # and must not recurse into the path it serves.
  direct_requests="$(awk '
    /^[a-z_]+\(\) \{/ { name = $1; sub(/\(\)$/, "", name); next }
    /^\}/ { name = ""; next }
    /^[[:space:]]*#/ { next }
    /(^[[:space:]]*|\$\(|&&[[:space:]]*|\|\|[[:space:]]*|;[[:space:]]*|\|[[:space:]]*)gh[[:space:]]+[a-z]/ && !/capture_command|read_with_retry/ { print (name == "" ? "-" : name) "\t" NR ": " $0 }
  ' "$pr_script")"
  [ -n "$direct_requests" ] \
    || fail "the direct-request scan found no gh command at all; it is not seeing the script"
  unrouted=""
  while IFS="$(printf '\t')" read -r request_function request_line; do
    [ -n "$request_line" ] || continue
    [ "$request_function" != stop_on_rate_limit ] || continue
    if [ "$request_function" != - ]; then
      # Every use of the function other than its definition, comments, and
      # calls through capture_command or read_with_retry.
      other_uses="$(grep -nE "(^|[^a-zA-Z0-9_])$request_function([^a-zA-Z0-9_(]|\$)" "$pr_script" | grep -vE "^[0-9]+:[[:space:]]*#" | grep -vE "(capture_command|read_with_retry)[[:space:]]+$request_function([^a-zA-Z0-9_]|\$)" || true)"
      [ -n "$other_uses" ] || continue
    fi
    unrouted="$unrouted
  $request_line"
  done <<<"$direct_requests"
  [ -z "$unrouted" ] && ok "every gh command runs through capture_command or read_with_retry" \
    || fail "a gh command bypasses the rate-limit path in capture_command:$unrouted"

  echo "==> the queue-history read includes every event that invalidates an eviction (AUT-1179)"
  # The fake serves the post-jq event list, so it cannot prove which timeline
  # item types the live query requests. This pins the contract: a retarget
  # must be fetched, or an evicted PR that was retargeted stays evicted.
  for item_type in ADDED_TO_MERGE_QUEUE_EVENT REMOVED_FROM_MERGE_QUEUE_EVENT PULL_REQUEST_COMMIT HEAD_REF_FORCE_PUSHED_EVENT BASE_REF_CHANGED_EVENT; do
    grep -qF "$item_type" "$TOUCHSTONE_ROOT/scripts/touchstone-pr.sh" \
      || fail "the queue-history query no longer requests $item_type"
  done
  grep -qF '"BaseRefChangedEvent" then "base_changed"' "$TOUCHSTONE_ROOT/scripts/touchstone-pr.sh" \
    || fail "a retarget is no longer mapped to an eviction-invalidating event"

  echo "==> workflow-run mutation selectors never rank by creation id alone"
  creation_id_selector='sort_by(.id) | last | "\(.id'
  stale_selectors="$(grep -nF "$creation_id_selector" "$TOUCHSTONE_ROOT"/scripts/*.sh || true)"
  [ -z "$stale_selectors" ] && ok "no creation-id-only workflow-run selector remains" \
    || fail "creation-id-only workflow-run selector found:
  $stale_selectors"

  echo "==> every command form the CLI prints is documented by a help surface"
  # A driver probes `--help` before trusting a subcommand, so a form the tool
  # tells them to run and the help denies exists reads as "missing command".
  # That happened on 2026-09-05: `pr open` printed `pr answer ... --finding`,
  # `touchstone pr --help` listed only open|status|merge|policy, and the driver
  # concluded the command was absent and hand-posted a body marker instead --
  # the path that fails review-binding and wedges `pr open`.
  # Truncate at the next command so trailing guidance ("then run touchstone pr
  # merge ... --head") is not mistaken for an answer flag, and drop --help,
  # which is a universal flag and a cross-reference rather than a command form.
  printed_answer_flags="$(grep -ho -- "touchstone pr answer[^\"']*" \
    "$TOUCHSTONE_ROOT"/scripts/*.sh \
    | sed -e 's/touchstone pr merge.*//' -e 's/ or run .*//' \
    | grep -oE -- '--[a-z-]+' | grep -v '^--help$' | sort -u)"
  [ -n "$printed_answer_flags" ] \
    || fail "no printed 'touchstone pr answer' guidance found; this guardrail now covers nothing"
  for printed_flag in $printed_answer_flags; do
    grep -qF -- "$printed_flag" "$TOUCHSTONE_ROOT/bin/touchstone" \
      || fail "the CLI prints 'touchstone pr answer $printed_flag' but bin/touchstone's usage does not document it"
    awk '/^Usage:/, /^EOF$/' "$TOUCHSTONE_ROOT/scripts/touchstone-pr.sh" \
      | grep -qF -- "$printed_flag" \
      || fail "the CLI prints 'touchstone pr answer $printed_flag' but 'touchstone pr --help' does not document it"
  done
  ok "every printed pr answer form is documented in both help surfaces"

  echo "==> a capacity notice never reaches the driver without its remedy"
  # The alarm and the remedy must travel together on the channel the driver
  # actually reads. The remedy shipped only in the pull-request comment while
  # stderr carried "primary reviewer declined (out of quota)" alone, and a
  # driver reading that concluded a working gate-authored review was a blocked
  # delivery it had to warn about. Any message naming the primary's capacity
  # must name how to answer what the gate reports, within the same group.
  capacity_lines="$(grep -n "at capacity" "$TOUCHSTONE_ROOT/scripts/touchstone-pr.sh" | cut -d: -f1)"
  [ -n "$capacity_lines" ] \
    || fail "no capacity notice found in touchstone-pr.sh; this guardrail now covers nothing"
  for capacity_line in $capacity_lines; do
    sed -n "${capacity_line},$((capacity_line + 3))p" \
      "$TOUCHSTONE_ROOT/scripts/touchstone-pr.sh" | grep -qF -- '--finding' \
      || fail "the capacity notice at scripts/touchstone-pr.sh:$capacity_line does not name 'pr answer --finding' within 3 lines"
  done
  ok "every capacity notice names pr answer --finding"

  echo "==> no user-facing message frames the gate-authored review as degraded"
  # "fallback" survives as the reviewFallback JSON enum value, which is a
  # documented compatibility boundary. It must not reappear in prose that tells
  # a driver the review it just got is second-best.
  grep -nE "printf.*(declined \(out of quota\)|review: fallback)" \
    "$TOUCHSTONE_ROOT/scripts/touchstone-pr.sh" \
    && fail "a user-facing message still frames the gate-authored review as a decline or a fallback" \
    || ok "no user-facing degradation framing remains"

  if [ "$ERRORS" -gt 0 ]; then
    echo "==> FAIL: $ERRORS respond-review assertion(s) failed" >&2
    exit 1
  fi
  echo "==> PASS: respond-review parses GitHub responses from stdout alone"
)

# A merged repin is not a deployed one. `policy status` assesses GitHub against
# the policy the TOOL ships, so between a repin merging and an administrator
# applying it, the tool's copy and GitHub agree and it prints "applied" while
# the branch declares a pin GitHub has not applied -- and nothing in the
# repository can request review. `pr status` binds the repository's policy at
# the PR base and reported the drift correctly, so the two readers disagreed
# about one repository at one moment (2026-09-09, touchstone#1174).
(
  echo "==> policy status names a declaration it did not assess"
  ERRORS=0
  drift_fail() {
    echo "FAIL: $*" >&2
    ERRORS=$((ERRORS + 1))
  }
  DRIFT_TMP="$(mktemp -d)"
  trap 'rm -rf "$DRIFT_TMP"' EXIT HUP INT TERM
  mkdir -p "$DRIFT_TMP/tool/policy/github" "$DRIFT_TMP/proj/policy/github"
  printf '{"pin":"OLD"}\n' >"$DRIFT_TMP/tool/policy/github/touchstone-main.json"
  printf '{"pin":"NEW"}\n' >"$DRIFT_TMP/proj/policy/github/touchstone-main.json"
  awk '/^policy_declaration_drift_note\(\) \{/,/^\}/' \
    "$TOUCHSTONE_ROOT/scripts/touchstone-pr.sh" >"$DRIFT_TMP/fn.sh"
  [ -s "$DRIFT_TMP/fn.sh" ] \
    || drift_fail "could not extract policy_declaration_drift_note from touchstone-pr.sh"
  drift_note() (
    # These four are the function's inputs, read by the fragment sourced
    # below; shellcheck cannot see through the source to their use.
    # shellcheck disable=SC2034
    PROJECT_ROOT="$1"
    # shellcheck disable=SC2034
    ENFORCEMENT_POLICY_SOURCE="policy/github/touchstone-main.json"
    # shellcheck disable=SC2034
    ENFORCEMENT_POLICY_FILE="$DRIFT_TMP/tool/policy/github/touchstone-main.json"
    # shellcheck disable=SC2034
    ENFORCEMENT_POLICY_REVISION="v3.12.0"
    # shellcheck source=/dev/null
    . "$DRIFT_TMP/fn.sh"
    policy_declaration_drift_note
  )

  OUT="$(drift_note "$DRIFT_TMP/proj")"
  case "$OUT" in
    *"declaration drift"*) ;;
    *) drift_fail "a checked-out policy differing from the assessed copy is not reported: '$OUT'" ;;
  esac
  case "$OUT" in
    *v3.12.0*) ;;
    *) drift_fail "the drift note does not name the revision that was assessed: '$OUT'" ;;
  esac

  # Identical copies are not drift: this must not fire on every ordinary run.
  cp "$DRIFT_TMP/tool/policy/github/touchstone-main.json" \
    "$DRIFT_TMP/proj/policy/github/touchstone-main.json"
  OUT="$(drift_note "$DRIFT_TMP/proj")"
  [ -z "$OUT" ] || drift_fail "identical policy copies reported drift: '$OUT'"

  # A consumer repository carries no policy of its own; silence, not an error.
  OUT="$(drift_note "$DRIFT_TMP/absent")"
  [ -z "$OUT" ] || drift_fail "a repository with no checked-out policy reported drift: '$OUT'"

  # The failure that blocked touchstone#1174 must name how to clear it.
  PIN_REMEDY="$(sed -n '/has no policy-compatible source revision/,/^    REQUIRED_WORKFLOW_REVISIONS=/p' \
    "$TOUCHSTONE_ROOT/scripts/touchstone-pr.sh")"
  case "$PIN_REMEDY" in
    *"github-policy.sh apply"*) ;;
    *) drift_fail "the pin-mismatch failure does not name the apply that clears it" ;;
  esac
  case "$PIN_REMEDY" in
    *"pr status"*) ;;
    *) drift_fail "the pin-mismatch failure does not point at the reader that names expected and observed" ;;
  esac

  rm -rf "$DRIFT_TMP"
  trap - EXIT HUP INT TERM
  if [ "$ERRORS" -ne 0 ]; then
    echo "==> FAIL: $ERRORS declaration-drift assertion(s) failed" >&2
    exit 1
  fi
  echo "==> PASS: policy status names a declaration it did not assess"
)
