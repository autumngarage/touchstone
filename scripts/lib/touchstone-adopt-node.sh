# shellcheck shell=bash

node_has_local_dependency() {
  local file="$1" object status
  for object in dependencies devDependencies optionalDependencies peerDependencies; do
    if json_object_has_local_path "$file" "$object"; then
      return 0
    else
      status=$?
    fi
    [ "$status" -eq 1 ] \
      || contract_refusal "package.json has a malformed or unsupported '$object' declaration"
  done
  return 1
}
node_has_declared_dependency() {
  local file="$1" object status
  for object in dependencies devDependencies optionalDependencies peerDependencies; do
    if json_object_has_local_path "$file" "$object" any; then
      return 0
    else
      status=$?
    fi
    [ "$status" -eq 1 ] \
      || contract_refusal "package.json has a malformed or unsupported '$object' declaration"
  done
  return 1
}
npm_lock_valid() {
  local file="$1" compact
  validate_json_document "$file" || return 1
  compact="$(tr -d '[:space:]' <"$file")"
  [ "$compact" = '{"lockfileVersion":3,"requires":true,"packages":{"":{}}}' ] \
    || [ "$compact" = '{"lockfileVersion":2,"requires":true,"packages":{"":{}}}' ]
}

pnpm_lock_valid() {
  local file="$1"
  awk '
    /^[[:space:]]*($|#)/ { next }
    /^lockfileVersion:[[:space:]]*["\047]?[0-9]+([.][0-9]+)?["\047]?[[:space:]]*$/ {
      if (version_seen) exit 2
      version_seen=1
      next
    }
    { exit 2 }
    END { if (!version_seen) exit 2 }
  ' "$file" >/dev/null 2>&1
}

yarn_lock_valid() {
  local file="$1" kind="$2"
  case "$kind" in
    classic)
      awk '
        /^[[:space:]]*$/ { next }
        /^# yarn lockfile v1$/ { if (header_seen) exit 2; header_seen=1; next }
        /^#/ { next }
        { exit 2 }
        END { if (!header_seen) exit 2 }
      ' "$file" >/dev/null 2>&1
      ;;
    berry)
      awk '
        /^[[:space:]]*$/ { next }
        /^__metadata:[[:space:]]*$/ { if (metadata_seen) exit 2; metadata_seen=1; next }
        /^  version:[[:space:]]*[0-9]+[[:space:]]*$/ {
          if (!metadata_seen || version_seen) exit 2
          version_seen=1
          next
        }
        /^  cacheKey:[[:space:]]*[^[:space:]]+[[:space:]]*$/ {
          if (!metadata_seen || cache_seen) exit 2
          cache_seen=1
          next
        }
        { exit 2 }
        END { if (!metadata_seen || !version_seen) exit 2 }
      ' "$file" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

node_has_script() {
  local file="$1" task="$2" status
  json_object_has_key "$file" scripts "$task" && return 0
  status=$?
  [ "$status" -eq 1 ] || contract_refusal "package.json is malformed or scripts is not an object"
  return 1
}

json_root_string_value() {
  local file="$1" wanted="$2"
  awk -v wanted="$wanted" '
    function hex_value(character, position) {
      position = index("0123456789abcdef", tolower(character))
      return position - 1
    }
    function decoded_unicode(hex, position, value) {
      value = 0
      for (position = 1; position <= 4; position++) {
        value = (value * 16) + hex_value(substr(hex, position, 1))
      }
      if (value < 128) return sprintf("%c", value)
      if (value < 2048) return sprintf("%c%c", 192 + int(value / 64), 128 + (value % 64))
      return sprintf("%c%c%c", 224 + int(value / 4096),
        128 + (int(value / 64) % 64), 128 + (value % 64))
    }
    function decoded_escape(character) {
      if (character == "b") return sprintf("%c", 8)
      if (character == "f") return sprintf("%c", 12)
      if (character == "n") return "\n"
      if (character == "r") return "\r"
      if (character == "t") return "\t"
      return character
    }
    function finish_string() {
      if (capturing_value) {
        value = token
        found = 1
        capturing_value = 0
      } else pending = token
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
          }
          else if (escaped) {
            if (character == "u") {
              unicode_left = 4
              unicode_hex = ""
            } else token = token decoded_escape(character)
            escaped = 0
          }
          else if (character == "\\") escaped = 1
          else if (character == "\"") finish_string()
          else token = token character
          continue
        }
        if (expecting_value && character ~ /[[:space:]]/) continue
        if (expecting_value) {
          if (character == "\"") {
            in_string = 1
            capturing_value = 1
            expecting_value = 0
            token = ""
            continue
          }
          invalid = 1
          expecting_value = 0
        }
        if (character == "\"") { in_string = 1; token = ""; continue }
        if (character == ":") {
          if (depth == 1 && pending == wanted) {
            if (property_seen) invalid = 1
            property_seen = 1
            expecting_value = 1
          }
          pending = ""
          continue
        }
        if (character == "{") { depth++; pending = ""; continue }
        if (character == "}") {
          if (depth <= 0) invalid = 1
          depth--
          pending = ""
          continue
        }
        if (character !~ /[[:space:]]/) pending = ""
      }
    }
    END {
      if (invalid || in_string || escaped || unicode_left > 0 || depth != 0 || expecting_value) exit 2
      if (found) { print value; exit 0 }
      exit 1
    }
  ' "$file"
}

