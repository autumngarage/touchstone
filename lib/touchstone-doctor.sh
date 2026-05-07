#!/usr/bin/env bash
#
# lib/touchstone-doctor.sh — review-log health reporting for `touchstone doctor`.
#
# Exit-code contract:
#   0  report completed and the 7-day fail-open rate is within threshold
#   1  invalid arguments, unreadable log, or malformed threshold input
#   2  advisory warning: 7-day fail-open rate exceeds the configured threshold
#
# The command is read-only. It never writes, rotates, truncates, or deletes the
# review log. Tests should inject fixture logs with --log-path or
# TOUCHSTONE_REVIEW_LOG instead of touching ~/.touchstone-review-log.

if [ -n "${TOUCHSTONE_DOCTOR_SOURCED:-}" ]; then return 0; fi
TOUCHSTONE_DOCTOR_SOURCED=1

TOUCHSTONE_DOCTOR_DEFAULT_LOG="$HOME/.touchstone-review-log"
TOUCHSTONE_DOCTOR_WINDOW_SHORT_DAYS=7
TOUCHSTONE_DOCTOR_WINDOW_LONG_DAYS=30
TOUCHSTONE_DOCTOR_DEFAULT_THRESHOLD=25
TOUCHSTONE_DOCTOR_FAIL_OPEN_CODES="FAIL_OPEN_TIMEOUT FAIL_OPEN_PARSE_ERROR FAIL_OPEN_DEPENDENCY_MISSING FAIL_OPEN_PROVIDER_UNAVAILABLE FAIL_OPEN_REVIEWER_ERROR"

touchstone_doctor_usage() {
  cat <<'EOF'
Usage: touchstone doctor [--log-path <path>] [--threshold <percent>]
       touchstone doctor --project
       touchstone doctor --require-capability <name>
       touchstone doctor --installation

  (no flag)             Report conductor-review fail-open trends from ~/.touchstone-review-log
  --log-path <path>     Read a fixture or alternate review log (also: TOUCHSTONE_REVIEW_LOG)
  --threshold <percent> Warn when the last-7d fail-open rate exceeds this value (default 25)
  --project             Check per-project health (hooks, manifest, registry)
  --require-capability <name>
                        Require a project-local Touchstone workflow capability
  --installation        Check touchstone installation health (CLI, tools, projects)

Exit codes:
  0  report completed and no fail-open warning fired
  1  invalid arguments or unreadable log
  2  advisory warning: last-7d fail-open rate exceeds threshold
EOF
}

touchstone_doctor_review_log() {
  local log_path="${TOUCHSTONE_REVIEW_LOG-$TOUCHSTONE_DOCTOR_DEFAULT_LOG}"
  local threshold="${TOUCHSTONE_DOCTOR_THRESHOLD:-$TOUCHSTONE_DOCTOR_DEFAULT_THRESHOLD}"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --log-path)
        if [ "$#" -lt 2 ]; then
          echo "ERROR: --log-path requires a path" >&2
          return 1
        fi
        log_path="$2"
        shift 2
        ;;
      --threshold)
        if [ "$#" -lt 2 ]; then
          echo "ERROR: --threshold requires a percentage value" >&2
          return 1
        fi
        threshold="$2"
        shift 2
        ;;
      -h|--help)
        touchstone_doctor_usage
        return 0
        ;;
      *)
        echo "ERROR: unknown doctor argument '$1'" >&2
        touchstone_doctor_usage >&2
        return 1
        ;;
    esac
  done

  case "$threshold" in
    ''|*[!0-9]*)
      echo "ERROR: --threshold must be an integer percentage (got '$threshold')" >&2
      return 1
      ;;
  esac

  if [ ! -e "$log_path" ] || [ ! -s "$log_path" ]; then
    echo "no review log found; conductor review hasn't run on this machine yet"
    return 0
  fi
  if [ ! -r "$log_path" ]; then
    echo "ERROR: review log is not readable: $log_path" >&2
    return 1
  fi

  local now_epoch cutoff_7 cutoff_30 report_file exit_code
  now_epoch="$(date +%s 2>/dev/null || true)"
  if [ -z "$now_epoch" ]; then
    echo "ERROR: could not determine current time" >&2
    return 1
  fi
  cutoff_7="$(touchstone_doctor_cutoff_epoch "$TOUCHSTONE_DOCTOR_WINDOW_SHORT_DAYS")" || return 1
  cutoff_30="$(touchstone_doctor_cutoff_epoch "$TOUCHSTONE_DOCTOR_WINDOW_LONG_DAYS")" || return 1

  report_file="$(mktemp "${TMPDIR:-/tmp}/touchstone-doctor.XXXXXX")" || {
    echo "ERROR: could not create temporary report file" >&2
    return 1
  }
  touchstone_doctor_analyze_log "$log_path" "$cutoff_7" "$cutoff_30" "$threshold" "$report_file" || {
    local status=$?
    rm -f "$report_file"
    return "$status"
  }

  exit_code="$(sed -n '1p' "$report_file")"
  sed '1d' "$report_file"
  rm -f "$report_file"
  return "$exit_code"
}

