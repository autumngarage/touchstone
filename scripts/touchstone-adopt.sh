#!/usr/bin/env bash
#
# scripts/touchstone-adopt.sh — compile repository facts into an adoption plan.
#
# Detectors are read-only adapters. They write records into one common plan
# model; only apply_plan writes repository files.

set -euo pipefail
LC_ALL=C
export LC_ALL

OPERATION="${1:-}"
if [ "$#" -gt 0 ]; then shift; fi

case "$OPERATION" in
  adopt | upgrade) ;;
  *)
    echo "ERROR: expected 'adopt' or 'upgrade'" >&2
    exit 2
    ;;
esac

usage() {
  if [ "$OPERATION" = adopt ]; then
    cat <<'EOF'
Usage:
  touchstone adopt [--check|--dry-run] [--json] [--project DIR] [--task NAME=COMMAND]
EOF
  else
    cat <<'EOF'
Usage:
  touchstone upgrade [--check|--dry-run] [--json] [--project DIR]
EOF
  fi
}

MODE=apply
JSON_MODE=false
PROJECT_ARG=""
MANUAL_TASK_ARGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)
      [ "$MODE" = apply ] || {
        echo "ERROR: --check and --dry-run are mutually exclusive" >&2
        exit 2
      }
      MODE=check
      shift
      ;;
    --dry-run)
      [ "$MODE" = apply ] || {
        echo "ERROR: --check and --dry-run are mutually exclusive" >&2
        exit 2
      }
      MODE=dry-run
      shift
      ;;
    --json)
      JSON_MODE=true
      shift
      ;;
    --project)
      [ "$#" -ge 2 ] || {
        echo "ERROR: --project requires a directory" >&2
        exit 2
      }
      PROJECT_ARG="$2"
      shift 2
      ;;
    --task)
      [ "$OPERATION" = adopt ] || {
        echo "ERROR: --task is valid only with adopt" >&2
        exit 2
      }
      [ "$#" -ge 2 ] || {
        echo "ERROR: --task requires NAME=COMMAND" >&2
        exit 2
      }
      MANUAL_TASK_ARGS+=("$2")
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
if [ -n "$PROJECT_ARG" ]; then
  PROJECT_INPUT="$PROJECT_ARG"
else
  PROJECT_INPUT="."
fi
PROJECT_ROOT="$(cd "$PROJECT_INPUT" 2>/dev/null && pwd -P)" || {
  echo "ERROR: project directory does not exist: $PROJECT_INPUT" >&2
  exit 2
}
GIT_ROOT="$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$GIT_ROOT" ]; then
  echo "ERROR: adoption requires a git repository: $PROJECT_ROOT" >&2
  exit 4
fi
GIT_ROOT="$(cd "$GIT_ROOT" && pwd -P)"
PROJECT_ROOT="$GIT_ROOT"

PLAN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-adopt.XXXXXX")" || {
  echo "ERROR: could not create adoption workspace" >&2
  exit 6
}
trap 'rm -rf "$PLAN_ROOT"' EXIT
TARGETS_FILE="$PLAN_ROOT/targets"
TASKS_FILE="$PLAN_ROOT/tasks"
SETUPS_FILE="$PLAN_ROOT/setups"
CHANGES_FILE="$PLAN_ROOT/changes"
DIFF_FILE="$PLAN_ROOT/diff"
OLD_ROOT="$PLAN_ROOT/old"
NEW_ROOT="$PLAN_ROOT/new"
mkdir -p "$OLD_ROOT" "$NEW_ROOT" || {
  echo "ERROR: could not initialize adoption workspace" >&2
  exit 6
}
: >"$TARGETS_FILE"
: >"$TASKS_FILE"
: >"$SETUPS_FILE"
: >"$CHANGES_FILE"
: >"$DIFF_FILE"

PROFILE=unknown
NODE_MANAGER=""
PLAN_STATUS=current
REFUSAL_REASON=""
TAB=$'\t'
CR=$'\r'
LF=$'\n'
TOUCHSTONE_BLOCK_BEGIN='<!-- touchstone:steering:start -->'
TOUCHSTONE_BLOCK_END='<!-- touchstone:steering:end -->'

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

valid_identifier() {
  case "$1" in "" | *[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac
}

valid_relative_path() {
  case "$1" in "" | /* | .. | ../* | */../* | */..) return 1 ;; esac
  case "$1" in *"$TAB"* | *"$CR"* | *"$LF"*) return 1 ;; esac
  return 0
}

json_string() {
  local value="$1"
  printf '"'
  printf '%s' "$value" | awk '
    {
      if (NR > 1) printf "\\n"
      for (position = 1; position <= length($0); position++) {
        character = substr($0, position, 1)
        if (character == "\\") printf "\\\\"
        else if (character == "\"") printf "\\\""
        else if (character == sprintf("%c", 8)) printf "\\b"
        else if (character == sprintf("%c", 9)) printf "\\t"
        else if (character == sprintf("%c", 12)) printf "\\f"
        else if (character == sprintf("%c", 13)) printf "\\r"
        else {
          control = 0
          for (code = 1; code < 32; code++) {
            if (character == sprintf("%c", code)) { control = code; break }
          }
          if (control) printf "\\u%04x", control
          else printf "%s", character
        }
      }
    }
  '
  printf '"'
}

