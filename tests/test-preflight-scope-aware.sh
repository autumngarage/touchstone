#!/usr/bin/env bash
#
# tests/test-preflight-scope-aware.sh — diff-scoped deterministic preflight.
#
set -euo pipefail

unset TOUCHSTONE_NO_PREFLIGHT TOUCHSTONE_NO_AUTO_UPDATE

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-preflight-scope.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

FAKE_BIN="$TEST_DIR/bin"
NO_ACTIONLINT_BIN="$TEST_DIR/bin-no-actionlint"
mkdir -p "$FAKE_BIN" "$NO_ACTIONLINT_BIN"

cat >"$FAKE_BIN/shellcheck" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'shellcheck:%s\n' "$*" >>"$PREFLIGHT_TOOL_LOG"
for arg in "$@"; do
  case "$arg" in
    *bad*.sh)
      printf '%s: simulated shellcheck failure\n' "$arg" >&2
      exit 1
      ;;
  esac
done
EOF

cat >"$FAKE_BIN/shfmt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'shfmt:%s\n' "$*" >>"$PREFLIGHT_TOOL_LOG"
EOF

cat >"$FAKE_BIN/markdownlint" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'markdownlint:%s\n' "$*" >>"$PREFLIGHT_TOOL_LOG"
EOF

cat >"$FAKE_BIN/actionlint" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'actionlint:%s\n' "$*" >>"$PREFLIGHT_TOOL_LOG"
EOF

chmod +x "$FAKE_BIN/shellcheck" "$FAKE_BIN/shfmt" "$FAKE_BIN/markdownlint" "$FAKE_BIN/actionlint"
ln -s "$FAKE_BIN/shellcheck" "$NO_ACTIONLINT_BIN/shellcheck"
ln -s "$FAKE_BIN/shfmt" "$NO_ACTIONLINT_BIN/shfmt"
ln -s "$FAKE_BIN/markdownlint" "$NO_ACTIONLINT_BIN/markdownlint"

new_fixture_repo() {
  local repo="$1"
  rm -rf "$repo"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q
    git config user.email test@example.com
    git config user.name "Touchstone Test"
    mkdir -p docs .github/workflows app scripts
    printf '#!/usr/bin/env bash\nset -euo pipefail\necho clean\n' >unchanged-bad.sh
    cat >scripts/touchstone-run.sh <<'EOF_TOUCHSTONE_RUN'
#!/usr/bin/env bash
set -euo pipefail
printf 'validate:%s\n' "$*" >>"$PREFLIGHT_TOOL_LOG"
if [ "${PREFLIGHT_VALIDATE_FAIL:-}" = "1" ]; then
  exit 42
fi
EOF_TOUCHSTONE_RUN
    chmod +x scripts/touchstone-run.sh
    printf '# Baseline\n' >docs/unchanged.md
    printf 'name: baseline\non: push\njobs: {}\n' >.github/workflows/baseline.yml
    printf 'broken = True\n' >app/preexisting_type_debt.py
    git add unchanged-bad.sh scripts/touchstone-run.sh docs/unchanged.md .github/workflows/baseline.yml app/preexisting_type_debt.py
    git commit -q -m "baseline debt"
    git update-ref refs/remotes/origin/main HEAD
    git checkout -q -b feature/scope-test
  )
}

run_preflight() {
  local repo="$1" output="$2" log="$3"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    PREFLIGHT_TOOL_LOG="$log" \
    bash "$TOUCHSTONE_ROOT/lib/preflight.sh" --diff origin/main "$repo" >"$output" 2>&1
}

run_preflight_all_files() {
  local repo="$1" output="$2" log="$3"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    PREFLIGHT_TOOL_LOG="$log" \
    bash "$TOUCHSTONE_ROOT/lib/preflight.sh" --all-files "$repo" >"$output" 2>&1
}

run_preflight_without_actionlint() {
  local repo="$1" output="$2" log="$3"
  PATH="$NO_ACTIONLINT_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    PREFLIGHT_TOOL_LOG="$log" \
    bash "$TOUCHSTONE_ROOT/lib/preflight.sh" --diff origin/main "$repo" >"$output" 2>&1
}

assert_log_contains() {
  local log="$1" pattern="$2"
  if ! grep -q "$pattern" "$log"; then
    echo "FAIL: expected log to contain '$pattern'" >&2
    cat "$log" >&2
    exit 1
  fi
}

assert_log_not_contains() {
  local log="$1" pattern="$2"
  if grep -q "$pattern" "$log"; then
    echo "FAIL: expected log not to contain '$pattern'" >&2
    cat "$log" >&2
    exit 1
  fi
}

echo "==> Test: changed clean shell file ignores unchanged shell debt"
REPO="$TEST_DIR/repo-clean-shell"
LOG="$TEST_DIR/clean-shell.log"
OUT="$TEST_DIR/clean-shell.out"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho changed\n' >changed-clean.sh
  git add changed-clean.sh
  git commit -q -m "change clean shell"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" 'shellcheck:.*changed-clean.sh'
assert_log_contains "$LOG" 'shfmt:.*changed-clean.sh'
assert_log_not_contains "$LOG" 'unchanged-bad.sh'
echo "==> PASS: clean changed shell passes despite unchanged debt"

echo "==> Test: changed shell file with issue blocks"
REPO="$TEST_DIR/repo-bad-shell"
LOG="$TEST_DIR/bad-shell.log"
OUT="$TEST_DIR/bad-shell.out"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho bad\n' >changed-bad.sh
  git add changed-bad.sh
  git commit -q -m "change bad shell"
)
: >"$LOG"
if run_preflight "$REPO" "$OUT" "$LOG"; then
  echo "FAIL: changed shellcheck issue unexpectedly passed" >&2
  cat "$OUT" >&2
  exit 1
