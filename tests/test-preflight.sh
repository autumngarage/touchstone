#!/usr/bin/env bash
#
# tests/test-preflight.sh — deterministic preflight gate and merge short-circuit.
#
set -euo pipefail

unset TOUCHSTONE_NO_PREFLIGHT TOUCHSTONE_NO_AUTO_UPDATE

if [ "${TOUCHSTONE_PREFLIGHT_IN_PROGRESS:-0}" = "1" ]; then
  echo "==> SKIP: test-preflight avoids recursive touchstone preflight"
  exit 0
fi

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-preflight.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

CLEAN_FAKE_BIN="$TEST_DIR/clean-bin"
mkdir -p "$CLEAN_FAKE_BIN"
for tool in shellcheck shfmt markdownlint actionlint; do
  cat >"$CLEAN_FAKE_BIN/$tool" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$CLEAN_FAKE_BIN/$tool"
done

echo "==> Test: touchstone preflight exits clean on this tree"
PATH="$CLEAN_FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  TOUCHSTONE_NO_AUTO_UPDATE=1 \
  TOUCHSTONE_PREFLIGHT_VALIDATE_COMMAND=: \
  bash "$TOUCHSTONE_ROOT/bin/touchstone" preflight "$TOUCHSTONE_ROOT" >"$TEST_DIR/clean.txt" 2>&1
if grep -q '==> preflight clean' "$TEST_DIR/clean.txt"; then
  echo "==> PASS: clean tree preflight exits 0"
else
  echo "FAIL: clean tree preflight did not report clean" >&2
  cat "$TEST_DIR/clean.txt" >&2
  exit 1
fi

echo "==> Test: broken shell fixture fails with a clear failure line"
FIXTURE_REPO="$TEST_DIR/fixture-repo"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FIXTURE_REPO" "$FAKE_BIN"
(
  cd "$FIXTURE_REPO"
  git init -q
  git config user.email test@example.com
  git config user.name "Touchstone Test"
  printf 'if true; then\n  echo broken\n' >broken.sh
  git add broken.sh
  git commit -q -m "broken fixture"
)
cat >"$FAKE_BIN/shellcheck" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'broken.sh: missing fi\n' >&2
exit 1
EOF
cat >"$FAKE_BIN/shfmt" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_BIN/shellcheck" "$FAKE_BIN/shfmt"

if PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  TOUCHSTONE_NO_AUTO_UPDATE=1 \
  TOUCHSTONE_PREFLIGHT_VALIDATE_COMMAND=: \
  bash "$TOUCHSTONE_ROOT/bin/touchstone" preflight "$FIXTURE_REPO" >"$TEST_DIR/broken.txt" 2>&1; then
  echo "FAIL: broken shell fixture unexpectedly passed preflight" >&2
  cat "$TEST_DIR/broken.txt" >&2
  exit 1
fi
if grep -q 'FAIL shellcheck' "$TEST_DIR/broken.txt" \
  && grep -q 'FAIL preflight failed' "$TEST_DIR/broken.txt"; then
  echo "==> PASS: broken shell fixture fails visibly"
else
  echo "FAIL: broken fixture did not produce expected failure lines" >&2
  cat "$TEST_DIR/broken.txt" >&2
  exit 1
fi

MERGE_DIR="$TEST_DIR/merge"
mkdir -p "$MERGE_DIR/scripts" "$MERGE_DIR/lib" "$MERGE_DIR/bin" "$MERGE_DIR/repo"
cp "$TOUCHSTONE_ROOT/scripts/merge-pr.sh" "$MERGE_DIR/scripts/merge-pr.sh"
cp "$TOUCHSTONE_ROOT/lib/preflight.sh" "$MERGE_DIR/lib/preflight.sh"
cp "$TOUCHSTONE_ROOT/lib/preflight-scope.sh" "$MERGE_DIR/lib/preflight-scope.sh"
cp "$TOUCHSTONE_ROOT/lib/toml.sh" "$MERGE_DIR/lib/toml.sh"
cat >"$MERGE_DIR/scripts/codex-review.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo invoked > "$CODEX_REVIEW_LOG"
EOF
chmod +x "$MERGE_DIR/scripts/merge-pr.sh" "$MERGE_DIR/scripts/codex-review.sh"
printf '[review]\npreflight_required = true\n' >"$MERGE_DIR/repo/.codex-review.toml"
printf 'if true; then\n  echo broken\n' >"$MERGE_DIR/repo/broken.sh"

cat >"$MERGE_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "repo view") echo "main" ;;
  "pr view")
    case "${5:-}" in
      state) echo "OPEN" ;;
      headRefName) echo "feature/test" ;;
      headRefOid) echo "pr-head-oid" ;;
      mergeStateStatus,mergeable) echo "CLEAN MERGEABLE" ;;
      *) echo "unexpected gh pr view args: $*" >&2; exit 1 ;;
    esac
    ;;
  "pr checkout") echo checked-out > "$GH_CHECKOUT_FILE" ;;
  "pr merge") echo merged > "$GH_MERGE_FILE" ;;
  "pr comment") echo comment > "$GH_COMMENT_FILE" ;;
  *) echo "unexpected gh args: $*" >&2; exit 1 ;;