change_count() {
  awk 'END { print NR + 0 }' "$CHANGES_FILE"
}

emit_json() {
  local status="$1" first=true action path ownership
  printf '{"schema":1,"operation":'
  json_string "$OPERATION"
  printf ',"status":'
  json_string "$status"
  printf ',"profile":'
  json_string "$PROFILE"
  printf ',"changes":['
  while IFS="$(printf '\t')" read -r action path ownership; do
    [ -n "$path" ] || continue
    if [ "$first" = false ]; then printf ','; fi
    first=false
    printf '{"path":'
    json_string "$path"
    printf ',"action":'
    json_string "$action"
    printf ',"ownership":'
    json_string "$ownership"
    printf '}'
  done <"$CHANGES_FILE"
  printf '],"remotePolicy":{"status":"separate-operation","required":true,"mutated":false},"diff":'
  json_string "$(cat "$DIFF_FILE")"
  if [ -n "$REFUSAL_REASON" ]; then
    printf ',"reason":'
    json_string "$REFUSAL_REASON"
  fi
  printf '}\n'
}

contract_refusal() {
  PROFILE="${PROFILE:-unknown}"
  REFUSAL_REASON="$*"
  if [ "$JSON_MODE" = true ]; then
    emit_json contract-refused
  else
    echo "ERROR: $*" >&2
  fi
  exit 4
}

safety_refusal() {
  REFUSAL_REASON="$*"
  if [ "$JSON_MODE" = true ]; then
    emit_json safety-refused
  else
    echo "ERROR: $*" >&2
  fi
  exit 5
}

operational_failure() {
  REFUSAL_REASON="$*"
  if [ "$JSON_MODE" = true ]; then
    emit_json operational-failure
  else
    echo "ERROR: $*" >&2
  fi
  exit 6
}

record_target() {
  local name="$1" path="$2" profile="$3"
  valid_identifier "$name" || contract_refusal "invalid target name '$name'"
  valid_relative_path "$path" || contract_refusal "target '$name' escapes the repository: $path"
  if awk -F '\t' -v value="$name" '$1 == value { found=1 } END { exit !found }' "$TARGETS_FILE"; then
    contract_refusal "duplicate target '$name'"
  fi
  printf '%s\t%s\t%s\n' "$name" "$path" "$profile" >>"$TARGETS_FILE"
}

record_task() {
  local name="$1" target="$2" command="$3"
  valid_identifier "$name" || contract_refusal "invalid task name '$name'"
  [ -n "$(trim "$command")" ] || contract_refusal "task '$name' has an empty command"
  case "$command" in *"$TAB"* | *"$CR"* | *"$LF"*)
    contract_refusal "task '$name' must be a single-line command"
    ;;
  esac
  if awk -F '\t' -v value="$name" '$1 == value { found=1 } END { exit !found }' "$TASKS_FILE"; then
    contract_refusal "duplicate task '$name'"
  fi
  printf '%s\t%s\ttrue\t%s\n' "$name" "$target" "$command" >>"$TASKS_FILE"
}

record_setup() {
  local directory="$1" command="$2" relative existing
  relative="${directory#"$PROJECT_ROOT"/}"
  [ "$directory" != "$PROJECT_ROOT" ] || relative=.
  valid_relative_path "$relative" || contract_refusal "setup path escapes the repository: $relative"
  case "$command" in "" | *"$TAB"* | *"$CR"* | *"$LF"*)
    contract_refusal "setup for '$relative' must be a non-empty single-line command"
    ;;
  esac
  existing="$(awk -F '\t' -v path="$relative" '$1 == path { print substr($0, index($0, "\t") + 1); exit }' "$SETUPS_FILE")"
  if [ -n "$existing" ]; then
    [ "$existing" = "$command" ] \
      || contract_refusal "target '$relative' requires conflicting setup commands"
    return 0
  fi
  printf '%s\t%s\n' "$relative" "$command" >>"$SETUPS_FILE"
}

legacy_value() {
  local key="$1" file="$2"
  awk -v wanted="$key" '
    /^[[:space:]]*#/ { next }
    {
      split($0, parts, "=")
      name = parts[1]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name != wanted) next
      value = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      answer = value
      seen = 1
    }
    END { if (seen) print answer }
  ' "$file"
}

detect_profile() {
  local directory="$1" count=0 found=""
  if [ -f "$directory/package.json" ] || [ -f "$directory/tsconfig.json" ] || [ -f "$directory/pnpm-workspace.yaml" ]; then
    found=node
    count=$((count + 1))
  fi
  if [ -f "$directory/pyproject.toml" ] || [ -f "$directory/uv.lock" ] || [ -f "$directory/requirements.txt" ]; then
    found="${found:+$found,}python"
    count=$((count + 1))
  fi
  if [ -f "$directory/Package.swift" ]; then
    found="${found:+$found,}swift"
    count=$((count + 1))
  fi
  if [ -f "$directory/Cargo.toml" ]; then
    found="${found:+$found,}rust"
    count=$((count + 1))
  fi
  if [ -f "$directory/go.mod" ]; then
    found="${found:+$found,}go"
    count=$((count + 1))
  fi
  if [ "$count" -gt 1 ]; then
    printf 'ambiguous:%s\n' "$found"
  elif [ "$count" -eq 1 ]; then
    printf '%s\n' "$found"
  else
    printf 'generic\n'
  fi
}

