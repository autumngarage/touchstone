#!/usr/bin/env bash
#
# Unit and smoke tests for sentinel cycle journal injection in codex-review.sh.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$TOUCHSTONE_ROOT/hooks/codex-review.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: $SCRIPT not found or not executable" >&2
  exit 1
fi

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-test-reviewer-sentinel.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

fail() {
  echo "FAIL: $1" >&2
  ERRORS=$((ERRORS + 1))
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local name="$3"
  if ! printf '%s' "$haystack" | grep -Fq "$needle"; then
    fail "$name: expected output to contain [$needle]"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local name="$3"
  if printf '%s' "$haystack" | grep -Fq "$needle"; then
    fail "$name: expected output not to contain [$needle]"
  fi
}

assert_empty() {
  local value="$1"
  local name="$2"
  if [ -n "$value" ]; then
    fail "$name: expected empty output, got [$value]"
  fi
}

new_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  printf 'init\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm init
}

run_context_helper() {
  local repo="$1"
  local stdout_file="$TEST_DIR/stdout"
  local stderr_file="$TEST_DIR/stderr"
  (
    cd "$repo"
    CODEX_REVIEW_TEST_SENTINEL_CONTEXT=1 bash "$SCRIPT"
  ) >"$stdout_file" 2>"$stderr_file"
  CONTEXT_STDOUT="$(cat "$stdout_file")"
  CONTEXT_STDERR="$(cat "$stderr_file")"
}

echo "==> reviewer sentinel context"

echo "==> Test: detects_and_injects_journal"
REPO_DETECT="$TEST_DIR/repo-detect"
new_repo "$REPO_DETECT"
mkdir -p "$REPO_DETECT/.sentinel/runs" "$REPO_DETECT/.cortex/journal"
printf -- '---\ncycle-id: foo\n---\n' > "$REPO_DETECT/.sentinel/runs/run.md"
cat > "$REPO_DETECT/.cortex/journal/20260428-sentinel-cycle-foo.md" <<'EOF'
---
title: Sentinel Cycle Foo
---
planner considered cached review behavior
coder tried prompt injection
rejected mid-cycle shortcut
EOF
run_context_helper "$REPO_DETECT"
assert_contains "$CONTEXT_STDOUT" "<sentinel-cycle-context>" "detects_and_injects_journal"
assert_contains "$CONTEXT_STDOUT" "planner considered cached review behavior" "detects_and_injects_journal"
assert_contains "$CONTEXT_STDOUT" "</sentinel-cycle-context>" "detects_and_injects_journal"
assert_empty "$CONTEXT_STDERR" "detects_and_injects_journal stderr"

echo "==> Test: no_sentinel_no_injection"
REPO_NONE="$TEST_DIR/repo-none"
new_repo "$REPO_NONE"
run_context_helper "$REPO_NONE"
assert_empty "$CONTEXT_STDOUT" "no_sentinel_no_injection stdout"
assert_empty "$CONTEXT_STDERR" "no_sentinel_no_injection stderr"

echo "==> Test: sentinel_but_no_cortex"
REPO_NO_CORTEX="$TEST_DIR/repo-no-cortex"
new_repo "$REPO_NO_CORTEX"
mkdir -p "$REPO_NO_CORTEX/.sentinel/runs"
printf 'sentinel run\n' > "$REPO_NO_CORTEX/.sentinel/runs/run.md"
run_context_helper "$REPO_NO_CORTEX"
assert_empty "$CONTEXT_STDOUT" "sentinel_but_no_cortex stdout"
assert_contains "$CONTEXT_STDERR" "no cycle journal entry found" "sentinel_but_no_cortex stderr"