touchstone_doctor_cutoff_epoch() {
  local days="$1" cutoff=""
  cutoff="$(date -d "$days days ago" +%s 2>/dev/null || true)"
  if [ -z "$cutoff" ]; then
    cutoff="$(date -v-"${days}"d +%s 2>/dev/null || true)"
  fi
  if [ -z "$cutoff" ]; then
    local now
    now="$(date +%s 2>/dev/null || true)"
    [ -n "$now" ] || {
      echo "ERROR: could not compute ${days}d cutoff" >&2
      return 1
    }
    cutoff=$((now - (days * 86400)))
  fi
  printf '%s\n' "$cutoff"
}

touchstone_doctor_parse_epoch() {
  local timestamp="$1" epoch=""
  epoch="$(date -d "$timestamp" +%s 2>/dev/null || true)"
  if [ -z "$epoch" ]; then
    epoch="$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$timestamp" +%s 2>/dev/null || true)"
  fi
  printf '%s\n' "$epoch"
}

touchstone_doctor_is_fail_open_code() {
  case "$1" in
    FAIL_OPEN_TIMEOUT|FAIL_OPEN_PARSE_ERROR|FAIL_OPEN_DEPENDENCY_MISSING|FAIL_OPEN_PROVIDER_UNAVAILABLE|FAIL_OPEN_REVIEWER_ERROR)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

touchstone_doctor_analyze_log() {
  local log_path="$1" cutoff_7="$2" cutoff_30="$3" threshold="$4" report_file="$5"
  local total_7=0 total_30=0 fail_7=0 fail_30=0 malformed=0
  local recent_epoch=0 recent_timestamp="" recent_code="" recent_repo="" recent_branch="" recent_sha="" recent_detail=""
  local line timestamp repo branch sha reason detail extra epoch
  local code

  for code in $TOUCHSTONE_DOCTOR_FAIL_OPEN_CODES; do
    eval "count7_${code}=0"
    eval "count30_${code}=0"
  done

  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    IFS=$'\t' read -r timestamp repo branch sha reason detail extra <<EOF
$line
EOF
    if [ -n "${extra:-}" ] || [ -z "${timestamp:-}" ] || [ -z "${repo:-}" ] || [ -z "${branch:-}" ] || [ -z "${sha:-}" ] || [ -z "${reason:-}" ]; then
      malformed=$((malformed + 1))
      continue
    fi
    detail="${detail:-}"

    epoch="$(touchstone_doctor_parse_epoch "$timestamp")"
    if [ -z "$epoch" ]; then
      malformed=$((malformed + 1))
      continue
    fi

    if touchstone_doctor_is_fail_open_code "$reason"; then
      if [ "$epoch" -ge "$cutoff_7" ]; then
        total_7=$((total_7 + 1))
        fail_7=$((fail_7 + 1))
        eval "count7_${reason}=\$((count7_${reason} + 1))"
      fi
      if [ "$epoch" -ge "$cutoff_30" ]; then
        total_30=$((total_30 + 1))
        fail_30=$((fail_30 + 1))
        eval "count30_${reason}=\$((count30_${reason} + 1))"
      fi
      if [ "$epoch" -ge "$recent_epoch" ]; then
        recent_epoch="$epoch"
        recent_timestamp="$timestamp"
        recent_code="$reason"
        recent_repo="$repo"
        recent_branch="$branch"
        recent_sha="$sha"
        recent_detail="$detail"
      fi
    elif [ "$reason" = "ran" ]; then
      [ "$epoch" -ge "$cutoff_7" ] && total_7=$((total_7 + 1))
      [ "$epoch" -ge "$cutoff_30" ] && total_30=$((total_30 + 1))
    fi
  done < "$log_path"

  {
    if touchstone_doctor_rate_exceeds "$fail_7" "$total_7" "$threshold"; then
      printf '2\n'
    else
      printf '0\n'
    fi
    touchstone_doctor_print_report \
      "$log_path" "$threshold" \
      "$total_7" "$fail_7" "$total_30" "$fail_30" \
      "$recent_timestamp" "$recent_code" "$recent_repo" "$recent_branch" "$recent_sha" "$recent_detail" \
      "$malformed"
  } > "$report_file"
}

