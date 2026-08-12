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

new_touchstone_self_repo() {
  local repo="$1" test_name
  rm -rf "$repo"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q
    git config user.email test@example.com
    git config user.name "Touchstone Test"
    mkdir -p bootstrap scripts tests principles .claude/skills/touchstone-git-workflow docs templates/ci .github/workflows
    printf '9.99.0\n' >VERSION
    printf '#!/usr/bin/env bash\nset -euo pipefail\n' >bootstrap/new-project.sh
    printf '#!/usr/bin/env bash\nset -euo pipefail\n' >scripts/touchstone-run.sh
    printf '#!/usr/bin/env bash\nset -euo pipefail\n' >scripts/issue-claim-check.sh
    printf '#!/usr/bin/env bash\nset -euo pipefail\n' >scripts/open-pr.sh
    printf '#!/usr/bin/env bash\nset -euo pipefail\n' >scripts/merge-pr.sh
    printf 'name: issue claim\n' >templates/ci/issue-claim-check.yml
    cp templates/ci/issue-claim-check.yml .github/workflows/issue-claim-check.yml
    chmod +x bootstrap/new-project.sh scripts/touchstone-run.sh scripts/issue-claim-check.sh scripts/open-pr.sh scripts/merge-pr.sh
    for test_name in \
      test-agent-steering-contract \
      test-bootstrap \
      test-claim-issue \
      test-dogfood \
      test-merge-pr \
      test-open-pr-cleanup-worktree \
      test-open-pr-exit-contract \
      test-open-pr-linked-issues \
      test-open-pr-sentinel-body \
      test-open-pr-upstream-mismatch \
      test-steering-size-caps \
      test-touchstone-block \
      test-update \
      test-other \
      test-target; do
      cat >"tests/${test_name}.sh" <<'EOF_SELF_TEST'
#!/usr/bin/env bash
set -euo pipefail
printf 'self:%s\n' "$(basename "$0")" >>"$PREFLIGHT_TOOL_LOG"
if [ "${SELF_TEST_FAIL:-}" = "$(basename "$0")" ]; then
  exit 1
fi
EOF_SELF_TEST
      chmod +x "tests/${test_name}.sh"
      case "$test_name" in
        test-update)
          printf '# direct consumer: scripts/open-pr.sh\n# direct consumer: scripts/merge-pr.sh\n' >>"tests/${test_name}.sh"
          ;;
      esac
    done
    printf '# Agent steering\n' >AGENTS.md
    printf '# Claude steering\n@TOUCHSTONE.md\n' >CLAUDE.md
    printf '# Workflow\n' >principles/git-workflow.md
    printf '# Skill\n' >.claude/skills/touchstone-git-workflow/SKILL.md
    printf '# Template agent steering\n' >templates/AGENTS.md
    printf '# Template Claude steering\n@TOUCHSTONE.md\n' >templates/CLAUDE.md
    printf '# Template Gemini steering\n' >templates/GEMINI.md
    printf '# Docs\n' >docs/overview.md
    git add VERSION bootstrap/new-project.sh scripts/touchstone-run.sh scripts/issue-claim-check.sh scripts/open-pr.sh scripts/merge-pr.sh tests AGENTS.md CLAUDE.md principles/git-workflow.md .claude/skills/touchstone-git-workflow/SKILL.md docs/overview.md templates .github/workflows/issue-claim-check.yml
    git commit -q -m "baseline touchstone fixture"
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