node_package_manager() {
  local directory="$1" inherited="${2:-}" fallback="${3-npm}" count=0 manager="" declared="" declaration_status
  if [ -f "$directory/package.json" ]; then
    validate_json_document "$directory/package.json" \
      || contract_refusal "package.json is malformed"
    if declared="$(json_root_string_value "$directory/package.json" packageManager)"; then
      declaration_status=0
    else
      declaration_status=$?
    fi
    case "$declaration_status" in
      0 | 1) ;;
      *) contract_refusal "package.json is malformed or packageManager is not a string" ;;
    esac
    declared="${declared%%@*}"
    case "$declared" in "" | npm | pnpm | yarn | bun) ;; *)
      contract_refusal "unsupported Node packageManager '$declared'"
      ;;
    esac
  fi
  if [ -f "$directory/pnpm-lock.yaml" ] || [ -f "$directory/pnpm-workspace.yaml" ]; then
    manager=pnpm
    count=$((count + 1))
  fi
  if [ -f "$directory/yarn.lock" ]; then
    manager=yarn
    count=$((count + 1))
  fi
  if [ -f "$directory/bun.lock" ] || [ -f "$directory/bun.lockb" ]; then
    manager=bun
    count=$((count + 1))
  fi
  if [ -f "$directory/package-lock.json" ] || [ -f "$directory/npm-shrinkwrap.json" ]; then
    manager=npm
    count=$((count + 1))
  fi
  if [ "$count" -gt 1 ]; then
    contract_refusal "conflicting Node lockfiles in ${directory#"$PROJECT_ROOT"/}"
  fi
  if [ -n "$declared" ] && [ -n "$manager" ] && [ "$declared" != "$manager" ]; then
    contract_refusal "packageManager '$declared' conflicts with the '$manager' lockfile"
  fi
  if [ -n "$declared" ]; then manager="$declared"; fi
  if [ -n "$inherited" ] && [ -n "$manager" ] && [ "$inherited" != "$manager" ]; then
    contract_refusal "Node package manager '$manager' conflicts with workspace package manager '$inherited'"
  fi
  NODE_MANAGER="${manager:-${inherited:-$fallback}}"
}

node_effective_package_manager_spec() {
  local directory="$1" spec status
  if spec="$(json_root_string_value "$directory/package.json" packageManager)"; then
    printf '%s\n' "$spec"
    return 0
  else
    status=$?
  fi
  [ "$status" -eq 1 ] || return "$status"
  if [ "$directory" != "$PROJECT_ROOT" ] && [ -f "$PROJECT_ROOT/package.json" ]; then
    json_root_string_value "$PROJECT_ROOT/package.json" packageManager
    return
  fi
  return 1
}

