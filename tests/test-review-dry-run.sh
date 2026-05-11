#!/usr/bin/env bash
#
# Tests for `touchstone review`: live manual review plus `--dry-run`
# provider preview, both without spending real model tokens.

set -euo pipefail

TOUCHSTONE_ROOT="${TOUCHSTONE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TOUCHSTONE_BIN="$TOUCHSTONE_ROOT/bin/touchstone"

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-test-review-dry.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

# Mock conductor that records its argv to a file so the test can assert
# which flags were passed. `route` echoes a synthetic preview; `review`
# emits a clean marker; `doctor` returns a configured marker.
FAKE_BIN="$TEST_DIR/bin"
ARGS_FILE="$TEST_DIR/conductor-argv.log"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/conductor" <<'CXEOF'
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
  review)
    cat >/dev/null
    printf 'Mock clean review\n'
    printf 'CODEX_REVIEW_CLEAN\n'
    ;;
  *) echo "mock conductor: unsupported subcommand $1" >&2; exit 2 ;;
esac
CXEOF
chmod +x "$FAKE_BIN/conductor"

run_review() {
  local repo="$1"
  shift
  (
    cd "$repo"
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
      ARGS_FILE="$ARGS_FILE" \
      CODEX_REVIEW_DISABLE_CACHE="${CODEX_REVIEW_DISABLE_CACHE:-}" \
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
  echo init >"$dir/README.md"
  git -C "$dir" add . && git -C "$dir" commit -qm init
}

commit_new_file_with_diff_lines() {
  local repo="$1"
  local target_lines="$2"
  local path="$3"
  local content_lines=$((target_lines - 6))
  local i=1

  if [ "$content_lines" -lt 1 ]; then
    echo "test setup error: target diff line count must be at least 7" >&2
    exit 1
  fi

  : >"$repo/$path"
  while [ "$i" -le "$content_lines" ]; do
    printf 'line %03d\n' "$i" >>"$repo/$path"
    i=$((i + 1))
  done
  git -C "$repo" add "$path" && git -C "$repo" commit -qm "change $target_lines lines"

  local actual_lines
  actual_lines="$(git -C "$repo" diff HEAD~1..HEAD | wc -l | tr -d ' ')"
  if [ "$actual_lines" != "$target_lines" ]; then
    echo "test setup error: expected $target_lines diff lines, got $actual_lines" >&2
    exit 1
  fi
}

# ----------------------------------------------------------------------------
echo "==> Test: small default route beats global conductor prefer/effort"
REPO_AUTO="$TEST_DIR/repo-auto"
new_repo "$REPO_AUTO"
cat >"$REPO_AUTO/.codex-review.toml" <<'EOF'
[review]
enabled = true
reviewer = "conductor"
[review.conductor]
prefer = "best"
effort = "max"
tags = "code-review"
EOF
git -C "$REPO_AUTO" add . && git -C "$REPO_AUTO" commit -qm cfg
echo c >>"$REPO_AUTO/README.md" && git -C "$REPO_AUTO" add . && git -C "$REPO_AUTO" commit -qm change

: >"$ARGS_FILE"
out="$(run_review "$REPO_AUTO" --dry-run --base HEAD~1 2>&1)"

if grep -q '^route' "$ARGS_FILE" \
  && grep -q '\-\-prefer cheapest' "$ARGS_FILE" \
  && grep -q '\-\-effort minimal' "$ARGS_FILE" \
  && grep -q '\-\-tags code-review' "$ARGS_FILE" \
  && grep -q '\-\-exclude ollama' "$ARGS_FILE" \
  && echo "$out" | grep -q 'routing:     small (.* <= 400 diff lines)' \
  && echo "$out" | grep -q 'would pick: claude'; then
  echo "==> PASS: small default route used cheapest/minimal and excluded ollama"
else
  echo "FAIL: small default route did not invoke conductor route as expected" >&2
  echo "args file: $(cat "$ARGS_FILE")" >&2
  echo "out: $out" >&2
  ERRORS=$((ERRORS + 1))
fi

# ----------------------------------------------------------------------------
echo "==> Test: dry-run review routing strips tool-use tag"
REPO_TAGS="$TEST_DIR/repo-tags"
new_repo "$REPO_TAGS"
cat >"$REPO_TAGS/.codex-review.toml" <<'EOF'
[review.conductor]
tags = "code-review,tool-use,long-context"
EOF
git -C "$REPO_TAGS" add . && git -C "$REPO_TAGS" commit -qm cfg
echo c >>"$REPO_TAGS/README.md" && git -C "$REPO_TAGS" add . && git -C "$REPO_TAGS" commit -qm change

: >"$ARGS_FILE"
out="$(run_review "$REPO_TAGS" --dry-run --base HEAD~1 2>&1)"

if grep -q '\-\-tags code-review,long-context' "$ARGS_FILE" \
  && ! grep -q 'tool-use' "$ARGS_FILE" \
  && echo "$out" | grep -q 'would pick: claude'; then
  echo "==> PASS: dry-run review routing strips tool-use tag"
else
  echo "FAIL: dry-run review routing should strip tool-use from tags" >&2
  echo "args file: $(cat "$ARGS_FILE")" >&2
  echo "out: $out" >&2
  ERRORS=$((ERRORS + 1))
fi

# ----------------------------------------------------------------------------
echo "==> Test: exact threshold stays in the small routing bucket"
REPO_THRESHOLD="$TEST_DIR/repo-threshold"
new_repo "$REPO_THRESHOLD"
commit_new_file_with_diff_lines "$REPO_THRESHOLD" 400 threshold.txt

: >"$ARGS_FILE"
out="$(run_review "$REPO_THRESHOLD" --dry-run --base HEAD~1 2>&1)"

if grep -q '\-\-prefer cheapest' "$ARGS_FILE" \
  && grep -q '\-\-effort minimal' "$ARGS_FILE" \
  && echo "$out" | grep -q 'routing:     small (400 <= 400 diff lines)'; then
  echo "==> PASS: 400-line diff used small cheapest/minimal bucket"
else
  echo "FAIL: exact threshold diff should use small routing bucket" >&2
  echo "args: $(cat "$ARGS_FILE")" >&2
  echo "out: $out" >&2
  ERRORS=$((ERRORS + 1))
fi

# ----------------------------------------------------------------------------
echo "==> Test: low-risk large default route uses best/medium"
REPO_LARGE="$TEST_DIR/repo-large"
new_repo "$REPO_LARGE"
commit_new_file_with_diff_lines "$REPO_LARGE" 401 large.txt

: >"$ARGS_FILE"
out="$(run_review "$REPO_LARGE" --dry-run --base HEAD~1 2>&1)"

if grep -q '\-\-prefer best' "$ARGS_FILE" \
  && grep -q '\-\-effort medium' "$ARGS_FILE" \
  && echo "$out" | grep -q 'routing:     large-low-risk (401 > 400 diff lines; no high-risk paths)'; then
  echo "==> PASS: 401-line low-risk diff used large best/medium bucket"
else
  echo "FAIL: low-risk large diff should use bounded large routing bucket" >&2
  echo "args: $(cat "$ARGS_FILE")" >&2
  echo "out: $out" >&2
  ERRORS=$((ERRORS + 1))
fi

# ----------------------------------------------------------------------------
echo "==> Test: high-risk large default route keeps best/high"
REPO_HIGH_RISK="$TEST_DIR/repo-high-risk-large"
new_repo "$REPO_HIGH_RISK"
cat >"$REPO_HIGH_RISK/.codex-review.toml" <<'EOF'
[codex_review]
unsafe_paths = ["critical/"]
EOF
git -C "$REPO_HIGH_RISK" add .codex-review.toml
git -C "$REPO_HIGH_RISK" commit -qm cfg
mkdir -p "$REPO_HIGH_RISK/critical"
commit_new_file_with_diff_lines "$REPO_HIGH_RISK" 401 critical/large.txt

: >"$ARGS_FILE"
out="$(run_review "$REPO_HIGH_RISK" --dry-run --base HEAD~1 2>&1)"

if grep -q '\-\-prefer best' "$ARGS_FILE" \
  && grep -q '\-\-effort high' "$ARGS_FILE" \
  && echo "$out" | grep -q 'routing:     high-risk (high-risk path critical/large.txt'; then
  echo "==> PASS: 401-line high-risk diff kept best/high bucket"
else
  echo "FAIL: high-risk large diff should use high-risk routing bucket" >&2
  echo "args: $(cat "$ARGS_FILE")" >&2
  echo "out: $out" >&2
  ERRORS=$((ERRORS + 1))
fi

# ----------------------------------------------------------------------------
echo "==> Test: built-in bootstrap path keeps best/high"
REPO_BOOTSTRAP="$TEST_DIR/repo-bootstrap-risk"
new_repo "$REPO_BOOTSTRAP"
mkdir -p "$REPO_BOOTSTRAP/bootstrap"
commit_new_file_with_diff_lines "$REPO_BOOTSTRAP" 401 bootstrap/new-project.sh

: >"$ARGS_FILE"
out="$(run_review "$REPO_BOOTSTRAP" --dry-run --base HEAD~1 2>&1)"

if grep -q '\-\-prefer best' "$ARGS_FILE" \
  && grep -q '\-\-effort high' "$ARGS_FILE" \
  && echo "$out" | grep -q 'routing:     high-risk (architectural path bootstrap/new-project.sh'; then
  echo "==> PASS: built-in bootstrap path kept best/high bucket"
else
  echo "FAIL: built-in bootstrap path should use high-risk routing bucket" >&2
  echo "args: $(cat "$ARGS_FILE")" >&2
  echo "out: $out" >&2
  ERRORS=$((ERRORS + 1))
fi

# ----------------------------------------------------------------------------
echo "==> Test: configured full-context path keeps best/high"
REPO_FULL_CONTEXT="$TEST_DIR/repo-full-context-risk"
new_repo "$REPO_FULL_CONTEXT"
cat >"$REPO_FULL_CONTEXT/.codex-review.toml" <<'EOF'
[review.context]
full_context_paths = ["docs/"]
EOF
git -C "$REPO_FULL_CONTEXT" add .codex-review.toml
git -C "$REPO_FULL_CONTEXT" commit -qm cfg
mkdir -p "$REPO_FULL_CONTEXT/docs"
printf 'doc change\n' >"$REPO_FULL_CONTEXT/docs/note.md"
git -C "$REPO_FULL_CONTEXT" add docs/note.md
git -C "$REPO_FULL_CONTEXT" commit -qm "touch docs"

: >"$ARGS_FILE"
out="$(run_review "$REPO_FULL_CONTEXT" --dry-run --base HEAD~1 2>&1)"

if grep -q '\-\-prefer best' "$ARGS_FILE" \
  && grep -q '\-\-effort high' "$ARGS_FILE" \
  && echo "$out" | grep -q 'routing:     high-risk (configured full-context path docs/note.md'; then
  echo "==> PASS: configured full-context path kept best/high bucket"
else
  echo "FAIL: configured full-context path should use high-risk routing bucket" >&2
  echo "args: $(cat "$ARGS_FILE")" >&2
  echo "out: $out" >&2
  ERRORS=$((ERRORS + 1))
fi

# ----------------------------------------------------------------------------
echo "==> Test: explicit routing opt-out preserves global conductor config"
REPO_DISABLED="$TEST_DIR/repo-routing-disabled"
new_repo "$REPO_DISABLED"
cat >"$REPO_DISABLED/.codex-review.toml" <<'EOF'
[review.conductor]
prefer = "balanced"
effort = "low"
[review.routing]
enabled = false
EOF
git -C "$REPO_DISABLED" add . && git -C "$REPO_DISABLED" commit -qm cfg
echo c >>"$REPO_DISABLED/README.md" && git -C "$REPO_DISABLED" add . && git -C "$REPO_DISABLED" commit -qm change

: >"$ARGS_FILE"
out="$(run_review "$REPO_DISABLED" --dry-run --base HEAD~1 2>&1)"

if grep -q '\-\-prefer balanced' "$ARGS_FILE" \
  && grep -q '\-\-effort low' "$ARGS_FILE" \
  && echo "$out" | grep -q 'routing:     default (review.routing.enabled=false)'; then
  echo "==> PASS: review.routing.enabled=false kept global conductor config"
else
  echo "FAIL: explicit routing opt-out should preserve global conductor config" >&2
  echo "args: $(cat "$ARGS_FILE")" >&2
  echo "out: $out" >&2
  ERRORS=$((ERRORS + 1))
fi

# ----------------------------------------------------------------------------
echo "==> Test: conductor exclude config reaches route preview"
REPO_EXCLUDE="$TEST_DIR/repo-exclude"
new_repo "$REPO_EXCLUDE"
cat >"$REPO_EXCLUDE/.codex-review.toml" <<'EOF'
[review.conductor]
exclude = ["ollama"]
EOF
git -C "$REPO_EXCLUDE" add . && git -C "$REPO_EXCLUDE" commit -qm cfg
echo c >>"$REPO_EXCLUDE/README.md" && git -C "$REPO_EXCLUDE" add . && git -C "$REPO_EXCLUDE" commit -qm change

: >"$ARGS_FILE"
out="$(run_review "$REPO_EXCLUDE" --dry-run --base HEAD~1 2>&1)"

if grep -q '\-\-exclude ollama' "$ARGS_FILE" \
  && echo "$out" | grep -q 'would pick: claude'; then
  echo "==> PASS: [review.conductor].exclude reached conductor route"
else
  echo "FAIL: conductor exclude config should pass --exclude to route preview" >&2
  echo "args: $(cat "$ARGS_FILE")" >&2
  echo "out: $out" >&2
  ERRORS=$((ERRORS + 1))
fi

# ----------------------------------------------------------------------------
echo "==> Test: explicit empty conductor exclude re-enables local providers"
REPO_EXCLUDE_EMPTY="$TEST_DIR/repo-exclude-empty"
new_repo "$REPO_EXCLUDE_EMPTY"
cat >"$REPO_EXCLUDE_EMPTY/.codex-review.toml" <<'EOF'
[review.conductor]
exclude = []
EOF
git -C "$REPO_EXCLUDE_EMPTY" add . && git -C "$REPO_EXCLUDE_EMPTY" commit -qm cfg
echo c >>"$REPO_EXCLUDE_EMPTY/README.md" && git -C "$REPO_EXCLUDE_EMPTY" add . && git -C "$REPO_EXCLUDE_EMPTY" commit -qm change

: >"$ARGS_FILE"
out="$(run_review "$REPO_EXCLUDE_EMPTY" --dry-run --base HEAD~1 2>&1)"

if ! grep -q '\-\-exclude' "$ARGS_FILE" \
  && echo "$out" | grep -q 'would pick: claude'; then
  echo "==> PASS: exclude=[] suppressed the default ollama exclusion"
else
  echo "FAIL: explicit empty exclude should avoid passing --exclude" >&2
  echo "args: $(cat "$ARGS_FILE")" >&2
  echo "out: $out" >&2
  ERRORS=$((ERRORS + 1))
fi

# ----------------------------------------------------------------------------
echo '==> Test: --dry-run with `with =` pinned config skips route preview'
REPO_PIN="$TEST_DIR/repo-pin"
new_repo "$REPO_PIN"
cat >"$REPO_PIN/.codex-review.toml" <<'EOF'
[review]
reviewer = "conductor"
[review.conductor]
with = "claude"
prefer = "best"
effort = "max"
EOF
git -C "$REPO_PIN" add . && git -C "$REPO_PIN" commit -qm cfg

: >"$ARGS_FILE"
out="$(run_review "$REPO_PIN" --dry-run --base HEAD 2>&1)"

if echo "$out" | grep -q 'pinned via --with=claude' \
  && echo "$out" | grep -q 'routing  = small (0 <= 400 diff lines)' \
  && ! grep -q '^route' "$ARGS_FILE"; then
  echo "==> PASS: pinned config explained, no route preview attempted"
else
  echo "FAIL: pinned config should have explained, not called conductor route" >&2
  echo "args: $(cat "$ARGS_FILE")" >&2
  echo "out: $out" >&2
  ERRORS=$((ERRORS + 1))
fi

# ----------------------------------------------------------------------------
echo "==> Test: env override beats size bucket defaults"
: >"$ARGS_FILE"
out="$(
  cd "$REPO_AUTO"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    ARGS_FILE="$ARGS_FILE" \
    TOUCHSTONE_CONDUCTOR_PREFER=fastest \
    TOUCHSTONE_CONDUCTOR_EFFORT=high \
    TOUCHSTONE_NO_AUTO_UPDATE=1 \
    bash "$TOUCHSTONE_BIN" review --dry-run --base HEAD~1 2>&1
)"

