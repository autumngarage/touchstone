#!/usr/bin/env bash
#
# scripts/merge-pr.sh — squash-merge a PR and clean up.
#
# Usage:
#   bash scripts/merge-pr.sh <pr-number>
#   bash scripts/merge-pr.sh <pr-number> --bypass-with-disclosure="<reason>"
#   bash scripts/merge-pr.sh <pr-number> --bypass-with-disclosure="<reason>" --allow-fail-open-marker
#
# What this does:
#   1. Verifies the PR is open and mergeable.
#   2. Verifies PR-visible feedback has no blocking review state.
#   3. Waits for configured PR-triggered AI review, or runs AI code review as a merge gate.
#   4. Re-checks PR-visible feedback on the reviewed head.
#   5. Squash-merges and deletes the remote branch.
#   6. Checks out/syncs the default branch where the local topology permits.
#   7. Deletes the verified-merged local feature branch when safe.
#   8. Removes the merged feature worktree when safe.
#
# Exit codes:
#   0 — merged cleanly
#   1 — merge failed (PR not mergeable, conflicts, etc.)
#   2 — usage / environment error
#
set -euo pipefail

PR_NUMBER=""
BYPASS_REASON=""
BYPASS_MARKER_SOURCE=""
BYPASS_MARKER_EVIDENCE=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_SYNC_GUARD="$SCRIPT_DIR/../lib/script-sync-guard.sh"
if [ -f "$SCRIPT_SYNC_GUARD" ]; then
  # shellcheck source=../lib/script-sync-guard.sh
  source "$SCRIPT_SYNC_GUARD"
  touchstone_script_sync_guard "$0" "$@"
fi
REVIEW_SCRIPT="$SCRIPT_DIR/conductor-review.sh"
if [ ! -f "$REVIEW_SCRIPT" ]; then
  REVIEW_SCRIPT="$SCRIPT_DIR/codex-review.sh"
fi
PREFLIGHT_SCRIPT="$SCRIPT_DIR/../lib/preflight.sh"
REVIEW_COMMENT_SCRIPT="$SCRIPT_DIR/../lib/review-comment.sh"
if [ -f "$SCRIPT_DIR/../lib/events.sh" ]; then
  # shellcheck source=../lib/events.sh
  source "$SCRIPT_DIR/../lib/events.sh"
else
  touchstone_emit_event() { :; }
fi
if [ -f "$PREFLIGHT_SCRIPT" ]; then
  # shellcheck source=../lib/preflight.sh
  source "$PREFLIGHT_SCRIPT"
fi
if [ -f "$REVIEW_COMMENT_SCRIPT" ]; then
  # shellcheck source=../lib/review-comment.sh
  source "$REVIEW_COMMENT_SCRIPT"
fi
REVIEWED_HEAD_OID=""
PR_HEAD_BRANCH=""
BYPASS_REVIEW=false
ALLOW_FAIL_OPEN_MARKER=false
TOUCHSTONE_MERGE_FAILURE_REASON="nonzero-exit"
PREFLIGHT_REQUIRED=true
COMMENT_ON_CLEAN=true
COMMENT_FINDINGS_HISTORY=true
PR_TRIGGERED_REVIEW_REQUIRED=false
PR_TRIGGERED_REVIEW_PROVIDER="github-codex"
PR_TRIGGERED_REVIEW_REQUEST_ON_PUSH=false
PR_TRIGGERED_REVIEW_TIMEOUT_SEC=1800
PR_TRIGGERED_REVIEW_POLL_SEC=10
PR_TRIGGERED_REVIEW_TRUSTED_REVIEW_AUTHORS="chatgpt-codex-connector,chatgpt-codex-connector[bot]"
PR_TRIGGERED_REVIEW_SKIP_MERGE_REVIEW=true
PR_TRIGGERED_REVIEWED_HEAD_OID=""
PR_TRIGGERED_REVIEWED_BASE_OID=""
PR_TRIGGERED_REVIEW_BASE_BOUND=false
PR_TRIGGERED_REVIEW_REQUEST_BASE_OID=""
PR_TRIGGERED_REVIEW_REQUEST_TIMESTAMP=""
PR_TRIGGERED_REVIEW_REQUEST_INTENT_TIMESTAMP=""
PR_TRIGGERED_REVIEW_CANDIDATE_TIMESTAMP=""
PR_TRIGGERED_REVIEW_CANDIDATE_CLEAN=false
PR_TRIGGERED_REVIEW_CANDIDATE_DETAIL=""
PR_TRIGGERED_REVIEW_INSPECTION_ERROR=""
CURRENT_REVIEW_BASE_OID=""
CURRENT_REVIEW_MERGE_BASE_OID=""
REVIEWED_BASE_OID=""
REVIEWED_MERGE_BASE_OID=""
REVIEW_SUMMARY_FILE=""
PREFLIGHT_CACHE_KEY=""
PREFLIGHT_CACHE_FILE=""
PREFLIGHT_CACHE_INPUTS=""
PR_WORKTREE_PATH=""
REPO_FULL_NAME=""
REPO_OWNER=""
REPO_NAME=""
PR_BASE_BRANCH=""
PR_BASE_REF=""
MERGE_REVIEW_CONFIG_TMP_FILES=()
MERGE_REVIEW_CONFIG_FILE=""
TOUCHSTONE_REVIEW_LOG="${TOUCHSTONE_REVIEW_LOG-${HOME:-}/.touchstone-review-log}"
TOUCHSTONE_REVIEW_LOG_MAX_LINES="${TOUCHSTONE_REVIEW_LOG_MAX_LINES:-1000}"
TOUCHSTONE_FAIL_OPEN_BYPASS_WINDOW_HOURS="${TOUCHSTONE_FAIL_OPEN_BYPASS_WINDOW_HOURS:-24}"

on_merge_exit() {
  local rc="$?"
  local tmp_file
  if [ "${#MERGE_REVIEW_CONFIG_TMP_FILES[@]}" -gt 0 ]; then
    for tmp_file in "${MERGE_REVIEW_CONFIG_TMP_FILES[@]}"; do
      rm -f "$tmp_file" 2>/dev/null || true
    done
  fi
  if [ "$rc" -ne 0 ]; then
    touchstone_emit_event failed phase=merge reason="$TOUCHSTONE_MERGE_FAILURE_REASON" pr_number="$PR_NUMBER"
  fi
  return "$rc"
}

trap on_merge_exit EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --bypass-with-disclosure=*)
      BYPASS_REVIEW=true
      BYPASS_REASON="${1#*=}"
      shift
      ;;
    --bypass-with-disclosure)
      echo "ERROR: --bypass-with-disclosure requires a non-empty reason." >&2
      exit 2
      ;;
    --allow-fail-open-marker)
      ALLOW_FAIL_OPEN_MARKER=true
      shift
      ;;
    --*)
      echo "ERROR: Unknown option: $1" >&2
      exit 2
      ;;
    *)
      if [ -n "$PR_NUMBER" ]; then
        echo "ERROR: Unexpected extra argument: $1" >&2
        exit 2
      fi
      PR_NUMBER="$1"
      shift
      ;;
  esac
done

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

csv_contains() {
  local csv="$1"
  local wanted="$2"
  local item
  local -a csv_items

  if [ -n "$csv" ]; then
    IFS=',' read -r -a csv_items <<<"$csv"
    for item in "${csv_items[@]}"; do
      item="$(trim "$item")"
      if [ "$item" = "$wanted" ]; then
        return 0
      fi
    done
  fi
  return 1
}

csv_add_unique() {
  local csv="$1"
  local value="$2"

  value="$(trim "$value")"
  [ -n "$value" ] || {
    printf '%s' "$csv"
    return 0
  }
  [ "$value" != "unknown" ] || {
    printf '%s' "$csv"
    return 0
  }
  [ "$value" != "none" ] || {
    printf '%s' "$csv"
    return 0
  }
  if csv_contains "$csv" "$value"; then
    printf '%s' "$csv"
  elif [ -n "$csv" ]; then
    printf '%s,%s' "$csv" "$value"
  else
    printf '%s' "$value"
  fi
}

summary_string_field() {
  local field="$1"
  [ -n "$REVIEW_SUMMARY_FILE" ] || return 0
  [ -f "$REVIEW_SUMMARY_FILE" ] || return 0
  sed -nE 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$REVIEW_SUMMARY_FILE" 2>/dev/null | head -1
}

summary_number_field() {
  local field="$1"
  [ -n "$REVIEW_SUMMARY_FILE" ] || return 0
  [ -f "$REVIEW_SUMMARY_FILE" ] || return 0
  sed -nE 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$REVIEW_SUMMARY_FILE" 2>/dev/null | head -1
}

review_output_has_concrete_findings() {
  local output_file="$1"
  [ -f "$output_file" ] || return 1
  grep -Eq 'CODEX_REVIEW_BLOCKED|^- ' "$output_file"
}

review_failure_is_infra() {
  local review_rc="$1"
  local output_file="$2"
  local findings exit_reason

  review_output_has_concrete_findings "$output_file" && return 1

  findings="$(summary_number_field findings)"
  if [ -n "$findings" ] && [ "$findings" != "0" ]; then
    return 1
  fi

  exit_reason="$(summary_string_field exit_reason)"
  case "$exit_reason" in
    timeout | error | provider-unavailable | dependency-missing | malformed-sentinel) return 0 ;;
    blocked | worktree-mutated | max-iterations) return 1 ;;
  esac

  [ "$review_rc" -eq 124 ] && return 0
  return 1
}

review_failed_provider_csv() {
  local csv field value item
  local -a provider_items

  csv=""
  for field in provider fallback_primary_provider fallback_retry_provider fallback_excluded_providers; do
    value="$(summary_string_field "$field")"
    if [ -n "$value" ]; then
      IFS=',' read -r -a provider_items <<<"$value"
      for item in "${provider_items[@]}"; do
        csv="$(csv_add_unique "$csv" "$item")"
      done
    fi
  done
  printf '%s' "$csv"
}

review_infra_retry_command() {
  printf 'TOUCHSTONE_CONDUCTOR_WITH=codex bash scripts/merge-pr.sh %s' "$PR_NUMBER"
}

print_review_infra_retry_guidance() {
  local failed_csv exit_reason fallback_reason retry_command

  failed_csv="$(review_failed_provider_csv)"
  exit_reason="$(summary_string_field exit_reason)"
  fallback_reason="$(summary_string_field fallback_reason)"
  [ -n "$exit_reason" ] || exit_reason="reviewer-infrastructure"
  retry_command="$(review_infra_retry_command)"

  echo "" >&2
  echo "Provider/infrastructure outage details:" >&2
  echo "  deterministic preflight: clean" >&2
  echo "  concrete findings: 0" >&2
  echo "  review exit reason: $exit_reason" >&2
  if [ -n "$fallback_reason" ]; then
    echo "  fallback reason: $fallback_reason" >&2
  fi
  if [ -n "$failed_csv" ]; then
    echo "  failed/stalled provider(s): $failed_csv" >&2
  fi
  echo "  retry command: $retry_command" >&2
  echo "  repair route: authenticate the subscription Codex CLI, then run the retry command" >&2
  echo "  cost boundary: any other provider or auto-routing mode requires explicit operator opt-in" >&2
}

BYPASS_REASON="$(trim "$(printf '%s' "$BYPASS_REASON" | tr '\r\n\t' '   ')")"

if [ -z "$PR_NUMBER" ] || ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Usage: bash scripts/merge-pr.sh <pr-number> [--bypass-with-disclosure=\"<reason>\" [--allow-fail-open-marker]]" >&2
  exit 2
fi
if [ "$BYPASS_REVIEW" = true ] && [ -z "$BYPASS_REASON" ]; then
  echo "ERROR: --bypass-with-disclosure requires a non-empty reason." >&2
  exit 2
fi
if [ "$ALLOW_FAIL_OPEN_MARKER" = true ] && [ "$BYPASS_REVIEW" != true ]; then
  echo "ERROR: --allow-fail-open-marker requires --bypass-with-disclosure=\"<reason>\"." >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: 'gh' is not installed." >&2
  exit 2
fi

# Resolve the default branch.
DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo main)"
REPO_FULL_NAME="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
if [ -n "$REPO_FULL_NAME" ] && [ "$REPO_FULL_NAME" != "${REPO_FULL_NAME#*/}" ]; then
  REPO_OWNER="${REPO_FULL_NAME%%/*}"
  REPO_NAME="${REPO_FULL_NAME#*/}"
fi

current_pr_base_revision() {
  if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
    echo "repository identity is unavailable" >&2
    return 1
  fi

  gh api "repos/$REPO_OWNER/$REPO_NAME/pulls/$PR_NUMBER" --jq '[.base.ref, .base.sha] | @tsv'
}

resolve_pr_base_ref() {
  local revision

  if ! revision="$(current_pr_base_revision 2>&1)"; then
    echo "ERROR: Could not resolve PR #$PR_NUMBER base branch: $revision" >&2
    exit 1
  fi
  IFS="$(printf '\t')" read -r PR_BASE_BRANCH _ <<<"$revision"
  if [ -z "$PR_BASE_BRANCH" ] || ! git check-ref-format --branch "$PR_BASE_BRANCH" >/dev/null 2>&1; then
    echo "ERROR: GitHub returned an invalid base branch for PR #$PR_NUMBER: ${PR_BASE_BRANCH:-<empty>}" >&2
    exit 1
  fi
  PR_BASE_REF="origin/$PR_BASE_BRANCH"
}

refresh_pr_base_ref() {
  local phase="$1"

  echo "==> Refreshing $PR_BASE_REF $phase ..."
  if ! git fetch origin "+refs/heads/$PR_BASE_BRANCH:refs/remotes/origin/$PR_BASE_BRANCH"; then
    echo "ERROR: Failed to refresh $PR_BASE_REF $phase." >&2
    return 1
  fi
  if ! git rev-parse --verify --quiet "$PR_BASE_REF^{commit}" >/dev/null; then
    echo "ERROR: Could not verify $PR_BASE_REF $phase." >&2
    return 1
  fi
}

resolve_pr_base_ref

truthy() {
  case "$(printf '%s' "${1:-false}" | tr '[:upper:]' '[:lower:]')" in
    true | 1 | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_bool() {
  case "$(printf '%s' "${1:-false}" | tr '[:upper:]' '[:lower:]')" in
    true | 1 | yes | on) printf 'true' ;;
    false | 0 | no | off) printf 'false' ;;
    *) printf '%s' "$1" ;;
  esac
}

