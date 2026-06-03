#!/usr/bin/env bash
#
# tests/test-review-gate-tools.sh — regression guard for merge-gate tool scoping.
# Under the merge gate (CODEX_REVIEW_PR_NUMBER set) the diff under review is
# attacker-controlled and is a prompt-injection vector into the tool-enabled
# review/fix loop. The Bash tool must be dropped there by default so injected
# instructions cannot run arbitrary commands; an explicit opt-in restores it.
# Local pre-push review keeps Bash.
#
# We extract conductor_tools_for_mode() (and its truthiness helpers) from the
# real hook and exercise it directly — no model/provider quota spent.
#
# REVIEW_MODE is consumed by the eval'd conductor_tools_for_mode; shellcheck
# cannot see through eval, so it reports it unused (file-scoped directive).
# shellcheck disable=SC2034
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$TOUCHSTONE_ROOT/hooks/codex-review.sh"

ERRORS=0
fail() {
  echo "FAIL: $1" >&2
  ERRORS=$((ERRORS + 1))
}

extract_fn() {
  awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{f=1} f{print} f&&/^}/{exit}' "$SRC"
}

# Faithful reconstruction of the truthiness chain the function depends on.
eval "$(extract_fn trim)"
eval "$(extract_fn normalize_bool)"
eval "$(extract_fn is_truthy)"
eval "$(extract_fn conductor_tools_for_mode)"

tools_for() {
  # $1 = phase, env: REVIEW_MODE, CODEX_REVIEW_PR_NUMBER, TOUCHSTONE_REVIEW_ALLOW_GATE_BASH
  conductor_tools_for_mode "$1"
}

has_bash() { case ",$1," in *,Bash,*) return 0 ;; *) return 1 ;; esac }

# === Merge gate, default: Bash dropped from fix and review ===
REVIEW_MODE="fix"
out="$(CODEX_REVIEW_PR_NUMBER=9 tools_for fix)"
if has_bash "$out"; then fail "gate fix must NOT include Bash by default (got: $out)"; fi
case ",$out," in *,Edit,*) : ;; *) fail "gate fix must still include Edit (got: $out)" ;; esac
case ",$out," in *,Write,*) : ;; *) fail "gate fix must still include Write (got: $out)" ;; esac

out="$(CODEX_REVIEW_PR_NUMBER=9 tools_for review)"
if has_bash "$out"; then fail "gate review must NOT include Bash by default (got: $out)"; fi

# === Merge gate, explicit opt-in: Bash restored ===
out="$(CODEX_REVIEW_PR_NUMBER=9 TOUCHSTONE_REVIEW_ALLOW_GATE_BASH=1 tools_for fix)"
has_bash "$out" || fail "gate fix with opt-in must include Bash (got: $out)"

# === Local pre-push (no PR number): Bash retained (unchanged behavior) ===
out="$(tools_for fix)"
has_bash "$out" || fail "local fix must include Bash (got: $out)"
out="$(tools_for review)"
has_bash "$out" || fail "local review must include Bash (got: $out)"

# === diff-only mode stays empty regardless of gate ===
REVIEW_MODE="diff-only"
out="$(CODEX_REVIEW_PR_NUMBER=9 tools_for review)"
[ -z "$out" ] || fail "diff-only review must grant no tools (got: $out)"

if [ "$ERRORS" -eq 0 ]; then
  echo "==> PASS: merge gate drops Bash by default; opt-in and local review unaffected"
else
  echo "==> FAILED with $ERRORS error(s)" >&2
  exit 1
fi