cache_input_field() {
  local repo="$1" field="$2"

  (
    cd "$repo"
    # shellcheck source=../lib/preflight.sh
    source "$TOUCHSTONE_ROOT/lib/preflight.sh"
    touchstone_preflight_cache_inputs origin/main | sed -n "s/^${field}=//p"
  )
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

echo "==> Test: scoped consumer discovery propagates inspection errors"
FAILING_GREP_BIN="$TEST_DIR/failing-grep-bin"
mkdir -p "$FAILING_GREP_BIN"
cat >"$FAILING_GREP_BIN/grep" <<'EOF_FAILING_GREP'
#!/usr/bin/env bash
exit 42
EOF_FAILING_GREP
chmod +x "$FAILING_GREP_BIN/grep"
if (
  cd "$TOUCHSTONE_ROOT"
  # shellcheck source=../lib/preflight.sh
  source "$TOUCHSTONE_ROOT/lib/preflight.sh"
  touchstone_preflight_changed_files() {
    printf 'scripts/open-pr.sh\n'
  }
  PATH="$FAILING_GREP_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    touchstone_preflight_touchstone_scoped_self_test_files \
    "$TEST_DIR/discovered-consumers.txt"
) >"$TEST_DIR/discovery-failure.out" 2>&1; then
  echo "FAIL: direct-consumer inspection error unexpectedly passed" >&2
  cat "$TEST_DIR/discovery-failure.out" >&2
  exit 1
fi
if grep -q 'could not inspect .* for dependency on scripts/open-pr.sh (grep exit 42)' \
  "$TEST_DIR/discovery-failure.out"; then
  echo "==> PASS: consumer inspection errors are explicit and blocking"
else
  echo "FAIL: consumer inspection error lacked actionable diagnostics" >&2
  cat "$TEST_DIR/discovery-failure.out" >&2
  exit 1
fi

echo "==> Test: partial changed-path enumeration falls back to the full suite"
if (
  cd "$TOUCHSTONE_ROOT"
  # shellcheck source=../lib/preflight.sh
  source "$TOUCHSTONE_ROOT/lib/preflight.sh"
  touchstone_preflight_changed_files() {
    printf 'scripts/open-pr.sh\n'
    return 42
  }
  touchstone_preflight_touchstone_scoped_self_test_files \
    "$TEST_DIR/partial-mapping.txt"
) >"$TEST_DIR/partial-mapping.out" 2>&1; then
  echo "FAIL: partial changed-path enumeration unexpectedly produced scoped coverage" >&2
  cat "$TEST_DIR/partial-mapping.out" >&2
  exit 1
fi
if grep -q 'could not enumerate changed paths for scoped self-tests; using the full suite' \
  "$TEST_DIR/partial-mapping.out"; then
  echo "==> PASS: partial changed-path enumeration cannot authorize scoped coverage"
else
  echo "FAIL: changed-path enumeration error lacked full-suite fallback context" >&2
  cat "$TEST_DIR/partial-mapping.out" >&2
  exit 1
fi

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

echo "==> Test: recognized shell-launched Python polyglot stays out of shell lint"
REPO="$TEST_DIR/repo-python-polyglot"
LOG="$TEST_DIR/python-polyglot.log"
OUT="$TEST_DIR/python-polyglot.out"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  cat >scripts/cross-platform-tool.py <<'EOF_PYTHON_POLYGLOT'
#!/bin/sh
""":"
if command -v py >/dev/null 2>&1; then
  exec py -3 "$0" "$@"
fi
if command -v python3 >/dev/null 2>&1; then
  exec python3 "$0" "$@"
fi
echo "ERROR: Python 3 is required." >&2
exit 2
":"""

print("python body")
EOF_PYTHON_POLYGLOT
  cat >scripts/single-quoted-tool.py <<'EOF_SINGLE_QUOTED_POLYGLOT'
#!/bin/sh
''':'
exec python3 "$0" "$@"
':'''

print("python body")
EOF_SINGLE_QUOTED_POLYGLOT
  cat >scripts/mixed-ending-tool.py <<'EOF_MIXED_ENDING_POLYGLOT'
#!/bin/sh
""":"
exec python3 "$0" "$@"
":"""
EOF_MIXED_ENDING_POLYGLOT
  printf '\r\nprint("CRLF Python body")\r\n' >>scripts/mixed-ending-tool.py
  git add scripts/cross-platform-tool.py scripts/single-quoted-tool.py \
    scripts/mixed-ending-tool.py
  git commit -q -m "add cross-platform Python tool"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_not_contains "$LOG" 'shellcheck:.*cross-platform-tool.py'
assert_log_not_contains "$LOG" 'shfmt:.*cross-platform-tool.py'
assert_log_not_contains "$LOG" 'shellcheck:.*single-quoted-tool.py'
assert_log_not_contains "$LOG" 'shfmt:.*single-quoted-tool.py'
assert_log_not_contains "$LOG" 'shellcheck:.*mixed-ending-tool.py'
assert_log_not_contains "$LOG" 'shfmt:.*mixed-ending-tool.py'
assert_log_contains "$LOG" '^validate:validate$'
echo "==> PASS: Python polyglot variants remain owned by Python validation"

echo "==> Test: shell-shebang Python file needs the recognized launcher contract"
REPO="$TEST_DIR/repo-unrecognized-python-shell"
LOG="$TEST_DIR/unrecognized-python-shell.log"
OUT="$TEST_DIR/unrecognized-python-shell.out"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  cat >scripts/not-a-python-polyglot.py <<'EOF_UNRECOGNIZED_PYTHON_SHELL'
#!/bin/sh
""":"
echo "This marker alone must not disable shell lint."
":"""

print("python body")
EOF_UNRECOGNIZED_PYTHON_SHELL
  cat >scripts/reordered-launcher.py <<'EOF_REORDERED_PYTHON_LAUNCHER'
#!/bin/sh
""":"
exec python3 "$@" "$0"
":"""

print("python body")
EOF_REORDERED_PYTHON_LAUNCHER
  cat >scripts/helper-launcher.py <<'EOF_HELPER_PYTHON_LAUNCHER'
#!/bin/sh
""":"
exec python3 helper.py "$0" "$@"
":"""

print("python body")
EOF_HELPER_PYTHON_LAUNCHER
  cat >scripts/heredoc-launcher.py <<'EOF_HEREDOC_PYTHON_LAUNCHER'
#!/bin/sh
""":"
cat <<'LAUNCHER_TEXT'
exec python3 "$0" "$@"
LAUNCHER_TEXT
":"""

print("python body")
EOF_HEREDOC_PYTHON_LAUNCHER
  printf '%s\r\n' \
    '#!/bin/sh' \
    '""":"' \
    'exec py -3 "$0" "$@"' \
    '":"""' \
    '' \
    'print("python body")' >scripts/crlf-polyglot.py
  git add scripts/not-a-python-polyglot.py scripts/reordered-launcher.py \
    scripts/helper-launcher.py scripts/heredoc-launcher.py \
    scripts/crlf-polyglot.py
  git commit -q -m "add unrecognized shell Python file"
)