load_merge_review_config() {
  local config_file config_error=""
  resolve_merge_review_config_file || return $?
  config_file="$MERGE_REVIEW_CONFIG_FILE"
  [ -f "$config_file" ] || return 0
  [ -f "$SCRIPT_DIR/../lib/toml.sh" ] || return 0

  # shellcheck source=../lib/toml.sh
  source "$SCRIPT_DIR/../lib/toml.sh"

  merge_pr_toml_callback() {
    local section="$1"
    local key="$2"
    local value="$3"
    local normalized

    if [ "$section" = "review" ] && [ "$key" = "preflight_required" ]; then
      normalized="$(normalize_bool "$value")"
      case "$normalized" in
        true | false) PREFLIGHT_REQUIRED="$normalized" ;;
        *) config_error="[review].preflight_required must be true or false; got: $value" ;;
      esac
    elif [ "$section" = "review" ] && [ "$key" = "comment_on_clean" ]; then
      normalized="$(normalize_bool "$value")"
      case "$normalized" in
        true | false) COMMENT_ON_CLEAN="$normalized" ;;
        *) config_error="[review].comment_on_clean must be true or false; got: $value" ;;
      esac
    elif [ "$section" = "review" ] && [ "$key" = "comment_findings_history" ]; then
      normalized="$(normalize_bool "$value")"
      case "$normalized" in
        true | false) COMMENT_FINDINGS_HISTORY="$normalized" ;;
        *) config_error="[review].comment_findings_history must be true or false; got: $value" ;;
      esac
    elif [ "$section" = "review.pr_triggered" ] && [ "$key" = "required" ]; then
      case "$value" in
        true | false) PR_TRIGGERED_REVIEW_REQUIRED="$value" ;;
        *) config_error="[review.pr_triggered].required must be true or false; got: $value" ;;
      esac
    elif [ "$section" = "review.pr_triggered" ] && [ "$key" = "provider" ]; then
      PR_TRIGGERED_REVIEW_PROVIDER="$value"
    elif [ "$section" = "review.pr_triggered" ] && [ "$key" = "request_on_push" ]; then
      case "$value" in
        true | false) PR_TRIGGERED_REVIEW_REQUEST_ON_PUSH="$value" ;;
        *) config_error="[review.pr_triggered].request_on_push must be true or false; got: $value" ;;
      esac
    elif [ "$section" = "review.pr_triggered" ] && [ "$key" = "timeout_sec" ]; then
      PR_TRIGGERED_REVIEW_TIMEOUT_SEC="$value"
    elif [ "$section" = "review.pr_triggered" ] && [ "$key" = "poll_sec" ]; then
      PR_TRIGGERED_REVIEW_POLL_SEC="$value"
    elif [ "$section" = "review.pr_triggered" ] && [ "$key" = "trusted_review_authors" ]; then
      PR_TRIGGERED_REVIEW_TRUSTED_REVIEW_AUTHORS="$(toml_normalize_array "$value")"
    elif [ "$section" = "review.pr_triggered" ] && [ "$key" = "skip_merge_review" ]; then
      case "$value" in
        true | false) PR_TRIGGERED_REVIEW_SKIP_MERGE_REVIEW="$value" ;;
        *) config_error="[review.pr_triggered].skip_merge_review must be true or false; got: $value" ;;
      esac
    fi
  }

  toml_parse "$config_file" merge_pr_toml_callback
  if [ -n "$config_error" ]; then
    echo "ERROR: Invalid trusted review config: $config_error" >&2
    echo "       source: $config_file" >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="trusted-review-config"
    return 1
  fi
}

resolve_merge_review_config_file() {
  local rel repo_root tmp trusted_base

  MERGE_REVIEW_CONFIG_FILE=""
  if [ -n "$PR_NUMBER" ] && [ -n "${PR_BASE_REF:-}" ]; then
    trusted_base="${MERGE_PR_TRUSTED_CONFIG_BASE:-$PR_BASE_REF}"
    for rel in .touchstone-review.toml .codex-review.toml; do
      if git cat-file -e "$trusted_base:$rel" 2>/dev/null; then
        if ! tmp="$(mktemp -t touchstone-merge-review-config.XXXXXX)"; then
          echo "ERROR: Failed to create a temporary file for trusted review config." >&2
          echo "       source: $trusted_base:$rel" >&2
          TOUCHSTONE_MERGE_FAILURE_REASON="trusted-review-config"
          return 1
        fi
        if git show "$trusted_base:$rel" >"$tmp" 2>/dev/null; then
          MERGE_REVIEW_CONFIG_TMP_FILES+=("$tmp")
          MERGE_REVIEW_CONFIG_FILE="$tmp"
          return 0
        fi
        rm -f "$tmp"
        echo "ERROR: Failed to extract trusted review config." >&2
        echo "       source: $trusted_base:$rel" >&2
        TOUCHSTONE_MERGE_FAILURE_REASON="trusted-review-config"
        return 1
      fi
    done
    return 0
  fi

  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$repo_root" ] || return 0
  for rel in .touchstone-review.toml .codex-review.toml; do
    if [ -f "$repo_root/$rel" ]; then
      MERGE_REVIEW_CONFIG_FILE="$repo_root/$rel"
      return 0
    fi
  done
  return 0
}

refresh_trusted_merge_review_config_base() {
  local trusted_base

  if [ -z "$PR_NUMBER" ] || [ -z "${PR_BASE_REF:-}" ]; then
    return 0
  fi

  trusted_base="${MERGE_PR_TRUSTED_CONFIG_BASE:-$PR_BASE_REF}"
  if [ "$trusted_base" = "$PR_BASE_REF" ]; then
    refresh_pr_base_ref "before loading merge review config" || exit 1
  fi
  if ! git rev-parse --verify --quiet "$trusted_base^{commit}" >/dev/null; then
    echo "ERROR: Could not verify trusted merge review config base $trusted_base." >&2
    exit 1
  fi
}

review_clean_marker_key() {
  local branch="$1"
  printf '%s' "$branch" | sed 's/[^A-Za-z0-9._-]/_/g'
}

review_clean_marker_file() {
  local branch="$1"
  printf '%s/%s.clean' \
    "$(git rev-parse --git-path touchstone/reviewer-clean)" \
    "$(review_clean_marker_key "$branch")"
}

review_findings_history_file() {
  local branch="$1"
  printf '%s/%s.jsonl' \
    "$(git rev-parse --git-path touchstone/reviewer-findings-history)" \
    "$(review_clean_marker_key "$branch")"
}

marker_field() {
  local field="$1"
  local marker="$2"
  awk -F= -v key="$field" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$marker"
}

preflight_hash_stream() {
  shasum -a 256 | awk '{ print $1 }'
}

preflight_hash_file() {
  local path="$1"

  if [ -f "$path" ]; then
    shasum -a 256 "$path" | awk '{ print $1 }'
  else
    printf 'missing'
  fi
}

preflight_hash_paths() {
  local repo_root="$1"
  shift
  local rel path

  for rel in "$@"; do
    path="$repo_root/$rel"
    printf '%s\t%s\n' "$rel" "$(preflight_hash_file "$path")"
  done | preflight_hash_stream
}

preflight_hash_changed_paths() {
  local repo_root="$1"
  shift
  local rel path

  for rel in "$@"; do
    [ -n "$rel" ] || continue
    path="$repo_root/$rel"
    if [ -f "$path" ]; then
      printf '%s\t%s\n' "$rel" "$(preflight_hash_file "$path")"
    else
      printf '%s\tmissing\n' "$rel"
    fi
  done | preflight_hash_stream
}

preflight_hash_file_list() {
  local label path

  while [ "$#" -gt 0 ]; do
    label="$1"
    path="$2"
    shift 2
    printf '%s\t%s\n' "$label" "$(preflight_hash_file "$path")"
  done | preflight_hash_stream
}

preflight_changed_paths() {
  local repo_root="$1"
  local base_ref="$2"

  (cd "$repo_root" && git diff --name-only "$base_ref"...HEAD) 2>/dev/null | sort -u
}

preflight_worktree_hash() {
  local repo_root="$1"
  local base_ref="$2"
  local -a paths=()
  local path

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    paths+=("$path")
  done < <(preflight_changed_paths "$repo_root" "$base_ref")

  if [ "${#paths[@]}" -eq 0 ]; then
    printf 'no-changed-paths\n' | preflight_hash_stream
    return
  fi

  (
    cd "$repo_root" || exit 1
    git status --porcelain --untracked-files=all -- "${paths[@]}"
    printf '\n-- worktree diff --\n'
    git diff --binary -- "${paths[@]}"
    printf '\n-- index diff --\n'
    git diff --cached --binary -- "${paths[@]}"
    printf '\n-- untracked files --\n'
    while IFS= read -r -d '' rel; do
      printf 'path\t%s\n' "$rel"
      if [ -f "$rel" ]; then
        printf 'sha256\t%s\n' "$(preflight_hash_file "$rel")"
      else
        printf 'sha256\tmissing\n'
      fi
    done < <(git ls-files --others --exclude-standard -z -- "${paths[@]}")
  ) 2>/dev/null | preflight_hash_stream
}

preflight_changed_paths_hash() {
  local repo_root="$1"
  local base_ref="$2"
  local -a paths=()
  local path

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    paths+=("$path")
  done < <(preflight_changed_paths "$repo_root" "$base_ref")

  preflight_hash_changed_paths "$repo_root" "${paths[@]}"
}

preflight_tool_fingerprint() {
  local tool path version_hash

  for tool in shellcheck shfmt markdownlint-cli2 markdownlint actionlint; do
    path="$(command -v "$tool" 2>/dev/null || true)"
    if [ -n "$path" ]; then
      version_hash="$({ "$tool" --version 2>&1 || true; } | preflight_hash_stream)"
      printf '%s\t%s\t%s\n' "$tool" "$path" "$version_hash"
    else
      printf '%s\tmissing\tmissing\n' "$tool"
    fi
  done | preflight_hash_stream
}

preflight_env_fingerprint() {
  local dogfood_resolved_command=""

  if declare -F touchstone_preflight_dogfood_command >/dev/null 2>&1; then
    dogfood_resolved_command="$(touchstone_preflight_dogfood_command || true)"
  fi
  {
    printf 'TOUCHSTONE_PREFLIGHT_VALIDATE_SCRIPT=%s\n' "${TOUCHSTONE_PREFLIGHT_VALIDATE_SCRIPT:-}"
    printf 'TOUCHSTONE_PREFLIGHT_VALIDATE_COMMAND=%s\n' "${TOUCHSTONE_PREFLIGHT_VALIDATE_COMMAND:-}"
    printf 'TOUCHSTONE_PREFLIGHT_VALIDATE_LANE=%s\n' "${TOUCHSTONE_PREFLIGHT_VALIDATE_LANE:-}"
    printf 'TOUCHSTONE_PREFLIGHT_VALIDATE_AFFECTED_COMMAND=%s\n' "${TOUCHSTONE_PREFLIGHT_VALIDATE_AFFECTED_COMMAND:-}"
    printf 'TOUCHSTONE_PREFLIGHT_VALIDATE_SMOKE_COMMAND=%s\n' "${TOUCHSTONE_PREFLIGHT_VALIDATE_SMOKE_COMMAND:-}"
    printf 'TOUCHSTONE_PREFLIGHT_VALIDATE_FULL_COMMAND=%s\n' "${TOUCHSTONE_PREFLIGHT_VALIDATE_FULL_COMMAND:-}"
    printf 'TOUCHSTONE_PREFLIGHT_DOGFOOD_COMMAND=%s\n' "${TOUCHSTONE_PREFLIGHT_DOGFOOD_COMMAND:-}"
    printf 'TOUCHSTONE_PREFLIGHT_DOGFOOD_RESOLVED_COMMAND=%s\n' "$dogfood_resolved_command"
    printf 'TOUCHSTONE_PREFLIGHT_SKIP_DOGFOOD=%s\n' "${TOUCHSTONE_PREFLIGHT_SKIP_DOGFOOD:-}"
  } | preflight_hash_stream
}

preflight_cache_inputs() {
  local base_ref="$1"
  local repo_root head_sha base_sha merge_base changed_paths_hash
  local checker_hash config_hash worktree_hash tool_hash env_hash

  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  repo_root="$(cd "$repo_root" && pwd)" || return 1
  head_sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null)" || return 1
  base_sha="$(git -C "$repo_root" rev-parse --verify "$base_ref^{commit}" 2>/dev/null)" || return 1
  merge_base="$(git -C "$repo_root" merge-base "$base_ref" "$head_sha" 2>/dev/null)" || return 1
  changed_paths_hash="$(preflight_changed_paths_hash "$repo_root" "$base_ref")" || return 1
  checker_hash="$(preflight_hash_file_list \
    "lib/preflight.sh" "$PREFLIGHT_SCRIPT" \
    "lib/preflight-scope.sh" "$(dirname "$PREFLIGHT_SCRIPT")/preflight-scope.sh" \
    "scripts/touchstone-run.sh" "$SCRIPT_DIR/touchstone-run.sh" \
    "scripts/conductor-dogfood-smoke.py" "$SCRIPT_DIR/conductor-dogfood-smoke.py")"
  config_hash="$(preflight_hash_paths "$repo_root" \
    ".touchstone-review.toml" \
    ".codex-review.toml" \
    ".touchstone-config" \
    ".touchstone-version" \
    ".pre-commit-config.yaml" \
    ".markdownlint.json")"
  worktree_hash="$(preflight_worktree_hash "$repo_root" "$base_ref")" || return 1
  tool_hash="$(preflight_tool_fingerprint)"
  env_hash="$(preflight_env_fingerprint)"

  printf 'version=4\n'
  printf 'repo_root=%s\n' "$repo_root"
  printf 'scope=diff\n'
  printf 'base_ref=%s\n' "$base_ref"
  printf 'base_sha=%s\n' "$base_sha"
  printf 'head_sha=%s\n' "$head_sha"
  printf 'merge_base=%s\n' "$merge_base"
  printf 'changed_files_hash=%s\n' "$changed_paths_hash"
  printf 'checker_hash=%s\n' "$checker_hash"
  printf 'config_hash=%s\n' "$config_hash"
  printf 'worktree_hash=%s\n' "$worktree_hash"
  printf 'tool_hash=%s\n' "$tool_hash"
  printf 'env_hash=%s\n' "$env_hash"
}

preflight_cache_prepare() {
  local base_ref="$1"
  local cache_dir

  PREFLIGHT_CACHE_KEY=""
  PREFLIGHT_CACHE_FILE=""
  PREFLIGHT_CACHE_INPUTS=""

  if truthy "${TOUCHSTONE_PREFLIGHT_DISABLE_CACHE:-false}"; then
    return 1
  fi

  PREFLIGHT_CACHE_INPUTS="$(preflight_cache_inputs "$base_ref")" || return 1
  PREFLIGHT_CACHE_KEY="$(printf '%s\n' "$PREFLIGHT_CACHE_INPUTS" | preflight_hash_stream)"
  cache_dir="$(git rev-parse --git-path touchstone/preflight-clean 2>/dev/null)" || return 1
  PREFLIGHT_CACHE_FILE="$cache_dir/$PREFLIGHT_CACHE_KEY.clean"
}

preflight_cache_short_key() {
  printf '%s' "${PREFLIGHT_CACHE_KEY:0:12}"
}

preflight_cache_hit() {
  local marker_inputs

  [ -n "$PREFLIGHT_CACHE_FILE" ] || return 1
  [ -f "$PREFLIGHT_CACHE_FILE" ] || return 1
  grep -q '^result=preflight_clean$' "$PREFLIGHT_CACHE_FILE" || return 1
  marker_inputs="$(sed '1,2d' "$PREFLIGHT_CACHE_FILE")"
  [ "$marker_inputs" = "$PREFLIGHT_CACHE_INPUTS" ]
}

write_preflight_clean_cache() {
  local cache_dir tmp

  [ -n "$PREFLIGHT_CACHE_FILE" ] || return 0
  [ -n "$PREFLIGHT_CACHE_INPUTS" ] || return 0
  cache_dir="$(dirname "$PREFLIGHT_CACHE_FILE")"
  if ! mkdir -p "$cache_dir" 2>/dev/null; then
    echo "WARNING: could not create preflight cache directory $cache_dir; continuing without cache." >&2
    return 0
  fi

  tmp="$PREFLIGHT_CACHE_FILE.$$"
  if {
    printf 'result=preflight_clean\n'
    printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
    printf '%s\n' "$PREFLIGHT_CACHE_INPUTS"
  } >"$tmp" 2>/dev/null && mv "$tmp" "$PREFLIGHT_CACHE_FILE" 2>/dev/null; then
    return 0
  fi

  rm -f "$tmp" 2>/dev/null || true
  echo "WARNING: could not write preflight cache marker $PREFLIGHT_CACHE_FILE; continuing without cache." >&2
  return 0
}

worktree_path_for_branch() {
  local branch="$1"
  local current_path=""
  local current_branch=""
  local line key value

  git worktree list --porcelain | while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then
      if [ "$current_branch" = "refs/heads/$branch" ]; then
        printf '%s\n' "$current_path"
        exit 0
      fi
      current_path=""
      current_branch=""
      continue
    fi

    key="${line%% *}"
    value="${line#* }"
    case "$key" in
      worktree) current_path="$value" ;;
      branch) current_branch="$value" ;;
    esac
  done

  if [ "$current_branch" = "refs/heads/$branch" ]; then
    printf '%s\n' "$current_path"
  fi
  return 0
}

