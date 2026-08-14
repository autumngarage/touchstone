#!/usr/bin/env bash
# Detect the frozen Touchstone workflow/config pairing that blocks validation
# after a legitimate push to a protected default branch.
set -euo pipefail

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
PRE_COMMIT="$ROOT/.pre-commit-config.yaml"
WORKFLOW_DIR="$ROOT/.github/workflows"

[ -f "$PRE_COMMIT" ] || exit 0
[ -d "$WORKFLOW_DIR" ] || exit 0

guard_runs_precommit() {
  awk '
    function scalar(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      sub(/,$/, "", value)
      if ((value ~ /^".*"$/) || (value ~ /^\047.*\047$/)) value = substr(value, 2, length(value) - 2)
      return value
    }
    function list_has_precommit(value, count, values, item) {
      value = scalar(value)
      if (value !~ /^\[.*\]$/) return value == "pre-commit"
      value = substr(value, 2, length(value) - 2)
      count = split(value, values, ",")
      for (item = 1; item <= count; item++) if (scalar(values[item]) == "pre-commit") return 1
      return 0
    }
    function finish_guard() {
      if (!in_guard) return
      if (!current_stages_seen) guard_without_stages = 1
      in_guard = 0
      in_guard_stages = 0
    }
    {
      trimmed = $0
      sub(/^[[:space:]]*/, "", trimmed)
      content = trimmed
      sub(/[[:space:]]*#.*/, "", content)
      indent = index($0, substr(trimmed, 1, 1)) - 1

      if (in_guard && content ~ /^-[[:space:]]*/ && indent <= guard_indent) finish_guard()
      if (in_guard_stages && content != "" && indent <= stages_indent) in_guard_stages = 0
      if (in_default_stages && content != "" && indent <= default_indent) in_default_stages = 0

      if (indent == 0 && content ~ /^default_stages:/) {
        default_seen = 1
        value = content
        sub(/^default_stages:[[:space:]]*/, "", value)
        if (value == "") {
          in_default_stages = 1
          default_indent = indent
        } else if (list_has_precommit(value)) {
          default_precommit = 1
        }
        next
      }
      if (in_default_stages && content ~ /^-[[:space:]]*/) {
        value = content
        sub(/^-[[:space:]]*/, "", value)
        if (scalar(value) == "pre-commit") default_precommit = 1
        next
      }
      if (content ~ /^-[[:space:]]*id:[[:space:]]*no-commit-to-branch[[:space:]]*$/) {
        finish_guard()
        in_guard = 1
        guard_seen = 1
        guard_indent = indent
        current_stages_seen = 0
        next
      }
      if (!in_guard) next
      if (content ~ /^stages:/) {
        current_stages_seen = 1
        explicit_stages = 1
        value = content
        sub(/^stages:[[:space:]]*/, "", value)
        if (value == "") {
          in_guard_stages = 1
          stages_indent = indent
        } else if (list_has_precommit(value)) {
          explicit_precommit = 1
        }
        next
      }
      if (in_guard_stages && content ~ /^-[[:space:]]*/) {
        value = content
        sub(/^-[[:space:]]*/, "", value)
        if (scalar(value) == "pre-commit") explicit_precommit = 1
      }
    }
    END {
      finish_guard()
      selected = explicit_precommit || (guard_without_stages && (!default_seen || default_precommit))
      exit !(guard_seen && selected)
    }
  ' "$1"
}

if ! guard_runs_precommit "$PRE_COMMIT"; then
  exit 0
fi

found=0
workflow_pushes_default() {
  awk '
    function trim_scalar(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      sub(/,$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if ((value ~ /^".*"$/) || (value ~ /^\047.*\047$/)) value = substr(value, 2, length(value) - 2)
      return value
    }
    function glob_matches(value, branch, position, character, next_character, closing, class, regex) {
      value = trim_scalar(value)
      regex = "^"
      for (position = 1; position <= length(value); position++) {
        character = substr(value, position, 1)
        next_character = substr(value, position + 1, 1)
        if (character == "*") {
          regex = regex ".*"
          if (next_character == "*") position++
        } else if (character == "?") {
          regex = regex "."
        } else if (character == "+") {
          regex = regex "+"
        } else if (character == "[") {
          closing = index(substr(value, position + 1), "]")
          if (!closing) {
            regex = regex "\\["
          } else {
            class = substr(value, position + 1, closing - 1)
            if (substr(class, 1, 1) == "!") class = "^" substr(class, 2)
            regex = regex "[" class "]"
            position += closing
          }
        } else if (character == "\\") {
          if (position < length(value)) {
            position++
            character = substr(value, position, 1)
          }
          regex = regex "\\" character
        } else if (character == "." || character == "^" || character == "$" \
          || character == "(" || character == ")" \
          || character == "{" || character == "}" || character == "|" \
          || character == "]") {
          regex = regex "\\" character
        } else {
          regex = regex character
        }
      }
      return branch ~ (regex "$")
    }
    function apply_branch_pattern(value, ignored, negative) {
      value = trim_scalar(value)
      negative = (substr(value, 1, 1) == "!")
      if (negative) value = substr(value, 2)
      if (glob_matches(value, "main")) {
        if (ignored) ignored_main = 1
        else selected_main = !negative
      }
      if (glob_matches(value, "master")) {
        if (ignored) ignored_master = 1
        else selected_master = !negative
      }
      default_branch = selected_main || selected_master
      ignored_default = ignored_main && ignored_master
    }
    function apply_branch_list(value, ignored, count, values, item) {
      value = trim_scalar(value)
      if (value !~ /^\[.*\]$/) {
        apply_branch_pattern(value, ignored)
        return
      }
      value = substr(value, 2, length(value) - 2)
      count = split(value, values, ",")
      for (item = 1; item <= count; item++) apply_branch_pattern(values[item], ignored)
    }
    function inline_filter_value(value, key, remainder, closing) {
      remainder = value
      sub("^.*" key ":[[:space:]]*", "", remainder)
      if (remainder ~ /^\[/) {
        closing = index(remainder, "]")
        if (closing) return substr(remainder, 1, closing)
      }
      sub(/[,}].*$/, "", remainder)
      return remainder
    }
    function event_list_has_push(value, count, values, item) {
      value = trim_scalar(value)
      if (value !~ /^\[.*\]$/) return value == "push"
      value = substr(value, 2, length(value) - 2)
      count = split(value, values, ",")
      for (item = 1; item <= count; item++) if (trim_scalar(values[item]) == "push") return 1
      return 0
    }
    function flow_on_pushes_default(value, rest) {
      if (!match(value, /(^|[,{][[:space:]]*)push[[:space:]]*:/)) return 0
      rest = substr(value, RSTART + RLENGTH)
      sub(/^[[:space:]]*/, "", rest)
      selected_main = 0
      selected_master = 0
      ignored_main = 0
      ignored_master = 0
      default_branch = 0
      ignored_default = 0
      branches_seen = 0
      tags_seen = 0
      if (rest !~ /^\{/) return 1
      if (rest ~ /branches:[[:space:]]*/) {
        branches_seen = 1
        apply_branch_list(inline_filter_value(rest, "branches"), 0)
      }
      if (rest ~ /branches-ignore:[[:space:]]*/) {
        apply_branch_list(inline_filter_value(rest, "branches-ignore"), 1)
      }
      if (rest ~ /tags(-ignore)?:/) tags_seen = 1
      return default_branch || (!branches_seen && !tags_seen && !ignored_default)
    }
    function flush_push() {
      if (in_push && (default_branch || (!branches_seen && !tags_seen && !ignored_default))) found = 1
      in_push = 0
      in_branches = 0
      in_ignored = 0
    }
    {
      trimmed = $0
      sub(/^[[:space:]]*/, "", trimmed)
      indent = index($0, substr(trimmed, 1, 1)) - 1
      content = trimmed
      sub(/[[:space:]]*#.*/, "", content)

      if (in_push && content != "" && indent <= push_indent) flush_push()
      if (in_on && content != "" && indent <= on_indent) {
        flush_push()
        in_on = 0
      }

      if (content ~ /^on:[[:space:]]*$/) {
        in_on = 1
        on_indent = indent
        next
      }
      if (content ~ /^on:[[:space:]]*\{/ && flow_on_pushes_default(content)) {
        found = 1
        next
      }
      if (content ~ /^on:[[:space:]]*/ && event_list_has_push(substr(content, index(content, ":") + 1))) {
        found = 1
        next
      }
      if (in_push) {
        if (content ~ /^branches:[[:space:]]*/) {
          branches_seen = 1
          in_branches = 1
          in_ignored = 0
          filter_indent = indent
          value = content
          sub(/^branches:[[:space:]]*/, "", value)
          apply_branch_list(value, 0)
        } else if (content ~ /^branches-ignore:[[:space:]]*/) {
          in_branches = 0
          in_ignored = 1
          filter_indent = indent
          value = content
          sub(/^branches-ignore:[[:space:]]*/, "", value)
          apply_branch_list(value, 1)
        } else if (content ~ /^tags(-ignore)?:/) {
          tags_seen = 1
          in_branches = 0
          in_ignored = 0
        } else if (content ~ /^-[[:space:]]*/ && indent > filter_indent) {
          value = content
          sub(/^-[[:space:]]*/, "", value)
          if (in_branches) apply_branch_pattern(value, 0)
          if (in_ignored) apply_branch_pattern(value, 1)
        } else if (content != "" && indent <= filter_indent) {
          in_branches = 0
          in_ignored = 0
        }
        next
      }
      if (!in_on || content !~ /^push:/) next

      flush_push()
      in_push = 1
      push_indent = indent
      branches_seen = 0
      default_branch = 0
      tags_seen = 0
      ignored_default = 0
      selected_main = 0
      selected_master = 0
      ignored_main = 0
      ignored_master = 0
      in_branches = 0
      in_ignored = 0
      sub(/^push:[[:space:]]*/, "", content)
      if (content ~ /branches:[[:space:]]*/) {
        branches_seen = 1
        value = inline_filter_value(content, "branches")
        apply_branch_list(value, 0)
      }
      if (content ~ /branches-ignore:[[:space:]]*/) {
        value = inline_filter_value(content, "branches-ignore")
        apply_branch_list(value, 1)
      }
      if (content ~ /tags(-ignore)?:/) tags_seen = 1
      next
    }
    END {
      flush_push()
      exit !found
    }
  ' "$1"
}

workflow_has_unguarded_precommit() {
  awk '
    function flush_step() {
      if (has_pre_commit && needs_step_env && !has_step_env) unsafe = 1
      has_pre_commit = 0
      needs_step_env = 0
      has_step_env = 0
      exported_skip = 0
      in_env = 0
    }
    /^[[:space:]]*-[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*:/ { flush_step() }
    {
      trimmed = $0
      sub(/^[[:space:]]*/, "", trimmed)
      indent = index($0, substr(trimmed, 1, 1)) - 1
      is_export = (trimmed !~ /^#/ && trimmed ~ /^export[[:space:]]+SKIP=[^[:cntrl:]]*no-commit-to-branch/)
      is_pre_commit = (trimmed !~ /^#/ && $0 ~ /pre-commit run --all-files --hook-stage pre-commit/)
      if (in_env && trimmed !~ /^($|#)/ && indent <= env_indent) in_env = 0
      if (trimmed == "env:") {
        in_env = 1
        env_indent = indent
      } else if (trimmed ~ /^-?[[:space:]]*env:[[:space:]]*\{[^}]*SKIP[^}]*no-commit-to-branch/) {
        has_step_env = 1
      } else if (in_env && trimmed ~ /^SKIP:[^#]*no-commit-to-branch/) {
        has_step_env = 1
      }
      if (is_export) {
        exported_skip = 1
      } else if (trimmed !~ /^($|#)/ && !is_pre_commit) {
        exported_skip = 0
      }
      if (is_pre_commit) {
        has_pre_commit = 1
        if ($0 !~ /(^[[:space:]]*(-[[:space:]]*)?(run:[[:space:]]*)?|[;&|][[:space:]]*)SKIP=[^[:space:];|&]*no-commit-to-branch[^[:space:];|&]*[[:space:]]+pre-commit run/ && !exported_skip) {
          needs_step_env = 1
        }
      }
    }
    END {
      flush_step()
      exit !unsafe
    }
  ' "$1"
}

for workflow in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
  [ -f "$workflow" ] || continue
  workflow_pushes_default "$workflow" || continue
  workflow_has_unguarded_precommit "$workflow" || continue
  printf 'LEGACY-CI-BRANCH-GUARD %s\n' "${workflow#"$ROOT/"}"
  found=$((found + 1))
done

if [ "$found" -eq 0 ]; then exit 0; fi

cat >&2 <<'EOF'
ERROR: protected-branch CI runs the local no-commit-to-branch guard.
Repair the pre-commit step so only protected-branch push runs set
SKIP=no-commit-to-branch. Keep pull-request hygiene and every other hook on.
Then run the project validation command normally. Review this migration; do
not silently rewrite project-owned CI.
EOF
exit 3