if grep -q '\-\-prefer fastest' "$ARGS_FILE" \
  && grep -q '\-\-effort high' "$ARGS_FILE"; then
  echo "==> PASS: TOUCHSTONE_CONDUCTOR_* env overrides took precedence"
else
  echo "FAIL: env overrides did not reach conductor route flags" >&2
  echo "args: $(cat "$ARGS_FILE")" >&2
  ERRORS=$((ERRORS + 1))
fi

# ----------------------------------------------------------------------------
echo "==> Test: --mode override changes tools without sandbox flags"
check_dry_run_mode() {
  local mode="$1"
  local expected_tools="$2"
  : >"$ARGS_FILE"
  out="$(run_review "$REPO_AUTO" --dry-run --mode "$mode" --base HEAD~1 2>&1)"

  if [ -n "$expected_tools" ]; then
    if ! grep -q -- "--tools $expected_tools" "$ARGS_FILE"; then
      echo "FAIL: expected --mode $mode to pass --tools $expected_tools" >&2
      echo "args: $(cat "$ARGS_FILE")" >&2
      ERRORS=$((ERRORS + 1))
      return
    fi
  elif grep -q -- '--tools' "$ARGS_FILE"; then
    echo "FAIL: expected --mode $mode to omit --tools" >&2
    echo "args: $(cat "$ARGS_FILE")" >&2
    ERRORS=$((ERRORS + 1))
    return
  fi

  if grep -q -- '--sandbox' "$ARGS_FILE" || echo "$out" | grep -q 'sandbox'; then
    echo "FAIL: expected --mode $mode dry-run to omit sandbox contract" >&2
    echo "args: $(cat "$ARGS_FILE")" >&2
    echo "out: $out" >&2
    ERRORS=$((ERRORS + 1))
    return
  fi
}