touchstone_doctor_rate_exceeds() {
  local fail_count="$1" total_count="$2" threshold="$3"
  [ "$total_count" -gt 0 ] || return 1
  [ $((fail_count * 100)) -gt $((threshold * total_count)) ]
}

touchstone_doctor_rate() {
  local fail_count="$1" total_count="$2"
  if [ "$total_count" -eq 0 ]; then
    printf '0.0'
    return 0
  fi
  awk -v fail="$fail_count" -v total="$total_count" 'BEGIN { printf "%.1f", (fail * 100) / total }'
}

touchstone_doctor_print_report() {
  local log_path="$1" threshold="$2"
  local total_7="$3" fail_7="$4" total_30="$5" fail_30="$6"
  local recent_timestamp="$7" recent_code="$8" recent_repo="$9" recent_branch="${10}" recent_sha="${11}" recent_detail="${12}"
  local malformed="${13}"
  local code rate_7 rate_30

  tk_header "Touchstone Doctor — conductor review"
  tk_dim "log: $log_path"
  tk_dim "warning threshold: ${threshold}% fail-open rate over last ${TOUCHSTONE_DOCTOR_WINDOW_SHORT_DAYS}d"

  rate_7="$(touchstone_doctor_rate "$fail_7" "$total_7")"
  rate_30="$(touchstone_doctor_rate "$fail_30" "$total_30")"

  echo ""
  tk_info "Last ${TOUCHSTONE_DOCTOR_WINDOW_SHORT_DAYS} days"
  printf "  total reviews: %s\n" "$total_7"
  printf "  fail-open: %s (%s%%)\n" "$fail_7" "$rate_7"
  for code in $TOUCHSTONE_DOCTOR_FAIL_OPEN_CODES; do
    eval "printf '    %s: %s\n' \"\$code\" \"\$count7_${code}\""
  done

  echo ""
  tk_info "Last ${TOUCHSTONE_DOCTOR_WINDOW_LONG_DAYS} days"
  printf "  total reviews: %s\n" "$total_30"
  printf "  fail-open: %s (%s%%)\n" "$fail_30" "$rate_30"
  for code in $TOUCHSTONE_DOCTOR_FAIL_OPEN_CODES; do
    eval "printf '    %s: %s\n' \"\$code\" \"\$count30_${code}\""
  done

  echo ""
  tk_info "Most recent fail-open"
  if [ -n "$recent_timestamp" ]; then
    printf "  timestamp: %s\n" "$recent_timestamp"
    printf "  code: %s\n" "$recent_code"
    printf "  repo: %s\n" "$recent_repo"
    printf "  branch: %s\n" "$recent_branch"
    printf "  sha: %s\n" "$recent_sha"
    [ -n "$recent_detail" ] && printf "  detail: %s\n" "$recent_detail"
  else
    printf "  none recorded\n"
  fi

  if [ "$malformed" -gt 0 ]; then
    echo ""
    tk_warn "$malformed malformed review log row(s) ignored"
  fi

  if touchstone_doctor_rate_exceeds "$fail_7" "$total_7" "$threshold"; then
    echo ""
    tk_warn "fail-open rate ${rate_7}% exceeds ${threshold}% over last ${TOUCHSTONE_DOCTOR_WINDOW_SHORT_DAYS}d"
  else
    echo ""
    tk_ok "fail-open rate ${rate_7}% is within threshold"
  fi
}
