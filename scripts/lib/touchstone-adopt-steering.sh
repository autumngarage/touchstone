# shellcheck shell=bash

CODEX_INSTRUCTION_LIMIT_BYTES=32768

render_consumer_markdown() {
  local source="$1" output="$2"
  awk '
    /^\*\*The mechanical guardrails\*\* that back this rule:/ {
      print "**The server guardrail.** Where the repository effective policy contains the"
      print "Touchstone organization ruleset, GitHub requires a pull request and rejects"
      print "direct pushes to the default branch. Local hooks are optional fast feedback."
      skip = "lifecycle"
      next
    }
    skip == "lifecycle" && /^## The lifecycle$/ { skip = ""; print ""; print; next }
    skip == "lifecycle" { next }
    /^The layers are complementary: the tool-boundary hook catches the intent and$/ {
      print "Local feedback and server policy are complementary when both are present."
      print "Missing local hooks do not change the branching rule; where effective GitHub"
      print "policy contains the Touchstone ruleset, the server rejects direct pushes."
      skip = "local-layers"
      next
    }
    skip == "local-layers" && /^rejects direct pushes at the server\.$/ { skip = ""; next }
    skip == "local-layers" { next }
    /^[0-9][0-9]*\. \*\*Answer every piece of PR feedback before merging\.\*\*/ {
      match($0, /^[0-9][0-9]*/)
      ordinal = substr($0, RSTART, RLENGTH)
      print ordinal ". **Answer every piece of PR feedback before merging.** Reply to each comment and resolve its thread, whoever left it. Where effective policy requires conversation resolution, GitHub blocks unresolved threads; elsewhere resolving them remains mandatory driver procedure."
      next
    }
    /^- \*\*Hard-won lesson worth capturing\*\*.*Hard-Won Lessons/ {
      print "- **Hard-won lesson worth capturing** → file the issue and record the lesson in durable project documentation."
      next
    }
    /^\*\*The mechanical steps\.\*\*$/ {
      print "**The mechanical steps for a GitHub issue.**"
      print ""
      print "```bash"
      print "me=\"$(gh api user --jq .login)\""
      print "owners=\"$(gh issue view <n> --json assignees --jq \".assignees[].login\")\""
      print "[ -z \"$owners\" ] || [ \"$owners\" = \"$me\" ] || exit 1"
      print "gh issue edit <n> --add-assignee \"$me\""
      print "owners=\"$(gh issue view <n> --json assignees --jq \".assignees[].login\")\""
      print "if [ \"$owners\" != \"$me\" ]; then"
      print "  gh issue edit <n> --remove-assignee \"$me\""
      print "  exit 1"
      print "fi"
      print "gh issue comment <n> --body \"Dispatched. Branch \\`<branch>\\`, worktree at \\`<path>\\`. <agent type> implementing.\""
      print "```"
      print ""
      print "The first read avoids disturbing an existing owner. The second detects a race;"
      print "the losing agent removes only its own assignment and publishes no false dispatch"
      print "signal. For a non-GitHub tracker, use its configured adapter to perform the same"
      print "claim, verification, and dispatch transition."
      skip = "claim-mechanics"
      next
    }
    skip == "claim-mechanics" && /^Then start the agent\. Not after\.$/ { skip = ""; print; next }
    skip == "claim-mechanics" { next }
    /^\*\*Deterministic enforcement\.\*\*/ { skip = "claim-enforcement"; next }
    skip == "claim-enforcement" && /^## Parallel work with worktrees$/ { skip = ""; print; next }
    skip == "claim-enforcement" { next }
    /^parallel lanes\. Pipeline fixes include the delivery prose in$/ {
      print "parallel lanes. Pipeline fixes include delivery steering, effective GitHub"
      print "policy, and local hooks. Every"
      skip = "pipeline-surfaces"
      next
    }
    skip == "pipeline-surfaces" && /^and pre-commit hooks\. Every$/ { skip = ""; next }
    skip == "pipeline-surfaces" { next }
    { print }
  ' "$source" | sed \
    -e 's#Use the `touchstone-audit-weak-points` skill (Claude) or read `principles/audit-weak-points.md` (other drivers)\.#Read `principles/audit-weak-points.md`.#' \
    -e '/^Claude Code agents: the bundled `touchstone-\*` and `memory-audit` skills mirror this table in your session header\. Trust whichever surface fires first\.$/d' \
    -e 's#Use the `touchstone-audit-weak-points` skill\.#Follow the procedure in `principles/audit-weak-points.md`.#' \
    -e 's#^Claude Code agents have the `memory-audit` skill for this\. Run it when a$#Run this audit when a#' \
    -e 's#^user never agreed to the change\. Drivers without the `memory-audit` skill owe$#user never agreed to the change. Every driver owes#' \
    -e 's#`bash scripts/claim-issue\.sh <n>`#`gh issue edit <n> --add-assignee @me`#g' \
    -e 's#^bash scripts/claim-issue\.sh <n>$#gh issue edit <n> --add-assignee @me#' \
    -e 's#`bash scripts/respond-review\.sh <pr> --comment-id <id> --body-file <file>` replies and resolves in one step; `--all-resolved-check` proves none remain\.#reply through GitHub, resolve the exact thread, and re-read all threads to prove none remain.#' \
    -e 's#^Answer each finding with the canonical response command instead of hand-rolling API calls:$#Answer each finding through GitHub review APIs: reply, resolve the exact thread, then re-read all threads:#' \
    -e 's#^bash scripts/respond-review\.sh <pr> --comment-id <id> --body-file <file> \[--fix-commit <sha>\]$#gh api repos/<owner>/<repo>/pulls/<pr>/comments/<id>/replies -F body=@<file>#' \
    -e 's#^bash scripts/respond-review\.sh <pr> --all-resolved-check$#\# Resolve through GitHub GraphQL, then rerun the reviewThreads query below.#' \
    -e '/^It posts the threaded reply, resolves the thread, and verifies the resolution stuck,/d' \
    -e '/^with bounded retries for transient API failures\./d' \
    -e 's#^The raw equivalent, if you need it: reply with #Reply with #' \
    -e 's#-f body=@<file>#-F body=@<file>#g' \
    -e 's#principles/#.touchstone/principles/#g' \
    >"$output" || operational_failure "could not render consumer steering"
  if grep -Eq 'scripts/(claim-issue|respond-review|issue-claim-check)\.sh|hooks/branch-guard\.sh|\.github/workflows/|\.pre-commit-config\.yaml' "$output"; then
    operational_failure "consumer steering retained a repository-local enforcement surface"
  fi
}

