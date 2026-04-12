#!/usr/bin/env bash
#
# hooks/codex-review.sh — non-interactive AI code review + auto-fix loop.
# Supports multiple reviewers (Codex, Claude, Gemini) with a configurable
# fallback cascade. Wired into merge-pr.sh and default-branch pre-push checks.
#
# Loop:
#   1. Run the selected reviewer against the local diff vs the default branch
#   2. If reviewer says CODEX_REVIEW_CLEAN → push allowed.
#   3. If reviewer says CODEX_REVIEW_FIXED → it edited files. Stage + commit
#      the fixes (a new commit, NOT an amend) and loop back to step 1.
#   4. If reviewer says CODEX_REVIEW_BLOCKED → push aborts, findings printed.
#   5. After max_iterations rounds without converging, push aborts.
#
# Reviewer cascade:
#   The [review] section in .codex-review.toml lists reviewers to try in order.
#   The first reviewer that is installed and authenticated wins.
#   If no [review] section exists, defaults to ["codex"] (backward compatible).
#
# Configuration:
#   Place a .codex-review.toml at the repo root to configure behavior.
#   See hooks/codex-review.config.example.toml for the full spec.
#
#   If no .codex-review.toml exists, ALL paths are treated as unsafe
#   (no auto-fix). This is the conservative default — opt in to auto-fix
#   explicitly by listing safe paths or setting safe_by_default = true.
#
# Modes:
#   review-only — reviewer can read + run commands, but cannot edit files or commit
#   fix         — full access: reviewer can edit, stage, and commit auto-fixes
#   diff-only   — read-only: reviewer can only read files, no commands or edits
#   no-tests    — reviewer can edit and commit, but cannot run commands (no test execution)
#
#   Modes are enforced at the wrapper level (tool restrictions, sandboxes), not just
#   in the prompt. Set via CODEX_REVIEW_MODE env var or `mode` in .codex-review.toml.
#
# Env overrides:
#   TOOLKIT_REVIEWER              — force a specific reviewer (skips cascade, hard-fails if unavailable)
#   CODEX_REVIEW_MODE             — review-only|fix|diff-only|no-tests (default: fix)
#   CODEX_REVIEW_BASE             — base ref to diff against (default: origin/<default-branch>)
#   CODEX_REVIEW_MAX_ITERATIONS   — fix loop cap (default: from config, or 3)
#   CODEX_REVIEW_MAX_DIFF_LINES   — skip review if diff > this many lines (default: 5000)
#   CODEX_REVIEW_CACHE_CLEAN      — cache exact-input clean reviews (default: true)
#   CODEX_REVIEW_DISABLE_CACHE    — set to true/1 to force a fresh review
#   CODEX_REVIEW_FORCE            — set to true/1 to run even on non-default-branch pushes
#   CODEX_REVIEW_NO_AUTOFIX       — set to true/1 for review-only mode (backward compat)
#   CODEX_REVIEW_IN_PROGRESS      — internal guard to skip nested review runs
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
cd "$REPO_ROOT"

# --------------------------------------------------------------------------
# Configuration loading
# --------------------------------------------------------------------------

# Defaults (conservative: all paths unsafe, no auto-fix unless configured)
SAFE_BY_DEFAULT=false
MAX_ITERATIONS="${CODEX_REVIEW_MAX_ITERATIONS:-3}"
MAX_DIFF_LINES="${CODEX_REVIEW_MAX_DIFF_LINES:-5000}"
CACHE_CLEAN_REVIEWS="${CODEX_REVIEW_CACHE_CLEAN:-true}"
NO_AUTOFIX="${CODEX_REVIEW_NO_AUTOFIX:-false}"
CONFIG_MODE=""
UNSAFE_PATHS=""
REVIEWER_CASCADE=()

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