check_dry_run_mode "diff-only" ""
check_dry_run_mode "review-only" ""
check_dry_run_mode "no-tests" "Read,Grep,Glob,Edit,Write"
check_dry_run_mode "fix" "Read,Grep,Glob,Bash,Edit,Write"

if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: --mode overrides map to tools and omit sandbox"
fi

# ----------------------------------------------------------------------------
echo "==> Test: bare touchstone review runs the same review path"
: >"$ARGS_FILE"
set +e
out="$(run_review "$REPO_AUTO" --base HEAD~1 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ] \
  && grep -q '^review ' "$ARGS_FILE" \
  && grep -q -- '--base HEAD~1' "$ARGS_FILE" \
  && echo "$out" | grep -q 'exit reason:    clean'; then
  echo '==> PASS: bare `touchstone review` ran the live review path'
else
  echo "FAIL: expected bare touchstone review to invoke conductor review and exit clean" >&2
  echo "args=$(cat "$ARGS_FILE")" >&2
  echo "rc=$rc out=$out" >&2
  ERRORS=$((ERRORS + 1))
fi

# ----------------------------------------------------------------------------
echo "==> Test: live review --json emits summary JSON on stdout"
: >"$ARGS_FILE"
JSON_OUT="$TEST_DIR/live-review.json"
JSON_ERR="$TEST_DIR/live-review.err"
set +e
CODEX_REVIEW_DISABLE_CACHE=1 run_review "$REPO_AUTO" --base HEAD~1 --json >"$JSON_OUT" 2>"$JSON_ERR"
rc=$?
set -e
if [ "$rc" -eq 0 ] \
  && grep -q '^review ' "$ARGS_FILE" \
  && grep -q '"exit_reason":"clean"' "$JSON_OUT" \
  && ! grep -q 'CODEX_REVIEW_CLEAN' "$JSON_OUT" \
  && grep -q 'exit reason:    clean' "$JSON_ERR"; then
  echo "==> PASS: live review --json preserved machine-readable stdout"
