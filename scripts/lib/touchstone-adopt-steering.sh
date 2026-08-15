# shellcheck shell=bash

TOUCHSTONE_BLOCK_BEGIN='<!-- touchstone:steering:start -->'
TOUCHSTONE_BLOCK_END='<!-- touchstone:steering:end -->'
CODEX_INSTRUCTION_LIMIT_BYTES=32768

render_consumer_markdown() {
  local source="$1" output="$2" raw
  raw="$output.raw"
  # shellcheck disable=SC2016 # backticks in these sed programs are literal Markdown.
  sed \
    -e 's#Use the `touchstone-audit-weak-points` skill (Claude) or read `principles/audit-weak-points.md` (other drivers)\.#Read `principles/audit-weak-points.md`.#' \
    -e '/^Claude Code agents: the bundled `touchstone-\*` and `memory-audit` skills mirror this table in your session header\. Trust whichever surface fires first\.$/d' \
    -e 's#Use the `touchstone-audit-weak-points` skill\.#Follow `principles/audit-weak-points.md`.#' \
    -e 's#principles/#.touchstone/principles/#g' \
    "$source" >"$raw" || operational_failure "could not render consumer steering"
  awk '
      { line[NR] = $0 }
      END {
        last = NR
        while (last > 0 && line[last] == "") last--
        for (position = 1; position <= last; position++) print line[position]
      }
    ' "$raw" >"$output" || operational_failure "could not normalize consumer steering"
  rm -f -- "$raw" || operational_failure "could not remove intermediate steering"
  if grep -Eq 'scripts/(claim-issue|respond-review|issue-claim-check)\.sh|hooks/branch-guard\.sh|\.github/workflows/|\.pre-commit-config\.yaml' "$output"; then
    operational_failure "consumer steering retained a repository-local implementation path"
  fi
}

render_inline_block() {
  local steering="$1" output="$2"
  {
    printf '%s\n' "$TOUCHSTONE_BLOCK_BEGIN"
    printf '%s\n\n' '<!-- Managed by touchstone upgrade. Edit content outside the markers. -->'
    cat "$steering"
    printf '\n%s\n' "$TOUCHSTONE_BLOCK_END"
  } >"$output" || operational_failure "could not render inline steering"
}

render_claude_block() {
  local output="$1"
  {
    printf '%s\n' "$TOUCHSTONE_BLOCK_BEGIN"
    printf '%s\n\n' '<!-- Managed by touchstone upgrade. Edit content outside the markers. -->'
    printf '## Touchstone universal steering\n\n'
    printf '@.touchstone/TOUCHSTONE.md\n\n'
    printf '%s\n' "$TOUCHSTONE_BLOCK_END"
  } >"$output" || operational_failure "could not render Claude steering"
}

marker_lines() {
  local source="$1"
  BEGIN_COUNT="$(awk -v marker="$TOUCHSTONE_BLOCK_BEGIN" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) count++ } END { print count + 0 }' "$source")"
  END_COUNT="$(awk -v marker="$TOUCHSTONE_BLOCK_END" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) count++ } END { print count + 0 }' "$source")"
  BEGIN_LINE="$(awk -v marker="$TOUCHSTONE_BLOCK_BEGIN" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) print NR }' "$source")"
  END_LINE="$(awk -v marker="$TOUCHSTONE_BLOCK_END" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) print NR }' "$source")"
}

check_rendered_steering_size() {
  local destination="$1" output="$2" size
  [ "$(basename "$destination")" = AGENTS.md ] || return 0
  size="$(wc -c <"$output" | awk '{ print $1 }')" \
    || operational_failure "could not measure rendered AGENTS.md"
  [ "$size" -le "$CODEX_INSTRUCTION_LIMIT_BYTES" ] \
    || contract_refusal "AGENTS.md would exceed the ${CODEX_INSTRUCTION_LIMIT_BYTES}-byte instruction limit"
}

managed_block_present() {
  local relative="$1" destination
  destination="$PROJECT_ROOT/$relative"
  safe_managed_path "$relative"
  [ -e "$destination" ] || return 1
  [ -f "$destination" ] || contract_refusal "steering path is not a regular file: $relative"
  marker_lines "$destination"
  [ "$BEGIN_COUNT" -eq "$END_COUNT" ] && [ "$BEGIN_COUNT" -le 1 ] \
    || contract_refusal "steering markers are malformed in $relative"
  [ "$BEGIN_COUNT" -eq 1 ] || return 1
  [ "$BEGIN_LINE" -lt "$END_LINE" ] || contract_refusal "steering markers are out of order in $relative"
}

