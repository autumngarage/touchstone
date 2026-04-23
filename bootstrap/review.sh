#!/usr/bin/env bash
#
# bootstrap/review.sh — preview or run a review of the current diff
# without (or before) pushing.
#
# Today the only supported subcommand is `--dry-run`: resolves the
# project's conductor configuration the same way the pre-push hook
# does, then invokes `conductor route --dry-run` so the user sees
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
    --dry-run) dry_run=true; shift ;;
    --mode)
      [ "$#" -ge 2 ] || { echo "ERROR: --mode requires a value" >&2; exit 1; }
      mode_override="$2"; shift 2 ;;
    --base)
      [ "$#" -ge 2 ] || { echo "ERROR: --base requires a ref" >&2; exit 1; }
      base_override="$2"; shift 2 ;;
    --json) json_flag="--json"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
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
[ -n "$REPO_ROOT" ] || { echo "ERROR: not inside a git repository." >&2; exit 1; }

CONFIG_FILE="$REPO_ROOT/.codex-review.toml"

# Defaults (mirror the runtime cascade in hooks/codex-review.sh).
CONDUCTOR_WITH=""
CONDUCTOR_PREFER=""
CONDUCTOR_EFFORT=""
CONDUCTOR_TAGS=""
CONDUCTOR_EXCLUDE=""
ROUTING_ENABLED=false
ROUTING_SMALL_MAX_DIFF_LINES=400
ROUTING_SMALL_WITH=""
ROUTING_SMALL_PREFER=""
ROUTING_SMALL_EFFORT=""
ROUTING_SMALL_TAGS=""
ROUTING_LARGE_WITH=""
ROUTING_LARGE_PREFER=""
ROUTING_LARGE_EFFORT=""
ROUTING_LARGE_TAGS=""
CONFIG_MODE=""

strip_quotes() {
  local v="$1"
  v="${v# }"; v="${v% }"
  case "$v" in
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s' "$v"
}

# Lightweight section-aware config parser. Just enough to read the
# fields touchstone review --dry-run cares about. (The hook has a
# fuller parser; duplicating here keeps the dry-run script standalone.)
if [ -f "$CONFIG_FILE" ]; then
  section=""
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%%#*}"
    line="${line# }"; line="${line% }"
    [ -z "$line" ] && continue
    case "$line" in
      \[*\])
        section="${line#[}"
        section="${section%]}"
        section="${section# }"; section="${section% }"
        continue
        ;;
    esac
    key="${line%%=*}"; val="${line#*=}"
    key="${key# }"; key="${key% }"
    val="$(strip_quotes "$val")"
    case "$section" in
      codex_review)
        case "$key" in
          mode) CONFIG_MODE="$val" ;;
        esac
        ;;
      review.conductor)
        case "$key" in
          prefer)  CONDUCTOR_PREFER="$val" ;;
          effort)  CONDUCTOR_EFFORT="$val" ;;
          tags)    CONDUCTOR_TAGS="$val" ;;
          with)    CONDUCTOR_WITH="$val" ;;
          exclude) CONDUCTOR_EXCLUDE="$val" ;;
        esac
        ;;
      review.routing)
        case "$key" in
          enabled)              [ "$val" = "true" ] && ROUTING_ENABLED=true ;;
          small_max_diff_lines) ROUTING_SMALL_MAX_DIFF_LINES="$val" ;;
          small_with)    ROUTING_SMALL_WITH="$val" ;;
          small_prefer)  ROUTING_SMALL_PREFER="$val" ;;
          small_effort)  ROUTING_SMALL_EFFORT="$val" ;;
          small_tags)    ROUTING_SMALL_TAGS="$val" ;;
          large_with)    ROUTING_LARGE_WITH="$val" ;;
          large_prefer)  ROUTING_LARGE_PREFER="$val" ;;
          large_effort)  ROUTING_LARGE_EFFORT="$val" ;;
          large_tags)    ROUTING_LARGE_TAGS="$val" ;;
        esac
        ;;
    esac
  done < "$CONFIG_FILE"
fi

# Env overrides win.
CONDUCTOR_WITH="${TOUCHSTONE_CONDUCTOR_WITH:-${CONDUCTOR_WITH:-}}"
CONDUCTOR_PREFER="${TOUCHSTONE_CONDUCTOR_PREFER:-${CONDUCTOR_PREFER:-best}}"
CONDUCTOR_EFFORT="${TOUCHSTONE_CONDUCTOR_EFFORT:-${CONDUCTOR_EFFORT:-max}}"
CONDUCTOR_TAGS="${TOUCHSTONE_CONDUCTOR_TAGS:-${CONDUCTOR_TAGS:-code-review}}"
CONDUCTOR_EXCLUDE="${TOUCHSTONE_CONDUCTOR_EXCLUDE:-${CONDUCTOR_EXCLUDE:-}}"

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
if git rev-parse --verify "$BASE" >/dev/null 2>&1; then
  DIFF_LINE_COUNT="$(git diff "$BASE"..HEAD 2>/dev/null | wc -l | tr -d ' ')"