render_consumer_steering() {
  local output="$1"
  render_consumer_markdown "$SCRIPT_ROOT/TOUCHSTONE.md" "$output"
}

render_inline_block() {
  local steering="$1" output="$2"
  {
    printf '%s\n\n' "$TOUCHSTONE_BLOCK_BEGIN"
    printf '%s\n' '<!-- Managed by touchstone upgrade. Edit content outside the markers. -->'
    printf '\n'
    cat "$steering"
    printf '\n%s\n' "$TOUCHSTONE_BLOCK_END"
  } >"$output" || operational_failure "could not render inline consumer steering"
}

render_claude_block() {
  local output="$1"
  {
    printf '%s\n\n' "$TOUCHSTONE_BLOCK_BEGIN"
    printf '%s\n' '<!-- Managed by touchstone upgrade. Edit content outside the markers. -->'
    printf '\n## Touchstone universal steering\n\n'
    printf '@.touchstone/TOUCHSTONE.md\n\n'
    printf '%s\n' "$TOUCHSTONE_BLOCK_END"
  } >"$output" || operational_failure "could not render Claude consumer steering"
}

merge_managed_block() {
  local destination="$1" block="$2" output="$3" default_heading="$4"
  local begin_count end_count begin_line end_line in_block=false inserted=false line comparison terminated
  if [ ! -e "$destination" ]; then
    {
      printf '# %s\n\n' "$default_heading"
      cat "$block"
    } >"$output" || operational_failure "could not create steering file ${destination#"$PROJECT_ROOT"/}"
    check_rendered_steering_size "$destination" "$output"
    return 0
  fi
  [ -f "$destination" ] || contract_refusal "steering path is not a regular file: ${destination#"$PROJECT_ROOT"/}"
  begin_count="$(awk -v marker="$TOUCHSTONE_BLOCK_BEGIN" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) count++ } END { print count + 0 }' "$destination")"
  end_count="$(awk -v marker="$TOUCHSTONE_BLOCK_END" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) count++ } END { print count + 0 }' "$destination")"
  if [ "$begin_count" -ne "$end_count" ] || [ "$begin_count" -gt 1 ]; then
    contract_refusal "steering markers are malformed in ${destination#"$PROJECT_ROOT"/}"
  fi
  if [ "$begin_count" -eq 0 ]; then
    cat "$block" >"$output" \
      || operational_failure "could not stage steering file ${destination#"$PROJECT_ROOT"/}"
    if [ -s "$destination" ]; then
      printf '\n' >>"$output" \
        || operational_failure "could not extend steering file ${destination#"$PROJECT_ROOT"/}"
      cat "$destination" >>"$output" \
        || operational_failure "could not preserve steering file ${destination#"$PROJECT_ROOT"/}"
    fi
    check_rendered_steering_size "$destination" "$output"
    return 0
  fi
  begin_line="$(awk -v marker="$TOUCHSTONE_BLOCK_BEGIN" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) print NR }' "$destination")"
  end_line="$(awk -v marker="$TOUCHSTONE_BLOCK_END" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) print NR }' "$destination")"
  if [ "$begin_line" -ge "$end_line" ]; then
    contract_refusal "steering markers are out of order in ${destination#"$PROJECT_ROOT"/}"
  fi
  while true; do
    line=""
    if IFS= read -r line; then
      terminated=true
    else
      [ -n "$line" ] || break
      terminated=false
    fi
    comparison="${line%"$CR"}"
    if [ "$in_block" = true ]; then
      if [ "$comparison" = "$TOUCHSTONE_BLOCK_END" ]; then in_block=false; fi
      continue
    fi
    if [ "$comparison" = "$TOUCHSTONE_BLOCK_BEGIN" ]; then
      if [ "$inserted" = false ]; then
        cat "$block" >>"$output" \
          || operational_failure "could not replace steering block in ${destination#"$PROJECT_ROOT"/}"
        inserted=true
      fi
      in_block=true
      continue
    fi
    if [ "$terminated" = true ]; then
      printf '%s\n' "$line" >>"$output" \
        || operational_failure "could not preserve steering file ${destination#"$PROJECT_ROOT"/}"
    else
      printf '%s' "$line" >>"$output" \
        || operational_failure "could not preserve steering file ${destination#"$PROJECT_ROOT"/}"
    fi
  done <"$destination"
  check_rendered_steering_size "$destination" "$output"
}