# Model MSYS awk's text-mode CRLF normalization directly. The classifier must
# reject the raw file before this shim can erase its carriage returns.
if (
  cd "$REPO"
  # shellcheck source=../lib/preflight.sh
  source "$TOUCHSTONE_ROOT/lib/preflight.sh"
  awk() {
    local program="$1" input
    if [ "$#" -eq 1 ]; then
      command awk "$program"
      return
    fi
    input="$2"
    tr -d '\r' <"$input" | command awk "$program"
  }
  touchstone_preflight_is_python_shell_polyglot scripts/crlf-polyglot.py
); then
  echo "FAIL: text-mode awk normalization hid a raw CRLF polyglot" >&2
  exit 1
fi
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" 'shellcheck:.*not-a-python-polyglot.py'
assert_log_contains "$LOG" 'shfmt:.*not-a-python-polyglot.py'
assert_log_contains "$LOG" 'shellcheck:.*crlf-polyglot.py'
assert_log_contains "$LOG" 'shfmt:.*crlf-polyglot.py'
assert_log_contains "$LOG" 'shellcheck:.*reordered-launcher.py'
assert_log_contains "$LOG" 'shfmt:.*reordered-launcher.py'
assert_log_contains "$LOG" 'shellcheck:.*helper-launcher.py'
assert_log_contains "$LOG" 'shfmt:.*helper-launcher.py'
assert_log_contains "$LOG" 'shellcheck:.*heredoc-launcher.py'
assert_log_contains "$LOG" 'shfmt:.*heredoc-launcher.py'
echo "==> PASS: a quote marker cannot become a shell-lint bypass"

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

echo "==> Test: affected lane runs only for safely target-scoped diffs"
REPO="$TEST_DIR/repo-affected-lane"
LOG="$TEST_DIR/affected-lane.log"
OUT="$TEST_DIR/affected-lane.out"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  git checkout -q -B main
  cat >.touchstone-config <<'EOF_CONFIG'
validate_affected_command=printf "affected:%s\n" "$TOUCHSTONE_PREFLIGHT_VALIDATE_LANE" >>"$PREFLIGHT_TOOL_LOG"
EOF_CONFIG
  git add .touchstone-config
  git commit -q -m "configure affected lane"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -B feature/scope-test
  mkdir -p apps/web/src
  printf 'export const changed = true;\n' >apps/web/src/feature.ts
  git add apps/web/src/feature.ts
  git commit -q -m "change target-scoped app file"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" '^affected:affected$'
assert_log_not_contains "$LOG" '^validate:validate$'
if ! grep -q 'tests lane: affected' "$OUT"; then
  echo "FAIL: affected lane was not reported" >&2
  cat "$OUT" >&2
  exit 1
fi
echo "==> PASS: target-scoped diff used affected validation"

echo "==> Test: smoke lane runs for docs-only diffs when configured"
REPO="$TEST_DIR/repo-smoke-lane"
LOG="$TEST_DIR/smoke-lane.log"
OUT="$TEST_DIR/smoke-lane.out"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  git checkout -q -B main
  cat >.touchstone-config <<'EOF_CONFIG'
validate_smoke_command=printf "smoke:%s\n" "$TOUCHSTONE_PREFLIGHT_VALIDATE_LANE" >>"$PREFLIGHT_TOOL_LOG"
EOF_CONFIG
  git add .touchstone-config
  git commit -q -m "configure smoke lane"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -B feature/scope-test
  printf '# Smoke lane\n' >docs/smoke.md
  git add docs/smoke.md
  git commit -q -m "change docs with smoke lane"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" '^markdownlint:.*docs/smoke.md'
assert_log_contains "$LOG" '^smoke:smoke$'
assert_log_not_contains "$LOG" '^validate:validate$'
if ! grep -q 'tests lane: smoke' "$OUT"; then
  echo "FAIL: smoke lane was not reported" >&2
  cat "$OUT" >&2
  exit 1
fi
echo "==> PASS: docs-only diff used smoke validation"

echo "==> Test: smoke lane runs for Cortex metadata-only diffs when configured"
REPO="$TEST_DIR/repo-cortex-metadata-smoke-lane"
LOG="$TEST_DIR/cortex-metadata-smoke-lane.log"
OUT="$TEST_DIR/cortex-metadata-smoke-lane.out"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  git checkout -q -B main
  cat >.touchstone-config <<'EOF_CONFIG'
validate_smoke_command=printf "smoke:%s\n" "$TOUCHSTONE_PREFLIGHT_VALIDATE_LANE" >>"$PREFLIGHT_TOOL_LOG"
EOF_CONFIG
  git add .touchstone-config
  git commit -q -m "configure smoke lane"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -B feature/scope-test
  mkdir -p .cortex
  printf '# State\n' >.cortex/state.md
  printf '{"spec":"0.5.0","candidates":[]}\n' >.cortex/.index.json
  git add .cortex/state.md .cortex/.index.json
  git commit -q -m "refresh cortex metadata"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" '^smoke:smoke$'
assert_log_not_contains "$LOG" '^validate:validate$'
if ! grep -q 'tests lane: smoke' "$OUT"; then
  echo "FAIL: smoke lane was not reported" >&2
  cat "$OUT" >&2
  exit 1