strip_toml_comment() {
  local line="$1"
  local out=""
  local char
  local in_single=false
  local in_double=false
  local len="${#line}"
  local i=0

  while [ "$i" -lt "$len" ]; do
    char="${line:$i:1}"

    if [ "$in_double" = true ] && [ "$char" = "\\" ]; then
      out="$out$char"
      i=$((i + 1))
      if [ "$i" -lt "$len" ]; then
        char="${line:$i:1}"
        out="$out$char"
      fi
      i=$((i + 1))
      continue
    fi

    if [ "$char" = '"' ] && [ "$in_single" = false ]; then
      if [ "$in_double" = true ]; then
        in_double=false
      else
        in_double=true
      fi
    elif [ "$char" = "'" ] && [ "$in_double" = false ]; then
      if [ "$in_single" = true ]; then
        in_single=false
      else
        in_single=true
      fi
    elif [ "$char" = "#" ] && [ "$in_single" = false ] && [ "$in_double" = false ]; then
      break
    fi

    out="$out$char"
    i=$((i + 1))
  done

  printf '%s' "$out"
}

append_unsafe_path() {
  local value="$1"
  value="$(trim "$value")"
  value="${value%,}"
  value="$(trim "$value")"

  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac

  [ -z "$value" ] && return

  if [ -n "$UNSAFE_PATHS" ]; then
    UNSAFE_PATHS="${UNSAFE_PATHS}
$value"
  else
    UNSAFE_PATHS="$value"
  fi
}

append_unsafe_paths_csv() {
  local csv="$1"
  local item
  local -a items=()

  [ -n "$csv" ] || return 0

  IFS=',' read -r -a items <<< "$csv"
  for item in "${items[@]}"; do
    append_unsafe_path "$item"
  done
}

append_reviewer() {
  local value="$1"
  value="$(trim "$value")"
  value="${value%,}"
  value="$(trim "$value")"
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  [ -z "$value" ] && return
  REVIEWER_CASCADE+=("$value")
}

append_reviewers_csv() {
  local csv="$1" item
  local -a items=()
  [ -n "$csv" ] || return 0
  IFS=',' read -r -a items <<< "$csv"
  for item in "${items[@]}"; do
    append_reviewer "$item"
  done
}

normalize_bool() {
  local value="$1"
  value="$(trim "$value")"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    true|1|yes|on) printf 'true' ;;
    false|0|no|off) printf 'false' ;;
    *) printf '%s' "$value" ;;
  esac
}

is_truthy() {
  case "$(normalize_bool "${1:-false}")" in
    true) return 0 ;;
    *) return 1 ;;
  esac
}

