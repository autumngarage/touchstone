#!/usr/bin/env bash
#
# bootstrap/review.sh — preview or run a review of the current diff
# without (or before) pushing.
#
# Today the only supported subcommand is `--dry-run`: resolves the
# project's conductor configuration the same way the pre-push hook
# does, then invokes `conductor route` so the user sees
# which provider would be picked, what it'd cost, how hard it'd
# think — without spending tokens or money.
#
# Future: a `touchstone review` (no flag) variant could run the
# real review without pushing. Out of scope for v2.0.

set -euo pipefail

usage() {
  cat <<EOF
Usage: touchstone review --dry-run [--mode MODE] [--base REF] [--json]

Options:
  --dry-run        Required for now. Print the routing decision without
                   spending tokens.
  --mode MODE      Override REVIEW_MODE: review-only|fix|diff-only|no-tests
                   (default: from .codex-review.toml or "fix").
  --base REF       Diff base. Default: origin/<default-branch>.
  --json           Emit conductor's JSON output instead of the human-readable form.
  -h, --help       Show this help.

Environment overrides take precedence over .codex-review.toml:
  TOUCHSTONE_CONDUCTOR_WITH    pin to a specific provider
  TOUCHSTONE_CONDUCTOR_PREFER  best | cheapest | fastest | balanced
  TOUCHSTONE_CONDUCTOR_EFFORT  minimal | low | medium | high | max
  TOUCHSTONE_CONDUCTOR_TAGS    comma-separated capability tags
  TOUCHSTONE_CONDUCTOR_EXCLUDE comma-separated providers to skip
EOF
}

dry_run=false
mode_override=""
base_override=""
json_flag=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      dry_run=true
      shift
      ;;
    --mode)
      [ "$#" -ge 2 ] || {
        echo "ERROR: --mode requires a value" >&2
        exit 1
      }
      mode_override="$2"
      shift 2
      ;;
    --base)
      [ "$#" -ge 2 ] || {
        echo "ERROR: --base requires a ref" >&2
        exit 1
      }
      base_override="$2"
      shift 2
      ;;
    --json)
      json_flag="--json"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "$dry_run" = false ]; then
  echo "ERROR: only --dry-run is supported in v2.0." >&2
  echo "" >&2
  usage >&2
  exit 1
fi

if ! command -v conductor >/dev/null 2>&1; then
  echo "ERROR: \`conductor\` CLI not found on PATH." >&2
  echo "  Install: brew install autumngarage/conductor/conductor" >&2
  echo "  Configure: conductor init" >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || {
  echo "ERROR: not inside a git repository." >&2
  exit 1
}

CONFIG_FILE="$REPO_ROOT/.codex-review.toml"

# Defaults (mirror the runtime cascade in hooks/codex-review.sh).
CONDUCTOR_WITH=""
CONDUCTOR_PREFER=""
CONDUCTOR_EFFORT=""
CONDUCTOR_TAGS=""
CONDUCTOR_EXCLUDE=""
CONDUCTOR_EXCLUDE_CONFIGURED=false
ROUTING_ENABLED=true
ROUTING_SMALL_MAX_DIFF_LINES=400
ROUTING_SMALL_WITH=""
ROUTING_SMALL_PREFER="cheapest"
ROUTING_SMALL_EFFORT="minimal"
ROUTING_SMALL_TAGS=""
ROUTING_LARGE_WITH=""
ROUTING_LARGE_PREFER="best"
ROUTING_LARGE_EFFORT="medium"
ROUTING_LARGE_TAGS=""
ROUTING_HIGH_RISK_WITH=""
ROUTING_HIGH_RISK_PREFER="best"
ROUTING_HIGH_RISK_EFFORT="high"
ROUTING_HIGH_RISK_TAGS=""
UNSAFE_PATHS=""
ARCHITECTURAL_PATHS="AGENTS.md
CLAUDE.md
GEMINI.md
.codex-review.toml
.codex-review-context.md
.github/codex-review-context.md
.github/workflows/
bootstrap/
hooks/codex-review.sh
hooks/codex-review.config.example.toml
scripts/codex-review.sh
architecture/
docs/architecture/
principles/"
FULL_CONTEXT_PATHS=""
CONFIG_MODE=""