merge_managed_block() {
  local destination="$1" block="$2" output="$3" heading="$4"
  local line comparison in_block=false inserted=false terminated
  if [ ! -e "$destination" ]; then
    {
      printf '# %s\n\n' "$heading"
      cat "$block"
    } >"$output" || operational_failure "could not create ${destination#"$PROJECT_ROOT"/}"
    check_rendered_steering_size "$destination" "$output"
    return 0
  fi
  [ -f "$destination" ] || contract_refusal "steering path is not a regular file: ${destination#"$PROJECT_ROOT"/}"
  marker_lines "$destination"
  [ "$BEGIN_COUNT" -eq "$END_COUNT" ] && [ "$BEGIN_COUNT" -le 1 ] \
    || contract_refusal "steering markers are malformed in ${destination#"$PROJECT_ROOT"/}"
  if [ "$BEGIN_COUNT" -eq 0 ]; then
    {
      cat "$block"
      [ ! -s "$destination" ] || printf '\n'
      cat "$destination"
    } >"$output" || operational_failure "could not extend ${destination#"$PROJECT_ROOT"/}"
    check_rendered_steering_size "$destination" "$output"
    return 0
  fi
  [ "$BEGIN_LINE" -lt "$END_LINE" ] \
    || contract_refusal "steering markers are out of order in ${destination#"$PROJECT_ROOT"/}"
  : >"$output" || operational_failure "could not initialize ${destination#"$PROJECT_ROOT"/}"
  while true; do
    line=""
    if IFS= read -r line; then terminated=true; else
      [ -n "$line" ] || break
      terminated=false
    fi
    comparison="${line%"$CR"}"
    if [ "$in_block" = true ]; then
      [ "$comparison" != "$TOUCHSTONE_BLOCK_END" ] || in_block=false
      continue
    fi
    if [ "$comparison" = "$TOUCHSTONE_BLOCK_BEGIN" ]; then
      if [ "$inserted" = false ]; then
        cat "$block" >>"$output" || operational_failure "could not replace steering block"
        inserted=true
      fi
      in_block=true
      continue
    fi
    if [ "$terminated" = true ]; then printf '%s\n' "$line" >>"$output"; else printf '%s' "$line" >>"$output"; fi \
      || operational_failure "could not preserve project steering"
  done <"$destination"
  check_rendered_steering_size "$destination" "$output"
}

plan_steering() {
  local refresh="$1" consumer="$PLAN_ROOT/consumer-touchstone.md"
  local block_consumer inline="$PLAN_ROOT/inline-block.md" claude="$PLAN_ROOT/claude-block.md"
  local source relative rendered proposed driver
  render_consumer_markdown "$SCRIPT_ROOT/TOUCHSTONE.md" "$consumer"
  plan_managed_file .touchstone/TOUCHSTONE.md "$consumer" "$refresh"
  block_consumer="$consumer"
  if [ "$refresh" = false ] && [ -f "$PROJECT_ROOT/.touchstone/TOUCHSTONE.md" ] \
    && [ ! -L "$PROJECT_ROOT/.touchstone/TOUCHSTONE.md" ]; then
    block_consumer="$PROJECT_ROOT/.touchstone/TOUCHSTONE.md"
  fi
  for source in "$SCRIPT_ROOT"/principles/*.md; do
    [ "$(basename "$source")" != README.md ] || continue
    relative=".touchstone/principles/$(basename "$source")"
    rendered="$PLAN_ROOT/principle-$(basename "$source")"
    render_consumer_markdown "$source" "$rendered"
    plan_managed_file "$relative" "$rendered" "$refresh"
  done
  render_inline_block "$block_consumer" "$inline"
  render_claude_block "$claude"
  for driver in AGENTS.md GEMINI.md; do
    if [ "$refresh" = false ] && managed_block_present "$driver"; then
      require_managed_output_available "$driver"
      continue
    fi
    proposed="$PLAN_ROOT/proposed-$driver"
    merge_managed_block "$PROJECT_ROOT/$driver" "$inline" "$proposed" "$driver instructions"
    plan_file "$driver" "$proposed" marked-block
  done
  if [ "$refresh" = false ] && managed_block_present CLAUDE.md; then
    require_managed_output_available CLAUDE.md
    return 0
  fi
  proposed="$PLAN_ROOT/proposed-CLAUDE.md"
  merge_managed_block "$PROJECT_ROOT/CLAUDE.md" "$claude" "$proposed" 'Claude Code instructions'
  plan_file CLAUDE.md "$proposed" marked-block
}