node_validate_package_manager_spec() {
  local manager="$1" directory="$2" status spec version major
  NODE_MANAGER_SPEC=""
  NODE_MANAGER_MAJOR=""
  case "$manager" in pnpm | yarn) ;; *) return 0 ;; esac
  if spec="$(node_effective_package_manager_spec "$directory")"; then
    status=0
  else
    status=$?
  fi
  case "$status" in
    0) ;;
    1) contract_refusal "$manager requires packageManager with an exact $manager version" ;;
    *) contract_refusal "package.json is malformed or packageManager is not a string" ;;
  esac
  case "$spec" in
    "$manager"@*) version="${spec#"$manager"@}" ;;
    *) contract_refusal "packageManager '$spec' conflicts with selected package manager '$manager'" ;;
  esac
  printf '%s' "$version" | grep -Eq '^[0-9]+[.][0-9]+[.][0-9]+([+-][A-Za-z0-9.-]+)?$' \
    || contract_refusal "$manager requires an exact packageManager version, found '$version'"
  major="${version%%.*}"
  case "$manager:$major" in
    pnpm:9 | pnpm:10) ;;
    yarn:*) [ "$major" -ge 1 ] || contract_refusal "unsupported Yarn packageManager version '$version'" ;;
    *) contract_refusal "unsupported pnpm packageManager version '$version'" ;;
  esac
  NODE_MANAGER_SPEC="$spec"
  NODE_MANAGER_MAJOR="$major"
}

node_setup_command() {
  local manager="$1" directory="$2" lock_kind=""
  case "$manager" in
    npm)
      if [ -f "$directory/package-lock.json" ] || [ -f "$directory/npm-shrinkwrap.json" ]; then
        printf 'npm ci --offline --ignore-scripts\n'
      fi
      ;;
    pnpm)
      if [ -f "$directory/pnpm-lock.yaml" ]; then
        printf 'COREPACK_ENABLE_NETWORK=0 pnpm install --offline --frozen-lockfile --ignore-scripts --ignore-pnpmfile\n'
      fi
      ;;
    yarn)
      if [ -f "$directory/yarn.lock" ]; then
        if grep -q '^# yarn lockfile v1' "$directory/yarn.lock"; then
          lock_kind=classic
        elif grep -q '^__metadata:' "$directory/yarn.lock"; then
          lock_kind=berry
        fi
        if [ "$NODE_MANAGER_MAJOR" -eq 1 ]; then
          [ "$lock_kind" != berry ] \
            || contract_refusal "Yarn Classic packageManager '$NODE_MANAGER_SPEC' conflicts with a Berry lockfile"
          printf 'COREPACK_ENABLE_NETWORK=0 yarn install --offline --frozen-lockfile --ignore-scripts\n'
        else
          [ "$lock_kind" != classic ] \
            || contract_refusal "Yarn Berry packageManager '$NODE_MANAGER_SPEC' conflicts with a Classic lockfile"
          printf 'COREPACK_ENABLE_NETWORK=0 yarn install --immutable --immutable-cache --mode=skip-build\n'
        fi
      fi
      ;;
    bun)
      if [ -f "$directory/bun.lock" ] || [ -f "$directory/bun.lockb" ]; then
        printf 'bun install --offline --frozen-lockfile --ignore-scripts\n'
      fi
      ;;
  esac
}

node_command() {
  local manager="$1" task="$2"
  case "$manager" in
    npm) printf 'npm run %s\n' "$task" ;;
    pnpm) printf 'COREPACK_ENABLE_NETWORK=0 pnpm run %s\n' "$task" ;;
    yarn) printf 'COREPACK_ENABLE_NETWORK=0 yarn %s\n' "$task" ;;
    bun) printf 'bun run %s\n' "$task" ;;
  esac
}

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