strip_quotes() {
  local v="$1"
  v="${v# }"
  v="${v% }"
  case "$v" in
    \"*\")
      v="${v#\"}"
      v="${v%\"}"
      ;;
    \'*\')
      v="${v#\'}"
      v="${v%\'}"
      ;;
  esac
  printf '%s' "$v"
}

normalize_bool() {
  local value
  value="$(strip_quotes "$1")"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    true | 1 | yes | on) printf 'true' ;;
    false | 0 | no | off) printf 'false' ;;
    *) printf '%s' "$value" ;;
  esac
}

# Parse .codex-review.toml if it exists.
if [ -f "$CONFIG_FILE" ]; then
  # Source the TOML library
  # shellcheck source=lib/toml.sh
  source "$TOUCHSTONE_ROOT/lib/toml.sh"

  toml_review_callback() {
    local section="$1"
    local key="$2"
    local value="$3"

    case "$section" in
      "codex_review" | "")
        case "$key" in
          mode) CONFIG_MODE="$(toml_unquote "$value")" ;;
          unsafe_paths) UNSAFE_PATHS="$(toml_normalize_array "$value" | tr ',' '\n')" ;;
        esac
        ;;
      "review.conductor")
        case "$key" in
          prefer) CONDUCTOR_PREFER="$(toml_unquote "$value")" ;;
          effort) CONDUCTOR_EFFORT="$(toml_unquote "$value")" ;;
          tags) CONDUCTOR_TAGS="$(toml_normalize_array "$value")" ;;
          with) CONDUCTOR_WITH="$(toml_unquote "$value")" ;;
          exclude)
            CONDUCTOR_EXCLUDE="$(toml_normalize_array "$value")"
            CONDUCTOR_EXCLUDE_CONFIGURED=true
            ;;
        esac
        ;;
      "review.routing")
        case "$key" in
          enabled) ROUTING_ENABLED="$(normalize_bool "$value")" ;;
          small_max_diff_lines | small_diff_lines) ROUTING_SMALL_MAX_DIFF_LINES="$value" ;;
          small_with) ROUTING_SMALL_WITH="$(toml_unquote "$value")" ;;
          small_prefer) ROUTING_SMALL_PREFER="$(toml_unquote "$value")" ;;
          small_effort) ROUTING_SMALL_EFFORT="$(toml_unquote "$value")" ;;
          small_tags) ROUTING_SMALL_TAGS="$(toml_normalize_array "$value")" ;;
          large_with) ROUTING_LARGE_WITH="$(toml_unquote "$value")" ;;
          large_prefer) ROUTING_LARGE_PREFER="$(toml_unquote "$value")" ;;
          large_effort) ROUTING_LARGE_EFFORT="$(toml_unquote "$value")" ;;
          large_tags) ROUTING_LARGE_TAGS="$(toml_normalize_array "$value")" ;;
          high_risk_with) ROUTING_HIGH_RISK_WITH="$(toml_unquote "$value")" ;;
          high_risk_prefer) ROUTING_HIGH_RISK_PREFER="$(toml_unquote "$value")" ;;
          high_risk_effort) ROUTING_HIGH_RISK_EFFORT="$(toml_unquote "$value")" ;;
          high_risk_tags) ROUTING_HIGH_RISK_TAGS="$(toml_normalize_array "$value")" ;;
        esac
        ;;
      "review.context")
        case "$key" in
          full_context_paths | full_context_patterns) FULL_CONTEXT_PATHS="$(toml_normalize_array "$value" | tr ',' '\n')" ;;
        esac
        ;;
    esac
  }

  toml_parse "$CONFIG_FILE" toml_review_callback
fi

