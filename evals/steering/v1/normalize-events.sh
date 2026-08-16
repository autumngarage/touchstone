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
  function emit_fact(name, sequence, position) {
    if (sequence == "") print name
    else printf "%s\t%d\t%d\n", name, sequence, position
  }
  function emit_command(command, sequence, result, branch_position, edit_position, checklist_position, prefix) {
    branch_position=match(command, /git (checkout -b|switch -c)/)
    edit_position=match(command, /(cat|printf|echo)[^"]*(>|>>)|sed [^"]*-i|[ ;](tee|touch|cp|mv|chmod|install) /)
    if (branch_position) emit_fact("branch", sequence, branch_position)
    if (edit_position) emit_fact("edit", sequence, edit_position)
    checklist_position=index(command, "pre-implementation-checklist.md")
    prefix=substr(command, 1, checklist_position)
    if (checklist_position && prefix ~ /(cat|head|tail|less|awk|sed)[^"]*$/ \
        && prefix !~ />/ \
        && result !~ /(No such file or directory|not found|Permission denied|cannot open)/) \
      emit_fact("checklist-read", "", "")
    if (command ~ /touchstone (run )?validate/) emit_fact("validation-run", "", "")
  }
  function remember(id, kind, command, sequence) {
    pending_kind[id]=kind
    pending_command[id]=command
    pending_sequence[id]=sequence
  }
  function complete(id, result, successful, kind) {
    kind=pending_kind[id]
    if (kind == "command" && successful) emit_command(pending_command[id], pending_sequence[id], result)
    else if (kind == "command" && pending_command[id] ~ /touchstone (run )?validate/) \
      emit_fact("validation-run", "", "")
    if (successful && kind == "read" && pending_command[id] ~ /pre-implementation-checklist\.md/) \
      emit_fact("checklist-read", "", "")
    if (successful && kind == "edit") emit_fact("edit", pending_sequence[id], 1)
    delete pending_kind[id]
    delete pending_command[id]
    delete pending_sequence[id]
  }
  {
    line=$0
    command=line
    sub(/"aggregated_output".*/, "", command)

    if (line ~ /"type":"item.completed"/ && line ~ /"type":"command_execution"/) {
      if (line ~ /"exit_code":0/) emit_command(command, NR, line)
      else if (command ~ /touchstone (run )?validate/) emit_fact("validation-run", "", "")
    }
    if (line ~ /"type":"item.completed"/ && line ~ /"type":"file_change"/) \
      emit_fact("edit", NR, 1)

    if (line ~ /"type":"tool_use"/ && line ~ /"name":"(Bash|Read|Write|Edit)"/) {
      id=value_after(line, "\"type\":\"tool_use\",\"id\":\"")
      kind=(line ~ /"name":"(Write|Edit)"/ ? "edit" : (line ~ /"name":"Read"/ ? "read" : "command"))
      remember(id, kind, command, NR)
    }
    if (line ~ /"type":"tool_result"/ && line ~ /"tool_use_id":/) \
      complete(value_after(line, "\"tool_use_id\":\""), line, line !~ /"is_error":true/)

    if (line ~ /"type":"tool_use"/ \
        && line ~ /"tool_name":"(run_shell_command|read_file|write_file|replace)"/) {
      id=value_after(line, "\"tool_id\":\"")
      kind=(line ~ /"tool_name":"(write_file|replace)"/ ? "edit" : (line ~ /"tool_name":"read_file"/ ? "read" : "command"))
      remember(id, kind, command, NR)
    }
    if (line ~ /"type":"tool_result"/ && line ~ /"tool_id":/) \
      complete(value_after(line, "\"tool_id\":\""), line, line ~ /"status":"success"/)
  }
' "$events"