validate_json_document() {
  local file="$1"
  awk '
    function value_allowed() {
      if (depth == 0) return root_state == "value"
      if (kind[depth] == "object") return state[depth] == "value"
      return state[depth] == "value_or_end" || state[depth] == "value"
    }
    function value_complete() {
      if (depth == 0) root_state = "done"
      else state[depth] = "comma_or_end"
    }
    function begin_value(token) {
      if (!value_allowed()) { invalid = 1; return }
      if (depth == 0 && token != "{") { invalid = 1; return }
      if (token == "{") {
        depth++
        kind[depth] = "object"
        state[depth] = "key_or_end"
      } else if (token == "[") {
        depth++
        kind[depth] = "array"
        state[depth] = "value_or_end"
      } else value_complete()
    }
    function close_container(token, expected) {
      expected = token == "}" ? "object" : "array"
      if (depth == 0 || kind[depth] != expected) { invalid = 1; return }
      if (expected == "object") {
        if (state[depth] != "key_or_end" && state[depth] != "comma_or_end") {
          invalid = 1
          return
        }
      } else if (state[depth] != "value_or_end" && state[depth] != "comma_or_end") {
        invalid = 1
        return
      }
      delete kind[depth]
      delete state[depth]
      depth--
      value_complete()
    }
    function accept(token) {
      if (invalid) return
      if (token == "string" && depth > 0 && kind[depth] == "object" &&
          (state[depth] == "key_or_end" || state[depth] == "key")) {
        state[depth] = "colon"
      } else if (token == ":") {
        if (depth == 0 || kind[depth] != "object" || state[depth] != "colon") invalid = 1
        else state[depth] = "value"
      } else if (token == ",") {
        if (depth == 0 || state[depth] != "comma_or_end") invalid = 1
        else if (kind[depth] == "object") state[depth] = "key"
        else state[depth] = "value"
      } else if (token == "}" || token == "]") close_container(token)
      else begin_value(token)
    }
    function finish_raw() {
      if (raw_token == "true" || raw_token == "false" || raw_token == "null" ||
          raw_token ~ /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) accept("scalar")
      else invalid = 1
      raw = 0
      raw_token = ""
    }
    function punctuation(character) {
      return character == "{" || character == "}" || character == "[" ||
        character == "]" || character == ":" || character == ","
    }
    BEGIN { root_state = "value" }
    {
      line = $0 "\n"
      for (position = 1; position <= length(line); position++) {
        character = substr(line, position, 1)
        if (raw) {
          if (character ~ /[[:space:]]/ || punctuation(character)) {
            finish_raw()
            position--
          } else raw_token = raw_token character
          continue
        }
        if (in_string) {
          if (unicode_left > 0) {
            if (character !~ /^[0-9A-Fa-f]$/) invalid = 1
            unicode_left--
          } else if (escaped) {
            if (character == "u") unicode_left = 4
            else if (index("\"\\/bfnrt", character) == 0) invalid = 1
            escaped = 0
          } else if (character == "\\") escaped = 1
          else if (character == "\"") {
            in_string = 0
            accept("string")
          } else if (character ~ /[[:cntrl:]]/) invalid = 1
          continue
        }
        if (character ~ /[[:space:]]/) continue
        if (character == "\"") { in_string = 1; continue }
        if (punctuation(character)) { accept(character); continue }
        raw = 1
        raw_token = character
      }
    }
    END {
      if (raw) finish_raw()
      if (in_string || escaped || unicode_left > 0 || depth != 0 || root_state != "done") invalid = 1
      exit invalid ? 1 : 0
    }
  ' "$file"
}