# Parse .codex-review.toml if it exists.
# We do minimal TOML parsing in bash — just key = value pairs and string arrays.
if [ -f "$CONFIG_FILE" ]; then
  IN_UNSAFE_PATHS=false
  IN_REVIEWERS=false
  CURRENT_SECTION=""
  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    # Strip comments and trim whitespace
    line="$(trim "$(strip_toml_comment "$raw_line")")"
    [ -z "$line" ] && continue

    # Track TOML section headers.
    if [[ "$line" == "["*"]" ]]; then
      IN_UNSAFE_PATHS=false
      IN_REVIEWERS=false
      CURRENT_SECTION="${line#\[}"
      CURRENT_SECTION="${CURRENT_SECTION%\]}"
      CURRENT_SECTION="$(trim "$CURRENT_SECTION")"
      continue
    fi

    # Continue multiline arrays regardless of section.
    if [ "$IN_UNSAFE_PATHS" = true ]; then
      if [[ "$line" == *"]"* ]]; then
        append_unsafe_paths_csv "${line%%]*}"
        IN_UNSAFE_PATHS=false
      else
        append_unsafe_path "$line"
      fi
      continue
    fi
    if [ "$IN_REVIEWERS" = true ]; then
      if [[ "$line" == *"]"* ]]; then
        append_reviewers_csv "${line%%]*}"
        IN_REVIEWERS=false
      else
        append_reviewer "$line"
      fi
      continue
    fi

    # Parse [review] section keys.
    if [ "$CURRENT_SECTION" = "review" ]; then
      case "$line" in
        reviewers*=*)
          array_value="$(trim "${line#*=}")"
          array_value="${array_value#\[}"
          if [[ "$array_value" == *"]"* ]]; then
            append_reviewers_csv "${array_value%%]*}"
          else
            append_reviewers_csv "$array_value"
            IN_REVIEWERS=true
          fi
          ;;
      esac
      continue
    fi

    # Parse [codex_review] section keys (also matches when no section header
    # has been seen yet, for backward compatibility with existing configs).
    case "$line" in
      max_iterations*=*)
        MAX_ITERATIONS="${CODEX_REVIEW_MAX_ITERATIONS:-$(trim "${line#*=}")}"
        ;;
      max_diff_lines*=*)
        MAX_DIFF_LINES="${CODEX_REVIEW_MAX_DIFF_LINES:-$(trim "${line#*=}")}"
        ;;
      cache_clean_reviews*=*)
        CACHE_CLEAN_REVIEWS="${CODEX_REVIEW_CACHE_CLEAN:-$(normalize_bool "${line#*=}")}"
        ;;
      safe_by_default*=*)
        val="$(trim "${line#*=}")"
        val="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
        SAFE_BY_DEFAULT="$val"
        ;;
      mode*=*)
        val="$(trim "${line#*=}")"
        val="${val%\"}"; val="${val#\"}"
        val="${val%\'}"; val="${val#\'}"
        CONFIG_MODE="$val"
        ;;
      unsafe_paths*=*)
        array_value="$(trim "${line#*=}")"
        array_value="${array_value#\[}"
        if [[ "$array_value" == *"]"* ]]; then
          append_unsafe_paths_csv "${array_value%%]*}"
        else
          append_unsafe_paths_csv "$array_value"
          IN_UNSAFE_PATHS=true
        fi
        ;;
    esac
  done < "$CONFIG_FILE"
fi

resolve_default_branch() {
  local local_ref

  local_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$local_ref" ]; then
    printf '%s\n' "${local_ref#origin/}"
    return 0
  fi

  if command -v gh >/dev/null 2>&1; then
    gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo main
  else
    echo main
  fi
}

DEFAULT_BRANCH="$(resolve_default_branch)"
BASE="${CODEX_REVIEW_BASE:-origin/$DEFAULT_BRANCH}"
NO_AUTOFIX="$(normalize_bool "$NO_AUTOFIX")"

# Default reviewer cascade: codex-only (backward compat with existing configs).
if [ "${#REVIEWER_CASCADE[@]}" -eq 0 ]; then
  REVIEWER_CASCADE=("codex")
fi

# TOOLKIT_REVIEWER env var overrides the cascade with a single forced reviewer.
if [ -n "${TOOLKIT_REVIEWER:-}" ]; then
  REVIEWER_CASCADE=("$TOOLKIT_REVIEWER")
fi

# --------------------------------------------------------------------------
# Mode resolution
# --------------------------------------------------------------------------
# Modes: review-only, fix, diff-only, no-tests
#   review-only — read + bash, no edits, no git ops (default for merge review)
#   fix         — full access, auto-fix + commit (default for pre-push)
#   diff-only   — read-only, no bash, no edits
#   no-tests    — edit + commit, no bash (skip test execution)

resolve_mode() {
  local mode="${CODEX_REVIEW_MODE:-}"

  # Backward compat: NO_AUTOFIX=true maps to review-only
  if [ -z "$mode" ] && is_truthy "$NO_AUTOFIX"; then
    mode="review-only"
  fi

  # Fall back to config, then default
  [ -n "$mode" ] || mode="${CONFIG_MODE:-fix}"

  case "$mode" in
    review-only|fix|diff-only|no-tests) ;;
    *)
      echo "ERROR: Invalid mode '$mode'. Valid: review-only, fix, diff-only, no-tests" >&2
      exit 2
      ;;
  esac
  printf '%s' "$mode"
}

REVIEW_MODE="$(resolve_mode)"

mode_allows_fix()  { [ "$REVIEW_MODE" = "fix" ] || [ "$REVIEW_MODE" = "no-tests" ]; }
mode_allows_bash() { [ "$REVIEW_MODE" = "fix" ] || [ "$REVIEW_MODE" = "review-only" ]; }

short_ref_name() {
  local ref="$1"
  ref="${ref#refs/heads/}"
  ref="${ref#refs/remotes/origin/}"
  printf '%s' "$ref"
}

is_pre_push_hook() {
  [ "${PRE_COMMIT:-}" = "1" ] && [ -n "${PRE_COMMIT_REMOTE_BRANCH:-}" ]
}