branch_has_clean_review_marker() {
  local branch="$1"
  local head_oid="$2"
  local merge_base="$3"
  local marker marker_branch marker_head marker_merge_base live_branch_head
  marker="$(review_clean_marker_file "$branch")"
  [ -f "$marker" ] || return 1
  grep -q '^result=CODEX_REVIEW_CLEAN$' "$marker" || return 1
  marker_branch="$(marker_field branch "$marker")"
  marker_head="$(marker_field head "$marker")"
  marker_merge_base="$(marker_field merge_base "$marker")"

  if ! live_branch_head="$(git rev-parse "$branch" 2>/dev/null)"; then
    live_branch_head="$(git rev-parse HEAD 2>/dev/null || echo "")"
  fi

  # Invariant: A clean-review marker is valid only when its `head` field equals the current branch HEAD.
  [ "$marker_branch" = "$branch" ] \
    && [ -n "$live_branch_head" ] \
    && [ "$live_branch_head" = "$head_oid" ] \
    && [ "$marker_head" = "$live_branch_head" ] \
    && [ "$marker_merge_base" = "$merge_base" ]
}

is_positive_integer() {
  case "${1:-}" in
    "" | *[!0-9]*) return 1 ;;
    *) [ "$1" -gt 0 ] ;;
  esac
}

is_nonnegative_integer() {
  case "${1:-}" in
    "" | *[!0-9]*) return 1 ;;
    *) [ "$1" -ge 0 ] ;;
  esac
}

timestamp_to_epoch() {
  local timestamp="$1"

  date -j -f "%Y-%m-%dT%H:%M:%S%z" "$timestamp" "+%s" 2>/dev/null \
    || date -d "$timestamp" "+%s" 2>/dev/null
}

head_oid_matches_logged_sha() {
  local head_oid="$1"
  local logged_sha="$2"

  [ -n "$head_oid" ] || return 1
  [ -n "$logged_sha" ] || return 1

  case "$head_oid" in
    "$logged_sha"*) return 0 ;;
  esac
  case "$logged_sha" in
    "$head_oid"*) return 0 ;;
  esac
  return 1
}

bypass_reason_mentions_fail_open() {
  local reason_lower
  reason_lower="$(printf '%s' "$BYPASS_REASON" | tr '[:upper:]' '[:lower:]')"

  case "$reason_lower" in
    *fail-open* | *"fail open"* | *provider* | *infra* | *outage* | *timeout* | *"timed out"* | *"reviewer unavailable"* | *"reviewer error"*)
      return 0
      ;;
    *) return 1 ;;
  esac
}

branch_has_recent_fail_open_marker() {
  local branch="$1"
  local head_oid="$2"
  local log_file="$TOUCHSTONE_REVIEW_LOG"
  local window_hours="$TOUCHSTONE_FAIL_OPEN_BYPASS_WINDOW_HOURS"
  local window_seconds now_epoch tab
  local timestamp repo_path log_branch logged_sha reason detail
  local event_epoch age

  [ -n "$log_file" ] || return 1
  [ "$log_file" != "/dev/null" ] || return 1
  [ -f "$log_file" ] || return 1
  is_positive_integer "$window_hours" || return 1

  window_seconds=$((window_hours * 3600))
  now_epoch="$(date "+%s" 2>/dev/null)" || return 1
  tab="$(printf '\t')"

  while IFS="$tab" read -r timestamp repo_path log_branch logged_sha reason detail || [ -n "$timestamp" ]; do
    [ "$log_branch" = "$branch" ] || continue
    head_oid_matches_logged_sha "$head_oid" "$logged_sha" || continue
    case "$reason" in
      FAIL_OPEN_*) ;;
      *) continue ;;
    esac
    case "$detail" in
      fail-open:*) ;;
      *) continue ;;
    esac
    event_epoch="$(timestamp_to_epoch "$timestamp" 2>/dev/null || true)"
    [ -n "$event_epoch" ] || continue
    age=$((now_epoch - event_epoch))
    # Allow a small future skew between the review hook and merge machine clocks.
    [ "$age" -ge -300 ] || continue
    [ "$age" -le "$window_seconds" ] || continue

    BYPASS_MARKER_EVIDENCE="timestamp=$timestamp; repo=$repo_path; branch=$log_branch; sha=$logged_sha; reason=$reason; detail=$detail"
    return 0
  done <"$log_file"

  return 1
}

sanitize_review_log_field() {
  printf '%s' "$1" | tr '\t\n' '  '
}

append_review_log_event() {
  local reason="$1"
  local detail="$2"
  local log_file="$TOUCHSTONE_REVIEW_LOG"
  local timestamp repo_root branch sha tmp_dir tmp_file line_count keep_lines

  [ -n "$log_file" ] || return 0
  [ "$log_file" != "/dev/null" ] || return 0

  timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo unknown)"
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo unknown)"
  branch="${PR_HEAD_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}"
  sha="${REVIEWED_HEAD_OID:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
  if [ "$sha" != "unknown" ] && [ "${#sha}" -gt 12 ]; then
    sha="${sha:0:12}"
  fi

  reason="$(sanitize_review_log_field "$reason")"
  detail="$(sanitize_review_log_field "$detail")"
  branch="$(sanitize_review_log_field "$branch")"

  tmp_dir="${TMPDIR:-/tmp}"
  tmp_dir="${tmp_dir%/}"
  tmp_file="$tmp_dir/touchstone-merge-review-log.$$.tmp"

  if ! mkdir -p "$(dirname "$log_file")" 2>/dev/null; then
    echo "WARNING: Could not create review audit log directory for $log_file." >&2
    return 0
  fi

  if [ -f "$log_file" ]; then
    line_count="$(wc -l <"$log_file" 2>/dev/null | tr -d ' ')" || line_count=0
    line_count="${line_count:-0}"
    if is_positive_integer "$TOUCHSTONE_REVIEW_LOG_MAX_LINES" && [ "$line_count" -ge "$TOUCHSTONE_REVIEW_LOG_MAX_LINES" ]; then
      keep_lines=$((TOUCHSTONE_REVIEW_LOG_MAX_LINES - 1))
      tail -n "$keep_lines" "$log_file" >"$tmp_file" 2>/dev/null || : >"$tmp_file"
    else
      cat "$log_file" >"$tmp_file" 2>/dev/null || : >"$tmp_file"
    fi
  else
    : >"$tmp_file"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$timestamp" "$repo_root" "$branch" "$sha" "$reason" "$detail" \
    >>"$tmp_file" 2>/dev/null || {
    rm -f "$tmp_file" 2>/dev/null
    echo "WARNING: Could not append review audit log entry for $log_file." >&2
    return 0
  }

  if ! mv "$tmp_file" "$log_file" 2>/dev/null; then
    rm -f "$tmp_file" 2>/dev/null
    echo "WARNING: Could not update review audit log $log_file." >&2
  fi
}

record_bypass_audit_log() {
  local detail
  detail="reason=$BYPASS_REASON; marker=$BYPASS_MARKER_SOURCE"
  if [ -n "$BYPASS_MARKER_EVIDENCE" ]; then
    detail="$detail; evidence=[$BYPASS_MARKER_EVIDENCE]"
  fi
  append_review_log_event review-bypass "$detail"
}

sync_default_branch_after_merge() {
  local current_branch current_worktree default_worktree

  echo "==> Merged. Updating local $DEFAULT_BRANCH ..."
  current_branch="$(git rev-parse --abbrev-ref HEAD)"

  if [ "$current_branch" = "$DEFAULT_BRANCH" ]; then
    if ! git pull --rebase; then
      echo "WARNING: PR #$PR_NUMBER merged remotely, but local $DEFAULT_BRANCH could not pull --rebase." >&2
      echo "WARNING: Run this when convenient: git pull --rebase" >&2
    fi
    return 0
  fi

  current_worktree="$(git rev-parse --show-toplevel)"
  default_worktree="$(worktree_path_for_branch "$DEFAULT_BRANCH" | head -n 1)"
  if [ -n "$default_worktree" ] && [ "$default_worktree" != "$current_worktree" ]; then
    if [ ! -d "$default_worktree" ]; then
      echo "WARNING: $DEFAULT_BRANCH is recorded as checked out in a missing worktree: $default_worktree" >&2
      echo "WARNING: This is stale git worktree metadata, usually from deleting the directory directly." >&2
      echo "WARNING: Run 'git worktree prune' from a remaining checkout, then rerun local sync if needed." >&2
      return 0
    fi
    echo "==> $DEFAULT_BRANCH is checked out in sibling worktree: $default_worktree"
    echo "==> Fast-forwarding that worktree after remote merge ..."
    if git -C "$default_worktree" pull --ff-only; then
      return 0
    fi
    echo "WARNING: PR #$PR_NUMBER merged remotely, but sibling worktree '$default_worktree' could not fast-forward." >&2
    echo "WARNING: Run this when convenient: git -C '$default_worktree' pull --ff-only" >&2
    return 0
  fi

  if ! git checkout "$DEFAULT_BRANCH"; then
    echo "WARNING: PR #$PR_NUMBER merged remotely, but this worktree could not check out $DEFAULT_BRANCH." >&2
    echo "WARNING: Run this when convenient: git checkout '$DEFAULT_BRANCH' && git pull --rebase" >&2
    return 0
  fi
  if ! git pull --rebase; then
    echo "WARNING: PR #$PR_NUMBER merged remotely, but local $DEFAULT_BRANCH could not pull --rebase." >&2
    echo "WARNING: Run this when convenient: git pull --rebase" >&2
  fi
}

checkout_default_ref_for_cleanup() {
  local branch="$1"
  local reviewed_head="$2"
  local current_branch current_head current_worktree default_worktree

  current_branch="$(git rev-parse --abbrev-ref HEAD)"
  current_head="$(git rev-parse HEAD 2>/dev/null || echo "")"
  if [ "$current_branch" != "$branch" ]; then
    if [ "$current_branch" != "HEAD" ] || [ "$current_head" != "$reviewed_head" ]; then
      return 0
    fi
  fi

  current_worktree="$(git rev-parse --show-toplevel)"
  default_worktree="$(worktree_path_for_branch "$DEFAULT_BRANCH" | head -n 1)"
  if [ -n "$default_worktree" ] && [ "$default_worktree" != "$current_worktree" ]; then
    echo "==> $DEFAULT_BRANCH is checked out elsewhere; detaching this worktree at $DEFAULT_BRANCH before local branch cleanup ..."
    if git checkout --detach "$DEFAULT_BRANCH"; then
      return 0
    fi
    echo "WARNING: Could not detach this worktree at $DEFAULT_BRANCH; leaving local branch '$branch' intact." >&2
    return 1
  fi

  if git checkout "$DEFAULT_BRANCH"; then
    return 0
  fi
  if git checkout --detach "$DEFAULT_BRANCH"; then
    echo "==> Detached this worktree at $DEFAULT_BRANCH before local branch cleanup."
    return 0
  fi
  echo "WARNING: Could not move off local branch '$branch'; leaving it intact." >&2
  return 1
}

