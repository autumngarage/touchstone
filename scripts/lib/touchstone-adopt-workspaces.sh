# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared across sourced compiler modules

node_workspace_patterns() {
  local manifest="$PROJECT_ROOT/package.json"
  [ -f "$manifest" ] || return 0
  awk '
    function decoded_escape(character) {
      if (character == "b") return sprintf("%c", 8)
      if (character == "f") return sprintf("%c", 12)
      if (character == "n") return "\n"
      if (character == "r") return "\r"
      if (character == "t") return "\t"
      return character
    }
    function decoded_unicode(value, number, cursor, digit) {
      number = 0
      for (cursor = 1; cursor <= 4; cursor++) {
        digit = index("0123456789abcdef", tolower(substr(value, cursor, 1))) - 1
        number = (number * 16) + digit
      }
      return number < 128 ? sprintf("%c", number) : "?"
    }
    function value_complete() {
      if (depth < 1) return
      state[depth] = "comma"
    }
    function begin_container(container, parent_depth, parent_key) {
      parent_depth = depth
      parent_key = key[parent_depth]
      depth++
      kind[depth] = container
      state[depth] = container == "object" ? "key" : "value"
      if (parent_depth == 1 && parent_key == "workspaces") {
        if (container == "array") workspace_array = depth
        else workspace_object = depth
      } else if (parent_depth == workspace_object && parent_key == "packages" && container == "array") {
        workspace_array = depth
      }
    }
    function finish_string() {
      if (kind[depth] == "object" && state[depth] == "key") {
        if (depth == 1 && token == "workspaces") {
          workspace_keys++
          if (workspace_keys > 1) exit 2
        } else if (depth == workspace_object && token == "packages") {
          workspace_package_keys++
          if (workspace_package_keys > 1) exit 2
        }
        key[depth] = token
        state[depth] = "colon"
      } else {
        if (kind[depth] == "object" && state[depth] == "value" &&
            ((depth == 1 && key[depth] == "workspaces") ||
             (depth == workspace_object && key[depth] == "packages"))) exit 2
        if (kind[depth] == "array" && state[depth] == "value" && depth == workspace_array) print token
        value_complete()
      }
      token = ""
      in_string = 0
    }
    {
      line = $0 "\n"
      for (position = 1; position <= length(line); position++) {
        character = substr(line, position, 1)
        if (in_string) {
          if (unicode_left > 0) {
            unicode_hex = unicode_hex character
            unicode_left--
            if (unicode_left == 0) {
              token = token decoded_unicode(unicode_hex)
              unicode_hex = ""
            }
          } else if (escaped) {
            if (character == "u") { unicode_left = 4; unicode_hex = "" }
            else token = token decoded_escape(character)
            escaped = 0
          } else if (character == "\\") escaped = 1
          else if (character == "\"") finish_string()
          else token = token character
          continue
        }
        if (character ~ /[[:space:]]/) continue
        if (character == "\"") { in_string = 1; token = ""; continue }
        if (character == "{") {
          if (depth == workspace_array && state[depth] == "value") exit 2
          if (depth == workspace_object && key[depth] == "packages") exit 2
          begin_container("object"); continue
        }
        if (character == "[") {
          if (depth == workspace_array && state[depth] == "value") exit 2
          begin_container("array"); continue
        }
        if (character == ":") { state[depth] = "value"; continue }
        if (character == ",") {
          state[depth] = kind[depth] == "object" ? "key" : "value"
          key[depth] = ""
          continue
        }
        if (character == "}" || character == "]") {
          if (depth == workspace_array) workspace_array = 0
          if (depth == workspace_object) workspace_object = 0
          delete kind[depth]; delete state[depth]; delete key[depth]
          depth--
          value_complete()
          continue
        }
        if ((depth == workspace_array && state[depth] == "value") ||
            (kind[depth] == "object" && state[depth] == "value" &&
             ((depth == 1 && key[depth] == "workspaces") ||
              (depth == workspace_object && key[depth] == "packages")))) exit 2
      }
    }
  ' "$manifest"
}

