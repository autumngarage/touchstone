# shellcheck shell=bash
# Sourced by github-policy.sh. The receipt captures intent before the first
# remote write. Every re-entry reconciles against both live rulesets.
repin_queue() {
  local query
  query='query($owner:String!,$name:String!,$branch:String!){repository(owner:$owner,name:$name){mergeQueue(branch:$branch){id entries(first:100){totalCount nodes{id position state headCommit{oid} baseCommit{oid} pullRequest{id number headRefOid}}}}}}'
  api graphql -f query="$query" -f owner="$ORG" -f name="$REPOSITORY" -f branch="$BRANCH" \
    | jq -ce '
      def sha: type=="string" and test("^[0-9a-f]{40}$");
      def waiting: .state=="QUEUED" and .headCommit==null and .baseCommit==null;
      select((.errors // [])==[]) | .data.repository.mergeQueue
      | select((.id|type)=="string" and (.entries.nodes|type)=="array"
          and .entries.totalCount==(.entries.nodes|length))
      | .entries=.entries.nodes
      | select(all(.entries[]; (.id|type)=="string" and (.pullRequest.id|type)=="string"
          and (.pullRequest.headRefOid|sha) and (.pullRequest.number|type)=="number"
          and has("headCommit") and has("baseCommit")
          and (waiting or ((.headCommit.oid|sha) and (.baseCommit.oid|sha)))))
      | select(([.entries[].id]|unique|length)==(.entries|length)
          and [.entries[].position]==[range(1; (.entries|length)+1)])'
}

repin_receipt() {
  local phase="$1" tmp
  tmp="$(mktemp "${ARTIFACT}.XXXXXX")" || return 1
  jq --arg phase "$phase" '.phase=$phase' <<<"$receipt" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  if [ "$phase" = prepared ]; then
    ln "$tmp" "$ARTIFACT" || {
      rm -f "$tmp"
      die "another maintenance receipt already exists"
    }
    rm -f "$tmp"
  else
    mv "$tmp" "$ARTIFACT"
  fi
  receipt="$(cat "$ARTIFACT")"
}

repin_run_inventory() {
  local sha response inventory='{}'
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    response="$(api "repos/$ORG/$REPOSITORY/actions/runs?event=merge_group&head_sha=$sha&per_page=100")" || return 1
    inventory="$(jq -cen --argjson inventory "$inventory" --argjson runs "$response" --arg sha "$sha" '
      $runs | select((.workflow_runs|type)=="array" and .total_count==(.workflow_runs|length))
      | select(all(.workflow_runs[]; .event=="merge_group" and .head_sha==$sha and (.id|type)=="number" and (.status|type)=="string"))
      | $inventory + {($sha):[.workflow_runs[]|{id,status}]}')" || return 1
  done < <(jq -r '.entries[].headCommit.oid // empty' <<<"$1" | sort -u)
  printf '%s\n' "$inventory"
}

maintain_validation_pin() {
  local receipt current target queue normal paused snapshot phase original runs queue_revision after
  verify_clean_checkout
  [ "$POLICY_TYPE" = consumer ] || die "validation-only maintenance requires a consumer policy"
  [ ! -L "$ARTIFACT" ] || die "maintenance receipt must be a regular local file"
  normal="$(normalize_ruleset <<<"$DESIRED_REPO_RULESET")"
  paused="$(jq -eS '
    select(.enforcement=="active" and ([.rules[]|select(.type=="merge_queue")]|length)==1)
    | select((.rules[]|select(.type=="merge_queue").parameters.max_entries_to_build) |
        type=="number" and .>=1 and .<=100 and floor==.)
    | (.rules[]|select(.type=="merge_queue").parameters.max_entries_to_build)=0' <<<"$normal")" || die "reviewed policy needs a positive native queue limit"
  target="$(jq '.managedRuleset' "$POLICY" | normalize_ruleset)"
  current="$(managed_ruleset_json)" && [ "$current" != null ] || die "organization ruleset missing"
  queue="$(managed_repo_ruleset_json)" && [ "$queue" != null ] || die "repository ruleset missing"
  queue_revision="$(jq -er '.updated_at | select(type=="string" and length>0)' <<<"$queue")" || die "queue revision missing"
  if [ ! -f "$ARTIFACT" ]; then
    [ "$COMMAND" = repin-validation ] || die "no maintenance window to resume"
    verify_source
    verify_policy_state "$current" null "$normal"
    [ "$(auto_merge_setting)" = true ] || die "automatic merge must already be enabled"
    original="$(normalize_ruleset <<<"$current")"
    jq -en --argjson original "$original" --argjson target "$target" '
      def validator: .rules[]|select(.type=="workflows").parameters.workflows[]|select(.path==".github/workflows/validate.yml");
      [$target|validator.sha] as $next | [$original|validator.sha] as $old
      | ($next|length)==1 and ($old|length)==1 and $next!=$old
        and all(($next+$old)[]; type=="string" and test("^[0-9a-f]{40}$"))
        and (($original | (validator.sha)=$next[0])==$target)' >/dev/null || die "only a validation SHA change is supported"
    snapshot="$(repin_queue)" || die "native queue inventory incomplete"
    runs="$(repin_run_inventory "$snapshot")" || die "could not capture active candidate runs"
    receipt="$(jq -cn --arg repo "$ORG/$REPOSITORY" --arg branch "$BRANCH" --argjson old "$original" \
      --argjson target "$target" --argjson queue "$snapshot" --argjson runs "$runs" --argjson normal "$normal" \
      --argjson orgID "$(jq -er .id <<<"$current")" --argjson repoID "$(jq -er .id <<<"$queue")" \
      '{schema:1,repo:$repo,branch:$branch,old:$old,target:$target,queue:$queue,runs:$runs,normal:$normal,orgID:$orgID,repoID:$repoID}')"
    repin_receipt prepared
  else
    receipt="$(cat "$ARTIFACT")"
  fi
  jq -e --arg repo "$ORG/$REPOSITORY" --arg branch "$BRANCH" --argjson target "$target" --argjson normal "$normal" \
    --argjson current "$current" --argjson queue "$queue" '
      .schema==1 and .repo==$repo and .branch==$branch and .target==$target and .normal==$normal
      and .orgID==$current.id and .repoID==$queue.id and (.phase|IN("prepared","paused","repinned","restoring","closed"))
    ' <<<"$receipt" >/dev/null || die "receipt or live ruleset identity differs"
  phase="$(jq -r .phase <<<"$receipt")"
  original="$(jq -S .old <<<"$receipt")"
  current="$(normalize_ruleset <<<"$current")"
  queue="$(normalize_ruleset <<<"$queue")"
  { [ "$current" = "$original" ] || [ "$current" = "$target" ]; } || die "organization policy changed outside this window"
  { [ "$queue" = "$normal" ] || [ "$queue" = "$paused" ]; } || die "queue policy changed outside this window"
  if [ "$phase" = closed ]; then
    [ "$queue" = "$normal" ] || die "closed window cannot release a new pause"
    echo "Maintenance window already closed."
    return
  fi
  if [ "$queue" = "$paused" ] && [ "$phase" != prepared ] \
    && [ "$(jq -r .pausedRevision <<<"$receipt")" != "$queue_revision" ]; then
    die "pause ownership changed; inspect before restoring dispatch"
  fi
  if [ "$COMMAND" = resume-dispatch ] || [ "$phase" = restoring ]; then
    repin_receipt restoring
    restore_repo_ruleset "$normal"
    repin_receipt closed
    echo "Recorded native build concurrency restored."
    return
  fi
  if [ "$phase" = prepared ]; then
    [ "$current" = "$original" ] || die "pin changed before the recorded pause"
    restore_repo_ruleset "$paused"
    queue_revision="$(managed_repo_ruleset_json | jq -er .updated_at)" || die "cannot bind the paused queue revision"
    receipt="$(jq --arg rev "$queue_revision" '.pausedRevision=$rev' <<<"$receipt")"
    repin_receipt paused
  else
    [ "$queue" = "$paused" ] || die "recorded native pause is no longer active"
  fi
  snapshot="$(repin_queue)" || die "native queue inventory incomplete; dispatch remains paused"
  jq -e 'all(.entries[]; .state=="QUEUED" and .headCommit==null and .baseCommit==null)' <<<"$snapshot" >/dev/null \
    || die "old candidates still active; dispatch paused, repeat after completion"
  jq -en --argjson before "$(jq .queue <<<"$receipt")" --argjson after "$snapshot" '
    def intent: {id,pullRequest};
    $after.id==$before.id and ([$before.entries[]|select(.headCommit==null)|intent]==[$after.entries[]|intent])' >/dev/null \
    || die "waiting membership, order or reviewed heads changed; inspect and use resume-dispatch"
  runs="$(repin_run_inventory "$(jq .queue <<<"$receipt")")" || die "cannot verify outgoing candidate runs"
  jq -e 'all(.[][]; .status=="completed")' <<<"$runs" >/dev/null || die "outgoing candidate workflows still running"
  verify_source
  verify_policy_state "$current" null "$paused"
  if [ "$current" = "$original" ]; then
    ruleset_update_payload <<<"$target" | api --method PUT "orgs/$ORG/rulesets/$(jq -r .orgID <<<"$receipt")" --input - >/dev/null
  fi
  verify_policy_state "$target" null "$paused"
  api "repos/$ORG/$REPOSITORY/rules/branches/$BRANCH" | jq -e --argjson desired "$target" '
    def workflows: [.[]|select(.type=="workflows").parameters.workflows[]]|sort_by([.repository_id,.path,.ref,.sha]);
    (workflows==($desired.rules|workflows)) and ([.[]|select(.type=="merge_queue").parameters.max_entries_to_build]==[0])
    ' >/dev/null || die "effective pins or native pause differ; inspect before resuming"
  after="$(repin_queue)" && [ "$snapshot" = "$after" ] || die "waiting entries changed during repin; inspect before resuming"
  [ "$(auto_merge_setting)" = true ] || die "automatic merge is disabled; inspect before resuming"
  repin_receipt repinned
  repin_receipt restoring
  restore_repo_ruleset "$normal"
  repin_receipt closed
  echo "Validation revision verified and native dispatch restored. Qualify the first new merge-group run."
}