cleanup_local_pr_branch_after_merge() {
  local branch="$PR_HEAD_BRANCH"
  local reviewed_head="$REVIEWED_HEAD_OID"
  local local_head pr_state

  if [ -z "$branch" ] || [ -z "$reviewed_head" ]; then
    echo "WARNING: Missing reviewed PR head metadata; skipping local branch cleanup." >&2
    return 0
  fi
  if [ "$branch" = "$DEFAULT_BRANCH" ] || [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
    echo "WARNING: Refusing to delete protected branch '$branch' after PR #$PR_NUMBER." >&2
    return 0
  fi
  if ! git show-ref --verify --quiet "refs/heads/$branch"; then
    echo "==> Local branch '$branch' is already absent."
    return 0
  fi
  if ! local_head="$(git rev-parse "$branch" 2>/dev/null)"; then
    echo "WARNING: Could not resolve local branch '$branch'; leaving it intact." >&2
    return 0
  fi
  if [ "$local_head" != "$reviewed_head" ]; then
    echo "WARNING: Local branch '$branch' is at $local_head, not reviewed PR head $reviewed_head; leaving it intact." >&2
    return 0
  fi
  [ -n "$PR_WORKTREE_PATH" ] || PR_WORKTREE_PATH="$(worktree_path_for_branch "$branch" | head -n 1)"
  pr_state="$(gh pr view "$PR_NUMBER" --json state --jq '.state' 2>/dev/null || echo "")"
  if [ "$pr_state" != "MERGED" ]; then
    echo "WARNING: PR #$PR_NUMBER is not confirmed MERGED (state: ${pr_state:-unknown}); leaving local branch '$branch' intact." >&2
    return 0
  fi

  if ! checkout_default_ref_for_cleanup "$branch" "$reviewed_head"; then
    return 0
  fi

  echo "==> Deleting local branch '$branch' after verified squash merge of $reviewed_head ..."
  if git branch -D -- "$branch"; then
    echo "==> Local branch '$branch' deleted."
  else
    echo "WARNING: Could not delete local branch '$branch' after verified merge." >&2
    echo "WARNING: Run this when convenient after moving off the branch: git branch -D '$branch'" >&2
  fi
}

cleanup_pr_worktree_after_merge() {
  local pr_worktree="$PR_WORKTREE_PATH"
  local current_worktree default_worktree dirty_status

  [ -n "$pr_worktree" ] || return 0
  if [ ! -d "$pr_worktree" ]; then
    echo "WARNING: Merged PR worktree '$pr_worktree' is missing; run 'git worktree prune' if Git still records it." >&2
    return 0
  fi

  current_worktree="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
  default_worktree="$(worktree_path_for_branch "$DEFAULT_BRANCH" | head -n 1)"
  if [ -z "$default_worktree" ] || [ ! -d "$default_worktree" ]; then
    default_worktree="$current_worktree"
  fi
  if [ -z "$default_worktree" ] || [ "$default_worktree" = "$pr_worktree" ]; then
    echo "WARNING: No separate default-branch worktree is available to remove merged PR worktree '$pr_worktree'." >&2
    echo "         Run 'bash scripts/cleanup-worktrees.sh --execute' after moving to a different worktree." >&2
    return 0
  fi

  dirty_status="$(git -C "$pr_worktree" status --porcelain 2>/dev/null || printf 'status-failed\n')"
  if [ -n "$dirty_status" ]; then
    echo "WARNING: Merged PR worktree '$pr_worktree' has uncommitted changes; leaving it in place." >&2
    echo "         Inspect it, then run 'bash scripts/cleanup-worktrees.sh --execute' when it is clean." >&2
    return 0
  fi

  echo "==> Removing merged PR worktree '$pr_worktree' ..."
  touchstone_emit_event cleanup_started worktree_path="$pr_worktree"
  if git -C "$default_worktree" worktree remove "$pr_worktree"; then
    echo "==> Merged PR worktree removed."
    touchstone_emit_event cleanup_done worktree_path="$pr_worktree" result=removed
  else
    echo "WARNING: Could not remove merged PR worktree '$pr_worktree'." >&2
    echo "         Run 'bash scripts/cleanup-worktrees.sh --execute' from $default_worktree to inspect and clean up." >&2
    touchstone_emit_event cleanup_done worktree_path="$pr_worktree" result=failed
  fi
}

print_bypass_banner() {
  cat <<EOF

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! BYPASSING REVIEWER GATE
!! marker: $BYPASS_MARKER_SOURCE
!! reason: $BYPASS_REASON
!! This bypass is recorded on the PR and squash commit.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

EOF
}

# Append a squash-merge record to .git/touchstone/squash-map.jsonl so
# scripts/cleanup-branches.sh can recognize a branch as squash-merged even
# after $DEFAULT_BRANCH evolves past it (later commits on the same files
# break the tree-equivalence heuristic).
#
# The record carries:
#   - branch       : the head ref name of the merged PR
#   - pr           : PR number
#   - branch_oid   : tip of the branch at merge time (so cleanup can detect
#                    "branch picked up new commits after the squash" and
#                    fall through to the existing tree check)
#   - squash_commit: the squash commit on the default branch (best effort —
#                    empty string if gh cannot resolve it yet)
#   - ts           : UTC ISO timestamp
#
# I/O is best-effort. A failure to write must not fail the merge: the merge
# already succeeded server-side, and the squash-map is an optimization for
# later cleanup, not a correctness boundary. Any failure is logged to stderr.
record_squash_merge() {
  local branch="$1"
  local pr="$2"
  local branch_oid="$3"
  local squash_commit="${4:-}"
  local map_path map_dir ts

  if [ -z "$branch" ] || [ -z "$pr" ] || [ -z "$branch_oid" ]; then
    echo "WARNING: record_squash_merge: missing branch/pr/oid, skipping squash-map write." >&2
    return 0
  fi

  if ! map_path="$(git rev-parse --git-path touchstone/squash-map.jsonl 2>/dev/null)" \
    || [ -z "$map_path" ]; then
    echo "WARNING: record_squash_merge: could not resolve squash-map path; skipping." >&2
    return 0
  fi
  map_dir="$(dirname "$map_path")"
  if ! mkdir -p "$map_dir" 2>/dev/null; then
    echo "WARNING: record_squash_merge: could not create $map_dir; skipping squash-map write." >&2
    return 0
  fi

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"

  # JSON-encode each string field. Bash can produce safe JSON for these
  # tightly constrained values (branch names exclude " and \, OIDs are hex,
  # ts is ISO-8601) by simply quoting — no escaping needed in practice.
  # Defense in depth: refuse to record if any field contains a quote or
  # backslash, rather than emit malformed JSON.
  local field
  for field in "$branch" "$pr" "$branch_oid" "$squash_commit" "$ts"; do
    case "$field" in
      *\"* | *\\*)
        echo "WARNING: record_squash_merge: field contains quote/backslash, skipping squash-map write." >&2
        return 0
        ;;
    esac
  done

  local line
  line="{\"branch\":\"$branch\",\"pr\":\"$pr\",\"branch_oid\":\"$branch_oid\",\"squash_commit\":\"$squash_commit\",\"ts\":\"$ts\"}"
  if ! printf '%s\n' "$line" >>"$map_path" 2>/dev/null; then
    echo "WARNING: record_squash_merge: could not append to $map_path; skipping squash-map write." >&2
    return 0
  fi
  echo "==> Recorded squash-merge metadata for '$branch' -> $map_path"
}

record_bypass_comment() {
  local body
  body="Reviewer bypassed via \`--bypass-with-disclosure\`. Marker: $BYPASS_MARKER_SOURCE. Reason: $BYPASS_REASON"
  if [ -n "$BYPASS_MARKER_EVIDENCE" ]; then
    body="$body

Fail-open evidence: $BYPASS_MARKER_EVIDENCE"
  fi
  gh pr comment "$PR_NUMBER" --body "$body"
}

post_clean_review_comment() {
  local summary_file="$1"
  local summary_json comment exit_reason

  if ! truthy "$COMMENT_ON_CLEAN"; then
    echo "==> Clean-review PR comment disabled by [review].comment_on_clean=false."
    return 0
  fi
  if [ "$BYPASS_REVIEW" = true ]; then
    return 0
  fi
  if ! declare -F format_clean_review_comment >/dev/null 2>&1 \
    || ! declare -F post_pr_review_comment >/dev/null 2>&1; then
    echo "WARNING: review comment helper not found at $REVIEW_COMMENT_SCRIPT; skipping clean-review comment." >&2
    return 0
  fi
  if [ -z "$summary_file" ] || [ ! -f "$summary_file" ]; then
    echo "WARNING: clean review summary file missing; skipping clean-review comment." >&2
    return 0
  fi

  summary_json="$(tail -n 1 "$summary_file" 2>/dev/null || true)"
  if [ -z "$summary_json" ]; then
    echo "WARNING: clean review summary file is empty; skipping clean-review comment." >&2
    return 0
  fi

  exit_reason="$(review_comment_json_field "$summary_json" exit_reason 2>/dev/null || true)"
  if [ -n "$exit_reason" ] && [ "$exit_reason" != "clean" ] && [ "$exit_reason" != "cache-hit" ]; then
    if declare -F format_review_failure_comment >/dev/null 2>&1; then
      comment="$(format_review_failure_comment "$summary_json" "" "" "")"
      if post_pr_review_comment "$PR_NUMBER" "$comment"; then
        echo "==> Posted non-clean review summary PR comment (exit_reason=$exit_reason)."
        return 0
      fi
      echo "WARNING: failed to post non-clean review summary comment for PR #$PR_NUMBER." >&2
    else
      echo "WARNING: review summary exit_reason=$exit_reason; skipping clean-review comment." >&2
    fi
    return 0
  fi

  comment="$(format_clean_review_comment "$summary_json")"
  if post_pr_review_comment "$PR_NUMBER" "$comment"; then
    echo "==> Posted clean-review PR comment."
    return 0
  fi

  echo "WARNING: failed to post clean-review PR comment for PR #$PR_NUMBER." >&2
  return 0
}

post_review_failure_comment() {
  local review_output_file="$1"
  local infra_failure="$2"
  local summary_json output comment retry_command failed_csv

  if [ "$BYPASS_REVIEW" = true ]; then
    return 0
  fi
  if ! declare -F format_review_failure_comment >/dev/null 2>&1 \
    || ! declare -F post_pr_review_comment >/dev/null 2>&1; then
    echo "WARNING: review comment helper not found at $REVIEW_COMMENT_SCRIPT; skipping review-failure comment." >&2
    return 0
  fi

  if [ -n "$REVIEW_SUMMARY_FILE" ] && [ -f "$REVIEW_SUMMARY_FILE" ]; then
    summary_json="$(tail -n 1 "$REVIEW_SUMMARY_FILE" 2>/dev/null || true)"
  else
    summary_json='{"reviewer":"Conductor","provider":"unknown","model":"unknown","peer_provider":"none","iterations":0,"mode":"fix","findings":0,"exit_reason":"reviewer-infrastructure"}'
  fi
  [ -n "$summary_json" ] || summary_json='{"reviewer":"Conductor","provider":"unknown","model":"unknown","peer_provider":"none","iterations":0,"mode":"fix","findings":0,"exit_reason":"reviewer-infrastructure"}'

  output="$(cat "$review_output_file" 2>/dev/null || true)"
  retry_command=""
  failed_csv=""
  if [ "$infra_failure" = true ]; then
    retry_command="$(review_infra_retry_command)"
    failed_csv="$(review_failed_provider_csv)"
  fi

  comment="$(format_review_failure_comment "$summary_json" "$output" "$retry_command" "$failed_csv")"
  if post_pr_review_comment "$PR_NUMBER" "$comment"; then
    echo "==> Posted review-failure PR comment."
    return 0
  fi

  echo "WARNING: failed to post review-failure PR comment for PR #$PR_NUMBER." >&2
  return 0
}

post_findings_history_comment() {
  local branch="$1"
  local history_file comment

  if ! truthy "$COMMENT_FINDINGS_HISTORY"; then
    echo "==> Findings-history PR comment disabled by [review].comment_findings_history=false."
    return 0
  fi
  if [ "$BYPASS_REVIEW" = true ]; then
    return 0
  fi
  if ! declare -F format_findings_history_comment >/dev/null 2>&1 \
    || ! declare -F post_pr_review_comment >/dev/null 2>&1; then
    echo "WARNING: review comment helper not found at $REVIEW_COMMENT_SCRIPT; skipping findings-history comment." >&2
    return 0
  fi
  if [ -z "$branch" ]; then
    echo "WARNING: PR head branch missing; skipping findings-history comment." >&2
    return 0
  fi

  history_file="$(review_findings_history_file "$branch")"
  if ! comment="$(format_findings_history_comment "$history_file")"; then
    echo "==> No actionable review findings history to comment."
    return 0
  fi

  if post_pr_review_comment "$PR_NUMBER" "$comment"; then
    echo "==> Posted findings-history PR comment."
    return 0
  fi

  echo "WARNING: failed to post findings-history PR comment for PR #$PR_NUMBER." >&2
  return 0
}

failed_checks() {
  gh pr checks "$PR_NUMBER" \
    --json name,bucket,state,link \
    --template '{{range .}}{{if eq .bucket "fail"}}{{.name}}{{"\t"}}{{.state}}{{"\t"}}{{.link}}{{"\n"}}{{end}}{{end}}' \
    2>/dev/null || true
}

unresolved_review_threads() {
  local query

  [ -n "$REPO_OWNER" ] || return 2
  [ -n "$REPO_NAME" ] || return 2

  query='
query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $endCursor) {
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          startLine
          comments(last: 1) {
            nodes {
              author { login }
              body
              url
            }
          }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
}'

  gh api graphql --paginate \
    -F owner="$REPO_OWNER" \
    -F name="$REPO_NAME" \
    -F number="$PR_NUMBER" \
    -f query="$query" \
    --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | [.id, .path, ((.line // .startLine // "") | tostring), (.isOutdated | tostring), (.comments.nodes[0].author.login // ""), (.comments.nodes[0].url // ""), ((.comments.nodes[0].body // "") | gsub("[\r\n\t]"; " ") | .[0:240])] | @tsv'
}

current_pr_head_or_die() {
  local phase="$1"
  local observed_head

  if ! observed_head="$(gh pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid' 2>&1)"; then
    echo "ERROR: Could not inspect PR #$PR_NUMBER head commit ($phase): $observed_head" >&2
    echo "       Refusing to merge without exact-head confirmation." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="head-not-updated"
    exit 1
  fi
  if [ -z "$observed_head" ]; then
    echo "ERROR: GitHub returned an empty head commit for PR #$PR_NUMBER ($phase)." >&2
    echo "       Refusing to merge without exact-head confirmation." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="head-not-updated"
    exit 1
  fi
  printf '%s' "$observed_head"
}

inspect_review_revision() {
  local expected_head="$1"
  local base_ref="$2"
  local phase="$3"
  local github_revision github_branch github_base local_base merge_base

  CURRENT_REVIEW_BASE_OID=""
  CURRENT_REVIEW_MERGE_BASE_OID=""

  if ! github_revision="$(current_pr_base_revision 2>&1)"; then
    echo "ERROR: Could not inspect PR #$PR_NUMBER base revision ($phase): $github_revision" >&2
    echo "       Refusing to authorize a merge against an unknown base." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="review-base-inspection"
    return 1
  fi
  IFS="$(printf '\t')" read -r github_branch github_base <<<"$github_revision"
  if [ -z "$github_branch" ] || [ -z "$github_base" ]; then
    echo "ERROR: GitHub returned an empty base revision for PR #$PR_NUMBER ($phase)." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="review-base-inspection"
    return 1
  fi
  if [ "$github_branch" != "$PR_BASE_BRANCH" ]; then
    echo "ERROR: PR #$PR_NUMBER was retargeted while inspecting the reviewed revision ($phase)." >&2
    echo "       reviewed base branch: $PR_BASE_BRANCH" >&2
    echo "       current base branch:  $github_branch" >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="review-base-changed"
    return 1
  fi
  if ! local_base="$(git rev-parse --verify "$base_ref^{commit}" 2>&1)"; then
    echo "ERROR: Could not resolve $base_ref while inspecting the reviewed revision ($phase): $local_base" >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="review-base-inspection"
    return 1
  fi
  if [ "$github_base" != "$local_base" ]; then
    echo "ERROR: PR #$PR_NUMBER base moved while inspecting the reviewed revision ($phase)." >&2
    echo "       GitHub base: $github_base" >&2
    echo "       local base:  $local_base" >&2
    echo "       Refresh and rerun the merge gate so review uses one base revision." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="review-base-changed"
    return 1
  fi
  if ! merge_base="$(git merge-base "$base_ref" "$expected_head" 2>&1)"; then
    echo "ERROR: Could not compute the merge base for PR #$PR_NUMBER ($phase): $merge_base" >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="review-base-inspection"
    return 1
  fi

  CURRENT_REVIEW_BASE_OID="$local_base"
  CURRENT_REVIEW_MERGE_BASE_OID="$merge_base"
  return 0
}

require_review_revision_unchanged() {
  local expected_head="$1"
  local base_ref="$PR_BASE_REF"
  local phase="$2"

  if [ -z "$REVIEWED_BASE_OID" ] || [ -z "$REVIEWED_MERGE_BASE_OID" ]; then
    echo "ERROR: No reviewed base revision was recorded for PR #$PR_NUMBER ($phase)." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="missing-reviewed-base"
    return 1
  fi

  if ! refresh_pr_base_ref "for reviewed-revision validation"; then
    TOUCHSTONE_MERGE_FAILURE_REASON="review-base-inspection"
    return 1
  fi
  inspect_review_revision "$expected_head" "$base_ref" "$phase" || return $?

  if [ "$CURRENT_REVIEW_BASE_OID" != "$REVIEWED_BASE_OID" ] \
    || [ "$CURRENT_REVIEW_MERGE_BASE_OID" != "$REVIEWED_MERGE_BASE_OID" ]; then
    echo "ERROR: PR #$PR_NUMBER base revision changed after semantic review." >&2
    echo "       reviewed base:       $REVIEWED_BASE_OID" >&2
    echo "       current base:        $CURRENT_REVIEW_BASE_OID" >&2
    echo "       reviewed merge base: $REVIEWED_MERGE_BASE_OID" >&2
    echo "       current merge base:  $CURRENT_REVIEW_MERGE_BASE_OID" >&2
    echo "       Update the branch and request a fresh exact-head review, then rerun the merge gate." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="review-base-changed"
    return 1
  fi
}

latest_trusted_pr_review_result() {
  local expected_head="$1"
  local query reviews author commit_oid state submitted_at url
  local candidate_clean candidate_detail
  local latest_submitted_at="" latest_clean=false latest_detail=""

  if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
    PR_TRIGGERED_REVIEW_INSPECTION_ERROR="formal reviews: repository identity is unavailable"
    return 2
  fi

  query='
query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviews(first: 100, after: $endCursor) {
        nodes {
          author { login }
          state
          submittedAt
          url
          commit { oid }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
}'

  if ! reviews="$(gh api graphql --paginate \
    -F owner="$REPO_OWNER" \
    -F name="$REPO_NAME" \
    -F number="$PR_NUMBER" \
    -f query="$query" \
    --jq '.data.repository.pullRequest.reviews.nodes[] | [(.author.login // ""), (.commit.oid // ""), (.state // ""), (.submittedAt // ""), (.url // "")] | @tsv' 2>&1)"; then
    PR_TRIGGERED_REVIEW_INSPECTION_ERROR="formal reviews: $reviews"
    return 2
  fi

  while IFS="$(printf '\t')" read -r author commit_oid state submitted_at url || [ -n "$author" ]; do
    [ -n "$author" ] || continue
    csv_contains "$PR_TRIGGERED_REVIEW_TRUSTED_REVIEW_AUTHORS" "$author" || continue
    [ "$commit_oid" = "$expected_head" ] || continue
    [ -n "$submitted_at" ] || continue
    candidate_clean=false
    [ "$state" = "APPROVED" ] && candidate_clean=true
    candidate_detail="formal review by @$author ($state) at $submitted_at"
    [ -n "$url" ] && candidate_detail="$candidate_detail: $url"
    if [ -n "$latest_submitted_at" ] && [[ "$submitted_at" < "$latest_submitted_at" ]]; then
      continue
    fi
    if [ -z "$latest_submitted_at" ] || [[ "$submitted_at" > "$latest_submitted_at" ]]; then
      latest_submitted_at="$submitted_at"
      latest_clean="$candidate_clean"
      latest_detail="$candidate_detail"
      continue
    fi
    if [ "$candidate_clean" != true ]; then
      latest_clean=false
    fi
    latest_detail="$latest_detail; $candidate_detail"
  done <<<"$reviews"

  [ -n "$latest_submitted_at" ] || return 1
  PR_TRIGGERED_REVIEW_CANDIDATE_TIMESTAMP="$latest_submitted_at"
  PR_TRIGGERED_REVIEW_CANDIDATE_CLEAN="$latest_clean"
  PR_TRIGGERED_REVIEW_CANDIDATE_DETAIL="$latest_detail"
  return 0
}

latest_trusted_pr_comment_result() {
  local expected_head="$1"
  local comments author created_at url body expected_head_short resolved_comment_commit=""
  local comment_commit_resolved=false
  local candidate_clean candidate_detail result_label
  local latest_created_at="" latest_clean=false latest_detail=""

  if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
    PR_TRIGGERED_REVIEW_INSPECTION_ERROR="review comments: repository identity is unavailable"
    return 2
  fi

  expected_head_short="$(printf '%.10s' "$expected_head")"
  if ! comments="$(gh api --paginate "repos/$REPO_OWNER/$REPO_NAME/issues/$PR_NUMBER/comments" \
    --jq '.[] | [(.user.login // ""), (.created_at // ""), (.html_url // ""), ((.body // "") | gsub("[\r\n\t]"; " "))] | @tsv' 2>&1)"; then
    PR_TRIGGERED_REVIEW_INSPECTION_ERROR="review comments: $comments"
    return 2
  fi

  while IFS="$(printf '\t')" read -r author created_at url body || [ -n "$author" ]; do
    [ -n "$author" ] || continue
    csv_contains "$PR_TRIGGERED_REVIEW_TRUSTED_REVIEW_AUTHORS" "$author" || continue
    [ -n "$created_at" ] || continue
    case "$body" in
      *"Reviewed commit:"*"\`$expected_head_short\`"*) ;;
      *) continue ;;
    esac
    if [ "$comment_commit_resolved" = false ]; then
      if ! resolved_comment_commit="$(gh api "repos/$REPO_OWNER/$REPO_NAME/commits/$expected_head_short" \
        --jq '.sha' 2>&1)"; then
        PR_TRIGGERED_REVIEW_INSPECTION_ERROR="reviewed commit resolution: $resolved_comment_commit"
        return 2
      fi
      comment_commit_resolved=true
    fi
    [ "$resolved_comment_commit" = "$expected_head" ] || continue
    candidate_clean=false
    result_label="non-clean"
    case "$body" in
      "Codex Review: Didn't find any major issues."* | "Codex Review: No major issues."*)
        candidate_clean=true
        result_label="clean"
        ;;
    esac
    candidate_detail="$result_label Codex review comment by @$author at $created_at"
    [ -n "$url" ] && candidate_detail="$candidate_detail: $url"
    if [ -n "$latest_created_at" ] && [[ "$created_at" < "$latest_created_at" ]]; then
      continue
    fi
    if [ -z "$latest_created_at" ] || [[ "$created_at" > "$latest_created_at" ]]; then
      latest_created_at="$created_at"
      latest_clean="$candidate_clean"
      latest_detail="$candidate_detail"
      continue
    fi
    if [ "$candidate_clean" != true ]; then
      latest_clean=false
    fi
    latest_detail="$latest_detail; $candidate_detail"
  done <<<"$comments"

  [ -n "$latest_created_at" ] || return 1
  PR_TRIGGERED_REVIEW_CANDIDATE_TIMESTAMP="$latest_created_at"
  PR_TRIGGERED_REVIEW_CANDIDATE_CLEAN="$latest_clean"
  PR_TRIGGERED_REVIEW_CANDIDATE_DETAIL="$latest_detail"
  return 0
}

trusted_pr_clean_signal() {
  local expected_head="$1"
  local expected_base="$2"
  local request_timestamp="$3"
  local result_status
  local review_found=false review_timestamp="" review_clean=false review_detail=""
  local comment_found=false comment_timestamp="" comment_clean=false comment_detail=""
  local review_same_second=false comment_same_second=false
  local review_inspection_error="" comment_inspection_error=""

  PR_TRIGGERED_REVIEW_INSPECTION_ERROR=""
  if [ -z "$expected_base" ]; then
    PR_TRIGGERED_REVIEW_INSPECTION_ERROR="review evidence is not bound to the current base revision"
    return 2
  fi
  if [ -z "$request_timestamp" ] && truthy "$PR_TRIGGERED_REVIEW_REQUEST_ON_PUSH"; then
    PR_TRIGGERED_REVIEW_INSPECTION_ERROR="review evidence is missing durable request freshness"
    return 2
  fi
  if latest_trusted_pr_review_result "$expected_head"; then
    review_timestamp="$PR_TRIGGERED_REVIEW_CANDIDATE_TIMESTAMP"
    if [ -z "$request_timestamp" ] || [[ "$review_timestamp" > "$request_timestamp" ]]; then
      review_found=true
      review_clean="$PR_TRIGGERED_REVIEW_CANDIDATE_CLEAN"
      review_detail="$PR_TRIGGERED_REVIEW_CANDIDATE_DETAIL"
    elif [ -n "$request_timestamp" ] && [ "$review_timestamp" = "$request_timestamp" ]; then
      review_same_second=true
    fi
  else
    result_status=$?
    if [ "$result_status" -eq 2 ]; then
      review_inspection_error="$PR_TRIGGERED_REVIEW_INSPECTION_ERROR"
    fi
  fi
  if latest_trusted_pr_comment_result "$expected_head"; then
    comment_timestamp="$PR_TRIGGERED_REVIEW_CANDIDATE_TIMESTAMP"
    if [ -z "$request_timestamp" ] || [[ "$comment_timestamp" > "$request_timestamp" ]]; then
      comment_found=true
      comment_clean="$PR_TRIGGERED_REVIEW_CANDIDATE_CLEAN"
      comment_detail="$PR_TRIGGERED_REVIEW_CANDIDATE_DETAIL"
    elif [ -n "$request_timestamp" ] && [ "$comment_timestamp" = "$request_timestamp" ]; then
      comment_same_second=true
    fi
  else
    result_status=$?
    if [ "$result_status" -eq 2 ]; then
      comment_inspection_error="$PR_TRIGGERED_REVIEW_INSPECTION_ERROR"
    fi
  fi

  if [ -n "$review_inspection_error" ] || [ -n "$comment_inspection_error" ]; then
    PR_TRIGGERED_REVIEW_INSPECTION_ERROR="$review_inspection_error"
    if [ -n "$comment_inspection_error" ]; then
      if [ -n "$PR_TRIGGERED_REVIEW_INSPECTION_ERROR" ]; then
        PR_TRIGGERED_REVIEW_INSPECTION_ERROR="$PR_TRIGGERED_REVIEW_INSPECTION_ERROR; "
      fi
      PR_TRIGGERED_REVIEW_INSPECTION_ERROR="$PR_TRIGGERED_REVIEW_INSPECTION_ERROR$comment_inspection_error"
    fi
    return 2
  fi

  # GitHub timestamps have second precision. Equal timestamps cannot prove
  # that review evidence followed the base-bound request, so fail closed.
  if [ "$review_found" != true ] && [ "$comment_found" != true ] \
    && { [ "$review_same_second" = true ] || [ "$comment_same_second" = true ]; }; then
    PR_TRIGGERED_REVIEW_INSPECTION_ERROR="review evidence has the same second-level timestamp as its request; request a fresh review"
    return 2
  fi

  if [ "$review_found" = true ] && [ "$comment_found" = true ]; then
    if [[ "$review_timestamp" > "$comment_timestamp" ]]; then
      PR_TRIGGERED_REVIEW_SIGNAL_DETAIL="$review_detail"
      [ "$review_clean" = true ] && return 0
      return 3
    fi
    if [[ "$comment_timestamp" > "$review_timestamp" ]]; then
      PR_TRIGGERED_REVIEW_SIGNAL_DETAIL="$comment_detail"
      [ "$comment_clean" = true ] && return 0
      return 3
    fi
    PR_TRIGGERED_REVIEW_SIGNAL_DETAIL="$review_detail; $comment_detail"
    if [ "$review_clean" = true ] && [ "$comment_clean" = true ]; then
      return 0
    fi
    return 3
  fi
  if [ "$review_found" = true ]; then
    PR_TRIGGERED_REVIEW_SIGNAL_DETAIL="$review_detail"
    [ "$review_clean" = true ] && return 0
    return 3
  fi
  if [ "$comment_found" = true ]; then
    PR_TRIGGERED_REVIEW_SIGNAL_DETAIL="$comment_detail"
    [ "$comment_clean" = true ] && return 0
    return 3
  fi
  return 1
}

wait_for_pr_triggered_review() {
  local expected_head="$1"
  local phase="$2"
  local timeout_sec poll_sec start_epoch now_epoch elapsed observed_head observed_revision observed_branch observed_base sleep_seconds
  local last_inspection_error="" last_review_inspection_error="" request_status signal_status

  if [ "$PR_TRIGGERED_REVIEW_PROVIDER" != "github-codex" ]; then
    echo "ERROR: Unsupported [review.pr_triggered].provider: $PR_TRIGGERED_REVIEW_PROVIDER" >&2
    echo "       Supported provider: github-codex" >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-triggered-review-config"
    exit 1
  fi
  if ! is_nonnegative_integer "$PR_TRIGGERED_REVIEW_TIMEOUT_SEC"; then
    echo "ERROR: [review.pr_triggered].timeout_sec must be a non-negative integer." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-triggered-review-config"
    exit 2
  fi
  if ! is_nonnegative_integer "$PR_TRIGGERED_REVIEW_POLL_SEC"; then
    echo "ERROR: [review.pr_triggered].poll_sec must be a non-negative integer." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-triggered-review-config"
    exit 2
  fi
  if [ "$PR_TRIGGERED_REVIEW_TIMEOUT_SEC" -gt 0 ] && [ "$PR_TRIGGERED_REVIEW_POLL_SEC" -eq 0 ]; then
    echo "ERROR: [review.pr_triggered].poll_sec must be positive when timeout_sec is positive." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-triggered-review-config"
    exit 2
  fi

  timeout_sec="$PR_TRIGGERED_REVIEW_TIMEOUT_SEC"
  poll_sec="$PR_TRIGGERED_REVIEW_POLL_SEC"
  start_epoch="$(date +%s)"
  PR_TRIGGERED_REVIEW_SIGNAL_DETAIL=""
  PR_TRIGGERED_REVIEW_BASE_BOUND=false
  PR_TRIGGERED_REVIEW_REQUEST_BASE_OID=""
  PR_TRIGGERED_REVIEW_REQUEST_TIMESTAMP=""
  PR_TRIGGERED_REVIEW_REQUEST_INTENT_TIMESTAMP=""

  echo "==> Waiting for trusted PR-visible AI review for PR #$PR_NUMBER ($phase) ..."
  echo "    provider=$PR_TRIGGERED_REVIEW_PROVIDER expected_head=$expected_head timeout=${timeout_sec}s"

  while true; do
    if observed_head="$(gh pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid' 2>&1)"; then
      last_inspection_error=""
    else
      last_inspection_error="$observed_head"
      observed_head=""
    fi
    if [ -n "$observed_head" ] && [ "$observed_head" != "$expected_head" ]; then
      echo "ERROR: PR #$PR_NUMBER head changed while waiting for PR-triggered AI review." >&2
      echo "       expected: $expected_head" >&2
      echo "       actual:   $observed_head" >&2
      echo "       Rerun the merge gate on the current head." >&2
      TOUCHSTONE_MERGE_FAILURE_REASON="head-not-updated"
      exit 1
    fi

    if [ "$observed_head" = "$expected_head" ]; then
      if observed_revision="$(current_pr_base_revision 2>&1)"; then
        IFS="$(printf '\t')" read -r observed_branch observed_base <<<"$observed_revision"
        if [ -z "$observed_branch" ] || [ -z "$observed_base" ]; then
          last_inspection_error="GitHub returned an empty base revision"
        elif [ "$observed_branch" != "$PR_BASE_BRANCH" ]; then
          echo "ERROR: PR #$PR_NUMBER was retargeted while waiting for PR-triggered AI review." >&2
          echo "       expected base branch: $PR_BASE_BRANCH" >&2
          echo "       actual base branch:   $observed_branch" >&2
          TOUCHSTONE_MERGE_FAILURE_REASON="review-base-changed"
          exit 1
        fi
      else
        last_inspection_error="$observed_revision"
        observed_base=""
      fi
    else
      observed_base=""
    fi

    if [ "$observed_head" = "$expected_head" ] && [ -n "$observed_base" ]; then
      request_status=0
      if [ "$PR_TRIGGERED_REVIEW_REQUEST_BASE_OID" != "$observed_base" ]; then
        PR_TRIGGERED_REVIEW_REQUEST_TIMESTAMP=""
        request_pr_triggered_review "$expected_head" "$observed_base" "$phase" || request_status=$?
        if [ "$request_status" -eq 2 ]; then
          last_review_inspection_error="review request markers: ${PR_TRIGGERED_REVIEW_REQUEST_INSPECTION_ERROR:-unknown GitHub API failure}"
        elif [ "$request_status" -ne 0 ]; then
          exit 1
        fi
      fi
      if [ "$request_status" -eq 0 ]; then
        if trusted_pr_clean_signal "$expected_head" "$observed_base" "$PR_TRIGGERED_REVIEW_REQUEST_TIMESTAMP"; then
          signal_status=0
        else
          signal_status=$?
        fi
        if [ "$signal_status" -eq 0 ]; then
          PR_TRIGGERED_REVIEWED_HEAD_OID="$expected_head"
          if [ -n "$PR_TRIGGERED_REVIEW_REQUEST_TIMESTAMP" ]; then
            PR_TRIGGERED_REVIEWED_BASE_OID="$observed_base"
            PR_TRIGGERED_REVIEW_BASE_BOUND=true
          else
            PR_TRIGGERED_REVIEWED_BASE_OID=""
          fi
          echo "==> Trusted PR-visible AI review found for PR #$PR_NUMBER head $expected_head."
          echo "    reviewed_base=$observed_base"
          [ -n "$PR_TRIGGERED_REVIEW_SIGNAL_DETAIL" ] && echo "    $PR_TRIGGERED_REVIEW_SIGNAL_DETAIL"
          return 0
        fi
        if [ "$signal_status" -eq 2 ]; then
          last_review_inspection_error="$PR_TRIGGERED_REVIEW_INSPECTION_ERROR"
        elif [ "$signal_status" -eq 3 ]; then
          echo "ERROR: Trusted PR-visible AI review is not clean for PR #$PR_NUMBER head $expected_head." >&2
          [ -n "$PR_TRIGGERED_REVIEW_SIGNAL_DETAIL" ] && echo "       $PR_TRIGGERED_REVIEW_SIGNAL_DETAIL" >&2
          echo "       Address the findings, push the fix, and request a fresh exact-head review." >&2
          TOUCHSTONE_MERGE_FAILURE_REASON="pr-triggered-review-findings"
          exit 1
        else
          last_review_inspection_error=""
        fi
      fi
    fi

    now_epoch="$(date +%s)"
    elapsed=$((now_epoch - start_epoch))
    if [ "$elapsed" -ge "$timeout_sec" ]; then
      break
    fi
    sleep_seconds="$poll_sec"
    if [ -n "${MERGE_PR_SLEEP_OVERRIDE+x}" ]; then
      sleep_seconds="$MERGE_PR_SLEEP_OVERRIDE"
    fi
    sleep "$sleep_seconds"
  done

  if [ -n "$last_inspection_error" ]; then
    echo "ERROR: Failed to inspect PR #$PR_NUMBER head or base revision while waiting for PR-triggered AI review." >&2
    echo "       phase: $phase" >&2
    echo "       last gh error: $(printf '%s' "$last_inspection_error" | tr '\n' ' ')" >&2
    echo "       Verify GitHub authentication and API availability, then rerun the merge gate." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-triggered-review-inspection"
    exit 1
  fi

  if [ -n "$last_review_inspection_error" ]; then
    echo "ERROR: Failed to inspect trusted PR-visible AI review evidence for PR #$PR_NUMBER." >&2
    echo "       phase: $phase" >&2
    echo "       last gh error: $(printf '%s' "$last_review_inspection_error" | tr '\n' ' ')" >&2
    echo "       Verify GitHub authentication and API availability, then rerun the merge gate." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-triggered-review-inspection"
    exit 1
  fi

  echo "ERROR: Timed out waiting for trusted PR-visible AI review for PR #$PR_NUMBER." >&2
  echo "       phase: $phase" >&2
  echo "       expected head: $expected_head" >&2
  echo "       provider: $PR_TRIGGERED_REVIEW_PROVIDER" >&2
  echo "       Confirm GitHub Codex automatic reviews are enabled, or comment '@codex review' on the PR." >&2
  echo "       Then rerun: bash scripts/open-pr.sh --auto-merge" >&2
  TOUCHSTONE_MERGE_FAILURE_REASON="pr-triggered-review-timeout"
  exit 1
}

load_pr_review_request_timestamp() {
  local expected_head="$1"
  local expected_base="$2"
  local records context created_at _creator creator_permission description request_base intent_at trigger_at
  local matching_intents="" matching_completions="" trusted_records=false conflicting_bases=""

  PR_TRIGGERED_REVIEW_REQUEST_INSPECTION_ERROR=""
  PR_TRIGGERED_REVIEW_REQUEST_INTENT_TIMESTAMP=""
  PR_TRIGGERED_REVIEW_REQUEST_TIMESTAMP=""
  if ! records="$(
    gh api --paginate "repos/$REPO_FULL_NAME/commits/$expected_head/statuses?per_page=100" \
      --jq '.[] |
        select(
          .context == "touchstone/review-request-intent" or
          .context == "touchstone/review-request-complete"
        ) |
        select(.state == "success") |
        [
          .context,
          .created_at,
          .creator.login,
          .description
        ] |
        @tsv' 2>&1
  )"; then
    PR_TRIGGERED_REVIEW_REQUEST_INSPECTION_ERROR="$records"
    return 2
  fi

  while IFS="$(printf '\t')" read -r context created_at _creator description || [ -n "$context" ]; do
    if ! creator_permission="$(
      gh api "repos/$REPO_FULL_NAME/collaborators/$_creator/permission" --jq '.permission' 2>/dev/null
    )"; then
      creator_permission=""
    fi
    case "$creator_permission" in
      admin | maintain | write) ;;
      *)
        echo "ERROR: PR #$PR_NUMBER head $expected_head has review-request status from untrusted creator '$_creator'." >&2
        echo "       Update the PR head so untrusted status records cannot authorize or suppress review." >&2
        TOUCHSTONE_MERGE_FAILURE_REASON="review-request-untrusted-creator"
        return 3
        ;;
    esac
    case "$context" in
      touchstone/review-request-intent)
        request_base="${description#base=}"
        [ "$request_base" != "$description" ] || continue
        intent_at="$created_at"
        ;;
      touchstone/review-request-complete)
        request_base="${description#base=}"
        request_base="${request_base%% intent=*}"
        intent_at="${description#* intent=}"
        intent_at="${intent_at%% trigger=*}"
        trigger_at="${description##* trigger=}"
        case "$description" in
          base=*' intent='*' trigger='*) ;;
          *) continue ;;
        esac
        ;;
      *) continue ;;
    esac
    trusted_records=true
    if [ "$request_base" != "$expected_base" ]; then
      conflicting_bases="${conflicting_bases}${conflicting_bases:+, }$request_base"
    elif [ "$context" = "touchstone/review-request-intent" ]; then
      matching_intents="${matching_intents}${matching_intents:+$'\n'}$intent_at"
    else
      matching_completions="${matching_completions}${matching_completions:+$'\n'}$intent_at"$'\t'"$trigger_at"
    fi
  done <<<"$records"

  if [ -n "$conflicting_bases" ]; then
    echo "ERROR: PR #$PR_NUMBER head $expected_head has trusted review requests for multiple base revisions." >&2
    echo "       current base:  $expected_base" >&2
    echo "       prior base(s): $conflicting_bases" >&2
    echo "       Update the PR head, then request a fresh review so old in-flight results cannot authorize the new base." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="review-request-base-conflict"
    return 3
  fi

  if [ "$trusted_records" = "false" ]; then
    return 4
  fi

  PR_TRIGGERED_REVIEW_REQUEST_INTENT_TIMESTAMP="$(
    printf '%s\n' "$matching_intents" | sed '/^$/d' | sort | tail -n 1
  )"
  PR_TRIGGERED_REVIEW_REQUEST_TIMESTAMP="$(
    while IFS="$(printf '\t')" read -r intent_at trigger_at; do
      [ -n "$intent_at" ] || continue
      printf '%s\n' "$matching_intents" | grep -Fxq "$intent_at" || continue
      printf '%s\n' "$trigger_at"
    done <<<"$matching_completions" | sort | tail -n 1
  )"
}

