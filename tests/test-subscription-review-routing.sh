#!/usr/bin/env bash
#
# Regression coverage for the subscription-only local review boundary.

set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$TOUCHSTONE_ROOT/hooks/codex-review.sh"
TEST_DIR="$(mktemp -d -t touchstone-subscription-review.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf 'main\n'
EOF

cat >"$FAKE_BIN/conductor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  doctor)
    printf '{"providers":[{"configured":true}]}\n'
    exit 0
    ;;
  review | exec | call)
    printf '%s\n' "$*" >>"$CONDUCTOR_ARGS_LOG"
    cat >/dev/null
    if [ "${CONDUCTOR_RESULT:-clean}" = "fail" ]; then
      printf 'configured provider unavailable\n' >&2
      exit 42
    fi
    printf 'CODEX_REVIEW_CLEAN\n'
    ;;
  *)
    printf 'unexpected conductor command: %s\n' "$*" >&2
    exit 99
    ;;
esac
EOF
chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/conductor"

setup_repo() {
  local repo="$1"
  local config="${2:-}"

  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name "Touchstone Test"
  git -C "$repo" config user.email "touchstone@example.com"
  printf 'base\n' >"$repo/example.txt"
  if [ -n "$config" ]; then
    printf '%s\n' "$config" >"$repo/.touchstone-review.toml"
  fi
  git -C "$repo" add .
  git -C "$repo" commit -qm base
  printf 'change\n' >>"$repo/example.txt"
  git -C "$repo" add example.txt
  git -C "$repo" commit -qm change
}

run_review() {
  local repo="$1"
  local output="$2"
  local result="${3:-clean}"

  (
    cd "$repo"
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
      CONDUCTOR_ARGS_LOG="$CONDUCTOR_ARGS_LOG" \
      CONDUCTOR_RESULT="$result" \
      CODEX_REVIEW_BASE=HEAD~1 \
      CODEX_REVIEW_DISABLE_CACHE=1 \
      CODEX_REVIEW_MODE=review-only \
      CODEX_REVIEW_ON_ERROR=fail-closed \
      TOUCHSTONE_REVIEW_LOG=/dev/null \
      bash "$HOOK" >"$output" 2>&1
  )
}

echo "==> Test: omitted provider defaults to subscription Codex without fallback"
DEFAULT_REPO="$TEST_DIR/default"
DEFAULT_OUTPUT="$TEST_DIR/default.out"
CONDUCTOR_ARGS_LOG="$TEST_DIR/default.args"
export CONDUCTOR_ARGS_LOG
setup_repo "$DEFAULT_REPO"
set +e
run_review "$DEFAULT_REPO" "$DEFAULT_OUTPUT" fail
default_rc=$?
set -e

if [ "$default_rc" -eq 1 ] \
  && [ "$(wc -l <"$CONDUCTOR_ARGS_LOG" | tr -d ' ')" = "1" ] \
  && grep -q -- '^review .*--with codex' "$CONDUCTOR_ARGS_LOG" \
  && grep -q 'cost boundary:  subscription-codex' "$DEFAULT_OUTPUT" \
  && ! grep -q 'Retrying once' "$DEFAULT_OUTPUT"; then
  echo "==> PASS: default stayed on subscription Codex"
else
  echo "FAIL: omitted provider should invoke Codex once and fail per on_error" >&2
  cat "$DEFAULT_OUTPUT" >&2
  cat "$CONDUCTOR_ARGS_LOG" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: explicit auto route is visible and unpinned"
AUTO_REPO="$TEST_DIR/auto"
AUTO_OUTPUT="$TEST_DIR/auto.out"
CONDUCTOR_ARGS_LOG="$TEST_DIR/auto.args"
export CONDUCTOR_ARGS_LOG
setup_repo "$AUTO_REPO" '[review.conductor]
with = "auto"'
run_review "$AUTO_REPO" "$AUTO_OUTPUT"

if grep -q '^review ' "$CONDUCTOR_ARGS_LOG" \
  && ! grep -q -- '--with ' "$CONDUCTOR_ARGS_LOG" \
  && grep -q -- '--prefer ' "$CONDUCTOR_ARGS_LOG" \
  && grep -q 'cost boundary:  auto-explicit-may-be-metered' "$AUTO_OUTPUT"; then
  echo "==> PASS: auto-routing required explicit, visible opt-in"
else
  echo "FAIL: explicit auto route should be unpinned and visibly metered-capable" >&2
  cat "$AUTO_OUTPUT" >&2
  cat "$CONDUCTOR_ARGS_LOG" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: explicit provider pin remains supported"
METERED_REPO="$TEST_DIR/metered"
METERED_OUTPUT="$TEST_DIR/metered.out"
CONDUCTOR_ARGS_LOG="$TEST_DIR/metered.args"
export CONDUCTOR_ARGS_LOG
setup_repo "$METERED_REPO" '[review.conductor]
with = "openrouter"'
run_review "$METERED_REPO" "$METERED_OUTPUT"

if grep -q -- '^review .*--with openrouter' "$CONDUCTOR_ARGS_LOG" \
  && grep -q 'cost boundary:  explicit-provider:openrouter' "$METERED_OUTPUT"; then
  echo "==> PASS: metered provider required an explicit pin"
else
  echo "FAIL: explicit provider should be forwarded and labeled" >&2
  cat "$METERED_OUTPUT" >&2
  cat "$CONDUCTOR_ARGS_LOG" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Test: managed defaults and installed hook mirror preserve the boundary"
if grep -q '^with = "codex"$' "$TOUCHSTONE_ROOT/.touchstone-review.toml" \
  && grep -q '^high_scrutiny_mode = "off"$' "$TOUCHSTONE_ROOT/.touchstone-review.toml" \
  && grep -q 'AI_CONDUCTOR_WITH="codex"' "$TOUCHSTONE_ROOT/templates/setup.sh" \
  && cmp -s "$TOUCHSTONE_ROOT/hooks/codex-review.sh" "$TOUCHSTONE_ROOT/scripts/codex-review.sh"; then
  echo "==> PASS: managed defaults are subscription-only"
else
  echo "FAIL: managed config, setup status, and hook mirror must agree" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -gt 0 ]; then
  echo "==> FAIL: $ERRORS assertion(s) failed" >&2
  exit 1
fi

echo "==> PASS: all subscription review routing assertions passed"
