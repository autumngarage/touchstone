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

PROJECT_NAME="$(basename "$(pwd)")"
echo ""
printf "${BOLD}Setting up ${PROJECT_NAME}${RESET}\n"
echo ""

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
  ok "toolkit $(toolkit version 2>&1 | head -1 | sed 's/toolkit //')"
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
# 4. Codex CLI (npm, optional but recommended)
# --------------------------------------------------------------------------
info "Checking Codex CLI"
if command -v codex >/dev/null 2>&1; then
  ok "codex installed"
elif command -v npm >/dev/null 2>&1; then
  warn "Installing codex CLI..."
  npm install -g @openai/codex 2>/dev/null && ok "codex installed" || warn "codex install failed (optional — install manually: npm install -g @openai/codex)"
else
  warn "codex not installed (requires npm). Install Node.js first, then: npm install -g @openai/codex"
fi

# --------------------------------------------------------------------------
# 5. Sync toolkit files to latest
# --------------------------------------------------------------------------
info "Syncing toolkit files"
if [ -f ".toolkit-version" ]; then
  toolkit update 2>&1 | grep -E "added|updated|Already" | head -5 | while read -r line; do
    ok "$line"
  done
  ok "toolkit files up to date"
else
  warn "No .toolkit-version found — this project hasn't been bootstrapped."
  warn "Run: toolkit new $(pwd)"
fi

# --------------------------------------------------------------------------
# 6. Pre-commit hooks
# --------------------------------------------------------------------------
info "Setting up git hooks"
if [ -f ".pre-commit-config.yaml" ]; then
  pre-commit install --install-hooks 2>&1 | tail -1 | while read -r line; do ok "$line"; done
  pre-commit install --hook-type commit-msg 2>&1 | tail -1 | while read -r line; do ok "$line"; done
  ok "pre-commit hooks installed"
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

# --------------------------------------------------------------------------
# 8. Project dependencies
# --------------------------------------------------------------------------
info "Installing project dependencies"
if [ -f "pnpm-lock.yaml" ] && command -v pnpm >/dev/null 2>&1; then
  pnpm install 2>&1 | tail -1 | while read -r line; do ok "$line"; done
elif [ -f "package-lock.json" ] && command -v npm >/dev/null 2>&1; then
  npm install 2>&1 | tail -1 | while read -r line; do ok "$line"; done
elif [ -f "package.json" ]; then
  if command -v pnpm >/dev/null 2>&1; then
    pnpm install 2>&1 | tail -1 | while read -r line; do ok "$line"; done
  elif command -v npm >/dev/null 2>&1; then
    npm install 2>&1 | tail -1 | while read -r line; do ok "$line"; done
  fi
elif [ -f "requirements.txt" ]; then
  pip install -r requirements.txt 2>&1 | tail -1 | while read -r line; do ok "$line"; done
elif [ -f "Cargo.toml" ]; then
  ok "Rust project — run: cargo build"
elif [ -f "Package.swift" ]; then
  ok "Swift project — run: swift build"
elif [ -f "go.mod" ]; then
  go mod download 2>&1 && ok "Go modules downloaded"
else
  ok "No recognized dependency file — skipping"
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