request_pr_triggered_review() {
  local expected_head="$1"
  local expected_base="$2"
  local phase="$3"
  local allow_status_bootstrap="${4:-false}"
  local observed_head observed_revision observed_branch observed_base marker body trigger_at created_at
  local request_lookup_status=0

  if ! truthy "$PR_TRIGGERED_REVIEW_REQUEST_ON_PUSH"; then
    return 0
  fi
  if [ "$PR_TRIGGERED_REVIEW_PROVIDER" != "github-codex" ]; then
    echo "ERROR: request_on_push only supports [review.pr_triggered].provider = \"github-codex\"." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-triggered-review-config"
    return 1
  fi
  if ! observed_head="$(gh pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid')"; then
    echo "ERROR: Failed to resolve PR #$PR_NUMBER head before requesting review ($phase)." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-triggered-review-request"
    return 1
  fi
  if [ "$observed_head" != "$expected_head" ]; then
    echo "ERROR: Refusing to request review for PR #$PR_NUMBER before its head converges." >&2
    echo "       expected: $expected_head" >&2
    echo "       actual:   ${observed_head:-<empty>}" >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-triggered-review-request"
    return 1
  fi
  if ! observed_revision="$(current_pr_base_revision 2>&1)"; then
    echo "ERROR: Failed to resolve PR #$PR_NUMBER base before requesting review ($phase): $observed_revision" >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-triggered-review-request"
    return 1
  fi
  IFS="$(printf '\t')" read -r observed_branch observed_base <<<"$observed_revision"
  if [ "$observed_branch" != "$PR_BASE_BRANCH" ] || [ "$observed_base" != "$expected_base" ]; then
    echo "ERROR: Refusing to request review for PR #$PR_NUMBER after its base changed." >&2
    echo "       expected: $PR_BASE_BRANCH@$expected_base" >&2
    echo "       actual:   ${observed_branch:-<empty>}@${observed_base:-<empty>}" >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-triggered-review-request"
    return 1
  fi

  marker="<!-- touchstone:pr-review-request provider=github-codex head=$expected_head base=$expected_base -->"
  load_pr_review_request_timestamp "$expected_head" "$expected_base" || request_lookup_status=$?
  if [ "$request_lookup_status" -ne 0 ]; then
    if [ "$request_lookup_status" -eq 3 ]; then
      return 3
    fi
    if [ "$request_lookup_status" -eq 4 ]; then
      if [ "$allow_status_bootstrap" != "true" ]; then
        echo "ERROR: PR #$PR_NUMBER head $expected_head has no durable review-request evidence." >&2
        echo "       The merge gate did not create or advance this head, so legacy review state is ambiguous." >&2
        echo "       Push a fresh head with scripts/open-pr.sh before requesting review." >&2
        TOUCHSTONE_MERGE_FAILURE_REASON="review-request-legacy-head"
        return 3
      fi
    else
      return 2
    fi
  fi
  PR_TRIGGERED_REVIEW_REQUEST_BASE_OID="$expected_base"
  if [ -n "$PR_TRIGGERED_REVIEW_REQUEST_TIMESTAMP" ]; then
    echo "==> GitHub Codex review already requested for head $expected_head at base $expected_base."
    return 0
  fi

  if [ -z "$PR_TRIGGERED_REVIEW_REQUEST_INTENT_TIMESTAMP" ]; then
    if ! PR_TRIGGERED_REVIEW_REQUEST_INTENT_TIMESTAMP="$(
      gh api -X POST "repos/$REPO_FULL_NAME/statuses/$expected_head" \
        -f state=success \
        -f context=touchstone/review-request-intent \
        -f description="base=$expected_base" \
        --jq '.created_at'
    )"; then
      echo "ERROR: Failed to record review-request intent for PR #$PR_NUMBER ($phase)." >&2
      TOUCHSTONE_MERGE_FAILURE_REASON="pr-triggered-review-request"
      return 1
    fi
  fi
  if [ -z "$PR_TRIGGERED_REVIEW_REQUEST_INTENT_TIMESTAMP" ]; then
    echo "ERROR: GitHub returned no timestamp for review-request intent." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-triggered-review-request"
    return 1
  fi

  body="$(printf '@codex review\n\n%s' "$marker")"
  if ! trigger_at="$(gh api -X POST "repos/$REPO_FULL_NAME/issues/$PR_NUMBER/comments" \
    -f body="$body" --jq '.created_at')"; then
    echo "ERROR: Failed to request GitHub Codex review for PR #$PR_NUMBER ($phase)." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-triggered-review-request"
    return 1
  fi
  if [ -z "$trigger_at" ]; then
    echo "ERROR: GitHub returned no timestamp for the review trigger comment." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-triggered-review-request"
    return 1
  fi
  if ! created_at="$(gh api -X POST "repos/$REPO_FULL_NAME/statuses/$expected_head" \
    -f state=success \
    -f context=touchstone/review-request-complete \
    -f description="base=$expected_base intent=$PR_TRIGGERED_REVIEW_REQUEST_INTENT_TIMESTAMP trigger=$trigger_at" \
    --jq '.created_at')"; then
    echo "ERROR: Failed to record durable review-request evidence for PR #$PR_NUMBER ($phase)." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-triggered-review-request"
    return 1
  fi
  if [ -z "$created_at" ]; then
    echo "ERROR: GitHub returned no timestamp for durable review-request evidence." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-triggered-review-request"
    return 1
  fi
  PR_TRIGGERED_REVIEW_REQUEST_TIMESTAMP="$trigger_at"
  echo "==> Requested GitHub Codex review for head $expected_head at base $expected_base ($phase)."
}

