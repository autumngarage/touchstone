#!/usr/bin/env bash
#
# lib/colors.sh — colored output helpers for the Touchstone CLI.
#

# Disable colors if stdout isn't a terminal or NO_COLOR is set.
# shellcheck disable=SC2034  # BLUE kept for palette parity (exported to sourcing
# callers); tk_* helpers below use RED/GREEN/YELLOW/BOLD/DIM/RESET directly.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  DIM='\033[2m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' DIM='' RESET=''
fi

tk_info()    { printf "${BOLD}==> %s${RESET}\n" "$*"; }
tk_ok()      { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
tk_warn()    { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }
tk_fail()    { printf "  ${RED}✗${RESET} %s\n" "$*"; }
tk_dim()     { printf "  ${DIM}%s${RESET}\n" "$*"; }
tk_header()  { printf "\n${BOLD}%s${RESET}\n\n" "$*"; }
