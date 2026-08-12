#!/usr/bin/env bash
#
# tests/test-validate-workflow.sh — static guardrails for the required
# validate workflow (.github/workflows/validate.yml, issue #742).
#
# WHAT THIS FILE IS, PLAINLY: static structural assertions over the workflow
# TEXT — greps plus awk passes over the YAML. Nothing here runs the workflow,
# starts a runner, or proves the fast tier passes; that is what the workflow's
# own live runs are for. What this file proves is the workflow's DEPENDENCY
# SURFACE, which no live run can prove: a run is green precisely when its
# third-party fetches happened to succeed, so "it worked yesterday" is not
# evidence about what it depends on.
#
# The property under guard is availability of the merge gate. `validate
# (ubuntu-latest)` is a required status check on main, so every service the
# job contacts at job time is a service that can block every merge in the
# repository. Twice in one day (#742) it did: chocolatey's community feed
# returned 503 on the Windows leg and a GitHub release download returned 503
# on the required Linux leg, both while fetching a lint toolchain that no test
# in this repository ever invokes. No test ran either time; the checks went red
# anyway, and read at a glance looked like code failures.
#
# So:
#   - the required job installs NOTHING it does not execute (a), which is
#     enforced as "no package manager or downloader appears in that job's
#     steps at all" — the only bound that does not require re-deriving which
#     binary each test needs on every edit;
#   - what it does still provision is version-pinned (b), so a fetch resolves
#     to a fixed artifact rather than to whatever the index serves today;
#   - the one remaining job-time fetch is labelled INFRASTRUCTURE (c) so a
#     reader can tell "a package host had a bad minute" from "the code is
#     broken" without opening the log. Labelling is ALL that changes: the step
#     still exits 1 and the check still blocks. A check that cannot prove the
#     tests passed must never report success;
#   - the required context keeps its literal name (d) — branch protection
#     matches `validate (ubuntu-latest)` as a string, and an advisory matrix
#     entry renames the check, which silently un-requires it;
#   - the advisory exit-0 tolerance stays unreachable from the required leg
#     (e) — that tolerance turns a red suite green, and one moved line would
#     apply it to the leg branch protection actually reads.
#
# All grep assertions scan the workflow with comment lines stripped: the
# header prose explains the hazards and therefore necessarily names them.
# Scanning comments too would force the file to stop documenting its own
# threat model.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$TOUCHSTONE_ROOT/.github/workflows/validate.yml"

# The job whose check name branch protection requires. Assertions about the
# dependency surface are scoped HERE, not to the file: a helper job that is
# not on the merge boundary may fetch whatever it likes.
REQUIRED_JOB="validate"
REQUIRED_CONTEXT="validate (ubuntu-latest)"

ERRORS=0
fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}
ok() {
  printf '  OK: %s\n' "$*"
}

if [ ! -f "$WORKFLOW" ]; then
  echo "FAIL: workflow not found: $WORKFLOW" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d -t touchstone-test-validate-workflow.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Extract one top-level job block (2-space key) from the jobs: mapping.
extract_job() {
  awk -v want="$1" '
    /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
    /^[^[:space:]]/ { in_jobs = 0; grab = 0 }
    in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      key = $1
      sub(/:$/, "", key)
      grab = (key == want)
      next
    }
    grab { print }
  ' "$WORKFLOW"
}

# Extract one step block by its `- name:` line, up to the next step at the
# same indentation (or the end of the job).
extract_step() {
  awk -v want="$1" '
    /^      - name: / {
      line = $0
      sub(/^      - name: /, "", line)
      grab = (index(line, want) > 0)
      if (grab) next
    }
    grab { print }
  ' "$WORKFLOW"
}

strip_comments() {
  grep -v -E '^[[:space:]]*#' || true
}

JOB_BODY="$TMP_DIR/required-job.txt"
extract_job "$REQUIRED_JOB" | strip_comments >"$JOB_BODY"
# A vacuous pass is a fail: if the job key is ever renamed, every assertion
# below would silently scan an empty file and report OK.
if [ ! -s "$JOB_BODY" ]; then
  echo "FAIL: could not extract the '$REQUIRED_JOB' job from $WORKFLOW (extraction guard)" >&2
  exit 1
fi

STRIPPED_FILE="$TMP_DIR/stripped-workflow.txt"
strip_comments <"$WORKFLOW" >"$STRIPPED_FILE"

# ---------------------------------------------------------------------------
# (a) The required job fetches nothing at job time.
# ---------------------------------------------------------------------------
echo "==> (a) The required job installs nothing it does not execute"
FETCHERS=(apt-get curl wget choco)
for tool in "${FETCHERS[@]}"; do
  if grep -q -E "(^|[^A-Za-z0-9_-])${tool}([^A-Za-z0-9_-]|$)" "$JOB_BODY"; then
    fail "the required job ($REQUIRED_JOB) invokes '$tool' — a job-time fetch on the merge boundary. Every service it contacts can block every merge in the repository; #742 is two such outages in one day. If a test needs a binary, name the test."
    grep -n -E "(^|[^A-Za-z0-9_-])${tool}([^A-Za-z0-9_-]|$)" "$JOB_BODY" | sed 's/^/      /' >&2
  else
    ok "no '$tool' in the required job's steps"
  fi
done

# ---------------------------------------------------------------------------
# (b) Everything still provisioned is version-pinned.
# ---------------------------------------------------------------------------
echo "==> (b) Every pipx install is version-pinned"
PIPX_LINES="$TMP_DIR/pipx-lines.txt"
grep -n 'pipx install' "$STRIPPED_FILE" >"$PIPX_LINES" || true
if [ ! -s "$PIPX_LINES" ]; then
  fail "no 'pipx install' line found in $WORKFLOW — pre-commit is a real requirement of the suite (lib/install-hooks.sh gates on it), so its absence is a regression, not a pass"
