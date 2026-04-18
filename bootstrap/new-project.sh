#!/usr/bin/env bash
#
# bootstrap/new-project.sh — spin up a new project with touchstone files.
#
# Usage:
#   new-project.sh <project-dir>
#   new-project.sh <project-dir> --no-register   # skip adding to ~/.touchstone-projects
#   new-project.sh <project-dir> --type node|python|swift|rust|go|generic|auto
#   new-project.sh <project-dir> --unsafe-paths src/auth/,migrations/
#   new-project.sh <project-dir> --reviewer codex|claude|gemini|local|auto|none
#   new-project.sh <project-dir> --review-routing all-hosted|all-local|small-local
#   new-project.sh <project-dir> --gitbutler
#
# What this does:
#   1. Creates the directory if it doesn't exist, initializes git
#   2. Copies templates, principles, hooks, and scripts into the project
#   3. Makes scripts executable
#   4. Writes .touchstone-version and .touchstone-manifest
#   5. Registers the project in ~/.touchstone-projects (for sync-all.sh)
#   6. Prints next steps
#
# After running, fill in the {{PLACEHOLDERS}} in CLAUDE.md and AGENTS.md.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/install-hooks.sh
source "$TOUCHSTONE_ROOT/lib/install-hooks.sh"
REGISTER=true
INPUT_UNSAFE=""
INPUT_TYPE=""
INPUT_REVIEWER=""
INPUT_REVIEW_ASSIST=""
INPUT_REVIEW_AUTOFIX=""
INPUT_LOCAL_REVIEW_COMMAND=""
INPUT_REVIEW_ROUTING=""
INPUT_SMALL_REVIEW_LINES=""
INPUT_GIT_WORKFLOW=""
INPUT_GITBUTLER_MCP=""
INPUT_CI=""
REVIEW_CONFIG_REQUESTED=false
WORKFLOW_CONFIG_REQUESTED=false

usage() {
  echo "Usage: $0 <project-dir> [--no-register] [--type node|python|swift|rust|go|generic|auto] [--unsafe-paths path1,path2] [--reviewer codex|claude|gemini|local|auto|none] [--review-routing all-hosted|all-local|small-local] [--small-review-lines N] [--review-assist|--no-review-assist] [--review-autofix|--no-review-autofix] [--local-review-command <command>] [--gitbutler|--no-gitbutler] [--gitbutler-mcp|--no-gitbutler-mcp] [--ci github|none]"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[\\/&]/\\&/g'
}

escape_toml_basic_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_unsafe_paths_block() {
  local file="$1"
  shift

  local block_file tmp_file
  block_file="$(mktemp -t touchstone-codex-review-block.XXXXXX)"
  tmp_file="$(mktemp -t touchstone-codex-review.XXXXXX)"

  {
    printf 'unsafe_paths = [\n'
    for path in "$@"; do
      [ -z "$path" ] && continue
      printf '  "%s",\n' "$(escape_toml_basic_string "$path")"
    done
    printf ']\n'
  } > "$block_file"

  if awk -v block_file="$block_file" '
    BEGIN { replaced = 0; in_block = 0 }
    /^[[:space:]]*unsafe_paths[[:space:]]*=/ && !replaced {
      while ((getline line < block_file) > 0) {
        print line
      }
      close(block_file)
      replaced = 1
      in_block = ($0 !~ /\]/)
      next
    }
    in_block {
      if ($0 ~ /^[[:space:]]*\]/) {
        in_block = 0
      }
      next
    }
    { print }
    END {
      if (!replaced) {
        exit 1
      }
    }
  ' "$file" > "$tmp_file"; then
    mv "$tmp_file" "$file"
  else
    rm -f "$block_file" "$tmp_file"
    return 1
  fi

  rm -f "$block_file"
}

next_backup_path() {
  local dst="$1"
  local backup="$dst.bak"
  local i=1

  while [ -e "$backup" ]; do
    backup="$dst.bak.$i"
    i=$((i + 1))
  done

  printf '%s' "$backup"
}

normalize_project_type() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    ""|auto) printf 'auto' ;;
    node|js|javascript|ts|typescript) printf 'node' ;;
    python|py) printf 'python' ;;
    swift) printf 'swift' ;;
    rust|rs) printf 'rust' ;;
    go|golang) printf 'go' ;;
    generic) printf 'generic' ;;
    *)
      echo "ERROR: unknown project type '$1' (expected node, python, swift, rust, go, generic, or auto)" >&2
      return 1
      ;;
  esac
}

normalize_reviewer() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    ""|auto) printf 'auto' ;;
    codex|claude|gemini|local) printf '%s' "$value" ;;
    none|no|off|disabled|false) printf 'none' ;;
    *)
      echo "ERROR: unknown reviewer '$1' (expected codex, claude, gemini, local, auto, or none)" >&2
      return 1
      ;;
  esac
}

normalize_review_routing() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    ""|hosted|all|all-hosted|cloud|remote) printf 'all-hosted' ;;
    local|all-local) printf 'all-local' ;;
    hybrid|small-local|local-small|small-local-large-hosted) printf 'small-local' ;;
    none|off|disabled|false) printf 'none' ;;
    *)
      echo "ERROR: unknown review routing '$1' (expected all-hosted, all-local, or small-local)" >&2
      return 1
      ;;
  esac
}

