#!/usr/bin/env bash
#
# hooks/codex-review.sh — non-interactive Codex review + auto-fix loop,
# run as a pre-push hook. Wired into .pre-commit-config.yaml.
#
# Loop:
#   1. Run `codex exec --full-auto` against the local diff vs the default branch
#   2. If Codex says CODEX_REVIEW_CLEAN → push allowed.
#   3. If Codex says CODEX_REVIEW_FIXED → it edited files. Stage + commit
#      the fixes (a new commit, NOT an amend) and loop back to step 1.
#   4. If Codex says CODEX_REVIEW_BLOCKED → push aborts, findings printed.
#   5. After max_iterations rounds without converging, push aborts.
#
# Configuration:
#   Place a .codex-review.toml at the repo root to configure behavior.
#   See hooks/codex-review.config.example.toml for the full spec.
#
#   If no .codex-review.toml exists, ALL paths are treated as unsafe
#   (no auto-fix). This is the conservative default — opt in to auto-fix
#   explicitly by listing safe paths or setting safe_by_default = true.
#
# Env overrides:
#   CODEX_REVIEW_BASE             — base ref to diff against (default: origin/<default-branch>)
#   CODEX_REVIEW_MAX_ITERATIONS   — fix loop cap (default: from config, or 3)
#   CODEX_REVIEW_MAX_DIFF_LINES   — skip review if diff > this many lines (default: 5000)
#
# To bypass entirely in an emergency: git push --no-verify
#
# Exit codes:
#   0 — clean review (or graceful skip), push allowed
#   1 — Codex flagged blocking issues OR fix loop did not converge, push aborted
#
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CONFIG_FILE="$REPO_ROOT/.codex-review.toml"

# --------------------------------------------------------------------------
# Configuration loading
# --------------------------------------------------------------------------

# Defaults (conservative: all paths unsafe, no auto-fix unless configured)
SAFE_BY_DEFAULT=false
MAX_ITERATIONS="${CODEX_REVIEW_MAX_ITERATIONS:-3}"
MAX_DIFF_LINES="${CODEX_REVIEW_MAX_DIFF_LINES:-5000}"
UNSAFE_PATHS=""

# Parse .codex-review.toml if it exists.
# We do minimal TOML parsing in bash — just key = value pairs, no nested tables.
# For arrays, we handle the single-line [...] format.
if [ -f "$CONFIG_FILE" ]; then
  while IFS= read -r line; do
    # Strip comments and trim whitespace
    line="$(echo "$line" | sed 's/#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue

    case "$line" in
      max_iterations*=*)
        MAX_ITERATIONS="${CODEX_REVIEW_MAX_ITERATIONS:-$(echo "$line" | sed 's/.*=[[:space:]]*//')}"
        ;;
      max_diff_lines*=*)
        MAX_DIFF_LINES="${CODEX_REVIEW_MAX_DIFF_LINES:-$(echo "$line" | sed 's/.*=[[:space:]]*//')}"
        ;;
      safe_by_default*=*)
        val="$(echo "$line" | sed 's/.*=[[:space:]]*//' | tr '[:upper:]' '[:lower:]')"
        SAFE_BY_DEFAULT="$val"
        ;;
      unsafe_paths*=*)
        # Extract array contents: unsafe_paths = ["path1", "path2"]
        UNSAFE_PATHS="$(echo "$line" | sed 's/.*\[//' | sed 's/\]//' | tr ',' '\n' | sed 's/[[:space:]]*"//g' | sed "s/[[:space:]]*'//g" | sed '/^$/d')"
        ;;
    esac
  done < "$CONFIG_FILE"
fi

# Resolve default branch
if command -v gh >/dev/null 2>&1; then
  DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo main)"
else
  DEFAULT_BRANCH="main"
fi
BASE="${CODEX_REVIEW_BASE:-origin/$DEFAULT_BRANCH}"

# --------------------------------------------------------------------------
# Build the auto-fix policy section of the prompt from config
# --------------------------------------------------------------------------

