# shellcheck shell=bash

tracker_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

tracker_parse_string() {
  local raw
  raw="$(tracker_trim "$1")"
  case "$raw" in
    \"*\")
      raw="${raw#\"}"
      raw="${raw%\"}"
      ;;
    *) return 1 ;;
  esac
  case "$raw" in *\"* | *\\*) return 1 ;; esac
  PARSED="$raw"
}

load_tracker_contract() {
  local config="$1" line key value lineno=0
  TRACKER="github"
  KEY_PREFIX=""
  TRACKER_SCHEMA_SEEN=false
  TRACKER_TYPE_SEEN=false
  TRACKER_KEYS=""
  [ ! -L "$config" ] \
    || tracker_contract_failure unsafe-config "Replace .touchstone-tracker.toml with a reviewed regular file in this repository."
  [ -e "$config" ] || return 0
  [ -f "$config" ] \
    || tracker_contract_failure unsafe-config "Replace .touchstone-tracker.toml with a reviewed regular file."

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="$(tracker_trim "${line%%#*}")"
    [ -n "$line" ] || continue
    case "$line" in
      *=*)
        key="$(tracker_trim "${line%%=*}")"
        value="${line#*=}"
        ;;
      *) tracker_contract_failure malformed-config "Use key = value syntax at .touchstone-tracker.toml:$lineno." ;;
    esac
    case " $TRACKER_KEYS " in
      *" $key "*) tracker_contract_failure duplicate-tracker-key "Keep exactly one tracker $key declaration." ;;
    esac
    TRACKER_KEYS="$TRACKER_KEYS $key"
    case "$key" in
      schema)
        value="$(tracker_trim "$value")"
        [ "$value" = 1 ] \
          || tracker_contract_failure unsupported-tracker-schema "Set schema = 1 in .touchstone-tracker.toml."
        TRACKER_SCHEMA_SEEN=true
        ;;
      type)
        tracker_parse_string "$value" \
          || tracker_contract_failure malformed-config "Set type to a single-line quoted string."
        TRACKER="$PARSED"
        TRACKER_TYPE_SEEN=true
        ;;
      key_prefix)
        tracker_parse_string "$value" \
          || tracker_contract_failure malformed-config "Set key_prefix to a single-line quoted string."
        KEY_PREFIX="$PARSED"
        ;;
      *) tracker_contract_failure unknown-tracker-key "Remove unsupported tracker key '$key'." ;;
    esac
  done <"$config"

  case "$TRACKER" in
    github | linear) ;;
    *) tracker_contract_failure unknown-tracker "Set type to \"github\" or \"linear\"." ;;
  esac
  [ "$TRACKER_SCHEMA_SEEN" = true ] \
    || tracker_contract_failure missing-tracker-schema "Add schema = 1 to .touchstone-tracker.toml."
  [ "$TRACKER_TYPE_SEEN" = true ] \
    || tracker_contract_failure missing-tracker-type "Add type = \"github\" or type = \"linear\" to .touchstone-tracker.toml."
  if [ "$TRACKER" = linear ]; then
    printf '%s' "$KEY_PREFIX" | grep -Eq '^[A-Z][A-Z0-9]*$' \
      || tracker_contract_failure invalid-key-prefix "Set key_prefix to the Linear team key, for example \"AUT\"."
  elif [ -n "$KEY_PREFIX" ]; then
    tracker_contract_failure invalid-key-prefix "Remove key_prefix; it applies only to the Linear tracker."
  fi
}