print_unresolved_review_threads() {
  local threads="$1"
  local count=0
  local id path line outdated author url body

  while IFS="$(printf '\t')" read -r id path line outdated author url body || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    count=$((count + 1))
    if [ -n "$line" ]; then
      printf '       - %s:%s' "${path:-<unknown>}" "$line" >&2
    else
      printf '       - %s' "${path:-<unknown>}" >&2
    fi
    [ -n "$author" ] && printf ' by @%s' "$author" >&2
    [ "$outdated" = "true" ] && printf ' (outdated)' >&2
    printf '\n' >&2
    [ -n "$url" ] && printf '         %s\n' "$url" >&2
    [ -n "$body" ] && printf '         %s\n' "$body" >&2
  done <<<"$threads"

  return "$count"
}

require_pr_feedback_clear() {
  local phase="$1"
  local expected_head="${2:-}"
  local is_draft review_decision observed_head threads thread_count

  echo "==> Checking PR-visible review feedback for PR #$PR_NUMBER ($phase) ..."

  if ! is_draft="$(gh pr view "$PR_NUMBER" --json isDraft --jq '.isDraft' 2>&1)"; then
    echo "ERROR: Could not inspect draft state for PR #$PR_NUMBER: $is_draft" >&2
    echo "       Refusing to merge without draft-state confirmation." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-feedback-state"
    exit 1
  fi
  if [ -z "$is_draft" ]; then
    echo "ERROR: GitHub returned an empty draft state for PR #$PR_NUMBER." >&2
    echo "       Refusing to merge without draft-state confirmation." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-feedback-state"
    exit 1
  fi
  if [ "$is_draft" = "true" ]; then
    echo "ERROR: PR #$PR_NUMBER is still a draft; refusing to merge." >&2
    echo "       Mark it ready for review, then rerun: bash scripts/open-pr.sh --auto-merge" >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-feedback-blocked"
    exit 1
  fi

  if [ -n "$expected_head" ]; then
    if ! observed_head="$(gh pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid' 2>&1)"; then
      echo "ERROR: Could not inspect PR #$PR_NUMBER head commit: $observed_head" >&2
      echo "       Refusing to merge without exact-head confirmation." >&2
      TOUCHSTONE_MERGE_FAILURE_REASON="pr-feedback-state"
      exit 1
    fi
    if [ -z "$observed_head" ]; then
      echo "ERROR: GitHub returned an empty head commit for PR #$PR_NUMBER." >&2
      echo "       Refusing to merge without exact-head confirmation." >&2
      TOUCHSTONE_MERGE_FAILURE_REASON="pr-feedback-state"
      exit 1
    fi
    if [ "$observed_head" != "$expected_head" ]; then
      echo "ERROR: PR #$PR_NUMBER head changed while checking review feedback." >&2
      echo "       expected: $expected_head" >&2
      echo "       actual:   $observed_head" >&2
      echo "       Rerun the merge gate on the current head." >&2
      TOUCHSTONE_MERGE_FAILURE_REASON="head-not-updated"
      exit 1
    fi
  fi

  if ! review_decision="$(gh pr view "$PR_NUMBER" --json reviewDecision --jq '.reviewDecision // empty' 2>&1)"; then
    echo "ERROR: Could not inspect review decision for PR #$PR_NUMBER: $review_decision" >&2
    echo "       Refusing to merge without review-decision confirmation." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-feedback-state"
    exit 1
  fi
  if [ "$review_decision" = "CHANGES_REQUESTED" ]; then
    echo "ERROR: PR #$PR_NUMBER has an active CHANGES_REQUESTED review decision." >&2
    echo "       Address the requested changes, push fixes, and rerun: bash scripts/open-pr.sh --auto-merge" >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-feedback-blocked"
    exit 1
  fi

  threads="$(unresolved_review_threads)" || {
    echo "ERROR: Could not inspect PR #$PR_NUMBER review threads via GitHub GraphQL." >&2
    if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
      echo "       Repository name could not be resolved from 'gh repo view --json nameWithOwner'." >&2
    fi
    echo "       Refusing to merge without thread-level review state." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-feedback-state"
    exit 1
  }

  if [ -n "$threads" ]; then
    echo "ERROR: PR #$PR_NUMBER has unresolved review thread(s)." >&2
    print_unresolved_review_threads "$threads" || thread_count="$?"
    thread_count="${thread_count:-0}"
    echo "       Resolve or explicitly answer every actionable thread, then rerun: bash scripts/open-pr.sh --auto-merge" >&2
    if [ "$thread_count" -gt 100 ]; then
      echo "       Listed first page(s) reported by GitHub; inspect the PR for the complete thread list." >&2
    fi
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-feedback-blocked"
    exit 1
  fi

  echo "==> PR-visible review feedback clear."
}

print_failed_checks_and_exit() {
  local failed_checks="$1"
  local name state link

  [ -n "$failed_checks" ] || return 1

  echo "ERROR: PR #$PR_NUMBER has failed check(s); stopping automerge." >&2
  while IFS="$(printf '\t')" read -r name state link || [ -n "$name" ]; do
    [ -n "$name" ] || continue
    if [ -n "$link" ]; then
      echo "       - $name (${state:-failed}): $link" >&2
    else
      echo "       - $name (${state:-failed})" >&2
    fi
  done <<<"$failed_checks"
  TOUCHSTONE_MERGE_FAILURE_REASON="check-failed"
  exit 1
}

