#!/usr/bin/env bash
#
# tests/test-open-pr-title-selection.sh — guard default PR title selection.
#
# Issue #421: when the trailing commit is generated conductor-refresh output
# (AGENTS.md / GEMINI.md / .cursor/rules/conductor-delegation.mdc), open-pr.sh
# should not use that trailing generated commit title as the default PR title.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-open-pr-title.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

SCRIPT_DIR="$TEST_DIR/scripts"
FAKE_BIN="$TEST_DIR/bin"
REMOTE_DIR="$TEST_DIR/remote.git"
REPO_DIR="$TEST_DIR/repo"
mkdir -p "$SCRIPT_DIR" "$FAKE_BIN"

cp "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$SCRIPT_DIR/open-pr.sh"
cp "$TOUCHSTONE_ROOT/scripts/issue-claim-check.sh" "$SCRIPT_DIR/issue-claim-check.sh"
chmod +x "$SCRIPT_DIR/open-pr.sh" "$SCRIPT_DIR/issue-claim-check.sh"

cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "repo view")
    json_fields=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--json" ]; then
        json_fields="$arg"
      fi
      prev="$arg"
    done
    case "$json_fields" in
      nameWithOwner) echo "autumngarage/touchstone" ;;
      *) echo "main" ;;
    esac
    ;;
  "pr list") echo "" ;;
  "pr create")
    prev=""
    title=""
    for arg in "$@"; do
      if [ "$prev" = "--title" ]; then
        title="$arg"
      fi
      prev="$arg"
    done
    printf '%s\n' "$title" >>"${GH_TITLE_LOG:?missing GH_TITLE_LOG}"
    echo "https://example.test/touchstone/pull/7777"
    ;;
  "pr view") echo "" ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/gh"

git init --bare "$REMOTE_DIR" >/dev/null 2>&1
git clone "$REMOTE_DIR" "$REPO_DIR" >/dev/null 2>&1
git -C "$REPO_DIR" switch -c main >/dev/null 2>&1
git -C "$REPO_DIR" config user.name "Touchstone Test"
git -C "$REPO_DIR" config user.email "touchstone@example.com"
printf 'base\n' >"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -m "base" >/dev/null 2>&1
git -C "$REPO_DIR" push -u origin main >/dev/null 2>&1

echo "==> Case 1: trailing conductor-refresh commit is ignored for default PR title"
git -C "$REPO_DIR" switch -c feat/title-selection >/dev/null 2>&1
printf 'feature\n' >>"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -m "fix: functional change" >/dev/null 2>&1

mkdir -p "$REPO_DIR/.cursor/rules"
printf 'generated\n' >"$REPO_DIR/AGENTS.md"
printf 'generated\n' >"$REPO_DIR/GEMINI.md"
printf 'generated\n' >"$REPO_DIR/.cursor/rules/conductor-delegation.mdc"
git -C "$REPO_DIR" add AGENTS.md GEMINI.md .cursor/rules/conductor-delegation.mdc
git -C "$REPO_DIR" commit -m "chore: refresh conductor integrations" >/dev/null 2>&1

OUT="$TEST_DIR/case1.out"
TITLE_LOG="$TEST_DIR/titles.log"
: >"$TITLE_LOG"
RC=0
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_TITLE_LOG="$TITLE_LOG" \
    bash "$SCRIPT_DIR/open-pr.sh"
) >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q '^https://example.test/touchstone/pull/7777$' "$OUT" \
  && [ "$(tail -n 1 "$TITLE_LOG")" = "fix: functional change" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected default title to use functional commit subject" >&2
  echo "    rc=$RC" >&2
  echo "    captured title: $(tail -n 1 "$TITLE_LOG" 2>/dev/null || true)" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

echo "==> Case 2: generated-only branch falls back to trailing commit title"
git -C "$REPO_DIR" switch main >/dev/null 2>&1
git -C "$REPO_DIR" switch -c feat/title-generated-only >/dev/null 2>&1
mkdir -p "$REPO_DIR/.cursor/rules"
printf 'generated only\n' >"$REPO_DIR/AGENTS.md"
printf 'generated only\n' >"$REPO_DIR/GEMINI.md"
printf 'generated only\n' >"$REPO_DIR/.cursor/rules/conductor-delegation.mdc"
git -C "$REPO_DIR" add AGENTS.md GEMINI.md .cursor/rules/conductor-delegation.mdc
git -C "$REPO_DIR" commit -m "chore: refresh conductor integrations" >/dev/null 2>&1

OUT="$TEST_DIR/case2.out"
RC=0
(
  cd "$REPO_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_TITLE_LOG="$TITLE_LOG" \
    bash "$SCRIPT_DIR/open-pr.sh"
) >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q '^https://example.test/touchstone/pull/7777$' "$OUT" \
  && [ "$(tail -n 1 "$TITLE_LOG")" = "chore: refresh conductor integrations" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected generated-only branch to keep trailing title" >&2
  echo "    rc=$RC" >&2
  echo "    captured title: $(tail -n 1 "$TITLE_LOG" 2>/dev/null || true)" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" = "0" ]; then
  echo "==> PASS: open-pr.sh default title selection skips trailing conductor-refresh commits"
  exit 0
fi

echo "==> FAIL: $ERRORS case(s) regressed" >&2
exit 1