normalize_git_workflow() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    ""|git|plain|standard|classic) printf 'git' ;;
    gitbutler|butler|but) printf 'gitbutler' ;;
    *)
      echo "ERROR: unknown git workflow '$1' (expected git or gitbutler)" >&2
      return 1
      ;;
  esac
}

normalize_positive_int() {
  local value="$1"
  case "$value" in
    ''|*[!0-9]*)
      echo "ERROR: expected a positive integer, got '$1'" >&2
      return 1
      ;;
    *)
      if [ "$value" -le 0 ] 2>/dev/null; then
        echo "ERROR: expected a positive integer, got '$1'" >&2
        return 1
      fi
      printf '%s' "$value"
      ;;
  esac
}

normalize_yes_no() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    y|yes|true|1|on) printf 'true' ;;
    n|no|false|0|off) printf 'false' ;;
    *) printf '%s' "$value" ;;
  esac
}

prompt_yes_no() {
  local prompt="$1"
  local default="$2"
  local suffix answer

  if [ "$default" = "true" ]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi

  read -r -p "   $prompt $suffix: " answer
  answer="$(trim "$answer")"
  if [ -z "$answer" ]; then
    printf '%s' "$default"
  else
    normalize_yes_no "$answer"
  fi
}

default_reviewer() {
  if command -v codex >/dev/null 2>&1; then
    printf 'codex'
  elif command -v claude >/dev/null 2>&1; then
    printf 'claude'
  elif command -v gemini >/dev/null 2>&1; then
    printf 'gemini'
  else
    printf 'codex'
  fi
}