pnpm_workspace_patterns() {
  local workspace="$PROJECT_ROOT/pnpm-workspace.yaml"
  [ -f "$workspace" ] || return 0
  awk '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    function emit_scalar(raw, quoted, lowered) {
      raw = trim(raw)
      lowered = tolower(raw)
      if (!quoted && (lowered ~ /^(null|true|false|yes|no|on|off|~)$/ ||
          raw ~ /^[-+]?[0-9]+([.][0-9]+)?$/)) exit 2
      print raw
    }
    function emit_flow(raw, position, character, token, quote, escaped, closed, expect_value, bare_space, scalar_closed, quoted) {
      raw = trim(raw)
      if (substr(raw, 1, 1) != "[") exit 2
      token = ""
      quote = ""
      quoted = 0
      escaped = 0
      closed = 0
      expect_value = 1
      bare_space = 0
      scalar_closed = 0
      for (position = 2; position <= length(raw); position++) {
        character = substr(raw, position, 1)
        if (quote != "") {
          if (quote == "\"" && escaped) { token = token character; escaped = 0; continue }
          if (quote == "\"" && character == "\\") { escaped = 1; continue }
          if (character == quote) { quote = ""; expect_value = 0; scalar_closed = 1; continue }
          token = token character
          continue
        }
        if (closed) {
          if (character == "#") return
          if (character !~ /[[:space:]]/) exit 2
          continue
        }
        if (character == "\"" || character == "\047") {
          if (!expect_value || trim(token) != "") exit 2
          quote = character
          quoted = 1
          continue
        }
        if (character == ",") {
          if (expect_value || trim(token) == "") exit 2
          emit_scalar(token, quoted)
          token = ""
          quoted = 0
          expect_value = 1
          bare_space = 0
          scalar_closed = 0
          continue
        }
        if (character == "]") {
          if (quote != "") exit 2
          if (trim(token) != "") emit_scalar(token, quoted)
          else if (!expect_value) exit 2
          closed = 1
          continue
        }
        if (scalar_closed && character !~ /[[:space:]]/) exit 2
        if (character ~ /[[:space:]]/) {
          if (trim(token) != "") bare_space = 1
          continue
        }
        if (bare_space) exit 2
        token = token character
        expect_value = 0
      }
      if (!closed || quote != "" || escaped) exit 2
    }
    /^[[:space:]]*["\047]packages["\047][[:space:]]*:/ { exit 2 }
    /^packages:[[:space:]]*/ {
      packages_keys++
      if (packages_keys > 1) exit 2
      value = $0
      sub(/^packages:[[:space:]]*/, "", value)
      if (value == "" || value ~ /^#/) in_packages = 1
      else { emit_flow(value); in_packages = 0 }
      next
    }
    in_packages && /^[^[:space:]#]/ { in_packages = 0 }
    in_packages && /^[[:space:]]*-[[:space:]]*/ {
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*/, "", value)
      value = trim(value)
      quoted = 0
      if (substr(value, 1, 1) == "\047" || substr(value, 1, 1) == "\"") {
        quote = substr(value, 1, 1)
        if (length(value) < 2 || substr(value, length(value), 1) != quote) exit 2
        value = substr(value, 2, length(value) - 2)
        quoted = 1
      }
      if (value != "") emit_scalar(value, quoted)
      next
    }
    in_packages {
      value = $0
      sub(/[[:space:]]*#.*/, "", value)
      if (trim(value) != "") exit 2
      next
    }
    {
      value = $0
      sub(/[[:space:]]*#.*/, "", value)
      if (trim(value) != "") exit 2
    }
    END { if (packages_keys != 1) exit 2 }
  ' "$workspace"
}

node_workspace_contains() {
  local relative="$1" manager="$2" patterns pattern candidate included=false excluded=false
  if [ "$manager" = pnpm ]; then
    [ -f "$PROJECT_ROOT/pnpm-workspace.yaml" ] || return 1
    if ! patterns="$(pnpm_workspace_patterns)"; then
      contract_refusal "pnpm-workspace.yaml has malformed, duplicate, or unsupported packages declarations"
    fi
  elif ! patterns="$(node_workspace_patterns)"; then
    contract_refusal "root package.json has a malformed, repeated, or unsupported workspace declaration"
  fi
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    candidate="${pattern#!}"
    workspace_pattern_supported "$candidate" \
      || contract_refusal "workspace pattern '$pattern' uses glob syntax this compiler cannot verify"
    case "$pattern" in
      !*)
        if workspace_pattern_matches "$candidate" "$relative"; then excluded=true; fi
        ;;
      *)
        if workspace_pattern_matches "$pattern" "$relative"; then included=true; fi
        ;;
    esac
  done <<<"$patterns"
  [ "$included" = true ] && [ "$excluded" = false ]
}

