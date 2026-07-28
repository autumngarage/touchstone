#!/usr/bin/env bash
#
# tests/test-open-pr-cleanup-worktree.sh — guard the --cleanup-worktree flag.
#
# Cases covered:
#   1. --cleanup-worktree without --auto-merge → exits non-zero with a clear
#      error (the cleanup runs only post-merge; the combo is meaningless).
#   2. --cleanup-worktree with --auto-merge from a feature worktree → after
#      successful merge, the feature worktree is removed by `git worktree
#      remove`.
#   3. The same cleanup also runs when --auto-merge attaches to an already
#      open PR for the current branch.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-open-pr-cleanup.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0

REPO_DIR="$TEST_DIR/repo"
SCRIPT_DIR="$TEST_DIR/scripts"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$SCRIPT_DIR" "$FAKE_BIN"

cp "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$SCRIPT_DIR/open-pr.sh"
cp "$TOUCHSTONE_ROOT/scripts/issue-claim-check.sh" "$SCRIPT_DIR/issue-claim-check.sh"
# merge-pr.sh is invoked by open-pr.sh on --auto-merge; stub it.
cat >"$SCRIPT_DIR/merge-pr.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SCRIPT_DIR/open-pr.sh" "$SCRIPT_DIR/issue-claim-check.sh" "$SCRIPT_DIR/merge-pr.sh"

# Mock gh: returns a stable PR URL on create, claims the PR is merged.
cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "repo view")
    case "$*" in
      *"nameWithOwner"*) echo "autumngarage/touchstone" ;;
      *"--json url"*) echo "https://github.com/autumngarage/touchstone" ;;
      *) echo "main" ;;
    esac
    ;;
  "api repos/autumngarage/touchstone/pulls/9999")
    case "$*" in
      *".body // \"\""*) echo "" ;;
      *".user.login // empty"*) echo "alice" ;;
      *) echo "unexpected gh api args: $*" >&2; exit 1 ;;
    esac
    ;;
  "pr list")
    if [ "${GH_HAS_EXISTING_PR:-0}" = "1" ]; then
      printf 'https://example.test/touchstone/pull/9999\tmain\n'
    else
      echo ""
    fi
    ;;
  "pr create") echo "https://example.test/touchstone/pull/9999" ;;
  "pr view")
    json_fields=""
    jq_expr=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--json" ]; then
        json_fields="$arg"
      elif [ "$prev" = "--jq" ]; then
        jq_expr="$arg"
      fi
      prev="$arg"
    done
    case "$json_fields" in
      body) echo "" ;;
      body,author)
        case "${jq_expr:-}" in
          ".body // \"\"") echo "" ;;
          ".author.login // empty") echo "alice" ;;
          *) echo "unexpected gh pr view jq: ${jq_expr:-}" >&2; exit 1 ;;
        esac
        ;;
      state,mergedAt) printf '{"state":"MERGED","mergedAt":"2026-04-30T05:00:00Z"}\n' ;;
      mergedAt) echo "2026-04-30T05:00:00Z" ;;
      *) echo "unexpected gh pr view json: $json_fields" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$FAKE_BIN/gh"

# Real git: bare remote + main worktree + feature worktree, so
# `git worktree list --porcelain` reflects an actual sibling.
REMOTE_DIR="$TEST_DIR/remote.git"
git init --bare "$REMOTE_DIR" >/dev/null 2>&1
git clone "$REMOTE_DIR" "$REPO_DIR" >/dev/null 2>&1
git -C "$REPO_DIR" switch -c main >/dev/null 2>&1
git -C "$REPO_DIR" config user.name "Touchstone Test"
git -C "$REPO_DIR" config user.email "touchstone@example.com"
mkdir -p "$REPO_DIR/.github"
printf '## Summary\n' >"$REPO_DIR/.github/pull_request_template.md"
printf 'base\n' >"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add .github/pull_request_template.md file.txt
git -C "$REPO_DIR" commit -m "base" >/dev/null 2>&1
git -C "$REPO_DIR" push -u origin main >/dev/null 2>&1

FEATURE_DIR="$TEST_DIR/repo-feature"
git -C "$REPO_DIR" worktree add "$FEATURE_DIR" -b feat/cleanup-test >/dev/null 2>&1
printf 'change\n' >>"$FEATURE_DIR/file.txt"
git -C "$FEATURE_DIR" add file.txt
git -C "$FEATURE_DIR" commit -m "test change" >/dev/null 2>&1

# Case 1 — flag combo validation
echo "==> Case 1: --cleanup-worktree without --auto-merge is rejected"
RC=0
OUT="$TEST_DIR/case1.out"
(
  cd "$FEATURE_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$SCRIPT_DIR/open-pr.sh" --cleanup-worktree
) >"$OUT" 2>&1 || RC=$?

if [ "$RC" != "0" ] && grep -q -- '--cleanup-worktree requires --auto-merge' "$OUT"; then
  echo "    PASS"
else
  echo "    FAIL: expected non-zero exit + clear error message" >&2
  echo "    rc=$RC" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 2 — happy path: feature worktree gets removed after merge
echo "==> Case 2: --cleanup-worktree --auto-merge removes the feature worktree"
RC=0
OUT="$TEST_DIR/case2.out"
(
  cd "$FEATURE_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$SCRIPT_DIR/open-pr.sh" --auto-merge --cleanup-worktree
) >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q '==> Worktree removed.' "$OUT" \
  && [ ! -d "$FEATURE_DIR" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected exit 0, 'Worktree removed.' in output, and \$FEATURE_DIR gone" >&2
  echo "    rc=$RC" >&2
  echo "    feature dir exists? $([ -d "$FEATURE_DIR" ] && echo yes || echo no)" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

# Case 3 — existing PR path: cleanup still runs after verified merge
echo "==> Case 3: existing PR --auto-merge --cleanup-worktree removes the feature worktree"
EXISTING_FEATURE_DIR="$TEST_DIR/repo-feature-existing"
git -C "$REPO_DIR" worktree add "$EXISTING_FEATURE_DIR" -b feat/cleanup-existing >/dev/null 2>&1
printf 'existing\n' >>"$EXISTING_FEATURE_DIR/file.txt"
git -C "$EXISTING_FEATURE_DIR" add file.txt
git -C "$EXISTING_FEATURE_DIR" commit -m "test existing change" >/dev/null 2>&1

RC=0
OUT="$TEST_DIR/case3.out"
(
  cd "$EXISTING_FEATURE_DIR"
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_HAS_EXISTING_PR=1 \
    bash "$SCRIPT_DIR/open-pr.sh" --auto-merge --cleanup-worktree
) >"$OUT" 2>&1 || RC=$?

if [ "$RC" = "0" ] \
  && grep -q '==> PR already open for feat/cleanup-existing' "$OUT" \
  && grep -q '==> Worktree removed.' "$OUT" \
  && [ ! -d "$EXISTING_FEATURE_DIR" ]; then
  echo "    PASS"
else
  echo "    FAIL: expected existing-PR auto-merge cleanup to remove the worktree" >&2
  echo "    rc=$RC" >&2
  echo "    existing feature dir exists? $([ -d "$EXISTING_FEATURE_DIR" ] && echo yes || echo no)" >&2
  cat "$OUT" >&2
  ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" = "0" ]; then
  echo "==> PASS: open-pr.sh --cleanup-worktree behaves correctly"
  exit 0
fi
echo "==> FAIL: $ERRORS case(s) regressed" >&2
exit 1
