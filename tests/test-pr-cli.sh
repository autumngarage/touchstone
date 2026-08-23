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

  mkdir -p "$TMP/bin" "$TMP/project" "$TMP/origin.git" "$TMP/state"
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
  git -C "$TMP/project" add README.md .touchstone.toml .touchstone-tracker.toml
  git -C "$TMP/project" commit -qm fixture
  git -C "$TMP/project" remote add origin "$TMP/origin.git"
  git -C "$TMP/project" push -qu origin main
  git -C "$TMP/project" remote set-head origin main
  MAIN_SHA="$(git -C "$TMP/project" rev-parse HEAD)"
  git -C "$TMP/project" switch -qc feat/test
  printf 'change\n' >>"$TMP/project/README.md"
  git -C "$TMP/project" add README.md
  git -C "$TMP/project" commit -qm change
  git -C "$TMP/project" push -qu origin HEAD
  HEAD_SHA="$(git -C "$TMP/project" rev-parse HEAD)"
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
  if [ -f "$GH_STATE/review-gate" ]; then
    # validate and review-gate carry the fixture's variant pin; delivery-evidence
    # stays at the policy revision, so a variant names exactly two gates.
    pin_sha="$GH_POLICY_SHA"
    evidence_sha="$GH_POLICY_SHA"
    source_id=1333343261
    [ ! -f "$GH_STATE/stale-pin" ] || pin_sha="$GH_DIVERGED_SHA"
    [ ! -f "$GH_STATE/behind-pin" ] || pin_sha="$GH_BEHIND_SHA"
    [ ! -f "$GH_STATE/offref-pin" ] || pin_sha="$GH_OFFREF_SHA"
    [ ! -f "$GH_STATE/unknown-pin" ] || pin_sha="$GH_UNKNOWN_SHA"
    [ ! -f "$GH_STATE/other-source-pin" ] || source_id=424242
    # The AUT-559 shape: the deployed ruleset pins the source branch head,
    # several revisions ahead of the policy the installed tool carries.
    if [ -f "$GH_STATE/ahead-pin" ]; then
      pin_sha="$GH_AHEAD_SHA"
      evidence_sha="$GH_AHEAD_SHA"
    fi
    queue_rule=',{"type":"merge_queue"}'
    [ ! -f "$GH_STATE/no-queue-rule" ] || queue_rule=""
    rules='['"$pr_rule"',{"type":"deletion"},{"type":"non_fast_forward"}'"$queue_rule"',{"type":"workflows","parameters":{"workflows":[{"path":".github/workflows/validate.yml","repository_id":'"$source_id"',"ref":"refs/heads/main","sha":"'"$pin_sha"'"},{"path":".github/workflows/review-gate.yml","repository_id":'"$source_id"',"ref":"refs/heads/main","sha":"'"$pin_sha"'"},{"path":".github/workflows/delivery-evidence.yml","repository_id":1333343261,"ref":"refs/heads/main","sha":"'"$evidence_sha"'"}]}}]'
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
    printf '%s' "$rules" | jq -r "$(value_after --jq "$@")"
  else
    printf '%s\n%s\n' "$page1" "$page2"
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
    if [ -n "${GH_REPO:-}" ]; then
      printf '%s\thttps://%s/%s\tmain\n' "$GH_REPO" "${GH_REPO_HOST:-github.com}" "$GH_REPO"
    else
      printf 'autumngarage/current\thttps://%s/autumngarage/current\tmain\n' "${GH_REPO_HOST:-github.com}"
    fi
    ;;
  "pr list")
    if [ -f "$GH_STATE/pr-exists" ]; then
      head="$GH_HEAD"
      [ "${GH_MODE:-ok}" = list_head_stale ] && head=stale-head-0000000000000000000000000000
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
    if has '--json headRefOid,baseRefName,baseRefOid' "$@"; then
      if [ "${GH_MODE:-ok}" = binding_moved ]; then
        printf 'moved-head\t%s\t%s\n' "$GH_BASE_REF" "$GH_BASE_SHA"
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
      if [ -f "$GH_STATE/pr-body" ]; then
        cat "$GH_STATE/pr-body"
      else
        printf '%s\n' 'Change summary.' '' 'Closes #42'
      fi
    elif has '--json state,url' "$@"; then
      if [ -f "$GH_STATE/merged" ]; then printf 'MERGED\thttps://example.test/pr/7\n'; else printf 'OPEN\thttps://example.test/pr/7\n'; fi
    elif [ -f "$GH_STATE/merged" ]; then
      printf '7\tMERGED\thttps://example.test/pr/7\t%s\tmain\tbase-sha\tUNKNOWN\tfalse\n' "$GH_HEAD"
    else
      printf '7\tOPEN\thttps://example.test/pr/7\t%s\tmain\tbase-sha\tCLEAN\tfalse\n' "$GH_HEAD"
    fi
    ;;
  "pr merge")
    if [ "${GH_MODE:-ok}" = merge_failed ]; then exit 1; fi
    if [ "${GH_MODE:-ok}" = merge_reconcile_failed ]; then
      printf 'merge rejected by rules\n' >&2
      exit 1
    fi
    case "${GH_MODE:-ok}" in merge_queue | auto_merge) exit 0 ;; esac
    touch "$GH_STATE/merged"
    case "${GH_MODE:-ok}" in merge_lied | merge_head_moved) exit 1 ;; esac
    ;;
  "issue view")
    if [ -f "$GH_STATE/merged" ]; then printf 'CLOSED\tCOMPLETED\n'; else printf 'OPEN\t\n'; fi
    ;;
  "api user") printf '%s\n' alice ;;
  "api graphql")
    if has 'mergeQueueEntry' "$@"; then
      if [ "${GH_MODE:-ok}" = merge_reconcile_failed ]; then
        printf 'GraphQL unavailable\n' >&2
        exit 1
      elif [ "${GH_MODE:-ok}" = merge_head_moved ]; then
        printf 'MERGED\thttps://example.test/pr/7\tmoved-head\tfalse\t\n'
      elif [ -f "$GH_STATE/merged" ]; then
        printf 'MERGED\thttps://example.test/pr/7\t%s\tfalse\t\n' "$GH_HEAD"
      elif [ "${GH_MODE:-ok}" = merge_queue ]; then
        printf 'OPEN\thttps://example.test/pr/7\t%s\tfalse\tQUEUED\n' "$GH_HEAD"
      elif [ "${GH_MODE:-ok}" = auto_merge ]; then
        printf 'OPEN\thttps://example.test/pr/7\t%s\ttrue\t\n' "$GH_HEAD"
      else
        printf 'OPEN\thttps://example.test/pr/7\t%s\tfalse\t\n' "$GH_HEAD"
      fi
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
    elif has 'touchstone:unguarded-merge' "$@"; then
      # The count of prior unguarded-merge records for this head, one per
      # page as --paginate delivers it: two pages, the record (if any) on the
      # second.
      if [ -f "$GH_STATE/unguarded-recorded" ]; then printf '0\n1\n'; else printf '0\n0\n'; fi
    elif has '/issues/7/comments' "$@"; then
      if [ "${GH_MODE:-ok}" = many_requests ]; then
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
      if has 'reviewId:.id' "$@"; then
        printf '%s\n' '[{"reviewId":61,"state":"COMMENTED","body":"body finding","url":"https://example.test/review","commit":"old-head"}]'
      else
        printf '%s\n' '  review 61 [COMMENTED] at old-head'
      fi
    elif has '/pulls/7/comments' "$@"; then
      if [ -f "$GH_STATE/reply" ]; then printf '%s\n' '<!-- touchstone:respond-review comment=51 -->'; fi
    fi
    ;;
  "api repos/autumngarage/current/pulls/7/comments/51/replies")
    touch "$GH_STATE/reply"
    printf '%s\n' 71
    ;;
  api*)
    if has 'actions/permissions --jq .enabled' "$@"; then
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
    elif has 'repos/autumngarage/current --jq .allow_auto_merge' "$@"; then
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
          "$GH_BEHIND_SHA" | "$GH_POLICY_SHA" | "$GH_AHEAD_SHA" | "$GH_OFFREF_SHA" | "$GH_DIVERGED_SHA") ;;
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
          "$GH_AHEAD_SHA") printf '3\n' ;;
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
    elif has 'actions/runs/77' "$@"; then
      # Single-run read. Before a re-run: attempt 1 completed. Right after a
      # re-run GitHub may still report attempt 1 completed (stale), then the
      # new attempt in progress, then attempt 2 completed.
      if has '.run_attempt' "$@" && ! has 'status' "$@"; then
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
    elif has 'actions/workflows?' "$@"; then
      printf '1\n2\n3\n'
    elif has 'rules/branches/' "$@"; then
      serve_rules "$@"
    elif has 'actions/runs?head_sha=' "$@"; then
      # Real selector over a real list: the pinned gate (run 77, unlisted
      # workflow id 999) next to a NEWER repository-local decoy of the same
      # name (run 78, listed workflow id 2) and another PR's run (79). Only
      # the jq the CLI passes decides which one it sees.
      if [ -f "$GH_STATE/review-gate" ] && [ ! -f "$GH_STATE/gate-never-runs" ]; then
        if [ -f "$GH_STATE/gate-in-progress" ]; then
          left="$(cat "$GH_STATE/gate-in-progress")"
          if [ "$left" -le 1 ]; then rm -f "$GH_STATE/gate-in-progress"; else echo $((left - 1)) >"$GH_STATE/gate-in-progress"; fi
          gate_status=in_progress
        else
          gate_status=completed
        fi
        runs="{\"workflow_runs\":[
          {\"id\":77,\"name\":\"review-gate\",\"event\":\"pull_request\",\"status\":\"$gate_status\",\"workflow_id\":999,\"pull_requests\":[{\"number\":7}]},
          {\"id\":78,\"name\":\"review-gate\",\"event\":\"pull_request\",\"status\":\"completed\",\"workflow_id\":2,\"pull_requests\":[{\"number\":7}]},
          {\"id\":79,\"name\":\"review-gate\",\"event\":\"pull_request\",\"status\":\"completed\",\"workflow_id\":999,\"pull_requests\":[{\"number\":8}]}]}"
      else
        runs='{"workflow_runs":[]}'
      fi
      printf '%s' "$runs" | jq -r "$(value_after --jq "$@")"
    elif has '/issues/comments/1' "$@"; then
      [ "${GH_MODE:-ok}" = live_comment_invalid ] || printf '%s\n' 1
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
  GH_AHEAD_SHA=9ab13f0c5d2e47bb8c6a1f30d94e7c2b5a08d613
  GH_OFFREF_SHA=3d5c7e91b02a4f68d17c9ae5b436f0c82d197ae4
  GH_DIVERGED_SHA=1f0b9d4c8e37a25610cd9f8b47e3a05c6d21f9b8
  GH_UNKNOWN_SHA=0000000000000000000000000000000000000000
  GH_SOURCE_HEAD="$GH_AHEAD_SHA"
  export PATH="$TMP/bin:$PATH" GH_CALLS="$TMP/calls" GH_STATE="$TMP/state" GH_HEAD="$HEAD_SHA" GH_POLICY_SHA
  export GH_BEHIND_SHA GH_AHEAD_SHA GH_OFFREF_SHA GH_DIVERGED_SHA GH_UNKNOWN_SHA GH_SOURCE_HEAD
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

  echo "==> status is versioned, read-only, and retries bounded transport failures"
  touch "$TMP/state/pr-exists"
  GH_MODE=read_retry run_pr "$TMP/out" status 7 --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"schema":"touchstone.pr/v1"'
  assert_has "$TMP/out" '"status":"observed"'
  assert_has "$TMP/out" "\"head\":\"$HEAD_SHA\""
  [ "$(grep -c '^pr view' "$GH_CALLS")" -eq 2 ] || fail "status did not retry exactly once"
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

  echo "==> open re-runs the pinned review gate where the repository has one"
  touch "$TMP/state/review-gate"
  rm -f "$TMP/state/gate-reruns" "$TMP/state/review-request"
  run_pr "$TMP/out" open --title 'Gate' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  [ -f "$TMP/state/gate-reruns" ] && grep -q 'rerun 77' "$TMP/state/gate-reruns" \
    || fail "open did not re-run the review-gate run for the head"
  rm -f "$TMP/state/gate-reruns"
  echo 3 >"$TMP/state/gate-in-progress"
  run_pr "$TMP/out" open --title 'Gate' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  grep -q 'rerun 77' "$TMP/state/gate-reruns" 2>/dev/null \
    || fail "open did not wait for an in-progress gate run before re-running it"
  [ "$(grep -c 'actions/runs?head_sha=' "$GH_CALLS")" -ge 2 ] \
    || fail "open did not poll the in-progress gate run"
  rm -f "$TMP/state/review-gate" "$TMP/state/gate-reruns"

  echo "==> open converges a reused PR on the title and body given (AUT-437)"
  # The PR exists with the original body; a second open with a different
  # body must apply it and say so, and a third with the same body must not
  # edit again. Silently keeping the old body let the delivery-evidence gate
  # fail with no signal from the one command the driver is told to use.
  rm -f "$TMP/state/edits" "$TMP/state/pr-title"
  printf 'Original body.\n' >"$TMP/state/pr-body"
  printf 'Corrected body with ## Review tier\n' >"$TMP/body2"
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body2" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"body":"updated"'
  grep -q -- '--body-file' "$TMP/state/edits" && [ "$(cat "$TMP/state/pr-body")" = "$(cat "$TMP/body2")" ] \
    && ok "changed body applied on reuse" || fail "body not applied on reuse: $(cat "$TMP/state/edits" 2>/dev/null)"
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
  GH_MODE=list_head_stale run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body2" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'does not match local/remote head'
  [ ! -f "$TMP/state/edits" ] && ok "no edit before the head check refuses" || fail "a drifted PR was edited before being refused"
  rm -f "$TMP/state/pr-body"
  # A freshly created PR carries the body by construction and says nothing
  # about applying it.
  rm -f "$TMP/state/pr-exists"
  run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"opened"'
  assert_not_has "$TMP/out" '"body":'

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
  touch "$TMP/state/pr-exists"
  GH_HEAD=wrong run_pr "$TMP/out" open --title 'Test PR' --body-file "$TMP/body" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'does not match local/remote head'
  GH_HEAD="$HEAD_SHA"
  rm -f "$TMP/state/pr-exists"
  caller_directory="$PWD"
  canonical_body="$(cd "$TMP" && pwd -P)/body"
  cd "$TMP"
  GH_MODE=create_lied run_pr "$TMP/out" open --title 'Test PR' --body-file body --json
  cd "$caller_directory"
  assert_rc "$RUN_RC" 0
  assert_has "$TMP/out" '"status":"opened"'
  assert_has "$TMP/out" '"reviewRequest":"posted:'
  # The result names the branch it acted on. Two pull requests were opened for
  # the wrong branch, and nothing in the output would have shown it.
  assert_has "$TMP/out" '"branch":"feat/test"'
  assert_has "$GH_CALLS" "pr create --repo github.com/autumngarage/current --head feat/test --base main --title Test PR --body-file $canonical_body"
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

  GH_BASE_REF=release GH_BASE_SHA=release-sha \
    run_pr "$TMP/out" open --title 'Retargeted PR' --body-file "$TMP/body" \
    --base release --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'already has a review request for different base coordinates'
  rm -f "$TMP/state/review-request"
  GH_BASE_REF=release GH_BASE_SHA=release-sha \
    run_pr "$TMP/out" open --title 'Retargeted PR' --body-file "$TMP/body" \
    --base release --json
  assert_rc "$RUN_RC" 0
  assert_has "$GH_CALLS" "touchstone:pr-open head=$HEAD_SHA base=release base_sha=release-sha"
  GH_BASE_REF=main
  GH_BASE_SHA=base-sha

  echo "==> review findings and responses stay on the canonical GitHub surface"
  run_pr "$TMP/out" findings 7 --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'touchstone pr open'
  run_pr "$TMP/out" respond 7 --comment-id 51 --body-file "$TMP/reply" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'touchstone pr open'

  echo "==> merge asks the pinned gate to re-evaluate, then asks GitHub to merge"
  touch "$TMP/state/review-gate" "$TMP/state/pr-exists"
  rm -f "$TMP/state/gate-reruns" "$TMP/state/gate-after-rerun"
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 0
  grep -q 'rerun 77' "$TMP/state/gate-reruns" 2>/dev/null \
    || fail "merge did not ask the review gate to re-evaluate before requesting the merge"
  assert_has "$GH_CALLS" 'pr merge'
  # The stale superseded attempt was visible once after the POST; merge waited
  # for attempt 2 to appear before asking GitHub to merge.
  [ "$(grep -c "actions/runs/77 --jq .run_attempt" "$GH_CALLS")" -ge 3 ] \
    || fail "merge did not wait for the new gate attempt to be visible: $(grep -c 'actions/runs/77 ' "$GH_CALLS") run reads"
  rm -f "$TMP/state/gate-reruns" "$TMP/state/gate-after-rerun" "$TMP/state/merged"
  GH_MODE=moved_during_gate run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 2
  assert_has "$TMP/out" 'moved (head moved-head'
  assert_not_has "$GH_CALLS" 'pr merge'
  # The verdict is GitHub's: merge is requested regardless of what the gate
  # will conclude; GitHub arms auto-merge or enqueues.
  rm -f "$TMP/state/gate-reruns" "$TMP/state/gate-after-rerun" "$TMP/state/merged"
  GH_GATE_CONCLUSION=failure run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 0
  assert_has "$GH_CALLS" 'pr merge'
  rm -f "$TMP/state/review-gate" "$TMP/state/gate-reruns" "$TMP/state/gate-after-rerun"

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
  touch "$TMP/state/review-gate"
  run_pr "$TMP/out" policy-status --json
  assert_has "$TMP/out" '"enforcement":{"status":"applied","missing":[]}'
  # The same paths from a stale revision are not the canonical gates, and a
  # stale gate does not take the guarded merge path either.
  touch "$TMP/state/stale-pin"
  run_pr "$TMP/out" policy-status --json
  assert_has "$TMP/out" '"status":"partial"'
  assert_has "$TMP/out" 'review-gate workflow (present but not pinned at the policy revision)'
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
  : >"$GH_CALLS"
  rm -f "$TMP/state/merged" "$TMP/state/gate-reruns" "$TMP/state/gate-after-rerun"
  run_pr "$TMP/out" merge 7 --head "$HEAD_SHA" --json
  assert_rc "$RUN_RC" 0
  assert_has "$GH_CALLS" 'pr merge'
  rm -f "$TMP/state/ahead-pin" "$TMP/state/merged" "$TMP/state/gate-reruns" "$TMP/state/gate-after-rerun"

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
  assert_has "$TMP/out" 'no review-gate run can exist for'
  assert_has "$TMP/out" 'repository Actions are disabled for autumngarage/current'
  assert_not_has "$TMP/out" 'Wait for the gate run to finish'
  rm -f "$TMP/state/review-gate" "$TMP/state/gate-never-runs" "$TMP/state/actions-disabled-after-preflight" "$TMP/state/actions-preflight-seen" "$TMP/state/review-request"
  touch "$TMP/state/review-gate"
  # A consumer derived --no-queue expects no queue: the tool consults the
  # repository's own shipped policy, reports applied without a queue rule,
  # and merges by arming auto-merge (there is no queue to enter).
  mkdir -p "$TMP/tool2/policy/github/consumers"
  cp -R "$ROOT/bin" "$ROOT/scripts" "$TMP/tool2/"
  cp "$ROOT/VERSION" "$TMP/tool2/VERSION"
  cp "$ROOT/policy/github/touchstone-main.json" "$TMP/tool2/policy/github/touchstone-main.json"
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
  assert_has "$TMP/out" '"enforcement":{"status":"applied","missing":[]}'
  : >"$GH_CALLS"
  rm -f "$TMP/state/merged" "$TMP/state/gate-reruns" "$TMP/state/gate-after-rerun"
  set +e
  GH_MODE=auto_merge bash "$TMP/tool2/bin/touchstone" pr merge 7 --head "$HEAD_SHA" --project "$TMP/project" --json >"$TMP/out" 2>&1
  RUN_RC=$?
  set -e
  assert_rc "$RUN_RC" 0
  grep -q '^pr merge.*--auto' "$GH_CALLS" || fail "a queue-less consumer merge did not arm auto-merge: $(grep '^pr merge' "$GH_CALLS")"
  assert_has "$TMP/out" '"status":"auto-merge-enabled"'
  touch "$TMP/state/auto-merge-off"
  set +e
  bash "$TMP/tool2/bin/touchstone" pr policy-status --project "$TMP/project" --json >"$TMP/out" 2>&1
  set -e
  assert_has "$TMP/out" '"missing":["auto-merge setting"]'
  rm -f "$TMP/state/auto-merge-off" "$TMP/state/no-queue-rule"
  run_pr "$TMP/out" status 7 --json
  assert_has "$TMP/out" '"enforcement":{"status":"applied","missing":[]}'
  run_pr "$TMP/out" status 7
  assert_has "$TMP/out" 'enforcement on main: applied'
  rm -f "$TMP/state/review-gate"
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
case "$1 $2" in
  "repo view")
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
    echo "71"
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
      runs="{\"workflow_runs\":[
        {\"id\":77,\"name\":\"review-gate\",\"status\":\"$gate_status\",\"workflow_id\":999,\"pull_requests\":[{\"number\":7}]},
        {\"id\":78,\"name\":\"review-gate\",\"status\":\"completed\",\"workflow_id\":2,\"pull_requests\":[{\"number\":7}]}]}"
    else
      runs='{"workflow_runs":[]}'
    fi
    printf '%s' "$runs" | jq -r "$(value_after --jq "$@")"
    ;;
  "api -X")
    # POST .../actions/runs/77/rerun
    has 'actions/runs/77/rerun' "$@" && echo "rerun 77" >>"$GH_STATE/gate-reruns"
    ;;
  *) exit 1 ;;
esac
exit 0
STUB
  chmod +x "$RR/bin/gh"
  export PATH="$RR/bin:$PATH" GH_STATE="$RR/state"

  printf 'Fixed.\n' >"$RR/body"
  run() {
    set +e
    bash "$TOUCHSTONE_ROOT/scripts/respond-review.sh" "$@" >"$RR/out" 2>&1
    RUN_RC=$?
    set -e
  }

  echo "==> a reply is posted once and the id is parsed from stdout alone"
  run 7 --comment-id 51 --body-file "$RR/body"
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
  run 7 --comment-id 51 --body-file "$RR/body"
  [ "$RUN_RC" -ne 0 ] && grep -qF 'PR head moved from abcdef0123456789abcdef0123456789abcdef01 to feedface' "$RR/out" \
    && ok "moved head refused with both SHAs named" \
    || fail "moved head was not refused (rc=$RUN_RC): $(tail -2 "$RR/out")"
  grep -qF 'pr merge 7 --head' "$RR/out" && fail "merge hint printed for a moved head" || true
  rm -f "$GH_STATE/moved-head"

  echo "==> a rerun recognises its own reply despite stderr noise on the login read"
  run 7 --comment-id 51 --body-file "$RR/body"
  [ "$RUN_RC" -eq 0 ] || fail "rerun exited $RUN_RC"
  replies="$(wc -l <"$GH_STATE/replies" | tr -d ' ')"
  [ "$replies" -eq 1 ] && ok "no duplicate reply posted" \
    || fail "rerun posted a duplicate reply (replies=$replies): author check read stderr"
  grep -qF 'matched our own reply as @alice' "$RR/out" && ok "author parsed as alice" \
    || fail "author was not parsed cleanly: $(grep 'matched' "$RR/out")"

  echo "==> an answer re-runs the pinned review gate where the repository has one"
  touch "$GH_STATE/review-gate"
  rm -f "$GH_STATE/gate-reruns"
  run 7 --comment-id 51 --body-file "$RR/body"
  [ "$RUN_RC" -eq 0 ] || fail "answer with a review gate exited $RUN_RC"
  grep -q 'rerun 77' "$GH_STATE/gate-reruns" 2>/dev/null && ok "answer re-ran the review gate" \
    || fail "answer did not re-run the review gate"
  rm -f "$GH_STATE/gate-reruns"
  # The run stays in progress for longer than the GraphQL transport retry
  # would tolerate; the gate wait has its own budget.
  echo 6 >"$GH_STATE/gate-in-progress"
  TOUCHSTONE_GATE_RETRY_DELAY=0 run 7 --comment-id 51 --body-file "$RR/body"
  [ "$RUN_RC" -eq 0 ] || fail "answer gave up on a gate run that was still in progress (rc=$RUN_RC)"
  grep -q 'rerun 77' "$GH_STATE/gate-reruns" 2>/dev/null && ok "answer waited for an in-progress gate run" \
    || fail "answer skipped the refresh while the gate run was in progress"
  rm -f "$GH_STATE/review-gate"

  echo "==> --all-resolved-check reads the thread list from stdout alone"
  run 7 --all-resolved-check
  [ "$RUN_RC" -eq 0 ] && ok "resolved PR passes the check" || {
    fail "all-resolved-check exited $RUN_RC"
    cat "$RR/out"
  }

  echo "==> a failed read still surfaces its diagnostics"
  GH_MODE=fail_user run 7 --comment-id 51 --body-file "$RR/body"
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

  if [ "$ERRORS" -gt 0 ]; then
    echo "==> FAIL: $ERRORS respond-review assertion(s) failed" >&2
    exit 1
  fi
  echo "==> PASS: respond-review parses GitHub responses from stdout alone"
)