check_rendered_steering_size() {
  local destination="$1" output="$2" size
  [ "$(basename "$destination")" = AGENTS.md ] || return 0
  size="$(wc -c <"$output" | awk '{ print $1 }')" \
    || operational_failure "could not measure rendered AGENTS.md"
  [ "$size" -le "$CODEX_INSTRUCTION_LIMIT_BYTES" ] || contract_refusal \
    "AGENTS.md would exceed Codex's ${CODEX_INSTRUCTION_LIMIT_BYTES}-byte instruction limit; shorten project-owned guidance or move it to routed documents"
}

managed_block_present() {
  local relative="$1" destination
  local begin_count end_count begin_line end_line
  destination="$PROJECT_ROOT/$relative"
  safe_owned_path "$relative"
  [ -e "$destination" ] || return 1
  [ -f "$destination" ] || contract_refusal "steering path is not a regular file: $relative"
  begin_count="$(awk -v marker="$TOUCHSTONE_BLOCK_BEGIN" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) count++ } END { print count + 0 }' "$destination")"
  end_count="$(awk -v marker="$TOUCHSTONE_BLOCK_END" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) count++ } END { print count + 0 }' "$destination")"
  if [ "$begin_count" -ne "$end_count" ] || [ "$begin_count" -gt 1 ]; then
    contract_refusal "steering markers are malformed in $relative"
  fi
  [ "$begin_count" -eq 1 ] || return 1
  begin_line="$(awk -v marker="$TOUCHSTONE_BLOCK_BEGIN" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) print NR }' "$destination")"
  end_line="$(awk -v marker="$TOUCHSTONE_BLOCK_END" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) print NR }' "$destination")"
  [ "$begin_line" -lt "$end_line" ] || contract_refusal "steering markers are out of order in $relative"
  return 0
}

plan_steering() {
  local refresh="$1"
  local consumer="$PLAN_ROOT/consumer-touchstone.md" inline="$PLAN_ROOT/inline-block.md"
  local block_consumer claude="$PLAN_ROOT/claude-block.md" proposed file relative rendered_principle
  render_consumer_steering "$consumer"
  plan_managed_file .touchstone/TOUCHSTONE.md "$consumer" "$refresh"
  block_consumer="$consumer"
  if [ "$refresh" = false ] && [ -f "$PROJECT_ROOT/.touchstone/TOUCHSTONE.md" ] \
    && [ ! -L "$PROJECT_ROOT/.touchstone/TOUCHSTONE.md" ]; then
    block_consumer="$PROJECT_ROOT/.touchstone/TOUCHSTONE.md"
  fi
  for file in "$SCRIPT_ROOT"/principles/*.md; do
    [ "$(basename "$file")" != README.md ] || continue
    relative=".touchstone/principles/$(basename "$file")"
    rendered_principle="$PLAN_ROOT/principle-$(basename "$file")"
    render_consumer_markdown "$file" "$rendered_principle"
    plan_managed_file "$relative" "$rendered_principle" "$refresh"
  done
  render_inline_block "$block_consumer" "$inline"
  render_claude_block "$claude"
  for file in AGENTS.md GEMINI.md; do
    if [ "$refresh" = false ] && managed_block_present "$file"; then continue; fi
    proposed="$PLAN_ROOT/proposed-$file"
    : >"$proposed" || operational_failure "could not initialize proposed steering for $file"
    merge_managed_block "$PROJECT_ROOT/$file" "$inline" "$proposed" "$file instructions"
    plan_file "$file" "$proposed" marked-block
  done
  if [ "$refresh" = false ] && managed_block_present CLAUDE.md; then return 0; fi
  proposed="$PLAN_ROOT/proposed-CLAUDE.md"
  : >"$proposed" || operational_failure "could not initialize proposed steering for CLAUDE.md"
  merge_managed_block "$PROJECT_ROOT/CLAUDE.md" "$claude" "$proposed" "Claude Code instructions"
  plan_file CLAUDE.md "$proposed" marked-block
}