esac
EOF
cat >"$MERGE_DIR/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-C" ]; then
  cd "$2"
  shift 2
fi

case "$*" in
  "rev-parse --show-toplevel") printf '%s\n' "$TEST_REPO_ROOT" ;;
  "rev-parse --abbrev-ref HEAD")
    if [ -f "$GH_CHECKOUT_FILE" ]; then echo "HEAD"; else echo "feature/test"; fi
    ;;
  "rev-parse HEAD")
    if [ -f "$GH_CHECKOUT_FILE" ]; then echo "pr-head-oid"; else echo "stale-local-oid"; fi
    ;;
  "rev-parse --git-path touchstone/reviewer-clean") printf '%s\n' "$TEST_REPO_ROOT/.git/touchstone/reviewer-clean" ;;
  "rev-parse --git-path touchstone/squash-map.jsonl") printf '%s\n' "$TEST_REPO_ROOT/.git/touchstone/squash-map.jsonl" ;;
  "rev-parse feature/test") echo "pr-head-oid" ;;
  "rev-parse --verify --quiet origin/main^{commit}") echo "base-oid" ;;
  "fetch origin +refs/heads/main:refs/remotes/origin/main") echo fetched ;;
  "cat-file -e pr-head-oid^{commit}") ;;
  "merge-base origin/main pr-head-oid") echo "base-oid" ;;
  "status --porcelain" | "status --porcelain --untracked-files=all") ;;
  "diff --name-only origin/main...HEAD") echo "broken.sh" ;;
  "diff --name-only --cached") ;;
  "diff --name-only") ;;
  "ls-files") echo "broken.sh" ;;
  "ls-files --others --exclude-standard -z") ;;
  "worktree list --porcelain") ;;
  *) echo "unexpected git args: $*" >&2; exit 1 ;;
esac
EOF
cat >"$MERGE_DIR/bin/shellcheck" <<'EOF'
#!/usr/bin/env bash
exit "${PREFLIGHT_SHELLCHECK_EXIT:-1}"
EOF
cat >"$MERGE_DIR/bin/shfmt" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MERGE_DIR/bin/gh" "$MERGE_DIR/bin/git" "$MERGE_DIR/bin/shellcheck" "$MERGE_DIR/bin/shfmt"

run_merge_fixture() {
  local output_file="$1"
  shift
  PATH="$MERGE_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    TEST_REPO_ROOT="$MERGE_DIR/repo" \
    GH_CHECKOUT_FILE="$TEST_DIR/gh-checkout" \
    GH_MERGE_FILE="$TEST_DIR/gh-merge" \
    GH_COMMENT_FILE="$TEST_DIR/gh-comment" \
    CODEX_REVIEW_LOG="$TEST_DIR/codex-review.log" \
    TOUCHSTONE_PREFLIGHT_VALIDATE_COMMAND=: \
    bash "$MERGE_DIR/scripts/merge-pr.sh" "$@" >"$output_file" 2>&1
}

echo "==> Test: merge-pr short-circuits when preflight fails"
rm -f "$TEST_DIR/codex-review.log" "$TEST_DIR/gh-merge"
if run_merge_fixture "$TEST_DIR/merge-preflight-fail.txt" 123; then
  echo "FAIL: merge-pr unexpectedly succeeded with failing preflight" >&2
  cat "$TEST_DIR/merge-preflight-fail.txt" >&2
  exit 1
fi
if grep -q 'Deterministic preflight failed' "$TEST_DIR/merge-preflight-fail.txt" \
  && [ ! -f "$TEST_DIR/codex-review.log" ] \
  && [ ! -f "$TEST_DIR/gh-merge" ]; then
  echo "==> PASS: preflight failure blocks before review"
else
  echo "FAIL: preflight failure did not short-circuit review/merge" >&2
  cat "$TEST_DIR/merge-preflight-fail.txt" >&2
  exit 1
fi

echo "==> Test: TOUCHSTONE_NO_PREFLIGHT skips preflight and invokes review"
rm -f "$TEST_DIR/codex-review.log" "$TEST_DIR/gh-merge"
TOUCHSTONE_NO_PREFLIGHT=1 run_merge_fixture "$TEST_DIR/merge-preflight-skip.txt" 123
if grep -q 'Skipping preflight because TOUCHSTONE_NO_PREFLIGHT=1' "$TEST_DIR/merge-preflight-skip.txt" \
  && grep -q '^invoked$' "$TEST_DIR/codex-review.log"; then
  echo "==> PASS: TOUCHSTONE_NO_PREFLIGHT bypasses preflight"
else
  echo "FAIL: TOUCHSTONE_NO_PREFLIGHT did not skip preflight cleanly" >&2
  cat "$TEST_DIR/merge-preflight-skip.txt" >&2
  exit 1
fi
