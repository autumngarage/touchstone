#!/usr/bin/env bash
#
# Tests for `touchstone review --dry-run` — preview which provider
# would be picked for the next push, without spending tokens.

set -euo pipefail

TOUCHSTONE_ROOT="${TOUCHSTONE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TOUCHSTONE_BIN="$TOUCHSTONE_ROOT/bin/touchstone"

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-test-review-dry.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

# Mock conductor that records its argv to a file so the test can assert
# which flags were passed. `route` echoes a synthetic preview; `doctor`
# returns a configured marker.
FAKE_BIN="$TEST_DIR/bin"
ARGS_FILE="$TEST_DIR/conductor-argv.log"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/conductor" <<'CXEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGS_FILE"
case "$1" in
  doctor) printf '{"providers":[{"configured":true}]}\n' ;;
  route)
    shift
    cat <<EOF
→ would pick: claude
  tier: frontier  ·  prefer: best  ·  effort: max
  matched tags: code-review

mocked dry-run for: $*
EOF
    ;;
  *) echo "mock conductor: unsupported subcommand $1" >&2; exit 2 ;;
esac
CXEOF
chmod +x "$FAKE_BIN/conductor"

run_review() {
  local repo="$1"; shift
  (
    cd "$repo"
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
      ARGS_FILE="$ARGS_FILE" \
      TOUCHSTONE_NO_AUTO_UPDATE=1 \
      bash "$TOUCHSTONE_BIN" review "$@"
  )
}

new_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  echo init > "$dir/README.md"
  git -C "$dir" add . && git -C "$dir" commit -qm init
}

# ----------------------------------------------------------------------------
echo "==> Test: --dry-run with auto-routed config calls conductor route"
REPO_AUTO="$TEST_DIR/repo-auto"
new_repo "$REPO_AUTO"
cat > "$REPO_AUTO/.codex-review.toml" <<'EOF'
[review]
enabled = true
reviewer = "conductor"
[review.conductor]
prefer = "best"
effort = "max"
tags = "code-review"
EOF
git -C "$REPO_AUTO" add . && git -C "$REPO_AUTO" commit -qm cfg
echo c >> "$REPO_AUTO/README.md" && git -C "$REPO_AUTO" add . && git -C "$REPO_AUTO" commit -qm change

: > "$ARGS_FILE"
out="$(run_review "$REPO_AUTO" --dry-run --base HEAD~1 2>&1)"

if grep -q '^route' "$ARGS_FILE" \
  && grep -q '\-\-prefer best' "$ARGS_FILE" \
  && grep -q '\-\-effort max' "$ARGS_FILE" \
  && grep -q '\-\-tags code-review' "$ARGS_FILE" \
  && echo "$out" | grep -q 'would pick: claude'; then
  echo "==> PASS: auto-routed --dry-run invoked conductor route with config flags"
else
  echo "FAIL: dry-run did not invoke conductor route as expected" >&2
  echo "args file: $(cat "$ARGS_FILE")" >&2
  echo "out: $out" >&2
  ERRORS=$((ERRORS + 1))
fi

# ----------------------------------------------------------------------------
echo '==> Test: --dry-run with `with =` pinned config skips route preview'
REPO_PIN="$TEST_DIR/repo-pin"
new_repo "$REPO_PIN"
cat > "$REPO_PIN/.codex-review.toml" <<'EOF'
[review]
reviewer = "conductor"
[review.conductor]
with = "claude"
prefer = "best"
effort = "max"
EOF
git -C "$REPO_PIN" add . && git -C "$REPO_PIN" commit -qm cfg

: > "$ARGS_FILE"
out="$(run_review "$REPO_PIN" --dry-run --base HEAD 2>&1)"

if echo "$out" | grep -q 'pinned via --with=claude' && ! grep -q '^route' "$ARGS_FILE"; then
  echo "==> PASS: pinned config explained, no route preview attempted"
else
  echo "FAIL: pinned config should have explained, not called conductor route" >&2
  echo "args: $(cat "$ARGS_FILE")" >&2
  echo "out: $out" >&2
  ERRORS=$((ERRORS + 1))
fi

# ----------------------------------------------------------------------------
echo "==> Test: env override beats config (TOUCHSTONE_CONDUCTOR_PREFER=cheapest)"
: > "$ARGS_FILE"
out="$(
  cd "$REPO_AUTO"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    ARGS_FILE="$ARGS_FILE" \
    TOUCHSTONE_CONDUCTOR_PREFER=cheapest \
    TOUCHSTONE_NO_AUTO_UPDATE=1 \
    bash "$TOUCHSTONE_BIN" review --dry-run --base HEAD~1 2>&1
)"

if grep -q '\-\-prefer cheapest' "$ARGS_FILE"; then
  echo "==> PASS: env override TOUCHSTONE_CONDUCTOR_PREFER took precedence"
else
  echo "FAIL: env override did not reach conductor route flags" >&2
  echo "args: $(cat "$ARGS_FILE")" >&2
  ERRORS=$((ERRORS + 1))