# TOUCHSTONE_REVIEWER is a v1.x-era env var that pinned the named *adapter*
# (codex / claude / gemini / local). In 2.0 the only adapter is conductor;
# the underlying provider pin is TOUCHSTONE_CONDUCTOR_WITH. Translate on the
# fly so --dry-run matches what the pre-push hook will actually do. Mirrors
# the translation block in hooks/codex-review.sh (keep in sync).
if [ -n "${TOUCHSTONE_REVIEWER:-}" ]; then
  case "$TOUCHSTONE_REVIEWER" in
    auto | conductor) ;;
    local)
      echo "==> NOTE: TOUCHSTONE_REVIEWER=local is deprecated in 2.0.0." >&2
      echo "    Migrating to explicit offline review: TOUCHSTONE_CONDUCTOR_WITH=ollama." >&2
      [ -z "${TOUCHSTONE_CONDUCTOR_WITH:-}" ] && export TOUCHSTONE_CONDUCTOR_WITH="ollama"
      ;;
    openrouter | codex | claude | gemini | ollama)
      echo "==> NOTE: TOUCHSTONE_REVIEWER=$TOUCHSTONE_REVIEWER is deprecated in 2.0.0." >&2
      echo "    Pin an underlying provider with: TOUCHSTONE_CONDUCTOR_WITH=$TOUCHSTONE_REVIEWER" >&2
      [ -z "${TOUCHSTONE_CONDUCTOR_WITH:-}" ] && export TOUCHSTONE_CONDUCTOR_WITH="$TOUCHSTONE_REVIEWER"
      ;;
    *)
      echo "==> WARNING: TOUCHSTONE_REVIEWER=$TOUCHSTONE_REVIEWER is not a known legacy value." >&2
      echo "    Ignoring. Pin an underlying provider with TOUCHSTONE_CONDUCTOR_WITH=<provider>." >&2
      ;;
  esac
fi

# Env overrides win.
CONDUCTOR_WITH="${TOUCHSTONE_CONDUCTOR_WITH:-${CONDUCTOR_WITH:-}}"
CONDUCTOR_PREFER="${TOUCHSTONE_CONDUCTOR_PREFER:-${CONDUCTOR_PREFER:-best}}"
CONDUCTOR_EFFORT="${TOUCHSTONE_CONDUCTOR_EFFORT:-${CONDUCTOR_EFFORT:-high}}"
CONDUCTOR_TAGS="${TOUCHSTONE_CONDUCTOR_TAGS:-${CONDUCTOR_TAGS:-code-review}}"
if [ -n "${TOUCHSTONE_CONDUCTOR_EXCLUDE+x}" ]; then
  CONDUCTOR_EXCLUDE="$TOUCHSTONE_CONDUCTOR_EXCLUDE"
elif [ "$CONDUCTOR_EXCLUDE_CONFIGURED" = true ]; then
  CONDUCTOR_EXCLUDE="${CONDUCTOR_EXCLUDE:-}"
else
  CONDUCTOR_EXCLUDE="ollama"
fi

# Resolve REVIEW_MODE: CLI flag > env > config > default.
REVIEW_MODE="${mode_override:-${CODEX_REVIEW_MODE:-${CONFIG_MODE:-fix}}}"

# Determine base ref. CLI flag > env > origin/<default-branch>.
default_branch() {
  git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's@^origin/@@' \
    || echo "main"
}
BASE="${base_override:-${CODEX_REVIEW_BASE:-origin/$(default_branch)}}"

# Try to compute diff line count for size-based routing. Best-effort:
# if the base ref doesn't exist locally we skip the small/large bucket.
DIFF_LINE_COUNT=0
diff_line_count_available=false
if git rev-parse --verify "$BASE" >/dev/null 2>&1; then
  DIFF_LINE_COUNT="$(git diff "$BASE"..HEAD 2>/dev/null | wc -l | tr -d ' ')"
  diff_line_count_available=true
fi
CHANGED_PATHS="$(git diff --name-only "$BASE"..HEAD 2>/dev/null || true)"

path_matches_pattern() {
  local path="$1"
  local pattern="$2"

  [ -n "$path" ] || return 1
  [ -n "$pattern" ] || return 1

  case "$pattern" in
    */)
      [[ "$path" == "$pattern"* ]] && return 0
      ;;
    *\** | *\?* | *\[*)
      # shellcheck disable=SC2053 # Configured patterns intentionally use globs.
      [[ "$path" == $pattern ]] && return 0
      ;;
    *)
      if [ "$path" = "$pattern" ] || [[ "$path" == "$pattern/"* ]]; then
        return 0
      fi
      ;;
  esac

  return 1
}