tasks_for_node() {
  local directory="$1" target="$2" suffix="$3" inherited="${4:-}" workspace_member="${5:-false}" manager setup_directory setup_command npm_lock="" yarn_kind="" task config found=false
  [ -f "$directory/package.json" ] || contract_refusal "Node target '$target' has no package.json"
  node_package_manager "$directory" "$inherited"
  for task in validate verify lint typecheck test build; do
    if node_has_script "$directory/package.json" "$task"; then :; fi
  done
  node_has_local_dependency "$directory/package.json" \
    && contract_refusal "Node target '$target' declares a local file dependency this portable compiler cannot verify within the checkout; pass --task NAME=COMMAND"
  manager="$NODE_MANAGER"
  if [ "$workspace_member" = true ]; then setup_directory="$PROJECT_ROOT"; else setup_directory="$directory"; fi
  node_has_declared_dependency "$directory/package.json" \
    && contract_refusal "Node target '$target' declares dependencies whose lock compatibility this portable compiler cannot verify; pass --task NAME=COMMAND"
  if [ "$setup_directory" != "$directory" ]; then
    node_has_declared_dependency "$setup_directory/package.json" \
      && contract_refusal "Node workspace root declares dependencies whose lock compatibility this portable compiler cannot verify; pass --task NAME=COMMAND"
  fi
  node_validate_package_manager_spec "$manager" "$directory"
  if [ "$manager" = npm ]; then
    for config in "$directory/.npmrc" "$setup_directory/.npmrc"; do
      if [ -e "$config" ] || [ -L "$config" ]; then
        contract_refusal "npm target '$target' has project-controlled config '${config#"$PROJECT_ROOT"/}'; pass --task NAME=COMMAND"
      fi
    done
    if [ -f "$setup_directory/package-lock.json" ]; then
      npm_lock="$setup_directory/package-lock.json"
    elif [ -f "$setup_directory/npm-shrinkwrap.json" ]; then
      npm_lock="$setup_directory/npm-shrinkwrap.json"
    fi
    if [ -n "$npm_lock" ]; then
      npm_lock_valid "$npm_lock" \
        || contract_refusal "Node target '$target' has an npm lockfile outside the dependency-free portable subset; regenerate a schema-v2/v3 lock or pass --task NAME=COMMAND"
    fi
  fi
  if [ "$manager" = pnpm ]; then
    for config in "$directory/.pnpmfile.cjs" "$directory/.pnpmfile.js" \
      "$setup_directory/.pnpmfile.cjs" "$setup_directory/.pnpmfile.js" \
      "$directory/.npmrc" "$setup_directory/.npmrc"; do
      if [ -e "$config" ] || [ -L "$config" ]; then
        contract_refusal "pnpm target '$target' has project-controlled pnpm hook or config '${config#"$PROJECT_ROOT"/}'; pass --task NAME=COMMAND"
      fi
    done
  fi
  if [ "$manager" = pnpm ] && [ -f "$setup_directory/pnpm-lock.yaml" ]; then
    pnpm_lock_valid "$setup_directory/pnpm-lock.yaml" \
      || contract_refusal "Node target '$target' has a pnpm lockfile outside the dependency-free portable subset; pass --task NAME=COMMAND"
  fi
  if [ "$manager" = yarn ]; then
    for config in "$directory/.yarnrc.yml" "$directory/.yarnrc" \
      "$setup_directory/.yarnrc.yml" "$setup_directory/.yarnrc"; do
      if [ -e "$config" ] || [ -L "$config" ]; then
        contract_refusal "Yarn target '$target' has project-controlled config '${config#"$PROJECT_ROOT"/}'; pass --task NAME=COMMAND"
      fi
    done
    if [ -f "$setup_directory/yarn.lock" ]; then
      if grep -q '^# yarn lockfile v1$' "$setup_directory/yarn.lock"; then
        yarn_kind=classic
      elif grep -q '^__metadata:$' "$setup_directory/yarn.lock"; then
        yarn_kind=berry
      fi
      yarn_lock_valid "$setup_directory/yarn.lock" "$yarn_kind" \
        || contract_refusal "Node target '$target' has a Yarn lockfile outside the dependency-free portable subset; pass --task NAME=COMMAND"
    fi
  fi
  if [ "$manager" = bun ] && { [ -f "$setup_directory/bun.lock" ] || [ -f "$setup_directory/bun.lockb" ]; }; then
    contract_refusal "Node target '$target' has a Bun lockfile this portable compiler cannot validate; pass --task NAME=COMMAND"
  fi
  setup_command="$(node_setup_command "$manager" "$setup_directory")"
  if [ -n "$setup_command" ]; then record_setup "$setup_directory" "$setup_command"; fi
  for task in validate verify; do
    if node_has_script "$directory/package.json" "$task"; then
      record_task "$task$suffix" "$target" "$(node_command "$manager" "$task")"
      return 0
    fi
  done
  for task in lint typecheck test build; do
    if node_has_script "$directory/package.json" "$task"; then
      record_task "$task$suffix" "$target" "$(node_command "$manager" "$task")"
      found=true
    fi
  done
  [ "$found" = true ] || contract_refusal "Node target '$target' declares no validate, verify, lint, typecheck, test, or build script; pass --task NAME=COMMAND"
}