wait_for_clean_merge_state() {
  local attempt max_attempts sleep_seconds

  echo "==> Checking merge state for PR #$PR_NUMBER ..."
  STATE=""
  MERGEABLE=""
  MERGE_STATE_RETRY_DELAYS=(1 2 5 10 30 30 30 30 30)
  max_attempts="${MERGE_PR_STATE_MAX_ATTEMPTS:-30}"
  if ! [[ "$max_attempts" =~ ^[0-9]+$ ]] || [ "$max_attempts" -lt 1 ]; then
    max_attempts=30
  fi
  attempt=1
  while [ "$attempt" -le "$max_attempts" ]; do
    MERGE_STATE="$(gh pr view "$PR_NUMBER" --json mergeStateStatus,mergeable --template '{{.mergeStateStatus}} {{.mergeable}}' 2>/dev/null || echo '')"
    STATE="${MERGE_STATE%% *}"
    MERGEABLE="${MERGE_STATE#* }"
    [ -n "$STATE" ] || STATE="UNKNOWN"
    [ -n "$MERGEABLE" ] || MERGEABLE="UNKNOWN"
    echo "    attempt $attempt: mergeStateStatus=$STATE mergeable=$MERGEABLE"
    if [ "$STATE" = "CLEAN" ] && [ "$MERGEABLE" = "MERGEABLE" ]; then
      return 0
    fi
    FAILED_CHECKS="$(failed_checks)"
    if [ -n "$FAILED_CHECKS" ]; then
      print_failed_checks_and_exit "$FAILED_CHECKS"
    fi
    if [ "$MERGEABLE" = "CONFLICTING" ] || [ "$STATE" = "DIRTY" ] || [ "$STATE" = "BEHIND" ] || [ "$STATE" = "CONFLICTING" ]; then
      echo "ERROR: PR #$PR_NUMBER is $STATE — has conflicts or is out of date with base." >&2
      echo "       Final merge state: mergeStateStatus=$STATE mergeable=$MERGEABLE." >&2
      echo "       Rebase or resolve conflicts on the PR branch before merging." >&2
      TOUCHSTONE_MERGE_FAILURE_REASON="not-mergeable"
      exit 1
    fi
    if [ "$attempt" -lt "$max_attempts" ]; then
      sleep_seconds="${MERGE_STATE_RETRY_DELAYS[$((attempt - 1))]:-30}"
      # Tests may set MERGE_PR_SLEEP_OVERRIDE=0 to exercise retry behavior
      # without waiting for the production backoff schedule.
      if [ -n "${MERGE_PR_SLEEP_OVERRIDE+x}" ]; then
        sleep_seconds="$MERGE_PR_SLEEP_OVERRIDE"
      fi
      sleep "$sleep_seconds"
    fi
    attempt=$((attempt + 1))
  done

  echo "ERROR: PR #$PR_NUMBER is not cleanly mergeable (state=$STATE mergeable=$MERGEABLE)." >&2
  echo "       Required checks may still be pending; waited $max_attempts merge-state attempts." >&2
  echo "       Inspect manually: gh pr view $PR_NUMBER --web" >&2
  TOUCHSTONE_MERGE_FAILURE_REASON="not-mergeable"
  exit 1
}

wait_for_pr_head() {
  local expected_head="$1"
  local actual_head sleep_seconds

  for attempt in 1 2 3 4 5; do
    actual_head="$(gh pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo "")"
    if [ "$actual_head" = "$expected_head" ]; then
      return 0
    fi
    echo "    waiting for PR head update (attempt $attempt): ${actual_head:-unknown}"
    if [ "$attempt" -lt 5 ]; then
      sleep_seconds="${MERGE_PR_SLEEP_OVERRIDE:-2}"
      sleep "$sleep_seconds"
    fi
  done

  echo "ERROR: PR #$PR_NUMBER head did not update to reviewed commit $expected_head." >&2
  echo "       Last observed head: ${actual_head:-unknown}" >&2
  TOUCHSTONE_MERGE_FAILURE_REASON="head-not-updated"
  exit 1
}

run_preflight_gate() {
  local base_ref="$1"
  local label="${2:-before merge review}"
  local event_mode="${3:-merge}"
  local head_sha cache_key_short

  if ! truthy "$PREFLIGHT_REQUIRED"; then
    echo "==> Preflight disabled by [review].preflight_required=false."
    return 0
  fi
  if truthy "${TOUCHSTONE_NO_PREFLIGHT:-false}"; then
    echo "==> Skipping preflight because TOUCHSTONE_NO_PREFLIGHT=1."
    return 0
  fi
  if ! declare -F touchstone_preflight_main >/dev/null 2>&1; then
    echo "==> Preflight helper not found at $PREFLIGHT_SCRIPT — skipping preflight."
    return 0
  fi

  head_sha="$(git rev-parse HEAD 2>/dev/null || echo "")"
  if preflight_cache_prepare "$base_ref" "$event_mode" && preflight_cache_hit; then
    cache_key_short="$(preflight_cache_short_key)"
    echo "==> Deterministic preflight clean (cached=true, key=$cache_key_short; $label, diff vs $base_ref)."
    touchstone_emit_event preflight_clean pr_number="$PR_NUMBER" head_sha="$head_sha" cached=true cache_key="$PREFLIGHT_CACHE_KEY"
    return 0
  fi

  echo "==> Running deterministic preflight $label (diff vs $base_ref) ..."
  touchstone_emit_event preflight_started pr_number="$PR_NUMBER" mode="$event_mode" cached=false
  if touchstone_preflight_main_sanitized --diff "$base_ref" "$(git rev-parse --show-toplevel)"; then
    head_sha="$(git rev-parse HEAD 2>/dev/null || echo "")"
    write_preflight_clean_cache
    if [ -n "$PREFLIGHT_CACHE_KEY" ]; then
      cache_key_short="$(preflight_cache_short_key)"
      echo "==> Deterministic preflight clean (cached=false, key=$cache_key_short)."
      touchstone_emit_event preflight_clean pr_number="$PR_NUMBER" head_sha="$head_sha" cached=false cache_key="$PREFLIGHT_CACHE_KEY"
    else
      echo "==> Deterministic preflight clean (cached=false)."
      touchstone_emit_event preflight_clean pr_number="$PR_NUMBER" head_sha="$head_sha" cached=false
    fi
    return 0
  fi

  echo "ERROR: Deterministic preflight failed; refusing to spend provider tokens on review." >&2
  echo "       Fix the preflight failure or set TOUCHSTONE_NO_PREFLIGHT=1 for an emergency bypass." >&2
  head_sha="$(git rev-parse HEAD 2>/dev/null || echo "")"
  touchstone_emit_event preflight_blocked pr_number="$PR_NUMBER" head_sha="$head_sha"
  TOUCHSTONE_MERGE_FAILURE_REASON="preflight-blocked"
  return 1
}

run_merge_review() {
  local current_branch current_worktree base_ref default_worktree local_head pr_head_branch pr_head_oid
  local pr_triggered_signal_covers_revision=false

  if ! pr_head_branch="$(gh pr view "$PR_NUMBER" --json headRefName --jq '.headRefName' 2>/dev/null)"; then
    echo "ERROR: Failed to resolve PR #$PR_NUMBER head branch." >&2
    exit 1
  fi
  if ! pr_head_oid="$(gh pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid' 2>/dev/null)"; then
    echo "ERROR: Failed to resolve PR #$PR_NUMBER head commit." >&2
    exit 1
  fi
  if [ -z "$pr_head_branch" ]; then
    echo "ERROR: PR #$PR_NUMBER head branch is empty." >&2
    exit 1
  fi
  if [ -z "$pr_head_oid" ]; then
    echo "ERROR: PR #$PR_NUMBER head commit is empty." >&2
    exit 1
  fi

  PR_HEAD_BRANCH="$pr_head_branch"
  REVIEWED_HEAD_OID="$pr_head_oid"
  if truthy "$PR_TRIGGERED_REVIEW_REQUIRED" \
    && [ -n "$PR_TRIGGERED_REVIEWED_HEAD_OID" ] \
    && [ "$pr_head_oid" != "$PR_TRIGGERED_REVIEWED_HEAD_OID" ]; then
    echo "ERROR: PR #$PR_NUMBER head changed after the trusted PR-triggered AI review signal." >&2
    echo "       reviewed head: $PR_TRIGGERED_REVIEWED_HEAD_OID" >&2
    echo "       current head:  $pr_head_oid" >&2
    echo "       Rerun the merge gate on the current head." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="head-not-updated"
    exit 1
  fi
  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  if [ "$current_branch" = "$PR_HEAD_BRANCH" ]; then
    current_worktree="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
    default_worktree="$(worktree_path_for_branch "$DEFAULT_BRANCH" | head -n 1)"
    if [ -n "$current_worktree" ] && [ -n "$default_worktree" ] && [ "$current_worktree" != "$default_worktree" ]; then
      PR_WORKTREE_PATH="$current_worktree"
    fi
  else
    PR_WORKTREE_PATH="$(worktree_path_for_branch "$PR_HEAD_BRANCH" | head -n 1)"
  fi
  base_ref="$PR_BASE_REF"

  if [ "$BYPASS_REVIEW" = true ]; then
    refresh_pr_base_ref "before reviewer bypass validation" || exit 1
    if ! git cat-file -e "$pr_head_oid^{commit}" 2>/dev/null; then
      echo "==> Checking out PR #$PR_NUMBER head ($pr_head_branch) for reviewer bypass validation ..."
      gh pr checkout "$PR_NUMBER" --detach
    fi
    inspect_review_revision "$pr_head_oid" "$base_ref" "before reviewer bypass validation" || exit $?
    local current_base_oid="$CURRENT_REVIEW_BASE_OID"
    local current_merge_base="$CURRENT_REVIEW_MERGE_BASE_OID"
    BYPASS_MARKER_SOURCE=""
    BYPASS_MARKER_EVIDENCE=""
    if [ "$current_merge_base" != "$current_base_oid" ]; then
      echo "ERROR: Refusing reviewer bypass for PR #$PR_NUMBER because the reviewed head does not contain the current base." >&2
      echo "       current base: $current_base_oid" >&2
      echo "       merge base:   $current_merge_base" >&2
      echo "       Update the PR branch and obtain a fresh exact-head review." >&2
      TOUCHSTONE_MERGE_FAILURE_REASON="review-base-behind"
      exit 1
    elif branch_has_clean_review_marker "$pr_head_branch" "$pr_head_oid" "$current_merge_base"; then
      BYPASS_MARKER_SOURCE="clean-review"
    elif load_pr_review_request_timestamp "$pr_head_oid" "$current_base_oid" \
      && trusted_pr_clean_signal "$pr_head_oid" "$current_base_oid" "$PR_TRIGGERED_REVIEW_REQUEST_TIMESTAMP"; then
      BYPASS_MARKER_SOURCE="pr-triggered-review"
    elif [ "$ALLOW_FAIL_OPEN_MARKER" = true ]; then
      if ! bypass_reason_mentions_fail_open; then
        echo "ERROR: Refusing reviewer bypass for PR #$PR_NUMBER." >&2
        echo "       --allow-fail-open-marker requires a disclosure reason that cites the fail-open reviewer/provider outage." >&2
        exit 1
      fi
      if ! is_positive_integer "$TOUCHSTONE_FAIL_OPEN_BYPASS_WINDOW_HOURS"; then
        echo "ERROR: TOUCHSTONE_FAIL_OPEN_BYPASS_WINDOW_HOURS must be a positive integer." >&2
        exit 2
      fi
      if ! branch_has_recent_fail_open_marker "$pr_head_branch" "$pr_head_oid"; then
        echo "ERROR: Refusing reviewer bypass for PR #$PR_NUMBER." >&2
        echo "       No recent fail-open review-log marker matches branch '$pr_head_branch' at head '$pr_head_oid'." >&2
        echo "       Looked in: ${TOUCHSTONE_REVIEW_LOG:-<disabled>} (window: ${TOUCHSTONE_FAIL_OPEN_BYPASS_WINDOW_HOURS}h)." >&2
        echo "       Expected a FAIL_OPEN_* entry with detail 'fail-open:*' for the current branch head." >&2
        exit 1
      fi
      BYPASS_MARKER_SOURCE="fail-open"
    else
      echo "ERROR: Refusing reviewer bypass for PR #$PR_NUMBER." >&2
      echo "       No trusted PR-visible review or prior clean review marker matches branch '$pr_head_branch' at head '$pr_head_oid' and merge base '$current_merge_base'." >&2
      echo "       Run the reviewer cleanly once before using --bypass-with-disclosure, or pass --allow-fail-open-marker after a recent fail-open review-log event for this branch head." >&2
      exit 1
    fi
    REVIEWED_BASE_OID="$current_base_oid"
    REVIEWED_MERGE_BASE_OID="$current_merge_base"
    touchstone_emit_event review_bypass pr_number="$PR_NUMBER" head_sha="$pr_head_oid" reason="$BYPASS_REASON" marker="$BYPASS_MARKER_SOURCE" evidence="$BYPASS_MARKER_EVIDENCE"
    print_bypass_banner
    record_bypass_comment
    record_bypass_audit_log
    return 0
  fi

  if truthy "${SKIP_REVIEW:-${SKIP_CODEX_REVIEW:-false}}"; then
    echo "==> Skipping merge review because SKIP_REVIEW is set."
    return 0
  fi

  if [ ! -f "$REVIEW_SCRIPT" ] && ! truthy "$PR_TRIGGERED_REVIEW_REQUIRED"; then
    echo "==> Review script not found at $REVIEW_SCRIPT — skipping review."
    return 0
  fi

  refresh_pr_base_ref "for merge review" || exit 1

  # The reviewer reads the committed diff against the PR base; uncommitted
  # changes in unrelated paths do not affect that view. Only refuse when at
  # least one dirty path overlaps the PR's diff against that base, which
  # is the actual ambiguous-tree case. Refusing on any dirty path false-positives
  # whenever the operator has unrelated WIP they aren't ready to commit.
  local dirty_status diff_paths dirty_paths overlap
  dirty_status="$(git status --porcelain)"
  if [ -n "$dirty_status" ]; then
    if ! diff_paths="$(git diff --name-only "$base_ref"...HEAD 2>/dev/null | sort -u)"; then
      echo "ERROR: Could not compute diff against $base_ref to evaluate dirty-tree overlap." >&2
      exit 1
    fi
    # Parse `git status --porcelain` robustly: rename entries have the form
    # `R<space|index> old -> new`, others are `XY path`. We want the path that
    # actually exists in the working tree, which is the post-rename path.
    dirty_paths="$(printf '%s\n' "$dirty_status" \
      | awk '{
          line = substr($0, 4)
          idx = index(line, " -> ")
          if (idx > 0) {
            print substr(line, idx + 4)
          } else {
            print line
          }
        }' \
      | sort -u)"
    if [ -n "$diff_paths" ] && [ -n "$dirty_paths" ]; then
      overlap="$(comm -12 <(printf '%s\n' "$diff_paths") <(printf '%s\n' "$dirty_paths"))"
    else
      overlap=""
    fi
    if [ -n "$overlap" ]; then
      echo "ERROR: Working tree has uncommitted changes that overlap PR #$PR_NUMBER's diff vs $base_ref;" >&2
      echo "       refusing to run review against an ambiguous tree. Overlapping paths:" >&2
      printf '%s\n' "$overlap" | sed 's/^/         /' >&2
      exit 1
    fi
    if [ -n "$dirty_paths" ]; then
      echo "==> Working tree has uncommitted changes outside PR #$PR_NUMBER's diff vs $base_ref; proceeding."
    fi
  fi

  current_branch="$(git rev-parse --abbrev-ref HEAD)"
  local_head="$(git rev-parse HEAD)"
  if [ "$current_branch" != "$pr_head_branch" ] || [ "$local_head" != "$pr_head_oid" ]; then
    echo "==> Checking out PR #$PR_NUMBER head ($pr_head_branch) for merge review ..."
    gh pr checkout "$PR_NUMBER" --detach
    local_head="$(git rev-parse HEAD)"
  fi

  if [ "$local_head" != "$pr_head_oid" ]; then
    echo "ERROR: Local review checkout does not match PR #$PR_NUMBER head commit." >&2
    echo "       expected: $pr_head_oid" >&2
    echo "       actual:   $local_head" >&2
    exit 1
  fi

  inspect_review_revision "$pr_head_oid" "$base_ref" "before merge review" || return $?
  REVIEWED_BASE_OID="$CURRENT_REVIEW_BASE_OID"
  REVIEWED_MERGE_BASE_OID="$CURRENT_REVIEW_MERGE_BASE_OID"

  run_preflight_gate "$base_ref" "before merge review" "merge" || return $?

  if truthy "$PR_TRIGGERED_REVIEW_REQUIRED" && truthy "$PR_TRIGGERED_REVIEW_SKIP_MERGE_REVIEW"; then
    if [ "$PR_TRIGGERED_REVIEWED_BASE_OID" = "$REVIEWED_BASE_OID" ] \
      && [ "$REVIEWED_MERGE_BASE_OID" = "$REVIEWED_BASE_OID" ]; then
      pr_triggered_signal_covers_revision=true
    fi
    if [ "$pr_triggered_signal_covers_revision" = true ]; then
      echo "==> Skipping merge review because the trusted PR-visible AI review is bound to the current head and base."
      return 0
    fi
    echo "==> PR-visible AI review cannot replace local semantic review because the base revision changed or the PR is behind."
    echo "    signal_base=${PR_TRIGGERED_REVIEWED_BASE_OID:-<missing>}"
    echo "    current_base=$REVIEWED_BASE_OID merge_base=$REVIEWED_MERGE_BASE_OID"
  fi

  if [ ! -f "$REVIEW_SCRIPT" ]; then
    if truthy "$PR_TRIGGERED_REVIEW_REQUIRED"; then
      echo "ERROR: Review script not found at $REVIEW_SCRIPT, but the PR-visible review does not cover the current base revision." >&2
      echo "       Update the PR branch and obtain a fresh exact-head review, or restore the local reviewer." >&2
      TOUCHSTONE_MERGE_FAILURE_REASON="review-base-unreviewed"
      return 1
    fi
    echo "==> Review script not found at $REVIEW_SCRIPT — skipping review."
    return 0
  fi

  echo "==> Running merge review ..."
  local review_rc=0
  local review_output_file
  local review_infra_failure
  local reviewed_head_after
  review_output_file="$(mktemp -t touchstone-merge-review.XXXXXX.txt)"
  REVIEW_SUMMARY_FILE="$(git rev-parse --git-path "touchstone/review-summary-pr-${PR_NUMBER}.json" 2>/dev/null || echo "")"
  if [ -n "$REVIEW_SUMMARY_FILE" ]; then
    mkdir -p "$(dirname "$REVIEW_SUMMARY_FILE")" 2>/dev/null || true
    rm -f "$REVIEW_SUMMARY_FILE" 2>/dev/null || true
  fi
  touchstone_emit_event review_started pr_number="$PR_NUMBER" mode=fix
  set +e
  CODEX_REVIEW_BASE="$base_ref" \
    CODEX_REVIEW_BRANCH_NAME="$pr_head_branch" \
    CODEX_REVIEW_PR_NUMBER="$PR_NUMBER" \
    CODEX_REVIEW_FORCE=1 \
    CODEX_REVIEW_MODE=fix \
    CODEX_REVIEW_ON_ERROR=fail-closed \
    TOUCHSTONE_PREFLIGHT_ALREADY_RAN=1 \
    CODEX_REVIEW_SUMMARY_FILE="$REVIEW_SUMMARY_FILE" \
    bash "$REVIEW_SCRIPT" 2>&1 | tee "$review_output_file"
  review_rc="${PIPESTATUS[0]}"
  set -e

  if [ "$review_rc" -eq 0 ]; then
    rm -f "$review_output_file"
    reviewed_head_after="$(git rev-parse HEAD 2>/dev/null || echo "")"
    if [ -z "$reviewed_head_after" ]; then
      echo "ERROR: Could not resolve reviewed HEAD after merge review." >&2
      TOUCHSTONE_MERGE_FAILURE_REASON="missing-reviewed-head"
      return 1
    fi
    REVIEWED_HEAD_OID="$reviewed_head_after"
    if [ "$reviewed_head_after" != "$pr_head_oid" ]; then
      echo "==> Merge review changed HEAD:"
      echo "    before: $pr_head_oid"
      echo "    after:  $reviewed_head_after"
      echo "==> Running deterministic postflight after review fixes ..."
      run_preflight_gate "$base_ref" "after review fixes" "post-review" || return $?
      echo "==> Pushing review fix commit(s) to PR branch $pr_head_branch ..."
      if ! git push origin "HEAD:refs/heads/$pr_head_branch"; then
        echo "ERROR: Failed to push review fix commit(s) to PR branch $pr_head_branch." >&2
        TOUCHSTONE_MERGE_FAILURE_REASON="push-review-fixes"
        return 1
      fi
      wait_for_pr_head "$reviewed_head_after"
      wait_for_clean_merge_state
      if ! request_pr_triggered_review "$reviewed_head_after" "$REVIEWED_BASE_OID" "after review fixes" true; then
        if [ -n "${PR_TRIGGERED_REVIEW_REQUEST_INSPECTION_ERROR:-}" ]; then
          echo "ERROR: Failed to inspect prior GitHub Codex review requests for PR #$PR_NUMBER: $PR_TRIGGERED_REVIEW_REQUEST_INSPECTION_ERROR" >&2
        fi
        return 1
      fi
      if truthy "$PR_TRIGGERED_REVIEW_REQUIRED"; then
        wait_for_pr_triggered_review "$reviewed_head_after" "after review fixes"
        require_pr_feedback_clear "after PR-triggered AI review on review fixes" "$reviewed_head_after"
      fi
    fi
    inspect_review_revision "$reviewed_head_after" "$base_ref" "after merge review" || return $?
    if [ "$CURRENT_REVIEW_BASE_OID" != "$REVIEWED_BASE_OID" ]; then
      echo "ERROR: PR #$PR_NUMBER base revision changed while semantic review was running." >&2
      echo "       reviewed base: $REVIEWED_BASE_OID" >&2
      echo "       current base:  $CURRENT_REVIEW_BASE_OID" >&2
      echo "       Rerun the merge gate against the refreshed base." >&2
      TOUCHSTONE_MERGE_FAILURE_REASON="review-base-changed"
      return 1
    fi
    REVIEWED_MERGE_BASE_OID="$CURRENT_REVIEW_MERGE_BASE_OID"
    touchstone_emit_event review_clean pr_number="$PR_NUMBER" head_sha="$reviewed_head_after"
    return 0
  fi

  echo "" >&2
  echo "ERROR: Merge review exited $review_rc; merge-gate review fails closed." >&2
  review_infra_failure=false
  if review_failure_is_infra "$review_rc" "$review_output_file"; then
    review_infra_failure=true
    echo "       No concrete review findings were reported; this is a provider/infrastructure outage path." >&2
    print_review_infra_retry_guidance
  else
    echo "       Concrete review findings were reported; fix the findings, then rerun the merge gate." >&2
  fi
  echo "       Emergency bypass requires an explicit --bypass-with-disclosure reason and either a matching prior clean review marker or --allow-fail-open-marker with recent fail-open evidence." >&2
  post_review_failure_comment "$review_output_file" "$review_infra_failure"

  rm -f "$review_output_file"
  touchstone_emit_event review_blocked pr_number="$PR_NUMBER" head_sha="$pr_head_oid"
  TOUCHSTONE_MERGE_FAILURE_REASON="review-blocked"
  return "$review_rc"
}