find_path_matching_patterns() {
  local paths="$1"
  local patterns="$2"
  local path pattern

  [ -n "$paths" ] || return 1
  [ -n "$patterns" ] || return 1

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    while IFS= read -r pattern; do
      [ -n "$pattern" ] || continue
      if path_matches_pattern "$path" "$pattern"; then
        printf '%s (matched %s)' "$path" "$pattern"
        return 0
      fi
    done <<<"$patterns"
  done <<<"$paths"

  return 1
}

find_high_risk_reason() {
  local match

  match="$(find_path_matching_patterns "$CHANGED_PATHS" "$UNSAFE_PATHS" || true)"
  if [ -n "$match" ]; then
    printf 'high-risk path %s' "$match"
    return 0
  fi

  match="$(find_path_matching_patterns "$CHANGED_PATHS" "$ARCHITECTURAL_PATHS" || true)"
  if [ -n "$match" ]; then
    printf 'architectural path %s' "$match"
    return 0
  fi

  match="$(find_path_matching_patterns "$CHANGED_PATHS" "$FULL_CONTEXT_PATHS" || true)"
  if [ -n "$match" ]; then
    printf 'configured full-context path %s' "$match"
    return 0
  fi

  return 1
}

routing_decision="default"
routing_reason="review.routing.enabled=false"
if [ "$ROUTING_ENABLED" = true ]; then
  routing_reason="diff line count unavailable for base $BASE"
  risk_reason="$(find_high_risk_reason || true)"
  case "$ROUTING_SMALL_MAX_DIFF_LINES" in
    '' | *[!0-9]*)
      routing_reason="invalid review.routing.small_max_diff_lines='$ROUTING_SMALL_MAX_DIFF_LINES'"
      ;;
    *)
      if [ "$diff_line_count_available" = true ] && [ -n "$risk_reason" ]; then
        routing_decision="high-risk"
        routing_reason="$risk_reason; $DIFF_LINE_COUNT diff lines"
        [ -n "$ROUTING_HIGH_RISK_WITH" ] && CONDUCTOR_WITH="${TOUCHSTONE_CONDUCTOR_WITH:-$ROUTING_HIGH_RISK_WITH}"
        [ -n "$ROUTING_HIGH_RISK_PREFER" ] && CONDUCTOR_PREFER="${TOUCHSTONE_CONDUCTOR_PREFER:-$ROUTING_HIGH_RISK_PREFER}"
        [ -n "$ROUTING_HIGH_RISK_EFFORT" ] && CONDUCTOR_EFFORT="${TOUCHSTONE_CONDUCTOR_EFFORT:-$ROUTING_HIGH_RISK_EFFORT}"
        [ -n "$ROUTING_HIGH_RISK_TAGS" ] && CONDUCTOR_TAGS="${TOUCHSTONE_CONDUCTOR_TAGS:-$ROUTING_HIGH_RISK_TAGS}"
      elif [ "$diff_line_count_available" = true ] && [ "$DIFF_LINE_COUNT" -le "$ROUTING_SMALL_MAX_DIFF_LINES" ] 2>/dev/null; then
        routing_decision="small"
        routing_reason="$DIFF_LINE_COUNT <= $ROUTING_SMALL_MAX_DIFF_LINES diff lines"
        [ -n "$ROUTING_SMALL_WITH" ] && CONDUCTOR_WITH="${TOUCHSTONE_CONDUCTOR_WITH:-$ROUTING_SMALL_WITH}"
        [ -n "$ROUTING_SMALL_PREFER" ] && CONDUCTOR_PREFER="${TOUCHSTONE_CONDUCTOR_PREFER:-$ROUTING_SMALL_PREFER}"
        [ -n "$ROUTING_SMALL_EFFORT" ] && CONDUCTOR_EFFORT="${TOUCHSTONE_CONDUCTOR_EFFORT:-$ROUTING_SMALL_EFFORT}"
        [ -n "$ROUTING_SMALL_TAGS" ] && CONDUCTOR_TAGS="${TOUCHSTONE_CONDUCTOR_TAGS:-$ROUTING_SMALL_TAGS}"
      elif [ "$diff_line_count_available" = true ]; then
        routing_decision="large-low-risk"
        routing_reason="$DIFF_LINE_COUNT > $ROUTING_SMALL_MAX_DIFF_LINES diff lines; no high-risk paths"
        [ -n "$ROUTING_LARGE_WITH" ] && CONDUCTOR_WITH="${TOUCHSTONE_CONDUCTOR_WITH:-$ROUTING_LARGE_WITH}"
        [ -n "$ROUTING_LARGE_PREFER" ] && CONDUCTOR_PREFER="${TOUCHSTONE_CONDUCTOR_PREFER:-$ROUTING_LARGE_PREFER}"
        [ -n "$ROUTING_LARGE_EFFORT" ] && CONDUCTOR_EFFORT="${TOUCHSTONE_CONDUCTOR_EFFORT:-$ROUTING_LARGE_EFFORT}"
        [ -n "$ROUTING_LARGE_TAGS" ] && CONDUCTOR_TAGS="${TOUCHSTONE_CONDUCTOR_TAGS:-$ROUTING_LARGE_TAGS}"
      fi
      ;;
  esac