json_object_has_key() {
  local file="$1" object="$2" wanted="$3"
  awk -v object="$object" -v wanted="$wanted" '
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
        if (token ~ /[^[:space:]]/) found = 1
        capturing_value = 0
      } else pending = token
      token = ""
      in_string = 0
    }
    {
      line = $0 "\n"
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (in_string) {
          if (unicode_left > 0) {
            unicode_hex = unicode_hex c
            unicode_left--
            if (unicode_left == 0) {
              token = token decoded_unicode(unicode_hex)
              unicode_hex = ""
            }
          }
          else if (escaped) {
            if (c == "u") {
              unicode_left = 4
              unicode_hex = ""
            } else token = token decoded_escape(c)
            escaped = 0
          }
          else if (c == "\\") escaped = 1
          else if (c == "\"") finish_string()
          else token = token c
          continue
        }
        if (seeking_object && c ~ /[[:space:]]/) continue
        if (seeking_object && c != "{") { invalid = 1; seeking_object = 0 }
        if (seeking_value && c ~ /[[:space:]]/) continue
        if (seeking_value) {
          if (c == "\"") {
            seeking_value = 0
            in_string = 1
            capturing_value = 1
            token = ""
            continue
          }
          invalid = 1
          seeking_value = 0
        }
        if (c == "\"") { in_string = 1; token = ""; continue }
        if (c == ":") {
          if (depth == 1 && pending == object) {
            if (object_seen) invalid = 1
            object_seen = 1
            seeking_object = 1
          }
          else if (object_depth > 0 && depth == object_depth && pending == wanted) seeking_value = 1
          pending = ""
          continue
        }
        if (c == "{") {
          depth++
          if (seeking_object) { object_depth = depth; seeking_object = 0 }
          pending = ""
          continue
        }
        if (c == "}") {
          if (depth <= 0) invalid = 1
          if (depth == object_depth) object_depth = 0
          depth--
          pending = ""
          continue
        }
        if (c !~ /[[:space:]]/) pending = ""
      }
    }
    END {
      if (invalid || in_string || escaped || unicode_left > 0 || depth != 0 || seeking_object || seeking_value) exit 2
      exit !found
    }
  ' "$file"
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

node_setup_command() {
  local manager="$1" directory="$2"
  case "$manager" in
    npm)
      if [ -f "$directory/package-lock.json" ] || [ -f "$directory/npm-shrinkwrap.json" ]; then
        printf 'npm ci\n'
      else
        printf 'npm install\n'
      fi
      ;;
    pnpm)
      if [ -f "$directory/pnpm-lock.yaml" ]; then
        printf 'pnpm install --frozen-lockfile\n'
      else
        printf 'pnpm install\n'
      fi
      ;;
    yarn) printf 'yarn install --immutable\n' ;;
    bun)
      if [ -f "$directory/bun.lock" ] || [ -f "$directory/bun.lockb" ]; then
        printf 'bun install --frozen-lockfile\n'
      else
        printf 'bun install\n'
      fi
      ;;
  esac
}

node_command() {
  local manager="$1" task="$2"
  case "$manager" in
    npm) printf 'npm run %s\n' "$task" ;;
    pnpm) printf 'pnpm run %s\n' "$task" ;;
    yarn) printf 'yarn %s\n' "$task" ;;
    bun) printf 'bun run %s\n' "$task" ;;
  esac
}

tasks_for_node() {
  local directory="$1" target="$2" suffix="$3" inherited="${4:-}" manager setup_directory task found=false
  [ -f "$directory/package.json" ] || contract_refusal "Node target '$target' has no package.json"
  node_package_manager "$directory" "$inherited"
  manager="$NODE_MANAGER"
  if [ -n "$inherited" ]; then setup_directory="$PROJECT_ROOT"; else setup_directory="$directory"; fi
  record_setup "$setup_directory" "$(node_setup_command "$manager" "$setup_directory")"
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

tasks_for_python() {
  local directory="$1" target="$2" suffix="$3" prefix="python -m" found=false
  if [ -f "$directory/uv.lock" ]; then
    prefix="uv run --no-sync"
    record_setup "$directory" "uv sync --frozen"
  elif [ -f "$directory/requirements.txt" ]; then
    record_setup "$directory" "python -m pip install -r requirements.txt"
  elif [ -f "$directory/pyproject.toml" ]; then
    record_setup "$directory" "python -m pip install -e ."
  fi
  if [ -f "$directory/pyproject.toml" ] && grep -Eq '^\[tool\.ruff(\.|\])' "$directory/pyproject.toml"; then
    record_task "lint$suffix" "$target" "$prefix ruff check ."
    found=true
  fi
  if [ -f "$directory/pyproject.toml" ] && grep -Eq '^\[tool\.mypy(\.|\])' "$directory/pyproject.toml"; then
    record_task "typecheck$suffix" "$target" "$prefix mypy ."
    found=true
  fi
  if { [ -f "$directory/pyproject.toml" ] && grep -Eq '^\[tool\.pytest(\.|\])|["'\'' ]pytest([<=>~! ]|$)' "$directory/pyproject.toml"; } \
    || [ -d "$directory/tests" ]; then
    record_task "test$suffix" "$target" "$prefix pytest"
    found=true
  fi
  [ "$found" = true ] || contract_refusal "Python target '$target' has no declared ruff, mypy, or pytest evidence; pass --task NAME=COMMAND"
}

tasks_for_profile() {
  local directory="$1" target="$2" profile="$3" suffix="$4" inherited_node_manager="${5:-}"
  case "$profile" in
    node) tasks_for_node "$directory" "$target" "$suffix" "$inherited_node_manager" ;;
    python) tasks_for_python "$directory" "$target" "$suffix" ;;
    swift) record_task "test$suffix" "$target" "swift test" ;;
    rust) record_task "test$suffix" "$target" "cargo test" ;;
    go) record_task "test$suffix" "$target" "go test ./..." ;;
    generic) contract_refusal "no supported project facts found; pass --task NAME=COMMAND for a manual declaration" ;;
    ambiguous:*) contract_refusal "ambiguous project facts for target '$target': ${profile#ambiguous:}" ;;
    *) contract_refusal "unsupported project profile '$profile'" ;;
  esac
}