echo "==> Test: cycle_id_match_preferred_over_recency"
REPO_CYCLE="$TEST_DIR/repo-cycle"
new_repo "$REPO_CYCLE"
mkdir -p "$REPO_CYCLE/.sentinel/runs" "$REPO_CYCLE/.cortex/journal"
printf -- '---\ncycle-id: B\n---\n' > "$REPO_CYCLE/.sentinel/runs/run.md"
printf 'journal A newer\n' > "$REPO_CYCLE/.cortex/journal/20260428-sentinel-cycle-A.md"
printf 'journal B matched\n' > "$REPO_CYCLE/.cortex/journal/20260427-sentinel-cycle-B.md"
touch -t 202604281200 "$REPO_CYCLE/.cortex/journal/20260428-sentinel-cycle-A.md"
touch -t 202604271200 "$REPO_CYCLE/.cortex/journal/20260427-sentinel-cycle-B.md"
run_context_helper "$REPO_CYCLE"
assert_contains "$CONTEXT_STDOUT" "journal B matched" "cycle_id_match_preferred_over_recency"
assert_not_contains "$CONTEXT_STDOUT" "journal A newer" "cycle_id_match_preferred_over_recency"

echo "==> Test: malformed_journal_falls_back"
REPO_MALFORMED="$TEST_DIR/repo-malformed"
new_repo "$REPO_MALFORMED"
mkdir -p "$REPO_MALFORMED/.sentinel/runs" "$REPO_MALFORMED/.cortex/journal"
printf 'sentinel run\n' > "$REPO_MALFORMED/.sentinel/runs/run.md"
printf 'unreadable journal\n' > "$REPO_MALFORMED/.cortex/journal/20260428-sentinel-cycle-bad.md"
chmod 000 "$REPO_MALFORMED/.cortex/journal/20260428-sentinel-cycle-bad.md"
run_context_helper "$REPO_MALFORMED"
chmod 644 "$REPO_MALFORMED/.cortex/journal/20260428-sentinel-cycle-bad.md"
assert_empty "$CONTEXT_STDOUT" "malformed_journal_falls_back stdout"
assert_contains "$CONTEXT_STDERR" "could not be read" "malformed_journal_falls_back stderr"

echo "==> Test: smoke prompt sent to conductor includes sentinel context"
REPO_SMOKE="$TEST_DIR/repo-smoke"
new_repo "$REPO_SMOKE"
mkdir -p "$REPO_SMOKE/.sentinel/runs" "$REPO_SMOKE/.cortex/journal" "$TEST_DIR/bin"
printf -- '---\ncycle-id: smoke\n---\n' > "$REPO_SMOKE/.sentinel/runs/run.md"
printf 'smoke journal context\n' > "$REPO_SMOKE/.cortex/journal/20260428-sentinel-cycle-smoke.md"
printf 'change\n' >> "$REPO_SMOKE/README.md"
git -C "$REPO_SMOKE" add README.md
git -C "$REPO_SMOKE" commit -qm change
PROMPT_CAPTURE="$TEST_DIR/prompt.capture"
cat > "$TEST_DIR/bin/conductor" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  doctor)
    printf '{"providers":[{"configured":true}]}\n'
    ;;
  call|exec)
    cat > "$PROMPT_CAPTURE"
    printf 'LGTM\nCODEX_REVIEW_CLEAN\n'
    ;;
  *)
    echo "unexpected conductor command: $1" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$TEST_DIR/bin/conductor"
(
  cd "$REPO_SMOKE"
  PATH="$TEST_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    PROMPT_CAPTURE="$PROMPT_CAPTURE" \
    CODEX_REVIEW_FORCE=1 \
    CODEX_REVIEW_BASE=HEAD~1 \
    CODEX_REVIEW_MODE=diff-only \
    CODEX_REVIEW_DISABLE_CACHE=1 \
    TOUCHSTONE_REVIEW_LOG=/dev/null \
    bash "$SCRIPT" >/dev/null
)
SMOKE_PROMPT="$(cat "$PROMPT_CAPTURE")"
assert_contains "$SMOKE_PROMPT" "<sentinel-cycle-context>" "smoke prompt"
assert_contains "$SMOKE_PROMPT" "smoke journal context" "smoke prompt"
assert_contains "$SMOKE_PROMPT" "You are reviewing AND optionally auto-fixing" "smoke prompt"

if [ "$ERRORS" -ne 0 ]; then
  echo "==> FAIL: $ERRORS reviewer sentinel context test(s) failed" >&2
  exit 1
fi

echo "==> OK: reviewer sentinel context tests passed"
