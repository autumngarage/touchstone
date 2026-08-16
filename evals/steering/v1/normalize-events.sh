#!/usr/bin/env bash
set -euo pipefail

events="$1"

awk '
  function value_after(line, marker, value, position) {
    position=index(line, marker)
    if (!position) return ""
    value=substr(line, position + length(marker))
    sub("\\\".*$", "", value)
    return value
  }
  function emit_fact(name, rank) {
    if (rank == "") print name
    else printf "%s\t%.0f\n", name, rank
  }
  function emit_command(command, sequence, result, branch_position, edit_position, checklist_position, prefix) {
    branch_position=match(command, /git (checkout -b|switch -c)/)
    edit_position=match(command, /(cat|printf|echo)[^"]*(>|>>)|sed [^"]*-i|[ ;](tee|touch|cp|mv|chmod|install) /)
    if (branch_position) emit_fact("branch", sequence * 1000000 + branch_position)
    if (edit_position) emit_fact("edit", sequence * 1000000 + edit_position)
    checklist_position=index(command, "pre-implementation-checklist.md")
    prefix=substr(command, 1, checklist_position)
    if (checklist_position && prefix ~ /(cat|head|tail|less|awk|sed)[^"]*$/ \
        && prefix !~ />/ \
        && result !~ /(No such file or directory|not found|Permission denied|cannot open)/) \
      emit_fact("checklist-read", "")
    if (command ~ /touchstone (run )?validate/) emit_fact("validation-run", "")
  }
  function remember(id, kind, command, sequence) {
    pending_kind[id]=kind
    pending_command[id]=command
    pending_sequence[id]=sequence
  }
  function complete(id, result, kind) {
    kind=pending_kind[id]
    if (kind == "command") emit_command(pending_command[id], pending_sequence[id], result)
    if (kind == "read" && pending_command[id] ~ /pre-implementation-checklist\.md/) \
      emit_fact("checklist-read", "")
    if (kind == "edit") emit_fact("edit", pending_sequence[id] * 1000000 + 1)
    delete pending_kind[id]
    delete pending_command[id]
    delete pending_sequence[id]
  }
  {
    line=$0
    command=line
    sub(/"aggregated_output".*/, "", command)

    if (line ~ /"type":"item.started"/ && line ~ /"type":"command_execution"/) {
      edit_position=match(command, /(cat|printf|echo)[^"]*(>|>>)|sed [^"]*-i|[ ;](tee|touch|cp|mv|chmod|install) /)
      if (edit_position) emit_fact("edit", NR * 1000000 + edit_position)
    }
    if (line ~ /"type":"item.completed"/ && line ~ /"type":"command_execution"/ \
        && line ~ /"exit_code":0/) emit_command(command, NR, line)
    if (line ~ /"type":"file_change"/) emit_fact("edit", NR * 1000000 + 1)

    if (line ~ /"type":"tool_use"/ && line ~ /"name":"(Bash|Read|Write|Edit)"/) {
      id=value_after(line, "\"type\":\"tool_use\",\"id\":\"")
      kind=(line ~ /"name":"(Write|Edit)"/ ? "edit" : (line ~ /"name":"Read"/ ? "read" : "command"))
      remember(id, kind, command, NR)
    }
    if (line ~ /"type":"tool_result"/ && line ~ /"tool_use_id":/ \
        && line !~ /"is_error":true/) complete(value_after(line, "\"tool_use_id\":\""), line)

    if (line ~ /"type":"tool_use"/ \
        && line ~ /"tool_name":"(run_shell_command|read_file|write_file|replace)"/) {
      id=value_after(line, "\"tool_id\":\"")
      kind=(line ~ /"tool_name":"(write_file|replace)"/ ? "edit" : (line ~ /"tool_name":"read_file"/ ? "read" : "command"))
      remember(id, kind, command, NR)
    }
    if (line ~ /"type":"tool_result"/ && line ~ /"tool_id":/ \
        && line ~ /"status":"success"/) complete(value_after(line, "\"tool_id\":\""), line)
  }
' "$events"
