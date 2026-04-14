#!/usr/bin/env bash
#
# setup.sh — one-command project setup.
#
# Run this after cloning the repo:
#   bash setup.sh
#
# Installs all dev tools, syncs toolkit files, sets up hooks, and installs
# project dependencies. Idempotent — safe to re-run anytime.
#
set -euo pipefail

# Colors.
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { printf "${BOLD}==> %s${RESET}\n" "$*"; }
ok()    { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
warn()  { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }
fail()  { printf "  ${RED}✗${RESET} %s\n" "$*"; }

DEPS_ONLY=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --deps-only) DEPS_ONLY=true; shift ;;
    -h|--help)
      echo "Usage: bash setup.sh [--deps-only]"
      exit 0
      ;;
    *) fail "Unknown argument: $1"; exit 1 ;;
  esac
done

PROJECT_NAME="$(basename "$(pwd)")"
echo ""
printf "${BOLD}Setting up ${PROJECT_NAME}${RESET}\n"
echo ""

if [ "$DEPS_ONLY" = false ]; then

# --------------------------------------------------------------------------
# 1. Homebrew (required foundation)
# --------------------------------------------------------------------------
info "Checking Homebrew"
if command -v brew >/dev/null 2>&1; then
  ok "brew installed"
else
  fail "Homebrew is required. Install from https://brew.sh"
  exit 1
fi

# --------------------------------------------------------------------------
# 2. Toolkit CLI
# --------------------------------------------------------------------------
info "Checking toolkit"
if command -v toolkit >/dev/null 2>&1; then
  TOOLKIT_VERSION_SUMMARY="$(toolkit version 2>&1 | awk 'NF && !seen { sub(/^toolkit /, ""); print; seen = 1 }')"
  ok "toolkit ${TOOLKIT_VERSION_SUMMARY:-installed}"
else
  warn "Installing toolkit..."
  brew tap henrymodisett/toolkit 2>/dev/null || true
  brew install toolkit
  ok "toolkit installed"
fi

# --------------------------------------------------------------------------
# 3. Dev tools (brew)
# --------------------------------------------------------------------------
info "Checking dev tools"

brew_install_if_missing() {
  local cmd="$1"
  local formula="${2:-$1}"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd installed"
  else
    warn "Installing $formula..."
    brew install "$formula" 2>/dev/null
    ok "$cmd installed"
  fi
}

brew_install_if_missing "git"        "git"
brew_install_if_missing "gh"         "gh"
brew_install_if_missing "pre-commit" "pre-commit"
brew_install_if_missing "gitleaks"   "gitleaks"
brew_install_if_missing "shellcheck" "shellcheck"
brew_install_if_missing "shfmt"      "shfmt"

# --------------------------------------------------------------------------
# 4. AI reviewer CLI (optional)
# --------------------------------------------------------------------------
info "Checking AI reviewer"

AI_REVIEW_ENABLED=true
AI_REVIEWERS=()
AI_LOCAL_REVIEW_COMMAND=""

trim_review_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value%,}"
  value="${value#\"}"; value="${value%\"}"
  value="${value#\'}"; value="${value%\'}"
  printf '%s' "$value"
}

add_reviewers_from_csv() {
  local csv="$1" item
  local -a items=()
  csv="$(trim_review_value "$csv")"
  csv="${csv#\[}"
  csv="${csv%\]}"
  IFS=',' read -r -a items <<< "$csv"
  for item in "${items[@]}"; do
    item="$(trim_review_value "$item")"
    [ -n "$item" ] && AI_REVIEWERS+=("$item")
  done
}

load_ai_review_config() {
  local section="" line key value

  [ -f ".codex-review.toml" ] || {
    AI_REVIEWERS=("codex")
    return 0
  }

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(trim_review_value "$line")"
    [ -z "$line" ] && continue

    case "$line" in
      \[*\])
        section="${line#\[}"
        section="${section%\]}"
        continue
        ;;
    esac

    case "$line" in *=*) ;; *) continue ;; esac
    key="$(trim_review_value "${line%%=*}")"
    value="$(trim_review_value "${line#*=}")"

    if [ "$section" = "review" ]; then
      case "$key" in
        enabled) AI_REVIEW_ENABLED="$value" ;;
        reviewers) add_reviewers_from_csv "${line#*=}" ;;
      esac
    elif [ "$section" = "review.local" ]; then
      case "$key" in
        command) AI_LOCAL_REVIEW_COMMAND="$value" ;;
      esac
    fi
  done < ".codex-review.toml"

  if [ "${#AI_REVIEWERS[@]}" -eq 0 ] && [ "$AI_REVIEW_ENABLED" != "false" ]; then
    AI_REVIEWERS=("codex")
  fi
}