detect_node_package_manager() {
  local dir="$1" package_manager

  if [ -f "$dir/package.json" ]; then
    package_manager="$(sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"\([^@"]*\)@.*/\1/p' "$dir/package.json" | head -1)"
    if [ -z "$package_manager" ]; then
      package_manager="$(sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$dir/package.json" | head -1)"
    fi
    if [ -n "$package_manager" ]; then
      printf '%s\n' "$package_manager"
      return 0
    fi
  fi

  if [ -f "$dir/pnpm-lock.yaml" ] || [ -f "$dir/pnpm-workspace.yaml" ]; then
    printf 'pnpm\n'
  elif [ -f "$dir/yarn.lock" ]; then
    printf 'yarn\n'
  elif [ -f "$dir/bun.lock" ] || [ -f "$dir/bun.lockb" ]; then
    printf 'bun\n'
  elif [ -f "$dir/package.json" ]; then
    printf 'npm\n'
  else
    printf '\n'
  fi
}

detect_project_type() {
  local dir="$1"

  if [ -f "$dir/pnpm-workspace.yaml" ]; then
    printf 'node\n'
  elif [ -f "$dir/package.json" ] || [ -f "$dir/tsconfig.json" ]; then
    printf 'node\n'
  elif [ -f "$dir/Cargo.toml" ]; then
    printf 'rust\n'
  elif [ -f "$dir/Package.swift" ]; then
    printf 'swift\n'
  elif [ -f "$dir/go.mod" ]; then
    printf 'go\n'
  elif [ -f "$dir/uv.lock" ] || [ -f "$dir/pyproject.toml" ] || [ -f "$dir/requirements.txt" ]; then
    printf 'python\n'
  else
    printf 'generic\n'
  fi
}

detect_monorepo() {
  local dir="$1"

  if [ -f "$dir/pnpm-workspace.yaml" ]; then
    printf 'true\n'
  elif [ -f "$dir/Cargo.toml" ] && grep -q '^\[workspace\]' "$dir/Cargo.toml" 2>/dev/null; then
    printf 'true\n'
  elif [ -f "$dir/package.json" ] && grep -q '"workspaces"' "$dir/package.json" 2>/dev/null; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

detect_targets() {
  local root="$1" base target_dir profile targets=""

  for base in apps packages services; do
    [ -d "$root/$base" ] || continue
    for target_dir in "$root/$base"/*; do
      [ -d "$target_dir" ] || continue
      profile="$(detect_project_type "$target_dir")"
      [ "$profile" = "generic" ] && continue
      if [ -n "$targets" ]; then
        targets="${targets},"
      fi
      targets="${targets}$(basename "$target_dir"):$base/$(basename "$target_dir"):$profile"
    done
  done

  printf '%s\n' "$targets"
}

if [ "$#" -lt 1 ]; then
  usage >&2
  exit 1
fi

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
  -*)
    echo "ERROR: missing project-dir before option '$1'" >&2
    usage >&2
    exit 1
    ;;
esac

PROJECT_DIR="$1"
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --no-register) REGISTER=false; shift ;;
    --type)
      [ "$#" -ge 2 ] || { echo "ERROR: --type requires a value (node, python, swift, rust, go, generic, auto)" >&2; exit 1; }
      INPUT_TYPE="$(normalize_project_type "$2")"
      shift 2
      ;;
    --unsafe-paths)
      [ "$#" -ge 2 ] || { echo "ERROR: --unsafe-paths requires a comma-separated value" >&2; exit 1; }
      INPUT_UNSAFE="$2"
      shift 2
      ;;
    --reviewer)
      [ "$#" -ge 2 ] || { echo "ERROR: --reviewer requires a value (codex, claude, gemini, local, auto, none)" >&2; exit 1; }
      INPUT_REVIEWER="$(normalize_reviewer "$2")"
      REVIEW_CONFIG_REQUESTED=true
      shift 2
      ;;
    --review-routing)
      [ "$#" -ge 2 ] || { echo "ERROR: --review-routing requires a value (all-hosted, all-local, small-local)" >&2; exit 1; }
      INPUT_REVIEW_ROUTING="$(normalize_review_routing "$2")"
      REVIEW_CONFIG_REQUESTED=true
      shift 2
      ;;
    --small-review-lines)
      [ "$#" -ge 2 ] || { echo "ERROR: --small-review-lines requires a positive integer" >&2; exit 1; }
      INPUT_SMALL_REVIEW_LINES="$(normalize_positive_int "$2")"
      REVIEW_CONFIG_REQUESTED=true
      shift 2
      ;;
    --no-ai-review|--no-review)
      INPUT_REVIEWER="none"
      INPUT_REVIEW_ROUTING="none"
      REVIEW_CONFIG_REQUESTED=true
      shift
      ;;
    --review-assist)
      INPUT_REVIEW_ASSIST=true
      REVIEW_CONFIG_REQUESTED=true
      shift
      ;;
    --no-review-assist)
      INPUT_REVIEW_ASSIST=false
      REVIEW_CONFIG_REQUESTED=true
      shift
      ;;
    --review-autofix)
      INPUT_REVIEW_AUTOFIX=true
      REVIEW_CONFIG_REQUESTED=true
      shift
      ;;
    --no-review-autofix)
      INPUT_REVIEW_AUTOFIX=false
      REVIEW_CONFIG_REQUESTED=true
      shift
      ;;
    --local-review-command)
      [ "$#" -ge 2 ] || { echo "ERROR: --local-review-command requires a command string" >&2; exit 1; }
      INPUT_LOCAL_REVIEW_COMMAND="$2"
      REVIEW_CONFIG_REQUESTED=true
      shift 2
      ;;
    --git-workflow)
      [ "$#" -ge 2 ] || { echo "ERROR: --git-workflow requires a value (git or gitbutler)" >&2; exit 1; }
      INPUT_GIT_WORKFLOW="$(normalize_git_workflow "$2")"
      WORKFLOW_CONFIG_REQUESTED=true
      shift 2
      ;;
    --gitbutler)
      INPUT_GIT_WORKFLOW="gitbutler"
      WORKFLOW_CONFIG_REQUESTED=true
      shift
      ;;
    --no-gitbutler)
      INPUT_GIT_WORKFLOW="git"
      INPUT_GITBUTLER_MCP=false
      WORKFLOW_CONFIG_REQUESTED=true
      shift
      ;;
    --gitbutler-mcp)
      INPUT_GITBUTLER_MCP=true
      WORKFLOW_CONFIG_REQUESTED=true
      shift
      ;;
    --no-gitbutler-mcp)
      INPUT_GITBUTLER_MCP=false
      WORKFLOW_CONFIG_REQUESTED=true
      shift
      ;;
    --ci)
      # Accept either `--ci` alone (defaults to github) or `--ci <provider>`
      # for future providers (gitlab, circle). For now only github is shipped.
      if [ "$#" -ge 2 ] && [[ "$2" != --* ]]; then
        case "$2" in
          github|none) INPUT_CI="$2"; shift 2 ;;
          *) echo "ERROR: --ci value must be one of: github, none" >&2; exit 1 ;;
        esac
      else
        INPUT_CI="github"
        shift
      fi
      ;;
    --no-ci)
      INPUT_CI="none"
      shift
      ;;
    *) echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

# Resolve to absolute path.
if [[ "$PROJECT_DIR" != /* ]]; then
  PROJECT_DIR="$(pwd)/$PROJECT_DIR"
fi

# Detect re-init state early so prompts and summary adapt to the case.
# Fresh = first touchstone bootstrap; reinit = repair/reconcile an already-touchstoned project.
if [ -f "$PROJECT_DIR/.touchstone-version" ]; then
  RE_INIT=true
  echo "==> Reconciling touchstone files in $PROJECT_DIR"
else
  RE_INIT=false
  echo "==> Bootstrapping project at $PROJECT_DIR"
fi

# Summary counters — populated by copy_file / copy_file_force, emitted at end.
FILES_ADDED=0
FILES_EXISTING=0
FILES_UPDATED=0
FILES_UNCHANGED=0

# Create directory if needed.
mkdir -p "$PROJECT_DIR"

# Init git if not already a repo.
if [ ! -d "$PROJECT_DIR/.git" ]; then
  echo "==> Initializing git repo ..."
  git -C "$PROJECT_DIR" init
fi

# Helper: copy a project-owned file if it does not already exist.
LAST_COPY_CREATED=false
copy_file() {
  local src="$1"
  local dst="$2"
  local dst_dir
  dst_dir="$(dirname "$dst")"
  mkdir -p "$dst_dir"

  if [ -e "$dst" ]; then
    LAST_COPY_CREATED=false
    if [ ! -f "$dst" ]; then
      echo "ERROR: destination exists but is not a regular file: $dst" >&2
      return 1
    fi
    echo "    exists (skipped): $(basename "$dst")"
    FILES_EXISTING=$((FILES_EXISTING + 1))
  else
    cp "$src" "$dst"
    LAST_COPY_CREATED=true
    echo "    + $(basename "$dst")"
    FILES_ADDED=$((FILES_ADDED + 1))
  fi
}

# Helper: copy a Touchstone-owned file, backing up existing local content first.
copy_file_force() {
  local src="$1"
  local dst="$2"
  local backup_path dst_dir
  dst_dir="$(dirname "$dst")"
  mkdir -p "$dst_dir"

  if [ -f "$dst" ] && diff -q "$src" "$dst" >/dev/null 2>&1; then
    echo "    same (skipped): $(basename "$dst")"
    FILES_UNCHANGED=$((FILES_UNCHANGED + 1))
    return
  fi

  if [ -e "$dst" ]; then
    if [ ! -f "$dst" ]; then
      echo "ERROR: destination exists but is not a regular file: $dst" >&2
      return 1
    fi
    backup_path="$(next_backup_path "$dst")"
    cp "$dst" "$backup_path"
    cp "$src" "$dst"
    echo "    ! $(basename "$dst") (backed up as $(basename "$backup_path"))"
    FILES_UPDATED=$((FILES_UPDATED + 1))
    return
  fi

  cp "$src" "$dst"
  echo "    + $(basename "$dst")"
  FILES_ADDED=$((FILES_ADDED + 1))
}

write_touchstone_manifest() {
  local manifest_tmp
  manifest_tmp="$(mktemp -t touchstone-manifest.XXXXXX)"
  {
    printf '# Managed by touchstone. These paths may be updated by `touchstone update`.\n'
    printf '.touchstone-manifest\n'
    printf '.touchstone-version\n'
    for f in "$TOUCHSTONE_ROOT/principles/"*.md; do
      printf 'principles/%s\n' "$(basename "$f")"
    done
    printf 'scripts/codex-review.sh\n'
    printf 'scripts/touchstone-run.sh\n'
    printf 'scripts/open-pr.sh\n'
    printf 'scripts/merge-pr.sh\n'
    printf 'scripts/cleanup-branches.sh\n'
    if [ "$INPUT_TYPE" = "python" ]; then
      printf 'scripts/run-pytest-in-venv.sh\n'
    fi
  } > "$manifest_tmp"
  if copy_file_force "$manifest_tmp" "$PROJECT_DIR/.touchstone-manifest"; then
    rm -f "$manifest_tmp"
  else
    rm -f "$manifest_tmp"
    return 1
  fi
}

set_codex_review_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp_file
  tmp_file="$(mktemp -t touchstone-codex-review-key.XXXXXX)"

  awk -v key="$key" -v repl="$key = $value" '
    BEGIN { in_section = 0; replaced = 0 }
    /^\[codex_review\][[:space:]]*$/ {
      in_section = 1
      print
      next
    }
    /^\[/ {
      if (in_section && !replaced) {
        print repl
        replaced = 1
      }
      in_section = 0
      print
      next
    }
    in_section && !replaced {
      pattern = "^[[:space:]#]*" key "[[:space:]]*="
      if ($0 ~ pattern) {
        print repl
        replaced = 1
        next
      }
    }
    { print }
    END {
      if (in_section && !replaced) {
        print repl
      }
    }
  ' "$file" > "$tmp_file"
  mv "$tmp_file" "$file"
}

reviewers_toml_for() {
  local reviewer="$1"
  case "$reviewer" in
    none) printf '[]' ;;
    auto|"") printf '["codex", "claude", "gemini"]' ;;
    *) printf '["%s"]' "$reviewer" ;;
  esac
}

small_local_reviewers_toml_for() {
  local reviewer="$1"
  case "$reviewer" in
    auto|"") printf '["local", "codex", "claude", "gemini"]' ;;
    local|none) printf '["local", "codex"]' ;;
    *) printf '["local", "%s"]' "$reviewer" ;;
  esac
}

write_review_onboarding_config() {
  local file="$1"
  local reviewer="${INPUT_REVIEWER:-auto}"
  local routing="${INPUT_REVIEW_ROUTING:-}"
  local assist="${INPUT_REVIEW_ASSIST:-false}"
  local autofix="${INPUT_REVIEW_AUTOFIX:-false}"
  local small_review_lines="${INPUT_SMALL_REVIEW_LINES:-400}"
  local enabled=true
  local reviewers_toml
  local large_reviewers_toml
  local small_reviewers_toml

  if [ -z "$routing" ]; then
    case "$reviewer" in
      local) routing="all-local" ;;
      none) routing="none" ;;
      *) routing="all-hosted" ;;
    esac
  fi

  if [ "$routing" = "none" ] || [ "$reviewer" = "none" ]; then
    enabled=false
    routing="none"
    reviewers_toml="$(reviewers_toml_for none)"
  elif [ "$routing" = "all-local" ]; then
    reviewer="local"
    reviewers_toml="$(reviewers_toml_for local)"
  else
    reviewers_toml="$(reviewers_toml_for "$reviewer")"
  fi

  large_reviewers_toml="$(reviewers_toml_for "$reviewer")"
  small_reviewers_toml="$(small_local_reviewers_toml_for "$reviewer")"

  if [ "$enabled" = true ] && [ "$autofix" = true ]; then
    set_codex_review_key "$file" "mode" '"fix"'
    set_codex_review_key "$file" "safe_by_default" "true"
  else
    set_codex_review_key "$file" "mode" '"review-only"'
    set_codex_review_key "$file" "safe_by_default" "false"
  fi

  {
    printf '\n# Touchstone onboarding choices. You can edit these later.\n'
    printf '[review]\n'
    printf 'enabled = %s\n' "$enabled"
    printf 'reviewers = %s\n' "$reviewers_toml"
    if [ "$routing" = "small-local" ]; then
      printf '\n[review.routing]\n'
      printf 'enabled = true\n'
      printf 'small_max_diff_lines = %s\n' "$small_review_lines"
      printf 'small_reviewers = %s\n' "$small_reviewers_toml"
      printf 'large_reviewers = %s\n' "$large_reviewers_toml"
    fi
    printf '\n[review.assist]\n'
    printf 'enabled = %s\n' "$assist"
    printf 'helpers = ["codex", "gemini", "claude", "local"]\n'
    if [ "$reviewer" = "local" ] || [ "$routing" = "small-local" ]; then
      printf '\n[review.local]\n'
      printf '# The command receives the review prompt on stdin and must print CODEX_REVIEW_CLEAN, CODEX_REVIEW_FIXED, or CODEX_REVIEW_BLOCKED as its last line.\n'
      printf 'command = "%s"\n' "$(escape_toml_basic_string "$INPUT_LOCAL_REVIEW_COMMAND")"
    fi
  } >> "$file"
}

print_review_setup_hint() {
  local reviewer="${INPUT_REVIEWER:-auto}"
  local routing="${INPUT_REVIEW_ROUTING:-}"
  local enabled=true

  if [ -z "$routing" ]; then
    case "$reviewer" in
      local) routing="all-local" ;;
      none) routing="none" ;;
      *) routing="all-hosted" ;;
    esac
  fi

  { [ "$reviewer" = "none" ] || [ "$routing" = "none" ]; } && enabled=false
  if [ "$enabled" = false ]; then
    echo "==> AI review disabled. You can enable it later in .codex-review.toml."
    return
  fi

  echo "==> AI review configured: routing=$routing reviewer=$reviewer"
  if [ "$routing" = "small-local" ]; then
    echo "    Small diffs (<= ${INPUT_SMALL_REVIEW_LINES:-400} lines) try your local reviewer first; larger diffs use the hosted reviewer."
  fi
  case "$reviewer" in
    codex|auto)
      if ! command -v codex >/dev/null 2>&1; then
        echo "    Codex is not installed yet. setup.sh will try to install it if npm is available."
        echo "    Manual install: npm install -g @openai/codex && codex login"
      fi
      ;;
    claude)
      if ! command -v claude >/dev/null 2>&1; then
        echo "    Claude CLI is not installed yet. Install and authenticate Claude before relying on review."
      fi
      ;;
    gemini)
      if ! command -v gemini >/dev/null 2>&1; then
        echo "    Gemini CLI is not installed yet. Install and authenticate Gemini before relying on review."
      fi
      ;;
    local)
      if [ -z "$INPUT_LOCAL_REVIEW_COMMAND" ]; then
        echo "    Add [review.local].command in .codex-review.toml before local review can run."
      else
        echo "    Local reviewer command: $INPUT_LOCAL_REVIEW_COMMAND"
      fi
      ;;
  esac

  if [ "$routing" = "small-local" ] && [ -z "$INPUT_LOCAL_REVIEW_COMMAND" ]; then
    echo "    Add [review.local].command in .codex-review.toml before local small-diff review can run."
  fi
}

echo ""
echo "==> Copying templates (project-owned, won't be auto-updated):"
copy_file "$TOUCHSTONE_ROOT/templates/CLAUDE.md" "$PROJECT_DIR/CLAUDE.md"
CLAUDE_MD_CREATED="$LAST_COPY_CREATED"
copy_file "$TOUCHSTONE_ROOT/templates/AGENTS.md" "$PROJECT_DIR/AGENTS.md"
copy_file "$TOUCHSTONE_ROOT/templates/pre-commit-config.yaml" "$PROJECT_DIR/.pre-commit-config.yaml"
copy_file "$TOUCHSTONE_ROOT/templates/gitignore" "$PROJECT_DIR/.gitignore"
copy_file "$TOUCHSTONE_ROOT/templates/pull_request_template.md" "$PROJECT_DIR/.github/pull_request_template.md"
copy_file "$TOUCHSTONE_ROOT/hooks/codex-review.config.example.toml" "$PROJECT_DIR/.codex-review.toml"
CODEX_REVIEW_CONFIG_CREATED="$LAST_COPY_CREATED"
copy_file "$TOUCHSTONE_ROOT/templates/setup.sh" "$PROJECT_DIR/setup.sh"
chmod +x "$PROJECT_DIR/setup.sh" 2>/dev/null || true

echo ""
echo "==> Copying principles (touchstone-owned, will be auto-updated):"
mkdir -p "$PROJECT_DIR/principles"
for f in "$TOUCHSTONE_ROOT/principles/"*.md; do
  copy_file_force "$f" "$PROJECT_DIR/principles/$(basename "$f")"
done

echo ""
echo "==> Copying scripts (touchstone-owned, will be auto-updated):"
mkdir -p "$PROJECT_DIR/scripts"
copy_file_force "$TOUCHSTONE_ROOT/hooks/codex-review.sh" "$PROJECT_DIR/scripts/codex-review.sh"
copy_file_force "$TOUCHSTONE_ROOT/scripts/touchstone-run.sh" "$PROJECT_DIR/scripts/touchstone-run.sh"
copy_file_force "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$PROJECT_DIR/scripts/open-pr.sh"
copy_file_force "$TOUCHSTONE_ROOT/scripts/merge-pr.sh" "$PROJECT_DIR/scripts/merge-pr.sh"
copy_file_force "$TOUCHSTONE_ROOT/scripts/cleanup-branches.sh" "$PROJECT_DIR/scripts/cleanup-branches.sh"
chmod +x "$PROJECT_DIR/scripts/"*.sh

# Optional CI workflow — opt-in via --ci. Not copied by default because not every
# project uses GitHub Actions, and shipping a workflow file silently into every
# bootstrap would force that opinion on GitLab/Bitbucket/self-hosted users.
CI_WORKFLOW_CREATED=false
if [ "$INPUT_CI" = "github" ]; then
  echo ""
  echo "==> Adding CI workflow (project-owned, won't be auto-updated):"
  copy_file "$TOUCHSTONE_ROOT/templates/ci/github-validate.yml" "$PROJECT_DIR/.github/workflows/validate.yml"
  if [ "$LAST_COPY_CREATED" = true ]; then
    CI_WORKFLOW_CREATED=true
  fi
fi

# Write touchstone version.
# Use git SHA if this is a git clone, otherwise use VERSION (brew install).
if [ -d "$TOUCHSTONE_ROOT/.git" ]; then
  TOUCHSTONE_SHA="$(git -C "$TOUCHSTONE_ROOT" rev-parse HEAD)"
else
  TOUCHSTONE_SHA="$(cat "$TOUCHSTONE_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "unknown")"
fi
echo "$TOUCHSTONE_SHA" > "$PROJECT_DIR/.touchstone-version"
echo ""
echo "==> Wrote .touchstone-version: $TOUCHSTONE_SHA"

# Register in ~/.touchstone-projects for sync-all.sh.
PROJECTS_FILE="$HOME/.touchstone-projects"
if [ "$REGISTER" = true ]; then
  # Ensure file exists.
  touch "$PROJECTS_FILE"
  # Add if not already registered.
  if ! grep -qxF "$PROJECT_DIR" "$PROJECTS_FILE" 2>/dev/null; then
    echo "$PROJECT_DIR" >> "$PROJECTS_FILE"
    echo "==> Registered in $PROJECTS_FILE"
  else
    echo "==> Already registered in $PROJECTS_FILE"
  fi
fi

# --------------------------------------------------------------------------
# Interactive placeholder filling (if stdin is a terminal)
# --------------------------------------------------------------------------
INPUT_NAME=""
INPUT_DESC=""
INPUT_TEST=""

if [ -t 0 ] && [ "$RE_INIT" = false ] && [ "$CLAUDE_MD_CREATED" = true ]; then
  echo ""
  echo "==> Fill in project details (press Enter to skip any):"
  echo ""

  read -r -p "   Project name [$(basename "$PROJECT_DIR")]: " INPUT_NAME
  INPUT_NAME="${INPUT_NAME:-$(basename "$PROJECT_DIR")}"

  read -r -p "   One-line description: " INPUT_DESC

  read -r -p "   Test command (e.g., pnpm build, pytest tests/): " INPUT_TEST

  if [ -z "$INPUT_TYPE" ]; then
    DETECTED_TYPE="$(detect_project_type "$PROJECT_DIR")"
    read -r -p "   Project type (node, python, swift, rust, go, generic, auto) [$DETECTED_TYPE]: " INPUT_TYPE
    INPUT_TYPE="${INPUT_TYPE:-$DETECTED_TYPE}"
    INPUT_TYPE="$(normalize_project_type "$INPUT_TYPE")"
  fi

  if [ "$REVIEW_CONFIG_REQUESTED" = false ] && [ "$CODEX_REVIEW_CONFIG_CREATED" = true ]; then
    echo ""
    echo "==> Configure AI review (press Enter for the default):"
    echo "   Hosted review: strongest default reviewer for every change."
    echo "   Local review: private and cheap, but quality depends on your local model."
    echo "   Hybrid review: local handles small diffs; hosted review handles larger diffs."
    if [ "$(prompt_yes_no "Use AI review before code reaches main?" "true")" = "true" ]; then
      local_default_reviewer="$(default_reviewer)"
      local_review_style=""
      read -r -p "   Review style (hosted, local, hybrid) [hosted]: " local_review_style
      local_review_style="$(normalize_review_routing "${local_review_style:-hosted}")"

      case "$local_review_style" in
        all-hosted)
          INPUT_REVIEW_ROUTING="all-hosted"
          read -r -p "   Hosted reviewer (codex, claude, gemini, auto) [$local_default_reviewer]: " INPUT_REVIEWER
          INPUT_REVIEWER="${INPUT_REVIEWER:-$local_default_reviewer}"
          INPUT_REVIEWER="$(normalize_reviewer "$INPUT_REVIEWER")"
          ;;
        all-local)
          INPUT_REVIEW_ROUTING="all-local"
          INPUT_REVIEWER="local"
          read -r -p "   Local reviewer command (reads prompt on stdin, e.g. 'ollama run MODEL'): " INPUT_LOCAL_REVIEW_COMMAND
          ;;
        small-local)
          INPUT_REVIEW_ROUTING="small-local"
          read -r -p "   Local reviewer command for small diffs (e.g. 'ollama run MODEL'): " INPUT_LOCAL_REVIEW_COMMAND
          read -r -p "   Hosted reviewer for larger diffs (codex, claude, gemini, auto) [$local_default_reviewer]: " INPUT_REVIEWER
          INPUT_REVIEWER="${INPUT_REVIEWER:-$local_default_reviewer}"
          INPUT_REVIEWER="$(normalize_reviewer "$INPUT_REVIEWER")"
          read -r -p "   Small-diff cutoff in changed diff lines [400]: " INPUT_SMALL_REVIEW_LINES
          INPUT_SMALL_REVIEW_LINES="${INPUT_SMALL_REVIEW_LINES:-400}"
          INPUT_SMALL_REVIEW_LINES="$(normalize_positive_int "$INPUT_SMALL_REVIEW_LINES")"
          ;;
      esac

      INPUT_REVIEW_AUTOFIX="$(prompt_yes_no "Let the AI auto-fix low-risk issues?" "false")"
      INPUT_REVIEW_ASSIST="$(prompt_yes_no "Let the AI ask one peer reviewer for larger changes?" "false")"

      if [ "$INPUT_REVIEW_AUTOFIX" = "true" ] && [ -z "$INPUT_UNSAFE" ]; then
        read -r -p "   High-scrutiny paths the AI must never auto-fix (comma-separated, e.g., src/auth/,migrations/): " INPUT_UNSAFE
      fi
    else
      INPUT_REVIEWER="none"
      INPUT_REVIEW_ROUTING="none"
      INPUT_REVIEW_AUTOFIX=false
      INPUT_REVIEW_ASSIST=false
    fi
    REVIEW_CONFIG_REQUESTED=true
  fi

  if [ "$WORKFLOW_CONFIG_REQUESTED" = false ]; then
    echo ""
    echo "==> Choose Git workflow helpers (press Enter for the default):"
    echo "   Plain Git: simplest, lowest surprise; use Touchstone's branch/PR scripts."
    echo "   GitButler: optional power workflow for stacked or parallel branches, undo history, and AI-agent branch management."
    if [ "$(prompt_yes_no "Use GitButler for this project?" "false")" = "true" ]; then
      INPUT_GIT_WORKFLOW="gitbutler"
      INPUT_GITBUTLER_MCP="$(prompt_yes_no "Expose GitButler to AI agents through MCP when the CLI is installed?" "false")"
    else
      INPUT_GIT_WORKFLOW="git"
      INPUT_GITBUTLER_MCP=false
    fi
    WORKFLOW_CONFIG_REQUESTED=true
  fi
fi

# Default project type if not set.
INPUT_TYPE="${INPUT_TYPE:-auto}"
INPUT_TYPE="$(normalize_project_type "$INPUT_TYPE")"
if [ "$INPUT_TYPE" = "auto" ]; then
  INPUT_TYPE="$(detect_project_type "$PROJECT_DIR")"
fi
INPUT_GIT_WORKFLOW="${INPUT_GIT_WORKFLOW:-git}"
INPUT_GIT_WORKFLOW="$(normalize_git_workflow "$INPUT_GIT_WORKFLOW")"
INPUT_GITBUTLER_MCP="${INPUT_GITBUTLER_MCP:-false}"
INPUT_GITBUTLER_MCP="$(normalize_yes_no "$INPUT_GITBUTLER_MCP")"

PACKAGE_MANAGER="$(detect_node_package_manager "$PROJECT_DIR")"
MONOREPO="$(detect_monorepo "$PROJECT_DIR")"
TARGETS="$(detect_targets "$PROJECT_DIR")"

if [ -n "$INPUT_NAME" ] || [ -n "$INPUT_DESC" ] || [ -n "$INPUT_TEST" ] || [ -n "$INPUT_UNSAFE" ]; then
  # Apply to CLAUDE.md / AGENTS.md.
  if [ -n "$INPUT_NAME" ]; then
    ESCAPED_NAME="$(escape_sed_replacement "$INPUT_NAME")"
    sed -i '' "s/{{PROJECT_NAME}}/$ESCAPED_NAME/g" "$PROJECT_DIR/CLAUDE.md" 2>/dev/null || true
    sed -i '' "s/{{PROJECT_NAME}}/$ESCAPED_NAME/g" "$PROJECT_DIR/AGENTS.md" 2>/dev/null || true
  fi

  if [ -n "$INPUT_DESC" ]; then
    ESCAPED_DESC="$(escape_sed_replacement "$INPUT_DESC")"
    sed -i '' "s/{{PROJECT_DESCRIPTION[^}]*}}/$ESCAPED_DESC/g" "$PROJECT_DIR/CLAUDE.md" 2>/dev/null || true
  fi

  if [ -n "$INPUT_TEST" ]; then
    ESCAPED_TEST="$(escape_sed_replacement "$INPUT_TEST")"
    sed -i '' "s/{{TEST_COMMAND[^}]*}}/$ESCAPED_TEST/g" "$PROJECT_DIR/CLAUDE.md" 2>/dev/null || true
  fi

  if [ -n "$INPUT_UNSAFE" ]; then
    unsafe_paths_input=()
    local_unsafe_paths=()
    IFS=',' read -r -a unsafe_paths_input <<< "$INPUT_UNSAFE"
    for unsafe_path in "${unsafe_paths_input[@]}"; do
      unsafe_path="$(trim "$unsafe_path")"
      [ -z "$unsafe_path" ] && continue
      local_unsafe_paths+=("$unsafe_path")
    done

    if [ "${#local_unsafe_paths[@]}" -gt 0 ] && [ "$CODEX_REVIEW_CONFIG_CREATED" = true ]; then
      write_unsafe_paths_block "$PROJECT_DIR/.codex-review.toml" "${local_unsafe_paths[@]}"
    elif [ "${#local_unsafe_paths[@]}" -gt 0 ]; then
      echo "==> .codex-review.toml already exists; left unsafe_paths unchanged."
    fi
  fi

  if [ -t 0 ]; then
    echo ""
    echo "==> Placeholders filled! Review CLAUDE.md and AGENTS.md to add more detail."
  fi
fi

if [ "$REVIEW_CONFIG_REQUESTED" = true ]; then
  if [ "$CODEX_REVIEW_CONFIG_CREATED" = true ]; then
    write_review_onboarding_config "$PROJECT_DIR/.codex-review.toml"
    print_review_setup_hint
  else
    echo "==> .codex-review.toml already exists; left AI review choices unchanged."
  fi
fi

# Write .touchstone-config with project type (skip if already exists).
if [ ! -f "$PROJECT_DIR/.touchstone-config" ]; then
  {
    printf '# touchstone project profile. Commit this file so all clones use the same commands.\n'
    printf 'project_type=%s\n' "$INPUT_TYPE"
    if [ -n "$PACKAGE_MANAGER" ]; then
      printf 'package_manager=%s\n' "$PACKAGE_MANAGER"
    else
      printf 'package_manager=auto\n'
    fi
    printf 'monorepo=%s\n' "$MONOREPO"
    printf 'targets=%s\n' "$TARGETS"
    printf 'git_workflow=%s\n' "$INPUT_GIT_WORKFLOW"
    printf 'gitbutler_mcp=%s\n' "$INPUT_GITBUTLER_MCP"
    printf 'lint_command=\n'
    printf 'typecheck_command=\n'
    printf 'build_command=\n'
    printf 'test_command=%s\n' "$INPUT_TEST"
    printf 'validate_command=\n'
  } > "$PROJECT_DIR/.touchstone-config"
  echo "==> Wrote .touchstone-config: project_type=$INPUT_TYPE"
else
  echo "==> .touchstone-config already exists; left unchanged."
fi

# Keep the legacy pytest helper only for Python projects. Generic ecosystem
# tasks should go through scripts/touchstone-run.sh.
if [ "$INPUT_TYPE" = "python" ]; then
  echo ""
  echo "==> Copying Python helper:"
  copy_file_force "$TOUCHSTONE_ROOT/scripts/run-pytest-in-venv.sh" "$PROJECT_DIR/scripts/run-pytest-in-venv.sh"
  chmod +x "$PROJECT_DIR/scripts/run-pytest-in-venv.sh" 2>/dev/null || true
fi

write_touchstone_manifest

# Install git hooks so the repo is actually gated, not just configured.
# pre-commit install is idempotent — safe even if setup.sh re-runs it later.
echo ""
HOOK_INSTALL_STATUS=0
touchstone_install_hooks "$PROJECT_DIR" || HOOK_INSTALL_STATUS=$?

# --------------------------------------------------------------------------
# Summary block — every init exits with a checkable state, not silent success.
# --------------------------------------------------------------------------
echo ""
if [ "$RE_INIT" = true ]; then
  echo "==> touchstone reconciled:"
else
  echo "==> touchstone bootstrapped:"
fi
printf '    files:    %d added, %d unchanged' "$FILES_ADDED" "$FILES_UNCHANGED"
if [ "$FILES_UPDATED" -gt 0 ]; then
  printf ', %d updated (previous content backed up as .bak)' "$FILES_UPDATED"
fi
if [ "$FILES_EXISTING" -gt 0 ]; then
  printf ', %d already present' "$FILES_EXISTING"
fi
printf '\n'
printf '    version:  %s\n' "$TOUCHSTONE_SHA"

case "$HOOK_INSTALL_STATUS" in
  0) printf '    hooks:    installed (pre-commit, pre-push)\n' ;;
  1) printf '    hooks:    SKIPPED — no .pre-commit-config.yaml (unexpected)\n' ;;
  2) printf '    hooks:    NOT INSTALLED — pre-commit CLI missing\n' ;;
  3) printf '    hooks:    PARTIAL — one or more installs failed (see above)\n' ;;
esac

if [ "$REGISTER" = true ]; then
  printf '    registry: %s\n' "$PROJECTS_FILE"
else
  printf '    registry: skipped (--no-register)\n'
fi

echo ""
echo "Next steps:"
STEP_NUM=1
if [ "$HOOK_INSTALL_STATUS" -eq 2 ]; then
  printf '  %d. Install pre-commit to gate commits & pushes:\n' "$STEP_NUM"
  printf '       brew install pre-commit   # or: pip install pre-commit\n'
  printf '       Then rerun: touchstone init\n'
  STEP_NUM=$((STEP_NUM + 1))
fi
if [ "$RE_INIT" = false ]; then
  printf '  %d. Fill in CLAUDE.md and AGENTS.md (architecture, key files, hard-won lessons)\n' "$STEP_NUM"
  STEP_NUM=$((STEP_NUM + 1))
fi
printf '  %d. Install dev tools and project deps: cd %s && bash setup.sh\n' "$STEP_NUM" "$PROJECT_DIR"
STEP_NUM=$((STEP_NUM + 1))
printf '  %d. Verify the install: touchstone doctor --project\n' "$STEP_NUM"
echo ""