else
  unpinned=0
  while IFS= read -r line; do
    case "$line" in
      *'=='*) ;;
      *)
        fail "unpinned dependency install: ${line#*:} — an unpinned install resolves to whatever the index serves today, so the required check's verdict depends on a version nobody chose"
        unpinned=$((unpinned + 1))
        ;;
    esac
  done <"$PIPX_LINES"
  if [ "$unpinned" -eq 0 ]; then
    ok "all $(wc -l <"$PIPX_LINES" | tr -d ' ') pipx install line(s) carry a '==' pin"
  fi
fi

# ---------------------------------------------------------------------------
# (c) The remaining job-time fetch is labelled as infrastructure.
# ---------------------------------------------------------------------------
echo "==> (c) The provisioning step is labelled INFRASTRUCTURE"
if grep -q -E '^      - name: .*INFRASTRUCTURE' "$STRIPPED_FILE"; then
  ok "provisioning step name carries the INFRASTRUCTURE label"
else
  fail "no step named with 'INFRASTRUCTURE' — the one step that can fail for a reason that is not a test verdict must say so in its NAME, which is the only part a reader sees without opening the log"
fi
# The label must not have bought itself a softer failure. Fail-closed is the
# property; the label is presentation.
if grep -q -E '^[[:space:]]*continue-on-error:' "$JOB_BODY"; then
  fail "the required job sets continue-on-error — an infrastructure label may change what a failure is CALLED, never whether it blocks"
else
  ok "no continue-on-error in the required job (a labelled failure is still a blocking failure)"
fi

# ---------------------------------------------------------------------------
# (d) The required context keeps its literal name.
# ---------------------------------------------------------------------------
echo "==> (d) The required context is literally '$REQUIRED_CONTEXT'"
MATRIX="$TMP_DIR/matrix.txt"
awk '
  /^        include:[[:space:]]*$/ { in_inc = 1; next }
  /^    [A-Za-z]/ { in_inc = 0 }
  in_inc && /^          - os:[[:space:]]*/ { os = $NF; next }
  in_inc && /^            advisory:[[:space:]]*/ { printf "%s %s\n", os, $NF; next }
' "$WORKFLOW" >"$MATRIX"
if [ ! -s "$MATRIX" ]; then
  fail "could not parse the matrix include entries (parser guard — a vacuous pass is a fail)"
elif grep -q -F -x 'ubuntu-latest false' "$MATRIX"; then
  ok "matrix entry os: ubuntu-latest carries advisory: false"
else
  fail "the ubuntu-latest matrix entry must set advisory: false. The job name is \"\${{ matrix.advisory && 'validate-advisory' || 'validate' }} (\${{ matrix.os }})\", so advisory: true renames the check to 'validate-advisory (ubuntu-latest)' and branch protection's required context '$REQUIRED_CONTEXT' silently stops existing — a green merge gate with nothing behind it. Parsed: $(tr '\n' ';' <"$MATRIX")"
fi
if grep -q -F "name: \${{ matrix.advisory && 'validate-advisory' || 'validate' }} (\${{ matrix.os }})" "$STRIPPED_FILE"; then
  ok "job name expression resolves to '$REQUIRED_CONTEXT' for the non-advisory ubuntu leg"
else
  fail "the required job's name: expression changed — branch protection matches '$REQUIRED_CONTEXT' as a literal string, so any rename un-requires the check without failing anything"
fi

# ---------------------------------------------------------------------------
# (e) The advisory exit-0 tolerance is unreachable from the required leg.
# ---------------------------------------------------------------------------
echo "==> (e) The fast-tier exit 0 tolerance is guarded by matrix.advisory"
FAST_TIER="$TMP_DIR/fast-tier-step.txt"
extract_step "Run the fast tier" >"$FAST_TIER"
if [ ! -s "$FAST_TIER" ]; then
  fail "could not extract the 'Run the fast tier' step (extraction guard — a vacuous pass is a fail)"
else
  ADVISORY_GUARD='if [ "${{ matrix.advisory }}" = "true" ]; then'
  if grep -q -F "$ADVISORY_GUARD" "$FAST_TIER"; then
    ok "advisory tolerance is guarded by the exact literal: $ADVISORY_GUARD"
  else
    fail "the advisory guard must be exactly '$ADVISORY_GUARD'. A negated or loosened condition (\"!= true\", a default, a matrix rename) hands the required leg a tolerance that turns a red suite green."
  fi
  # Walk the step's bash and prove every `exit 0` sits inside that guard.
  UNGUARDED="$(awk '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^#/) next
      if (line ~ /^(if |for |while |case )/) {
        depth++
        if (line ~ /matrix\.advisory/) adv = depth
      } else if (line ~ /^(fi|done|esac)$/) {
        if (adv && depth == adv) adv = 0
        depth--
      }
      if (line ~ /^exit 0([[:space:]]|$)/ && adv == 0) print NR ": " line
    }
  ' "$FAST_TIER")"
  if [ -n "$UNGUARDED" ]; then
    fail "the fast tier contains an 'exit 0' outside the matrix.advisory guard — the required leg would report success on a red suite:"
    printf '%s\n' "$UNGUARDED" | sed 's/^/      /' >&2
  else
    ok "every 'exit 0' in the fast tier sits inside the matrix.advisory guard"
  fi
fi

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS validate workflow check(s) failed"
  exit 1
fi
echo ""
echo "==> PASS: validate workflow dependency-surface guardrails respected"