fi

routing_decision="default"
if [ "$ROUTING_ENABLED" = true ] && [ "$DIFF_LINE_COUNT" -gt 0 ]; then
  if [ "$DIFF_LINE_COUNT" -le "$ROUTING_SMALL_MAX_DIFF_LINES" ] 2>/dev/null; then
    routing_decision="small"
    [ -n "$ROUTING_SMALL_WITH" ]   && CONDUCTOR_WITH="${TOUCHSTONE_CONDUCTOR_WITH:-$ROUTING_SMALL_WITH}"
    [ -n "$ROUTING_SMALL_PREFER" ] && CONDUCTOR_PREFER="${TOUCHSTONE_CONDUCTOR_PREFER:-$ROUTING_SMALL_PREFER}"
    [ -n "$ROUTING_SMALL_EFFORT" ] && CONDUCTOR_EFFORT="${TOUCHSTONE_CONDUCTOR_EFFORT:-$ROUTING_SMALL_EFFORT}"
    [ -n "$ROUTING_SMALL_TAGS" ]   && CONDUCTOR_TAGS="${TOUCHSTONE_CONDUCTOR_TAGS:-$ROUTING_SMALL_TAGS}"
  else
    routing_decision="large"
    [ -n "$ROUTING_LARGE_WITH" ]   && CONDUCTOR_WITH="${TOUCHSTONE_CONDUCTOR_WITH:-$ROUTING_LARGE_WITH}"
    [ -n "$ROUTING_LARGE_PREFER" ] && CONDUCTOR_PREFER="${TOUCHSTONE_CONDUCTOR_PREFER:-$ROUTING_LARGE_PREFER}"
    [ -n "$ROUTING_LARGE_EFFORT" ] && CONDUCTOR_EFFORT="${TOUCHSTONE_CONDUCTOR_EFFORT:-$ROUTING_LARGE_EFFORT}"
    [ -n "$ROUTING_LARGE_TAGS" ]   && CONDUCTOR_TAGS="${TOUCHSTONE_CONDUCTOR_TAGS:-$ROUTING_LARGE_TAGS}"
  fi
fi

# Mode → tools / sandbox (mirror the adapter in hooks/codex-review.sh).
tools=""
sandbox=""
case "$REVIEW_MODE" in
  diff-only)   tools=""                              ; sandbox="" ;;
  review-only) tools="Read,Grep,Glob,Bash"           ; sandbox="read-only" ;;
  no-tests)    tools="Read,Grep,Glob,Edit,Write"     ; sandbox="workspace-write" ;;
  fix)         tools="Read,Grep,Glob,Bash,Edit,Write"; sandbox="workspace-write" ;;
  *)
    echo "WARNING: unknown REVIEW_MODE='$REVIEW_MODE' — defaulting to review-only flags." >&2
    tools="Read,Grep,Glob,Bash"; sandbox="read-only"
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
  echo "      mode     = $REVIEW_MODE → tools=${tools:-<none>}, sandbox=${sandbox:-<none>}"
  echo "      base     = $BASE  ($DIFF_LINE_COUNT diff lines)"
  echo "      routing  = $routing_decision"
  echo ""
  echo "    To preview which provider auto-routing would pick, unset"
  echo "    TOUCHSTONE_CONDUCTOR_WITH and remove [review.conductor].with"
  echo "    from .codex-review.toml, then re-run."
  exit 0
fi

[ -n "$CONDUCTOR_PREFER" ]  && args+=(--prefer  "$CONDUCTOR_PREFER")
[ -n "$CONDUCTOR_EFFORT" ]  && args+=(--effort  "$CONDUCTOR_EFFORT")
[ -n "$CONDUCTOR_TAGS" ]    && args+=(--tags    "$CONDUCTOR_TAGS")
[ -n "$CONDUCTOR_EXCLUDE" ] && args+=(--exclude "$CONDUCTOR_EXCLUDE")
[ -n "$tools" ]             && args+=(--tools   "$tools")
[ -n "$sandbox" ]           && args+=(--sandbox "$sandbox")
[ -n "$json_flag" ]         && args+=("$json_flag")

if [ -z "$json_flag" ]; then
  echo "==> touchstone review --dry-run"
  echo "    base ref:    $BASE"
  echo "    diff lines:  $DIFF_LINE_COUNT"
  echo "    review mode: $REVIEW_MODE → tools=${tools:-<none>} sandbox=${sandbox:-<none>}"
  echo "    routing:     $routing_decision (small/large bucket detection)"
  echo ""
fi

# Hand off to conductor for the actual routing decision + cost estimate.
exec conductor route "${args[@]}"