should_skip_pre_push_review() {
  local remote_branch default_branch

  is_pre_push_hook || return 1
  is_truthy "${CODEX_REVIEW_FORCE:-false}" && return 1

  remote_branch="$(short_ref_name "$PRE_COMMIT_REMOTE_BRANCH")"
  default_branch="$(short_ref_name "$DEFAULT_BRANCH")"

  if [ "$remote_branch" = "$default_branch" ]; then
    return 1
  fi

  echo "==> Review runs on pushes to $default_branch only — skipping push to $remote_branch."
  echo "    Force review with: CODEX_REVIEW_FORCE=1 git push"
  return 0
}

# --------------------------------------------------------------------------
# Build the auto-fix policy section of the prompt from config
# --------------------------------------------------------------------------

build_autofix_policy() {
  local policy=""

  if ! mode_allows_fix; then
    cat <<POLICY_EOF
Mode: $REVIEW_MODE — do not edit files. Do not stage, commit, or modify anything.

Review only:
- If there are no blocking issues, emit CLEAN.
- If any issue needs a code or documentation change, emit BLOCKED with findings.
- Do not emit FIXED.

When in doubt, STOP and emit BLOCKED.
POLICY_EOF
    return 0
  fi

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

  if [ "${WORKTREE_DIRTY_BEFORE_REVIEW:-false}" = true ]; then
    policy="$policy

The working tree already has uncommitted changes. Do not edit files in this run; emit BLOCKED for issues that need changes."
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
# Reviewer adapters
# --------------------------------------------------------------------------
# Each reviewer exposes three functions:
#   reviewer_<id>_available  — exit 0 if the CLI is installed
#   reviewer_<id>_auth_ok    — exit 0 if auth is configured
#   reviewer_<id>_exec PROMPT — run the review; stdout = output, exit code = success

reviewer_codex_available() { command -v codex >/dev/null 2>&1; }
reviewer_codex_auth_ok()   { codex login status >/dev/null 2>&1; }
reviewer_codex_exec() {
  # Codex sandbox: read-only (no file writes) or workspace-write (edits allowed).
  # Codex cannot selectively disable command execution, so diff-only and no-tests
  # degrade: diff-only → read-only sandbox, no-tests → workspace-write sandbox.
  # The prompt still instructs the reviewer, but enforcement is filesystem-only.
  local sandbox="read-only"
  if [ "$REVIEW_MODE" = "fix" ] || [ "$REVIEW_MODE" = "no-tests" ]; then
    sandbox="workspace-write"
  fi
  if [ "$REVIEW_MODE" = "diff-only" ] || [ "$REVIEW_MODE" = "no-tests" ]; then
    printf "  ${C_DIM}(codex: '%s' enforced via sandbox=%s + prompt; command restriction is prompt-level only)${C_RESET}\n" \
      "$REVIEW_MODE" "$sandbox" >&2
  fi
  CODEX_REVIEW_IN_PROGRESS=1 codex exec \
    --sandbox "$sandbox" --ephemeral "$1" 2>/dev/null
}

reviewer_claude_available() { command -v claude >/dev/null 2>&1; }
reviewer_claude_auth_ok()   { claude auth status >/dev/null 2>&1; }
reviewer_claude_exec() {
  # Claude has fine-grained --allowedTools: all four modes are fully enforced.
  local tools
  case "$REVIEW_MODE" in
    diff-only)    tools="Read,Grep,Glob" ;;
    review-only)  tools="Read,Grep,Glob,Bash" ;;
    no-tests)     tools="Read,Grep,Glob,Edit,Write" ;;
    fix)          tools="Read,Grep,Glob,Bash,Edit,Write" ;;
  esac
  CODEX_REVIEW_IN_PROGRESS=1 claude -p \
    --allowedTools "$tools" \
    --output-format text \
    "$1" 2>/dev/null
}

