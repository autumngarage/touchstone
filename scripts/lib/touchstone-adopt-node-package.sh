# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared across sourced compiler modules

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
  local directory="$1" inherited="${2:-}" fallback="${3-npm}" count=0 manager="" declared="" declaration_status dev_engines_status
  if [ -f "$directory/package.json" ]; then
    validate_json_document "$directory/package.json" \
      || contract_refusal "package.json is malformed"
    if json_root_string_value "$directory/package.json" devEngines >/dev/null; then
      dev_engines_status=0
    else
      dev_engines_status=$?
    fi
    [ "$dev_engines_status" -eq 1 ] \
      || contract_refusal "package.json declares devEngines runtime policy this portable compiler cannot verify; pass --task NAME=COMMAND"
    if declared="$(json_root_string_value "$directory/package.json" packageManager)"; then
      declaration_status=0
    else
      declaration_status=$?
    fi
    case "$declaration_status" in
      0 | 1) ;;
      *) contract_refusal "package.json is malformed or packageManager is not a string" ;;
    esac
    if [ "$declaration_status" -eq 0 ]; then
      [ -n "$declared" ] || contract_refusal "unsupported Node packageManager ''"
      declared="${declared%@*}"
      case "$declared" in npm | pnpm | yarn | bun) ;; *)
        contract_refusal "unsupported Node packageManager '$declared'"
        ;;
      esac
    fi
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
  local directory="$1" inherit_root="${2:-false}" spec status
  if spec="$(json_root_string_value "$directory/package.json" packageManager)"; then
    printf '%s\n' "$spec"
    return 0
  else
    status=$?
  fi
  [ "$status" -eq 1 ] || return "$status"
  if [ "$inherit_root" = true ] && [ "$directory" != "$PROJECT_ROOT" ] \
    && [ -f "$PROJECT_ROOT/package.json" ]; then
    json_root_string_value "$PROJECT_ROOT/package.json" packageManager
    return
  fi
  return 1
}

node_validate_package_manager_spec() {
  local manager="$1" directory="$2" inherit_root="${3:-false}" status spec version major
  NODE_MANAGER_SPEC=""
  NODE_MANAGER_MAJOR=""
  case "$manager" in pnpm | yarn) ;; *) return 0 ;; esac
  if spec="$(node_effective_package_manager_spec "$directory" "$inherit_root")"; then
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