compile_manual_tasks() {
  local argument name command
  record_target root . manual
  for argument in "${MANUAL_TASK_ARGS[@]}"; do
    case "$argument" in *=*) ;; *) contract_refusal "--task requires NAME=COMMAND" ;; esac
    name="${argument%%=*}"
    command="${argument#*=}"
    record_task "$name" root "$command"
  done
  PROFILE=manual
}

compile_legacy() {
  local file="$PROJECT_ROOT/.touchstone-config" configured_profile command key found=false
  configured_profile="$(legacy_value project_type "$file")"
  for key in validate_command validate_full_command; do
    command="$(legacy_value "$key" "$file")"
    if [ -n "$command" ]; then
      record_target root . "${configured_profile:-legacy}"
      record_task validate root "$command"
      PROFILE="legacy-${configured_profile:-manual}"
      return 0
    fi
  done
  record_target root . "${configured_profile:-legacy}"
  for key in lint_command typecheck_command test_command build_command; do
    command="$(legacy_value "$key" "$file")"
    if [ -n "$command" ]; then
      record_task "${key%_command}" root "$command"
      found=true
    fi
  done
  if [ "$found" = true ]; then
    PROFILE="legacy-${configured_profile:-manual}"
    return 0
  fi
  case "$configured_profile" in
    node | python | swift | rust | go) PROFILE="$configured_profile" ;;
    generic | "" | auto) PROFILE="$(detect_profile "$PROJECT_ROOT")" ;;
    *) contract_refusal "legacy .touchstone-config declares unsupported project_type '$configured_profile'" ;;
  esac
  tasks_for_profile "$PROJECT_ROOT" root "$PROFILE" ""
}

target_name_for_path() {
  local path="$1" name
  name="$(basename "$path" | tr -c 'A-Za-z0-9._-' '-')"
  name="${name%-}"
  valid_identifier "$name" || name=target
  printf '%s\n' "$name"
}

