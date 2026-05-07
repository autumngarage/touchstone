#!/usr/bin/env bash
#
# tests/test-events-json.sh — verify opt-in lifecycle NDJSON events.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-events.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

assert_contains() {
  local file="$1" pattern="$2"
  if ! grep -qE "$pattern" "$file"; then
    fail "expected $file to contain: $pattern"
    [ -f "$file" ] && cat "$file" >&2
  fi
}

assert_not_contains() {
  local file="$1" pattern="$2"
  if grep -qE "$pattern" "$file"; then
    fail "expected $file not to contain: $pattern"
    cat "$file" >&2
  fi
}

assert_event_order() {
  local file="$1"
  shift
  local expected="$*" actual
  actual="$(sed -n 's/.*"event":"\([^"]*\)".*/\1/p' "$file" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [ "$actual" != "$expected" ]; then
    fail "event order mismatch: expected '$expected', got '$actual'"
    cat "$file" >&2
  fi
}

assert_json_lines() {
  local file="$1"
  if [ ! -s "$file" ]; then
    fail "expected non-empty events file: $file"
    return
  fi
  if grep -nvE '^\{"event":"[^"]+","ts":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z","script":"[^"]+"' "$file"; then
    fail "events file has malformed required fields: $file"
    cat "$file" >&2
  fi
}

copy_event_scripts() {
  local dst="$1"
  mkdir -p "$dst/scripts" "$dst/lib"
  cp "$TOUCHSTONE_ROOT/lib/events.sh" "$dst/lib/events.sh"
  cp "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$dst/scripts/open-pr.sh"
  cp "$TOUCHSTONE_ROOT/scripts/merge-pr.sh" "$dst/scripts/merge-pr.sh"
  chmod +x "$dst/scripts/"*.sh
}

setup_git_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -b main >/dev/null 2>&1
  git -C "$repo" config user.name "Touchstone Test"
  git -C "$repo" config user.email "touchstone@example.com"
  printf 'base\n' >"$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -m "base commit" >/dev/null 2>&1
}

echo "==> Case a: spawn-worktree emits worktree_created"
SPAWN_REPO="$TEST_DIR/spawn-repo"
setup_git_repo "$SPAWN_REPO"
SPAWN_REPO_REAL="$(cd "$SPAWN_REPO" && pwd -P)"
SPAWN_EVENTS="$TEST_DIR/spawn-events.ndjson"
SPAWN_WORKTREE="$TEST_DIR/spawn-worktree"
(
  cd "$SPAWN_REPO"
  TOUCHSTONE_EVENTS_FILE="$SPAWN_EVENTS" \
    bash "$TOUCHSTONE_ROOT/scripts/spawn-worktree.sh" "feat/events-one" "$SPAWN_WORKTREE" >"$TEST_DIR/spawn.out" 2>&1
)
assert_json_lines "$SPAWN_EVENTS"
assert_event_order "$SPAWN_EVENTS" worktree_created
assert_contains "$SPAWN_EVENTS" '"branch":"feat/events-one"'
assert_contains "$SPAWN_EVENTS" "\"worktree_path\":\"$SPAWN_WORKTREE\""
assert_contains "$SPAWN_EVENTS" '"base_branch":"main"'
assert_contains "$SPAWN_EVENTS" "\"repo_root\":\"$SPAWN_REPO_REAL\""

echo "==> Case b/e: open-pr happy-path events and unset no-op"
OPEN_FIXTURE="$TEST_DIR/open-fixture"
copy_event_scripts "$OPEN_FIXTURE"
cat >"$OPEN_FIXTURE/scripts/merge-pr.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/events.sh"
touchstone_emit_event review_started pr_number="$1" mode=review-only
touchstone_emit_event review_clean pr_number="$1" head_sha=open-head-oid
touchstone_emit_event merged pr_number="$1" merged_at=2026-05-06T12:00:00Z head_sha=open-head-oid
EOF
chmod +x "$OPEN_FIXTURE/scripts/merge-pr.sh"

OPEN_REPO="$TEST_DIR/open-repo"
setup_git_repo "$OPEN_REPO"
OPEN_REPO_REAL="$(cd "$OPEN_REPO" && pwd -P)"
git -C "$OPEN_REPO" checkout -b feat/open-events >/dev/null 2>&1
printf 'change\n' >>"$OPEN_REPO/file.txt"
git -C "$OPEN_REPO" add file.txt
git -C "$OPEN_REPO" commit -m "open events" >/dev/null 2>&1

OPEN_BIN="$TEST_DIR/open-bin"
mkdir -p "$OPEN_BIN"
REAL_GIT="$(command -v git)"
cat >"$OPEN_BIN/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "push" ]; then
  echo "[mock] git push \$*"
  exit 0
fi
if [ "\${1:-} \${2:-} \${3:-}" = "worktree list --porcelain" ]; then
  printf 'worktree %s\nHEAD main-oid\nbranch refs/heads/main\n\nworktree %s\nHEAD open-head-oid\nbranch refs/heads/feat/open-events\n\n' "$TEST_DIR/main-open-worktree" "$OPEN_REPO"
  exit 0
fi
if [ "\${1:-} \${2:-}" = "worktree remove" ]; then
  echo "[mock] git worktree remove \${3:-}"
  exit 0
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$OPEN_BIN/git"
cat >"$OPEN_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "repo view") echo "main" ;;
  "pr list") echo "" ;;
  "pr create") echo "https://example.test/touchstone/pull/123" ;;
  "pr view") echo "2026-05-06T12:00:00Z" ;;
  *) echo "unexpected gh args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$OPEN_BIN/gh"