refresh_trusted_merge_review_config_base
load_merge_review_config

# 1. Sanity check the PR exists and is open.
if ! PR_STATE="$(gh pr view "$PR_NUMBER" --json state --jq '.state')"; then
  echo "ERROR: Failed to inspect PR #$PR_NUMBER state with gh." >&2
  TOUCHSTONE_MERGE_FAILURE_REASON="pr-state"
  exit 1
fi
if [ "$PR_STATE" != "OPEN" ]; then
  echo "ERROR: PR #$PR_NUMBER is not open (state: $PR_STATE)." >&2
  TOUCHSTONE_MERGE_FAILURE_REASON="pr-not-open"
  exit 1
fi

# 2. Check mergeability with retries (GitHub's status can lag after a push).
wait_for_clean_merge_state

# 3. If configured, block until the current PR head has a trusted PR-visible
# AI review signal before spending local model-review tokens.
if truthy "$PR_TRIGGERED_REVIEW_REQUIRED" && [ "$BYPASS_REVIEW" != true ]; then
  require_pr_feedback_clear "before PR-triggered AI review"
  PR_TRIGGERED_HEAD_OID="$(current_pr_head_or_die "before PR-triggered AI review")"
  wait_for_pr_triggered_review "$PR_TRIGGERED_HEAD_OID" "before merge review"
  require_pr_feedback_clear "after PR-triggered AI review" "$PR_TRIGGERED_HEAD_OID"
else
  # Block on PR-visible requested changes or unresolved review threads before
  # spending model-review tokens. Audited bypasses also come through here so
  # the bypass path can still work when the PR-triggered reviewer is unavailable.
  require_pr_feedback_clear "before merge review"
fi

# 4. Run AI review as the merge gate.
run_merge_review

# 5. Re-check PR-visible feedback on the exact reviewed head before merging.
require_pr_feedback_clear "after merge review" "$REVIEWED_HEAD_OID"
if { truthy "$PR_TRIGGERED_REVIEW_REQUIRED" && [ "$BYPASS_REVIEW" != true ] \
  && [ "$PR_TRIGGERED_REVIEW_BASE_BOUND" = true ]; } \
  || [ "$BYPASS_MARKER_SOURCE" = "pr-triggered-review" ]; then
  if ! load_pr_review_request_timestamp "$REVIEWED_HEAD_OID" "$REVIEWED_BASE_OID" \
    || ! trusted_pr_clean_signal "$REVIEWED_HEAD_OID" "$REVIEWED_BASE_OID" "$PR_TRIGGERED_REVIEW_REQUEST_TIMESTAMP"; then
    echo "ERROR: The latest trusted PR-visible AI result is not clean for reviewed head $REVIEWED_HEAD_OID." >&2
    echo "       A newer review result may have arrived during preflight; resolve it and rerun the merge gate." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="pr-triggered-review-stale"
    exit 1
  fi
  echo "==> Revalidated latest trusted PR-visible AI result for head $REVIEWED_HEAD_OID."
  [ -n "$PR_TRIGGERED_REVIEW_SIGNAL_DETAIL" ] && echo "    $PR_TRIGGERED_REVIEW_SIGNAL_DETAIL"
fi
if { truthy "$PR_TRIGGERED_REVIEW_REQUIRED" && [ "$BYPASS_REVIEW" != true ]; } \
  || [ -n "$BYPASS_MARKER_SOURCE" ]; then
  require_review_revision_unchanged "$REVIEWED_HEAD_OID" "final merge authorization" || exit $?
fi

# 6. Squash-merge and delete the branch.
echo "==> Squash-merging PR #$PR_NUMBER ..."
if [ -z "$REVIEWED_HEAD_OID" ]; then
  echo "ERROR: Cannot merge PR #$PR_NUMBER because no reviewed head commit was recorded." >&2
  TOUCHSTONE_MERGE_FAILURE_REASON="missing-reviewed-head"
  exit 1
fi
gh_merge_exit=0
if [ "$BYPASS_REVIEW" = true ]; then
  gh pr merge "$PR_NUMBER" --squash --delete-branch --match-head-commit "$REVIEWED_HEAD_OID" \
    --body "Reviewer-bypass: $BYPASS_REASON" || gh_merge_exit=$?
else
  gh pr merge "$PR_NUMBER" --squash --delete-branch --match-head-commit "$REVIEWED_HEAD_OID" \
    || gh_merge_exit=$?
fi

# `gh pr merge --delete-branch` does the squash AND tries to delete the
# local feature branch. The local-delete fails when the branch is checked
# out in the current worktree (the common case for parallel-worktree work).
# When that happens, the remote merge succeeded server-side — only the
# local cleanup didn't. Verify by asking the API; if MERGED, treat as
# success with a warning so the script doesn't claim the PR failed.
if [ "$gh_merge_exit" -ne 0 ]; then
  pr_state="$(gh pr view "$PR_NUMBER" --json state --jq '.state' 2>/dev/null || echo "")"
  if [ "$pr_state" = "MERGED" ]; then
    echo "WARNING: gh pr merge exited $gh_merge_exit, but PR #$PR_NUMBER is MERGED on GitHub."
    echo "         Likely cause: local feature branch is checked out in a worktree,"
    echo "         or stale worktree metadata still records it there. Remote branch is gone."
    echo "         Use 'git worktree remove <path>' or 'bash scripts/cleanup-worktrees.sh --execute' for normal cleanup."
    echo "         If the directory was deleted directly, run 'git worktree prune' from a remaining checkout."
  else
    echo "ERROR: gh pr merge exited $gh_merge_exit and PR #$PR_NUMBER is not MERGED." >&2
    TOUCHSTONE_MERGE_FAILURE_REASON="gh-pr-merge"
    exit "$gh_merge_exit"
  fi
fi

MERGED_AT="$(gh pr view "$PR_NUMBER" --json mergedAt --jq '.mergedAt // empty' 2>/dev/null || echo "")"
touchstone_emit_event merged pr_number="$PR_NUMBER" merged_at="$MERGED_AT" head_sha="$REVIEWED_HEAD_OID"
post_clean_review_comment "$REVIEW_SUMMARY_FILE"
post_findings_history_comment "$PR_HEAD_BRANCH"

# Record squash-merge metadata for cleanup-branches.sh. The merge has
# succeeded on GitHub; this is best-effort persistence for later cleanup.
SQUASH_COMMIT_OID="$(gh pr view "$PR_NUMBER" --json mergeCommit --jq '.mergeCommit.oid' 2>/dev/null || echo "")"
record_squash_merge "$PR_HEAD_BRANCH" "$PR_NUMBER" "$REVIEWED_HEAD_OID" "$SQUASH_COMMIT_OID"

# 5. Sync local default branch.
sync_default_branch_after_merge

# 6. Cortex post-merge hook (T1.9). Fires only when the project meets the
# activation criteria documented in scripts/cortex-pr-merged-hook.sh.
# Activation is the hook's job — we always invoke and let it self-gate.
# The hook may produce a follow-up journal branch/PR; the journal commit
# is created with --no-verify so it doesn't recurse through this script's
# review gates. Failures inside the hook surface as visible stderr; we
# don't fail the overall merge over a journal-write hiccup.
CORTEX_HOOK_SCRIPT=""
for candidate_hook in \
  "$SCRIPT_DIR/cortex-pr-merged-hook.sh" \
  "$(git rev-parse --show-toplevel 2>/dev/null)/scripts/cortex-pr-merged-hook.sh"; do
  if [ -n "$candidate_hook" ] && [ -f "$candidate_hook" ]; then
    CORTEX_HOOK_SCRIPT="$candidate_hook"
    break
  fi
done

if [ -n "$CORTEX_HOOK_SCRIPT" ]; then
  hook_status=0
  TOUCHSTONE_MERGED_PR="$PR_NUMBER" bash "$CORTEX_HOOK_SCRIPT" || hook_status=$?
  if [ "$hook_status" -ne 0 ]; then
    echo "WARNING: cortex-pr-merged-hook exited $hook_status (see above)." >&2
    echo "         The PR merged cleanly; only the auto-draft journal step had a problem." >&2
  fi
fi

cleanup_local_pr_branch_after_merge
cleanup_pr_worktree_after_merge

echo "==> Done."
