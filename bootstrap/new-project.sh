#!/usr/bin/env bash
#
# bootstrap/new-project.sh — spin up a new project with toolkit files.
#
# Usage:
#   new-project.sh <project-dir>
#   new-project.sh <project-dir> --no-register   # skip adding to ~/.toolkit-projects
#   new-project.sh <project-dir> --unsafe-paths src/auth/,migrations/
#
# What this does:
#   1. Creates the directory if it doesn't exist, initializes git
#   2. Copies templates, principles, hooks, and scripts into the project
#   3. Makes scripts executable
#   4. Writes .toolkit-version with the current toolkit commit SHA
#   5. Registers the project in ~/.toolkit-projects (for sync-all.sh)
#   6. Prints next steps
#
# After running, fill in the {{PLACEHOLDERS}} in CLAUDE.md and AGENTS.md.
#
set -euo pipefail

TOOLKIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGISTER=true
INPUT_UNSAFE=""

usage() {
  echo "Usage: $0 <project-dir> [--no-register] [--unsafe-paths path1,path2]"
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
  block_file="$(mktemp -t toolkit-codex-review-block.XXXXXX)"
  tmp_file="$(mktemp -t toolkit-codex-review.XXXXXX)"

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
    --unsafe-paths)
      [ "$#" -ge 2 ] || { echo "ERROR: --unsafe-paths requires a comma-separated value" >&2; exit 1; }
      INPUT_UNSAFE="$2"
      shift 2
      ;;
    *) echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

# Resolve to absolute path.
if [[ "$PROJECT_DIR" != /* ]]; then
  PROJECT_DIR="$(pwd)/$PROJECT_DIR"
fi

echo "==> Bootstrapping project at $PROJECT_DIR"

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
  else
    cp "$src" "$dst"
    LAST_COPY_CREATED=true
    echo "    + $(basename "$dst")"
  fi
}

# Helper: copy a toolkit-owned file, backing up existing local content first.
copy_file_force() {
  local src="$1"
  local dst="$2"
  local backup_path dst_dir
  dst_dir="$(dirname "$dst")"
  mkdir -p "$dst_dir"

  if [ -f "$dst" ] && diff -q "$src" "$dst" >/dev/null 2>&1; then
    echo "    same (skipped): $(basename "$dst")"
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
    return
  fi

  cp "$src" "$dst"
  echo "    + $(basename "$dst")"
}

echo ""
echo "==> Copying templates (project-owned, won't be auto-updated):"
copy_file "$TOOLKIT_ROOT/templates/CLAUDE.md" "$PROJECT_DIR/CLAUDE.md"
copy_file "$TOOLKIT_ROOT/templates/AGENTS.md" "$PROJECT_DIR/AGENTS.md"
copy_file "$TOOLKIT_ROOT/templates/pre-commit-config.yaml" "$PROJECT_DIR/.pre-commit-config.yaml"
copy_file "$TOOLKIT_ROOT/templates/gitignore" "$PROJECT_DIR/.gitignore"
copy_file "$TOOLKIT_ROOT/templates/pull_request_template.md" "$PROJECT_DIR/.github/pull_request_template.md"
copy_file "$TOOLKIT_ROOT/hooks/codex-review.config.example.toml" "$PROJECT_DIR/.codex-review.toml"
CODEX_REVIEW_CONFIG_CREATED="$LAST_COPY_CREATED"
copy_file "$TOOLKIT_ROOT/templates/setup.sh" "$PROJECT_DIR/setup.sh"
chmod +x "$PROJECT_DIR/setup.sh" 2>/dev/null || true

echo ""
echo "==> Copying principles (toolkit-owned, will be auto-updated):"
mkdir -p "$PROJECT_DIR/principles"
for f in "$TOOLKIT_ROOT/principles/"*.md; do
  copy_file_force "$f" "$PROJECT_DIR/principles/$(basename "$f")"
done

echo ""
echo "==> Copying scripts (toolkit-owned, will be auto-updated):"
mkdir -p "$PROJECT_DIR/scripts"
copy_file_force "$TOOLKIT_ROOT/hooks/codex-review.sh" "$PROJECT_DIR/scripts/codex-review.sh"
copy_file_force "$TOOLKIT_ROOT/scripts/open-pr.sh" "$PROJECT_DIR/scripts/open-pr.sh"
copy_file_force "$TOOLKIT_ROOT/scripts/merge-pr.sh" "$PROJECT_DIR/scripts/merge-pr.sh"
copy_file_force "$TOOLKIT_ROOT/scripts/cleanup-branches.sh" "$PROJECT_DIR/scripts/cleanup-branches.sh"
copy_file_force "$TOOLKIT_ROOT/scripts/run-pytest-in-venv.sh" "$PROJECT_DIR/scripts/run-pytest-in-venv.sh"
chmod +x "$PROJECT_DIR/scripts/"*.sh

# Write toolkit version.
# Use git SHA if this is a git clone, otherwise use VERSION (brew install).
if [ -d "$TOOLKIT_ROOT/.git" ]; then
  TOOLKIT_SHA="$(git -C "$TOOLKIT_ROOT" rev-parse HEAD)"
else
  TOOLKIT_SHA="$(cat "$TOOLKIT_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "unknown")"
fi
echo "$TOOLKIT_SHA" > "$PROJECT_DIR/.toolkit-version"
echo ""
echo "==> Wrote .toolkit-version: $TOOLKIT_SHA"

# Register in ~/.toolkit-projects for sync-all.sh.
PROJECTS_FILE="$HOME/.toolkit-projects"
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

if [ -t 0 ] && [ -f "$PROJECT_DIR/CLAUDE.md" ]; then
  echo ""
  echo "==> Fill in project details (press Enter to skip any):"
  echo ""

  read -r -p "   Project name [$(basename "$PROJECT_DIR")]: " INPUT_NAME
  INPUT_NAME="${INPUT_NAME:-$(basename "$PROJECT_DIR")}"

  read -r -p "   One-line description: " INPUT_DESC

  read -r -p "   Test command (e.g., pnpm build, pytest tests/): " INPUT_TEST

  if [ -z "$INPUT_UNSAFE" ] && [ "$CODEX_REVIEW_CONFIG_CREATED" = true ]; then
    read -r -p "   High-scrutiny paths (comma-separated, e.g., src/auth/,migrations/): " INPUT_UNSAFE
  fi
fi

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

echo ""
echo "==> Done! Next steps:"
echo ""
echo "   1. Review CLAUDE.md and AGENTS.md — add architecture, key files, hard-won lessons"
echo "   2. Run setup.sh to install all dev tools:"
echo "        cd $PROJECT_DIR && bash setup.sh"
echo ""