fi
echo "==> PASS: Cortex metadata-only diff used smoke validation"

echo "==> Test: high-risk paths force full validation despite affected lane config"
REPO="$TEST_DIR/repo-high-risk-full"
LOG="$TEST_DIR/high-risk-full.log"
OUT="$TEST_DIR/high-risk-full.out"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  git checkout -q -B main
  cat >.touchstone-config <<'EOF_CONFIG'
validate_affected_command=printf "affected:%s\n" "$TOUCHSTONE_PREFLIGHT_VALIDATE_LANE" >>"$PREFLIGHT_TOOL_LOG"
EOF_CONFIG
  git add .touchstone-config
  git commit -q -m "configure affected lane"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -B feature/scope-test
  mkdir -p apps/web
  printf '{"scripts":{"test":"node test.js"}}\n' >apps/web/package.json
  git add apps/web/package.json
  git commit -q -m "change target dependency manifest"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" '^validate:validate$'
assert_log_not_contains "$LOG" '^affected:affected$'
if ! grep -q 'tests lane: full (dependency manifest or lockfile changed: apps/web/package.json)' "$OUT"; then
  echo "FAIL: high-risk path did not report full-validation reason" >&2
  cat "$OUT" >&2
  exit 1
fi
echo "==> PASS: high-risk target diff used full validation"

echo "==> Test: nested container config forces full validation"
REPO="$TEST_DIR/repo-nested-container-full"
LOG="$TEST_DIR/nested-container-full.log"
OUT="$TEST_DIR/nested-container-full.out"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  git checkout -q -B main
  cat >.touchstone-config <<'EOF_CONFIG'
validate_affected_command=printf "affected:%s\n" "$TOUCHSTONE_PREFLIGHT_VALIDATE_LANE" >>"$PREFLIGHT_TOOL_LOG"
EOF_CONFIG
  git add .touchstone-config
  git commit -q -m "configure affected lane"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -B feature/scope-test
  mkdir -p apps/web
  printf 'FROM node:22-alpine\n' >apps/web/Dockerfile
  git add apps/web/Dockerfile
  git commit -q -m "change nested container config"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" '^validate:validate$'
assert_log_not_contains "$LOG" '^affected:affected$'
if ! grep -q 'tests lane: full (deployment container config changed: apps/web/Dockerfile)' "$OUT"; then
  echo "FAIL: nested container config did not report full-validation reason" >&2
  cat "$OUT" >&2
  exit 1
fi
echo "==> PASS: nested container config used full validation"

echo "==> Test: delivery-only Touchstone-managed diff skips project validate"
REPO="$TEST_DIR/repo-delivery-only"
LOG="$TEST_DIR/delivery-only.log"
OUT="$TEST_DIR/delivery-only.out"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  mkdir -p lib scripts principles .claude/skills/touchstone-git-workflow
  printf '2.99.0\n' >.touchstone-version
  printf '# shared subscription auth boundary\n' >lib/codex-auth.sh
  printf '# touchstone managed\n' >lib/preflight.sh
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho managed\n' >scripts/merge-pr.sh
  printf '# Principle\n' >principles/git-workflow.md
  printf '# Skill\n' >.claude/skills/touchstone-git-workflow/SKILL.md
  git add .touchstone-version lib/codex-auth.sh lib/preflight.sh scripts/merge-pr.sh principles/git-workflow.md .claude/skills/touchstone-git-workflow/SKILL.md
  git commit -q -m "touchstone delivery-only bump"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" 'shellcheck:.*scripts/merge-pr.sh'
assert_log_contains "$LOG" 'shfmt:.*scripts/merge-pr.sh'
assert_log_not_contains "$LOG" '^validate:validate$'
if ! grep -q 'SKIP tests (delivery-only Touchstone-managed diff; project validate not required)' "$OUT"; then
  echo "FAIL: delivery-only diff did not report the project validate skip" >&2
  cat "$OUT" >&2
  exit 1
fi
echo "==> PASS: delivery-only sync diff skips app validation while keeping file checks"

echo "==> Test: mixed delivery and app diff keeps project validate"
REPO="$TEST_DIR/repo-delivery-mixed"
LOG="$TEST_DIR/delivery-mixed.log"
OUT="$TEST_DIR/delivery-mixed.out"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  mkdir -p scripts
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho managed\n' >scripts/merge-pr.sh
  printf 'changed = True\n' >app/feature.py
  git add scripts/merge-pr.sh app/feature.py
  git commit -q -m "touchstone bump plus app change"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" 'shellcheck:.*scripts/merge-pr.sh'
assert_log_contains "$LOG" '^validate:validate$'
echo "==> PASS: app-impacting mixed diff still runs project validate"

echo "==> Test: explicit validate command overrides delivery-only skip"
REPO="$TEST_DIR/repo-delivery-explicit-validate"
LOG="$TEST_DIR/delivery-explicit-validate.log"
OUT="$TEST_DIR/delivery-explicit-validate.out"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  mkdir -p scripts
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho managed\n' >scripts/merge-pr.sh
  git add scripts/merge-pr.sh
  git commit -q -m "touchstone managed script"
)
: >"$LOG"
if ! TOUCHSTONE_PREFLIGHT_VALIDATE_COMMAND='printf "custom-validate\n" >>"$PREFLIGHT_TOOL_LOG"' run_preflight "$REPO" "$OUT" "$LOG"; then
  echo "FAIL: explicit validate command failed unexpectedly" >&2
  cat "$OUT" >&2
  exit 1