workspace_pattern_supported() {
  local pattern="$1" segment remainder
  case "$pattern" in "" | /* | */ | *'{'* | *'}'* | *'['* | *']'* | *'?'* | *'\\'* | *'**'*) return 1 ;; esac
  remainder="$pattern"
  while :; do
    segment="${remainder%%/*}"
    case "$segment" in "" | *'*'*) [ "$segment" = '*' ] || return 1 ;; esac
    [ "$remainder" != "$segment" ] || break
    remainder="${remainder#*/}"
  done
}

workspace_pattern_matches() {
  local pattern="$1" relative="$2" pattern_segment relative_segment
  while :; do
    pattern_segment="${pattern%%/*}"
    relative_segment="${relative%%/*}"
    [ "$pattern_segment" = '*' ] || [ "$pattern_segment" = "$relative_segment" ] || return 1
    if [ "$pattern" = "$pattern_segment" ] || [ "$relative" = "$relative_segment" ]; then
      [ "$pattern" = "$pattern_segment" ] && [ "$relative" = "$relative_segment" ]
      return
    fi
    pattern="${pattern#*/}"
    relative="${relative#*/}"
  done
}

cargo_workspace_values() {
  local key="$1" manifest="$PROJECT_ROOT/Cargo.toml"
  [ -f "$manifest" ] || return 0
  awk -v wanted="$key" '
    function scan(raw, position, character) {
      for (position = 1; position <= length(raw); position++) {
        character = substr(raw, position, 1)
        if (quote != "") {
          if (quote == "\"" && character == "\\") exit 2
          if (character == quote) { quote = ""; print token; token = ""; closed_scalar = 1; continue }
          token = token character
          continue
        }
        if (character == "#") return
        if (finished) {
          if (character ~ /[[:space:]]/) continue
          exit 2
        }
        if (character == ",") {
          if (!started || !closed_scalar) exit 2
          closed_scalar = 0
          continue
        }
        if (character ~ /[[:space:]]/) continue
        if (!started && character == "[") { started = 1; continue }
        if (started && character == "]") { collecting = 0; finished = 1; continue }
        if (character == "\"" || character == "\047") {
          if (!started || closed_scalar) exit 2
          quote = character
          continue
        }
        exit 2
      }
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      if (collecting) exit 2
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      next
    }
    {
      line = $0
      compact = line
      sub(/[[:space:]]*#.*/, "", compact)
      gsub(/[[:space:]"\047]/, "", compact)
      if (section == "" && compact ~ "^workspace[.]" wanted "=") exit 2
      if (!collecting) {
        if (section != "workspace" || line !~ "^[[:space:]]*" wanted "[[:space:]]*=") next
        keys++
        if (keys > 1) exit 2
        sub("^[[:space:]]*" wanted "[[:space:]]*=", "", line)
        collecting = 1
        started = 0
        finished = 0
        closed_scalar = 0
      }
      scan(line)
      if (!collecting && (quote != "" || !started)) exit 2
    }
    END { if (collecting || quote != "") exit 2 }
  ' "$manifest"
}

cargo_workspace_contains() {
  local relative="$1" members excludes pattern member=false
  if ! members="$(cargo_workspace_values members)"; then
    contract_refusal "root Cargo.toml has a malformed or repeated workspace members declaration"
  fi
  if ! excludes="$(cargo_workspace_values exclude)"; then
    contract_refusal "root Cargo.toml has a malformed or repeated workspace exclude declaration"
  fi
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    workspace_pattern_supported "$pattern" \
      || contract_refusal "Cargo workspace pattern '$pattern' uses glob syntax this compiler cannot verify"
    if workspace_pattern_matches "$pattern" "$relative"; then member=true; fi
  done <<<"$members"
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    workspace_pattern_supported "$pattern" \
      || contract_refusal "Cargo workspace exclude '$pattern' uses glob syntax this compiler cannot verify"
    if workspace_pattern_matches "$pattern" "$relative"; then member=false; fi
  done <<<"$excludes"
  [ "$member" = true ]
}