check_ai_reviewer() {
  local reviewer="$1"

  case "$reviewer" in
    codex)
      if command -v codex >/dev/null 2>&1; then
        if codex login status >/dev/null 2>&1; then
          ok "codex installed and authenticated"
        else
          warn "codex installed but not logged in. Run: codex login"
        fi
      elif command -v npm >/dev/null 2>&1; then
        warn "Installing Codex CLI..."
        npm install -g @openai/codex 2>/dev/null && ok "codex installed — run: codex login" || warn "codex install failed. Manual install: npm install -g @openai/codex"
      else
        warn "codex not installed. Install Node.js/npm first, then: npm install -g @openai/codex && codex login"
      fi
      ;;
    claude)
      if command -v claude >/dev/null 2>&1; then
        if claude auth status >/dev/null 2>&1; then
          ok "claude installed and authenticated"
        else
          warn "claude installed but auth check failed. Authenticate Claude before relying on review."
        fi
      else
        warn "claude reviewer selected, but Claude CLI is not installed."
      fi
      ;;
    gemini)
      if command -v gemini >/dev/null 2>&1; then
        if [ -n "${GEMINI_API_KEY:-}" ] || { command -v gcloud >/dev/null 2>&1 && gcloud auth print-access-token >/dev/null 2>&1; }; then
          ok "gemini installed and authenticated"
        else
          warn "gemini installed but auth is not configured. Set GEMINI_API_KEY or authenticate gcloud."
        fi
      else
        warn "gemini reviewer selected, but Gemini CLI is not installed."
      fi
      ;;
    local)
      if [ -n "$AI_LOCAL_REVIEW_COMMAND" ]; then
        ok "local reviewer configured: $AI_LOCAL_REVIEW_COMMAND"
      else
        warn "local reviewer selected, but [review.local].command is empty in .codex-review.toml"
      fi
      ;;
    *)
      warn "unknown AI reviewer '$reviewer' in .codex-review.toml"
      ;;
  esac
}

load_ai_review_config
if [ "$AI_REVIEW_ENABLED" = "false" ]; then
  ok "AI review disabled in .codex-review.toml"
else
  for reviewer in "${AI_REVIEWERS[@]}"; do
    check_ai_reviewer "$reviewer"
  done
fi

# --------------------------------------------------------------------------
# 5. Sync toolkit files to latest
# --------------------------------------------------------------------------
info "Syncing toolkit files"
# Skip update if this IS the toolkit repo (it's the source, not a downstream project).
if [ -f "bin/toolkit" ] && [ -f "lib/auto-update.sh" ]; then
  ok "this is the toolkit repo — skipping self-update"
elif [ -f ".toolkit-version" ]; then
  toolkit update --check 2>&1 | grep -E "Already|Needs sync|Run: toolkit update" | head -5 | while read -r line; do
    ok "$line"
  done
  ok "toolkit sync status checked"
else
  warn "No .toolkit-version found — this project hasn't been bootstrapped."
  warn "Run: toolkit new $(pwd)"
fi

# --------------------------------------------------------------------------
# 6. Pre-commit hooks
# --------------------------------------------------------------------------
info "Setting up git hooks"
if [ -f ".pre-commit-config.yaml" ]; then
  # Clear core.hooksPath if set — it conflicts with pre-commit.
  git config --unset-all core.hooksPath 2>/dev/null || true
  # Install hook shims (environments install lazily on first run).
  pre-commit install 2>&1 | tail -1 | while read -r line; do ok "$line"; done
  pre-commit install --hook-type pre-push 2>&1 | tail -1 | while read -r line; do ok "$line"; done
  pre-commit install --hook-type commit-msg 2>&1 | tail -1 | while read -r line; do ok "$line"; done
  ok "pre-commit hooks installed (pre-commit, pre-push, commit-msg)"
else
  warn "No .pre-commit-config.yaml found — skipping hooks"
fi

# --------------------------------------------------------------------------
# 7. gh CLI auth check
# --------------------------------------------------------------------------
info "Checking GitHub auth"
if gh auth status 2>&1 | grep -q "Logged in"; then
  ok "gh authenticated"
else
  warn "gh not authenticated. Run: gh auth login"
fi

fi

# --------------------------------------------------------------------------
# 8. Project dependencies
# --------------------------------------------------------------------------
info "Installing project dependencies"

select_python_for_venv() {
  local python_dir="${1:-.}"
  local pyenv_python

  if [ -n "${PYTHON:-}" ]; then
    if command -v "$PYTHON" >/dev/null 2>&1; then
      command -v "$PYTHON"
      return 0
    fi
    fail "PYTHON is set but not executable: $PYTHON"
    return 1
  fi

  if command -v pyenv >/dev/null 2>&1; then
    if [ -f "$python_dir/.python-version" ] || [ -f ".python-version" ]; then
      pyenv_python="$(cd "$python_dir" && pyenv which python 2>/dev/null || true)"
      if [ -n "$pyenv_python" ] && [ -x "$pyenv_python" ]; then
        printf '%s\n' "$pyenv_python"
        return 0
      fi
    fi
  fi

  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    command -v python
    return 0
  fi

  fail "Python is required to create a virtualenv"
  return 1
}