mkdir -p "$TEST_DIR/main-open-worktree"

OPEN_EVENTS="$TEST_DIR/open-events.ndjson"
(
  cd "$OPEN_REPO"
  PATH="$OPEN_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    TOUCHSTONE_EVENTS_FILE="$OPEN_EVENTS" \
    bash "$OPEN_FIXTURE/scripts/open-pr.sh" --auto-merge --cleanup-worktree >"$TEST_DIR/open.out" 2>&1
)
assert_json_lines "$OPEN_EVENTS"
assert_event_order "$OPEN_EVENTS" pr_opened review_started review_clean merged cleanup_started cleanup_done
assert_contains "$OPEN_EVENTS" '"pr_url":"https://example.test/touchstone/pull/123"'
assert_contains "$OPEN_EVENTS" '"pr_number":123'
assert_contains "$OPEN_EVENTS" '"branch":"feat/open-events"'
assert_contains "$OPEN_EVENTS" '"base_branch":"main"'
assert_contains "$OPEN_EVENTS" "\"worktree_path\":\"$OPEN_REPO_REAL\""
assert_contains "$OPEN_EVENTS" '"result":"removed"'

NO_EVENT_FILE="$TEST_DIR/should-not-exist.ndjson"
(
  cd "$OPEN_REPO"
  PATH="$OPEN_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$OPEN_FIXTURE/scripts/open-pr.sh" --auto-merge >"$TEST_DIR/open-no-events.out" 2>&1
)
if [ -e "$NO_EVENT_FILE" ]; then
  fail "events file was created with TOUCHSTONE_EVENTS_FILE unset"
fi
assert_not_contains "$TEST_DIR/open-no-events.out" '\[events\]'

echo "==> Cases c/d: merge-pr review blocked and auto-bypass events"
MERGE_FIXTURE="$TEST_DIR/merge-fixture"
copy_event_scripts "$MERGE_FIXTURE"
cat >"$MERGE_FIXTURE/scripts/codex-review.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit "${CODEX_REVIEW_EXIT:-0}"
EOF
chmod +x "$MERGE_FIXTURE/scripts/codex-review.sh"

MERGE_BIN="$TEST_DIR/merge-bin"
GIT_PATH_ROOT="$TEST_DIR/git-path"
mkdir -p "$MERGE_BIN" "$GIT_PATH_ROOT"
cat >"$MERGE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "repo view") echo "main" ;;
  "pr view")
    case "${5:-}" in
      state) [ -f "${GH_MERGED_MARKER:-/dev/null/never}" ] && echo "MERGED" || echo "OPEN" ;;
      headRefName) echo "feature/test" ;;
      headRefOid) echo "pr-head-oid" ;;
      mergeStateStatus,mergeable) echo "CLEAN MERGEABLE" ;;
      mergedAt) echo "2026-05-06T12:34:56Z" ;;
      mergeCommit) echo "squash-oid" ;;
      *) echo "unexpected gh pr view args: $*" >&2; exit 1 ;;
    esac
    ;;
  "pr checkout") touch "$GH_CHECKOUT_FILE"; echo "checked out PR $3" ;;
  "pr comment") echo "commented" ;;
  "pr merge") touch "$GH_MERGED_MARKER"; echo "merged" ;;
  *) echo "unexpected gh args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$MERGE_BIN/gh"
