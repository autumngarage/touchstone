#!/usr/bin/env bash
#
# setup.sh — one-command project setup.
#
# Run this after cloning the repo:
#   bash setup.sh
#
set -euo pipefail

echo "==> Setting up $(basename "$(pwd)")"

# 1. Install toolkit if not present.
if command -v toolkit >/dev/null 2>&1; then
  echo "==> toolkit $(toolkit version 2>&1 | head -1 | sed 's/toolkit //')"
else
  echo "==> Installing toolkit..."
  if command -v brew >/dev/null 2>&1; then
    brew tap henrymodisett/toolkit 2>/dev/null || true
    brew install toolkit
  else
    echo "ERROR: Homebrew is required. Install from https://brew.sh" >&2
    exit 1
  fi
fi

# 2. Update toolkit-owned files to latest.
echo "==> Syncing toolkit files..."
toolkit update 2>&1 | grep -E "^==>|added|updated|unchanged" || true

# 3. Install pre-commit hooks.
if command -v pre-commit >/dev/null 2>&1; then
  echo "==> Installing pre-commit hooks..."
  pre-commit install --install-hooks 2>&1 | tail -1
else
  echo "==> pre-commit not installed (optional). Install with: pip install pre-commit"
fi

# 4. Install project dependencies.
if [ -f "package.json" ]; then
  echo "==> Installing Node dependencies..."
  if command -v pnpm >/dev/null 2>&1; then
    pnpm install
  elif command -v npm >/dev/null 2>&1; then
    npm install
  fi
elif [ -f "requirements.txt" ]; then
  echo "==> Installing Python dependencies..."
  pip install -r requirements.txt
elif [ -f "Package.swift" ]; then
  echo "==> Swift project — build with: swift build"
fi

echo ""
echo "==> Done! Run 'toolkit doctor' to verify everything is set up."