build_autofix_policy() {
  local policy=""

  if [ "$SAFE_BY_DEFAULT" = "true" ]; then
    policy="By default, all paths are SAFE to auto-fix unless listed as unsafe."
  else
    policy="By default, all paths are NOT safe to auto-fix. Only fix issues in paths explicitly marked as safe."
  fi

  if [ -n "$UNSAFE_PATHS" ]; then
    policy="$policy

NOT safe to auto-fix — STOP and emit BLOCKED instead:
$(echo "$UNSAFE_PATHS" | while read -r p; do [ -n "$p" ] && echo "- Anything in $p"; done)"
  fi

  policy="$policy

General auto-fix rules:
SAFE to auto-fix (apply the smallest possible change, then emit FIXED):
- Typos in comments / docstrings / log messages
- Missing null checks on optional fields
- Missing error logging on exception handlers (except: pass -> except Exception as e: logger.warning(...))
- Adding missing imports for symbols that are clearly used
- Replacing magic-number values with named constants in non-critical code

NOT safe to auto-fix regardless of path (STOP and emit BLOCKED):
- Anything that removes or weakens an existing test
- Anything that changes business logic or calculation semantics
- Anything where the fix requires a design decision (which of two approaches is right)
- Anything you're not at least 90% confident about

When in doubt, STOP and emit BLOCKED."

  echo "$policy"
}

# --------------------------------------------------------------------------
# Pre-flight checks
# --------------------------------------------------------------------------

# Graceful skip if Codex CLI not installed.
if ! command -v codex >/dev/null 2>&1; then
  echo "==> codex CLI not installed — skipping Codex review."
  echo "    Install with: npm install -g @openai/codex && codex login"
  exit 0
fi

# Fetch latest base ref (silent on failure — offline, rebasing, etc.)
git fetch origin "$DEFAULT_BRANCH" --quiet 2>/dev/null || true

# Find merge base so we review only this branch's commits.
if ! MERGE_BASE="$(git merge-base "$BASE" HEAD 2>/dev/null)"; then
  echo "==> Couldn't find merge base with $BASE — skipping Codex review."
  exit 0
fi

# Skip if no changes vs base.
if git diff --quiet "$MERGE_BASE"..HEAD; then
  echo "==> No changes vs $BASE — skipping Codex review."
  exit 0
fi

# --------------------------------------------------------------------------
# Build the review prompt
# --------------------------------------------------------------------------

AUTOFIX_POLICY="$(build_autofix_policy)"

read -r -d '' REVIEW_PROMPT <<PROMPT_EOF || true
You are reviewing AND optionally auto-fixing a pull request before it is pushed.

Read AGENTS.md at the repo root for the full review rubric (if it exists).
Read CLAUDE.md at the repo root for project context (if it exists).

Do NOT flag: formatting, style, naming, missing docstrings, speculative refactors, "you could consider" observations without a concrete bug.

Examine the diff vs $BASE using your tools.

## Auto-fix policy

$AUTOFIX_POLICY

## Output contract — strict

The LAST line of your output must be exactly one of these three sentinels (no extra characters, no trailing whitespace):

- CODEX_REVIEW_CLEAN — no blocking issues found, push should proceed
- CODEX_REVIEW_FIXED — you applied auto-fixes, script will commit and re-review
- CODEX_REVIEW_BLOCKED — you found blocking issues you cannot/should not auto-fix

If you emit CODEX_REVIEW_BLOCKED, list each blocking issue on its own line in the format:
- path/to/file.py:LINE — short description of what's wrong

If you emit CODEX_REVIEW_FIXED, briefly describe what you fixed (one line per fix).

Do not invent new sentinels. Do not output anything after the sentinel line.
PROMPT_EOF

# --------------------------------------------------------------------------
# Review loop
# --------------------------------------------------------------------------

FIX_COMMITS=0

# Colors (respect NO_COLOR).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_BOLD='\033[1m' C_DIM='\033[2m' C_GREEN='\033[0;32m'
  C_YELLOW='\033[0;33m' C_RED='\033[0;31m' C_CYAN='\033[0;36m' C_RESET='\033[0m'
else
  C_BOLD='' C_DIM='' C_GREEN='' C_YELLOW='' C_RED='' C_CYAN='' C_RESET=''
fi

printf "${C_CYAN}"
cat <<'BANNER'

  ╔══════════════════════════════════════╗
  ║         ⚡ TOOLKIT REVIEW ⚡        ║
  ║      Codex pre-push code review      ║
  ╚══════════════════════════════════════╝

BANNER
printf "${C_RESET}"