install_python_requirements() {
  local label="$1"
  local requirements_file="$2"
  local venv_dir="$3"
  local python_bin python_dir python_version
  python_dir="$(dirname "$requirements_file")"

  if [ ! -x "$venv_dir/bin/python" ]; then
    python_bin="$(select_python_for_venv "$python_dir")"
    python_version="$("$python_bin" --version 2>&1)"
    if [ ! -f "$python_dir/.python-version" ] && [ ! -f ".python-version" ]; then
      warn "No .python-version found — creating $venv_dir with $python_version"
    else
      ok "Using $python_version for $venv_dir"
    fi
    "$python_bin" -m venv "$venv_dir"
    ok "$venv_dir created"
  fi

  "$venv_dir/bin/python" -m pip install -r "$requirements_file" 2>&1 | tail -1 | while read -r line; do
    ok "$label dependencies installed: $line"
  done
}

install_uv_if_missing() {
  if command -v uv >/dev/null 2>&1; then
    return 0
  fi

  if command -v brew >/dev/null 2>&1; then
    warn "Installing uv..."
    brew install uv 2>/dev/null
    ok "uv installed"
    return 0
  fi

  warn "uv is required for uv.lock/pyproject.toml projects. Install uv first."
  return 1
}

install_uv_project() {
  local label="$1"
  local project_dir="$2"

  if install_uv_if_missing; then
    (cd "$project_dir" && uv sync) 2>&1 | tail -1 | while read -r line; do
      ok "$label dependencies synced: $line"
    done
  fi
}

DEPS_FOUND=false

if [ -f "pnpm-lock.yaml" ]; then
  DEPS_FOUND=true
  if command -v pnpm >/dev/null 2>&1; then
    pnpm install 2>&1 | tail -1 | while read -r line; do ok "$line"; done
  else
    warn "pnpm-lock.yaml found, but pnpm is not installed. Run: brew install pnpm"
  fi
elif [ -f "package-lock.json" ]; then
  DEPS_FOUND=true
  if command -v npm >/dev/null 2>&1; then
    npm install 2>&1 | tail -1 | while read -r line; do ok "$line"; done
  else
    warn "package-lock.json found, but npm is not installed. Install Node.js/npm first."
  fi
elif [ -f "package.json" ]; then
  DEPS_FOUND=true
  if command -v pnpm >/dev/null 2>&1; then
    pnpm install 2>&1 | tail -1 | while read -r line; do ok "$line"; done
  elif command -v npm >/dev/null 2>&1; then
    npm install 2>&1 | tail -1 | while read -r line; do ok "$line"; done
  else
    warn "package.json found, but neither pnpm nor npm is installed."
  fi
fi

if [ -f "uv.lock" ]; then
  DEPS_FOUND=true
  install_uv_project "Python" "."
elif [ -f "pyproject.toml" ] && [ ! -f "requirements.txt" ]; then
  DEPS_FOUND=true
  install_uv_project "Python" "."
elif [ -f "requirements.txt" ]; then
  DEPS_FOUND=true
  install_python_requirements "Python" "requirements.txt" ".venv"
fi

if [ -f "agent/uv.lock" ]; then
  DEPS_FOUND=true
  install_uv_project "agent Python" "agent"
elif [ -f "agent/pyproject.toml" ] && [ ! -f "agent/requirements.txt" ]; then
  DEPS_FOUND=true
  install_uv_project "agent Python" "agent"
elif [ -f "agent/requirements.txt" ]; then
  DEPS_FOUND=true
  install_python_requirements "agent Python" "agent/requirements.txt" "agent/.venv"
fi

if [ "$DEPS_FOUND" = false ]; then
  if [ -f "Cargo.toml" ]; then
    ok "Rust project — run: cargo build"
  elif [ -f "Package.swift" ]; then
    ok "Swift project — run: swift build"
  elif [ -f "go.mod" ]; then
    go mod download 2>&1 && ok "Go modules downloaded"
  else
    ok "No recognized dependency file — skipping"
  fi
fi

# --------------------------------------------------------------------------
# 9. Summary
# --------------------------------------------------------------------------
echo ""
info "Setup complete"
echo ""
printf "  Run ${BOLD}toolkit doctor${RESET} to verify everything.\n"
printf "  Run ${BOLD}toolkit status${RESET} to see project health.\n"
echo ""
