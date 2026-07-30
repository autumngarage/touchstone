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
SYSTEM_PATH="$PATH"

echo "==> Test: SHA-256 adapter falls back to sha256sum"
SHA256_FALLBACK_BIN="$TEST_DIR/sha256-fallback-bin"
mkdir -p "$SHA256_FALLBACK_BIN"
cat >"$SHA256_FALLBACK_BIN/sha256sum" <<'EOF'
#!/bin/bash
printf 'windows-fallback-digest  -\n'
EOF
cat >"$SHA256_FALLBACK_BIN/awk" <<'EOF'
#!/bin/bash
read -r digest _rest
printf '%s\n' "$digest"
EOF
chmod +x "$SHA256_FALLBACK_BIN/sha256sum" "$SHA256_FALLBACK_BIN/awk"
fallback_digest="$(
  printf 'portable input\n' \
    | PATH="$SHA256_FALLBACK_BIN" TOUCHSTONE_ROOT="$TOUCHSTONE_ROOT" /bin/bash -c \
      'source "$TOUCHSTONE_ROOT/lib/sha256.sh"; touchstone_sha256_stream'
)"
if [ "$fallback_digest" != "windows-fallback-digest" ]; then
  echo "FAIL: SHA-256 adapter did not use the sha256sum fallback" >&2
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

echo "==> PASS: deterministic preflight checks are explicit and fail closed"
