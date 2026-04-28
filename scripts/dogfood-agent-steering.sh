#!/usr/bin/env bash
#
# Dogfood Touchstone's agent steering docs by asking Conductor-routed models to
# derive the delivery workflow from a freshly bootstrapped temporary project.
#
# This is intentionally not named tests/test-*.sh: it can spend real provider
# quota and should be run deliberately.

set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PROVIDERS="${TOUCHSTONE_DOGFOOD_PROVIDERS:-auto}"
PERSONAS="${TOUCHSTONE_DOGFOOD_PERSONAS:-codex,claude,gemini}"
PREFER="${TOUCHSTONE_DOGFOOD_PREFER:-best}"
EFFORT="${TOUCHSTONE_DOGFOOD_EFFORT:-medium}"
TAGS="${TOUCHSTONE_DOGFOOD_TAGS:-code-review,documentation}"
TIMEOUT="${TOUCHSTONE_DOGFOOD_TIMEOUT:-300}"
KEEP=false
VALIDATE_RESPONSE_FILE=""

require_pattern() {
  local file="$1" pattern="$2" label="$3"
  if ! grep -Eiq "$pattern" "$file"; then
    echo "    FAIL: missing $label" >&2
    return 1
  fi
  return 0
}

validate_response() {
  local file="$1" failures=0

  require_pattern "$file" 'TOUCHSTONE_DOGFOOD_RESULT:[[:space:]]*PASS' "PASS result" || failures=$((failures + 1))
  require_pattern "$file" 'BRANCH_BEFORE_EDIT:[[:space:]]*yes' "branch-before-edit yes" || failures=$((failures + 1))
  require_pattern "$file" 'FEATURE_BRANCH_COMMAND:.*git[[:space:]]+(checkout[[:space:]]+-b|switch[[:space:]]+-c)' "feature branch command" || failures=$((failures + 1))
  require_pattern "$file" 'PR_CREATED:[[:space:]]*yes' "PR_CREATED yes" || failures=$((failures + 1))
  require_pattern "$file" 'CONDUCTOR_REVIEW_BEFORE_MERGE:[[:space:]]*yes' "Conductor review before merge" || failures=$((failures + 1))
  require_pattern "$file" 'AUTO_MERGE_COMMAND:.*scripts/open-pr\.sh[[:space:]]+--auto-merge' "open-pr auto-merge command" || failures=$((failures + 1))
  require_pattern "$file" 'PRINCIPLES_APPLIED:[[:space:]]*yes' "principles applied" || failures=$((failures + 1))
  require_pattern "$file" 'NO_SILENT_FAILURES_TESTED:[[:space:]]*yes' "no silent failures tested" || failures=$((failures + 1))
  require_pattern "$file" 'DIRECT_MAIN_PUSH_ALLOWED:[[:space:]]*no' "direct main push disallowed" || failures=$((failures + 1))
  require_pattern "$file" 'DRIVING_CLI_OWNS_REPO_WORKFLOW:[[:space:]]*yes' "driving CLI owns repo workflow" || failures=$((failures + 1))
  require_pattern "$file" 'CONDUCTOR_IS_WORKER_OR_REVIEWER:[[:space:]]*yes' "Conductor worker/reviewer role" || failures=$((failures + 1))
  require_pattern "$file" 'DRIVER_FALLBACK_SHARED_CONTRACT:[[:space:]]*yes' "driver fallback shared contract" || failures=$((failures + 1))
  require_pattern "$file" 'CONDUCTOR_PROVIDER_FALLBACK:[[:space:]]*yes' "Conductor provider fallback" || failures=$((failures + 1))

  [ "$failures" -eq 0 ]
}