reviewer_gemini_available() { command -v gemini >/dev/null 2>&1; }
reviewer_gemini_auth_ok() {
  [ -n "${GEMINI_API_KEY:-}" ] && return 0
  command -v gcloud >/dev/null 2>&1 && gcloud auth print-access-token >/dev/null 2>&1
}
reviewer_gemini_exec() {
  # Gemini: --yolo (full auto-approve) or not (no auto-approve).
  # Only fix mode uses --yolo. diff-only, review-only, and no-tests all run
  # without --yolo. no-tests cannot be fully enforced (edits without commands)
  # since Gemini lacks granular tool control.
  if [ "$REVIEW_MODE" = "fix" ]; then
    CODEX_REVIEW_IN_PROGRESS=1 gemini -p "$1" --yolo 2>/dev/null
  else
    if [ "$REVIEW_MODE" = "no-tests" ]; then
      printf "  ${C_DIM}(gemini: 'no-tests' mode degrades to review-only; gemini lacks granular tool control)${C_RESET}\n" >&2
    fi
    CODEX_REVIEW_IN_PROGRESS=1 gemini -p "$1" 2>/dev/null
  fi
}

# --------------------------------------------------------------------------
# Reviewer cascade resolver
# --------------------------------------------------------------------------

ACTIVE_REVIEWER=""
REVIEWER_STATUS=""

resolve_reviewer() {
  local reviewer
  ACTIVE_REVIEWER=""
  REVIEWER_STATUS=""

  for reviewer in "${REVIEWER_CASCADE[@]}"; do
    if ! "reviewer_${reviewer}_available"; then
      REVIEWER_STATUS="${REVIEWER_STATUS}    ${reviewer}: CLI not installed\n"
      continue
    fi
    if ! "reviewer_${reviewer}_auth_ok"; then
      REVIEWER_STATUS="${REVIEWER_STATUS}    ${reviewer}: auth check failed\n"
      continue
    fi
    ACTIVE_REVIEWER="$reviewer"
    return 0
  done

  return 1
}

run_reviewer() {
  "reviewer_${ACTIVE_REVIEWER}_exec" "$1"
}

reviewer_label() {
  case "$ACTIVE_REVIEWER" in
    codex)  printf 'Codex' ;;
    claude) printf 'Claude' ;;
    gemini) printf 'Gemini' ;;
    *)      printf '%s' "$ACTIVE_REVIEWER" ;;
  esac
}

# --------------------------------------------------------------------------
# Pre-flight checks
# --------------------------------------------------------------------------

# Feature-branch pushes should stay fast. Manual invocations and direct pushes
# to the default branch still run the review.
if is_truthy "${CODEX_REVIEW_IN_PROGRESS:-false}"; then
  echo "==> Review already in progress — skipping nested review."
  exit 0
fi

if should_skip_pre_push_review; then
  exit 0
fi

# Resolve which reviewer to use from the cascade.
if ! resolve_reviewer; then
  if [ -n "${TOOLKIT_REVIEWER:-}" ]; then
    echo "ERROR: TOOLKIT_REVIEWER=$TOOLKIT_REVIEWER but that reviewer is not available:" >&2
    printf '%b' "$REVIEWER_STATUS" >&2
    exit 1
  fi
  echo "==> No reviewer available — skipping review."
  printf '%b' "$REVIEWER_STATUS"
  echo "    Install at least one: codex, claude, or gemini CLI."
  exit 0
fi
REVIEWER_LABEL="$(reviewer_label)"
echo "==> Using reviewer: $REVIEWER_LABEL"

# Fetch latest base ref for the default review target (silent on failure —
# offline, rebasing, etc.). If CODEX_REVIEW_BASE is set, trust the caller.
if [ -z "${CODEX_REVIEW_BASE:-}" ]; then
  git fetch origin "$DEFAULT_BRANCH" --quiet 2>/dev/null || true
fi

# Find merge base so we review only this branch's commits.
if ! MERGE_BASE="$(git merge-base "$BASE" HEAD 2>/dev/null)"; then
  echo "==> Couldn't find merge base with $BASE — skipping review."
  exit 0
fi

# Skip if no changes vs base.
if git diff --quiet "$MERGE_BASE"..HEAD; then
  echo "==> No changes vs $BASE — skipping review."
  exit 0
fi

WORKTREE_DIRTY_BEFORE_REVIEW=false
if [ -n "$(git status --porcelain)" ]; then
  WORKTREE_DIRTY_BEFORE_REVIEW=true
fi

# --------------------------------------------------------------------------
# Build the review prompt
# --------------------------------------------------------------------------