fi

# ----------------------------------------------------------------------------
echo "==> Test: --mode override changes tools/sandbox flags"
: > "$ARGS_FILE"
out="$(run_review "$REPO_AUTO" --dry-run --mode review-only --base HEAD~1 2>&1)"
if grep -q '\-\-tools Read,Grep,Glob,Bash' "$ARGS_FILE" \
  && grep -q '\-\-sandbox read-only' "$ARGS_FILE"; then
  echo "==> PASS: --mode review-only mapped to read-only sandbox + read tools"
else
  echo "FAIL: --mode override did not rewrite tools/sandbox" >&2
  echo "args: $(cat "$ARGS_FILE")" >&2
  ERRORS=$((ERRORS + 1))
fi

# ----------------------------------------------------------------------------
echo "==> Test: missing --dry-run errors with usage hint"
set +e
out="$(run_review "$REPO_AUTO" 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'only --dry-run is supported'; then
  echo '==> PASS: bare `touchstone review` rejects with helpful message'
else
  echo "FAIL: expected non-zero exit + 'only --dry-run is supported' message" >&2
  echo "rc=$rc out=$out" >&2
  ERRORS=$((ERRORS + 1))
fi

# ----------------------------------------------------------------------------
echo "==> Test: missing conductor CLI errors with install hint"
set +e
out="$(
  cd "$REPO_AUTO"
  PATH="/usr/bin:/bin" \
    TOUCHSTONE_NO_AUTO_UPDATE=1 \
    bash "$TOUCHSTONE_BIN" review --dry-run 2>&1
)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'brew install autumngarage/conductor/conductor'; then
  echo "==> PASS: missing conductor CLI gives brew-install hint"
else
  echo "FAIL: expected install hint when conductor CLI absent" >&2
  echo "rc=$rc out=$out" >&2
  ERRORS=$((ERRORS + 1))
fi

# ----------------------------------------------------------------------------
echo "==> Test: TOUCHSTONE_REVIEWER=<legacy> translates to --with pin + deprecation note"
: > "$ARGS_FILE"
set +e
out="$(
  cd "$REPO_AUTO"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    ARGS_FILE="$ARGS_FILE" \
    TOUCHSTONE_REVIEWER=codex \
    TOUCHSTONE_NO_AUTO_UPDATE=1 \
    bash "$TOUCHSTONE_BIN" review --dry-run --base HEAD~1 2>&1
)"
set -e
if echo "$out" | grep -q 'TOUCHSTONE_REVIEWER=codex is deprecated' \
  && echo "$out" | grep -q 'pinned via --with=codex'; then
  echo "==> PASS: TOUCHSTONE_REVIEWER=codex → deprecation note + --with=codex"
else
  echo "FAIL: legacy TOUCHSTONE_REVIEWER value was silently ignored (regression of bug #13)" >&2
  echo "out: $out" >&2
  ERRORS=$((ERRORS + 1))
fi

# TOUCHSTONE_REVIEWER=local must map to ollama, not crash or no-op.
: > "$ARGS_FILE"
out="$(
  cd "$REPO_AUTO"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    ARGS_FILE="$ARGS_FILE" \
    TOUCHSTONE_REVIEWER=local \
    TOUCHSTONE_NO_AUTO_UPDATE=1 \
    bash "$TOUCHSTONE_BIN" review --dry-run --base HEAD~1 2>&1
)"
if echo "$out" | grep -q 'TOUCHSTONE_REVIEWER=local is deprecated' \
  && echo "$out" | grep -q 'pinned via --with=ollama'; then
  echo "==> PASS: TOUCHSTONE_REVIEWER=local → ollama (closest 2.0 analog)"
else
  echo "FAIL: TOUCHSTONE_REVIEWER=local did not translate to --with=ollama" >&2
  echo "out: $out" >&2
  ERRORS=$((ERRORS + 1))
fi

# Unknown value warns but does not pin (must not silently succeed with junk).
: > "$ARGS_FILE"
out="$(
  cd "$REPO_AUTO"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    ARGS_FILE="$ARGS_FILE" \
    TOUCHSTONE_REVIEWER=bogus \
    TOUCHSTONE_NO_AUTO_UPDATE=1 \
    bash "$TOUCHSTONE_BIN" review --dry-run --base HEAD~1 2>&1
)"
if echo "$out" | grep -q 'TOUCHSTONE_REVIEWER=bogus is not a known legacy value' \
  && ! echo "$out" | grep -q 'pinned via --with=bogus'; then
  echo "==> PASS: unknown TOUCHSTONE_REVIEWER value warns and auto-routes"
else
  echo "FAIL: unknown legacy value silently pinned or skipped warning" >&2
  echo "out: $out" >&2
  ERRORS=$((ERRORS + 1))
fi

# ----------------------------------------------------------------------------
if [ "$ERRORS" -gt 0 ]; then
  echo "==> FAIL: $ERRORS assertion(s) failed"
  exit 1
fi
echo "==> PASS: all touchstone review --dry-run assertions passed"