fi
assert_log_contains "$LOG" 'shellcheck:.*changed-bad.sh'
echo "==> PASS: changed shell issue blocks"

echo "==> Test: markdown-only change scopes to markdownlint"
REPO="$TEST_DIR/repo-md"
LOG="$TEST_DIR/md.log"
OUT="$TEST_DIR/md.out"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  printf '# Changed\n' >docs/changed.md
  git add docs/changed.md
  git commit -q -m "change markdown"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" 'markdownlint:.*docs/changed.md'
assert_log_not_contains "$LOG" '^shellcheck:'
assert_log_not_contains "$LOG" '^shfmt:'
assert_log_not_contains "$LOG" '^actionlint:'
echo "==> PASS: markdown-only change skips shell and workflow checks"

echo "==> Test: mixed changed paths run matching scoped checks"
REPO="$TEST_DIR/repo-mixed"
LOG="$TEST_DIR/mixed.log"
OUT="$TEST_DIR/mixed.out"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho mixed\n' >mixed.sh
  printf '# Mixed\n' >docs/mixed.md
  printf 'name: mixed\non: push\njobs: {}\n' >.github/workflows/mixed.yml
  git add mixed.sh docs/mixed.md .github/workflows/mixed.yml
  git commit -q -m "mixed changes"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" 'shellcheck:.*mixed.sh'
assert_log_contains "$LOG" 'shfmt:.*mixed.sh'
assert_log_contains "$LOG" 'markdownlint:.*docs/mixed.md'
assert_log_contains "$LOG" 'actionlint:.*.github/workflows/mixed.yml'
assert_log_not_contains "$LOG" 'unchanged-bad.sh'
echo "==> PASS: mixed change runs each scoped file list"

echo "==> Test: missing actionlint skips without pipefail failure"
REPO="$TEST_DIR/repo-missing-actionlint"
LOG="$TEST_DIR/missing-actionlint.log"
OUT="$TEST_DIR/missing-actionlint.out"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  printf 'name: missing-actionlint\non: push\njobs: {}\n' >.github/workflows/missing-actionlint.yml
  git add .github/workflows/missing-actionlint.yml
  git commit -q -m "change workflow without local actionlint"
)
: >"$LOG"
run_preflight_without_actionlint "$REPO" "$OUT" "$LOG"
if ! grep -q 'SKIP actionlint (actionlint not installed)' "$OUT"; then
  echo "FAIL: missing actionlint did not produce expected skip line" >&2
  cat "$OUT" >&2
  exit 1
fi
assert_log_not_contains "$LOG" '^actionlint:'
echo "==> PASS: missing actionlint remains a skip for workflow-only changes"

echo "==> Test: diff mode still runs full project validate"
REPO="$TEST_DIR/repo-validate"
LOG="$TEST_DIR/validate.log"
OUT="$TEST_DIR/validate.out"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  printf 'changed = True\n' >app/feature.py
  git add app/feature.py
  git commit -q -m "change app code"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" '^validate:validate$'
echo "==> PASS: diff mode runs full project validate"

echo "==> Test: full project validate failure blocks diff mode"
REPO="$TEST_DIR/repo-validate-fail"
LOG="$TEST_DIR/validate-fail.log"
OUT="$TEST_DIR/validate-fail.out"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  printf 'changed = True\n' >app/feature.py
  git add app/feature.py
  git commit -q -m "change app code"
)
: >"$LOG"
if PREFLIGHT_VALIDATE_FAIL=1 run_preflight "$REPO" "$OUT" "$LOG"; then
  echo "FAIL: failing project validate unexpectedly passed" >&2
  cat "$OUT" >&2
  exit 1
fi
assert_log_contains "$LOG" '^validate:validate$'
echo "==> PASS: diff mode blocks on full project validate failure"

echo "==> Test: --all-files restores full-project behavior"
REPO="$TEST_DIR/repo-all-files"
LOG="$TEST_DIR/all-files.log"
OUT="$TEST_DIR/all-files.out"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho clean\n' >changed-clean.sh
  git add changed-clean.sh
  git commit -q -m "change clean shell"
)
: >"$LOG"
if run_preflight_all_files "$REPO" "$OUT" "$LOG"; then
  echo "FAIL: --all-files unexpectedly ignored unchanged shell debt" >&2
  cat "$OUT" >&2
  exit 1
fi
assert_log_contains "$LOG" 'shellcheck:.*unchanged-bad.sh'
echo "==> PASS: --all-files checks unchanged baseline files"

echo "==> Test: touchstone-bump shape ignores project type debt outside change set"
REPO="$TEST_DIR/repo-touchstone-bump"
LOG="$TEST_DIR/touchstone-bump.log"
OUT="$TEST_DIR/touchstone-bump.out"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  mkdir -p lib scripts hooks principles .claude/skills/example
  printf '# touchstone managed\n' >lib/preflight.sh
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho managed\n' >scripts/merge-pr.sh
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho managed\n' >hooks/codex-review.sh
  printf '# Principle\n' >principles/git-workflow.md
  printf '# Skill\n' >.claude/skills/example/SKILL.md
  git add lib/preflight.sh scripts/merge-pr.sh hooks/codex-review.sh principles/git-workflow.md .claude/skills/example/SKILL.md
  git commit -q -m "touchstone bump"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_not_contains "$LOG" 'app/preexisting_type_debt.py'
assert_log_not_contains "$LOG" 'unchanged-bad.sh'
echo "==> PASS: pre-existing debt outside a touchstone-bump diff does not block"