usage() {
  cat <<'EOF'
Usage: scripts/dogfood-agent-steering.sh [options]

Options:
  --providers LIST  Comma-separated Conductor providers, or "auto" (default: auto)
                    Example: --providers auto,claude,codex,gemini
  --personas LIST   Comma-separated agent personas to test (default: codex,claude,gemini)
  --prefer MODE     Conductor routing preference for --auto (default: best)
  --effort LEVEL    Conductor effort level (default: medium)
  --tags LIST       Conductor routing tags (default: code-review,documentation)
  --timeout SEC     Per-run timeout in seconds (default: 300)
  --keep            Keep the temporary project and transcripts even on success
  --validate-response FILE
                    Validate a saved dogfood response without invoking Conductor
  -h, --help        Show this help

Environment variables mirror the options:
  TOUCHSTONE_DOGFOOD_PROVIDERS
  TOUCHSTONE_DOGFOOD_PERSONAS
  TOUCHSTONE_DOGFOOD_PREFER
  TOUCHSTONE_DOGFOOD_EFFORT
  TOUCHSTONE_DOGFOOD_TAGS
  TOUCHSTONE_DOGFOOD_TIMEOUT
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --providers)
      [ "$#" -ge 2 ] || { echo "ERROR: --providers requires a value" >&2; exit 1; }
      PROVIDERS="$2"
      shift 2
      ;;
    --personas)
      [ "$#" -ge 2 ] || { echo "ERROR: --personas requires a value" >&2; exit 1; }
      PERSONAS="$2"
      shift 2
      ;;
    --prefer)
      [ "$#" -ge 2 ] || { echo "ERROR: --prefer requires a value" >&2; exit 1; }
      PREFER="$2"
      shift 2
      ;;
    --effort)
      [ "$#" -ge 2 ] || { echo "ERROR: --effort requires a value" >&2; exit 1; }
      EFFORT="$2"
      shift 2
      ;;
    --tags)
      [ "$#" -ge 2 ] || { echo "ERROR: --tags requires a value" >&2; exit 1; }
      TAGS="$2"
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || { echo "ERROR: --timeout requires a value" >&2; exit 1; }
      TIMEOUT="$2"
      shift 2
      ;;
    --keep)
      KEEP=true
      shift
      ;;
    --validate-response)
      [ "$#" -ge 2 ] || { echo "ERROR: --validate-response requires a file" >&2; exit 1; }
      VALIDATE_RESPONSE_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -n "$VALIDATE_RESPONSE_FILE" ]; then
  validate_response "$VALIDATE_RESPONSE_FILE"
  exit $?
fi

if ! command -v conductor >/dev/null 2>&1; then
  echo "ERROR: conductor is required for agent steering dogfood." >&2
  echo "       Install/configure it, then rerun this script." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d -t touchstone-agent-steering.XXXXXX)"
PROJECT_DIR="$WORK_DIR/project"
TRANSCRIPTS_DIR="$WORK_DIR/transcripts"
mkdir -p "$TRANSCRIPTS_DIR"

cleanup() {
  local rc=$?
  if [ "$KEEP" = true ] || [ "$rc" -ne 0 ]; then
    echo "==> Dogfood artifacts kept at: $WORK_DIR" >&2
  else
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

echo "==> Bootstrapping temporary Touchstone project"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT_DIR" \
  --yes \
  --no-register \
  --type generic \
  --skip-language-scaffold \
  --reviewer conductor \
  --review-routing all-hosted \
  --ci none \
  --no-gitbutler \
  --no-gitbutler-mcp \
  --no-with-cortex \
  --no-with-sentinel \
  --no-github \
  --no-initial-commit >/dev/null

mkdir -p "$PROJECT_DIR/src"
cat > "$PROJECT_DIR/src/example.py" <<'EOF'
def load_value(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read()
    except Exception:
        return ""
EOF

persona_prompt() {
  local persona="$1"
  case "$persona" in
    codex)
      cat <<'EOF'
You are Codex running in an AGENTS.md-native project. Start from AGENTS.md and follow it as your steering file.
EOF
      ;;
    claude)
      cat <<'EOF'
You are Claude Code running in this project. Start from CLAUDE.md. Resolve any @principles imports by reading the referenced files.
EOF
      ;;
    gemini)
      cat <<'EOF'
You are Gemini CLI running in this project. Start from GEMINI.md, then follow the files it delegates to.
EOF
      ;;
    *)
      cat <<EOF
You are an AI coding agent named "$persona". Use the project steering file that applies to that agent if one exists; otherwise start from AGENTS.md.
EOF
      ;;
  esac
}