fi
assert_log_contains "$LOG" '^custom-validate$'
assert_log_not_contains "$LOG" '^validate:validate$'
echo "==> PASS: explicit validate command remains authoritative"

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
  mkdir -p lib scripts principles .claude/skills/touchstone-example
  printf '# touchstone managed\n' >lib/preflight.sh
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho managed\n' >scripts/merge-pr.sh
  printf '[review.pr_triggered]\nrequired = true\nrequest_on_push = true\n' >.touchstone-review.toml
  printf '# Principle\n' >principles/git-workflow.md
  printf '# Skill\n' >.claude/skills/touchstone-example/SKILL.md
  git add .touchstone-review.toml lib/preflight.sh scripts/merge-pr.sh principles/git-workflow.md .claude/skills/touchstone-example/SKILL.md
  git commit -q -m "touchstone bump"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_not_contains "$LOG" 'app/preexisting_type_debt.py'
assert_log_not_contains "$LOG" 'unchanged-bad.sh'
assert_log_not_contains "$LOG" '^validate:validate$'
if ! grep -q 'SKIP tests (delivery-only Touchstone-managed diff; project validate not required)' "$OUT"; then
  echo "FAIL: touchstone-bump diff did not report the project validate skip" >&2
  cat "$OUT" >&2
  exit 1
fi
echo "==> PASS: pre-existing debt outside a touchstone-bump diff does not block"

