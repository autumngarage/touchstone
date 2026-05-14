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

new_touchstone_fixture_repo() {
  local repo="$1"
  rm -rf "$repo"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q
    git config user.email test@example.com
    git config user.name "Touchstone Test"
    mkdir -p bootstrap scripts tests docs lib
    printf '2.99.0\n' >VERSION
    printf '#!/usr/bin/env bash\nset -euo pipefail\n' >bootstrap/new-project.sh
    chmod +x bootstrap/new-project.sh
    cat >scripts/touchstone-run.sh <<'EOF_TOUCHSTONE_RUN'
#!/usr/bin/env bash
set -euo pipefail
printf 'validate:%s\n' "$*" >>"$PREFLIGHT_TOOL_LOG"
EOF_TOUCHSTONE_RUN
    cat >tests/test-alpha.sh <<'EOF_TEST_ALPHA'
#!/usr/bin/env bash
set -euo pipefail
printf 'selftest:alpha\n' >>"$PREFLIGHT_TOOL_LOG"
if [ "${SELFTEST_FAIL_ALPHA:-0}" = "1" ]; then
  exit 41
fi
EOF_TEST_ALPHA
    cat >tests/test-beta.sh <<'EOF_TEST_BETA'
#!/usr/bin/env bash
set -euo pipefail
printf 'selftest:beta\n' >>"$PREFLIGHT_TOOL_LOG"
if [ "${SELFTEST_FAIL_BETA:-0}" = "1" ]; then
  exit 42
fi
EOF_TEST_BETA
    printf '# Touchstone fixture\n' >CLAUDE.md
    printf '# Guidance\n' >docs/guide.md
    printf '#!/usr/bin/env bash\nset -euo pipefail\necho core\n' >lib/core.sh
    chmod +x scripts/touchstone-run.sh tests/test-alpha.sh tests/test-beta.sh lib/core.sh
    git add VERSION bootstrap/new-project.sh scripts/touchstone-run.sh tests/test-alpha.sh tests/test-beta.sh CLAUDE.md docs/guide.md lib/core.sh
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
  printf '# touchstone managed\n' >lib/preflight.sh
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho managed\n' >scripts/merge-pr.sh
  printf '# Principle\n' >principles/git-workflow.md
  printf '# Skill\n' >.claude/skills/touchstone-git-workflow/SKILL.md
  git add .touchstone-version lib/preflight.sh scripts/merge-pr.sh principles/git-workflow.md .claude/skills/touchstone-git-workflow/SKILL.md
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
  mkdir -p lib scripts hooks principles .claude/skills/touchstone-example
  printf '# touchstone managed\n' >lib/preflight.sh
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho managed\n' >scripts/merge-pr.sh
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho managed\n' >hooks/codex-review.sh
  printf '# Principle\n' >principles/git-workflow.md
  printf '# Skill\n' >.claude/skills/touchstone-example/SKILL.md
  git add lib/preflight.sh scripts/merge-pr.sh hooks/codex-review.sh principles/git-workflow.md .claude/skills/touchstone-example/SKILL.md
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

echo "==> Test: touchstone self-preflight runs only changed self-test for test-only diff"
REPO="$TEST_DIR/repo-touchstone-self-test-only"
LOG="$TEST_DIR/touchstone-self-test-only.log"
OUT="$TEST_DIR/touchstone-self-test-only.out"
new_touchstone_fixture_repo "$REPO"
(
  cd "$REPO"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "selftest:alpha-changed\\n" >>"$PREFLIGHT_TOOL_LOG"\n' >tests/test-alpha.sh
  chmod +x tests/test-alpha.sh
  git add tests/test-alpha.sh
  git commit -q -m "change one self-test"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" '^selftest:alpha-changed$'
assert_log_not_contains "$LOG" '^selftest:beta$'
assert_log_not_contains "$LOG" '^validate:validate$'
if ! grep -q 'tests lane: touchstone-test-only (changed tests only)' "$OUT"; then
  echo "FAIL: touchstone test-only lane was not reported" >&2
  cat "$OUT" >&2
  exit 1
fi
echo "==> PASS: touchstone test-only diff runs only changed self-tests"

echo "==> Test: touchstone guidance diff skips full self-test suite"
REPO="$TEST_DIR/repo-touchstone-guidance-only"
LOG="$TEST_DIR/touchstone-guidance-only.log"
OUT="$TEST_DIR/touchstone-guidance-only.out"
new_touchstone_fixture_repo "$REPO"
(
  cd "$REPO"
  printf '# Guidance update\n' >docs/guide.md
  printf '# Touchstone fixture updated\n' >CLAUDE.md
  git add docs/guide.md CLAUDE.md
  git commit -q -m "guidance-only touchstone diff"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_not_contains "$LOG" '^selftest:alpha$'
assert_log_not_contains "$LOG" '^selftest:beta$'
assert_log_not_contains "$LOG" '^validate:validate$'
if ! grep -q 'SKIP tests (touchstone self-preflight: guidance/delivery-only diff; full self-tests not required)' "$OUT"; then
  echo "FAIL: touchstone guidance-only diff did not report self-test skip" >&2
  cat "$OUT" >&2
  exit 1
fi
echo "==> PASS: touchstone guidance-only diff skips full self-tests"

echo "==> Test: touchstone delivery-only diff skips full self-test suite"
REPO="$TEST_DIR/repo-touchstone-delivery-only"
LOG="$TEST_DIR/touchstone-delivery-only.log"
OUT="$TEST_DIR/touchstone-delivery-only.out"
new_touchstone_fixture_repo "$REPO"
(
  cd "$REPO"
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho managed\n' >scripts/merge-pr.sh
  chmod +x scripts/merge-pr.sh
  git add scripts/merge-pr.sh
  git commit -q -m "delivery-only touchstone diff"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" 'shellcheck:.*scripts/merge-pr.sh'
assert_log_contains "$LOG" 'shfmt:.*scripts/merge-pr.sh'
assert_log_not_contains "$LOG" '^selftest:alpha$'
assert_log_not_contains "$LOG" '^selftest:beta$'
if ! grep -q 'SKIP tests (touchstone self-preflight: guidance/delivery-only diff; full self-tests not required)' "$OUT"; then
  echo "FAIL: touchstone delivery-only diff did not report self-test skip" >&2
  cat "$OUT" >&2
  exit 1
fi
echo "==> PASS: touchstone delivery-only diff skips full self-tests"

echo "==> Test: touchstone core diff keeps full self-test suite"
REPO="$TEST_DIR/repo-touchstone-core-diff"
LOG="$TEST_DIR/touchstone-core-diff.log"
OUT="$TEST_DIR/touchstone-core-diff.out"
new_touchstone_fixture_repo "$REPO"
(
  cd "$REPO"
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho core changed\n' >lib/core.sh
  chmod +x lib/core.sh
  git add lib/core.sh
  git commit -q -m "touchstone core change"
)
: >"$LOG"
run_preflight "$REPO" "$OUT" "$LOG"
assert_log_contains "$LOG" '^selftest:alpha$'
assert_log_contains "$LOG" '^selftest:beta$'
assert_log_not_contains "$LOG" '^validate:validate$'
if ! grep -q 'tests lane: touchstone-full (core/risky or mixed diff)' "$OUT"; then
  echo "FAIL: touchstone full lane was not reported for core diff" >&2
  cat "$OUT" >&2
  exit 1
fi
echo "==> PASS: touchstone core diff runs full self-test suite"

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
CACHE_HASH_BEFORE="$(
  cd "$REPO"
  # shellcheck source=../lib/preflight.sh
  source "$TOUCHSTONE_ROOT/lib/preflight.sh"
  touchstone_preflight_cache_inputs origin/main | sed -n 's/^changed_files_hash=//p'
)"
(
  cd "$REPO"
  printf 'export const value = 2;\n' >apps/web/src/cache.ts
)
CACHE_HASH_AFTER="$(
  cd "$REPO"
  # shellcheck source=../lib/preflight.sh
  source "$TOUCHSTONE_ROOT/lib/preflight.sh"
  touchstone_preflight_cache_inputs origin/main | sed -n 's/^changed_files_hash=//p'
)"
if [ -z "$CACHE_HASH_BEFORE" ] || [ -z "$CACHE_HASH_AFTER" ] || [ "$CACHE_HASH_BEFORE" = "$CACHE_HASH_AFTER" ]; then
  echo "FAIL: changed file content did not affect changed_files_hash" >&2
  printf 'before=%s\nafter=%s\n' "$CACHE_HASH_BEFORE" "$CACHE_HASH_AFTER" >&2
  exit 1
fi
echo "==> PASS: cache inputs include changed file content hashes"