write_brief() {
  local persona="$1" brief_file="$2"
  {
    persona_prompt "$persona"
    cat <<'EOF'

This is a read-only dogfood check. Do not edit files, run git mutations, create branches, or create PRs.

Inspect the steering docs in this temporary project and answer this scenario:

  The user asks you to fix the swallowed exception in src/example.py and ship the change.

Report the workflow you would follow and the engineering principles that constrain the fix.
Your answer must include this machine-check block exactly once, with yes/no values:

TOUCHSTONE_DOGFOOD_RESULT: PASS|FAIL
BRANCH_BEFORE_EDIT: yes|no
FEATURE_BRANCH_COMMAND: <the git command you would use>
PR_CREATED: yes|no
CONDUCTOR_REVIEW_BEFORE_MERGE: yes|no
AUTO_MERGE_COMMAND: <the command you would use>
PRINCIPLES_APPLIED: yes|no
NO_SILENT_FAILURES_TESTED: yes|no
DIRECT_MAIN_PUSH_ALLOWED: yes|no
DRIVING_CLI_OWNS_REPO_WORKFLOW: yes|no
CONDUCTOR_IS_WORKER_OR_REVIEWER: yes|no
DRIVER_FALLBACK_SHARED_CONTRACT: yes|no
CONDUCTOR_PROVIDER_FALLBACK: yes|no

Mark PASS only if the docs tell you to branch before editing, apply the shared
engineering principles, create a PR, run Conductor-backed review, and ship via
the auto-merge flow instead of pushing directly to main. Also mark PASS only if
you distinguish the driving CLI from Conductor: Claude/Codex/Gemini own the repo
workflow as interchangeable drivers with a shared contract, while Conductor is a
worker/reviewer router whose provider fallback happens inside Conductor.

After the machine-check block, add at most five concise bullets explaining the
evidence you found in the docs.
EOF
  } > "$brief_file"
}

run_conductor() {
  local provider="$1" brief_file="$2" out_file="$3" err_file="$4"
  if [ "$provider" = "auto" ]; then
    conductor exec \
      --auto \
      --tags "$TAGS" \
      --prefer "$PREFER" \
      --effort "$EFFORT" \
      --tools Read,Grep,Glob \
      --sandbox read-only \
      --cwd "$PROJECT_DIR" \
      --timeout "$TIMEOUT" \
      --brief-file "$brief_file" \
      >"$out_file" 2>"$err_file"
  else
    conductor exec \
      --with "$provider" \
      --effort "$EFFORT" \
      --tools Read,Grep,Glob \
      --sandbox read-only \
      --cwd "$PROJECT_DIR" \
      --timeout "$TIMEOUT" \
      --brief-file "$brief_file" \
      >"$out_file" 2>"$err_file"
  fi
}

IFS=',' read -r -a provider_list <<< "$PROVIDERS"
IFS=',' read -r -a persona_list <<< "$PERSONAS"

total=0
failed=0

for persona in "${persona_list[@]}"; do
  persona="$(printf '%s' "$persona" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$persona" ] || continue
  for provider in "${provider_list[@]}"; do
    provider="$(printf '%s' "$provider" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$provider" ] || continue
    total=$((total + 1))

    safe_name="$(printf '%s-%s' "$persona" "$provider" | tr -c 'A-Za-z0-9._-' '_')"
    brief_file="$TRANSCRIPTS_DIR/$safe_name.brief.txt"
    out_file="$TRANSCRIPTS_DIR/$safe_name.out.txt"
    err_file="$TRANSCRIPTS_DIR/$safe_name.err.txt"
    write_brief "$persona" "$brief_file"

    echo "==> Dogfood: persona=$persona provider=$provider"
    if ! run_conductor "$provider" "$brief_file" "$out_file" "$err_file"; then
      echo "    FAIL: conductor exec failed (stderr: $err_file)" >&2
      failed=$((failed + 1))
      continue
    fi

    if validate_response "$out_file"; then
      echo "    PASS"
    else
      echo "    FAIL: response did not prove the required steering contract ($out_file)" >&2
      failed=$((failed + 1))
    fi
  done
done

echo ""
echo "==> Dogfood summary: $((total - failed))/$total passed"
echo "    Transcripts: $TRANSCRIPTS_DIR"

if [ "$failed" -gt 0 ]; then
  exit 1
fi