else
  echo "FAIL: live review --json should emit summary JSON to stdout and logs to stderr" >&2
  echo "args=$(cat "$ARGS_FILE")" >&2
  echo "rc=$rc json=$(cat "$JSON_OUT" 2>/dev/null || true)" >&2
  echo "err=$(cat "$JSON_ERR" 2>/dev/null || true)" >&2
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
: >"$ARGS_FILE"
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

# TOUCHSTONE_REVIEWER=openrouter is a supported provider pin for the hosted path.
: >"$ARGS_FILE"
out="$(
  cd "$REPO_AUTO"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    ARGS_FILE="$ARGS_FILE" \
    TOUCHSTONE_REVIEWER=openrouter \
    TOUCHSTONE_NO_AUTO_UPDATE=1 \
    bash "$TOUCHSTONE_BIN" review --dry-run --base HEAD~1 2>&1
)"
if echo "$out" | grep -q 'TOUCHSTONE_REVIEWER=openrouter is deprecated' \
  && echo "$out" | grep -q 'pinned via --with=openrouter'; then
  echo "==> PASS: TOUCHSTONE_REVIEWER=openrouter → deprecation note + --with=openrouter"
else
  echo "FAIL: TOUCHSTONE_REVIEWER=openrouter did not translate to --with=openrouter" >&2
  echo "out: $out" >&2
  ERRORS=$((ERRORS + 1))
fi

# TOUCHSTONE_REVIEWER=local is an explicit offline/local compatibility path and
# must map to ollama, not crash or no-op.
: >"$ARGS_FILE"
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
  echo "==> PASS: TOUCHSTONE_REVIEWER=local → ollama (offline compatibility)"
else
  echo "FAIL: TOUCHSTONE_REVIEWER=local did not translate to --with=ollama" >&2
  echo "out: $out" >&2
  ERRORS=$((ERRORS + 1))
fi

# Unknown value warns but does not pin (must not silently succeed with junk).
: >"$ARGS_FILE"
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
echo "==> PASS: all touchstone review assertions passed"