cat >"$MERGE_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "rev-parse --abbrev-ref HEAD") [ -f "$GH_CHECKOUT_FILE" ] && echo "HEAD" || echo "feature/test" ;;
  "rev-parse HEAD") [ -f "$GH_CHECKOUT_FILE" ] && echo "pr-head-oid" || echo "stale-local-oid" ;;
  "rev-parse --git-path touchstone/reviewer-clean") echo "$GIT_PATH_ROOT/touchstone/reviewer-clean" ;;
  "rev-parse --show-toplevel") echo "/tmp/touchstone-feature-worktree" ;;
  "rev-parse feature/test") echo "pr-head-oid" ;;
  "show-ref --verify --quiet refs/heads/feature/test") ;;
  "cat-file -e pr-head-oid^{commit}") ;;
  "merge-base origin/main pr-head-oid") echo "base-oid" ;;
  "fetch origin +refs/heads/main:refs/remotes/origin/main") echo "fetched main" ;;
  "rev-parse --verify --quiet origin/main^{commit}") echo "base-oid" ;;
  "status --porcelain") ;;
  "worktree list --porcelain") ;;
  "checkout main") echo "Switched to branch main" ;;
  "pull --rebase") echo "Already up to date." ;;
  "branch -D feature/test") echo "Deleted branch feature/test." ;;
  "rev-parse --git-path touchstone/squash-map.jsonl") echo "$GIT_PATH_ROOT/touchstone/squash-map.jsonl" ;;
  *) echo "unexpected git args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$MERGE_BIN/git"

BLOCKED_EVENTS="$TEST_DIR/blocked-events.ndjson"
GH_CHECKOUT_FILE="$TEST_DIR/gh-checkout-blocked" \
  GH_MERGED_MARKER="$TEST_DIR/gh-merged-blocked" \
  GIT_PATH_ROOT="$GIT_PATH_ROOT" \
  PATH="$MERGE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  TOUCHSTONE_EVENTS_FILE="$BLOCKED_EVENTS" \
  CODEX_REVIEW_EXIT=1 \
  bash "$MERGE_FIXTURE/scripts/merge-pr.sh" 123 >"$TEST_DIR/blocked.out" 2>&1 && fail "blocked merge unexpectedly exited 0"
assert_json_lines "$BLOCKED_EVENTS"
assert_event_order "$BLOCKED_EVENTS" review_started review_blocked failed
assert_not_contains "$BLOCKED_EVENTS" '"event":"merged"'

mkdir -p "$GIT_PATH_ROOT/touchstone/reviewer-clean"
cat >"$GIT_PATH_ROOT/touchstone/reviewer-clean/feature_test.clean" <<'EOF'
result=CODEX_REVIEW_CLEAN
branch=feature/test
head=pr-head-oid
merge_base=base-oid
EOF
BYPASS_EVENTS="$TEST_DIR/bypass-events.ndjson"
rm -f "$TEST_DIR/gh-checkout-bypass" "$TEST_DIR/gh-merged-bypass"
GH_CHECKOUT_FILE="$TEST_DIR/gh-checkout-bypass" \
  GH_MERGED_MARKER="$TEST_DIR/gh-merged-bypass" \
  GIT_PATH_ROOT="$GIT_PATH_ROOT" \
  PATH="$MERGE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  TOUCHSTONE_EVENTS_FILE="$BYPASS_EVENTS" \
  CODEX_REVIEW_EXIT=1 \
  bash "$MERGE_FIXTURE/scripts/merge-pr.sh" 123 >"$TEST_DIR/bypass.out" 2>&1
assert_json_lines "$BYPASS_EVENTS"
assert_event_order "$BYPASS_EVENTS" review_started review_bypass merged
assert_contains "$BYPASS_EVENTS" '"reason":"merge-pr.sh final review iteration exited 1'

if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: lifecycle event stream is opt-in, ordered, and machine-readable"
  exit 0
fi

echo "==> FAIL: $ERRORS event assertion(s) failed" >&2
exit 1