AUTOFIX_POLICY="$(build_autofix_policy)"

read -r -d '' REVIEW_PROMPT <<PROMPT_EOF || true
You are reviewing AND optionally auto-fixing a pull request before it reaches the default branch.

Read AGENTS.md at the repo root for the full review rubric (if it exists).
Read CLAUDE.md at the repo root for project context (if it exists).

Do NOT flag: formatting, style, naming, missing docstrings, speculative refactors, "you could consider" observations without a concrete bug.

Examine the diff vs $BASE using your tools.
$(if [ "$REVIEW_MODE" = "diff-only" ]; then
printf '\n## Diff (included because mode=diff-only restricts tool access)\n\n```\n'
git diff "$MERGE_BASE"..HEAD 2>/dev/null | head -2000
printf '```\n'
fi)

## Auto-fix policy

$AUTOFIX_POLICY

## Output contract — strict

The LAST line of your output must be exactly one of these three sentinels (no extra characters, no trailing whitespace):

- CODEX_REVIEW_CLEAN — no blocking issues found, operation should proceed
- CODEX_REVIEW_FIXED — you applied auto-fixes, script will commit and re-review
- CODEX_REVIEW_BLOCKED — you found blocking issues you cannot/should not auto-fix

If you emit CODEX_REVIEW_BLOCKED, list each blocking issue on its own line in the format:
- path/to/file.py:LINE — short description of what's wrong

If you emit CODEX_REVIEW_FIXED, briefly describe what you fixed (one line per fix).

Do not invent new sentinels. Do not output anything after the sentinel line.
PROMPT_EOF

# --------------------------------------------------------------------------
# Clean-review cache
# --------------------------------------------------------------------------

cache_enabled() {
  case "$(normalize_bool "${CODEX_REVIEW_DISABLE_CACHE:-false}")" in
    true) return 1 ;;
  esac

  case "$(normalize_bool "$CACHE_CLEAN_REVIEWS")" in
    true) return 0 ;;
    *) return 1 ;;
  esac
}

hash_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    cksum | awk '{print $1 "-" $2}'
  fi
}

append_cache_file() {
  local label="$1"
  local path="$2"

  printf '\n-- %s --\n' "$label"
  if [ -f "$path" ]; then
    cat "$path"
  else
    printf '<missing>\n'
  fi
}

review_cache_key() {
  {
    printf 'toolkit-codex-review-cache-v2\n'
    printf 'reviewer=%s\n' "$ACTIVE_REVIEWER"
    printf 'base=%s\n' "$BASE"
    printf 'merge_base=%s\n' "$MERGE_BASE"
    printf 'worktree_dirty_before_review=%s\n' "$WORKTREE_DIRTY_BEFORE_REVIEW"
    printf '\n-- prompt --\n%s\n' "$REVIEW_PROMPT"
    append_cache_file "AGENTS.md" "$REPO_ROOT/AGENTS.md"
    append_cache_file "CLAUDE.md" "$REPO_ROOT/CLAUDE.md"
    append_cache_file ".codex-review.toml" "$CONFIG_FILE"
    append_cache_file "codex-review.sh" "$0"
    printf '\n-- branch diff --\n'
    git diff --binary "$MERGE_BASE"..HEAD
  } | hash_stdin
}

clean_review_cache_dir() {
  git rev-parse --git-path toolkit/codex-review-clean
}

clean_review_cache_file() {
  local key="$1"
  printf '%s/%s.clean' "$(clean_review_cache_dir)" "$key"
}