for iter in $(seq 1 "$MAX_ITERATIONS"); do
  DIFF_LINE_COUNT="$(git diff "$MERGE_BASE"..HEAD | wc -l | tr -d ' ')"
  if [ "$DIFF_LINE_COUNT" -gt "$MAX_DIFF_LINES" ]; then
    echo "==> Diff is $DIFF_LINE_COUNT lines (> $MAX_DIFF_LINES cap) — skipping review."
    echo "    Override with: CODEX_REVIEW_MAX_DIFF_LINES=100000 git push"
    exit 0
  fi

  printf "  ${C_DIM}iteration ${iter}/${MAX_ITERATIONS} · ${DIFF_LINE_COUNT} lines vs ${BASE}${C_RESET}\n"

  set +e
  OUTPUT="$(codex exec --full-auto --ephemeral "$REVIEW_PROMPT" 2>/dev/null)"
  EXIT=$?
  set -e

  if [ $EXIT -ne 0 ]; then
    echo "==> codex exec failed with exit $EXIT — not blocking push."
    echo "    If this keeps happening, check: codex login status, API quota, network."
    exit 0
  fi

  LAST_LINE="$(printf '%s\n' "$OUTPUT" | tail -1 | tr -d '\r ')"
  case "$LAST_LINE" in
    CODEX_REVIEW_CLEAN)
      echo ""
      printf "${C_GREEN}"
      cat <<'PASS'
  ╔══════════════════════════════════════╗
  ║           ✅ ALL CLEAR              ║
  ║         Push approved.              ║
  ╚══════════════════════════════════════╝
PASS
      printf "${C_RESET}"
      if [ "$FIX_COMMITS" -gt 0 ]; then
        printf "  ${C_DIM}($FIX_COMMITS auto-fix commit(s) applied)${C_RESET}\n"
      fi
      echo ""
      exit 0
      ;;

    CODEX_REVIEW_FIXED)
      if [ -z "$(git status --porcelain)" ]; then
        echo "==> Codex emitted FIXED but no working-tree changes detected."
        echo "    Treating as ambiguous — not blocking push."
        exit 0
      fi

      printf "\n  ${C_YELLOW}🔧 Auto-fixing...${C_RESET}\n\n"
      git diff --stat
      echo ""

      git add -A
      git commit -m "fix: address Codex review findings (auto, iter $iter)"
      FIX_COMMITS=$((FIX_COMMITS + 1))
      echo "==> Created fix commit $(git rev-parse --short HEAD). Re-running review on new HEAD..."
      echo ""
      continue
      ;;

    CODEX_REVIEW_BLOCKED)
      echo ""
      printf "${C_RED}"
      cat <<'BLOCKED'
  ╔══════════════════════════════════════╗
  ║          🚫 PUSH BLOCKED           ║
  ║    Codex found issues to address    ║
  ╚══════════════════════════════════════╝
BLOCKED
      printf "${C_RESET}"
      echo ""
      printf '%s\n' "$OUTPUT" | sed 's/^/    /'
      echo ""
      if [ "$FIX_COMMITS" -gt 0 ]; then
        echo "    Note: Codex made $FIX_COMMITS fix commit(s) earlier this run that are still in your local history."
        echo "    To undo them: git reset --hard HEAD~$FIX_COMMITS"
      fi
      echo "    Address findings and try again. Emergency override: git push --no-verify"
      exit 1
      ;;

    *)
      echo "==> Codex output did not match the expected sentinel contract — not blocking push."
      echo "    Last line was: '$LAST_LINE'"
      echo "    Raw output (first 20 lines):"
      printf '%s\n' "$OUTPUT" | head -20 | sed 's/^/    /'
      exit 0
      ;;
  esac
done

echo ""
echo "==> Codex review loop did not converge after $MAX_ITERATIONS iterations."
echo "    Codex made $FIX_COMMITS fix commit(s) but kept finding new issues."
echo "    Push aborted. Investigate manually:"
echo "      git log --oneline -$((MAX_ITERATIONS + 1))"
echo "      git diff HEAD~$FIX_COMMITS..HEAD"
echo ""
echo "    To undo all auto-fix commits: git reset --hard HEAD~$FIX_COMMITS"
echo "    Emergency override: git push --no-verify"
exit 1