fi

# Mode → dry-run shape (mirror the adapter in hooks/codex-review.sh).
tools=""
case "$REVIEW_MODE" in
  diff-only) tools="" ;;
  review-only) tools="" ;;
  no-tests) tools="Read,Grep,Glob,Edit,Write" ;;
  fix) tools="Read,Grep,Glob,Bash,Edit,Write" ;;
  *)
    echo "WARNING: unknown REVIEW_MODE='$REVIEW_MODE' — defaulting to review-only flags." >&2
    tools="Read,Grep,Glob,Bash"
    ;;
esac

# Build the conductor route command line.
args=()
if [ -n "$CONDUCTOR_WITH" ]; then
  # `conductor route` doesn't take --with (it's a router preview); the
  # equivalent is "exclude everyone but X". Show that as the dry-run
  # equivalent to a pinned provider.
  echo "==> Provider pinned via --with=$CONDUCTOR_WITH (skipping route preview;"
  echo "    pinned providers bypass auto-routing). Showing capability check instead."
  echo ""
  echo "    Effective config:"
  echo "      with     = $CONDUCTOR_WITH"
  echo "      effort   = $CONDUCTOR_EFFORT"
  echo "      prefer   = $CONDUCTOR_PREFER"
  echo "      mode     = $REVIEW_MODE → tools=${tools:-<none>}"
  echo "      base     = $BASE  ($DIFF_LINE_COUNT diff lines)"
  echo "      routing  = $routing_decision ($routing_reason)"
  echo ""
  echo "    To preview which provider auto-routing would pick, unset"
  echo "    TOUCHSTONE_CONDUCTOR_WITH and remove [review.conductor].with"
  echo "    from .codex-review.toml, then re-run."
  exit 0
fi

[ -n "$CONDUCTOR_PREFER" ] && args+=(--prefer "$CONDUCTOR_PREFER")
[ -n "$CONDUCTOR_EFFORT" ] && args+=(--effort "$CONDUCTOR_EFFORT")
[ -n "$CONDUCTOR_TAGS" ] && args+=(--tags "$CONDUCTOR_TAGS")
[ -n "$CONDUCTOR_EXCLUDE" ] && args+=(--exclude "$CONDUCTOR_EXCLUDE")
[ -n "$tools" ] && args+=(--tools "$tools")
[ -n "$json_flag" ] && args+=("$json_flag")

if [ -z "$json_flag" ]; then
  echo "==> touchstone review --dry-run"
  echo "    base ref:    $BASE"
  echo "    diff lines:  $DIFF_LINE_COUNT"
  echo "    review mode: $REVIEW_MODE → tools=${tools:-<none>}"
  if [ "$REVIEW_MODE" != "diff-only" ] && [ -z "$CONDUCTOR_WITH" ]; then
    echo "    review cmd:  conductor review --base $BASE --brief-file -"
  fi
  if [ "$REVIEW_MODE" = "fix" ] || [ "$REVIEW_MODE" = "no-tests" ]; then
    echo "    fix tools:   ${tools:-<none>}"
  fi
  echo "    routing:     $routing_decision ($routing_reason)"
  echo ""
fi

# Hand off to conductor for the actual routing decision + cost estimate.
exec conductor route ${args[@]+"${args[@]}"}
