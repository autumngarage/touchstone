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
TOUCHSTONE_TEST_GIT_BIN_DIR="$(dirname "$(command -v git)")"
SYSTEM_PATH="$PATH"

echo "==> Test: SHA-256 adapter falls back to sha256sum"
SHA256_FALLBACK_BIN="$TEST_DIR/sha256-fallback-bin"
mkdir -p "$SHA256_FALLBACK_BIN"
cat >"$SHA256_FALLBACK_BIN/sha256sum" <<'EOF'
#!/bin/bash
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  -\n'
EOF
chmod +x "$SHA256_FALLBACK_BIN/sha256sum"
fallback_digest="$(
  printf 'portable input\n' \
    | PATH="$SHA256_FALLBACK_BIN" TOUCHSTONE_ROOT="$TOUCHSTONE_ROOT" /bin/bash -c \
      'source "$TOUCHSTONE_ROOT/lib/sha256.sh"; touchstone_sha256_stream'
)"
if [ "$fallback_digest" != "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]; then
  echo "FAIL: SHA-256 adapter did not use the sha256sum fallback" >&2
  exit 1
fi

echo "==> Test: SHA-256 adapter propagates checksum command failures"
SHA256_BROKEN_BIN="$TEST_DIR/sha256-broken-bin"
mkdir -p "$SHA256_BROKEN_BIN"
cat >"$SHA256_BROKEN_BIN/shasum" <<'EOF'
#!/bin/bash
exit 23
EOF
cat >"$SHA256_BROKEN_BIN/sha256sum" <<'EOF'
#!/bin/bash
printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  -\n'
EOF
chmod +x "$SHA256_BROKEN_BIN/shasum" "$SHA256_BROKEN_BIN/sha256sum"
set +e
PATH="$SHA256_BROKEN_BIN" TOUCHSTONE_ROOT="$TOUCHSTONE_ROOT" /bin/bash -c \
  'set +o pipefail; source "$TOUCHSTONE_ROOT/lib/sha256.sh"; touchstone_sha256_stream' \
  >"$TEST_DIR/sha256-broken.out" 2>&1
broken_status=$?
set -e
if [ "$broken_status" -ne 23 ]; then
  echo "FAIL: SHA-256 adapter did not propagate the selected command failure" >&2
  cat "$TEST_DIR/sha256-broken.out" >&2
  exit 1
fi
if [ -s "$TEST_DIR/sha256-broken.out" ]; then
  echo "FAIL: SHA-256 adapter emitted output after the selected command failed" >&2
  cat "$TEST_DIR/sha256-broken.out" >&2
  exit 1
fi

echo "==> Test: SHA-256 adapter rejects malformed command output"
SHA256_MALFORMED_BIN="$TEST_DIR/sha256-malformed-bin"
mkdir -p "$SHA256_MALFORMED_BIN"
cat >"$SHA256_MALFORMED_BIN/shasum" <<'EOF'
#!/bin/bash
printf 'not-a-digest  -\n'
EOF
chmod +x "$SHA256_MALFORMED_BIN/shasum"
if PATH="$SHA256_MALFORMED_BIN" TOUCHSTONE_ROOT="$TOUCHSTONE_ROOT" /bin/bash -c \
  'source "$TOUCHSTONE_ROOT/lib/sha256.sh"; touchstone_sha256_stream' \
  >"$TEST_DIR/sha256-malformed.out" 2>&1; then
  echo "FAIL: SHA-256 adapter accepted malformed command output" >&2
  exit 1
fi
if ! grep -q "returned an invalid SHA-256 digest" "$TEST_DIR/sha256-malformed.out"; then
  echo "FAIL: SHA-256 adapter did not explain malformed command output" >&2
  cat "$TEST_DIR/sha256-malformed.out" >&2
  exit 1
fi

echo "==> Test: SHA-256 adapter fails closed without an implementation"
SHA256_EMPTY_BIN="$TEST_DIR/sha256-empty-bin"
mkdir -p "$SHA256_EMPTY_BIN"
if PATH="$SHA256_EMPTY_BIN" TOUCHSTONE_ROOT="$TOUCHSTONE_ROOT" /bin/bash -c \
  'source "$TOUCHSTONE_ROOT/lib/sha256.sh"; touchstone_sha256_stream' \
  >"$TEST_DIR/sha256-missing.out" 2>&1; then
  echo "FAIL: SHA-256 adapter passed without shasum or sha256sum" >&2
  exit 1
fi
if ! grep -q "requires 'shasum' or 'sha256sum'" "$TEST_DIR/sha256-missing.out"; then
  echo "FAIL: SHA-256 adapter did not explain its missing dependency" >&2
  cat "$TEST_DIR/sha256-missing.out" >&2
  exit 1
fi

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
if ! PATH="$CLEAN_FAKE_BIN:$SYSTEM_PATH" \
  TOUCHSTONE_NO_AUTO_UPDATE=1 \
  TOUCHSTONE_PREFLIGHT_VALIDATE_COMMAND=: \
  bash "$TOUCHSTONE_ROOT/bin/touchstone" preflight "$TOUCHSTONE_ROOT" >"$TEST_DIR/clean.txt" 2>&1; then
  echo "FAIL: clean tree preflight exited non-zero" >&2
  cat "$TEST_DIR/clean.txt" >&2
  exit 1
fi
if grep -q '==> preflight clean' "$TEST_DIR/clean.txt"; then
  echo "==> PASS: clean tree preflight exits 0"
else
  echo "FAIL: clean tree preflight did not report clean" >&2
  cat "$TEST_DIR/clean.txt" >&2
  exit 1
fi

echo "==> Test: optional dogfood smoke runs when configured"
DOGFOOD_REPO="$TEST_DIR/dogfood-repo"
DOGFOOD_LOG="$TEST_DIR/dogfood.log"
mkdir -p "$DOGFOOD_REPO"
(
  cd "$DOGFOOD_REPO"
  git init -q
  git config user.email test@example.com
  git config user.name "Touchstone Test"
  printf 'ok\n' >README.md
  git add README.md
  git commit -q -m "dogfood fixture"
)
PATH="$CLEAN_FAKE_BIN:$SYSTEM_PATH" \
  TOUCHSTONE_NO_AUTO_UPDATE=1 \
  TOUCHSTONE_PREFLIGHT_VALIDATE_COMMAND=: \
  TOUCHSTONE_PREFLIGHT_DOGFOOD_COMMAND='printf "dogfood\n" >>"$DOGFOOD_LOG"' \
  DOGFOOD_LOG="$DOGFOOD_LOG" \
  bash "$TOUCHSTONE_ROOT/bin/touchstone" preflight "$DOGFOOD_REPO" >"$TEST_DIR/dogfood.txt" 2>&1
if grep -q '^dogfood$' "$DOGFOOD_LOG" \
  && grep -q '==> dogfood smoke' "$TEST_DIR/dogfood.txt" \
  && grep -q 'OK dogfood smoke' "$TEST_DIR/dogfood.txt"; then
  echo "==> PASS: optional dogfood smoke ran through preflight"
else
  echo "FAIL: dogfood smoke did not run as expected" >&2
  cat "$TEST_DIR/dogfood.txt" >&2
  [ ! -f "$DOGFOOD_LOG" ] || cat "$DOGFOOD_LOG" >&2
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

if PATH="$FAKE_BIN:$SYSTEM_PATH" \
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

echo "==> Test: failure-log enumeration errors fail closed"
FAILING_FIND_BIN="$TEST_DIR/failing-find-bin"
FIND_FAILURE_ROOT="$TEST_DIR/find-failure-root"
FIND_CURRENT_DIR="$FIND_FAILURE_ROOT/20260804T000000Z-1"
mkdir -p "$FAILING_FIND_BIN" "$FIND_CURRENT_DIR"
cat >"$FAILING_FIND_BIN/find" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
chmod +x "$FAILING_FIND_BIN/find"
# shellcheck source=../lib/preflight.sh
source "$TOUCHSTONE_ROOT/lib/preflight.sh"
if PATH="$FAILING_FIND_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  touchstone_preflight_prune_failure_log_dirs \
  "$FIND_FAILURE_ROOT" "$FIND_CURRENT_DIR" >"$TEST_DIR/find-failure.txt" 2>&1; then
  echo "FAIL: failed failure-log enumeration unexpectedly passed" >&2
  cat "$TEST_DIR/find-failure.txt" >&2
  exit 1
fi
if grep -q 'could not enumerate retained preflight diagnostics' "$TEST_DIR/find-failure.txt"; then
  echo "==> PASS: failure-log enumeration errors are explicit and blocking"
else
  echo "FAIL: failed failure-log enumeration lacked actionable diagnostics" >&2
  cat "$TEST_DIR/find-failure.txt" >&2
  exit 1
fi

echo "==> Test: silent self-test failures retain exact command diagnostics"
SILENT_REPO="$TEST_DIR/silent-self-test-repo"
mkdir -p "$SILENT_REPO/bootstrap" "$SILENT_REPO/scripts" "$SILENT_REPO/tests" "$SILENT_REPO/lib"
(
  cd "$SILENT_REPO"
  git init -q
  git checkout -q -b main
  git config user.email test@example.com
  git config user.name "Touchstone Test"
  printf '0.0.0\n' >VERSION
  printf '#!/usr/bin/env bash\nexit 0\n' >bootstrap/new-project.sh
  printf '#!/usr/bin/env bash\nexit 0\n' >scripts/touchstone-run.sh
  printf '#!/usr/bin/env bash\nexit 0\n' >tests/test-a-pass.sh
  printf '#!/usr/bin/env bash\nexit 7\n' >tests/test-b-silent.sh
  printf '#!/usr/bin/env bash\nexit 9\n' >tests/test-c-silent.sh
  printf '#!/usr/bin/env bash\nexit 0\n' >lib/example.sh
  chmod +x bootstrap/new-project.sh scripts/touchstone-run.sh \
    tests/test-a-pass.sh tests/test-b-silent.sh tests/test-c-silent.sh lib/example.sh
  git add VERSION bootstrap/new-project.sh scripts/touchstone-run.sh tests lib/example.sh
  git commit -q -m "fixture baseline"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -b fix/silent-test
  printf '# changed\n' >>lib/example.sh
  git add lib/example.sh
  git commit -q -m "trigger full fallback"
)
SILENT_OUT="$TEST_DIR/silent-self-test.txt"
SILENT_COMMON_DIR="$(git -C "$SILENT_REPO" rev-parse --path-format=absolute --git-common-dir)"
SILENT_COMMON_DIR="$(cd "$SILENT_COMMON_DIR" && pwd)"
SILENT_FAILURE_ROOT="$SILENT_COMMON_DIR/touchstone/preflight-failures"
mkdir -p "$SILENT_FAILURE_ROOT"
for old_run in 01 02 03 04 05 06 07 08; do
  mkdir -p "$SILENT_FAILURE_ROOT/20000101T0000${old_run}Z-$old_run"
  printf 'old diagnostic %s\n' "$old_run" >"$SILENT_FAILURE_ROOT/20000101T0000${old_run}Z-$old_run/output.log"
done
if PATH="$TOUCHSTONE_TEST_GIT_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
  TOUCHSTONE_PREFLIGHT_SKIP_DOGFOOD=1 \
  bash "$TOUCHSTONE_ROOT/lib/preflight.sh" --diff origin/main "$SILENT_REPO" >"$SILENT_OUT" 2>&1; then
  echo "FAIL: silent self-test fixture unexpectedly passed preflight" >&2
  cat "$SILENT_OUT" >&2
  exit 1
fi
SILENT_LOGS="$(sed -n 's/^  FAIL retained output: //p' "$SILENT_OUT")"
SILENT_FIRST_LOG="$(printf '%s\n' "$SILENT_LOGS" | sed -n '1p')"
SILENT_SECOND_LOG="$(printf '%s\n' "$SILENT_LOGS" | sed -n '2p')"
SILENT_RETAINED_RUNS="$(find "$SILENT_FAILURE_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')"
if grep -q 'command: TOUCHSTONE_PREFLIGHT_IN_PROGRESS=1 bash tests/test-a-pass.sh' "$SILENT_OUT" \
  && grep -q 'OK command exit=0: TOUCHSTONE_PREFLIGHT_IN_PROGRESS=1 bash tests/test-a-pass.sh' "$SILENT_OUT" \
  && grep -q 'FAIL command exit=7: TOUCHSTONE_PREFLIGHT_IN_PROGRESS=1 bash tests/test-b-silent.sh' "$SILENT_OUT" \
  && grep -q 'FAIL command exit=9: TOUCHSTONE_PREFLIGHT_IN_PROGRESS=1 bash tests/test-c-silent.sh' "$SILENT_OUT" \
  && grep -q 'FAIL first failing command: TOUCHSTONE_PREFLIGHT_IN_PROGRESS=1 bash tests/test-b-silent.sh' "$SILENT_OUT" \
  && grep -q 'FAIL first exit status: 7' "$SILENT_OUT" \
  && [ -n "$SILENT_FIRST_LOG" ] && [ -f "$SILENT_FIRST_LOG" ] \
  && [ -n "$SILENT_SECOND_LOG" ] && [ -f "$SILENT_SECOND_LOG" ] \
  && [ "$SILENT_RETAINED_RUNS" -eq 6 ] \
  && [ ! -e "$SILENT_FAILURE_ROOT/20000101T000001Z-01" ]; then
  echo "==> PASS: silent failures preserve bounded, actionable diagnostics"
else
  echo "FAIL: silent self-test failure lacked actionable diagnostics" >&2
  cat "$SILENT_OUT" >&2
  exit 1
fi

echo "==> Test: invalid diagnostic retention limits fail closed without persistent output"
SILENT_INVALID_OUT="$TEST_DIR/silent-invalid-retention.txt"
if PATH="$TOUCHSTONE_TEST_GIT_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
  TOUCHSTONE_PREFLIGHT_SKIP_DOGFOOD=1 \
  TOUCHSTONE_PREFLIGHT_FAILURE_LOG_MAX_RUNS=invalid \
  bash "$TOUCHSTONE_ROOT/lib/preflight.sh" --diff origin/main "$SILENT_REPO" >"$SILENT_INVALID_OUT" 2>&1; then
  echo "FAIL: invalid retention fixture unexpectedly passed preflight" >&2
  cat "$SILENT_INVALID_OUT" >&2
  exit 1
fi
SILENT_RUNS_AFTER_INVALID="$(find "$SILENT_FAILURE_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')"
if [ "$SILENT_RUNS_AFTER_INVALID" -eq 6 ] \
  && grep -q 'invalid TOUCHSTONE_PREFLIGHT_FAILURE_LOG_MAX_RUNS=invalid' "$SILENT_INVALID_OUT" \
  && ! grep -q "retained output: $SILENT_FAILURE_ROOT/" "$SILENT_INVALID_OUT"; then
  echo "==> PASS: invalid retention configuration leaves persistent storage bounded"
else
  echo "FAIL: invalid retention configuration persisted unbounded output" >&2
  cat "$SILENT_INVALID_OUT" >&2
  exit 1
fi

echo "==> PASS: deterministic preflight checks are explicit and fail closed"