write_clean_review_cache() {
  local key="$1"
  local line_count="$2"
  local cache_dir cache_file

  [ -n "$key" ] || return 0
  cache_dir="$(clean_review_cache_dir)"
  cache_file="$(clean_review_cache_file "$key")"

  mkdir -p "$cache_dir" 2>/dev/null || return 0
  {
    printf 'result=CODEX_REVIEW_CLEAN\n'
    printf 'base=%s\n' "$BASE"
    printf 'merge_base=%s\n' "$MERGE_BASE"
    printf 'head=%s\n' "$(git rev-parse HEAD 2>/dev/null || echo unknown)"
    printf 'diff_lines=%s\n' "$line_count"
    printf 'reviewed_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$cache_file" 2>/dev/null || true
}

changed_paths() {
  {
    git diff --name-only
    git diff --cached --name-only
    git ls-files --others --exclude-standard
  } | sed '/^$/d' | sort -u
}

path_is_unsafe() {
  local path="$1"
  local unsafe_path

  [ -n "$UNSAFE_PATHS" ] || return 1

  while IFS= read -r unsafe_path; do
    [ -z "$unsafe_path" ] && continue
    case "$unsafe_path" in
      */)
        [[ "$path" == "$unsafe_path"* ]] && return 0
        ;;
      *)
        if [ "$path" = "$unsafe_path" ] || [[ "$path" == "$unsafe_path/"* ]]; then
          return 0
        fi
        ;;
    esac
  done <<< "$UNSAFE_PATHS"

  return 1
}

path_allows_autofix() {
  local path="$1"

  if [ "$SAFE_BY_DEFAULT" != "true" ]; then
    return 1
  fi

  if path_is_unsafe "$path"; then
    return 1
  fi

  return 0
}

disallowed_autofix_paths() {
  local changed="$1"
  local path
  local disallowed=""

  while IFS= read -r path; do
    [ -z "$path" ] && continue
    if ! path_allows_autofix "$path"; then
      if [ -n "$disallowed" ]; then
        disallowed="${disallowed}
$path"
      else
        disallowed="$path"
      fi
    fi
  done <<< "$changed"

  printf '%s' "$disallowed"
}

# --------------------------------------------------------------------------
# Review loop
# --------------------------------------------------------------------------

FIX_COMMITS=0
BANNER_PRINTED=false

# Colors (respect NO_COLOR).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_DIM='\033[2m' C_GREEN='\033[0;32m'
  C_YELLOW='\033[0;33m' C_RED='\033[0;31m' C_CYAN='\033[0;36m' C_RESET='\033[0m'
else
  C_DIM='' C_GREEN='' C_YELLOW='' C_RED='' C_CYAN='' C_RESET=''
fi

print_banner() {
  [ "$BANNER_PRINTED" = false ] || return 0
  local label
  label="$(reviewer_label)"
  printf "${C_CYAN}"
  printf '\n  ╔══════════════════════════════════════╗\n'
  printf '  ║         ⚡ TOOLKIT REVIEW ⚡        ║\n'
  printf '  ║     %s merge code review%s║\n' "$label" "$(printf '%*s' $((23 - ${#label})) '')"
  printf '  ╚══════════════════════════════════════╝\n\n'
  printf "${C_RESET}"
  BANNER_PRINTED=true
}