echo "==> Test: Touchstone self preflight scopes changed test-only diffs"
REPO="$TEST_DIR/repo-touchstone-self-test-only"
LOG="$TEST_DIR/touchstone-self-test-only.log"
OUT="$TEST_DIR/touchstone-self-test-only.out"
new_touchstone_self_repo "$REPO"
(
  cd "$REPO"
  printf '\n# changed target test\n' >>tests/test-target.sh
  git add tests/test-target.sh
  git commit -q -m "change one self-test"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" '^self:test-target.sh$'
assert_log_not_contains "$LOG" '^self:test-other.sh$'
if ! grep -q 'tests (touchstone scoped self-tests)' "$OUT"; then
  echo "FAIL: Touchstone test-only diff did not report scoped self-tests" >&2
  cat "$OUT" >&2
  exit 1
fi
echo "==> PASS: Touchstone test-only diff runs only changed self-tests"

echo "==> Test: Touchstone steering diffs run steering sentinel tests"
REPO="$TEST_DIR/repo-touchstone-steering"
LOG="$TEST_DIR/touchstone-steering.log"
OUT="$TEST_DIR/touchstone-steering.out"
new_touchstone_self_repo "$REPO"
(
  cd "$REPO"
  printf '\n# updated guidance\n' >>AGENTS.md
  git add AGENTS.md
  git commit -q -m "change steering guidance"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" '^self:test-agent-steering-contract.sh$'
assert_log_contains "$LOG" '^self:test-dogfood.sh$'
assert_log_contains "$LOG" '^self:test-steering-size-caps.sh$'
assert_log_contains "$LOG" '^self:test-touchstone-block.sh$'
assert_log_not_contains "$LOG" '^self:test-other.sh$'
echo "==> PASS: Touchstone steering diff runs focused sentinel self-tests"

echo "==> Test: Touchstone Claude/template steering diffs run steering sentinel tests"
REPO="$TEST_DIR/repo-touchstone-template-steering"
LOG="$TEST_DIR/touchstone-template-steering.log"
OUT="$TEST_DIR/touchstone-template-steering.out"
new_touchstone_self_repo "$REPO"
(
  cd "$REPO"
  printf '\n# updated Claude guidance\n' >>CLAUDE.md
  printf '\n# updated template guidance\n' >>templates/AGENTS.md
  git add CLAUDE.md templates/AGENTS.md
  git commit -q -m "change Claude and template steering"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" '^self:test-agent-steering-contract.sh$'
assert_log_contains "$LOG" '^self:test-dogfood.sh$'
assert_log_contains "$LOG" '^self:test-steering-size-caps.sh$'
assert_log_contains "$LOG" '^self:test-touchstone-block.sh$'
assert_log_not_contains "$LOG" '^self:test-other.sh$'
echo "==> PASS: Touchstone Claude/template steering diff runs focused sentinel self-tests"

echo "==> Test: Touchstone issue-claim helper runs only its declared consumers"
REPO="$TEST_DIR/repo-touchstone-issue-claim"
LOG="$TEST_DIR/touchstone-issue-claim.log"
OUT="$TEST_DIR/touchstone-issue-claim.out"
new_touchstone_self_repo "$REPO"
(
  cd "$REPO"
  printf '\n# changed claim boundary\n' >>scripts/issue-claim-check.sh
  git add scripts/issue-claim-check.sh
  git commit -q -m "change issue claim helper"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" '^self:test-open-pr-cleanup-worktree.sh$'
assert_log_contains "$LOG" '^self:test-open-pr-exit-contract.sh$'
assert_log_contains "$LOG" '^self:test-open-pr-linked-issues.sh$'
assert_log_not_contains "$LOG" '^self:test-claim-issue.sh$'
assert_log_not_contains "$LOG" '^self:test-bootstrap.sh$'
assert_log_not_contains "$LOG" '^self:test-update.sh$'
assert_log_not_contains "$LOG" '^self:test-other.sh$'
assert_log_not_contains "$LOG" '^self:test-target.sh$'
if ! grep -q 'tests (touchstone scoped self-tests)' "$OUT"; then
  echo "FAIL: issue-claim helper diff did not report scoped self-tests" >&2
  cat "$OUT" >&2
  exit 1
fi
echo "==> PASS: issue-claim helper runs its fixture consumers without the full suite"

echo "==> Test: governed-path deletion selects the capability registry guard while staying scoped"
REPO="$TEST_DIR/repo-touchstone-governed-registry"
LOG="$TEST_DIR/touchstone-governed-registry.log"
OUT="$TEST_DIR/touchstone-governed-registry.out"
new_touchstone_self_repo "$REPO"
(
  cd "$REPO"
  git rm -q scripts/issue-claim-check.sh
  git commit -q -m "delete governed helper"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
# Deleting (or renaming) a file under a governed directory can strand a stale
# capabilities.toml declaration, and only the registry guard catches that. An
# explicitly mapped path must select the guard IN ADDITION to its own
# consumers — its own mapping alone let the deletion through with the fast
# tier green (PR #703 review).
assert_log_contains "$LOG" '^self:test-steering-size-caps.sh$'
assert_log_contains "$LOG" '^self:test-open-pr-cleanup-worktree.sh$'
assert_log_contains "$LOG" '^self:test-open-pr-exit-contract.sh$'
assert_log_contains "$LOG" '^self:test-open-pr-linked-issues.sh$'
# Still the scoped lane, not the full-suite fallback — a fallback would run
# the registry guard for the vacuous reason that it runs everything, and the
# assertion above would prove nothing about the governed-path mapping.
assert_log_not_contains "$LOG" '^self:test-other.sh$'
if ! grep -q 'tests (touchstone scoped self-tests)' "$OUT"; then
  echo "FAIL: governed-path deletion did not stay in the scoped self-test lane" >&2
  cat "$OUT" >&2
  exit 1
fi
echo "==> PASS: governed-path deletion adds the registry guard to its scoped selection"

echo "==> Test: Touchstone issue-claim workflow runs installation and consistency consumers"
REPO="$TEST_DIR/repo-touchstone-issue-claim-workflow"
LOG="$TEST_DIR/touchstone-issue-claim-workflow.log"
OUT="$TEST_DIR/touchstone-issue-claim-workflow.out"
new_touchstone_self_repo "$REPO"
(
  cd "$REPO"
  printf '\n# changed workflow contract\n' >>templates/ci/issue-claim-check.yml
  git add templates/ci/issue-claim-check.yml
  git commit -q -m "change issue claim workflow"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" '^self:test-bootstrap.sh$'
assert_log_contains "$LOG" '^self:test-update.sh$'
assert_log_contains "$LOG" '^self:test-open-pr-cleanup-worktree.sh$'
assert_log_contains "$LOG" '^self:test-open-pr-exit-contract.sh$'
assert_log_contains "$LOG" '^self:test-open-pr-linked-issues.sh$'
assert_log_not_contains "$LOG" '^self:test-other.sh$'
echo "==> PASS: issue-claim workflow runs every demonstrated workflow consumer"

echo "==> Test: Touchstone open-PR helper includes every direct and indirect consumer"
REPO="$TEST_DIR/repo-touchstone-open-pr-helper"
LOG="$TEST_DIR/touchstone-open-pr-helper.log"
OUT="$TEST_DIR/touchstone-open-pr-helper.out"
new_touchstone_self_repo "$REPO"
(
  cd "$REPO"
  printf '\n# changed PR helper boundary\n' >>scripts/open-pr.sh
  git add scripts/open-pr.sh
  git commit -q -m "change open PR helper"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" '^self:test-open-pr-cleanup-worktree.sh$'
assert_log_contains "$LOG" '^self:test-open-pr-exit-contract.sh$'
assert_log_contains "$LOG" '^self:test-open-pr-linked-issues.sh$'
assert_log_contains "$LOG" '^self:test-open-pr-sentinel-body.sh$'
assert_log_contains "$LOG" '^self:test-open-pr-upstream-mismatch.sh$'
assert_log_contains "$LOG" '^self:test-update.sh$'
assert_log_not_contains "$LOG" '^self:test-other.sh$'
echo "==> PASS: open-PR helper includes its discovered update integration consumer"

echo "==> Test: Touchstone merge helper runs merge and update consumers"
REPO="$TEST_DIR/repo-touchstone-merge-helper"
LOG="$TEST_DIR/touchstone-merge-helper.log"
OUT="$TEST_DIR/touchstone-merge-helper.out"
new_touchstone_self_repo "$REPO"
(
  cd "$REPO"
  printf '\n# changed merge boundary\n' >>scripts/merge-pr.sh
  git add scripts/merge-pr.sh
  git commit -q -m "change merge helper"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" '^self:test-merge-pr.sh$'
assert_log_contains "$LOG" '^self:test-update.sh$'
# Journal hook retired (issue #730): the merge-helper mapping must not
# select the removed hook test.
assert_log_not_contains "$LOG" '^self:test-cortex-pr-merged-hook.sh$'
assert_log_not_contains "$LOG" '^self:test-other.sh$'
echo "==> PASS: merge helper runs merge and update integration consumers"

echo "==> Test: Touchstone unknown diffs keep full self-test fallback"
REPO="$TEST_DIR/repo-touchstone-full-fallback"
LOG="$TEST_DIR/touchstone-full-fallback.log"
OUT="$TEST_DIR/touchstone-full-fallback.out"
new_touchstone_self_repo "$REPO"
(
  cd "$REPO"
  printf 'updated\n' >unexpected-runtime-file.txt
  git add unexpected-runtime-file.txt
  git commit -q -m "change unknown runtime file"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" '^self:test-target.sh$'
assert_log_contains "$LOG" '^self:test-other.sh$'
if ! grep -q 'tests (touchstone self-tests)' "$OUT"; then
  echo "FAIL: Touchstone unknown diff did not report full self-tests" >&2
  cat "$OUT" >&2
  exit 1
fi
if ! grep -q 'full self-test fallback: unmapped changed path: unexpected-runtime-file.txt' "$OUT"; then
  echo "FAIL: Touchstone fallback did not name the unmapped changed path" >&2
  cat "$OUT" >&2
  exit 1
fi
echo "==> PASS: Touchstone unknown diff falls back to full self-tests"

echo "==> Test: preflight cache inputs hash changed file contents"
REPO="$TEST_DIR/repo-cache-inputs"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  mkdir -p apps/web/src
  printf 'export const value = 1;\n' >apps/web/src/cache.ts
  git add apps/web/src/cache.ts
  git commit -q -m "change cached file"
)
CACHE_HASH_BEFORE="$(cache_input_field "$REPO" changed_files_hash)"
(
  cd "$REPO"
  printf 'export const value = 2;\n' >apps/web/src/cache.ts
)
CACHE_HASH_AFTER="$(cache_input_field "$REPO" changed_files_hash)"
if [ -z "$CACHE_HASH_BEFORE" ] || [ -z "$CACHE_HASH_AFTER" ] || [ "$CACHE_HASH_BEFORE" = "$CACHE_HASH_AFTER" ]; then
  echo "FAIL: changed file content did not affect changed_files_hash" >&2
  printf 'before=%s\nafter=%s\n' "$CACHE_HASH_BEFORE" "$CACHE_HASH_AFTER" >&2
  exit 1
fi
echo "==> PASS: cache inputs include changed file content hashes"

echo "==> Test: preflight cache worktree hash ignores unrelated untracked files"
REPO="$TEST_DIR/repo-cache-unrelated-untracked"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  mkdir -p apps/web/src
  printf 'export const value = 1;\n' >apps/web/src/cache.ts
  git add apps/web/src/cache.ts
  git commit -q -m "change cached file"
)
WORKTREE_HASH_BEFORE="$(cache_input_field "$REPO" worktree_hash)"
printf 'local scratch\n' >"$REPO/local-scratch.log"
WORKTREE_HASH_AFTER="$(cache_input_field "$REPO" worktree_hash)"
if [ -z "$WORKTREE_HASH_BEFORE" ] || [ -z "$WORKTREE_HASH_AFTER" ] || [ "$WORKTREE_HASH_BEFORE" != "$WORKTREE_HASH_AFTER" ]; then
  echo "FAIL: unrelated untracked file changed worktree_hash" >&2
  printf 'before=%s\nafter=%s\n' "$WORKTREE_HASH_BEFORE" "$WORKTREE_HASH_AFTER" >&2
  exit 1
fi
echo "==> PASS: unrelated untracked file does not affect worktree_hash"

echo "==> Test: preflight cache worktree hash includes dirty changed paths"
REPO="$TEST_DIR/repo-cache-dirty-changed-path"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  mkdir -p apps/web/src
  printf 'export const value = 1;\n' >apps/web/src/cache.ts
  git add apps/web/src/cache.ts
  git commit -q -m "change cached file"
)
WORKTREE_HASH_BEFORE="$(cache_input_field "$REPO" worktree_hash)"
printf 'export const value = 2;\n' >"$REPO/apps/web/src/cache.ts"
WORKTREE_HASH_AFTER="$(cache_input_field "$REPO" worktree_hash)"
if [ -z "$WORKTREE_HASH_BEFORE" ] || [ -z "$WORKTREE_HASH_AFTER" ] || [ "$WORKTREE_HASH_BEFORE" = "$WORKTREE_HASH_AFTER" ]; then
  echo "FAIL: dirty changed path did not affect worktree_hash" >&2
  printf 'before=%s\nafter=%s\n' "$WORKTREE_HASH_BEFORE" "$WORKTREE_HASH_AFTER" >&2
  exit 1
fi
echo "==> PASS: dirty changed path affects worktree_hash"

echo "==> Test: preflight cache worktree hash includes untracked replacements for changed paths"
REPO="$TEST_DIR/repo-cache-untracked-replacement"
new_fixture_repo "$REPO"
(
  cd "$REPO"
  git rm -q docs/unchanged.md
  git commit -q -m "delete docs file"
)
WORKTREE_HASH_BEFORE="$(cache_input_field "$REPO" worktree_hash)"
mkdir -p "$REPO/docs"
printf '# Local replacement\n' >"$REPO/docs/unchanged.md"
WORKTREE_HASH_AFTER="$(cache_input_field "$REPO" worktree_hash)"
if [ -z "$WORKTREE_HASH_BEFORE" ] || [ -z "$WORKTREE_HASH_AFTER" ] || [ "$WORKTREE_HASH_BEFORE" = "$WORKTREE_HASH_AFTER" ]; then
  echo "FAIL: untracked replacement for changed path did not affect worktree_hash" >&2
  printf 'before=%s\nafter=%s\n' "$WORKTREE_HASH_BEFORE" "$WORKTREE_HASH_AFTER" >&2
  exit 1
fi
echo "==> PASS: untracked changed-path replacement affects worktree_hash"

# ---------------------------------------------------------------------------
# Issue #628: a diff of exactly {VERSION, .touchstone-version} holding the
# same valid semver is the deterministic release bump and selects the focused
# release lane. Any looser shape fails closed to the full self-test suite.
# ---------------------------------------------------------------------------
add_release_lane_baseline() {
  # Extends the touchstone-self fixture baseline with the release-lane test
  # consumers and a synchronized .touchstone-version, then re-anchors
  # origin/main so a later bump commit is the entire diff.
  (
    cd "$1"
    local t
    for t in test-release test-run-script test-auto-update test-status; do
      cp tests/test-other.sh "tests/${t}.sh"
      chmod +x "tests/${t}.sh"
    done
    printf '9.99.0\n' >.touchstone-version
    git add tests .touchstone-version
    git commit -q -m "baseline release-lane fixtures"
    git update-ref refs/remotes/origin/main HEAD
  )
}

echo "==> Test: version-only release bump selects the focused release lane"
REPO="$TEST_DIR/repo-touchstone-release-bump"
LOG="$TEST_DIR/touchstone-release-bump.log"
OUT="$TEST_DIR/touchstone-release-bump.out"
new_touchstone_self_repo "$REPO"
add_release_lane_baseline "$REPO"
(
  cd "$REPO"
  printf '9.99.1\n' >VERSION
  printf '9.99.1\n' >.touchstone-version
  git add VERSION .touchstone-version
  git commit -q -m "release bump"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
if ! grep -q 'version-only release lane (VERSION = .touchstone-version = 9.99.1)' "$OUT"; then
  echo "FAIL: version-only bump did not report the release lane" >&2
  cat "$OUT" >&2
  exit 1
fi
assert_log_contains "$LOG" '^self:test-release.sh$'
assert_log_contains "$LOG" '^self:test-update.sh$'
assert_log_contains "$LOG" '^self:test-run-script.sh$'
assert_log_contains "$LOG" '^self:test-auto-update.sh$'
assert_log_contains "$LOG" '^self:test-status.sh$'
assert_log_not_contains "$LOG" '^self:test-other.sh$'
assert_log_not_contains "$LOG" '^self:test-bootstrap.sh$'
echo "==> PASS: version-only release bump runs only version-reader self-tests"

echo "==> Test: non-release version diffs fail closed to the full suite"
for variant in alone mismatch invalid extra; do
  REPO="$TEST_DIR/repo-touchstone-release-$variant"
  LOG="$TEST_DIR/touchstone-release-$variant.log"
  OUT="$TEST_DIR/touchstone-release-$variant.out"
  new_touchstone_self_repo "$REPO"
  add_release_lane_baseline "$REPO"
  (
    cd "$REPO"
    case "$variant" in
      alone)
        printf '9.99.1\n' >VERSION
        git add VERSION
        ;;
      mismatch)
        printf '9.99.1\n' >VERSION
        printf '9.99.2\n' >.touchstone-version
        git add VERSION .touchstone-version
        ;;
      invalid)
        printf 'v9.99.1-rc\n' >VERSION
        printf 'v9.99.1-rc\n' >.touchstone-version
        git add VERSION .touchstone-version
        ;;
      extra)
        printf '9.99.1\n' >VERSION
        printf '9.99.1\n' >.touchstone-version
        printf '# stray\n' >stray-file.md
        git add VERSION .touchstone-version stray-file.md
        ;;
    esac
    git commit -q -m "non-release version diff ($variant)"
  )
  : >"$LOG"
  run_preflight "$REPO" "$OUT" "$LOG"
  if grep -q 'version-only release lane' "$OUT"; then
    echo "FAIL: variant '$variant' wrongly selected the release lane" >&2
    cat "$OUT" >&2
    exit 1
  fi
  if ! grep -q 'full self-test fallback: unmapped changed path' "$OUT"; then
    echo "FAIL: variant '$variant' did not fall back to the full suite" >&2
    cat "$OUT" >&2
    exit 1
  fi
  assert_log_contains "$LOG" '^self:test-other.sh$'
done
echo "==> PASS: version diffs outside the exact release shape fail closed"
