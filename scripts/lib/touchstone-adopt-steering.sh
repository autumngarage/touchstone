# shellcheck shell=bash

CODEX_INSTRUCTION_LIMIT_BYTES=32768

render_consumer_markdown() {
  local source="$1" output="$2"
  sed \
    -e 's#Use the `touchstone-audit-weak-points` skill (Claude) or read `principles/audit-weak-points.md` (other drivers)\.#Read `principles/audit-weak-points.md`.#' \
    -e '/^Claude Code agents: the bundled `touchstone-\*` and `memory-audit` skills mirror this table in your session header\. Trust whichever surface fires first\.$/d' \
    -e 's#Use the `touchstone-audit-weak-points` skill\.#Follow the procedure in `principles/audit-weak-points.md`.#' \
    -e 's#^Claude Code agents have the `memory-audit` skill for this\. Run it when a$#Run this audit when a#' \
    -e 's#^user never agreed to the change\. Drivers without the `memory-audit` skill owe$#user never agreed to the change. Every driver owes#' \
    -e 's#principles/#.touchstone/principles/#g' \
    "$source" \
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
    cat "$steering" || operational_failure "could not read rendered consumer steering"
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

require_tracked_steering_file() {
  local relative="$1"
  git -C "$PROJECT_ROOT" ls-files --error-unmatch -- "$relative" >/dev/null 2>&1 \
    || contract_refusal "steering integration '$relative' is not tracked; commit it or remove it before planning"
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
    if [ "$refresh" = false ] && managed_block_present "$file"; then
      require_tracked_steering_file "$file"
      continue
    fi
    proposed="$PLAN_ROOT/proposed-$file"
    : >"$proposed" || operational_failure "could not initialize proposed steering for $file"
    merge_managed_block "$PROJECT_ROOT/$file" "$inline" "$proposed" "$file instructions"
    plan_file "$file" "$proposed" marked-block
  done
  if [ "$refresh" = false ] && managed_block_present CLAUDE.md; then
    require_tracked_steering_file CLAUDE.md
    return 0
  fi
  proposed="$PLAN_ROOT/proposed-CLAUDE.md"
  : >"$proposed" || operational_failure "could not initialize proposed steering for CLAUDE.md"
  merge_managed_block "$PROJECT_ROOT/CLAUDE.md" "$claude" "$proposed" "Claude Code instructions"
  plan_file CLAUDE.md "$proposed" marked-block
}