for iter in $(seq 1 "$MAX_ITERATIONS"); do
  DIFF_LINE_COUNT="$(git diff "$MERGE_BASE"..HEAD | wc -l | tr -d ' ')"
  if [ "$DIFF_LINE_COUNT" -gt "$MAX_DIFF_LINES" ]; then
    echo "==> Diff is $DIFF_LINE_COUNT lines (> $MAX_DIFF_LINES cap) — skipping review."
    echo "    Override with: CODEX_REVIEW_MAX_DIFF_LINES=100000 git push"
    exit 0
  fi

  REVIEW_CACHE_KEY=""
  if cache_enabled; then
    REVIEW_CACHE_KEY="$(review_cache_key 2>/dev/null || true)"
    if [ -n "$REVIEW_CACHE_KEY" ] && [ -f "$(clean_review_cache_file "$REVIEW_CACHE_KEY")" ]; then
      echo "==> Review previously passed for this exact diff — skipping repeat review."
      echo "    Force a fresh review with: CODEX_REVIEW_DISABLE_CACHE=1 git push"
      exit 0
    fi
  fi

  print_banner
  printf "  ${C_DIM}iteration ${iter}/${MAX_ITERATIONS} · ${DIFF_LINE_COUNT} lines vs ${BASE}${C_RESET}\n"

  set +e
  OUTPUT="$(run_reviewer "$REVIEW_PROMPT")"
  EXIT=$?
  set -e

  if [ $EXIT -ne 0 ]; then
    echo "==> $REVIEWER_LABEL review failed with exit $EXIT — not blocking push."
    echo "    If this keeps happening, check auth, API quota, and network."
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
      write_clean_review_cache "$REVIEW_CACHE_KEY" "$DIFF_LINE_COUNT"
      exit 0
      ;;

    CODEX_REVIEW_FIXED)
      if ! mode_allows_fix; then
        echo "==> $REVIEWER_LABEL emitted FIXED in '$REVIEW_MODE' mode."
        echo "    The reviewer was restricted from editing — this should not happen."
        echo "    Inspect the working tree before continuing."
        exit 1
      fi

      AUTOFIX_CHANGED_PATHS="$(changed_paths)"
      if [ -z "$AUTOFIX_CHANGED_PATHS" ]; then
        echo "==> $REVIEWER_LABEL emitted FIXED but no working-tree changes detected."
        echo "    Treating as ambiguous — not blocking push."
        exit 0
      fi

      if [ "$WORKTREE_DIRTY_BEFORE_REVIEW" = true ]; then
        echo "==> $REVIEWER_LABEL emitted FIXED, but the working tree was already dirty before review."
        echo "    Refusing to auto-commit because that could include unrelated local changes."
        echo "    Commit or stash local changes, then push again."
        exit 1
      fi

      DISALLOWED_AUTOFIX_PATHS="$(disallowed_autofix_paths "$AUTOFIX_CHANGED_PATHS")"
      if [ -n "$DISALLOWED_AUTOFIX_PATHS" ]; then
        echo "==> $REVIEWER_LABEL edited paths that are not allowed by .codex-review.toml."
        echo "    Refusing to auto-commit. Review these changes manually:"
        printf '%s\n' "$DISALLOWED_AUTOFIX_PATHS" | sed 's/^/    - /'
        echo "    Inspect the working-tree diff before deciding whether to keep or discard them."
        exit 1
      fi

      printf "\n  ${C_YELLOW}🔧 Auto-fixing...${C_RESET}\n\n"
      git diff --stat
      echo ""

      git add -A
      git commit -m "fix: address $REVIEWER_LABEL review findings (auto, $REVIEW_MODE, iter $iter)"
      WORKTREE_DIRTY_BEFORE_REVIEW=false
      FIX_COMMITS=$((FIX_COMMITS + 1))
      echo "==> Created fix commit $(git rev-parse --short HEAD). Re-running review on new HEAD..."
      echo ""
      continue
      ;;

    CODEX_REVIEW_BLOCKED)
      echo ""
      printf "${C_RED}"
      printf '  ╔══════════════════════════════════════╗\n'
      printf '  ║          🚫 PUSH BLOCKED           ║\n'
      printf '  ║  %s found issues to address%s║\n' "$REVIEWER_LABEL" "$(printf '%*s' $((25 - ${#REVIEWER_LABEL})) '')"
      printf '  ╚══════════════════════════════════════╝\n'
      printf "${C_RESET}"
      echo ""
      printf '%s\n' "$OUTPUT" | sed 's/^/    /'
      echo ""
      if [ "$FIX_COMMITS" -gt 0 ]; then
        echo "    Note: $REVIEWER_LABEL made $FIX_COMMITS fix commit(s) earlier this run that are still in your local history."
        echo "    To undo them: git reset --hard HEAD~$FIX_COMMITS"
      fi
      echo "    Address findings and try again. Emergency override: git push --no-verify"
      exit 1
      ;;

    *)
      echo "==> $REVIEWER_LABEL output did not match the expected sentinel contract — not blocking push."
      echo "    Last line was: '$LAST_LINE'"
      echo "    Raw output (first 20 lines):"
      printf '%s\n' "$OUTPUT" | head -20 | sed 's/^/    /'
      exit 0
      ;;
  esac
done

echo ""
echo "==> Review loop did not converge after $MAX_ITERATIONS iterations."
echo "    $REVIEWER_LABEL made $FIX_COMMITS fix commit(s) but kept finding new issues."
echo "    Push aborted. Investigate manually:"
echo "      git log --oneline -$((MAX_ITERATIONS + 1))"
echo "      git diff HEAD~$FIX_COMMITS..HEAD"
echo ""
echo "    To undo all auto-fix commits: git reset --hard HEAD~$FIX_COMMITS"
echo "    Emergency override: git push --no-verify"
exit 1