compile_detected() {
  local base directory relative profile target suffix found_targets=false workspace_node_manager resolved_directory
  node_package_manager "$PROJECT_ROOT" "" ""
  workspace_node_manager="$NODE_MANAGER"
  for base in apps packages services; do
    [ -d "$PROJECT_ROOT/$base" ] || continue
    for directory in "$PROJECT_ROOT/$base"/*; do
      [ -d "$directory" ] || continue
      resolved_directory="$(cd "$directory" 2>/dev/null && pwd -P)" \
        || contract_refusal "could not resolve monorepo target ${directory#"$PROJECT_ROOT"/}"
      case "$resolved_directory" in "$PROJECT_ROOT"/*) ;; *)
        contract_refusal "monorepo target ${directory#"$PROJECT_ROOT"/} resolves outside the repository"
        ;;
      esac
      profile="$(detect_profile "$directory")"
      [ "$profile" = generic ] && continue
      relative="${directory#"$PROJECT_ROOT"/}"
      target="$(target_name_for_path "$base-$(basename "$relative")")"
      suffix="-$target"
      record_target "$target" "$relative" "$profile"
      tasks_for_profile "$directory" "$target" "$profile" "$suffix" "$workspace_node_manager"
      found_targets=true
    done
  done
  if [ "$found_targets" = true ]; then
    PROFILE=monorepo
    return 0
  fi
  PROFILE="$(detect_profile "$PROJECT_ROOT")"
  record_target root . "$PROFILE"
  tasks_for_profile "$PROJECT_ROOT" root "$PROFILE" ""
}

toml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

render_contract() {
  local output="$1" name path _profile task target required command setup_command="" setup_entry quoted_path
  while IFS="$(printf '\t')" read -r path command; do
    [ -n "$path" ] || continue
    if [ "$path" = . ]; then
      setup_entry="$command"
    else
      printf -v quoted_path '%q' "$path"
      setup_entry="(cd $quoted_path && $command)"
    fi
    setup_command="${setup_command:+$setup_command && }$setup_entry"
  done <"$SETUPS_FILE"
  {
    printf 'schema = 1\n\n'
    printf '[validation]\n'
    printf 'runtime = "bash"\n'
    if [ -n "$setup_command" ]; then
      printf 'setup = "%s"\n' "$(toml_escape "$setup_command")"
    fi
    while IFS="$(printf '\t')" read -r name path _profile; do
      printf '\n[[validation.targets]]\n'
      printf 'name = "%s"\n' "$(toml_escape "$name")"
      printf 'path = "%s"\n' "$(toml_escape "$path")"
    done <"$TARGETS_FILE"
    while IFS="$(printf '\t')" read -r task target required command; do
      printf '\n[[validation.tasks]]\n'
      printf 'name = "%s"\n' "$(toml_escape "$task")"
      printf 'target = "%s"\n' "$(toml_escape "$target")"
      printf 'command = "%s"\n' "$(toml_escape "$command")"
      printf 'required = %s\n' "$required"
    done <"$TASKS_FILE"
  } >"$output"
}

safe_owned_path() {
  local relative="$1" destination parent
  destination="$PROJECT_ROOT/$relative"
  valid_relative_path "$relative" || contract_refusal "managed path escapes the repository: $relative"
  if [ -L "$destination" ]; then
    contract_refusal "managed path is a symlink: $relative"
  fi
  parent="$(dirname "$destination")"
  while [ "$parent" != "$PROJECT_ROOT" ] && [ "$parent" != / ]; do
    if [ -L "$parent" ]; then
      contract_refusal "managed path traverses a symlink: ${parent#"$PROJECT_ROOT"/}"
    fi
    parent="$(dirname "$parent")"
  done
}

plan_file() {
  local relative="$1" proposed="$2" ownership="$3" action destination old_file new_file
  safe_owned_path "$relative"
  destination="$PROJECT_ROOT/$relative"
  old_file="$OLD_ROOT/$relative"
  new_file="$NEW_ROOT/$relative"
  mkdir -p "$(dirname "$old_file")" "$(dirname "$new_file")" \
    || operational_failure "could not stage the plan for $relative"
  if [ -e "$destination" ]; then
    [ -f "$destination" ] || contract_refusal "managed path is not a regular file: $relative"
    cp -p "$destination" "$old_file" || operational_failure "could not read $relative"
    action=update
  else
    : >"$old_file"
    action=create
  fi
  if [ -e "$destination" ]; then
    if ! cp -p "$destination" "$new_file" || ! cat "$proposed" >"$new_file"; then
      operational_failure "could not stage proposed content for $relative"
    fi
  else
    cp -p "$proposed" "$new_file" || operational_failure "could not stage proposed content for $relative"
  fi
  if cmp -s "$old_file" "$new_file"; then return 0; fi
  printf '%s\t%s\t%s\n' "$action" "$relative" "$ownership" >>"$CHANGES_FILE"
}

plan_managed_file() {
  local relative="$1" proposed="$2" refresh="$3"
  if [ "$refresh" = true ] || [ ! -e "$PROJECT_ROOT/$relative" ]; then
    plan_file "$relative" "$proposed" touchstone-managed
    return 0
  fi
  safe_owned_path "$relative"
  [ -f "$PROJECT_ROOT/$relative" ] || contract_refusal "managed path is not a regular file: $relative"
}

render_consumer_steering() {
  local output="$1"
  sed 's#principles/#.touchstone/principles/#g' "$SCRIPT_ROOT/TOUCHSTONE.md" >"$output" \
    || operational_failure "could not render consumer steering"
}

render_inline_block() {
  local steering="$1" output="$2"
  {
    printf '%s\n\n' "$TOUCHSTONE_BLOCK_BEGIN"
    printf '%s\n' '<!-- Managed by touchstone upgrade. Edit content outside the markers. -->'
    printf '\n'
    cat "$steering"
    printf '\n%s\n' "$TOUCHSTONE_BLOCK_END"
  } >"$output"
}

render_claude_block() {
  local output="$1"
  {
    printf '%s\n\n' "$TOUCHSTONE_BLOCK_BEGIN"
    printf '%s\n' '<!-- Managed by touchstone upgrade. Edit content outside the markers. -->'
    printf '\n## Touchstone universal steering\n\n'
    printf '@.touchstone/TOUCHSTONE.md\n\n'
    printf '%s\n' "$TOUCHSTONE_BLOCK_END"
  } >"$output"
}

merge_managed_block() {
  local destination="$1" block="$2" output="$3" default_heading="$4"
  local begin_count end_count begin_line end_line in_block=false inserted=false line comparison
  if [ ! -e "$destination" ]; then
    {
      printf '# %s\n\n' "$default_heading"
      cat "$block"
    } >"$output"
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
    cat "$destination" >"$output"
    if [ -s "$output" ] && [ "$(tail -c 1 "$output" | wc -l | tr -d ' ')" -eq 0 ]; then printf '\n' >>"$output"; fi
    printf '\n' >>"$output"
    cat "$block" >>"$output"
    return 0
  fi
  begin_line="$(awk -v marker="$TOUCHSTONE_BLOCK_BEGIN" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) print NR }' "$destination")"
  end_line="$(awk -v marker="$TOUCHSTONE_BLOCK_END" \
    '{ line=$0; sub(/\r$/, "", line); if (line == marker) print NR }' "$destination")"
  if [ "$begin_line" -ge "$end_line" ]; then
    contract_refusal "steering markers are out of order in ${destination#"$PROJECT_ROOT"/}"
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    comparison="${line%"$CR"}"
    if [ "$in_block" = true ]; then
      if [ "$comparison" = "$TOUCHSTONE_BLOCK_END" ]; then in_block=false; fi
      continue
    fi
    if [ "$comparison" = "$TOUCHSTONE_BLOCK_BEGIN" ]; then
      if [ "$inserted" = false ]; then
        cat "$block" >>"$output"
        inserted=true
      fi
      in_block=true
      continue
    fi
    printf '%s\n' "$line" >>"$output"
  done <"$destination"
}

managed_block_present() {
  local relative="$1" destination
  local begin_count end_count begin_line end_line
  destination="$PROJECT_ROOT/$relative"
  safe_owned_path "$relative"
  [ -e "$destination" ] || return 1
  [ -f "$destination" ] || contract_refusal "steering path is not a regular file: $relative"
  begin_count="$(grep -cFx "$TOUCHSTONE_BLOCK_BEGIN" "$destination" || true)"
  end_count="$(grep -cFx "$TOUCHSTONE_BLOCK_END" "$destination" || true)"
  if [ "$begin_count" -ne "$end_count" ] || [ "$begin_count" -gt 1 ]; then
    contract_refusal "steering markers are malformed in $relative"
  fi
  [ "$begin_count" -eq 1 ] || return 1
  begin_line="$(awk -v marker="$TOUCHSTONE_BLOCK_BEGIN" '$0 == marker { print NR }' "$destination")"
  end_line="$(awk -v marker="$TOUCHSTONE_BLOCK_END" '$0 == marker { print NR }' "$destination")"
  [ "$begin_line" -lt "$end_line" ] || contract_refusal "steering markers are out of order in $relative"
  return 0
}

plan_steering() {
  local refresh="$1"
  local consumer="$PLAN_ROOT/consumer-touchstone.md" inline="$PLAN_ROOT/inline-block.md"
  local claude="$PLAN_ROOT/claude-block.md" proposed file relative rendered_principle
  render_consumer_steering "$consumer"
  plan_managed_file .touchstone/TOUCHSTONE.md "$consumer" "$refresh"
  for file in "$SCRIPT_ROOT"/principles/*.md; do
    relative=".touchstone/principles/$(basename "$file")"
    rendered_principle="$PLAN_ROOT/principle-$(basename "$file")"
    sed 's#principles/#.touchstone/principles/#g' "$file" >"$rendered_principle" \
      || operational_failure "could not render $(basename "$file")"
    plan_managed_file "$relative" "$rendered_principle" "$refresh"
  done
  render_inline_block "$consumer" "$inline"
  render_claude_block "$claude"
  for file in AGENTS.md GEMINI.md; do
    if [ "$refresh" = false ] && managed_block_present "$file"; then continue; fi
    proposed="$PLAN_ROOT/proposed-$file"
    : >"$proposed"
    merge_managed_block "$PROJECT_ROOT/$file" "$inline" "$proposed" "$file instructions"
    plan_file "$file" "$proposed" marked-block
  done
  if [ "$refresh" = false ] && managed_block_present CLAUDE.md; then return 0; fi
  proposed="$PLAN_ROOT/proposed-CLAUDE.md"
  : >"$proposed"
  merge_managed_block "$PROJECT_ROOT/CLAUDE.md" "$claude" "$proposed" "Claude Code instructions"
  plan_file CLAUDE.md "$proposed" marked-block
}

render_diff() {
  local action path ownership status
  : >"$DIFF_FILE"
  while IFS="$(printf '\t')" read -r action path ownership; do
    [ -n "$path" ] || continue
    set +e
    if [ "$action" = create ]; then
      (
        cd "$PLAN_ROOT"
        git diff --no-index --no-ext-diff --src-prefix=a/ --dst-prefix=b/ -- /dev/null "new/$path"
      ) | sed \
        -e 's#^diff --git a/new/\(.*\) b/new/#diff --git a/\1 b/#' \
        -e 's#^+++ b/new/#+++ b/#' >>"$DIFF_FILE"
    else
      (
        cd "$PLAN_ROOT"
        git diff --no-index --no-ext-diff --src-prefix=a/ --dst-prefix=b/ -- "old/$path" "new/$path"
      ) | sed \
        -e 's#^diff --git a/old/\(.*\) b/new/#diff --git a/\1 b/#' \
        -e 's#^--- a/old/#--- a/#' \
        -e 's#^+++ b/new/#+++ b/#' >>"$DIFF_FILE"
    fi
    status=${PIPESTATUS[0]}
    set -e
    case "$status" in 0 | 1) ;; *)
      echo "ERROR: could not render proposed diff for $path" >&2
      exit 6
      ;;
    esac
  done <"$CHANGES_FILE"
}

extract_schema() {
  awk '
    /^[[:space:]]*\[/ { in_root = 0 }
    BEGIN { in_root = 1 }
    in_root && /^[[:space:]]*schema[[:space:]]*=/ {
      value = $0
      sub(/^[^=]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]*(#.*)?$/, "", value)
      print value
    }
  ' "$1"
}

validate_existing_contract() {
  local schema_output validation_output status
  [ ! -L "$PROJECT_ROOT/.touchstone.toml" ] || contract_refusal ".touchstone.toml must be a regular file inside the repository"
  schema_output="$(extract_schema "$PROJECT_ROOT/.touchstone.toml")"
  [ "$schema_output" = 1 ] || contract_refusal "unsupported or ambiguous .touchstone.toml schema '$schema_output'; this CLI accepts schema 1"
  set +e
  validation_output="$(bash "$SCRIPT_ROOT/scripts/touchstone-run.sh" validate --check-contract --project "$PROJECT_ROOT" 2>&1)"
  status=$?
  set -e
  [ "$status" -eq 0 ] || contract_refusal "existing .touchstone.toml is invalid: $validation_output"
}

compile_plan() {
  local proposed_contract="$PLAN_ROOT/proposed-contract.toml" contract_existed=false
  if [ -f "$PROJECT_ROOT/.touchstone.toml" ]; then
    [ "${#MANUAL_TASK_ARGS[@]}" -eq 0 ] || contract_refusal "--task cannot replace an existing .touchstone.toml declaration"
    validate_existing_contract
    PROFILE="declared-v1"
    contract_existed=true
  elif [ "$OPERATION" = upgrade ]; then
    contract_refusal "repository is not adopted; run touchstone adopt first"
  else
    if [ "${#MANUAL_TASK_ARGS[@]}" -gt 0 ]; then
      compile_manual_tasks
    elif [ -f "$PROJECT_ROOT/.touchstone-config" ]; then
      compile_legacy
    else
      compile_detected
    fi
    render_contract "$proposed_contract"
    plan_file .touchstone.toml "$proposed_contract" project-contract
  fi
  if [ "$OPERATION" = upgrade ]; then
    plan_steering true
  elif [ "$contract_existed" = true ]; then
    plan_steering false
  else
    plan_steering true
  fi
  if [ -s "$CHANGES_FILE" ]; then PLAN_STATUS=changes-required; else PLAN_STATUS=current; fi
  render_diff
}

current_branch_is_default() {
  local branch remote_default=""
  branch="$(git -C "$PROJECT_ROOT" branch --show-current)" \
    || operational_failure "could not read the current branch"
  [ -n "$branch" ] || return 0
  remote_default="$(git -C "$PROJECT_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  remote_default="${remote_default#origin/}"
  case "$branch" in main | master) return 0 ;; esac
  [ -n "$remote_default" ] || return 2
  [ "$branch" = "$remote_default" ]
}

apply_plan() {
  local action path ownership destination source parent temporary worktree_status default_status
  [ -s "$CHANGES_FILE" ] || return 0
  worktree_status="$(git -C "$PROJECT_ROOT" status --porcelain=v1)" \
    || operational_failure "could not inspect worktree state"
  [ -z "$worktree_status" ] || safety_refusal "apply requires a clean worktree"
  if current_branch_is_default; then
    safety_refusal "apply requires a non-default branch"
  else
    default_status=$?
    [ "$default_status" -eq 1 ] \
      || safety_refusal "apply requires a known default branch; set refs/remotes/origin/HEAD before applying"
  fi
  while IFS="$(printf '\t')" read -r action path ownership; do
    [ -n "$path" ] || continue
    safe_owned_path "$path"
    destination="$PROJECT_ROOT/$path"
    source="$NEW_ROOT/$path"
    parent="$(dirname "$destination")"
    mkdir -p "$parent" || operational_failure "could not create $parent"
    temporary="$(mktemp "$parent/.touchstone-write.XXXXXX")" || {
      operational_failure "could not stage $path"
    }
    if [ -e "$destination" ]; then
      if ! cp -p "$destination" "$temporary" || ! cat "$source" >"$temporary"; then
        rm -f "$temporary"
        operational_failure "could not stage $path"
      fi
    elif ! cp -p "$source" "$temporary"; then
      rm -f "$temporary"
      operational_failure "could not stage $path"
    fi
    if ! mv "$temporary" "$destination"; then
      rm -f "$temporary"
      operational_failure "could not apply $path"
    fi
  done <"$CHANGES_FILE"
}

compile_plan

case "$MODE" in
  check)
    if [ "$JSON_MODE" = true ]; then emit_json "$PLAN_STATUS"; fi
    if [ "$PLAN_STATUS" = current ]; then
      if [ "$JSON_MODE" = false ]; then printf '%s: current\n' "$OPERATION"; fi
      exit 0
    fi
    if [ "$JSON_MODE" = false ]; then
      printf '%s: %s file change(s) required\n' "$OPERATION" "$(change_count)"
      awk -F '\t' '{ printf "  %s %s\n", $1, $2 }' "$CHANGES_FILE"
    fi
    exit 3
    ;;
  dry-run)
    if [ "$JSON_MODE" = true ]; then
      emit_json "$PLAN_STATUS"
    else
      printf '%s: %s file change(s) proposed\n' "$OPERATION" "$(change_count)"
      cat "$DIFF_FILE"
      printf 'Remote policy: separate operation; no remote state was read or changed.\n'
    fi
    ;;
  apply)
    apply_plan
    if [ "$JSON_MODE" = true ]; then
      if [ "$PLAN_STATUS" = current ]; then emit_json current; else emit_json applied; fi
    elif [ "$PLAN_STATUS" = current ]; then
      printf '%s: current; no files changed\n' "$OPERATION"
    else
      printf '%s: applied %s file change(s)\n' "$OPERATION" "$(change_count)"
      printf 'Remote policy: separate operation; no remote state was read or changed.\n'
    fi
    ;;
esac
